---
name: capture
description: Record, stop, inspect, set up, or list capturable Mac apps with the local record CLI. Use for native macOS app and Zoom meeting capture requests.
argument-hint: "[start APP|stop|status|apps|doctor|setup]"
allowed-tools: Bash(record capture *)
---

# Capture

Use `record capture` and request JSON output:

```bash
record capture start --app APP [--output DIR] [--width PX] [--height PX] --json
record capture stop --json
record capture status --json
record capture doctor --json
record capture setup --json
record capture apps --json
```

- Infer the app from the request; ask only when it is ambiguous.
- Let the CLI choose output and resolution defaults unless the user asks otherwise.
- After stopping, report the video and metadata paths returned by the CLI.
- On failure, run `record capture doctor --json`; for app resolution failures also run `record capture apps --json`. Suggest setup or macOS Screen & System Audio Recording permission only after those checks.
- Treat recordings, transcripts, metadata, and run output as sensitive. Do not inspect, upload, summarize, move, or delete them unless the user asks.
