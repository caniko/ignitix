use std::collections::HashSet;
use std::env;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use clap::Parser;
use iced::widget::{button, column, container, row, text, text_input};
use iced::{Alignment, Element, Length, Task, Theme, window};
use tempfile::NamedTempFile;
use zeroize::{Zeroize, Zeroizing};

const HOST_KEY_ALIAS: &str = "ignitix-luks-target";
const PROMPT_TIMEOUT: Duration = Duration::from_secs(120);
const CREDENTIAL_TIMEOUT: Duration = Duration::from_secs(30);
const FRAME_MAGIC: &[u8; 8] = b"IGXTPM1\0";
const MAX_PASSPHRASE_BYTES: usize = 4096;
const MAX_PIN_BYTES: usize = 256;
const PCRLOCK_POLICY: &str = "/var/lib/systemd/pcrlock.json";
const DEFAULT_REMOTE_HELPER: &str = "/run/current-system/sw/bin/ignitix-unlock-luks";
const EFI_GLOBAL_VARIABLE_GUID: &str = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
type FramedEnrollmentSecrets = (Zeroizing<Vec<u8>>, Zeroizing<Vec<u8>>);

#[derive(Debug, Parser)]
#[command(
    about = "Securely unlock a remote LUKS device through an Iced prompt",
    after_help = "TPM2 enrollment: ignitix-unlock-luks enroll-tpm2-pin --help"
)]
struct Args {
    /// SSH target in root@host form
    target: String,

    /// Rescue SSH port
    #[arg(long, default_value_t = 22)]
    port: u16,

    /// Expected ED25519 host-key fingerprint, including the SHA256: prefix
    #[arg(long)]
    host_key_sha256: String,

    /// UUID of the remote LUKS device
    #[arg(long)]
    device_uuid: String,

    /// Device-mapper name to create
    #[arg(long, default_value = "cryptroot")]
    mapper: String,
}

#[derive(Debug, Parser)]
#[command(about = "Enroll TPM2+pcrlock+PIN on a remote LUKS2 device")]
struct EnrollArgs {
    /// SSH target in root@host form
    target: String,

    /// Rescue SSH port
    #[arg(long, default_value_t = 22)]
    port: u16,

    /// Expected ED25519 host-key fingerprint, including the SHA256: prefix
    #[arg(long)]
    host_key_sha256: String,

    /// UUID of the remote LUKS2 device
    #[arg(long)]
    device_uuid: String,

    /// Absolute path to this package on the target
    #[arg(long, default_value = DEFAULT_REMOTE_HELPER)]
    remote_helper: PathBuf,
}

#[derive(Debug, Parser)]
struct EnrollHelperArgs {
    #[arg(long)]
    device_uuid: String,

    #[arg(long)]
    preflight: bool,
}

fn main() -> Result<()> {
    disable_core_dumps()?;
    match env::args_os()
        .nth(1)
        .and_then(|arg| arg.into_string().ok())
        .as_deref()
    {
        Some("enroll-tpm2-pin") => run_enroll(EnrollArgs::parse_from(env::args_os().skip(1))),
        Some("enroll-helper") => {
            run_enroll_helper(EnrollHelperArgs::parse_from(env::args_os().skip(1)))
        }
        _ => run_unlock(Args::parse()),
    }
}

fn run_unlock(args: Args) -> Result<()> {
    validate_uuid(&args.device_uuid)?;
    validate_mapper(&args.mapper)?;
    let endpoint = verify_endpoint(&args.target, args.port, &args.host_key_sha256)?;

    let remote_mapper = format!("/dev/mapper/{}", args.mapper);
    let status = ssh_command(&args.target, args.port, endpoint.known_hosts.path())
        .arg(format!("test -e {remote_mapper}"))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("checking remote mapper")?;
    match status.code() {
        Some(0) => {
            eprintln!("{remote_mapper} is already open");
            return Ok(());
        }
        Some(1) => {}
        _ => bail!("could not inspect {remote_mapper} over SSH ({status})"),
    }

    let Some(mut passphrase) = prompt(&args, &endpoint.observed)? else {
        bail!("LUKS unlock cancelled");
    };

    let mut child = ssh_command(&args.target, args.port, endpoint.known_hosts.path())
        .arg(remote_unlock_command(&args.device_uuid, &args.mapper))
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .context("starting SSH unlock command")?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow!("SSH stdin was not piped"))?;
    let write_result = write_secret(&mut stdin, &mut passphrase);
    drop(stdin);
    write_result.context("sending passphrase to cryptsetup")?;

    let status = child.wait().context("waiting for remote cryptsetup")?;
    if !status.success() {
        bail!("remote cryptsetup failed ({status})");
    }

    eprintln!("{remote_mapper} is open");
    Ok(())
}

fn run_enroll(args: EnrollArgs) -> Result<()> {
    validate_uuid(&args.device_uuid)?;
    validate_absolute_path(&args.remote_helper)?;
    let endpoint = verify_endpoint(&args.target, args.port, &args.host_key_sha256)?;

    let status = ssh_command(&args.target, args.port, endpoint.known_hosts.path())
        .arg(remote_enroll_command(
            &args.remote_helper,
            &args.device_uuid,
            true,
        ))
        .status()
        .context("running remote TPM2 enrollment preflight")?;
    if !status.success() {
        bail!("remote TPM2 enrollment preflight failed ({status})");
    }

    let Some(mut secrets) = enroll_prompt(&args, &endpoint.observed)? else {
        bail!("TPM2 enrollment cancelled");
    };

    let mut child = ssh_command(&args.target, args.port, endpoint.known_hosts.path())
        .arg(remote_enroll_command(
            &args.remote_helper,
            &args.device_uuid,
            false,
        ))
        .stdin(Stdio::piped())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .context("starting remote TPM2 enrollment")?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow!("SSH stdin was not piped"))?;
    let write_result =
        write_enrollment_frames(&mut stdin, &mut secrets.passphrase, &mut secrets.pin);
    drop(stdin);
    write_result.context("sending enrollment credentials")?;

    let status = child.wait().context("waiting for TPM2 enrollment")?;
    if !status.success() {
        bail!("remote TPM2 enrollment failed ({status})");
    }
    eprintln!(
        "TPM2+PIN enrollment completed for LUKS UUID {}",
        args.device_uuid
    );
    Ok(())
}

