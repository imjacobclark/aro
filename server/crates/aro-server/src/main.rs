mod audio_metadata;
mod config;
#[cfg(unix)]
mod control;
mod dashboard;
mod dlna;
mod http;
mod metadata_delta;
mod metadata_overrides;
mod playlists;
mod sources;

use anyhow::{Context, Result, bail};
use aro_sync_core::{JobRegistry, PairingManager};
#[cfg(test)]
use aro_sync_protocol::{HybridTimestamp, Operation};
use aro_sync_protocol::{PROTOCOL_VERSION, SERVICE_TYPE};
use aro_sync_store::HubStore;
use axum_server::tls_rustls::RustlsConfig;
use clap::{Parser, Subcommand};
use config::{Config, StorageMode, default_config_path};
use http::AppState;
use mdns_sd::{ServiceDaemon, ServiceInfo};
use rcgen::generate_simple_self_signed;
use sha2::{Digest, Sha256};
#[cfg(test)]
use std::collections::BTreeMap;
use std::{
    fs::{self, File, OpenOptions},
    net::{IpAddr, Ipv4Addr},
    path::{Path, PathBuf},
};
use tracing_subscriber::EnvFilter;

#[derive(Parser)]
#[command(version, about = "Authoritative Aro LAN library server")]
struct Cli {
    #[arg(long, global = true, env = "ARO_CONFIG")]
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
        #[arg(long, value_enum, default_value = "managed")]
        mode: StorageMode,
    },
    Folders {
        #[command(subcommand)]
        command: FolderCommand,
    },
    Pairing {
        #[command(subcommand)]
        command: PairingCommand,
    },
    Pair,
    Approve {
        request_id: uuid::Uuid,
    },
    Devices {
        #[command(subcommand)]
        command: Option<DeviceCommand>,
    },
    Revoke {
        device_id: uuid::Uuid,
    },
    Status,
    Verify,
    Purge {
        hash: String,
    },
    Migrate {
        #[arg(long)]
        to: PathBuf,
    },
    Config {
        #[command(subcommand)]
        command: ConfigCommand,
    },
    Metadata {
        #[command(subcommand)]
        command: MetadataCommand,
    },
}

#[derive(Subcommand)]
enum MetadataCommand {
    /// Whether Aro may write its metadata into your audio files.
    ///
    /// Off by default, and only ever acted on when someone asks for a specific write —
    /// nothing in Aro rewrites files on its own. Turning this on lets corrections made in
    /// Aro be carried out to the files themselves, which changes those files on disk.
    WriteBack {
        /// `on` to permit writes, `off` to forbid them. Omit to show the current setting.
        state: Option<String>,
    },
}

#[derive(Subcommand)]
enum ConfigCommand {
    Get { key: String },
    Set { key: String, value: String },
}

#[derive(Subcommand)]
enum FolderCommand {
    Add {
        path: PathBuf,
    },
    List {
        #[arg(long)]
        json: bool,
    },
    Scan {
        source_id: Option<uuid::Uuid>,
        #[arg(long)]
        all: bool,
    },
    Remove {
        source_id: uuid::Uuid,
    },
}

#[derive(Subcommand)]
enum DeviceCommand {
    List,
    Allow { device_id: uuid::Uuid },
    Deny { device_id: uuid::Uuid },
}

#[derive(Subcommand)]
enum PairingCommand {
    Requests {
        #[arg(long)]
        json: bool,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "aro_server=info,aro_track_id=info".into()),
        )
        .init();
    let cli = Cli::parse();
    let config_path = cli.config.unwrap_or_else(default_config_path);
    match cli.command {
        Command::Init {
            data_dir,
            display_name,
            mode,
        } => init(&config_path, data_dir, display_name, mode),
        Command::Serve => serve(Config::load(&config_path)?, config_path).await,
        Command::Folders { command } => folders(&config_path, command).await,
        Command::Pairing { command } => pairing(&config_path, command).await,
        Command::Pair => open_pairing(&config_path).await,
        Command::Approve { request_id } => approve_pairing(&config_path, request_id).await,
        Command::Devices { command } => devices(&config_path, command).await,
        Command::Revoke { device_id } => revoke_device(&config_path, device_id).await,
        Command::Status => status(&config_path),
        Command::Verify => verify(&config_path),
        Command::Purge { hash } => purge(&config_path, &hash),
        Command::Migrate { to } => migrate_instance(&config_path, &to),
        Command::Config { command } => config_command(&config_path, command),
        Command::Metadata { command } => metadata_command(&config_path, command).await,
    }
}

