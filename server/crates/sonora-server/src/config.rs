use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::{
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::{Path, PathBuf},
};
use uuid::Uuid;

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
    pub advertise_mdns: bool,
}

impl Default for Config {
    fn default() -> Self {
        let data_dir = default_data_dir();
        Self {
            hub_id: Uuid::new_v4(),
            display_name: "Sonora Hub".into(),
            bind: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 4848),
            tls_cert: data_dir.join("tls/cert.pem"),
            tls_key: data_dir.join("tls/key.pem"),
            control_socket: data_dir.join("control.sock"),
            data_dir,
            admin_token: Uuid::new_v4().simple().to_string(),
            advertise_mdns: true,
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.is_file() {
            bail!(
                "configuration not found at {}; run `sonora-server init` first",
                path.display()
            );
        }
        let mut config: Self = toml::from_str(&std::fs::read_to_string(path)?)
            .with_context(|| format!("invalid config {}", path.display()))?;
        if let Ok(value) = std::env::var("SONORA_BIND") {
            config.bind = value.parse().context("invalid SONORA_BIND")?;
        }
        if let Ok(value) = std::env::var("SONORA_DATA_DIR") {
            config.data_dir = value.into();
        }
        if let Ok(value) = std::env::var("SONORA_ADMIN_TOKEN") {
            config.admin_token = value;
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
        if let IpAddr::V4(ip) = self.bind.ip()
            && !(ip.is_unspecified() || ip.is_private() || ip.is_loopback())
        {
            bail!("refusing non-private bind address; WAN hosting is out of scope");
        }
        if let IpAddr::V6(ip) = self.bind.ip()
            && !(ip.is_unspecified() || ip.is_loopback() || ip.is_unique_local())
        {
            bail!("refusing non-private bind address; WAN hosting is out of scope");
        }
        Ok(())
    }
}

pub fn default_config_path() -> PathBuf {
    default_data_dir().join("sonora.toml")
}

fn default_data_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("SONORA_DATA_DIR") {
        return PathBuf::from(path);
    }
    #[cfg(target_os = "macos")]
    if let Some(home) = macos_home_dir() {
        return home.join("Library/Application Support/Sonora/Server");
    }
    #[cfg(target_os = "windows")]
    if let Some(app_data) = std::env::var_os("PROGRAMDATA") {
        return PathBuf::from(app_data).join("Sonora/Server");
    }
    if let Some(data_home) = std::env::var_os("XDG_DATA_HOME") {
        return PathBuf::from(data_home).join("sonora/server");
    }
    PathBuf::from("/var/lib/sonora")
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
