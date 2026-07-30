use crate::http::AppState;
use axum::{
    Json, Router,
    extract::State,
    http::{HeaderValue, StatusCode, header},
    response::{Html, IntoResponse, Response},
    routing::get,
};
use serde_json::{Value, json};
use std::{sync::Arc, time::Instant};

#[derive(Clone)]
pub struct DashboardState {
    app: Arc<AppState>,
    started: Instant,
    storage_mode: &'static str,
}

impl DashboardState {
    pub fn new(app: AppState, storage_mode: &'static str) -> Self {
        Self {
            app: Arc::new(app),
            started: Instant::now(),
            storage_mode,
        }
    }
}

pub fn router(state: DashboardState) -> Router {
    Router::new()
        .route("/", get(index))
        .route("/api/v1/stats", get(stats))
        .route("/api/v1/overview", get(stats))
        .route("/api/v1/history", get(history))
        .route("/api/v1/library", get(library))
        .route("/api/v1/metadata", get(metadata))
        .route("/api/v1/live", get(live))
        .route("/api/v1/devices", get(devices))
        .route("/api/v1/sources", get(sources))
        .route("/api/v1/host", get(host))
        .route("/api/v1/traffic", get(traffic))
        .route("/metrics", get(metrics))
        .fallback(not_found)
        .with_state(state)
        .layer(axum::middleware::from_fn(security_headers))
}

async fn security_headers(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'",
        ),
    );
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("referrer-policy", HeaderValue::from_static("no-referrer"));
    headers.insert("x-frame-options", HeaderValue::from_static("DENY"));
    response
}

async fn stats(State(state): State<DashboardState>) -> Response {
    match state.app.store.dashboard_stats() {
        Ok(mut value) => {
            value["transport"] = json!({
                "active_transfers": state.app.telemetry.active_transfers(),
                "completed_transfers": state.app.telemetry.completed_transfers(),
                "bytes_served": state.app.telemetry.bytes_served(),
            });
            Json(value).into_response()
        }
        Err(error) => dashboard_error(error),
    }
}

async fn live(State(state): State<DashboardState>) -> Response {
    match state.app.store.dashboard_live_activity() {
        Ok(value) => Json(json!({
            "generated_at": chrono::Utc::now(),
            "sessions": value,
        }))
        .into_response(),
        Err(error) => dashboard_error(error),
    }
}

async fn history(State(state): State<DashboardState>) -> Response {
    stats_section(&state, "listening")
}

async fn library(State(state): State<DashboardState>) -> Response {
    stats_section(&state, "library")
}

async fn metadata(State(state): State<DashboardState>) -> Response {
    stats_section(&state, "metadata")
}

fn stats_section(state: &DashboardState, section: &str) -> Response {
    match state.app.store.dashboard_stats() {
        Ok(value) => {
            let mut response = json!({"generated_at": value["generated_at"]});
            response[section] = value[section].clone();
            Json(response).into_response()
        }
        Err(error) => dashboard_error(error),
    }
}

async fn devices(State(state): State<DashboardState>) -> Response {
    match state.app.store.devices() {
        Ok(value) => Json(json!({
            "generated_at": chrono::Utc::now(),
            "devices": value,
        }))
        .into_response(),
        Err(error) => dashboard_error(error),
    }
}

async fn sources(State(state): State<DashboardState>) -> Response {
    let _ = state.app.store.refresh_host_source_health();
    match state.app.store.source_health() {
        Ok(value) => Json(json!({
            "generated_at": chrono::Utc::now(),
            "sources": value,
        }))
        .into_response(),
        Err(error) => dashboard_error(error),
    }
}

async fn traffic(State(state): State<DashboardState>) -> Response {
    match state.app.store.dashboard_traffic() {
        Ok(mut value) => {
            value["active_transfers"] = json!(state.app.telemetry.active_transfers());
            value["completed_transfers"] = json!(state.app.telemetry.completed_transfers());
            value["bytes_served"] = json!(state.app.telemetry.bytes_served());
            Json(value).into_response()
        }
        Err(error) => dashboard_error(error),
    }
}

