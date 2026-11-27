use super::analysis::root_cause_line;
use super::model::{DiagnosticReport, Probe};

pub fn render_human(report: &DiagnosticReport) -> String {
    let mut lines = Vec::new();
    lines.push(root_cause_line(report));
    lines.push(String::new());

    lines.push("Boot media".to_string());
    lines.extend(render_bootmedia(report));
    lines.push(String::new());

    lines.push("Installed".to_string());
    lines.extend(render_installed(report));
    lines.push(String::new());

    lines.push("Live".to_string());
    lines.extend(render_live(report));
    lines.push(String::new());

    lines.push("Disks".to_string());
    lines.extend(render_disks(report));

    lines.join("\n")
}

fn render_bootmedia(report: &DiagnosticReport) -> Vec<String> {
    match &report.bootmedia.kernel {
        Probe::Ok { data, .. } => vec![format!("  kernel release: {}", data.release)],
        Probe::Err { error, .. } => vec![format!("  kernel: error: {error}")],
    }
}

fn render_installed(report: &DiagnosticReport) -> Vec<String> {
    let mut lines = Vec::new();
    lines.push(match &report.installed.kernel {
        Probe::Ok { data, .. } => format!("  kernel release: {}", data.release),
        Probe::Err { error, .. } => format!("  kernel: error: {error}"),
    });
    lines.push(match &report.installed.bcache_module.path {
        Probe::Ok { data, .. } => format!("  bcache module path: {}", data.module_path),
        Probe::Err { error, .. } => format!("  bcache module path: error: {error}"),
    });
    lines.push(match &report.installed.bcache_module.modinfo {
        Probe::Ok { data, .. } => format!("  bcache modinfo vermagic: {}", data.vermagic),
        Probe::Err { error, .. } => format!("  bcache modinfo: error: {error}"),
    });
    lines.push(format!(
        "  /etc/modprobe.d entries: {}",
        report.installed.modprobe_d.len()
    ));
    lines.push(format!(
        "  bcache superblock probes: {}",
        report.installed.bcache_super.len()
    ));
    lines.push(match &report.installed.system_profile {
        Probe::Ok { data, .. } => format!("  system profile: {}", data.target),
        Probe::Err { error, .. } => format!("  system profile: error: {error}"),
    });
    lines
}

fn render_live(report: &DiagnosticReport) -> Vec<String> {
    let mut lines = Vec::new();
    lines.push(match &report.live.modprobe.bcache {
        Probe::Ok { data, .. } => {
            format!("  modprobe bcache: ok (exit_status={})", data.exit_status)
        }
        Probe::Err { error, .. } => format!("  modprobe bcache: error: {error}"),
    });
    lines.push(match &report.live.dmesg.bcache {
        Probe::Ok { data, .. } => format!("  dmesg lines: {}", data.lines.len()),
        Probe::Err { error, .. } => format!("  dmesg bcache: error: {error}"),
    });
    lines
}