fn run_enroll_helper(args: EnrollHelperArgs) -> Result<()> {
    if effective_uid() != 0 {
        bail!("enroll-helper must run as root");
    }
    validate_uuid(&args.device_uuid)?;
    let device = PathBuf::from(format!("/dev/disk/by-uuid/{}", args.device_uuid));
    enrollment_preflight(&device)?;
    if args.preflight {
        eprintln!("TPM2 enrollment preflight passed");
        return Ok(());
    }

    let _lock = EnrollmentLock::acquire(&PathBuf::from(format!(
        "/run/lock/ignitix-enroll-{}.lock",
        args.device_uuid
    )))?;
    let (passphrase, pin) = read_enrollment_frames(&mut io::stdin().lock())?;
    run_cryptenroll(&device, passphrase, pin)
}

struct EnrollmentLock {
    _file: File,
}

impl EnrollmentLock {
    #[allow(unsafe_code)]
    fn acquire(path: &Path) -> Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .open(path)
            .with_context(|| format!("opening enrollment lock {}", path.display()))?;
        // SAFETY: flock only uses the valid file descriptor and constant flags.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::WouldBlock {
                bail!("TPM2 enrollment is already in progress for this device");
            }
            return Err(error)
                .with_context(|| format!("locking enrollment lock {}", path.display()));
        }
        Ok(Self { _file: file })
    }
}

fn remote_enroll_command(helper: &Path, uuid: &str, preflight: bool) -> String {
    format!(
        "exec {} enroll-helper --device-uuid {}{}",
        helper.display(),
        uuid,
        if preflight { " --preflight" } else { "" }
    )
}

fn write_enrollment_frames<W: Write>(
    writer: &mut W,
    passphrase: &mut Zeroizing<String>,
    pin: &mut Zeroizing<String>,
) -> io::Result<()> {
    let result = (|| {
        if passphrase.is_empty()
            || passphrase.len() > MAX_PASSPHRASE_BYTES
            || pin.is_empty()
            || pin.len() > MAX_PIN_BYTES
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "credential length is outside protocol bounds",
            ));
        }
        writer.write_all(FRAME_MAGIC)?;
        write_frame(writer, passphrase.as_bytes())?;
        write_frame(writer, pin.as_bytes())
    })();
    passphrase.zeroize();
    pin.zeroize();
    result
}

fn write_frame<W: Write>(writer: &mut W, value: &[u8]) -> io::Result<()> {
    writer.write_all(&(value.len() as u32).to_be_bytes())?;
    writer.write_all(value)
}

fn read_enrollment_frames<R: Read>(reader: &mut R) -> Result<FramedEnrollmentSecrets> {
    let mut magic = [0_u8; FRAME_MAGIC.len()];
    reader
        .read_exact(&mut magic)
        .context("reading enrollment protocol header")?;
    if &magic != FRAME_MAGIC {
        bail!("invalid enrollment protocol header");
    }
    let passphrase = read_frame(reader, MAX_PASSPHRASE_BYTES, "passphrase")?;
    let pin = read_frame(reader, MAX_PIN_BYTES, "PIN")?;
    if passphrase.is_empty() || pin.is_empty() {
        bail!("enrollment credentials must not be empty");
    }
    let mut trailing = [0_u8; 1];
    if reader.read(&mut trailing)? != 0 {
        trailing.zeroize();
        bail!("unexpected trailing enrollment data");
    }
    Ok((passphrase, pin))
}

fn read_frame<R: Read>(reader: &mut R, maximum: usize, name: &str) -> Result<Zeroizing<Vec<u8>>> {
    let mut encoded_length = [0_u8; 4];
    reader
        .read_exact(&mut encoded_length)
        .with_context(|| format!("reading {name} frame length"))?;
    let length = u32::from_be_bytes(encoded_length) as usize;
    if length > maximum {
        bail!("{name} frame exceeds {maximum} bytes");
    }
    let mut value = Zeroizing::new(vec![0_u8; length]);
    reader
        .read_exact(&mut value)
        .with_context(|| format!("reading {name} frame"))?;
    Ok(value)
}

fn enrollment_preflight(device: &Path) -> Result<()> {
    let policy = fs::metadata(PCRLOCK_POLICY)
        .with_context(|| format!("required pcrlock policy is missing: {PCRLOCK_POLICY}"))?;
    if !policy.is_file() || policy.len() == 0 {
        bail!("pcrlock policy must be a non-empty regular file: {PCRLOCK_POLICY}");
    }
    let policy = fs::read(PCRLOCK_POLICY)
        .with_context(|| format!("reading required pcrlock policy: {PCRLOCK_POLICY}"))?;
    let policy: serde_json::Value =
        serde_json::from_slice(&policy).context("parsing pcrlock policy")?;
    validate_pcrlock_policy(&policy)?;

    let metadata = fs::metadata(device)
        .with_context(|| format!("expected LUKS2 device is missing: {}", device.display()))?;
    if !metadata.file_type().is_block_device() {
        bail!(
            "expected LUKS2 path is not a block device: {}",
            device.display()
        );
    }
    secure_boot_preflight(Path::new("/sys/firmware/efi/efivars"))?;

    let output = Command::new("cryptsetup")
        .args(["luksDump", "--dump-json-metadata"])
        .arg(device)
        .stdin(Stdio::null())
        .stderr(Stdio::inherit())
        .output()
        .context("inspecting LUKS2 metadata")?;
    if !output.status.success() {
        bail!(
            "cryptsetup could not read expected LUKS2 metadata ({})",
            output.status
        );
    }
    let metadata: serde_json::Value =
        serde_json::from_slice(&output.stdout).context("parsing LUKS2 JSON metadata")?;
    validate_luks_metadata(&metadata)
}

