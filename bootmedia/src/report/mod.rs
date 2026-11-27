mod analysis;
pub mod model;
mod render;

pub use model::{DiagnosticReport, SCHEMA_VERSION};
pub use render::render_human;

use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use serde_json::Value;

#[derive(Debug)]
pub struct Report {
    model: DiagnosticReport,
    json: Value,
}

impl Report {
    pub fn model(&self) -> &DiagnosticReport {
        &self.model
    }

    pub fn human(&self) -> String {
        render_human(&self.model)
    }

    /// Keep collector fields not needed by the human renderer, such as probe_log.
    pub fn json(&self) -> &Value {
        &self.json
    }
}

pub fn parse(bytes: &[u8]) -> Result<Report> {
    let json: Value = serde_json::from_slice(bytes).context("invalid disk-diagnose JSON")?;
    let version = json["schema_version"]
        .as_str()
        .context("missing or non-string disk-diagnose schema_version")?;
    ensure!(
        version == SCHEMA_VERSION,
        "unsupported disk-diagnose schema version {version:?}; expected {SCHEMA_VERSION:?}"
    );
    let model = DiagnosticReport::deserialize(&json).context("invalid disk-diagnose v1 report")?;
    Ok(Report { model, json })
}