async fn host(State(state): State<DashboardState>) -> Json<Value> {
    let data_path = state.app.store.root();
    Json(json!({
        "generated_at": chrono::Utc::now(),
        "hub_id": state.app.hub_id,
        "display_name": state.app.display_name,
        "server_version": env!("CARGO_PKG_VERSION"),
        "protocol_version": aro_sync_protocol::PROTOCOL_VERSION,
        "process_uptime_seconds": state.started.elapsed().as_secs(),
        "operating_system": std::env::consts::OS,
        "architecture": std::env::consts::ARCH,
        "hostname": std::env::var("HOSTNAME").ok(),
        "storage_mode": state.storage_mode,
        "data_path": data_path,
        "disk_free_bytes": fs2::available_space(data_path).ok(),
        "disk_total_bytes": fs2::total_space(data_path).ok(),
    }))
}

async fn metrics(State(state): State<DashboardState>) -> Response {
    let stats = match state.app.store.dashboard_stats() {
        Ok(value) => value,
        Err(error) => return dashboard_error(error),
    };
    let metric = |path: &[&str]| {
        let mut value = &stats;
        for key in path {
            value = &value[*key];
        }
        value.as_f64().unwrap_or_default()
    };
    let body = format!(
        concat!(
            "# HELP aro_server_uptime_seconds Time since the Aro server started.\n",
            "# TYPE aro_server_uptime_seconds gauge\n",
            "aro_server_uptime_seconds {}\n",
            "# HELP aro_active_playback_sessions Playback sessions with a recent heartbeat.\n",
            "# TYPE aro_active_playback_sessions gauge\n",
            "aro_active_playback_sessions {}\n",
            "# HELP aro_connected_devices Authorized devices seen in the last minute.\n",
            "# TYPE aro_connected_devices gauge\n",
            "aro_connected_devices {}\n",
            "# HELP aro_active_media_transfers Open media response streams.\n",
            "# TYPE aro_active_media_transfers gauge\n",
            "aro_active_media_transfers {}\n",
            "# HELP aro_media_bytes_served_total Media bytes served since process start.\n",
            "# TYPE aro_media_bytes_served_total counter\n",
            "aro_media_bytes_served_total {}\n",
            "# HELP aro_library_tracks Tracks in the authoritative library.\n",
            "# TYPE aro_library_tracks gauge\n",
            "aro_library_tracks {}\n",
            "# HELP aro_library_bytes Bytes in the authoritative library.\n",
            "# TYPE aro_library_bytes gauge\n",
            "aro_library_bytes {}\n",
            "# HELP aro_sources_unavailable Unavailable library sources.\n",
            "# TYPE aro_sources_unavailable gauge\n",
            "aro_sources_unavailable {}\n",
            "# HELP aro_metadata_coverage_ratio Fraction of tracks with metadata.\n",
            "# TYPE aro_metadata_coverage_ratio gauge\n",
            "aro_metadata_coverage_ratio{{field=\"title\"}} {}\n",
            "aro_metadata_coverage_ratio{{field=\"artist\"}} {}\n",
            "aro_metadata_coverage_ratio{{field=\"album\"}} {}\n"
        ),
        state.started.elapsed().as_secs(),
        metric(&["live", "active_listeners"]),
        metric(&["live", "connected_devices"]),
        state.app.telemetry.active_transfers(),
        state.app.telemetry.bytes_served(),
        metric(&["library", "track_count"]),
        metric(&["library", "file_size_bytes"]),
        metric(&["sources", "unavailable"]),
        metric(&["metadata", "title_coverage"]),
        metric(&["metadata", "artist_coverage"]),
        metric(&["metadata", "album_coverage"]),
    );
    (
        [(
            header::CONTENT_TYPE,
            "text/plain; version=0.0.4; charset=utf-8",
        )],
        body,
    )
        .into_response()
}

async fn not_found() -> StatusCode {
    StatusCode::NOT_FOUND
}