fn validate_pcrlock_policy(policy: &serde_json::Value) -> Result<()> {
    let pcr_values = policy
        .get("pcrValues")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| anyhow!("pcrlock policy has no pcrValues array"))?;
    for required in [4, 7] {
        let present = pcr_values.iter().any(|entry| {
            entry.get("pcr").and_then(serde_json::Value::as_u64) == Some(required)
                && entry
                    .get("values")
                    .and_then(serde_json::Value::as_array)
                    .is_some_and(|values| !values.is_empty())
        });
        if !present {
            bail!("pcrlock policy does not protect required PCR {required}");
        }
    }
    Ok(())
}

fn secure_boot_preflight(efivars: &Path) -> Result<()> {
    if read_efi_variable(efivars, "SecureBoot")? != 1 {
        bail!("Secure Boot is not enabled");
    }
    if read_efi_variable(efivars, "SetupMode")? != 0 {
        bail!("firmware is not in Secure Boot user mode");
    }
    Ok(())
}

fn read_efi_variable(directory: &Path, name: &str) -> Result<u8> {
    let path = directory.join(format!("{name}-{EFI_GLOBAL_VARIABLE_GUID}"));
    let value =
        fs::read(&path).with_context(|| format!("reading EFI variable {}", path.display()))?;
    efi_variable_value(&value)
        .ok_or_else(|| anyhow!("EFI variable {} is malformed", path.display()))
}

fn efi_variable_value(value: &[u8]) -> Option<u8> {
    value.get(4).copied()
}

fn validate_luks_metadata(metadata: &serde_json::Value) -> Result<()> {
    let keyslots = metadata
        .get("keyslots")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| anyhow!("LUKS2 metadata has no keyslots object"))?;
    if keyslots.is_empty() {
        bail!("LUKS2 device has no enrolled keyslots");
    }

    let tokens = metadata
        .get("tokens")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| anyhow!("LUKS2 metadata has no tokens object"))?;
    let mut token_keyslots = HashSet::new();
    for token in tokens.values() {
        if token.get("type").and_then(serde_json::Value::as_str) == Some("systemd-tpm2") {
            bail!("LUKS2 device already has a TPM2 token");
        }
        if let Some(slots) = token.get("keyslots").and_then(serde_json::Value::as_array) {
            token_keyslots.extend(slots.iter().filter_map(serde_json::Value::as_str));
        }
    }
    if !keyslots
        .keys()
        .any(|slot| !token_keyslots.contains(slot.as_str()))
    {
        bail!("LUKS2 device has no password keyslot");
    }
    Ok(())
}

fn run_cryptenroll(
    device: &Path,
    passphrase: Zeroizing<Vec<u8>>,
    pin: Zeroizing<Vec<u8>>,
) -> Result<()> {
    enrollment_preflight(device)?;
    let directory = tempfile::Builder::new()
        .prefix("ignitix-cryptenroll-")
        .tempdir_in("/run")
        .context("creating runtime credential socket directory")?;
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))?;
    let passphrase_socket = directory.path().join("passphrase.sock");
    let pin_socket = directory.path().join("pin.sock");
    let passphrase_listener = bind_credential_socket(&passphrase_socket)?;
    let pin_listener = bind_credential_socket(&pin_socket)?;
    let cancelled = Arc::new(AtomicBool::new(false));
    let passphrase_server =
        spawn_credential_server(passphrase_listener, passphrase, Arc::clone(&cancelled));
    let pin_server = spawn_credential_server(pin_listener, pin, Arc::clone(&cancelled));

    let status = cryptenroll_command(device, &passphrase_socket, &pin_socket).status();
    cancelled.store(true, Ordering::Release);
    let passphrase_result = passphrase_server
        .join()
        .map_err(|_| anyhow!("passphrase credential server panicked"))?;
    let pin_result = pin_server
        .join()
        .map_err(|_| anyhow!("PIN credential server panicked"))?;
    let status = status.context("starting transient systemd-cryptenroll service")?;
    passphrase_result?;
    pin_result?;
    if !status.success() {
        bail!("systemd-cryptenroll failed ({status})");
    }
    Ok(())
}

