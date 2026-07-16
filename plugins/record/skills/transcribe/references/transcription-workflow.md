# Transcription Workflow

## Adapter Boundary

The plugin wraps `record transcribe`. If the CLI is missing, tell the user to run:

```bash
brew install jlave-dev/tap/record
```

## Transcribe

1. Resolve exactly one readable local audio or video input path.
2. Choose an output directory from the user request, or default to a sibling directory named `<source-stem>-transcript`.
3. Run:

```bash
<plugin-root>/scripts/run-transcribe.sh --input PATH --output DIR
```

Only pass `--copy-source` or `--move-source` when the user explicitly asks. Never pass both.

## Failure Triage

When transcription fails, triage in this order:

1. If the input is missing or unreadable, ask for a readable local file path and do not run setup.
2. Run `record transcribe doctor --json` for setup-like failures.
3. Distinguish missing model setup from bad input. For missing setup, suggest `record transcribe setup`.

Report transcript artifact paths only after success. Do not inspect, summarize, upload, or move source media or transcript files unless the user asks.
