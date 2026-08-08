#!/usr/bin/env bash
# Builds Aro's web client for a Raspberry Pi (armv7 by default), ships the image over SSH,
# and installs or upgrades it as a systemd-managed container alongside aro-server.
#
# Modelled on server/scripts/build-and-run-rpi.sh, and idempotent in the same way: every
# remote step checks before it creates, so re-running only changes what has actually moved.
#
# Fresh install: installs docker.io if absent, reads the hub's admin token out of
# /etc/aro/aro.toml, copies the hub's TLS certificate for the client to pin, writes the
# systemd unit, and opens the port to the LAN if ufw is active.
#
# Upgrade: loads the new image and restarts the unit. Nothing touches aro-server, its
# config, or its database at any point.
#
# It also puts the app behind `tailscale serve` when the node can get a certificate, which
# matters more than it sounds: served as plain HTTP on a hostname, the app is not a secure
# context, and the browser withholds service workers, installability, and parts of the
# crypto API. HTTPS is what makes it a real installable app rather than a web page.
# This is `serve`, never `funnel` — the app is published to the tailnet, not the internet.
#
# Usage:
#   deploy-web.sh --host mercury --user imjacobclark
#
# Options:
#   --port PORT           Port to serve on (default: 4851)
#   --hub-url URL         Hub sync API as seen from the Pi (default: https://127.0.0.1:4848)
#   --aro-location PATH   Hub data directory, where its tls/cert.pem lives
#                         (default: read from /etc/aro/aro.toml)
#   --platform PLATFORM   Docker platform (default: linux/arm/v7)
#   --skip-build          Ship an image archive that already exists
#   --archive PATH        Archive to ship when --skip-build is set
#   --no-firewall         Do not add a ufw rule for the LAN
#   --no-tailscale-serve  Leave Tailscale's HTTPS proxy alone (LAN HTTP only)
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

HOST=""
REMOTE_USER=""
PORT="4851"
HUB_URL="https://127.0.0.1:4848"
ARO_LOCATION=""
PLATFORM="linux/arm/v7"
SKIP_BUILD=false
ARCHIVE=""
FIREWALL=true
TAILSCALE_SERVE=true
IMAGE_TAG="aro-web:latest"

usage() { sed -n '2,32p' "$0"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --user) REMOTE_USER="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --hub-url) HUB_URL="$2"; shift 2 ;;
        --aro-location) ARO_LOCATION="$2"; shift 2 ;;
        --platform) PLATFORM="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --archive) ARCHIVE="$2"; shift 2 ;;
        --no-firewall) FIREWALL=false; shift ;;
        --no-tailscale-serve) TAILSCALE_SERVE=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

for required in HOST REMOTE_USER; do
    if [ -z "${!required}" ]; then
        echo "Missing required argument: --$(echo "$required" | tr '[:upper:]' '[:lower:]' | tr '_' '-')" >&2
        usage >&2
        exit 1
    fi
done

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if [ "$SKIP_BUILD" = true ]; then
    if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
        echo "--skip-build requires --archive pointing at an existing image archive" >&2
        exit 1
    fi
    cp "$ARCHIVE" "$WORKDIR/aro-web.tar.gz"
else
    "$SCRIPT_DIR/build-image.sh" \
        --platform "$PLATFORM" \
        --tag "$IMAGE_TAG" \
        --output "$WORKDIR/aro-web.tar.gz"
fi

REMOTE="$REMOTE_USER@$HOST"
echo "==> Shipping image to $REMOTE:/tmp/aro-web.tar.gz"
scp -q "$WORKDIR/aro-web.tar.gz" "$REMOTE:/tmp/aro-web.tar.gz"

echo "==> Installing on $HOST"
# Streamed and captured: the remote side is the only thing that knows the node's
# certificate name, and reporting a URL that has to be guessed at helps nobody.
# shellcheck disable=SC2087
ssh "$REMOTE" PORT="$PORT" HUB_URL="$HUB_URL" ARO_LOCATION="$ARO_LOCATION" \
    IMAGE_TAG="$IMAGE_TAG" FIREWALL="$FIREWALL" TAILSCALE_SERVE="$TAILSCALE_SERVE" bash -s \
    <<'REMOTE_SCRIPT' | tee "$WORKDIR/deploy.log"
set -euo pipefail

CONFIG_DIR=/etc/aro-web
ENV_PATH="$CONFIG_DIR/aro-web.env"
CERT_PATH="$CONFIG_DIR/hub-cert.pem"
UNIT_PATH=/etc/systemd/system/aro-web.service
HUB_CONFIG=/etc/aro/aro.toml

if ! command -v docker >/dev/null; then
    echo "==> Installing docker.io"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends docker.io
    sudo systemctl enable --now docker
fi

echo "==> Loading image"
sudo docker load -i /tmp/aro-web.tar.gz >/dev/null
rm -f /tmp/aro-web.tar.gz

if [ ! -f "$HUB_CONFIG" ]; then
    echo "No hub config at $HUB_CONFIG; is aro-server installed on this host?" >&2
    exit 1
fi

