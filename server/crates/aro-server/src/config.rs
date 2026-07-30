use anyhow::{Context, Result, bail};
use ipnet::IpNet;
use serde::{Deserialize, Serialize};
use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::{Path, PathBuf},
};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, clap::ValueEnum, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum StorageMode {
    #[default]
    Managed,
    Referenced,
}

impl StorageMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Managed => "managed",
            Self::Referenced => "referenced",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub hub_id: Uuid,
    pub display_name: String,
    pub bind: SocketAddr,
    pub data_dir: PathBuf,
    pub tls_cert: PathBuf,
    pub tls_key: PathBuf,
    pub control_socket: PathBuf,
    pub admin_token: String,
    /// Networks permitted to reach admin-only endpoints (folder management,
    /// pairing approval, device revocation), independent of `bind`. Defaults
    /// to loopback-only; widen it (e.g. to a LAN subnet, or `0.0.0.0/0` for
    /// any network) if the admin API needs to be reachable from other
    /// devices. Requests are still required to present `admin_token`.
    #[serde(default = "default_admin_allow")]
    pub admin_allow: Vec<IpNet>,
    pub advertise_mdns: bool,
    pub storage_mode: StorageMode,
    pub source_rescan_seconds: u64,
    pub dashboard: DashboardConfig,
    /// Personal AcoustID API key used for background track identification. Empty
    /// disables identification entirely (its background queue is never started) —
    /// this is the expected state until a user enters a key in Settings.
    #[serde(default)]
    pub acoustid_api_key: String,
    /// Sent as the `User-Agent` header on every MusicBrainz webservice request.
    /// MusicBrainz actively throttles generic/missing User-Agents, so this should
    /// identify the app and include real contact information.
    #[serde(default = "default_musicbrainz_user_agent")]
    pub musicbrainz_user_agent: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct DashboardConfig {
    pub enabled: bool,
    pub bind: SocketAddr,
}

impl Default for DashboardConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 4849),
        }
    }
}

fn default_musicbrainz_user_agent() -> String {
    "Aro/0.1 ( https://github.com/imjacobclark/aro )".into()
}

fn default_admin_allow() -> Vec<IpNet> {
    vec![
        IpNet::V4("127.0.0.0/8".parse().expect("valid CIDR literal")),
        IpNet::V6("::1/128".parse().expect("valid CIDR literal")),
    ]
}

impl Default for Config {
    fn default() -> Self {
        let data_dir = default_data_dir();
        Self {
            hub_id: Uuid::new_v4(),
            display_name: "Aro".into(),
            bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 4848),
            tls_cert: data_dir.join("tls/cert.pem"),
            tls_key: data_dir.join("tls/key.pem"),
            control_socket: data_dir.join("control.sock"),
            data_dir,
            admin_token: Uuid::new_v4().simple().to_string(),
            admin_allow: default_admin_allow(),
            advertise_mdns: true,
            storage_mode: StorageMode::Managed,
            source_rescan_seconds: 300,
            dashboard: DashboardConfig::default(),
            acoustid_api_key: String::new(),
            musicbrainz_user_agent: default_musicbrainz_user_agent(),
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.is_file() {
            bail!(
                "configuration not found at {}; run `aro-server init` first",
                path.display()
            );
        }
        let mut config: Self = toml::from_str(&std::fs::read_to_string(path)?)
            .with_context(|| format!("invalid config {}", path.display()))?;
        if let Ok(value) = std::env::var("ARO_BIND") {
            config.bind = value.parse().context("invalid ARO_BIND")?;
        }
        if let Ok(value) = std::env::var("ARO_DATA_DIR") {
            config.data_dir = value.into();
        }
        if let Ok(value) = std::env::var("ARO_ADMIN_TOKEN") {
            config.admin_token = value;
        }
        if let Ok(value) = std::env::var("ARO_STORAGE_MODE") {
            config.storage_mode = match value.to_ascii_lowercase().as_str() {
                "managed" => StorageMode::Managed,
                "referenced" => StorageMode::Referenced,
                _ => bail!("ARO_STORAGE_MODE must be managed or referenced"),
            };
        }
        if let Ok(value) = std::env::var("ACOUSTID_API_KEY") {
            config.acoustid_api_key = value;
        }
        if let Ok(value) = std::env::var("ARO_ADMIN_ALLOW") {
            config.admin_allow = value
                .split(',')
                .map(|entry| entry.trim().parse())
                .collect::<Result<_, _>>()
                .context("invalid ARO_ADMIN_ALLOW; expected comma-separated CIDR networks")?;
        }
        config.validate()?;
        Ok(config)
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, toml::to_string_pretty(self)?)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
        Ok(())
    }

    fn validate(&self) -> Result<()> {
        if self.admin_token.len() < 16 {
            bail!("admin_token must contain at least 16 characters");
        }
        if self.admin_allow.is_empty() {
            bail!("admin_allow must contain at least one network; use 127.0.0.0/8 to restrict to this machine");
        }
        if self.source_rescan_seconds < 10 {
            bail!("source_rescan_seconds must be at least 10");
        }
        if self.dashboard.enabled {
            validate_lan_bind(self.dashboard.bind, "dashboard.bind")?;
            if self.dashboard.bind.port() == self.bind.port() {
                bail!("dashboard.bind must use a different port from the sync listener");
            }
        }
        validate_lan_bind(self.bind, "bind")?;
        Ok(())
    }
}