async fn metadata_command(path: &Path, command: MetadataCommand) -> Result<()> {
    let config = Config::load(path)?;
    let client = admin_client()?;
    let url = format!("{}/v1/metadata/write-back/enabled", local_url(&config));
    let MetadataCommand::WriteBack { state } = command;
    let enabled = match state.as_deref() {
        None => {
            client
                .get(&url)
                .bearer_auth(&config.admin_token)
                .send()
                .await?
                .error_for_status()?
                .json::<serde_json::Value>()
                .await?["enabled"]
                == serde_json::json!(true)
        }
        Some("on" | "true" | "yes") => {
            set_write_back(&client, &url, &config.admin_token, true).await?
        }
        Some("off" | "false" | "no") => {
            set_write_back(&client, &url, &config.admin_token, false).await?
        }
        Some(other) => anyhow::bail!("expected `on` or `off`, got `{other}`"),
    };
    println!(
        "Writing metadata into your audio files is {}",
        if enabled { "ON" } else { "OFF" }
    );
    Ok(())
}

async fn set_write_back(
    client: &reqwest::Client,
    url: &str,
    admin_token: &str,
    enabled: bool,
) -> Result<bool> {
    client
        .put(url)
        .bearer_auth(admin_token)
        .json(&serde_json::json!({"enabled": enabled}))
        .send()
        .await?
        .error_for_status()?;
    Ok(enabled)
}

fn config_command(path: &Path, command: ConfigCommand) -> Result<()> {
    match command {
        ConfigCommand::Get { key } => {
            let config = Config::load(path)?;
            let value = serde_json::to_value(&config)?;
            let field = key
                .split('.')
                .try_fold(&value, |current, part| current.get(part));
            match field {
                Some(field) => println!("{field}"),
                None => bail!("unknown config field: {key}"),
            }
        }
        ConfigCommand::Set { key, value } => {
            let mut config = Config::load(path)?;
            config.set_field(&key, &value)?;
            config.save(path)?;
            println!("Set {key}; restart the server to apply it");
        }
    }
    Ok(())
}

fn init(
    path: &Path,
    data_dir: Option<PathBuf>,
    display_name: Option<String>,
    mode: StorageMode,
) -> Result<()> {
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
    config.storage_mode = mode;
    std::fs::create_dir_all(&config.data_dir)?;
    ensure_certificate(&config)?;
    HubStore::open(&config.data_dir)?;
    config.save(path)?;
    println!("Initialized {}", path.display());
    println!("Admin token: {}", config.admin_token);
    Ok(())
}

