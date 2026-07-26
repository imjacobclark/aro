#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
configuration=${CONFIGURATION:-release}
app_name=Sonora
app_dir="$project_dir/dist/$app_name.app"
icon_source="$project_dir/Assets/app-icon.png"
info_plist="$project_dir/Packaging/Info.plist"
app_version=${APP_VERSION:-0.0.0}
build_number=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}

if [[ ! -f "$icon_source" ]]; then
    print -u2 "Missing app icon: $icon_source"
    exit 1
fi

if [[ ! -f "$info_plist" ]]; then
    print -u2 "Missing app metadata: $info_plist"
    exit 1
fi

print "Building Sonora ($configuration)…"
swift build --package-path "$project_dir" -c "$configuration"
bin_dir=$(swift build --package-path "$project_dir" -c "$configuration" --show-bin-path)
executable="$bin_dir/$app_name"
resource_bundle_name="SonoraMac_Sonora.bundle"
resource_bundle="$bin_dir/$resource_bundle_name"

if [[ ! -x "$executable" ]]; then
    print -u2 "Build did not produce $executable"
    exit 1
fi

if [[ ! -d "$resource_bundle" ]]; then
    print -u2 "Build did not produce $resource_bundle"
    exit 1
fi

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/sonora-app.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/$app_name.app"
staged_contents="$staged_app/Contents"
staged_macos="$staged_contents/MacOS"
staged_resources="$staged_contents/Resources"
staged_frameworks="$staged_contents/Frameworks"
staged_launch_agents="$staged_contents/Library/LaunchAgents"
iconset="$staging_dir/$app_name.iconset"

mkdir -p "$staged_macos" "$staged_resources" "$staged_frameworks" \
    "$staged_launch_agents" "$iconset"
ditto "$executable" "$staged_macos/$app_name"
ditto "$info_plist" "$staged_contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $app_version" \
    -c "Set :CFBundleVersion $build_number" \
    "$staged_contents/Info.plist"

print "Building Sonora sync helper…"
cargo build --manifest-path "$project_dir/../server/Cargo.toml" \
    -p sonora-server --release
helper="$project_dir/../server/target/release/sonora-server"
ditto "$helper" "$staged_macos/sonora-server"
ditto "$project_dir/../server/packaging/com.sonora.server.plist" \
    "$staged_launch_agents/com.sonora.server.plist"

# App bundles expose resources through Contents/Resources. Bundle.module still
# resolves the SwiftPM bundle when running the executable directly in builds.
ditto "$resource_bundle/Montserrat-Variable.ttf" \
    "$staged_resources/Montserrat-Variable.ttf"
ditto "$resource_bundle/OFL-Montserrat.txt" \
    "$staged_resources/OFL-Montserrat.txt"

frameworks=("$bin_dir"/*.framework(N))
for framework in "${frameworks[@]}"; do
    ditto "$framework" "$staged_frameworks/${framework:t}"
done

if (( ${#frameworks} > 0 )); then
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$staged_macos/$app_name"
fi

for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size=${spec%% *}
    filename=${spec#* }
    sips --resampleHeightWidth "$size" "$size" "$icon_source" \
        --out "$iconset/$filename" >/dev/null
done

iconutil --convert icns "$iconset" --output "$staged_resources/$app_name.icns"
chmod 755 "$staged_macos/$app_name"
chmod 755 "$staged_macos/sonora-server"

codesign --force --sign - --timestamp=none \
    --identifier com.imjacobclark.sonora.server \
    "$staged_macos/sonora-server"
codesign --force --deep --sign - --timestamp=none \
    --preserve-metadata=identifier \
    "$staged_app"
codesign --verify --strict \
    --test-requirement '=identifier "com.imjacobclark.sonora.server"' \
    "$staged_macos/sonora-server"
codesign --verify --deep --strict "$staged_app"
plutil -lint "$staged_contents/Info.plist" >/dev/null

mkdir -p "$project_dir/dist"
rm -rf "$app_dir"
ditto "$staged_app" "$app_dir"

print ""
print "Created $app_dir"
print "Install it with: make macos install"
