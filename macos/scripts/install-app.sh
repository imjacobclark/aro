#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
source_app="$project_dir/dist/Aro.app"
applications_dir="$HOME/Applications"
installed_app="$applications_dir/Aro.app"
legacy_app="$applications_dir/Sonora.app"
migration_marker="$HOME/Library/Application Support/Aro/.aro-brand-migration-v1"

"$project_dir/scripts/build-app.sh"

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