fn validate_lan_bind(bind: SocketAddr, field: &str) -> Result<()> {
    let allowed = match bind.ip() {
        IpAddr::V4(ip) => ip.is_unspecified() || ip.is_private() || ip.is_loopback(),
        IpAddr::V6(ip) => ip.is_unspecified() || ip.is_loopback() || ip.is_unique_local(),
    };
    if !allowed {
        bail!("{field} must be a private, loopback, or unspecified LAN address");
    }
    Ok(())
}

pub fn default_config_path() -> PathBuf {
    default_data_dir().join("aro.toml")
}

fn default_data_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("ARO_DATA_DIR") {
        return PathBuf::from(path);
    }
    #[cfg(target_os = "macos")]
    if let Some(home) = macos_home_dir() {
        return home.join("Library/Application Support/Aro/Server");
    }
    #[cfg(target_os = "windows")]
    if let Some(app_data) = std::env::var_os("PROGRAMDATA") {
        return PathBuf::from(app_data).join("Aro/Server");
    }
    if let Some(data_home) = std::env::var_os("XDG_DATA_HOME") {
        return PathBuf::from(data_home).join("aro/server");
    }
    PathBuf::from("/var/lib/aro")
}

#[cfg(target_os = "macos")]
fn macos_home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from).or_else(|| {
        // SMAppService launch agents do not necessarily receive HOME.
        // Resolve the current user's home from the account database so the
        // bundled helper finds the same config written by the app.
        let entry = unsafe { libc::getpwuid(libc::getuid()) };
        if entry.is_null() {
            return None;
        }
        let directory = unsafe { std::ffi::CStr::from_ptr((*entry).pw_dir) };
        Some(PathBuf::from(directory.to_string_lossy().into_owned()))
    })
}

#[cfg(test)]
mod admin_allow_tests {
    use super::*;

    #[test]
    fn defaults_to_loopback_only() {
        let config = Config::default();
        assert!(config.admin_allow.contains(
            &"127.0.0.0/8".parse::<IpNet>().unwrap()
        ));
        assert!(config.admin_allow.contains(
            &"::1/128".parse::<IpNet>().unwrap()
        ));
        assert!(config.validate().is_ok());
    }

    #[test]
    fn rejects_empty_admin_allow() {
        let mut config = Config::default();
        config.admin_allow.clear();
        assert!(config.validate().is_err());
    }

    #[test]
    fn accepts_a_widened_lan_subnet() {
        let mut config = Config::default();
        config.admin_allow = vec!["192.168.1.0/24".parse().unwrap()];
        assert!(config.validate().is_ok());
    }

    #[test]
    fn dashboard_is_disabled_on_a_separate_port_by_default() {
        let config = Config::default();
        assert!(!config.dashboard.enabled);
        assert_eq!(config.dashboard.bind.port(), 4849);
    }

    #[test]
    fn enabled_dashboard_rejects_public_addresses_and_sync_port() {
        let mut config = Config::default();
        config.dashboard.enabled = true;
        config.dashboard.bind = "8.8.8.8:4849".parse().unwrap();
        assert!(config.validate().is_err());
        config.dashboard.bind = "127.0.0.1:4848".parse().unwrap();
        assert!(config.validate().is_err());
        config.dashboard.bind = "127.0.0.1:4849".parse().unwrap();
        assert!(config.validate().is_ok());
    }
}
