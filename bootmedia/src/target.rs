//! Resolve install targets and dispatch their consumer-flake apps.

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::process::Command;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallTarget {
    pub flake_uri: String,
    pub target_port: u16,
    pub media: String,
    #[serde(default)]
    pub ssh_options: Vec<String>,
    pub routes: BTreeMap<String, InstallRoute>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallRoute {
    pub target_host: String,
}

pub fn resolve(flake: &str, host: &str) -> Result<InstallTarget> {
    validate_flake(flake)?;
    // Select one exact attribute, even for names containing dots or quotes.
    let name = serde_json::to_string(host)?;
    let nix_string = serde_json::to_string(&name)?.replace("${", "\\${");
    let select = format!("targets: builtins.getAttr (builtins.fromJSON {nix_string}) targets");
    let output = Command::new("nix")
        .args([
            "eval",
            "--json",
            "--apply",
            &select,
            &format!("{flake}#installTargetsResolved"),
        ])
        .output()
        .context("starting nix eval")?;
    ensure!(
        output.status.success(),
        "resolving {flake}#installTargetsResolved for {host:?} failed ({}): {}",
        output.status,
        String::from_utf8_lossy(&output.stderr).trim()
    );
    serde_json::from_slice(&output.stdout)
        .with_context(|| format!("parsing installTargetsResolved for {host:?}"))
}

#[derive(Clone, Copy)]
pub enum App {
    Install,
    Diagnose,
}

pub fn app_command(flake: &str, app: App, route: &str, host: &str) -> Result<Command> {
    let target = resolve(flake, host)?;
    ensure!(
        target.routes.contains_key(route),
        "unknown route {route:?} for {host:?}; available routes: {}",
        target.routes.keys().cloned().collect::<Vec<_>>().join(", ")
    );
    wrapper_command(flake, app, route, host, &target.flake_uri)
}

fn wrapper_command(
    flake: &str,
    app: App,
    route: &str,
    host: &str,
    target_flake: &str,
) -> Result<Command> {
    let name = match app {
        App::Install => "install",
        App::Diagnose => "disk-diagnose",
    };
    let attr = target_flake
        .strip_prefix(".#")
        .filter(|attr| !attr.is_empty())
        .with_context(|| format!("expected a relative target flake URI, got {target_flake:?}"))?;
    let mut command = Command::new("nix");
    command.args([
        "run",
        &format!("{flake}#{name}"),
        "--",
        route,
        host,
        "--flake",
        &format!("{flake}#{attr}"),
    ]);
    if matches!(app, App::Install) {
        let local = flake
            .strip_prefix("path:")
            .map(|path| path.split('?').next().unwrap_or(path))
            .or_else(|| {
                (matches!(flake, "." | "..")
                    || ["/", "./", "../"]
                        .iter()
                        .any(|prefix| flake.starts_with(prefix)))
                .then_some(flake)
            });
        if let Some(root) = local {
            command.env("IGNITIX_HARDWARE_REPORT_ROOT", root);
        }
    }
    Ok(command)
}

fn validate_flake(flake: &str) -> Result<()> {
    ensure!(
        !flake.is_empty() && !flake.starts_with('-') && !flake.contains('#'),
        "--flake must be a flake reference without an output fragment"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrappers_use_the_consumer_configuration_without_changing_directory() {
        for (app, output) in [(App::Install, "install"), (App::Diagnose, "disk-diagnose")] {
            let cmd = wrapper_command("path:/consumer", app, "lan", "host", ".#custom").unwrap();
            assert_eq!(
                cmd.get_args().collect::<Vec<_>>(),
                [
                    "run",
                    &format!("path:/consumer#{output}"),
                    "--",
                    "lan",
                    "host",
                    "--flake",
                    "path:/consumer#custom"
                ]
            );
            assert!(cmd.get_current_dir().is_none());
            assert_eq!(
                cmd.get_envs()
                    .find(|(name, _)| *name == "IGNITIX_HARDWARE_REPORT_ROOT")
                    .and_then(|(_, value)| value)
                    .and_then(|value| value.to_str()),
                matches!(app, App::Install).then_some("/consumer")
            );
        }
    }
}
