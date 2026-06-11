---
name: transcribe
description: Use when the user asks to transcribe a local audio or video file, inspect transcription setup, or triage local whisper.cpp transcription through the installed transcribe CLI.
---

# transcribe

Use the installed local `transcribe` CLI through this plugin. This skill is an adapter; it does not install, vendor, or replace the CLI.

## Run Commands

Resolve the plugin root from this `SKILL.md` path, then invoke helpers by absolute path so the current working directory does not matter:

```bash
<plugin-root>/scripts/run-transcribe.sh --input PATH --output DIR [--copy-source|--move-source]
```

## Workflow

- Infer the input file from the user's request; ask only when no path or multiple plausible paths are present.
- Infer the output directory when the user gives one. Otherwise choose a sibling directory beside the source named from the source file stem plus `-transcript`.
- Leave the source file untouched unless the user explicitly asks to copy, include, bundle, move, or relocate it.
- Never pass both source handling flags.
- Report created artifact paths only after a successful run.
- For failure triage, read `references/transcription-workflow.md`.

## Privacy

Source media, recordings, transcripts, metadata, and run output are sensitive local artifacts. Do not upload, paste, summarize, or move them unless the user explicitly asks.