async fn serve(config: Config, config_path: PathBuf) -> Result<()> {
    let _instance_lock = lock_instance(&config.data_dir)?;
    ensure_certificate(&config)?;
    let fingerprint = certificate_fingerprint(&config.tls_cert)?;
    let store = HubStore::open(&config.data_dir)?;
    let identification_config =
        (!config.acoustid_api_key.is_empty()).then(|| aro_track_id::IdentificationConfig {
            acoustid_api_key: config.acoustid_api_key.clone(),
            musicbrainz_user_agent: config.musicbrainz_user_agent.clone(),
        });
    let identification = aro_track_id::IdentificationQueue::start(
        store.clone(),
        config.hub_id,
        identification_config,
    );
    let loudness = aro_track_id::loudness::LoudnessQueue::start(store.clone(), config.hub_id);
    let audio_features = {
        let success_store = store.clone();
        let failure_store = store.clone();
        aro_track_id::audio_features::AudioFeatureQueue::start(
            std::sync::Arc::new(
                move |hash: &str,
                      version: i64,
                      features: &aro_track_id::audio_features::AudioFeatures| {
                    let payload = serde_json::to_string(features)?;
                    success_store.put_audio_features(hash, version, &payload)?;
                    Ok(())
                },
            ),
            std::sync::Arc::new(move |hash: &str, version: i64, error: &str| {
                failure_store
                    .record_audio_feature_failure(hash, version, error)
                    .ok();
            }),
        )
    };
    let sources = sources::SourceManager::start(
        store.clone(),
        config.hub_id,
        config.storage_mode,
        config.source_rescan_seconds,
        identification.clone(),
        loudness,
        audio_features,
    )?;
    let pairing = PairingManager::new(fingerprint.clone());
    let state = AppState {
        config_path: config_path.clone(),
        hub_id: config.hub_id,
        display_name: config.display_name.clone(),
        tls_fingerprint: fingerprint.clone(),
        https_port: config.bind.port(),
        admin_token: config.admin_token.clone(),
        admin_allow: config.admin_allow.clone(),
        pairing,
        jobs: JobRegistry::default(),
        store,
        sources,
        telemetry: http::RuntimeTelemetry::default(),
        identification_available: !config.acoustid_api_key.is_empty(),
        musicbrainz_user_agent: config.musicbrainz_user_agent.clone(),
        musicbrainz: std::sync::Arc::new(aro_track_id::musicbrainz::MusicBrainzClient::new(
            config.musicbrainz_user_agent.clone(),
        )),
        artwork_http: reqwest::Client::new(),
        playlist_seeds: std::sync::Arc::new(parking_lot::Mutex::new(None)),
        transcode_slots: std::sync::Arc::new(tokio::sync::Semaphore::new(
            http::default_transcode_slots(),
        )),
    };
    let _dashboard = if config.dashboard.enabled {
        let listener = tokio::net::TcpListener::bind(config.dashboard.bind)
            .await
            .with_context(|| {
                format!(
                    "could not bind unauthenticated dashboard at {}",
                    config.dashboard.bind
                )
            })?;
        let dashboard = dashboard::router(dashboard::DashboardState::new(
            state.clone(),
            config.storage_mode.as_str(),
        ));
        tracing::warn!(
            address = %config.dashboard.bind,
            "Dashboard enabled; telemetry is public and administration requires the admin token"
        );
        Some(tokio::spawn(async move {
            if let Err(error) = axum::serve(
                listener,
                dashboard.into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
            {
                tracing::error!(%error, "Dashboard listener stopped");
            }
        }))
    } else {
        None
    };
    let _dlna = if config.dlna.enabled {
        Some(dlna::start(&config, state.clone()).await?)
    } else {
        None
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
        "Aro server listening"
    );
    let tls = RustlsConfig::from_pem_file(&config.tls_cert, &config.tls_key).await?;
    axum_server::bind_rustls(config.bind, tls)
        .serve(http::router(state).into_make_service_with_connect_info::<std::net::SocketAddr>())
        .await?;
    Ok(())
}

fn lock_instance(data_dir: &Path) -> Result<File> {
    fs::create_dir_all(data_dir)?;
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(data_dir.join("instance.lock"))?;
    fs2::FileExt::try_lock_exclusive(&file)
        .with_context(|| format!("Aro instance at {} is already running", data_dir.display()))?;
    Ok(file)
}

fn migrate_instance(config_path: &Path, destination: &Path) -> Result<()> {
    let mut config = Config::load(config_path)?;
    let source = config.data_dir.canonicalize()?;
    let destination = destination.to_path_buf();
    if destination.exists() {
        bail!(
            "destination must not already exist: {}",
            destination.display()
        );
    }
    let parent = destination
        .parent()
        .context("migration destination must have a parent directory")?;
    fs::create_dir_all(parent)?;
    let parent = parent.canonicalize()?;
    let destination = parent.join(
        destination
            .file_name()
            .context("migration destination needs a directory name")?,
    );
    if destination.starts_with(&source) || source.starts_with(&destination) {
        bail!("migration destination must not contain the current Library Data or be inside it");
    }
    let _lock = lock_instance(&source)?;
    {
        let store = HubStore::open(&source)?;
        store.checkpoint()?;
        let (_, failures) = store.verify_all()?;
        if !failures.is_empty() {
            bail!(
                "current Library Data contains corrupt blobs: {}",
                failures.join(", ")
            );
        }
    }
    let required = directory_size(&source)?;
    let free = fs2::available_space(&parent)?;
    if required > free {
        bail!("migration needs {required} bytes but only {free} bytes are free");
    }
    let stage = parent.join(format!(".aro-migrate-{}", uuid::Uuid::new_v4().simple()));
    copy_directory(&source, &stage)?;
    {
        let copied = HubStore::open(&stage)?;
        let (_, failures) = copied.verify_all()?;
        if !failures.is_empty() {
            let _ = fs::remove_dir_all(&stage);
            bail!(
                "copied Library Data failed verification: {}",
                failures.join(", ")
            );
        }
        copied.checkpoint()?;
    }
    fs::rename(&stage, &destination)?;
    let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
    let backup = source.with_file_name(format!(
        "{}.backup-{stamp}",
        source
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("Aro")
    ));
    fs::rename(&source, &backup)?;

    let relocate = |path: &Path| {
        path.strip_prefix(&source)
            .map(|relative| destination.join(relative))
            .unwrap_or_else(|_| path.to_path_buf())
    };
    config.data_dir = destination.clone();
    config.tls_cert = relocate(&config.tls_cert);
    config.tls_key = relocate(&config.tls_key);
    config.control_socket = relocate(&config.control_socket);
    let new_config_path = config_path
        .strip_prefix(&source)
        .map(|relative| destination.join(relative))
        .unwrap_or_else(|_| config_path.to_path_buf());
    if let Err(error) = config.save(&new_config_path) {
        let _ = fs::rename(&backup, &source);
        return Err(error);
    }
    println!("Migrated Library Data to {}", destination.display());
    println!("Configuration: {}", new_config_path.display());
    println!("Recoverable backup: {}", backup.display());
    Ok(())
}

fn directory_size(root: &Path) -> Result<u64> {
    walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .try_fold(0_u64, |total, entry| {
            let entry = entry?;
            Ok(total.saturating_add(entry.metadata().map(|metadata| {
                if metadata.is_file() {
                    metadata.len()
                } else {
                    0
                }
            })?))
        })
}

fn copy_directory(source: &Path, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)?;
    for entry in walkdir::WalkDir::new(source).follow_links(false) {
        let entry = entry?;
        let relative = entry.path().strip_prefix(source)?;
        if relative == Path::new("control.sock")
            || relative == Path::new("instance.lock")
            || relative == Path::new("hub.sqlite3-wal")
            || relative == Path::new("hub.sqlite3-shm")
        {
            continue;
        }
        let target = destination.join(relative);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target)?;
        } else if entry.file_type().is_file() {
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

fn ensure_certificate(config: &Config) -> Result<()> {
    if config.tls_cert.is_file() && config.tls_key.is_file() {
        return Ok(());
    }
    let certified = generate_simple_self_signed(vec!["aro.local".into(), "localhost".into()])?;
    if let Some(parent) = config.tls_cert.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&config.tls_cert, certified.cert.pem())?;
    std::fs::write(&config.tls_key, certified.signing_key.serialize_pem())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&config.tls_key, std::fs::Permissions::from_mode(0o600))?;
    }
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
    let hostname = format!("aro-{}.local.", &hub_label[..8]);
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
    println!("Aro: {} ({})", config.display_name, config.hub_id);
    println!("Data: {}", config.data_dir.display());
    println!("Storage: {}", config.storage_mode.as_str());
    println!("Bind: {}", config.bind);
    println!(
        "Dashboard: {}",
        if config.dashboard.enabled {
            format!("http://{}", config.dashboard.bind)
        } else {
            "disabled".into()
        }
    );
    println!("Sequence: {}", store.latest_sequence()?);
    let folders = store.source_folders()?;
    println!(
        "Imported folders: {}",
        folders.iter().filter(|folder| folder.watching).count()
    );
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

