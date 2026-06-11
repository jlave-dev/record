# Capture Workflow

## Adapter Boundary

The plugin wraps the installed `capture` binary. It must not vendor runtime code or add a top-level `record` command. If the binary is missing, tell the user to run:

```bash
npm run setup:capture
```

## Start

1. Infer a visible Mac app name from the request.
2. If the app is unclear, ask for the target app.
3. Run:

```bash
<plugin-root>/scripts/run-capture.sh start --app APP
```

Only pass `--output`, `--width`, `--height`, or `--video-bitrate` when the user asks for them.

## Stop And Report

Run:

```bash
<plugin-root>/scripts/run-capture.sh stop
```

After success, report the recording path and metadata path when the CLI returns them. Do not inspect, summarize, upload, or move the artifacts unless the user asks.

## Failure Triage

When capture fails, triage in this order:

1. Run `capture doctor --json`.
2. For app resolution failures, run `capture apps --json`.
3. Only after those checks, suggest setup or restart steps such as `npm run setup:capture`, relaunching OBS, or checking macOS permissions.

Treat missing OBS, inactive OBS WebSocket, and macOS permission problems as environment checks. Report them plainly with the next command to run.
