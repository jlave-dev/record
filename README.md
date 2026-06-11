# record

Local macOS tooling for two independent command line products:

- `capture`: record one visible macOS application through OBS Studio.
- `transcribe`: transcribe a local audio or video file with local whisper.cpp.

The tools are commonly used together, but there is no top-level `record` executable. Recordings, transcripts, metadata, configuration, and runtime state stay local to the machine.

## Workspace Commands

Requires Node.js 22 or newer.

```bash
npm install
npm run setup:capture
npm run setup:transcribe
npm run setup
npm run build:bundle
npm run build:binary:macos-arm64
npm run doctor
npm run install:local
```

Development examples:

```bash
npm --workspace capture run capture -- --help
npm --workspace transcribe run transcribe -- --help
```

## Capture

```bash
capture setup
capture doctor
capture apps
capture start --app firefox
capture status
capture pause
capture resume
capture stop
```

Default recordings are written under `~/Movies/capture/<timestamp>-<app>/`. Each run writes `metadata.json` when recording begins and updates it when recording stops.

Capture config lives at `$XDG_CONFIG_HOME/capture/config.toml` or `~/.config/capture/config.toml`. Runtime state lives at `~/.local/share/capture/state.json`.

## Transcribe

```bash
transcribe setup
transcribe doctor
transcribe --input /path/to/recording.mp4 --output /path/to/recording-transcript
transcribe --input /path/to/recording.mp4 --output /path/to/recording-transcript --copy-source
```

Successful runs write:

- `transcript.txt`
- `transcript.json`
- `metadata.json`

Transcribe config lives at `$XDG_CONFIG_HOME/transcribe/config.toml` or `~/.config/transcribe/config.toml`. The default model path is under `~/.local/share/transcribe/models/`.

## Agent Plugin

The local plugin surface lives in `plugins/record` and packages separate `capture` and `transcribe` skills plus helper scripts. The plugin assumes the corresponding CLI has already been installed on the same Mac.

Validate the plugin adapter with:

```bash
plugins/record/scripts/smoke-test.sh
```

## Sensitive Artifacts

Recordings, source media, transcripts, metadata, local output, config, secrets, dependencies, and build artifacts are ignored by default and should be treated as sensitive local data.
