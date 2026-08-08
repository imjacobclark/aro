#!/usr/bin/env bash
# Builds the web client's container image for a target platform, defaulting to the ARMv7
# Raspberry Pi the hub runs on. The Next build itself runs natively (see the Dockerfile);
# only the runtime layer is cross-built, so this is fast rather than emulated.
#
# Usage:
#   build-image.sh [--platform linux/arm/v7] [--tag aro-web:latest] [--output PATH]
#
# With --output, the image is also saved as a gzipped tarball ready to ship over SSH.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WEB_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

PLATFORM="linux/arm/v7"
TAG="aro-web:latest"
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if ! command -v docker >/dev/null; then
    echo "docker is required to build the image" >&2
    exit 1
fi

echo "==> Building $TAG for $PLATFORM"
docker buildx build \
    --platform "$PLATFORM" \
    --tag "$TAG" \
    --load \
    "$WEB_DIR"

if [ -n "$OUTPUT" ]; then
    echo "==> Saving $TAG to $OUTPUT"
    docker save "$TAG" | gzip -1 > "$OUTPUT"
    echo "==> $(du -h "$OUTPUT" | cut -f1) image archive"
fi
