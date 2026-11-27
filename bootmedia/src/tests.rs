use super::{
    cli::{Cli, Operation},
    report,
};
use clap::Parser;

pub(crate) const FIXTURE: &str = include_str!("../tests/disk-diagnose-v1.json");

#[test]
fn renders_v1_fixture() {
    let parsed = report::parse(FIXTURE.as_bytes()).unwrap();
    assert_eq!(parsed.model().tool.name, "disk-diagnose");
    assert_eq!(
        parsed.human().lines().next().unwrap(),
        "ROOT CAUSE: nothing obviously wrong - all probes succeeded"
    );
    assert_eq!(
        parsed.json(),
        &serde_json::from_str::<serde_json::Value>(FIXTURE).unwrap()
    );
}

#[test]
fn renders_collector_failures_by_discriminator() {
    let mut json: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
    json["live"]["modprobe"]["bcache"] = serde_json::json!({
        "ok": false, "exit_status": 1, "stdout": "", "stderr": "", "error": "modprobe failed"
    });
    json["live"]["dmesg"]["bcache"] = serde_json::json!({"ok": false, "error": "dmesg failed"});
    json["disks"]["by_partlabel"] = serde_json::json!({"ok": false, "error": "labels unavailable"});
    let report = report::parse(json.to_string().as_bytes()).unwrap();
    let rendered = report.human();
    for expected in [
        "modprobe bcache: error: modprobe failed",
        "dmesg bcache: error: dmesg failed",
        "by-partlabel: error: labels unavailable",
    ] {
        assert!(rendered.contains(expected), "{rendered}");
    }
}

#[test]
fn rejects_bad_reports() {
    assert!(report::parse(b"{").is_err());
    assert!(report::parse(b"{\"schema_version\":\"1\"}").is_err());
    let wrong = FIXTURE.replace("\"schema_version\": \"1\"", "\"schema_version\": \"2\"");
    assert!(
        report::parse(wrong.as_bytes())
            .unwrap_err()
            .to_string()
            .contains("unsupported disk-diagnose schema version")
    );
}

#[test]
fn parses_install_with_passthrough() {
    let cli = Cli::try_parse_from([
        "bootmedia",
        "install",
        "--flake",
        "path:/consumer",
        "usb",
        "example",
        "--build-on",
        "split",
        "--",
        "--phases",
        "kexec,disko,install",
    ])
    .unwrap();
    let Operation::Install {
        target,
        build_on,
        args,
    } = cli.operation
    else {
        panic!("expected install");
    };
    assert_eq!(target.flake, "path:/consumer");
    assert_eq!(target.route, "usb");
    assert_eq!(target.host, "example");
    assert_eq!(build_on.as_deref(), Some("split"));
    assert_eq!(args, ["--phases", "kexec,disko,install"]);
}

#[test]
fn parses_diagnose_and_offline_report() {
    let cli = Cli::try_parse_from([
        "bootmedia",
        "diagnose",
        "lan",
        "example",
        "--json",
        "--no-mount",
    ])
    .unwrap();
    let Operation::Diagnose {
        target,
        json,
        no_mount,
    } = cli.operation
    else {
        panic!("expected diagnose");
    };
    assert_eq!(target.flake, ".");
    assert!(json && no_mount);
    for input in ["-", "report.json"] {
        let cli = Cli::try_parse_from(["bootmedia", "report", input, "--json"]).unwrap();
        let Operation::Report { file, json } = cli.operation else {
            panic!("expected report");
        };
        assert_eq!(file.to_str(), Some(input));
        assert!(json);
    }
    assert!(Cli::try_parse_from(["bootmedia", "install", "usb"]).is_err());
    assert!(Cli::try_parse_from(["bootmedia", "report"]).is_err());
}
