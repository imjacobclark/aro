#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
source_app="$project_dir/dist/Aro.app"
applications_dir="$HOME/Applications"
installed_app="$applications_dir/Aro.app"
legacy_app="$applications_dir/Sonora.app"
migration_marker="$HOME/Library/Application Support/Aro/.aro-brand-migration-v1"

"$project_dir/scripts/build-app.sh"

# The Background Service helper is ad-hoc signed (no stable Team ID — see
# build-app.sh), so every rebuild produces a different code-signature identity even
# though the binary is functionally identical. Its LaunchAgent is registered through
# SMAppService (`managed_by = com.apple.xpc.ServiceManagement` in `launchctl print`),
# not plain launchd, so a `launchctl bootout` against the bundled plist path is a
# no-op for it — it doesn't touch smd's registration. If Aro is still running when
# ditto below overwrites the on-disk binary, `open` just re-activates that already
# running process instead of launching a fresh one, so its `AroHubService` never
# re-runs its unregister/re-register recovery (`ensureCompatibleHelper`), which only
# happens at app launch — and the LaunchAgent is left registered against a code
# identity that no longer matches what's on disk. macOS's launch-constraint
# enforcement then SIGKILLs the helper on every respawn with "Code Signature
# Invalid" until the app is fully quit and relaunched (observed directly). Quitting
# it here first guarantees `open` below starts a genuinely fresh process, whose
# launch-time `ensureCompatibleHelper` call re-registers the helper against the new
# binary.
if pgrep -xq "Aro"; then
    osascript -e 'tell application "Aro" to quit' 2>/dev/null || true
    for _ in {1..40}; do
        pgrep -xq "Aro" || break
        sleep 0.25
    done
fi

mkdir -p "$applications_dir"
ditto "$source_app" "$installed_app"

print ""
print "Installed Aro in $installed_app"
print "Opening Aro…"
open "$installed_app"

if [[ -d "$legacy_app" ]]; then
    for _ in {1..60}; do
        [[ -f "$migration_marker" ]] && break
        sleep 0.5
    done
    if [[ -f "$migration_marker" ]]; then
        trash_name="Sonora-before-Aro-$(date -u +%Y%m%d%H%M%S).app"
        mkdir -p "$HOME/.Trash"
        mv "$legacy_app" "$HOME/.Trash/$trash_name"
        print "Moved the previous app to ~/.Trash/$trash_name"
    else
        print -u2 "Aro did not confirm migration; the previous app was kept."
    fi
fi
