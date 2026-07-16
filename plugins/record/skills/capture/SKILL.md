---
name: capture
description: Use when the user asks to record, start, stop, inspect status, list capturable Mac apps, run setup, or triage native macOS app capture through the installed record CLI.
---

# capture

Use `record capture` through this plugin. This skill is an adapter; if `record` is missing, direct the user to the Homebrew install command reported by the helper.

## Run Commands

Resolve the plugin root from this `SKILL.md` path, then invoke helpers by absolute path so the current working directory does not matter:

```bash
<plugin-root>/scripts/run-capture.sh start --app APP [--output DIR] [--width PX] [--height PX]
<plugin-root>/scripts/run-capture.sh stop
<plugin-root>/scripts/run-capture.sh status
<plugin-root>/scripts/run-capture.sh doctor
<plugin-root>/scripts/run-capture.sh setup
<plugin-root>/scripts/run-capture.sh apps
```

## Workflow

- Map record/start requests to `start --app APP`; ask for the app only when it cannot be inferred.
- Map stop, status, setup, doctor, and app-list requests to the corresponding helper command.
- Let `record capture` choose output and resolution defaults unless the user asks for a specific directory, size, or readability target.
- After a successful stop, report the final video path and metadata path when present.
- For failure triage, read `references/capture-workflow.md`.

## Privacy

Recordings, transcripts, metadata, and run output are sensitive local artifacts. Do not upload, paste, summarize, or move them unless the user explicitly asks.
