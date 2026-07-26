# Sonora

Sonora is a native macOS music library and high-resolution audio player with
optional authoritative LAN library sharing. The macOS app discovers other Sonoras
with Bonjour, pairs using a six-digit authenticated code, automatically pins
TLS, and synchronizes logical library records and verified media without
sharing live SQLite files.

## Download a development build

Every commit pushed to `main` creates a sequential pre-1.0 semantic version
with Arm64 and Intel ad-hoc-signed builds on the
[GitHub Releases page](https://github.com/imjacobclark/sonora/releases).
Download the `Sonora-v0.0.<number>-macos-arm64.zip` file for Apple Silicon or
the `Sonora-v0.0.<number>-macos-x86_64.zip` file for an Intel Mac. Then run
the following commands from the download directory:

```sh
ditto -x -k Sonora-v*-macos-*.zip .
xattr -dr com.apple.quarantine Sonora.app
codesign --force --sign - --timestamp=none \
  --identifier com.imjacobclark.sonora.server \
  Sonora.app/Contents/MacOS/sonora-server
codesign --force --deep --sign - --timestamp=none \
  --preserve-metadata=identifier Sonora.app
mkdir -p "$HOME/Applications"
ditto Sonora.app "$HOME/Applications/Sonora.app"
open "$HOME/Applications/Sonora.app"
```

The local `codesign` command intentionally applies an ad-hoc development
signature after download. These automated builds are not Apple-notarized;
do not bypass quarantine for builds from an untrusted source. Sonora currently
requires macOS 26 or later.

To confirm the downloaded bundle before opening it:

```sh
codesign --verify --deep --strict --verbose=2 \
  "$HOME/Applications/Sonora.app"
codesign --verify --strict \
  --test-requirement '=identifier "com.imjacobclark.sonora.server"' \
  "$HOME/Applications/Sonora.app/Contents/MacOS/sonora-server"
```

### Share a library with other devices

1. Open **Devices** in Sonora’s main sidebar.
2. Choose **Create a Library** if this is a new installation, or select
   **Enable Sharing** for a library already stored on this Mac.
3. Select **Add Device**. Scan the QR code from the other device or enter the
   six-digit connection code, then approve the named device.
4. If Sonora reports **Approval required in Login Items**, open **System
   Settings → General → Login Items & Extensions** and allow Sonora.

The Background Service is embedded in `Sonora.app`; don’t move or delete the app after
enabling hosting. Installing it in `~/Applications` with the commands above
gives the Background Service a stable path across logins.

Sonora’s private sharing-data location cannot be inside `~/Desktop`, `~/Documents`, or
`~/Downloads`: macOS blocks background LaunchAgents from opening those
privacy-protected folders. This does not require moving your music library.
Network addresses, ports, process state, logs, and storage maintenance remain
available under **Settings → Devices** for diagnostics.

### Library and file lifecycle

Sonora presents two library behaviours:

- **Stored by Sonora** keeps a byte-identical Sonora copy of every imported or
  contributed audio file. Original watched folders remain the user’s files:
  Sonora never edits or deletes them. If one goes offline, Sonora reports the
  missing source but continues serving its stored copy.
- **Linked files** indexes audio in place without duplicating it. It is
  read-only for device contributions and requires the linked storage to remain
  online.

Newly paired devices can play by default. A library owner must explicitly grant
**Can add music** before that device may upload tracks. Every upload and
download preserves the original bytes and SHA-256 identity; Sonora does not
transcode, retag, recompress, or change the file extension.

**Remove from Sonora** removes the logical track but never deletes an original
file. A stored Sonora copy remains recoverable for 30 days, after which
unreferenced storage can be reclaimed. **Export Entire Library** writes active
tracks to `sonora-library/<Artist>/<Album>/…`, recoverable removed tracks to
`_Recently Removed`, and includes a JSON manifest. Interrupted exports resume,
matching files are skipped by SHA-256, and conflicting files are not
overwritten.

## Build and launch from source

Install the current Xcode Command Line Tools and Rust, then clone and build:

```sh
git clone git@github.com:imjacobclark/sonora.git
cd sonora
make server doctor
make check
make macos app
xattr -dr com.apple.quarantine macos/dist/Sonora.app
open macos/dist/Sonora.app
```

To build, install, and launch the app in the user Applications directory:

```sh
make macos install
open "$HOME/Applications/Sonora.app"
```

Useful development commands:

```sh
make all build
make all test
make server run
make server package
```

See [the macOS guide](macos/README.md) for playback and architecture details,
and [the server guide](server/README.md) for standalone hosting configuration,
imports, pairing, verification, and Docker deployment.

## Development release automation

On every push to `main`, the Development Release workflow:

1. Builds Arm64 and Intel Swift apps in debug configuration.
2. Builds and embeds the optimized Rust Background Service.
3. Ad-hoc signs and verifies the complete app bundle.
4. Archives it with resource forks preserved.
5. Publishes a GitHub prerelease and SHA-256 checksum for that commit.

Production distribution will require a Developer ID Application certificate
and Apple notarization; the development workflow deliberately does not store
or require those credentials.
