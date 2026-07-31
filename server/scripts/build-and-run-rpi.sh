#!/usr/bin/env bash
# Cross-builds aro-server for a Raspberry Pi (armv7 by default) using an
# emulated Docker build, ships the binary to the target host, and installs
# or upgrades it as a systemd service.
#
# Fresh install: creates the aro/aro system user, the data directory, an
# initial config (`aro-server init`), the systemd unit, and starts watching
# --media-location.
#
# Upgrade (systemd unit already present): atomically swaps the binary in
# place (same-filesystem `mv`, so the running process keeps its old inode
# until it exits) and restarts the service. aro-server migrates its own
# SQLite schema on open — this script never touches the database directly.
#
# Usage:
#   build-and-run-rpi.sh --host mercury --user imjacobclark \
#     --media-location /srv/mercury/Library --aro-location /srv/mercury/Aro
#
# Safe to re-run: every remote step is idempotent (checks before creating
# the user/directories/unit/watched folder).
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SERVER_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

HOST=""
REMOTE_USER=""
MEDIA_LOCATION=""
ARO_LOCATION=""
PLATFORM="linux/arm/v7"
STORAGE_MODE="managed"
DASHBOARD_ENABLED="true"
DLNA_ENABLED="false"
ACOUSTID_API_KEY=""
SKIP_BUILD=false
BINARY_PATH=""

usage() {
    cat <<'EOF'
Usage: build-and-run-rpi.sh --host HOST --user USER \
         --media-location PATH --aro-location PATH [options]

Required:
  --host HOST                SSH host (as in ~/.ssh/config, or a real hostname)
  --user USER                SSH user
  --media-location PATH      Folder on the remote host for aro-server to watch
  --aro-location PATH        Folder on the remote host for aro-server's own data

Options:
  --platform PLATFORM        Docker buildx platform (default: linux/arm/v7)
  --storage-mode MODE        managed|referenced, fresh installs only (default: managed)
  --acoustid-api-key KEY     Personal AcoustID key to configure after install
  --no-dashboard             Do not enable the LAN dashboard (enabled by default)
  --dlna                     Enable DLNA/UPnP media serving (disabled by default)
  --skip-build                Skip the Docker build and ship an existing binary
  --binary PATH               Binary to ship when --skip-build is set
  -h, --help                  Show this help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --user) REMOTE_USER="$2"; shift 2 ;;
        --media-location) MEDIA_LOCATION="$2"; shift 2 ;;
        --aro-location) ARO_LOCATION="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --storage-mode) STORAGE_MODE="$2"; shift 2 ;;
        --acoustid-api-key) ACOUSTID_API_KEY="$2"; shift 2 ;;
        --no-dashboard) DASHBOARD_ENABLED="false"; shift ;;
        --dlna) DLNA_ENABLED="true"; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --binary) BINARY_PATH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

for required in HOST REMOTE_USER MEDIA_LOCATION ARO_LOCATION; do
    if [ -z "${!required}" ]; then
        echo "Missing required argument: --$(echo "$required" | tr '[:upper:]' '[:lower:]' | tr '_' '-')" >&2
        usage >&2
        exit 1
    fi