fn render_disks(report: &DiagnosticReport) -> Vec<String> {
    let mut lines = Vec::new();
    lines.push(match &report.disks.lsblk {
        Probe::Ok { .. } => "  lsblk: ok".to_string(),
        Probe::Err { error, .. } => format!("  lsblk: error: {error}"),
    });
    lines.push(match &report.disks.by_partlabel {
        Probe::Ok { data, .. } => format!("  by-partlabel entries: {}", data.entries.len()),
        Probe::Err { error, .. } => format!("  by-partlabel: error: {error}"),
    });
    lines.push(format!("  gpt probes: {}", report.disks.gpt.len()));
    lines.push(format!("  blkid probes: {}", report.disks.blkid.len()));
    lines
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::report::model::{
        BcacheModuleModinfo, BootmediaKernel, LiveDmesgResult, LiveModprobeResult,
    };
    use serde_json::Value;

    fn clean_report() -> DiagnosticReport {
        serde_json::from_str(crate::tests::FIXTURE).expect("sample report parses")
    }

    fn first_line(rendered: &str) -> &str {
        rendered
            .lines()
            .next()
            .expect("rendered report has a first line")
    }

    #[test]
    fn root_cause_vermagic_mismatch_wins_first() {
        let mut report = clean_report();
        report.live.modprobe.bcache = Probe::Err {
            ok: false,
            error: "modprobe failed".to_string(),
        };
        report.bootmedia.kernel = Probe::Ok {
            ok: true,
            data: BootmediaKernel {
                release: "6.12.31".to_string(),
                vermagic: Some("6.12.31 SMP".to_string()),
            },
        };
        report.installed.bcache_module.modinfo = Probe::Ok {
            ok: true,
            data: BcacheModuleModinfo {
                file: "bcache.ko".to_string(),
                vermagic: "6.12.30 SMP".to_string(),
                depends: vec!["crc64".to_string()],
                srcversion: "ABC".to_string(),
                raw: Value::Object(Default::default()),
            },
        };
        assert!(
            first_line(&render_human(&report))
                .starts_with("ROOT CAUSE: BCACHE MODULE LOAD FAILED - vermagic mismatch:")
        );
    }

    #[test]
    fn root_cause_crypto_dependency_is_reported() {
        let mut report = clean_report();
        report.live.modprobe.bcache = Probe::Err {
            ok: false,
            error: "modprobe failed".to_string(),
        };
        report.bootmedia.kernel = Probe::Ok {
            ok: true,
            data: BootmediaKernel {
                release: "6.12.31".to_string(),
                vermagic: None,
            },
        };
        report.installed.bcache_module.modinfo = Probe::Ok {
            ok: true,
            data: BcacheModuleModinfo {
                file: "bcache.ko".to_string(),
                vermagic: "6.12.31 SMP".to_string(),
                depends: vec!["crc64".to_string()],
                srcversion: "ABC".to_string(),
                raw: Value::Object(Default::default()),
            },
        };
        report.live.dmesg.bcache = Probe::Ok {
            ok: true,
            data: LiveDmesgResult {
                lines: vec!["bcache: missing crc32c".to_string()],
            },
        };
        assert!(first_line(&render_human(&report)).starts_with(
            "ROOT CAUSE: BCACHE MODULE LOAD FAILED - crypto dependency missing or unavailable"
        ));
    }

    #[test]
    fn root_cause_missing_module_path_is_reported() {
        let mut report = clean_report();
        report.installed.bcache_module.path = Probe::Err {
            ok: false,
            error: "bcache module path missing".to_string(),
        };
        report.live.modprobe.bcache = Probe::Err {
            ok: false,
            error: "modprobe failed".to_string(),
        };
        report.bootmedia.kernel = Probe::Ok {
            ok: true,
            data: BootmediaKernel {
                release: "6.12.31".to_string(),
                vermagic: Some("6.12.31 SMP".to_string()),
            },
        };
        report.installed.bcache_module.modinfo = Probe::Ok {
            ok: true,
            data: BcacheModuleModinfo {
                file: "bcache.ko".to_string(),
                vermagic: "6.12.31 SMP".to_string(),
                depends: vec!["crc64".to_string()],
                srcversion: "ABC".to_string(),
                raw: Value::Object(Default::default()),
            },
        };
        report.live.dmesg.bcache = Probe::Ok {
            ok: true,
            data: LiveDmesgResult {
                lines: vec!["kernel: bcache".to_string()],
            },
        };
        assert!(first_line(&render_human(&report)).starts_with(
            "ROOT CAUSE: BCACHE MODULE NOT PRESENT - installed kernel tree has no bcache module"
        ));
    }

    #[test]
    fn unmounted_installed_system_is_not_reported_as_missing_module() {
        let mut report = clean_report();
        report.installed.kernel = Probe::Err {
            ok: false,
            error: "installed system not mounted at /mnt".to_string(),
        };
        report.installed.bcache_module.path = Probe::Err {
            ok: false,
            error: "installed system not mounted at /mnt".to_string(),
        };
        report.installed.bcache_module.modinfo = Probe::Err {
            ok: false,
            error: "installed system not mounted at /mnt".to_string(),
        };
        report.installed.system_profile = Probe::Err {
            ok: false,
            error: "installed system not mounted at /mnt".to_string(),
        };
        assert_eq!(
            first_line(&render_human(&report)),
            "ROOT CAUSE: indeterminate - see sections below"
        );
    }

    #[test]
    fn root_cause_missing_partition_labels_is_reported() {
        let mut report = clean_report();
        report.live.modprobe.bcache = Probe::Ok {
            ok: true,
            data: LiveModprobeResult {
                exit_status: 0,
                stderr: String::new(),
                stdout: String::new(),
            },
        };
        report.disks.by_partlabel = Probe::Err {
            ok: false,
            error: "cannot read /dev/disk/by-partlabel".to_string(),
        };
        report.disks.gpt = vec![
            Probe::Err {
                ok: false,
                error: "sgdisk -p failed".to_string(),
            },
            Probe::Err {
                ok: false,
                error: "sgdisk -p failed".to_string(),
            },
        ];
        report.disks.blkid = vec![
            Probe::Err {
                ok: false,
                error: "blkid failed".to_string(),
            },
            Probe::Err {
                ok: false,
                error: "blkid failed".to_string(),
            },
        ];
        assert!(first_line(&render_human(&report)).starts_with(
            "ROOT CAUSE: PARTITION LABELS MISSING - install never partitioned or storage is not visible"
        ));
    }
}
