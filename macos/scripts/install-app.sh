#!/bin/zsh

set -euo pipefail

project_dir=${0:A:h:h}
source_app="$project_dir/dist/Sonora.app"
applications_dir="$HOME/Applications"
installed_app="$applications_dir/Sonora.app"

"$project_dir/scripts/build-app.sh"

mkdir -p "$applications_dir"
ditto "$source_app" "$installed_app"

print ""
print "Installed Sonora in $installed_app"
print "Opening Sonora…"
open "$installed_app"
