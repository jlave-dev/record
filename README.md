# record

Local macOS capture and transcription tooling for agent workflows.

`record` is an npm workspace with two independent CLIs:

- `capture` records one visible macOS application through OBS Studio.
- `transcribe` converts a local audio or video file into transcript artifacts with local whisper.cpp.

The tools are often used together, but they stay separate. There is no top-level `record` executable. Recordings, source media, transcripts, metadata, configuration, and runtime state stay on the local machine by default.

## Requirements

- macOS.
- Node.js 22 or newer.
- OBS Studio installed in `/Applications`.
- OBS WebSocket enabled on port `4455`; `capture setup` writes the local OBS WebSocket config.
- Homebrew for `transcribe setup`.
- `ffmpeg`, `ffprobe`, and `whisper-cli`; `transcribe setup` installs `whisper-cpp` with Homebrew when needed.
- `~/.local/bin` on `PATH` if you want to use the installed `capture` and `transcribe` launchers directly.

## Quick Start

```bash
npm install
npm run setup
npm run doctor
```

`npm run setup` builds both packages, configures local defaults, installs launchers into `~/.local/bin`, and runs package doctors. If OBS is open while setup updates its profile, scene collection, or WebSocket config, restart OBS before running `capture doctor`.

Record an app, then transcribe the resulting video:

```bash
capture start --app chrome
# use the app while OBS records it
capture stop

transcribe --input ~/Movies/capture/<run>/recording.mp4 --output ~/Movies/capture/<run>/transcript
```

Use the `output_path` returned by `capture stop` for the real recording path; OBS names the final media file.

## Capture CLI

`capture` records a selected Mac app through a dedicated OBS profile and scene collection.

Common commands:

```bash
capture setup
capture doctor
capture apps
capture config --json
capture config set video_bitrate 6000
capture start --app firefox --json
capture status --json
capture pause
capture resume
capture stop --json
```

App values can be friendly aliases, installed app names, bundle identifiers, or `.app` paths. Built-in aliases include `chrome`, `firefox`, and `zoom`.

Defaults:

- Output root: `~/Movies/capture`.
- Video size: `1920x1080`.
- Video bitrate: `6000` kbps.
- Capture mode: macOS application capture.
- Metadata: `metadata.json` beside each recording.
- Runtime state: `~/.local/share/capture/state.json`.
- Config: `$XDG_CONFIG_HOME/capture/config.toml` or `~/.config/capture/config.toml`.

Useful start options:

```bash
capture start \
  --app chrome \
  --output ~/Movies/capture/chrome-test \
  --width 1920 \
  --height 1080 \
  --video-bitrate 6000
```

The target app must have a visible capturable window when recording starts. Once OBS has the application source, you can switch focus to another app while capture continues.

## Transcribe CLI

`transcribe` turns a local audio or video file into local transcript artifacts.

Common commands:

```bash
transcribe setup
transcribe doctor
transcribe config --json
transcribe --input /path/to/recording.mp4 --output /path/to/recording-transcript
transcribe --input /path/to/recording.mp4 --output /path/to/recording-transcript --copy-source
```

Successful runs write:

- `transcript.txt`
- `transcript.json`
- `metadata.json`

Defaults:

- Whisper command: `whisper-cli`.
- Model: `~/.local/share/transcribe/models/ggml-large-v3-turbo.bin`.
- Config: `$XDG_CONFIG_HOME/transcribe/config.toml` or `~/.config/transcribe/config.toml`.

The default model is downloaded with a temporary file and validated by byte size before it is installed. `transcribe doctor` reports missing tools, unreadable models, and partial model downloads.

## Agent Plugin

The local Codex plugin lives in [`plugins/record`](plugins/record). It packages two adapter skills:

- `$capture` wraps the installed `capture` CLI.
- `$transcribe` wraps the installed `transcribe` CLI.

The plugin does not install or replace the runtime CLIs. Install the CLIs first with:

```bash
npm run setup
```

Validate the plugin adapter with:

```bash
npm run plugin:smoke
```

## Development

Build both packages:

```bash
npm run build:bundle
```

Run package CLIs from the workspace:

```bash
npm --workspace capture run capture -- --help
npm --workspace transcribe run transcribe -- --help
```

Create local launchers:

```bash
npm run install:local
```

Create Node-backed macOS arm64 launcher artifacts:

```bash
npm run build:binary:macos-arm64
```

Run the combined environment check:

```bash
npm run doctor
```

## Troubleshooting

`capture doctor` fails on OBS connectivity:

- Open or restart OBS after `capture setup`.
- Confirm OBS WebSocket is enabled on port `4455`.
- Check macOS Screen Recording permissions for OBS.

`capture start` says the app has no visible capturable window:

- Open the app and make sure at least one non-minimized window is visible.
- Run `capture apps --json` to confirm how the app resolves.

`transcribe doctor` reports a missing or partial model:

- Run `transcribe setup --force`.
- Confirm there is enough disk space for the `ggml-large-v3-turbo.bin` model.

`capture` or `transcribe` is not found after setup:

- Add `~/.local/bin` to `PATH`, or run through npm with `npm --workspace <package> run <command> -- ...`.

## Sensitive Artifacts

Generated media and transcripts are sensitive by default. The repository ignores dependencies, build output, recordings, transcripts, local run output, media files, environment files, and local config directories.

Do not commit:

- recordings or source media
- transcripts or metadata from real runs
- local config, secrets, or environment files
- `dist/`, `node_modules/`, or other generated output

## Support

Use GitHub issues for bugs and setup problems: [jlave-dev/record](https://github.com/jlave-dev/record/issues).

## License

The packages and plugin metadata declare MIT licensing. Add a root `LICENSE` file before publishing outside this repository.
