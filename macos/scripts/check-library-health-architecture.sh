#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h:h}
common_feature="$repository_root/common/Sources/AroCommon/LibraryHealth/LibraryHealthFeature.swift"
macos_context="$repository_root/macos/Sources/Aro/LibraryHealth"

required_files=(
  "$common_feature"
  "$macos_context/Infrastructure/Mappers/LibraryHealthTrackMapper.swift"
  "$macos_context/Infrastructure/Queries/SQLiteLibraryHealthTrackQuery.swift"
  "$macos_context/Interface/UI/LibraryHealthView.swift"
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    print -u2 "Missing architectural boundary file: $required_file"
    exit 1
  fi
done

if rg -n \
  'import (SwiftUI|AppKit|SQLite3|SFBAudioEngine)' \
  "$common_feature"; then
  print -u2 "Common Library Health imports an outward framework."
  exit 1
fi

if rg -n \
  'LibraryDatabase|SQLiteLibraryHealth|sqlite3' \
  "$common_feature" \
  "$macos_context/Interface"; then
  print -u2 "The common feature or its interface accesses concrete persistence."
  exit 1
fi

if rg -n \
  'LibraryHealthAnalyzer' \
  "$macos_context/Infrastructure"; then
  print -u2 "Infrastructure is making a Library Health business decision."
  exit 1
fi

if rg -n \
  'SwiftUI|AppKit' \
  "$macos_context/Infrastructure"; then
  print -u2 "Infrastructure imports a presentation framework."
  exit 1
fi

print "Library Health architecture checks passed"
