use crate::{
    report,
    target::{self, App},
};
use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand, builder::PossibleValuesParser};
use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::process::Stdio;

#[derive(Debug, Parser)]
#[command(name = "ignitix-bootmedia", about = "Operate Ignitix install media")]
pub struct Cli {
    #[command(subcommand)]
    pub operation: Operation,
}

#[derive(Debug, Args)]
pub struct Target {
    /// Consumer flake exposing installTargetsResolved and the target apps.
    #[arg(long, default_value = ".")]
    pub flake: String,
    /// Configured route, for example usb or lan.
    pub route: String,
    /// Target name in ignitix.installTargets.
    pub host: String,
}

#[derive(Debug, Subcommand)]
pub enum Operation {
    /// Run the consumer flake's install app.
    Install {
        #[command(flatten)]
        target: Target,
        #[arg(long, value_parser = PossibleValuesParser::new(["auto", "local", "remote", "split"]))]
        build_on: Option<String>,
        /// Arguments passed to nixos-anywhere.
        #[arg(last = true, value_name = "NIXOS_ANYWHERE_ARG")]
        args: Vec<OsString>,
    },
    /// Collect a disk-diagnose report from the target.
    Diagnose {
        #[command(flatten)]
        target: Target,
        /// Probe live media without mounting the installed system.
        #[arg(long)]
        no_mount: bool,
        #[arg(long)]
        json: bool,
    },
    /// Render a saved disk-diagnose report (use - for stdin).
    Report {
        file: PathBuf,
        #[arg(long)]
        json: bool,
    },
}

impl Cli {
    pub fn run(self) -> Result<i32> {
        match self.operation {
            Operation::Install {
                target,
                build_on,
                args,
            } => {
                let mut cmd = target.command(App::Install)?;
                if let Some(mode) = build_on {
                    cmd.args(["--build-on", &mode]);
                }
                if !args.is_empty() {
                    cmd.arg("--").args(args);
                }
                let status = cmd.status().context("running the consumer install app")?;
                Ok(status.code().unwrap_or(1))
            }
            Operation::Diagnose {
                target,
                no_mount,
                json,
            } => {
                let mut cmd = target.command(App::Diagnose)?;
                if no_mount {
                    cmd.arg("--no-mount");
                }
                let output = cmd
                    .stdin(Stdio::inherit())
                    .stderr(Stdio::inherit())
                    .output()
                    .context("running the consumer disk-diagnose app")?;
                // The collector can emit a valid failure report and exit nonzero.
                emit_report(&output.stdout, json).with_context(|| {
                    format!(
                        "reading disk-diagnose output from {}#disk-diagnose ({})",
                        target.flake, output.status
                    )
                })?;
                Ok(output.status.code().unwrap_or(1))
            }
            Operation::Report { file, json } => {
                let bytes = if file.as_os_str() == "-" {
                    let mut bytes = Vec::new();
                    io::stdin()
                        .lock()
                        .read_to_end(&mut bytes)
                        .context("reading stdin")?;
                    bytes
                } else {
                    std::fs::read(&file).with_context(|| format!("reading {}", file.display()))?
                };
                emit_report(&bytes, json)?;
                Ok(0)
            }
        }
    }
}

impl Target {
    fn command(&self, app: App) -> Result<std::process::Command> {
        target::app_command(&self.flake, app, &self.route, &self.host)
    }
}

fn emit_report(bytes: &[u8], json: bool) -> Result<()> {
    let report = report::parse(bytes)?;
    let mut out = io::stdout().lock();
    if json {
        serde_json::to_writer_pretty(&mut out, report.json())?;
        writeln!(out)?;
    } else {
        writeln!(out, "{}", report.human())?;
    }
    out.flush()?;
    Ok(())
}
