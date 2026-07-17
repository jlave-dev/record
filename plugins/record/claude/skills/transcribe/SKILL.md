---
name: transcribe
description: Transcribe a local audio or video file or diagnose local whisper.cpp setup with the record CLI.
argument-hint: "[media-path]"
allowed-tools: Bash(record transcribe *)
---

# Transcribe

Run:

```bash
record transcribe --input PATH --output DIR [--copy-source|--move-source] --json
```

- Infer one readable input file from the request; ask only when none or several are plausible.
- Use the requested output directory, or a sibling `<source-stem>-transcript` directory.
- Leave the source untouched unless the user explicitly asks to copy or move it. Never pass both source flags.
- Report created artifact paths only after success.
- On failure, distinguish bad input from setup problems. Run `record transcribe doctor --json` for setup failures and suggest `record transcribe setup` only when the model is missing.
- Treat media, transcripts, metadata, and run output as sensitive. Do not inspect, upload, summarize, move, or delete them unless the user asks.
