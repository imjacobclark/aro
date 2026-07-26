mod config;
#[cfg(unix)]
mod control;
mod http;

use anyhow::{Result, bail};
use axum_server::tls_rustls::RustlsConfig;
use clap::{Parser, Subcommand};
use config::{Config, default_config_path};
use http::AppState;
use mdns_sd::{ServiceDaemon, ServiceInfo};
use rcgen::generate_simple_self_signed;
use sha2::{Digest, Sha256};
use sonora_sync_core::{JobRegistry, PairingManager};
use sonora_sync_protocol::{HybridTimestamp, Operation, PROTOCOL_VERSION, SERVICE_TYPE};
use sonora_sync_store::HubStore;
use std::{
    collections::BTreeMap,
    net::{IpAddr, Ipv4Addr},
    path::{Path, PathBuf},
};
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(version, about = "Authoritative Sonora LAN library hub")]
struct Cli {
    #[arg(long, global = true, env = "SONORA_CONFIG")]
    config: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    Serve,
    Init {
        #[arg(long)]
        data_dir: Option<PathBuf>,
        #[arg(long)]
        display_name: Option<String>,
    },
    Import {
        path: PathBuf,
        #[arg(long, default_value = "managed")]
        mode: String,
    },
    Pair,
    Approve {
        request_id: uuid::Uuid,
    },
    Devices,
    Revoke {
        device_id: uuid::Uuid,
    },
    Status,
    Verify,
    Purge {
        hash: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| "sonora_server=info".into()),
        )
        .init();
    let cli = Cli::parse();
    let config_path = cli.config.unwrap_or_else(default_config_path);
    match cli.command {
        Command::Init {
            data_dir,
            display_name,
        } => init(&config_path, data_dir, display_name),
        Command::Serve => serve(Config::load(&config_path)?).await,
        Command::Import { path, mode } => import(&config_path, path, mode),
        Command::Pair => open_pairing(&config_path).await,
        Command::Approve { request_id } => approve_pairing(&config_path, request_id).await,
        Command::Devices => list_devices(&config_path).await,
        Command::Revoke { device_id } => revoke_device(&config_path, device_id).await,
        Command::Status => status(&config_path),
        Command::Verify => verify(&config_path),
        Command::Purge { hash } => purge(&config_path, &hash),
    }
}

fn init(path: &Path, data_dir: Option<PathBuf>, display_name: Option<String>) -> Result<()> {
    if path.exists() {
        bail!("configuration already exists at {}", path.display());
    }
    let mut config = Config::default();
    if let Some(data_dir) = data_dir {
        config.data_dir = data_dir;
        config.tls_cert = config.data_dir.join("tls/cert.pem");
        config.tls_key = config.data_dir.join("tls/key.pem");
        config.control_socket = config.data_dir.join("control.sock");
    }
    if let Some(name) = display_name {
        config.display_name = name;
    }
    std::fs::create_dir_all(&config.data_dir)?;
    ensure_certificate(&config)?;
    HubStore::open(&config.data_dir)?;
    config.save(path)?;
    println!("Initialized {}", path.display());
    println!("Admin token: {}", config.admin_token);
    Ok(())
}

async fn serve(config: Config) -> Result<()> {
    ensure_certificate(&config)?;
    let fingerprint = certificate_fingerprint(&config.tls_cert)?;
    let store = HubStore::open(&config.data_dir)?;
    let pairing = PairingManager::new(fingerprint.clone());
    let state = AppState {
        hub_id: config.hub_id,
        display_name: config.display_name.clone(),
        #[cfg(unix)]
        data_dir: config.data_dir.clone(),
        admin_token: config.admin_token.clone(),
        pairing,
        jobs: JobRegistry::default(),
        store,
    };
    #[cfg(unix)]
    let _control =
        control::start(&config.control_socket, std::sync::Arc::new(state.clone())).await?;
    let _mdns = if config.advertise_mdns {
        Some(advertise(&config, state.pairing.clone())?)
    } else {
        None
    };
    tracing::info!(
        address = %config.bind,
        hub_id = %config.hub_id,
        fingerprint,
        "Sonora hub listening"
    );
    let tls = RustlsConfig::from_pem_file(&config.tls_cert, &config.tls_key).await?;
    axum_server::bind_rustls(config.bind, tls)
        .serve(http::router(state).into_make_service())
        .await?;
    Ok(())
}

fn ensure_certificate(config: &Config) -> Result<()> {
    if config.tls_cert.is_file() && config.tls_key.is_file() {
        return Ok(());
    }
    let certified = generate_simple_self_signed(vec!["sonora.local".into(), "localhost".into()])?;
    if let Some(parent) = config.tls_cert.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&config.tls_cert, certified.cert.pem())?;
    std::fs::write(&config.tls_key, certified.signing_key.serialize_pem())?;
    Ok(())
}

fn certificate_fingerprint(path: &Path) -> Result<String> {
    let pem = std::fs::read_to_string(path)?;
    let body: String = pem
        .lines()
        .filter(|line| !line.starts_with("-----"))
        .collect();
    let der = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, body)?;
    Ok(hex::encode(Sha256::digest(der)))
}

