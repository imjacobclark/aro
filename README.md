# Sonora

Sonora is a native macOS music library and high-resolution audio player with
an optional authoritative LAN library hub. The macOS app discovers Sonora hubs
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

### Enable LAN library hosting

The hub helper is managed by macOS and needs a persistent server-data
directory before it can start:

1. Open **Sonora → Settings → Sync**.
2. Under **Host This Library**, click **Use Recommended Location**. This stores
   the hub database and cache in
   `~/Library/Application Support/Sonora/Hub Data`.
3. Turn on **Enable Sonora Hub**.
4. If Sonora reports **Approval required in Login Items**, open **System
   Settings → General → Login Items & Extensions** and allow Sonora.

The helper is embedded in `Sonora.app`; don’t move or delete the app after
enabling hosting. Installing it in `~/Applications` with the commands above
gives the helper a stable path across logins.

The server-data location cannot be inside `~/Desktop`, `~/Documents`, or
`~/Downloads`: macOS blocks background LaunchAgents from opening those
privacy-protected folders. This does not require moving your music library.
Server data is the hub’s private database/cache location; watched music sources
remain separate.

To pair another Mac, click **Open Pairing Window** on the host. On the other
Mac, choose the discovered hub, enter the displayed six-digit code, then click
**Pair…**. The request appears on the host; click **Approve** there to issue
that Mac its revocable credential. The code authenticates the hub with
SPAKE2+, and Sonora saves the TLS certificate pin automatically.

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
and [the server guide](server/README.md) for standalone hub configuration,
imports, pairing, verification, and Docker deployment.

## Development release automation

On every push to `main`, the Development Release workflow:

1. Builds Arm64 and Intel Swift apps in debug configuration.
2. Builds and embeds the optimized Rust sync helper.
3. Ad-hoc signs and verifies the complete app bundle.
4. Archives it with resource forks preserved.
5. Publishes a GitHub prerelease and SHA-256 checksum for that commit.

Production distribution will require a Developer ID Application certificate
and Apple notarization; the development workflow deliberately does not store
or require those credentials.
