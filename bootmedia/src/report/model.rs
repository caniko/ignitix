use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const SCHEMA_VERSION: &str = "1";

#[derive(Debug, Deserialize, Serialize)]
pub struct DiagnosticReport {
    pub schema_version: String,
    pub generated_at: String,
    pub tool: ToolInfo,
    pub target: TargetInfo,
    pub context: ContextInfo,
    pub bootmedia: BootmediaInfo,
    pub installed: InstalledInfo,
    pub live: LiveInfo,
    pub disks: DisksInfo,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct ToolInfo {
    pub name: String,
    pub version: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct TargetInfo {
    pub host: String,
    pub route: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct ContextInfo {
    pub mode: String,
    pub mounted_system_root: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct BootmediaInfo {
    pub kernel: Probe<BootmediaKernel>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct BootmediaKernel {
    pub release: String,
    #[serde(default)]
    pub vermagic: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct InstalledInfo {
    pub kernel: Probe<InstalledKernel>,
    #[serde(rename = "bcache_module")]
    pub bcache_module: InstalledBcacheModule,
    #[serde(default, rename = "modprobe_d")]
    pub modprobe_d: Vec<Probe<ModprobeDEntry>>,
    #[serde(default, rename = "bcache_super")]
    pub bcache_super: Vec<Probe<BcacheSuperEntry>>,
    #[serde(rename = "system_profile")]
    pub system_profile: Probe<SystemProfile>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct InstalledKernel {
    pub kernel_path: String,
    pub release: String,
    pub modules_builtin_first_line: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct InstalledBcacheModule {
    pub path: Probe<BcacheModulePath>,
    pub modinfo: Probe<BcacheModuleModinfo>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct BcacheModulePath {
    pub module_dir: String,
    pub module_path: String,
    pub exists: bool,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct BcacheModuleModinfo {
    pub file: String,
    pub vermagic: String,
    #[serde(default)]
    pub depends: Vec<String>,
    #[serde(default)]
    pub srcversion: String,
    pub raw: Value,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct ModprobeDEntry {
    pub path: String,
    #[serde(default)]
    pub contents: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct BcacheSuperEntry {
    pub device: String,
    pub resolved_device: String,
    pub role: String,
    #[serde(default)]
    pub raw: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct SystemProfile {
    pub link: String,
    pub target: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct LiveInfo {
    pub modprobe: LiveModprobe,
    pub dmesg: LiveDmesg,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct LiveModprobe {
    pub bcache: Probe<LiveModprobeResult>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct LiveModprobeResult {
    pub exit_status: i32,
    #[serde(default)]
    pub stderr: String,
    #[serde(default)]
    pub stdout: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct LiveDmesg {
    pub bcache: Probe<LiveDmesgResult>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct LiveDmesgResult {
    #[serde(default)]
    pub lines: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct DisksInfo {
    pub lsblk: Probe<LsblkResult>,
    pub by_partlabel: Probe<ByPartLabelResult>,
    #[serde(default)]
    pub gpt: Vec<Probe<GptResult>>,
    #[serde(default)]
    pub blkid: Vec<Probe<BlkidResult>>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct LsblkResult {
    pub devices: Value,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct ByPartLabelResult {
    #[serde(default)]
    pub entries: Vec<PartLabelEntry>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct PartLabelEntry {
    pub name: String,
    pub path: String,
    pub target: String,
    pub resolved_device: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct GptResult {
    pub device: String,
    pub header: GptHeader,
    #[serde(default)]
    pub partitions: Vec<GptPartition>,
    #[serde(default)]
    pub raw: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct GptHeader {
    #[serde(default)]
    pub disk_identifier: String,
    #[serde(default)]
    pub holds: String,
    #[serde(default)]
    pub main_table_sectors: String,
    #[serde(default)]
    pub first_usable_sector: String,
    #[serde(default)]
    pub last_usable_sector: String,
    #[serde(default)]
    pub partitions_free_space: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct GptPartition {
    pub number: i32,
    #[serde(default)]
    pub start: String,
    #[serde(default)]
    pub end: String,
    #[serde(default)]
    pub size: String,
    #[serde(default)]
    pub code: String,
    #[serde(default)]
    pub name: String,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct BlkidResult {
    pub device: String,
    #[serde(default)]
    pub properties: Value,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(untagged)]
pub enum Probe<T> {
    Ok {
        ok: bool,
        #[serde(flatten)]
        data: T,
    },
    Err {
        ok: bool,
        error: String,
    },
}

impl<T> Probe<T> {
    pub fn is_ok(&self) -> bool {
        matches!(self, Self::Ok { ok: true, .. })
    }

    pub fn is_err(&self) -> bool {
        !self.is_ok()
    }

    pub fn ok(&self) -> Option<&T> {
        match self {
            Self::Ok { ok: true, data } => Some(data),
            _ => None,
        }
    }

    pub fn error(&self) -> Option<&str> {
        match self {
            Self::Err { error, .. } => Some(error.as_str()),
            _ => None,
        }
    }
}
