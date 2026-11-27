use super::model::{DiagnosticReport, Probe};

pub(super) fn root_cause_line(report: &DiagnosticReport) -> String {
    if all_probes_succeeded(report) {
        return "ROOT CAUSE: nothing obviously wrong - all probes succeeded".to_string();
    }

    if let Some((installed, running)) = vermagic_mismatch(report) {
        return format!(
            "ROOT CAUSE: BCACHE MODULE LOAD FAILED - vermagic mismatch: installed={installed}, running={running}"
        );
    }

    if report.live.modprobe.bcache.is_err() && dmesg_mentions_crypto(report) {
        return "ROOT CAUSE: BCACHE MODULE LOAD FAILED - crypto dependency missing or unavailable"
            .to_string();
    }

    if installed_bcache_module_missing(report) {
        return "ROOT CAUSE: BCACHE MODULE NOT PRESENT - installed kernel tree has no bcache module"
            .to_string();
    }

    if partlabel_probes_all_failed(report) {
        return "ROOT CAUSE: PARTITION LABELS MISSING - install never partitioned or storage is not visible"
            .to_string();
    }

    "ROOT CAUSE: indeterminate - see sections below".to_string()
}

fn all_probes_succeeded(report: &DiagnosticReport) -> bool {
    report.bootmedia.kernel.is_ok()
        && report.installed.kernel.is_ok()
        && report.installed.bcache_module.path.is_ok()
        && report.installed.bcache_module.modinfo.is_ok()
        && report.live.modprobe.bcache.is_ok()
        && report.live.dmesg.bcache.is_ok()
        && report.disks.lsblk.is_ok()
        && report.disks.by_partlabel.is_ok()
        && report.disks.gpt.iter().all(Probe::is_ok)
        && report.disks.blkid.iter().all(Probe::is_ok)
        && report.installed.modprobe_d.iter().all(Probe::is_ok)
        && report.installed.bcache_super.iter().all(Probe::is_ok)
        && report.installed.system_profile.is_ok()
}

fn vermagic_mismatch(report: &DiagnosticReport) -> Option<(&str, &str)> {
    if !report.live.modprobe.bcache.is_err() {
        return None;
    }

    let installed = report.installed.bcache_module.modinfo.ok()?;
    let bootmedia = report.bootmedia.kernel.ok()?;
    let (installed_magic, running) = match bootmedia.vermagic.as_deref() {
        Some(running) => (installed.vermagic.as_str(), running),
        None => (
            installed.vermagic.split_whitespace().next()?,
            bootmedia.release.as_str(),
        ),
    };
    (installed_magic != running).then_some((installed_magic, running))
}

fn dmesg_mentions_crypto(report: &DiagnosticReport) -> bool {
    let Some(dmesg) = report.live.dmesg.bcache.ok() else {
        return false;
    };
    dmesg.lines.iter().any(|line| {
        let lower = line.to_ascii_lowercase();
        lower.contains("crc32c") || lower.contains("crypto")
    })
}

fn installed_bcache_module_missing(report: &DiagnosticReport) -> bool {
    match report.installed.bcache_module.path.error() {
        Some(error) => {
            let lower = error.to_ascii_lowercase();
            !lower.contains("not mounted") && !lower.contains("mounted system")
        }
        None => false,
    }
}

fn partlabel_probes_all_failed(report: &DiagnosticReport) -> bool {
    let by_partlabel_failed = match report.disks.by_partlabel.ok() {
        Some(entries) => entries.entries.is_empty(),
        None => true,
    };

    by_partlabel_failed
        && report.disks.gpt.iter().all(|probe| !probe.is_ok())
        && report.disks.blkid.iter().all(|probe| !probe.is_ok())
}