fn advertise(
    config: &Config,
    pairing: PairingManager,
) -> Result<(ServiceDaemon, tokio::task::JoinHandle<()>)> {
    let daemon = ServiceDaemon::new()?;
    daemon.register(service_info(config, pairing.is_open())?)?;
    let updater = daemon.clone();
    let advertised = config.clone();
    let task = tokio::spawn(async move {
        let mut last_available = pairing.is_open();
        let mut timer = tokio::time::interval(std::time::Duration::from_secs(1));
        loop {
            timer.tick().await;
            let available = pairing.is_open();
            if available == last_available {
                continue;
            }
            match service_info(&advertised, available)
                .and_then(|info| updater.register(info).map_err(Into::into))
            {
                Ok(()) => last_available = available,
                Err(error) => {
                    tracing::warn!(%error, "failed to refresh Bonjour pairing state");
                }
            }
        }
    });
    Ok((daemon, task))
}

fn service_info(config: &Config, pairing_available: bool) -> Result<ServiceInfo> {
    let hub_label = config.hub_id.simple().to_string();
    let hostname = format!("sonora-{}.local.", &hub_label[..8]);
    let properties = [
        ("hub_id", config.hub_id.to_string()),
        ("name", config.display_name.clone()),
        ("protocol", PROTOCOL_VERSION.to_string()),
        ("pairing", pairing_available.to_string()),
        ("host", hostname.clone()),
    ];
    let info = ServiceInfo::new(
        SERVICE_TYPE,
        &config.display_name,
        &hostname,
        IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        config.bind.port(),
        &properties[..],
    )?
    .enable_addr_auto();
    Ok(info)
}

fn status(path: &Path) -> Result<()> {
    let config = Config::load(path)?;
    let store = HubStore::open(&config.data_dir)?;
    println!("Hub: {} ({})", config.display_name, config.hub_id);
    println!("Data: {}", config.data_dir.display());
    println!("Bind: {}", config.bind);
    println!("Sequence: {}", store.latest_sequence()?);
    println!(
        "TLS fingerprint: {}",
        certificate_fingerprint(&config.tls_cert)?
    );
    Ok(())
}

fn verify(path: &Path) -> Result<()> {
    let config = Config::load(path)?;
    let (count, failures) = HubStore::open(&config.data_dir)?.verify_all()?;
    println!("Verified {count} blobs");
    if !failures.is_empty() {
        bail!(
            "{} corrupt or missing blobs: {}",
            failures.len(),
            failures.join(", ")
        );
    }
    Ok(())
}

fn purge(path: &Path, hash: &str) -> Result<()> {
    let config = Config::load(path)?;
    let removed = HubStore::open(&config.data_dir)?.purge_blob(hash)?;
    println!(
        "{}",
        if removed {
            "Blob purged"
        } else {
            "Blob did not exist"
        }
    );
    Ok(())
}

fn import(path: &Path, source: PathBuf, mode: String) -> Result<()> {
    let config = Config::load(path)?;
    let store = HubStore::open(&config.data_dir)?;
    let imported = import_into_store(&store, config.hub_id, &config.data_dir, &source, &mode)?;
    println!("Imported {imported} tracks in {mode} mode");
    Ok(())
}

fn import_into_store(
    store: &HubStore,
    hub_id: uuid::Uuid,
    data_dir: &Path,
    source: &Path,
    mode: &str,
) -> Result<usize> {
    if mode != "managed" && mode != "referenced" {
        bail!("mode must be managed or referenced");
    }
    if !source.exists() {
        bail!("source does not exist: {}", source.display());
    }
    let files = media_files(source)?;
    let required_bytes = files.iter().try_fold(0_u64, |total, file| {
        Ok::<_, std::io::Error>(total.saturating_add(file.metadata()?.len()))
    })?;
    let free_bytes = fs2::available_space(data_dir)?;
    println!(
        "Importing {} files (required: {} bytes, free: {} bytes)",
        files.len(),
        if mode == "managed" { required_bytes } else { 0 },
        free_bytes
    );
    if mode == "managed" && required_bytes > free_bytes {
        bail!("insufficient free space for managed import");
    }

    let now = chrono::Utc::now().timestamp_millis();
    let mut source_identity = Sha256::new();
    source_identity.update(hub_id.as_bytes());
    source_identity.update(source.to_string_lossy().as_bytes());
    let source_digest = source_identity.finalize();
    let source_id = uuid::Uuid::from_slice(&source_digest[..16])?;
    store.register_host_source(
        source_id,
        source
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("Music Folder"),
        mode,
        source,
    )?;
    let mut operations = Vec::with_capacity(files.len());
    let mut known_hashes = store.content_hashes()?;
    for file in files {
        let (hash, size) = if mode == "managed" {
            store.import_managed(&file)?
        } else {
            store.import_referenced(&file)?
        };
        if !known_hashes.insert(hash.clone()) {
            continue;
        }
        let track_id = uuid::Uuid::new_v4();
        let timestamp = HybridTimestamp {
            physical_millis: now,
            logical: operations.len() as u32,
            device_id: hub_id,
        };
        operations.push(Operation {
            operation_id: uuid::Uuid::new_v4(),
            device_id: hub_id,
            entity_type: "track".into(),
            entity_id: track_id.to_string(),
            kind: "upsert".into(),
            payload: serde_json::json!({
                "content_hash": hash,
                "byte_count": size,
                "title": file.file_stem().and_then(|value| value.to_str()).unwrap_or("Unknown"),
                "original_filename": file.file_name().and_then(|value| value.to_str()).unwrap_or("Unknown"),
                "original_extension": file.extension().and_then(|value| value.to_str()).unwrap_or("audio"),
                "source_id": source_id
            }),
            field_versions: BTreeMap::from([
                ("content_hash".into(), timestamp.clone()),
                ("byte_count".into(), timestamp.clone()),
                ("title".into(), timestamp.clone()),
                ("original_filename".into(), timestamp.clone()),
                ("original_extension".into(), timestamp.clone()),
                ("source_id".into(), timestamp),
            ]),
        });
    }
    let imported = store.append_operations(&operations)?.len();
    store.set_setting(
        "last_import",
        &serde_json::json!({"path": source, "mode": mode, "tracks": imported}),
    )?;
    Ok(imported)
}

