#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
configuration=${CONFIGURATION:-release}
app_name=Aro
app_dir="$project_dir/dist/$app_name.app"
icon_source="$project_dir/Assets/app-icon.png"
info_plist="$project_dir/Packaging/Info.plist"
asset_catalog="$project_dir/Assets.xcassets"
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

if [[ ! -d "$asset_catalog" ]]; then
    print -u2 "Missing asset catalog: $asset_catalog"
    exit 1
fi

print "Building Aro ($configuration)…"
swift build --package-path "$project_dir" -c "$configuration"
bin_dir=$(swift build --package-path "$project_dir" -c "$configuration" --show-bin-path)
executable="$bin_dir/$app_name"
resource_bundle_name="AroMac_Aro.bundle"
resource_bundle="$bin_dir/$resource_bundle_name"

if [[ ! -x "$executable" ]]; then
    print -u2 "Build did not produce $executable"
    exit 1
fi

if [[ ! -d "$resource_bundle" ]]; then
    print -u2 "Build did not produce $resource_bundle"
    exit 1
fi

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/aro-app.XXXXXX")
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

print "Building Aro sync helper…"
cargo build --manifest-path "$project_dir/../server/Cargo.toml" \
    -p aro-server --release
helper="$project_dir/../server/target/release/aro-server"
ditto "$helper" "$staged_macos/aro-server"
ditto "$project_dir/../server/packaging/com.aro.server.plist" \
    "$staged_launch_agents/com.aro.server.plist"

# aro-track-id links libchromaprint dynamically (LGPLv2.1 — see its src/fingerprint.rs
# for why static linking isn't used). The linker records an absolute build-machine
# path (e.g. /opt/homebrew/opt/chromaprint/...); that won't exist on an end user's
# Mac, so the real dylib is bundled here and aro-server's dependency is repointed at
# it via an rpath, the same pattern already used for the main app's .frameworks.
chromaprint_dylib=$(otool -L "$staged_macos/aro-server" \
    | awk '/libchromaprint/{print $1}')
if [[ -z "$chromaprint_dylib" ]]; then
    print -u2 "aro-server does not link libchromaprint — expected a dynamic dependency"
    exit 1
fi
chromaprint_dylib_real=$(readlink -f "$chromaprint_dylib" 2>/dev/null || echo "$chromaprint_dylib")
ditto "$chromaprint_dylib_real" "$staged_frameworks/${chromaprint_dylib:t}"
install_name_tool -change "$chromaprint_dylib" \
    "@rpath/${chromaprint_dylib:t}" "$staged_macos/aro-server"
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$staged_macos/aro-server"

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

# Declaring a bundled "AccentColor" is the only way to make AppKit-drawn chrome that
# ignores SwiftUI's `.tint()` — sidebar/source-list selection highlighting, in
# particular — follow Aro's violet instead of the user's system-wide accent color
# preference. `swift build` alone (running the raw executable, not this .app) won't
# pick this up, since it's only discoverable from a real bundle's Resources.
#
# `--accent-color-name` is what makes the compiled asset actually *apply*: it is
# paired with `NSAccentColorName` in Packaging/Info.plist, without which AppKit
# never looks the colour up and silently falls back to the stock system blue.
# Xcode sets both from a build setting; this bundle is assembled by hand, so they
# are spelled out here and asserted below.
# actool reports failures as XML on *stdout* and still exits non-zero, so its output is
# captured and echoed on failure rather than discarded — silently swallowing it turns a
# broken accent colour into a build that "succeeds" and looks stock-blue at runtime.
if ! actool_output=$(xcrun actool "$asset_catalog" \
    --compile "$staged_resources" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --accent-color AccentColor \
    --output-partial-info-plist "$staging_dir/assetcatalog-info.plist" 2>&1); then
    print -u2 "actool failed to compile $asset_catalog:"
    print -u2 "$actool_output"
    exit 1
fi

if [[ ! -f "$staged_resources/Assets.car" ]]; then
    print -u2 "actool did not produce Assets.car — the app accent colour would fall back to system blue"
    exit 1
fi

chmod 755 "$staged_macos/$app_name"
chmod 755 "$staged_macos/aro-server"

codesign --force --sign - --timestamp=none \
    --identifier com.imjacobclark.aro.server \
    "$staged_macos/aro-server"
codesign --force --deep --sign - --timestamp=none \
    --preserve-metadata=identifier \
    "$staged_app"
codesign --verify --strict \
    --test-requirement '=identifier "com.imjacobclark.aro.server"' \
    "$staged_macos/aro-server"
codesign --verify --deep --strict "$staged_app"
plutil -lint "$staged_contents/Info.plist" >/dev/null

# Pairs with the actool invocation above: the compiled colour is inert unless the
# bundle also names it here, and the failure mode is silent (stock blue chrome).
accent_name=$(/usr/libexec/PlistBuddy -c "Print :NSAccentColorName" \
    "$staged_contents/Info.plist" 2>/dev/null || true)
if [[ "$accent_name" != "AccentColor" ]]; then
    print -u2 "Info.plist is missing NSAccentColorName=AccentColor — accent colour would fall back to system blue"
    exit 1
fi

mkdir -p "$project_dir/dist"
rm -rf "$app_dir"
ditto "$staged_app" "$app_dir"

print ""
print "Created $app_dir"
print "Install it with: make macos install"
