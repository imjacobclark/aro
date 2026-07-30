#!/bin/sh
set -eu

failed=0

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        printf "%-18s %s\n" "$1" "available"
    else
        printf "%-18s %s\n" "$1" "missing"
        failed=1
    fi
}

check_command cargo
check_command rustc
check_command rustup
check_command pkg-config

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists libchromaprint 2>/dev/null; then
    printf "%-18s %s\n" "libchromaprint" "available ($(pkg-config --modversion libchromaprint))"
else
    printf "%-18s %s\n" "libchromaprint" "missing"
    printf "%-18s %s\n" "" "aro-track-id links this at build time — install it:"
    printf "%-18s %s\n" "" "macOS: brew install chromaprint pkgconf"
    printf "%-18s %s\n" "" "Debian/Ubuntu: apt-get install libchromaprint-dev pkg-config"
    failed=1
fi

for tool in codesign security docker; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf "%-18s %s\n" "$tool" "available (optional)"
    else
        printf "%-18s %s\n" "$tool" "missing (optional)"
    fi
done

if command -v rustup >/dev/null 2>&1; then
    installed=$(rustup target list --installed)
    for target in \
        aarch64-apple-darwin \
        x86_64-apple-darwin \
        x86_64-unknown-linux-gnu \
        aarch64-unknown-linux-gnu \
        x86_64-pc-windows-msvc
    do
        if printf '%s\n' "$installed" | grep -qx "$target"; then
            printf "%-28s %s\n" "$target" "installed"
        else
            printf "%-28s %s\n" "$target" "missing"
        fi
    done
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi
