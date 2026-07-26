#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
cd "$repository_root"

common_root="common/Sources/SonoraCommon"
macos_root="macos/Sources/Sonora"

fail() {
    echo "Architecture check failed: $1" >&2
    exit 1
}

test -f "common/Package.swift" || fail "Missing common Swift package."
test -f "macos/Package.swift" || fail "Missing macOS Swift package."
test ! -f "Package.swift" || fail "The repository root must orchestrate packages, not own one."

grep -q '\.package(path: "../common")' "macos/Package.swift" \
    || fail "The macOS package must depend on ../common."

if find "$common_root" -maxdepth 1 -name '*.swift' -print | grep -q .; then
    fail "Common Swift sources must live in an owning capability."
fi

for directory in AudioAnalysis Library LibraryHealth Playback Stats; do
    test -d "$common_root/$directory" \
        || fail "Missing common capability directory: $directory"
done

for directory in \
    App \
    AudioAnalysis \
    DesignSystem \
    Library \
    LibraryHealth \
    Playback \
    Settings \
    Shared \
    Stats
do
    test -d "$macos_root/$directory" \
        || fail "Missing macOS capability directory: $directory"
done

if grep -R -En --include='*.swift' \
    '^import (SwiftUI|AppKit|Charts|SQLite3|CoreAudio|AVFAudio|AVFoundation|SFBAudioEngine|CoreServices|CoreText|UniformTypeIdentifiers)$' \
    "$common_root"
then
    fail "Common code imports a platform UI, persistence, filesystem, or audio framework."
fi

if grep -R -En --include='*.swift' \
    '#if[[:space:]]+os\(macOS\)|@available\(macOS' \
    "$common_root"
then
    fail "Common code contains a macOS-specific compilation branch."
fi

domain_files=$(find "$macos_root" -path '*/Domain/*.swift' -type f -print)
if test -n "$domain_files" && grep -En \
    '^import (SwiftUI|AppKit|SQLite3|CoreAudio|AVFAudio|AVFoundation|SFBAudioEngine)' \
    $domain_files
then
    fail "macOS domain code imports a UI, persistence, or hardware framework."
fi

application_files=$(find "$macos_root" -path '*/Application/*.swift' -type f -print)
if test -n "$application_files" && grep -En \
    '^import (SwiftUI|AppKit|SQLite3|CoreAudio|AVFAudio|AVFoundation|SFBAudioEngine)' \
    $application_files
then
    fail "macOS application code imports a UI, persistence, or hardware framework."
fi

interface_files=$(find "$macos_root" -path '*/Interface/*.swift' -type f -print)
if test -n "$interface_files" && grep -En \
    '^import (SQLite3|CoreAudio|AVFAudio|AVFoundation|SFBAudioEngine)' \
    $interface_files
then
    fail "macOS interface code imports persistence or audio hardware frameworks."
fi

if test -n "$interface_files" && grep -En \
    'LibraryDatabase|sqlite3_' \
    $interface_files
then
    fail "Interface code reaches directly into SQLite persistence."
fi

if grep -R -n --include='*.swift' \
    'LibraryDatabase\.shared\|= \.shared' "$macos_root"
then
    fail "A global database singleton remains."
fi

if grep -R -n --include='*.swift' \
    'LibraryDatabase(' "$macos_root" \
    | grep -v '/App/Composition/'
then
    fail "The SQLite database is constructed outside the composition root."
fi

echo "Repository architecture checks passed"