done

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if [ "$SKIP_BUILD" = true ]; then
    if [ -z "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; then
        echo "--skip-build requires --binary pointing at an existing aro-server binary" >&2
        exit 1
    fi
    cp "$BINARY_PATH" "$WORKDIR/aro-server"
else
    echo "==> Building aro-server for $PLATFORM (emulated; this is slow, expect tens of minutes)"
    IMAGE_TAG="aro-server-rpi-build:$(date +%s)"
    docker buildx build \
        --platform "$PLATFORM" \
        --target builder \
        -t "$IMAGE_TAG" \
        --load \
        "$SERVER_DIR"
    CONTAINER_ID=$(docker create "$IMAGE_TAG")
    docker cp "$CONTAINER_ID:/src/target/release/aro-server" "$WORKDIR/aro-server"
    docker rm "$CONTAINER_ID" >/dev/null
    docker image rm "$IMAGE_TAG" >/dev/null 2>&1 || true
fi

chmod 755 "$WORKDIR/aro-server"
echo "==> Built $(du -h "$WORKDIR/aro-server" | cut -f1) binary"

REMOTE="$REMOTE_USER@$HOST"
echo "==> Shipping binary to $REMOTE:/tmp/aro-server.new"
scp -q "$WORKDIR/aro-server" "$REMOTE:/tmp/aro-server.new"

echo "==> Installing/upgrading on $HOST"
# shellcheck disable=SC2087
ssh "$REMOTE" MEDIA_LOCATION="$MEDIA_LOCATION" ARO_LOCATION="$ARO_LOCATION" \
    STORAGE_MODE="$STORAGE_MODE" DASHBOARD_ENABLED="$DASHBOARD_ENABLED" \
    DLNA_ENABLED="$DLNA_ENABLED" \
    ACOUSTID_API_KEY="$ACOUSTID_API_KEY" bash -s <<'REMOTE_SCRIPT'
set -euo pipefail

CONFIG_DIR=/etc/aro
CONFIG_PATH=/etc/aro/aro.toml
UNIT_PATH=/etc/systemd/system/aro-server.service
BIN_PATH=/usr/local/bin/aro-server

if ! getent group aro >/dev/null; then
    sudo groupadd --system aro
fi
if ! getent passwd aro >/dev/null; then
    sudo useradd --system --home "$ARO_LOCATION" --shell /usr/sbin/nologin --gid aro aro
fi

sudo mkdir -p "$ARO_LOCATION"
sudo chown -R aro:aro "$ARO_LOCATION"

# Atomic swap: rename is atomic on the same filesystem, so a process holding
# the old binary open keeps running against its old inode until it exits.
sudo mv /tmp/aro-server.new /usr/local/bin/aro-server.new
sudo chmod 755 /usr/local/bin/aro-server.new
sudo chown root:root /usr/local/bin/aro-server.new
sudo mv /usr/local/bin/aro-server.new "$BIN_PATH"
echo "Installed $("$BIN_PATH" --version 2>&1 || echo unknown) at $BIN_PATH"

FRESH_INSTALL=false
if [ ! -f "$CONFIG_PATH" ]; then
    FRESH_INSTALL=true
    sudo mkdir -p "$CONFIG_DIR"
    sudo chown aro:aro "$CONFIG_DIR"
    echo "==> No existing config; running aro-server init"
    sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" init \
        --data-dir "$ARO_LOCATION" \
        --display-name "$(hostname)" \
        --mode "$STORAGE_MODE"
fi

if [ ! -f "$UNIT_PATH" ]; then
    echo "==> Installing systemd unit"
    sudo tee "$UNIT_PATH" >/dev/null <<'UNIT'
[Unit]
Description=Aro Music Library Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=aro
Group=aro
ExecStart=/usr/local/bin/aro-server --config /etc/aro/aro.toml serve
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable aro-server
fi

if [ "$DASHBOARD_ENABLED" = "true" ]; then
    sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" config set dashboard.enabled true
    sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" config set dashboard.bind 0.0.0.0:4849
fi
if [ "$DLNA_ENABLED" = "true" ]; then
    sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" config set dlna.enabled true
    sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" config set dlna.bind 0.0.0.0:4850
    # aro-server binding the port is not the same as a LAN client being able to reach
    # it -- an active ufw with a default-deny incoming policy (as on this host) silently
    # drops both the DLNA HTTP server and SSDP discovery unless each port has its own
    # explicit allow rule, the same way 4848/4849 already do below. Without this, DLNA
    # would bind and log successfully while remaining completely invisible to every
    # renderer/player on the LAN -- exactly the "server up, but nothing can find it"
    # failure mode that's easy to mistake for an application bug.
    if command -v ufw >/dev/null && sudo ufw status | grep -q "^Status: active"; then
        # host+prefix (e.g. 192.168.1.220/24) works identically to a network address as a
        # ufw/iptables source matcher, so no need to zero the host bits here.
        LAN_CIDR=$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '!/tailscale/ {print $4}' | head -n1)
        if [ -n "$LAN_CIDR" ]; then
            sudo ufw allow proto tcp to any port 4850 from "$LAN_CIDR" comment "Aro DLNA LAN"
            sudo ufw allow proto udp to any port 1900 from "$LAN_CIDR" comment "Aro DLNA SSDP"
        else
            echo "==> Could not auto-detect a LAN subnet; DLNA firewall rules were not added -- add them manually if ufw blocks discovery" >&2
        fi
    fi
fi
if [ -n "$ACOUSTID_API_KEY" ]; then
    sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" config set acoustid_api_key "$ACOUSTID_API_KEY"
fi

echo "==> Restarting service"
sudo systemctl restart aro-server
sudo systemctl is-active --quiet aro-server || {
    echo "aro-server failed to become active; recent logs:" >&2
    sudo journalctl -u aro-server -n 40 --no-pager >&2
    exit 1
}
# systemd reporting "active" only means the process launched, not that its
# TLS listener has finished binding -- opening the certificate/key and
# HubStore can take a moment, especially on a Pi with a large library. Wait
# for the actual HTTPS endpoint to answer before touching the admin API.
BIND_PORT=$(sudo grep -oE '^bind = "[^"]*:[0-9]+"' "$CONFIG_PATH" \
    | grep -oE '[0-9]+"$' | tr -d '"')
for _ in $(seq 1 20); do
    if curl -sk --max-time 2 "https://127.0.0.1:${BIND_PORT:-4848}/v1/hub" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

echo "==> Ensuring $MEDIA_LOCATION is a watched folder"
ALREADY_WATCHED=$(sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" folders list --json 2>/dev/null \
    | grep -F "$MEDIA_LOCATION" || true)
if [ -z "$ALREADY_WATCHED" ]; then
    sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" folders add "$MEDIA_LOCATION"
else
    echo "$MEDIA_LOCATION is already watched"
fi

# The CLI's own status query opens a second SQLite connection; if it lands
# mid-write against a busy hub (e.g. right after a folder scan just kicked
# off identification/loudness work) it can transiently see "database is
# locked" even though the server itself is healthy. Retry a few times
# rather than reporting a spurious failure at the very last step.
for attempt in 1 2 3 4 5; do
    if sudo -u aro "$BIN_PATH" --config "$CONFIG_PATH" status; then
        break
    fi
    if [ "$attempt" -eq 5 ]; then
        echo "status check still failing after retries; the server may still be healthy -- check manually" >&2
    else
        sleep 2
    fi
done
REMOTE_SCRIPT

echo "==> Done. $HOST is running the new build and watching $MEDIA_LOCATION."
