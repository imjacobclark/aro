#!/bin/sh
set -eu

matches=$(
    git grep -n -i 'sonora' -- \
        . \
        ':(exclude)clients/macos/Sources/Aro/App/Composition/LegacyProductMigration.swift' \
        ':(exclude)clients/macos/Tests/AroTests/Persistence/LegacyProductMigrationTests.swift' \
        ':(exclude)clients/macos/scripts/install-app.sh' \
        ':(exclude)scripts/check-legacy-brand.sh' \
        ':(exclude)README.md' \
        || true
)

if [ -n "$matches" ]; then
    printf '%s\n' "Legacy product name found outside migration/history files:" >&2
    printf '%s\n' "$matches" >&2
    exit 1
fi

printf '%s\n' "Legacy product-name audit passed."
