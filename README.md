# record

Native macOS app capture and local transcription for humans, Codex, and Claude Code.

The installed product is one command with three runtime surfaces:

```bash
record capture start --app chrome
record capture stop
record transcribe --input /path/to/recording.mp4 --output /path/to/transcript
record live start --app zoom
```

Capture uses ScreenCaptureKit and application audio. Batch transcription uses local whisper.cpp. Live transcription uses the open-source FluidAudio runtime and local models. Recordings, source media, transcripts, metadata, configuration, and runtime state stay on the local machine by default.

> [!IMPORTANT]
> You are responsible for making sure each recording is legal and allowed by applicable consent laws and workplace, school, client, meeting, and platform policies.

## Install

Install the latest release:

```bash
brew install jlave-dev/tap/record
```

Homebrew installs the `record` command plus `ffmpeg` and `whisper-cpp`. The release contains a self-contained transcription executable and a signed `CaptureAgent.app`; users do not need Node.js, npm, Swift, or Xcode.
Agent plugins are optional; see [Agent Plugins](#agent-plugins) to install the Codex or Claude Code integration.

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

Prepare the local live model before the first meeting:

```bash
record live setup
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

## Live transcription

```bash
record live setup
record live start --app zoom --json
record live next --after 0 --timeout 20 --json
record live status --json
record live stop --json
```

`start` records the selected app normally while a separate worker receives 16 kHz mono application-audio frames. It emits local JSONL events at `live-transcript.jsonl`; committed transcript events include an ordered cursor, source-audio timestamp, delivery latency, and commit reason. Native end-of-utterance is used when available, with stable-partial and maximum-utterance fallbacks so continuous meeting audio cannot stall the stream.

`next` returns committed events only. Pass its `next_cursor` into the following call. This cursor contract lets either agent plugin maintain rolling context and surface questions without sending unstable partial hypotheses to the model. Microphone capture and speaker diarization are not included in this first release.

## Agent Plugins

The repository contains marketplaces for Codex at `.agents/plugins/marketplace.json` and Claude Code at `.claude-plugin/marketplace.json`. The Homebrew release carries matching local marketplaces.

The corresponding agent CLI must already be on `PATH`. Install one plugin:

```bash
record plugin install --codex
record plugin install --claude
```

If both CLIs are installed, install both together:

```bash
record plugin install
```

Record remembers only successfully installed hosts. After a Homebrew upgrade, the first `capture`, `transcribe`, `live`, `doctor`, or `setup` command refreshes stale Record plugins automatically. A plugin removed through its agent CLI is not reinstalled.

Then start a new Codex task or Claude Code session. Both plugins expose the same three skills:

- Codex: `$capture`, `$transcribe`, and `$live`
- Claude Code: `/record:capture`, `/record:transcribe`, and `/record:live`

The live skills poll the same cursor API and require timestamp grounding, final-only evidence, semantic debouncing, and local-artifact privacy. Codex CLI is the semantic E2E test provider; Claude Code is covered by strict plugin validation and the shared adapter contract test.

## Development

Development requirements:

- Node.js 22 or newer.
- Bun for the self-contained transcription build.
- Xcode Command Line Tools.
- Homebrew with `ffmpeg` and `whisper-cpp` for live transcription tests.
- Codex and Claude Code for full plugin validation.

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
record-dev doctor
```

Package-specific development remains available:

```bash
npm --workspace capture run capture -- --help
npm --workspace transcribe run transcribe -- --help
npm --workspace live run build
npm --workspace live run test:prerecorded -- /path/to/meeting.mp4 30
```

## Release

```bash
npm run build:release:macos-arm64
```

This creates `dist/release/record-<version>-macos-arm64.tar.gz`. Local archives use the available development signing identity and are not publishable.

Releases from `main` use semantic-release and Conventional Commits to choose the next version. The macOS arm64 release job then:

1. Updates the workspace, CLI, both plugin manifests, and Formula versions.
2. Signs CaptureAgent, capture, transcribe, live, and live-worker with Developer ID and hardened runtime.
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
