use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderKind {
    Local,
    Cloud,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalConfig {
    #[serde(default = "default_ollama_host")]
    pub host: String,
    #[serde(default = "default_ollama_model")]
    pub model: String,
}

impl Default for LocalConfig {
    fn default() -> Self {
        Self {
            host: default_ollama_host(),
            model: default_ollama_model(),
        }
    }
}

fn default_ollama_host() -> String {
    "http://localhost:11434".to_string()
}

fn default_ollama_model() -> String {
    "qwen2.5-coder".to_string()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CloudVendor {
    Anthropic,
    Openai,
    Gemini,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CloudConfig {
    #[serde(default = "default_cloud_vendor")]
    pub vendor: CloudVendor,
    /// Left empty in the config file on purpose; resolved from an env var at
    /// load time (ANTHROPIC_API_KEY / OPENAI_API_KEY / GEMINI_API_KEY) so the
    /// key never has to live on disk.
    #[serde(default)]
    pub api_key: Option<String>,
    #[serde(default = "default_cloud_model")]
    pub model: String,
}

impl Default for CloudConfig {
    fn default() -> Self {
        Self {
            vendor: default_cloud_vendor(),
            api_key: None,
            model: default_cloud_model(),
        }
    }
}

fn default_cloud_vendor() -> CloudVendor {
    CloudVendor::Anthropic
}

fn default_cloud_model() -> String {
    "claude-sonnet-5".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    #[serde(default = "default_provider")]
    pub provider: ProviderKind,
    #[serde(default)]
    pub fallback_to_local_on_cloud_error: bool,
    #[serde(default = "default_max_suggestions")]
    pub max_suggestions: usize,
    #[serde(default = "default_debounce_ms")]
    pub debounce_ms: u64,
    #[serde(default)]
    pub socket_path: Option<PathBuf>,
    #[serde(default)]
    pub local: LocalConfig,
    #[serde(default)]
    pub cloud: CloudConfig,
}

fn default_provider() -> ProviderKind {
    ProviderKind::Local
}

fn default_max_suggestions() -> usize {
    5
}

fn default_debounce_ms() -> u64 {
    250
}

impl Default for Config {
    fn default() -> Self {
        Self {
            provider: default_provider(),
            fallback_to_local_on_cloud_error: true,
            max_suggestions: default_max_suggestions(),
            debounce_ms: default_debounce_ms(),
            socket_path: None,
            local: LocalConfig::default(),
            cloud: CloudConfig::default(),
        }
    }
}

impl Config {
    pub fn config_path() -> Result<PathBuf> {
        let base = dirs::home_dir().context("could not determine home directory")?;
        Ok(base.join(".config").join("ai-suggest").join("config.toml"))
    }

    /// Loads the config from disk, writing out a commented default file the
    /// first time it's missing so the user has something to edit.
    pub fn load_or_init() -> Result<Self> {
        let path = Self::config_path()?;
        let mut cfg = if path.exists() {
            let raw = std::fs::read_to_string(&path)
                .with_context(|| format!("reading {}", path.display()))?;
            toml::from_str(&raw).with_context(|| format!("parsing {}", path.display()))?
        } else {
            let cfg = Config::default();
            cfg.write_default(&path)?;
            cfg
        };
        cfg.resolve_api_key_from_env();
        Ok(cfg)
    }

    fn write_default(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let toml_str = toml::to_string_pretty(self)?;
        let commented = format!(
            "# ai-suggest config\n\
             # provider = \"local\" uses Ollama (see [local]); provider = \"cloud\" uses [cloud].\n\
             # Cloud API keys are NOT stored here: set ANTHROPIC_API_KEY / OPENAI_API_KEY /\n\
             # GEMINI_API_KEY in your shell environment instead.\n\n{toml_str}"
        );
        std::fs::write(path, commented)?;
        Ok(())
    }

    fn resolve_api_key_from_env(&mut self) {
        if self.cloud.api_key.is_some() {
            return;
        }
        let var = match self.cloud.vendor {
            CloudVendor::Anthropic => "ANTHROPIC_API_KEY",
            CloudVendor::Openai => "OPENAI_API_KEY",
            CloudVendor::Gemini => "GEMINI_API_KEY",
        };
        self.cloud.api_key = std::env::var(var).ok();
    }

    pub fn socket_path(&self) -> Result<PathBuf> {
        if let Some(p) = &self.socket_path {
            return Ok(p.clone());
        }
        let base = dirs::home_dir().context("could not determine home directory")?;
        Ok(base
            .join(".cache")
            .join("ai-suggest")
            .join("daemon.sock"))
    }
}
