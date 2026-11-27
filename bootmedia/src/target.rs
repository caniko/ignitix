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
    let name = match app {
        App::Install => "install",
        App::Diagnose => "disk-diagnose",
    };
    let mut command = Command::new("nix");
    command.args(["run", &format!("{flake}#{name}"), "--", route, host]);
    Ok(command)
}

fn validate_flake(flake: &str) -> Result<()> {
    ensure!(
        !flake.is_empty() && !flake.starts_with('-') && !flake.contains('#'),
        "--flake must be a flake reference without an output fragment"
    );
    Ok(())
}
