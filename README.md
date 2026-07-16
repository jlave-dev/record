# record

Native macOS app capture and local transcription for humans and Codex.

The installed product is one command with two runtime surfaces:

```bash
record capture start --app chrome
record capture stop
record transcribe --input /path/to/recording.mp4 --output /path/to/transcript
```

Capture uses ScreenCaptureKit and application audio. Transcription uses local whisper.cpp. Recordings, source media, transcripts, metadata, configuration, and runtime state stay on the local machine by default.

> [!IMPORTANT]
> You are responsible for making sure each recording is legal and allowed by applicable consent laws and workplace, school, client, meeting, and platform policies.

## Install

Install the latest release:

```bash
brew install jlave-dev/tap/record
record plugin install
```

Homebrew installs the `record` command plus `ffmpeg` and `whisper-cpp`. The release contains a self-contained transcription executable and a signed `CaptureAgent.app`; users do not need Node.js, npm, Swift, or Xcode.

Requirements:

- macOS 15 or newer.
- Apple silicon.
- Screen & System Audio Recording permission for CaptureAgent.
- About 1.6 GB of free space for the default Whisper model.

The first capture may require:

```bash
record capture setup
```

The first transcription downloads and verifies the default model:

```bash
record transcribe setup
```

## Capture

```bash
record capture apps
record capture start --app firefox --json
record capture status --json
record capture stop --json
record capture doctor --json
```

Defaults:

- Output root: `~/Movies/capture`.
- Source resolution capped at `2560x1440` unless overridden.
- H.264 video and application-level AAC audio in MP4.
- Metadata beside each recording.
- Runtime state under `~/.local/share/capture-native`.

The target app must be running with a visible shareable window when capture starts. App values may be friendly aliases, app names, bundle identifiers, or `.app` paths.
When Zoom shares local content, capture automatically follows the shared window or display with audio and returns to the Zoom windows when sharing stops.

## Transcribe

```bash
record transcribe doctor --json
record transcribe setup
record transcribe \
  --input /path/to/recording.mp4 \
  --output /path/to/recording-transcript
```

Successful runs write:

- `transcript.txt`
- `transcript.json`
- `metadata.json`

Defaults:

- Engine: `whisper-cli`.
- Model: `~/.local/share/transcribe/models/ggml-large-v3-turbo.bin`.
- Config: `$XDG_CONFIG_HOME/transcribe/config.toml` or `~/.config/transcribe/config.toml`.

The model download is written through a temporary file and verified by byte size and SHA-256 before installation.

## Codex Plugin

The marketplace lives at `.agents/plugins/marketplace.json`. The Homebrew release also carries a matching local marketplace so CLI and plugin versions cannot drift.

Install the bundled plugin with:

```bash
record plugin install
```

Then start a new Codex task. The plugin exposes:

- `$capture`
- `$transcribe`

The skills are thin adapters around `record capture` and `record transcribe`.

## Development

Development requirements:

- Node.js 22 or newer.
- Bun for the self-contained transcription build.
- Xcode Command Line Tools.
- Homebrew with `ffmpeg` and `whisper-cpp` for live transcription tests.

```bash
npm install
npm run build:bundle
npm run build:binary:macos-arm64
npm run test:record
npm run plugin:smoke
```

Install a development build locally:

```bash
npm run install:local
record doctor
```

Package-specific development remains available:

```bash
npm --workspace capture run capture -- --help
npm --workspace transcribe run transcribe -- --help
```

## Release

```bash
npm run build:release:macos-arm64
```

This creates `dist/release/record-<version>-macos-arm64.tar.gz`. Local archives use the available development signing identity and are not publishable.

Releases from `main` use semantic-release and Conventional Commits to choose the next version. The macOS arm64 release job then:

1. Updates the workspace, CLI, plugin, and Formula versions.
2. Signs CaptureAgent, capture, and transcribe with Developer ID and hardened runtime.
3. Notarizes the assembled bundle and staples the CaptureAgent ticket.
4. Builds the final archive and writes its SHA-256 to `Formula/record.rb`.
5. Commits the generated versions and Formula checksum with `[skip ci]`.
6. Creates the Git tag and GitHub release with the exact Homebrew archive.
7. Updates `Formula/record.rb` in `jlave-dev/homebrew-tap`.

The first automated run locally seeds the original repository commit as the `v0.1.0` baseline, so the native capture feature releases as `v0.2.0` instead of semantic-release's default first version of `v1.0.0`. Later runs use the published tags normally.

The repository needs these GitHub Actions secrets:

- `APPLE_DEVELOPER_ID_CERTIFICATE_P12`: base64-encoded Developer ID Application certificate and private key.
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`: password used when exporting that P12.
- `APPLE_NOTARIZATION_KEY_P8`: base64-encoded App Store Connect team API key.
- `APPLE_NOTARIZATION_KEY_ID`: API key ID.
- `APPLE_NOTARIZATION_ISSUER_ID`: API issuer ID.
- `HOMEBREW_TAP_DEPLOY_KEY`: write-enabled deploy key for `jlave-dev/homebrew-tap`.

Use `npm run release:dry-run` to inspect the next semantic version without publishing. A public release intentionally fails rather than falling back to development signing or skipping notarization.

## Sensitive Artifacts

Do not commit recordings, transcripts, real source media, runtime output, local configuration, dependencies, or build output.

## License

MIT. See [LICENSE](LICENSE).