#[cfg(test)]
#[allow(dead_code)]
fn import(path: &Path, source: PathBuf, mode: String) -> Result<()> {
    let config = Config::load(path)?;
    let store = HubStore::open(&config.data_dir)?;
    let imported = import_into_store(&store, config.hub_id, &config.data_dir, &source, &mode)?;
    println!("Imported {imported} songs in {mode} mode");
    Ok(())
}

#[cfg(test)]
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
            payload: audio_metadata::song_payload(&file, &hash, size, source_id),
            field_versions: BTreeMap::new(),
        });
        let operation = operations.last_mut().expect("operation was just added");
        operation.field_versions = operation
            .payload
            .as_object()
            .expect("song payload is an object")
            .keys()
            .map(|field| (field.clone(), timestamp.clone()))
            .collect();
    }
    let imported = store.append_operations(&operations)?.len();
    store.set_setting(
        "last_import",
        &serde_json::json!({"path": source, "mode": mode, "tracks": imported}),
    )?;
    Ok(imported)
}

#[cfg(test)]
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

async fn folders(path: &Path, command: FolderCommand) -> Result<()> {
    let config = Config::load(path)?;
    let client = admin_client()?;
    match command {
        FolderCommand::Add { path } => {
            let value = client
                .post(format!("{}/v1/admin/folders", local_url(&config)))
                .bearer_auth(&config.admin_token)
                .json(&serde_json::json!({"path": path}))
                .send()
                .await?
                .error_for_status()?
                .json::<serde_json::Value>()
                .await?;
            println!("{}", serde_json::to_string_pretty(&value)?);
        }
        FolderCommand::List { json } => {
            let value = client
                .get(format!("{}/v1/admin/folders", local_url(&config)))
                .bearer_auth(&config.admin_token)
                .send()
                .await?
                .error_for_status()?
                .json::<serde_json::Value>()
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&value)?);
            } else {
                let folders = value.as_array().cloned().unwrap_or_default();
                if folders.is_empty() {
                    println!("No imported folders");
                }
                for folder in folders {
                    println!(
                        "{}  {}  {} songs, {} missing  {}",
                        folder["source_id"].as_str().unwrap_or("?"),
                        folder["path"].as_str().unwrap_or("?"),
                        folder["song_count"].as_u64().unwrap_or(0),
                        folder["missing_count"].as_u64().unwrap_or(0),
                        if folder["watching"].as_bool().unwrap_or(false) {
                            "watching"
                        } else {
                            "detached"
                        }
                    );
                }
            }
        }
        FolderCommand::Scan { source_id, all } => {
            if !all && source_id.is_none() {
                bail!("provide a folder ID or --all");
            }
            let value = client
                .post(format!("{}/v1/admin/folders/scan", local_url(&config)))
                .bearer_auth(&config.admin_token)
                .json(&serde_json::json!({"source_id": if all { None } else { source_id }}))
                .send()
                .await?
                .error_for_status()?
                .json::<serde_json::Value>()
                .await?;
            println!("{}", serde_json::to_string_pretty(&value)?);
        }
        FolderCommand::Remove { source_id } => {
            client
                .post(format!("{}/v1/admin/folders/remove", local_url(&config)))
                .bearer_auth(&config.admin_token)
                .json(&serde_json::json!({"source_id": source_id}))
                .send()
                .await?
                .error_for_status()?;
            println!("Stopped watching {source_id}; imported songs were kept");
        }
    }
    Ok(())
}