fn media_files(source: &Path) -> Result<Vec<PathBuf>> {
    const EXTENSIONS: &[&str] = &[
        "aac", "aif", "aiff", "alac", "ape", "dsf", "dff", "flac", "m4a", "mp3", "ogg", "opus",
        "wav", "wv",
    ];
    let mut files = Vec::new();
    for entry in walkdir::WalkDir::new(source).follow_links(false) {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }
        let supported = entry
            .path()
            .extension()
            .and_then(|value| value.to_str())
            .is_some_and(|extension| {
                EXTENSIONS
                    .iter()
                    .any(|candidate| extension.eq_ignore_ascii_case(candidate))
            });
        if supported {
            files.push(entry.into_path());
        }
    }
    files.sort();
    Ok(files)
}

async fn open_pairing(path: &Path) -> Result<()> {
    let config = Config::load(path)?;
    let response = admin_client()?
        .post(format!("{}/v1/pairing/open", local_url(&config)))
        .bearer_auth(&config.admin_token)
        .send()
        .await?
        .error_for_status()?
        .json::<serde_json::Value>()
        .await?;
    println!("{}", serde_json::to_string_pretty(&response)?);
    Ok(())
}

async fn list_devices(path: &Path) -> Result<()> {
    let config = Config::load(path)?;
    let response = admin_client()?
        .get(format!("{}/v1/devices", local_url(&config)))
        .bearer_auth(&config.admin_token)
        .send()
        .await?
        .error_for_status()?
        .json::<serde_json::Value>()
        .await?;
    println!("{}", serde_json::to_string_pretty(&response)?);
    Ok(())
}

async fn approve_pairing(path: &Path, request_id: uuid::Uuid) -> Result<()> {
    let config = Config::load(path)?;
    admin_client()?
        .post(format!("{}/v1/pairing/approve", local_url(&config)))
        .bearer_auth(&config.admin_token)
        .json(&serde_json::json!({
            "request_id": request_id,
            "approve": true
        }))
        .send()
        .await?
        .error_for_status()?;
    println!("Approved pairing request {request_id}");
    Ok(())
}

async fn revoke_device(path: &Path, device_id: uuid::Uuid) -> Result<()> {
    let config = Config::load(path)?;
    admin_client()?
        .post(format!("{}/v1/devices/revoke", local_url(&config)))
        .bearer_auth(&config.admin_token)
        .json(&serde_json::json!({"device_id": device_id}))
        .send()
        .await?
        .error_for_status()?;
    println!("Revoked {device_id}");
    Ok(())
}

fn admin_client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        // The admin CLI connects only over loopback with the admin token.
        // Pairing clients authenticate the hub through SPAKE2+.
        .danger_accept_invalid_certs(true)
        .build()?)
}

fn local_url(config: &Config) -> String {
    let host = if config.bind.is_ipv6() {
        "[::1]"
    } else {
        "127.0.0.1"
    };
    format!("https://{host}:{}", config.bind.port())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watched_folder_import_is_idempotent() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("Music");
        let data = directory.path().join("Hub");
        std::fs::create_dir_all(&source).unwrap();
        std::fs::write(source.join("Track.mp3"), b"audio").unwrap();
        let store = HubStore::open(&data).unwrap();
        let hub_id = uuid::Uuid::new_v4();

        assert_eq!(
            import_into_store(&store, hub_id, &data, &source, "managed").unwrap(),
            1
        );
        assert_eq!(
            import_into_store(&store, hub_id, &data, &source, "managed").unwrap(),
            0
        );
        assert_eq!(store.latest_sequence().unwrap(), 1);
    }
}
