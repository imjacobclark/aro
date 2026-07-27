#!/bin/sh
set -eu

server_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$server_dir/.." && pwd)
target_dir=${CARGO_TARGET_DIR:-"$server_dir/target"}
out_dir="$server_dir/dist"
package_dir="$out_dir/aro-server"

mkdir -p "$package_dir/bin" "$package_dir/config"
cp "$target_dir/release/aro-server" "$package_dir/bin/"
cp "$server_dir/packaging/aro-server.toml.example" "$package_dir/config/"
cp "$server_dir/packaging/com.aro.server.plist" "$package_dir/"
cp "$server_dir/packaging/aro-server.service" "$package_dir/"
cp "$server_dir/README.md" "$package_dir/"
cp "$repo_dir/rust-toolchain.toml" "$package_dir/"

tar -C "$out_dir" -czf "$out_dir/aro-server.tar.gz" aro-server
printf "Created %s\n" "$out_dir/aro-server.tar.gz"
