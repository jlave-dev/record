# Capture Workflow

## Adapter Boundary

The plugin wraps `record capture`. If the CLI is missing, tell the user to run:

```bash
brew install jlave-dev/tap/record
```

## Start

1. Infer a visible Mac app name from the request.
2. If the app is unclear, ask for the target app.
3. Run:

```bash
<plugin-root>/scripts/run-capture.sh start --app APP
```

Only pass `--output`, `--width`, or `--height` when the user asks for them.

## Stop And Report

Run:

```bash
<plugin-root>/scripts/run-capture.sh stop
```

After success, report the recording path and metadata path when the CLI returns them. Do not inspect, summarize, upload, or move the artifacts unless the user asks.

## Failure Triage

When capture fails, triage in this order:

1. Run `record capture doctor --json`.
2. For app resolution failures, run `record capture apps --json`.
3. Only after those checks, suggest `record capture setup` or enabling Screen & System Audio Recording permission for CaptureAgent.

Treat missing macOS permission as an environment check. Report it plainly with the next command to run.