# The admin token is the web client's only credential, and it is the hub's own. Reading it
# here rather than passing it over the command line keeps it out of the local shell history
# and out of the process list on both machines.
ADMIN_TOKEN=$(sudo grep -oE '^admin_token[[:space:]]*=[[:space:]]*"[^"]+"' "$HUB_CONFIG" \
    | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$ADMIN_TOKEN" ]; then
    echo "Could not read admin_token from $HUB_CONFIG" >&2
    exit 1
fi

if [ -z "${ARO_LOCATION:-}" ]; then
    ARO_LOCATION=$(sudo grep -oE '^data_dir[[:space:]]*=[[:space:]]*"[^"]+"' "$HUB_CONFIG" \
        | sed -E 's/.*"([^"]+)".*/\1/')
fi
HUB_CERT_SOURCE="$ARO_LOCATION/tls/cert.pem"
if [ ! -f "$HUB_CERT_SOURCE" ]; then
    echo "No hub certificate at $HUB_CERT_SOURCE; pass --aro-location" >&2
    exit 1
fi

sudo mkdir -p "$CONFIG_DIR"
# The certificate is public by definition — it is what the hub presents to every client —
# so it is readable, while the token file is not.
sudo cp "$HUB_CERT_SOURCE" "$CERT_PATH"
sudo chmod 644 "$CERT_PATH"

sudo tee "$ENV_PATH" >/dev/null <<ENVFILE
ARO_HUB_URL=$HUB_URL
ARO_ADMIN_TOKEN=$ADMIN_TOKEN
ARO_HUB_CERT=/run/aro/hub-cert.pem
PORT=$PORT
ENVFILE
sudo chown root:root "$ENV_PATH"
sudo chmod 600 "$ENV_PATH"

if [ ! -f "$UNIT_PATH" ]; then
    echo "==> Installing systemd unit"
    sudo tee "$UNIT_PATH" >/dev/null <<UNIT
[Unit]
Description=Aro Web Client
# The web client is useless without the hub, but it must not take the hub down with it, so
# this is an ordering preference rather than a hard dependency.
After=network-online.target docker.service aro-server.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
TimeoutStartSec=120
# --rm plus a stable name means a failed start never leaves a container behind to collide
# with the next one.
ExecStartPre=-/usr/bin/docker rm -f aro-web
ExecStart=/usr/bin/docker run --rm --name aro-web \\
    --network host \\
    --env-file $ENV_PATH \\
    --volume $CERT_PATH:/run/aro/hub-cert.pem:ro \\
    --memory 320m \\
    $IMAGE_TAG
ExecStop=/usr/bin/docker stop aro-web

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable aro-web
else
    # An upgrade may have changed the unit's image tag or port, so reload regardless.
    sudo systemctl daemon-reload
fi

if [ "$FIREWALL" = "true" ] && command -v ufw >/dev/null \
    && sudo ufw status | grep -q "^Status: active"; then
    # aro-server binding a port is not the same as a phone being able to reach it: a
    # default-deny ufw silently drops the connection, which looks exactly like the app
    # being broken. The DLNA setup opens its ports the same way.
    LAN_CIDR=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '!/tailscale/ {print $4}' | head -n1)
    if [ -n "$LAN_CIDR" ]; then
        sudo ufw allow proto tcp to any port "$PORT" from "$LAN_CIDR" \
            comment "Aro web client" >/dev/null
    else
        echo "==> Could not detect a LAN subnet; no firewall rule was added" >&2
    fi
fi

echo "==> Restarting aro-web"
sudo systemctl restart aro-web

HEALTHY=false
for _ in $(seq 1 40); do
    if curl -sf --max-time 2 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
        HEALTHY=true
        break
    fi
    sleep 1
done

if [ "$HEALTHY" != "true" ]; then
    echo "aro-web did not become healthy; recent logs:" >&2
    sudo journalctl -u aro-web -n 40 --no-pager >&2
    exit 1
fi

echo "==> Healthy on port $PORT"
curl -s "http://127.0.0.1:$PORT/api/health"
echo

# HTTPS, via Tailscale's own certificate for this node.
#
# Without it the app is reachable but not a *secure context*, and browsers withhold service
# workers, Add to Home Screen, and parts of the crypto API from those — so the difference
# between http:// and https:// here is the difference between a web page and an installable
# app. `serve` publishes to the tailnet only; `funnel` would publish to the internet and is
# deliberately not used.
if [ "$TAILSCALE_SERVE" = "true" ] && command -v tailscale >/dev/null; then
    CERT_DOMAIN=$(tailscale status --json 2>/dev/null \
        | python3 -c 'import json,sys; print((json.load(sys.stdin).get("CertDomains") or [""])[0])' 2>/dev/null || true)

    if [ -z "$CERT_DOMAIN" ]; then
        echo "==> Tailscale has no certificate domain for this node; skipping HTTPS." >&2
        echo "    Enable HTTPS Certificates in the tailnet's admin console to use it." >&2
    else
        echo "==> Publishing over HTTPS as https://$CERT_DOMAIN/"
        # Idempotent: re-running simply restates the same mapping.
        sudo tailscale serve --bg --https=443 "http://127.0.0.1:$PORT" >/dev/null

        # The first request has to mint a certificate, which takes a few seconds; polling
        # here means the deploy reports a URL that already works.
        for _ in $(seq 1 30); do
            if curl -sf --max-time 5 "https://$CERT_DOMAIN/api/health" >/dev/null 2>&1; then
                echo "==> HTTPS ready"
                break
            fi
            sleep 2
        done
        echo "TAILSCALE_URL=https://$CERT_DOMAIN/"
    fi
fi
REMOTE_SCRIPT

TAILSCALE_URL=$(sed -n 's/^TAILSCALE_URL=//p' "$WORKDIR/deploy.log" | tail -n1)

echo
echo "==> Deployed."
echo "    LAN:       http://$HOST:$PORT   (plain HTTP — plays, but cannot install)"
if [ -n "$TAILSCALE_URL" ]; then
    echo "    Tailscale: $TAILSCALE_URL   (HTTPS — installable, works offline)"
fi
