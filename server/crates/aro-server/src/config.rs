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
    pub dlna: DlnaConfig,
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

/// Optional DLNA media server. DLNA renderers speak plain HTTP with no
/// authentication, so enabling this exposes the whole library to any device on
/// the LAN — it is off by default and its bind is held to the same
/// private/loopback constraint as every other listener.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct DlnaConfig {
    pub enabled: bool,
    pub bind: SocketAddr,
    /// Name renderers display for this server; empty falls back to `display_name`.
    pub friendly_name: String,
}

impl Default for DlnaConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 4850),
            friendly_name: String::new(),
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
            dlna: DlnaConfig::default(),
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
            if store_exists(&config.data_dir) {
                bail!(
                    "storage_mode is fixed at initialization and cannot be changed via \
                     ARO_STORAGE_MODE once a store exists at {}; initialize a fresh data_dir \
                     to switch modes",
                    config.data_dir.display()
                );
            }
            config.storage_mode = match value.to_ascii_lowercase().as_str() {
                "managed" => StorageMode::Managed,
                "referenced" => StorageMode::Referenced,
                _ => bail!("ARO_STORAGE_MODE must be managed or referenced"),
            };
        }
        if let Ok(value) = std::env::var("ACOUSTID_API_KEY") {
            config.acoustid_api_key = value;
        }
        if let Ok(value) = std::env::var("ARO_DLNA_BIND") {
            config.dlna.bind = value.parse().context("invalid ARO_DLNA_BIND")?;
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

    /// Changes a single field by name, for the CLI's `config set` and the
    /// control socket's `SetConfig`, so neither platform hand-writes TOML.
    /// `storage_mode` is deliberately not settable here: it is fixed at
    /// initialization (see `Config::load`'s `ARO_STORAGE_MODE` handling) —
    /// switching modes means initializing a fresh `data_dir`.
    pub fn set_field(&mut self, key: &str, value: &str) -> Result<()> {
        match key {
            "storage_mode" => bail!(
                "storage_mode is fixed at initialization and cannot be changed; \
                 initialize a fresh data_dir to switch modes"
            ),
            "display_name" => self.display_name = value.to_string(),
            "bind" => self.bind = value.parse().context("invalid bind address")?,
            "advertise_mdns" => {
                self.advertise_mdns = value
                    .parse()
                    .context("advertise_mdns must be true or false")?;
            }
            "source_rescan_seconds" => {
                self.source_rescan_seconds = value
                    .parse()
                    .context("source_rescan_seconds must be a positive integer")?;
            }
            "dashboard.enabled" => {
                self.dashboard.enabled = value
                    .parse()
                    .context("dashboard.enabled must be true or false")?;
            }
            "dashboard.bind" => {
                self.dashboard.bind = value.parse().context("invalid dashboard.bind address")?;
            }
            "dlna.enabled" => {
                self.dlna.enabled = value
                    .parse()
                    .context("dlna.enabled must be true or false")?;
            }
            "dlna.bind" => {
                self.dlna.bind = value.parse().context("invalid dlna.bind address")?;
            }
            "dlna.friendly_name" => self.dlna.friendly_name = value.to_string(),
            "acoustid_api_key" => self.acoustid_api_key = value.to_string(),
            "musicbrainz_user_agent" => self.musicbrainz_user_agent = value.to_string(),
            "admin_allow" => {
                self.admin_allow = value
                    .split(',')
                    .map(|entry| entry.trim().parse())
                    .collect::<std::result::Result<_, _>>()
                    .context("invalid admin_allow; expected comma-separated CIDR networks")?;
            }
            other => bail!("unknown or unsettable config field: {other}"),
        }
        self.validate()?;
        Ok(())
    }

    fn validate(&self) -> Result<()> {
        if self.admin_token.len() < 16 {
            bail!("admin_token must contain at least 16 characters");
        }
        if self.admin_allow.is_empty() {
            bail!(
                "admin_allow must contain at least one network; use 127.0.0.0/8 to restrict to this machine"
            );
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
        if self.dlna.enabled {
            validate_lan_bind(self.dlna.bind, "dlna.bind")?;
            if self.dlna.bind.port() == self.bind.port() {
                bail!("dlna.bind must use a different port from the sync listener");
            }
            if self.dashboard.enabled && self.dlna.bind.port() == self.dashboard.bind.port() {
                bail!("dlna.bind must use a different port from the dashboard");
            }
        }
        validate_lan_bind(self.bind, "bind")?;
        Ok(())
    }
}

fn store_exists(data_dir: &Path) -> bool {
    data_dir.join("hub.sqlite3").is_file()
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
        assert!(
            config
                .admin_allow
                .contains(&"127.0.0.0/8".parse::<IpNet>().unwrap())
        );
        assert!(
            config
                .admin_allow
                .contains(&"::1/128".parse::<IpNet>().unwrap())
        );
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

    #[test]
    fn dlna_is_disabled_on_a_separate_port_by_default() {
        let config = Config::default();
        assert!(!config.dlna.enabled);
        assert_eq!(config.dlna.bind.port(), 4850);
    }

    #[test]
    fn enabled_dlna_rejects_public_addresses_and_port_collisions() {
        let mut config = Config::default();
        config.dlna.enabled = true;
        config.dlna.bind = "8.8.8.8:4850".parse().unwrap();
        assert!(config.validate().is_err());
        config.dlna.bind = "127.0.0.1:4848".parse().unwrap();
        assert!(config.validate().is_err(), "should reject the sync port");
        config.dashboard.enabled = true;
        config.dlna.bind = "127.0.0.1:4849".parse().unwrap();
        assert!(
            config.validate().is_err(),
            "should reject the dashboard port"
        );
        config.dlna.bind = "127.0.0.1:4850".parse().unwrap();
        assert!(config.validate().is_ok());
    }

    #[test]
    fn set_field_updates_dlna_fields() {
        let mut config = Config::default();
        config.set_field("dlna.enabled", "true").unwrap();
        config.set_field("dlna.bind", "127.0.0.1:4850").unwrap();
        config
            .set_field("dlna.friendly_name", "Living Room Aro")
            .unwrap();
        assert!(config.dlna.enabled);
        assert_eq!(config.dlna.friendly_name, "Living Room Aro");
        assert!(
            config.set_field("dlna.bind", "8.8.8.8:4850").is_err(),
            "should reject a public dlna bind via validate()"
        );
    }

    #[test]
    fn set_field_rejects_storage_mode() {
        let mut config = Config::default();
        assert!(config.set_field("storage_mode", "referenced").is_err());
        assert_eq!(config.storage_mode, StorageMode::Managed);
    }

    #[test]
    fn set_field_updates_known_fields_and_validates() {
        let mut config = Config::default();
        config.set_field("display_name", "Living Room").unwrap();
        assert_eq!(config.display_name, "Living Room");
        config.set_field("dashboard.enabled", "true").unwrap();
        config
            .set_field("dashboard.bind", "127.0.0.1:4849")
            .unwrap();
        assert!(config.dashboard.enabled);
        assert!(
            config.set_field("dashboard.bind", "8.8.8.8:4849").is_err(),
            "should reject a public dashboard bind via validate()"
        );
    }

    #[test]
    fn set_field_rejects_unknown_keys() {
        let mut config = Config::default();
        assert!(config.set_field("nonexistent", "value").is_err());
    }

    #[test]
    fn storage_mode_env_override_is_ignored_once_a_store_exists() {
        let directory = tempfile::tempdir().unwrap();
        let data_dir = directory.path().join("Hub");
        std::fs::create_dir_all(&data_dir).unwrap();
        std::fs::write(data_dir.join("hub.sqlite3"), b"").unwrap();

        let config_path = directory.path().join("aro.toml");
        let mut config = Config::default();
        config.data_dir = data_dir;
        config.storage_mode = StorageMode::Managed;
        config.save(&config_path).unwrap();

        // SAFETY: single-threaded test process; no other thread reads/writes
        // this env var concurrently.
        unsafe { std::env::set_var("ARO_STORAGE_MODE", "referenced") };
        let result = Config::load(&config_path);
        unsafe { std::env::remove_var("ARO_STORAGE_MODE") };

        assert!(result.is_err(), "expected the override to be rejected");
    }
}
