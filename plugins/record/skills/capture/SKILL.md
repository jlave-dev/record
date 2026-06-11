---
name: capture
description: Use when the user asks to record, start, stop, pause, resume, inspect status, list capturable Mac apps, run setup, or triage OBS-backed macOS app capture with the installed capture CLI.
---

# capture

Use the installed local `capture` CLI through this plugin. This skill is an adapter; it does not install, vendor, or replace the CLI.

## Run Commands

Resolve the plugin root from this `SKILL.md` path, then invoke helpers by absolute path so the current working directory does not matter:

```bash
<plugin-root>/scripts/run-capture.sh start --app APP [--output DIR] [--width PX] [--height PX] [--video-bitrate KBPS]
<plugin-root>/scripts/run-capture.sh stop
<plugin-root>/scripts/run-capture.sh status
<plugin-root>/scripts/run-capture.sh pause
<plugin-root>/scripts/run-capture.sh resume
<plugin-root>/scripts/run-capture.sh doctor
<plugin-root>/scripts/run-capture.sh setup [--force] [--dry-run]
<plugin-root>/scripts/run-capture.sh apps
```

## Workflow

- Map record/start requests to `start --app APP`; ask for the app only when it cannot be inferred.
- Map stop, pause, resume, status, setup, doctor, and app-list requests to the corresponding helper command.
- Let `capture` choose output and resolution defaults unless the user asks for a specific directory, size, quality, or readability target.
- After a successful stop, report the final video path and metadata path when present.
- For failure triage, read `references/capture-workflow.md`.

## Privacy

Recordings, transcripts, metadata, and run output are sensitive local artifacts. Do not upload, paste, summarize, or move them unless the user explicitly asks.