async fn pairing(path: &Path, command: PairingCommand) -> Result<()> {
    let config = Config::load(path)?;
    match command {
        PairingCommand::Requests { json: _ } => {
            let response = admin_client()?
                .get(format!("{}/v1/pairing/requests", local_url(&config)))
                .bearer_auth(&config.admin_token)
                .send()
                .await?
                .error_for_status()?
                .json::<serde_json::Value>()
                .await?;
            println!("{}", serde_json::to_string_pretty(&response)?);
        }
    }
    Ok(())
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

async fn devices(path: &Path, command: Option<DeviceCommand>) -> Result<()> {
    match command.unwrap_or(DeviceCommand::List) {
        DeviceCommand::List => list_devices(path).await,
        DeviceCommand::Allow { device_id } => set_device_contribution(path, device_id, true).await,
        DeviceCommand::Deny { device_id } => set_device_contribution(path, device_id, false).await,
    }
}

async fn set_device_contribution(
    path: &Path,
    device_id: uuid::Uuid,
    can_contribute: bool,
) -> Result<()> {
    let config = Config::load(path)?;
    admin_client()?
        .post(format!("{}/v1/devices/permissions", local_url(&config)))
        .bearer_auth(&config.admin_token)
        .json(&serde_json::json!({
            "device_id": device_id,
            "can_contribute": can_contribute
        }))
        .send()
        .await?
        .error_for_status()?;
    println!(
        "{} contributions for {device_id}",
        if can_contribute {
            "Enabled"
        } else {
            "Disabled"
        }
    );
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