fn dashboard_error(error: impl std::fmt::Display) -> Response {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({"error": "dashboard_query_failed", "message": error.to_string()})),
    )
        .into_response()
}

async fn index() -> Html<&'static str> {
    Html(INDEX)
}

const INDEX: &str = r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aro Library Intelligence</title>
<style>
:root{color-scheme:dark;--bg:#090913;--surface:#141425;--line:#292946;--text:#f4f2ff;--muted:#9d99b8;--violet:#9d73ff;--cyan:#5be0d0;--warn:#ffb45c}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 20% 0,#231848 0,transparent 34%),var(--bg);color:var(--text);font:14px/1.45 ui-sans-serif,system-ui,-apple-system,sans-serif}
main{max-width:1240px;margin:auto;padding:38px 24px 80px}header{display:flex;align-items:end;justify-content:space-between;margin-bottom:28px}h1{font-size:34px;margin:0;letter-spacing:-1px}h2{font-size:17px;margin:0 0 14px}.eyebrow,.muted{color:var(--muted)}.eyebrow{text-transform:uppercase;letter-spacing:.16em;font-size:11px}
.pulse{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--cyan);box-shadow:0 0 12px var(--cyan);margin-right:7px}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}.card,.panel{background:color-mix(in srgb,var(--surface) 90%,transparent);border:1px solid var(--line);border-radius:15px;box-shadow:0 16px 50px #0003}.card{padding:17px}.label{color:var(--muted);font-size:12px}.value{font-size:27px;font-weight:650;margin-top:5px;font-variant-numeric:tabular-nums}.panel{padding:20px;margin-top:18px}.split{display:grid;grid-template-columns:1.5fr 1fr;gap:18px}.session{display:grid;grid-template-columns:1fr auto;gap:8px;padding:14px 0;border-top:1px solid var(--line)}.session:first-of-type{border:0}.track{font-weight:650;font-size:16px}.bar{height:6px;border-radius:5px;background:#2b2945;overflow:hidden;margin-top:8px}.fill{height:100%;background:linear-gradient(90deg,var(--violet),var(--cyan))}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:9px;border-bottom:1px solid var(--line)}th{color:var(--muted);font-weight:500}.empty{padding:24px 0;color:var(--muted)}
@media(max-width:850px){.grid{grid-template-columns:repeat(2,1fr)}.split{grid-template-columns:1fr}}@media(max-width:480px){main{padding:24px 14px}.grid{grid-template-columns:1fr}header{align-items:start;gap:12px;flex-direction:column}}
</style>
</head>
<body><main>
<header><div><div class="eyebrow">Aro server intelligence</div><h1 id="name">Library dashboard</h1></div><div class="muted"><span class="pulse"></span>Live · refreshes every 5 seconds</div></header>
<section class="grid">
<div class="card"><div class="label">Listening now</div><div class="value" id="active">—</div></div>
<div class="card"><div class="label">Connected devices</div><div class="value" id="connected">—</div></div>
<div class="card"><div class="label">Active transfers</div><div class="value" id="transfers">—</div></div>
<div class="card"><div class="label">Library tracks</div><div class="value" id="tracks">—</div></div>
<div class="card"><div class="label">Library size</div><div class="value" id="bytes">—</div></div>
<div class="card"><div class="label">Lifetime listening</div><div class="value" id="hours">—</div></div>
<div class="card"><div class="label">Logged plays</div><div class="value" id="plays">—</div></div>
<div class="card"><div class="label">Artists</div><div class="value" id="artists">—</div></div>
<div class="card"><div class="label">Albums</div><div class="value" id="albums">—</div></div>
</section>
<section class="panel"><h2>Now playing</h2><div id="live" class="empty">Waiting for playback activity…</div></section>
<section class="split">
<div class="panel"><h2>Format breakdown</h2><table><thead><tr><th>Format</th><th>Tracks</th><th>Storage</th></tr></thead><tbody id="formats"></tbody></table></div>
<div class="panel"><h2>Metadata coverage</h2><div id="metadata"></div></div>
</section>
<section class="panel"><h2>Host</h2><table><tbody id="host"></tbody></table></section>
</main>
<script>
const $=id=>document.getElementById(id),num=n=>new Intl.NumberFormat().format(n||0),bytes=n=>{let value=Number(n)||0;if(value<1000)return num(value)+" B";const units=["KB","MB","GB","TB","PB"];let unit=units[0];for(let i=0;i<units.length;i++){unit=units[i];value/=1000;if(value<1000||i===units.length-1)break}const digits=value>=100?0:value>=10?1:2;return new Intl.NumberFormat(undefined,{minimumFractionDigits:0,maximumFractionDigits:digits}).format(value)+" "+unit},pct=n=>Math.round((n||0)*100)+"%";
async function json(path){let r=await fetch(path,{cache:"no-store"});if(!r.ok)throw Error(r.status);return r.json()}
function set(id,v){$(id).textContent=v}
async function refresh(){
 try{
  const [s,l,h]=await Promise.all([json("/api/v1/stats"),json("/api/v1/live"),json("/api/v1/host")]);
  set("name",h.display_name);set("active",num(s.live.active_listeners));set("connected",num(s.live.connected_devices));set("transfers",num(s.transport.active_transfers));set("tracks",num(s.library.track_count));set("bytes",bytes(s.library.file_size_bytes));set("hours",num(Math.round(s.listening.total_seconds/3600))+" h");set("plays",num(s.listening.logged_plays));set("artists",num(s.library.artist_count));set("albums",num(s.library.album_count));
  $("formats").innerHTML=s.library.formats.map(x=>`<tr><td>${escapeHtml(x.name)}</td><td>${num(x.track_count)}</td><td>${bytes(x.file_size_bytes)}</td></tr>`).join("");
  $("metadata").innerHTML=["title","artist","album"].map(k=>`<div style="margin:14px 0"><div class="label">${k[0].toUpperCase()+k.slice(1)} · ${pct(s.metadata[k+"_coverage"])}</div><div class="bar"><div class="fill" style="width:${pct(s.metadata[k+"_coverage"])}"></div></div></div>`).join("");
  $("live").className=l.sessions.length?"":"empty";$("live").innerHTML=l.sessions.length?l.sessions.map(x=>{let p=x.playback,t=x.track,d=p.duration_seconds||0,pos=p.position_seconds||0;return `<div class="session"><div><div class="track">${escapeHtml(t.title||"Unknown track")}</div><div class="muted">${escapeHtml(t.artist||"Unknown artist")} · ${escapeHtml(x.device_name)} · ${escapeHtml(p.state)}</div><div class="bar"><div class="fill" style="width:${d?Math.min(100,pos/d*100):0}%"></div></div></div><div class="muted">${Math.floor(pos/60)}:${String(Math.floor(pos%60)).padStart(2,"0")}</div></div>`}).join(""):"No active listeners.";
  $("host").innerHTML=[["Version",h.server_version],["Protocol",h.protocol_version],["Host",h.hostname||"Unknown"],["Platform",h.operating_system+" / "+h.architecture],["Storage mode",h.storage_mode],["Data path",h.data_path],["Disk free",bytes(h.disk_free_bytes)],["Process uptime",num(Math.floor(h.process_uptime_seconds/3600))+" h"]].map(x=>`<tr><th>${x[0]}</th><td>${escapeHtml(String(x[1]))}</td></tr>`).join("");
 }catch(e){console.error(e)}
}
function escapeHtml(v){return v.replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
refresh();setInterval(refresh,5000);
</script></body></html>"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dashboard_is_self_contained() {
        assert!(INDEX.contains("/api/v1/stats"));
        assert!(!INDEX.contains("https://"));
    }

    #[test]
    fn dashboard_formats_storage_with_conventional_units() {
        assert!(INDEX.contains(r#"const units=["KB","MB","GB","TB","PB"]"#));
        assert!(!INDEX.contains(r#"notation:"compact""#));
        assert!(!INDEX.contains(r#"unitDisplay:"narrow""#));
    }
}