fn bind_credential_socket(path: &Path) -> Result<UnixListener> {
    let listener = UnixListener::bind(path)
        .with_context(|| format!("binding credential socket {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    listener.set_nonblocking(true)?;
    Ok(listener)
}

fn spawn_credential_server(
    listener: UnixListener,
    secret: Zeroizing<Vec<u8>>,
    cancelled: Arc<AtomicBool>,
) -> thread::JoinHandle<Result<()>> {
    thread::spawn(move || serve_credential_once(listener, secret, &cancelled))
}

fn serve_credential_once(
    listener: UnixListener,
    mut secret: Zeroizing<Vec<u8>>,
    cancelled: &AtomicBool,
) -> Result<()> {
    let deadline = Instant::now() + CREDENTIAL_TIMEOUT;
    loop {
        match listener.accept() {
            Ok((mut stream, _)) => {
                let result = stream.write_all(&secret);
                secret.zeroize();
                return result.context("serving transient systemd credential");
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if cancelled.load(Ordering::Acquire) {
                    bail!("credential request was cancelled");
                }
                if Instant::now() >= deadline {
                    bail!("timed out waiting for systemd credential request");
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(error).context("accepting systemd credential request"),
        }
    }
}

fn cryptenroll_command(device: &Path, passphrase_socket: &Path, pin_socket: &Path) -> Command {
    let mut command = Command::new("systemd-run");
    command
        .args([
            "--quiet",
            "--wait",
            "--collect",
            "--pipe",
            "--service-type=exec",
            "--property=LimitCORE=0",
        ])
        .arg(format!(
            "--property=LoadCredential=cryptenroll.passphrase:{}",
            passphrase_socket.display()
        ))
        .arg(format!(
            "--property=LoadCredential=cryptenroll.new-tpm2-pin:{}",
            pin_socket.display()
        ))
        .args([
            "systemd-cryptenroll",
            "--tpm2-device=auto",
            "--tpm2-with-pin=true",
            "--tpm2-pcrlock=/var/lib/systemd/pcrlock.json",
        ])
        .arg(device)
        .stdin(Stdio::null());
    command
}

#[allow(unsafe_code)]
fn disable_core_dumps() -> Result<()> {
    let limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: setrlimit only reads the fully initialized rlimit value.
    if unsafe { libc::setrlimit(libc::RLIMIT_CORE, &limit) } != 0 {
        return Err(io::Error::last_os_error()).context("disabling core dumps");
    }
    Ok(())
}

#[allow(unsafe_code)]
fn effective_uid() -> libc::uid_t {
    // SAFETY: geteuid has no arguments or preconditions.
    unsafe { libc::geteuid() }
}

struct VerifiedEndpoint {
    observed: String,
    known_hosts: NamedTempFile,
}

fn verify_endpoint(
    target: &str,
    port: u16,
    expected_fingerprint: &str,
) -> Result<VerifiedEndpoint> {
    let scan_host = validate_target(target)?;
    validate_fingerprint(expected_fingerprint)?;
    eprintln!("Verifying rescue host {target}:{port}");
    let scanned_key = scan_ed25519_host_key(scan_host, port)?;
    let pinned_key = alias_host_key(&scanned_key)?;
    let observed = fingerprint(&pinned_key)?;
    if observed != expected_fingerprint {
        bail!("rescue host-key mismatch: expected {expected_fingerprint}, got {observed}");
    }
    eprintln!("Verified host key: {observed}");

    let mut known_hosts = NamedTempFile::new().context("creating temporary known_hosts")?;
    fs::set_permissions(known_hosts.path(), fs::Permissions::from_mode(0o600))?;
    writeln!(known_hosts, "{pinned_key}")?;
    known_hosts.flush()?;
    Ok(VerifiedEndpoint {
        observed,
        known_hosts,
    })
}

fn ssh_command(target: &str, port: u16, known_hosts: &Path) -> Command {
    let mut command = Command::new("ssh");
    command.args([
        "-F".to_string(),
        "/dev/null".to_string(),
        "-T".to_string(),
        "-p".to_string(),
        port.to_string(),
        "-o".to_string(),
        "BatchMode=yes".to_string(),
        "-o".to_string(),
        "PasswordAuthentication=no".to_string(),
        "-o".to_string(),
        "KbdInteractiveAuthentication=no".to_string(),
        "-o".to_string(),
        "HostKeyAlgorithms=ssh-ed25519".to_string(),
        "-o".to_string(),
        format!("HostKeyAlias={HOST_KEY_ALIAS}"),
        "-o".to_string(),
        "StrictHostKeyChecking=yes".to_string(),
        "-o".to_string(),
        format!("UserKnownHostsFile={}", known_hosts.display()),
        "-o".to_string(),
        "GlobalKnownHostsFile=/dev/null".to_string(),
        "-o".to_string(),
        "ControlMaster=no".to_string(),
        "-o".to_string(),
        "ControlPath=none".to_string(),
        "-o".to_string(),
        "ConnectTimeout=5".to_string(),
        "-o".to_string(),
        "LogLevel=ERROR".to_string(),
        target.to_owned(),
    ]);
    command
}

fn validate_target(target: &str) -> Result<&str> {
    let (user, host) = target
        .split_once('@')
        .ok_or_else(|| anyhow!("target must use root@host form"))?;
    if user != "root" {
        bail!("target user must be root");
    }
    if host.is_empty()
        || !host
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ".:-[]".contains(ch))
    {
        bail!("target host contains unsupported characters");
    }
    let scan_host = host
        .strip_prefix('[')
        .and_then(|host| host.strip_suffix(']'))
        .unwrap_or(host);
    if scan_host.is_empty()
        || (host.contains(['[', ']']) && !(host.starts_with('[') && host.ends_with(']')))
    {
        bail!("target host is malformed");
    }
    Ok(scan_host)
}

fn scan_ed25519_host_key(host: &str, port: u16) -> Result<String> {
    let output = Command::new("ssh-keyscan")
        .args(["-T", "5", "-p", &port.to_string(), "-t", "ed25519", host])
        .stderr(Stdio::null())
        .output()
        .context("running ssh-keyscan")?;
    if !output.status.success() {
        bail!("ssh-keyscan failed ({})", output.status);
    }
    let stdout = String::from_utf8(output.stdout).context("ssh-keyscan returned non-UTF-8")?;
    stdout
        .lines()
        .find(|line| line.split_whitespace().nth(1) == Some("ssh-ed25519"))
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("ssh-keyscan returned no ED25519 host key"))
}

fn alias_host_key(scanned_key: &str) -> Result<String> {
    let mut fields = scanned_key.split_whitespace();
    let _host = fields.next();
    let key_type = fields.next();
    let key = fields.next();
    match (key_type, key) {
        (Some("ssh-ed25519"), Some(key)) => Ok(format!("{HOST_KEY_ALIAS} ssh-ed25519 {key}")),
        _ => bail!("invalid ED25519 host-key record"),
    }
}

fn fingerprint(host_key: &str) -> Result<String> {
    let mut child = Command::new("ssh-keygen")
        .args(["-E", "sha256", "-lf", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .context("running ssh-keygen")?;
    writeln!(
        child
            .stdin
            .take()
            .ok_or_else(|| anyhow!("ssh-keygen stdin was not piped"))?,
        "{host_key}"
    )?;
    let output = child.wait_with_output()?;
    if !output.status.success() {
        bail!("ssh-keygen failed ({})", output.status);
    }
    String::from_utf8(output.stdout)?
        .split_whitespace()
        .nth(1)
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("ssh-keygen returned no fingerprint"))
}

fn remote_unlock_command(uuid: &str, mapper: &str) -> String {
    format!(
        "exec cryptsetup open --type luks --batch-mode --key-file=- /dev/disk/by-uuid/{uuid} {mapper}"
    )
}

fn write_secret<W: Write>(writer: &mut W, secret: &mut Zeroizing<String>) -> io::Result<()> {
    let result = writer.write_all(secret.as_bytes());
    secret.zeroize();
    result
}

fn validate_fingerprint(value: &str) -> Result<()> {
    let Some(digest) = value.strip_prefix("SHA256:") else {
        bail!("host fingerprint must be one SHA256: value");
    };
    if digest.len() != 43
        || !digest
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'+' | b'/'))
    {
        bail!("host fingerprint must contain an unpadded SHA256 digest");
    }
    Ok(())
}

fn validate_uuid(value: &str) -> Result<()> {
    let valid = value.len() == 36
        && value.chars().enumerate().all(|(index, ch)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                ch == '-'
            } else {
                ch.is_ascii_hexdigit()
            }
        });
    if !valid {
        bail!("device UUID must use canonical 8-4-4-4-12 hexadecimal form");
    }
    Ok(())
}

