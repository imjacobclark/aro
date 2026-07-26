use crate::http::AppState;
use anyhow::Result;
use chrono::Duration;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    task::JoinHandle,
};
use uuid::Uuid;

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum ControlCommand {
    OpenPairing,
    PendingPairingRequests,
    Approve { request_id: Uuid, approve: bool },
    Devices,
    Revoke { device_id: Uuid },
    Import { path: PathBuf, mode: String },
    Status,
}

#[derive(Serialize)]
struct ControlResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

const CONTROL_PROTOCOL_VERSION: u16 = 3;

pub async fn start(path: &Path, state: Arc<AppState>) -> Result<JoinHandle<()>> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    if path.exists() {
        tokio::fs::remove_file(path).await?;
    }
    let listener = UnixListener::bind(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).await?;
    }
    Ok(tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else {
                break;
            };
            let state = state.clone();
            tokio::spawn(async move {
                if let Err(error) = respond(stream, state).await {
                    tracing::warn!(%error, "control socket request failed");
                }
            });
        }
    }))
}

async fn respond(mut stream: UnixStream, state: Arc<AppState>) -> Result<()> {
    let response = match handle(&mut stream, state).await {
        Ok(result) => ControlResponse {
            ok: true,
            result: Some(result),
            error: None,
        },
        Err(error) => {
            tracing::warn!(%error, "control socket request rejected");
            ControlResponse {
                ok: false,
                result: None,
                error: Some(error.to_string()),
            }
        }
    };
    stream.write_all(&serde_json::to_vec(&response)?).await?;
    stream.shutdown().await?;
    Ok(())
}

async fn handle(stream: &mut UnixStream, state: Arc<AppState>) -> Result<Value> {
    let mut request = Vec::new();
    {
        let mut reader = BufReader::new(stream);
        reader.read_until(b'\n', &mut request).await?;
    }
    if request.len() > 64 * 1_024 {
        anyhow::bail!("control request too large");
    }
    let command: ControlCommand = serde_json::from_slice(&request)?;
    let result = match command {
        ControlCommand::OpenPairing => {
            let code = state.pairing.open(Duration::minutes(5));
            json!({
                "code": code,
                "expires_in_seconds": 300
            })
        }
        ControlCommand::PendingPairingRequests => {
            serde_json::to_value(state.pairing.pending_requests())?
        }
        ControlCommand::Approve {
            request_id,
            approve,
        } => {
            let credential = state.pairing.approve(request_id, approve)?;
            if let Some(credential) = &credential {
                let summary = state
                    .pairing
                    .devices()
                    .into_iter()
                    .find(|device| device.device_id == credential.device_id)
                    .ok_or_else(|| anyhow::anyhow!("approved device missing"))?;
                state.store.save_device(&summary, &credential.credential)?;
            }
            serde_json::to_value(credential)?
        }
        ControlCommand::Devices => serde_json::to_value(state.store.devices()?)?,
        ControlCommand::Revoke { device_id } => {
            let revoked = state.store.revoke_device(device_id)?;
            state.pairing.revoke(device_id);
            json!({"revoked": revoked})
        }
        ControlCommand::Import { path, mode } => {
            let store = state.store.clone();
            let hub_id = state.hub_id;
            let data_dir = state.data_dir.clone();
            let imported = tokio::task::spawn_blocking(move || {
                crate::import_into_store(&store, hub_id, &data_dir, &path, &mode)
            })
            .await??;
            json!({"imported_tracks": imported})
        }
        ControlCommand::Status => json!({
            "control_protocol_version": CONTROL_PROTOCOL_VERSION,
            "hub_id": state.hub_id,
            "display_name": state.display_name,
            "sequence": state.store.latest_sequence()?,
            "pairing_available": state.pairing.is_open()
        }),
    };
    Ok(result)
}