fn validate_mapper(value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > 127
        || !value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || "_.+-".contains(ch))
    {
        bail!("mapper must contain only ASCII letters, numbers, '_', '.', '+', or '-'");
    }
    Ok(())
}

fn validate_absolute_path(value: &Path) -> Result<()> {
    if !value.is_absolute()
        || value
            .components()
            .any(|component| !matches!(component, Component::RootDir | Component::Normal(_)))
        || !value.as_os_str().as_encoded_bytes().iter().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'_' | b'.' | b'+' | b'-')
        })
    {
        bail!("remote helper must be a normalized absolute ASCII path");
    }
    Ok(())
}

#[derive(Clone)]
enum Message {
    PassphraseChanged(String),
    Submit,
    Cancel,
    Timeout,
}

impl fmt::Debug for Message {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PassphraseChanged(_) => formatter.write_str("PassphraseChanged([REDACTED])"),
            Self::Submit => formatter.write_str("Submit"),
            Self::Cancel => formatter.write_str("Cancel"),
            Self::Timeout => formatter.write_str("Timeout"),
        }
    }
}

enum Outcome {
    Cancelled,
    Timeout,
    Submitted(Zeroizing<String>),
}

struct Prompt {
    target: String,
    fingerprint: String,
    device_uuid: String,
    passphrase: String,
    outcome: Arc<Mutex<Outcome>>,
}

impl Drop for Prompt {
    fn drop(&mut self) {
        self.passphrase.zeroize();
    }
}

fn prompt(args: &Args, fingerprint: &str) -> Result<Option<Zeroizing<String>>> {
    if env::var_os("WAYLAND_DISPLAY").is_none() && env::var_os("DISPLAY").is_none() {
        bail!("no Wayland or X11 display is available for the LUKS prompt");
    }

    let outcome = Arc::new(Mutex::new(Outcome::Cancelled));
    let app_outcome = Arc::clone(&outcome);
    let target = format!("{}:{}", args.target, args.port);
    let fingerprint = fingerprint.to_owned();
    let device_uuid = args.device_uuid.clone();

    iced::application(
        move || {
            (
                Prompt {
                    target: target.clone(),
                    fingerprint: fingerprint.clone(),
                    device_uuid: device_uuid.clone(),
                    passphrase: String::new(),
                    outcome: Arc::clone(&app_outcome),
                },
                Task::none(),
            )
        },
        update,
        view,
    )
    .title("Ignitix LUKS unlock")
    .theme(|_: &Prompt| Theme::Dark)
    .window_size((520.0, 340.0))
    .resizable(false)
    .centered()
    .subscription(|_| iced::time::every(PROMPT_TIMEOUT).map(|_| Message::Timeout))
    .run()
    .context("running Iced LUKS prompt")?;

    let result = match std::mem::replace(
        &mut *outcome
            .lock()
            .map_err(|_| anyhow!("LUKS prompt outcome lock was poisoned"))?,
        Outcome::Cancelled,
    ) {
        Outcome::Submitted(passphrase) => Some(passphrase),
        Outcome::Cancelled => None,
        Outcome::Timeout => bail!("LUKS prompt timed out"),
    };
    Ok(result)
}

fn update(prompt: &mut Prompt, message: Message) -> Task<Message> {
    match message {
        Message::PassphraseChanged(value) => {
            prompt.passphrase.zeroize();
            prompt.passphrase = value;
            Task::none()
        }
        Message::Submit if prompt.passphrase.is_empty() => Task::none(),
        Message::Submit => {
            let passphrase = Zeroizing::new(std::mem::take(&mut prompt.passphrase));
            set_outcome(&prompt.outcome, Outcome::Submitted(passphrase));
            close_window()
        }
        Message::Cancel => {
            prompt.passphrase.zeroize();
            set_outcome(&prompt.outcome, Outcome::Cancelled);
            close_window()
        }
        Message::Timeout => {
            prompt.passphrase.zeroize();
            set_outcome(&prompt.outcome, Outcome::Timeout);
            close_window()
        }
    }
}

fn view(prompt: &Prompt) -> Element<'_, Message> {
    let content = column![
        text("Unlock encrypted storage").size(24),
        text(format!("Rescue host: {}", prompt.target)).size(14),
        text(format!("Verified key: {}", prompt.fingerprint)).size(14),
        text(format!("LUKS UUID: {}", prompt.device_uuid)).size(14),
        text_input("LUKS passphrase", &prompt.passphrase)
            .secure(true)
            .on_input(Message::PassphraseChanged)
            .on_submit(Message::Submit)
            .padding([12, 12])
            .size(18)
            .width(Length::Fill),
        row![
            button(text("Cancel"))
                .on_press(Message::Cancel)
                .padding([10, 18]),
            button(text("Unlock"))
                .on_press(Message::Submit)
                .padding([10, 18]),
        ]
        .spacing(12)
        .align_y(Alignment::Center),
    ]
    .spacing(14)
    .align_x(Alignment::Start)
    .width(Length::Fill);

    container(content)
        .padding(24)
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

fn set_outcome(outcome: &Mutex<Outcome>, value: Outcome) {
    if let Ok(mut current) = outcome.lock() {
        *current = value;
    }
}

fn close_window() -> Task<Message> {
    window::latest().then(|id| match id {
        Some(id) => window::close(id),
        None => Task::none(),
    })
}

struct EnrollmentSecrets {
    passphrase: Zeroizing<String>,
    pin: Zeroizing<String>,
}

#[derive(Clone)]
enum EnrollMessage {
    PassphraseChanged(String),
    PinChanged(String),
    PinConfirmationChanged(String),
    Submit,
    Cancel,
    Timeout,
}

impl fmt::Debug for EnrollMessage {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PassphraseChanged(_) => formatter.write_str("PassphraseChanged([REDACTED])"),
            Self::PinChanged(_) => formatter.write_str("PinChanged([REDACTED])"),
            Self::PinConfirmationChanged(_) => {
                formatter.write_str("PinConfirmationChanged([REDACTED])")
            }
            Self::Submit => formatter.write_str("Submit"),
            Self::Cancel => formatter.write_str("Cancel"),
            Self::Timeout => formatter.write_str("Timeout"),
        }
    }
}

enum EnrollOutcome {
    Cancelled,
    Timeout,
    Submitted(EnrollmentSecrets),
}

struct EnrollPrompt {
    target: String,
    fingerprint: String,
    device_uuid: String,
    passphrase: String,
    pin: String,
    pin_confirmation: String,
    outcome: Arc<Mutex<EnrollOutcome>>,
}

impl Drop for EnrollPrompt {
    fn drop(&mut self) {
        self.passphrase.zeroize();
        self.pin.zeroize();
        self.pin_confirmation.zeroize();
    }
}

fn enroll_prompt(args: &EnrollArgs, fingerprint: &str) -> Result<Option<EnrollmentSecrets>> {
    if env::var_os("WAYLAND_DISPLAY").is_none() && env::var_os("DISPLAY").is_none() {
        bail!("no Wayland or X11 display is available for the TPM2 enrollment prompt");
    }

    let outcome = Arc::new(Mutex::new(EnrollOutcome::Cancelled));
    let app_outcome = Arc::clone(&outcome);
    let target = format!("{}:{}", args.target, args.port);
    let fingerprint = fingerprint.to_owned();
    let device_uuid = args.device_uuid.clone();

    iced::application(
        move || {
            (
                EnrollPrompt {
                    target: target.clone(),
                    fingerprint: fingerprint.clone(),
                    device_uuid: device_uuid.clone(),
                    passphrase: String::new(),
                    pin: String::new(),
                    pin_confirmation: String::new(),
                    outcome: Arc::clone(&app_outcome),
                },
                Task::none(),
            )
        },
        update_enroll,
        view_enroll,
    )
    .title("Ignitix TPM2+PIN enrollment")
    .theme(|_: &EnrollPrompt| Theme::Dark)
    .window_size((560.0, 500.0))
    .resizable(false)
    .centered()
    .subscription(|_| iced::time::every(PROMPT_TIMEOUT).map(|_| EnrollMessage::Timeout))
    .run()
    .context("running Iced TPM2 enrollment prompt")?;

    match std::mem::replace(
        &mut *outcome
            .lock()
            .map_err(|_| anyhow!("TPM2 enrollment prompt outcome lock was poisoned"))?,
        EnrollOutcome::Cancelled,
    ) {
        EnrollOutcome::Submitted(secrets) => Ok(Some(secrets)),
        EnrollOutcome::Cancelled => Ok(None),
        EnrollOutcome::Timeout => bail!("TPM2 enrollment prompt timed out"),
    }
}

fn update_enroll(prompt: &mut EnrollPrompt, message: EnrollMessage) -> Task<EnrollMessage> {
    match message {
        EnrollMessage::PassphraseChanged(value) if value.len() <= MAX_PASSPHRASE_BYTES => {
            prompt.passphrase.zeroize();
            prompt.passphrase = value;
            Task::none()
        }
        EnrollMessage::PinChanged(value) if value.len() <= MAX_PIN_BYTES => {
            prompt.pin.zeroize();
            prompt.pin = value;
            Task::none()
        }
        EnrollMessage::PinConfirmationChanged(value) if value.len() <= MAX_PIN_BYTES => {
            prompt.pin_confirmation.zeroize();
            prompt.pin_confirmation = value;
            Task::none()
        }
        EnrollMessage::PassphraseChanged(mut value)
        | EnrollMessage::PinChanged(mut value)
        | EnrollMessage::PinConfirmationChanged(mut value) => {
            value.zeroize();
            Task::none()
        }
        EnrollMessage::Submit if !enrollment_ready(prompt) => Task::none(),
        EnrollMessage::Submit => {
            let secrets = EnrollmentSecrets {
                passphrase: Zeroizing::new(std::mem::take(&mut prompt.passphrase)),
                pin: Zeroizing::new(std::mem::take(&mut prompt.pin)),
            };
            prompt.pin_confirmation.zeroize();
            set_enroll_outcome(&prompt.outcome, EnrollOutcome::Submitted(secrets));
            close_enroll_window()
        }
        EnrollMessage::Cancel => {
            clear_enroll_prompt(prompt);
            set_enroll_outcome(&prompt.outcome, EnrollOutcome::Cancelled);
            close_enroll_window()
        }
        EnrollMessage::Timeout => {
            clear_enroll_prompt(prompt);
            set_enroll_outcome(&prompt.outcome, EnrollOutcome::Timeout);
            close_enroll_window()
        }
    }
}

fn enrollment_ready(prompt: &EnrollPrompt) -> bool {
    !prompt.passphrase.is_empty() && !prompt.pin.is_empty() && prompt.pin == prompt.pin_confirmation
}

fn clear_enroll_prompt(prompt: &mut EnrollPrompt) {
    prompt.passphrase.zeroize();
    prompt.pin.zeroize();
    prompt.pin_confirmation.zeroize();
}

fn view_enroll(prompt: &EnrollPrompt) -> Element<'_, EnrollMessage> {
    let pin_status = if prompt.pin_confirmation.is_empty() || prompt.pin == prompt.pin_confirmation
    {
        ""
    } else {
        "PIN confirmation does not match"
    };
    let content = column![
        text("Enroll TPM2 with PIN").size(24),
        text(format!("Rescue host: {}", prompt.target)).size(14),
        text(format!("Verified key: {}", prompt.fingerprint)).size(14),
        text(format!("LUKS UUID: {}", prompt.device_uuid)).size(14),
        text("The target passed Secure Boot, pcrlock, LUKS2, password-slot, and TPM-token checks.")
            .size(14),
        text_input("Existing LUKS passphrase", &prompt.passphrase)
            .secure(true)
            .on_input(EnrollMessage::PassphraseChanged)
            .padding([12, 12])
            .size(18)
            .width(Length::Fill),
        text_input("New TPM PIN", &prompt.pin)
            .secure(true)
            .on_input(EnrollMessage::PinChanged)
            .padding([12, 12])
            .size(18)
            .width(Length::Fill),
        text_input("Confirm new TPM PIN", &prompt.pin_confirmation)
            .secure(true)
            .on_input(EnrollMessage::PinConfirmationChanged)
            .on_submit(EnrollMessage::Submit)
            .padding([12, 12])
            .size(18)
            .width(Length::Fill),
        text(pin_status).size(14),
        row![
            button(text("Cancel"))
                .on_press(EnrollMessage::Cancel)
                .padding([10, 18]),
            button(text("Enroll TPM2+PIN"))
                .on_press(EnrollMessage::Submit)
                .padding([10, 18]),
        ]
        .spacing(12)
        .align_y(Alignment::Center),
    ]
    .spacing(12)
    .align_x(Alignment::Start)
    .width(Length::Fill);

    container(content)
        .padding(24)
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

fn set_enroll_outcome(outcome: &Mutex<EnrollOutcome>, value: EnrollOutcome) {
    if let Ok(mut current) = outcome.lock() {
        *current = value;
    }
}

fn close_enroll_window() -> Task<EnrollMessage> {
    window::latest().then(|id| match id {
        Some(id) => window::close(id),
        None => Task::none(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;

    fn test_prompt(passphrase: &str) -> Prompt {
        Prompt {
            target: "root@10.10.0.2:1337".to_owned(),
            fingerprint: "SHA256:test".to_owned(),
            device_uuid: "fdb706ad-54f0-40ea-acba-c24fe5e38edf".to_owned(),
            passphrase: passphrase.to_owned(),
            outcome: Arc::new(Mutex::new(Outcome::Cancelled)),
        }
    }

    #[test]
    fn validators_reject_unsafe_input() {
        assert!(validate_target("user@host").is_err());
        assert!(validate_target("root@host;id").is_err());
        assert!(validate_target("root@ho[st").is_err());
        assert!(validate_uuid("$(id)").is_err());
        assert!(validate_mapper("cryptroot;id").is_err());
        assert!(validate_fingerprint("SHA256:key other").is_err());
        assert!(validate_absolute_path(Path::new("relative/helper")).is_err());
        assert!(validate_absolute_path(Path::new("/run/../tmp/helper")).is_err());
        assert!(validate_absolute_path(Path::new("/run/helper;id")).is_err());
        assert!(validate_fingerprint(&format!("SHA256:{}", "A".repeat(43))).is_ok());
    }

    #[test]
    fn host_key_alias_discards_scanned_address() {
        assert_eq!(
            alias_host_key("[10.10.0.2]:1337 ssh-ed25519 AAAAkey").unwrap(),
            "ignitix-luks-target ssh-ed25519 AAAAkey"
        );
    }

    #[test]
    fn remote_command_contains_only_validated_identifiers() {
        let command = remote_unlock_command("fdb706ad-54f0-40ea-acba-c24fe5e38edf", "cryptroot");
        assert_eq!(
            command,
            "exec cryptsetup open --type luks --batch-mode --key-file=- /dev/disk/by-uuid/fdb706ad-54f0-40ea-acba-c24fe5e38edf cryptroot"
        );
        assert!(!command.contains("passphrase"));
    }

    #[test]
    fn stdin_transport_preserves_then_zeroizes_secret() {
        let mut output = Vec::new();
        let mut secret = Zeroizing::new(" leading and trailing ".to_owned());
        write_secret(&mut output, &mut secret).unwrap();
        assert_eq!(output, b" leading and trailing ");
        assert!(secret.is_empty());
    }

    #[test]
    fn submit_preserves_passphrase_whitespace() {
        let mut prompt = test_prompt(" leading and trailing ");
        let _ = update(&mut prompt, Message::Submit);
        let outcome = std::mem::replace(&mut *prompt.outcome.lock().unwrap(), Outcome::Cancelled);
        assert!(
            matches!(outcome, Outcome::Submitted(value) if value.as_str() == " leading and trailing ")
        );
    }

    #[test]
    fn secret_messages_redact_debug_values() {
        let marker = "do-not-print-this-secret";
        let messages = [
            format!("{:?}", Message::PassphraseChanged(marker.to_owned())),
            format!("{:?}", EnrollMessage::PassphraseChanged(marker.to_owned())),
            format!("{:?}", EnrollMessage::PinChanged(marker.to_owned())),
            format!(
                "{:?}",
                EnrollMessage::PinConfirmationChanged(marker.to_owned())
            ),
        ];
        assert!(messages.iter().all(|message| !message.contains(marker)));
        assert!(
            messages
                .iter()
                .all(|message| message.contains("[REDACTED]"))
        );
    }

    #[test]
    fn enrollment_framing_round_trips_and_zeroizes_sources() {
        let mut encoded = Vec::new();
        let mut passphrase = Zeroizing::new(" pass phrase ".to_owned());
        let mut pin = Zeroizing::new("1234".to_owned());
        write_enrollment_frames(&mut encoded, &mut passphrase, &mut pin).unwrap();
        assert!(passphrase.is_empty());
        assert!(pin.is_empty());

        let (decoded_passphrase, decoded_pin) =
            read_enrollment_frames(&mut encoded.as_slice()).unwrap();
        assert_eq!(&*decoded_passphrase, b" pass phrase ");
        assert_eq!(&*decoded_pin, b"1234");
    }

    #[test]
    fn enrollment_framing_rejects_malformed_oversized_and_trailing_data() {
        assert!(read_enrollment_frames(&mut b"wrong".as_slice()).is_err());

        let mut oversized = FRAME_MAGIC.to_vec();
        oversized.extend_from_slice(&((MAX_PASSPHRASE_BYTES + 1) as u32).to_be_bytes());
        assert!(read_enrollment_frames(&mut oversized.as_slice()).is_err());

        let mut trailing = Vec::new();
        let mut passphrase = Zeroizing::new("passphrase".to_owned());
        let mut pin = Zeroizing::new("pin".to_owned());
        write_enrollment_frames(&mut trailing, &mut passphrase, &mut pin).unwrap();
        trailing.push(1);
        assert!(read_enrollment_frames(&mut trailing.as_slice()).is_err());
    }

    #[test]
    fn enrollment_requires_matching_pin() {
        let mut prompt = EnrollPrompt {
            target: "root@host:22".to_owned(),
            fingerprint: format!("SHA256:{}", "A".repeat(43)),
            device_uuid: "fdb706ad-54f0-40ea-acba-c24fe5e38edf".to_owned(),
            passphrase: "passphrase".to_owned(),
            pin: "1234".to_owned(),
            pin_confirmation: "4321".to_owned(),
            outcome: Arc::new(Mutex::new(EnrollOutcome::Cancelled)),
        };
        assert!(!enrollment_ready(&prompt));
        prompt.pin_confirmation = "1234".to_owned();
        assert!(enrollment_ready(&prompt));
    }

    #[test]
    fn cryptenroll_command_contains_public_data_only_and_never_wipes_slots() {
        let marker = "do-not-print-this-secret";
        let command = cryptenroll_command(
            Path::new("/dev/disk/by-uuid/fdb706ad-54f0-40ea-acba-c24fe5e38edf"),
            Path::new("/run/credentials/passphrase.sock"),
            Path::new("/run/credentials/pin.sock"),
        );
        let command_line = command
            .get_args()
            .map(|argument| argument.to_string_lossy())
            .collect::<Vec<_>>()
            .join(" ");
        assert!(!command_line.contains(marker));
        assert!(!command_line.contains("--wipe-slot"));
        assert!(command_line.contains("--tpm2-device=auto"));
        assert!(command_line.contains("--tpm2-with-pin=true"));
        assert!(command_line.contains("--tpm2-pcrlock=/var/lib/systemd/pcrlock.json"));
        assert!(command.get_envs().all(|(_, value)| {
            value.is_none_or(|value| !value.to_string_lossy().contains(marker))
        }));
    }

    #[test]
    fn luks_metadata_requires_password_slot_and_refuses_existing_tpm() {
        let valid = serde_json::json!({
            "keyslots": {"0": {"type": "luks2"}},
            "tokens": {}
        });
        assert!(validate_luks_metadata(&valid).is_ok());

        let tpm = serde_json::json!({
            "keyslots": {"0": {"type": "luks2"}, "1": {"type": "luks2"}},
            "tokens": {"0": {"type": "systemd-tpm2", "keyslots": ["1"]}}
        });
        assert!(validate_luks_metadata(&tpm).is_err());

        let token_only = serde_json::json!({
            "keyslots": {"0": {"type": "luks2"}},
            "tokens": {"0": {"type": "systemd-recovery", "keyslots": ["0"]}}
        });
        assert!(validate_luks_metadata(&token_only).is_err());
    }

    #[test]
    fn secure_boot_requires_enabled_user_mode() {
        assert_eq!(efi_variable_value(&[7, 0, 0, 0, 1]), Some(1));
        assert_eq!(efi_variable_value(&[7, 0, 0, 0]), None);

        let directory = tempfile::tempdir().unwrap();
        fs::write(
            directory
                .path()
                .join(format!("SecureBoot-{EFI_GLOBAL_VARIABLE_GUID}")),
            [7, 0, 0, 0, 1],
        )
        .unwrap();
        fs::write(
            directory
                .path()
                .join(format!("SetupMode-{EFI_GLOBAL_VARIABLE_GUID}")),
            [7, 0, 0, 0, 0],
        )
        .unwrap();
        assert!(secure_boot_preflight(directory.path()).is_ok());
        fs::write(
            directory.path().join("SetupMode-wrong-guid"),
            [7, 0, 0, 0, 0],
        )
        .unwrap();
        fs::write(
            directory
                .path()
                .join(format!("SetupMode-{EFI_GLOBAL_VARIABLE_GUID}")),
            [7, 0, 0, 0, 1],
        )
        .unwrap();
        assert!(secure_boot_preflight(directory.path()).is_err());

        let wrong_guid = tempfile::tempdir().unwrap();
        fs::write(
            wrong_guid.path().join("SecureBoot-wrong-guid"),
            [7, 0, 0, 0, 1],
        )
        .unwrap();
        fs::write(
            wrong_guid.path().join("SetupMode-wrong-guid"),
            [7, 0, 0, 0, 0],
        )
        .unwrap();
        assert!(secure_boot_preflight(wrong_guid.path()).is_err());
    }

    #[test]
    fn pcrlock_policy_requires_populated_pcr_4_and_7() {
        let valid = serde_json::json!({
            "pcrValues": [
                {"pcr": 4, "values": ["boot-loader"]},
                {"pcr": 7, "values": ["secure-boot"]}
            ]
        });
        assert!(validate_pcrlock_policy(&valid).is_ok());

        let missing_boot_loader = serde_json::json!({
            "pcrValues": [{"pcr": 7, "values": ["secure-boot"]}]
        });
        assert!(validate_pcrlock_policy(&missing_boot_loader).is_err());

        let empty_secure_boot = serde_json::json!({
            "pcrValues": [
                {"pcr": 4, "values": ["boot-loader"]},
                {"pcr": 7, "values": []}
            ]
        });
        assert!(validate_pcrlock_policy(&empty_secure_boot).is_err());
    }

    #[test]
    fn enrollment_lock_serializes_device_updates() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("enroll.lock");
        let first = EnrollmentLock::acquire(&path).unwrap();
        assert!(EnrollmentLock::acquire(&path).is_err());
        drop(first);
        assert!(EnrollmentLock::acquire(&path).is_ok());
    }

    #[test]
    fn credential_socket_is_one_shot_and_runtime_directory_cleans_up() {
        let directory = tempfile::tempdir().unwrap();
        let socket = directory.path().join("credential.sock");
        let listener = bind_credential_socket(&socket).unwrap();
        let cancelled = Arc::new(AtomicBool::new(false));
        let server = spawn_credential_server(
            listener,
            Zeroizing::new(b"secret".to_vec()),
            Arc::clone(&cancelled),
        );
        let mut stream = UnixStream::connect(&socket).unwrap();
        let mut received = Vec::new();
        stream.read_to_end(&mut received).unwrap();
        server.join().unwrap().unwrap();
        assert_eq!(received, b"secret");
        assert!(UnixStream::connect(&socket).is_err());
        drop(directory);
        assert!(!socket.exists());
    }
}
