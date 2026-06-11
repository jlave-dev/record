# record Plugin

This plugin packages two local adapter skills for agents:

- `capture`: operate the installed `capture` CLI for OBS-backed Mac app recording.
- `transcribe`: operate the installed `transcribe` CLI for local whisper.cpp transcription.

It does not install, vendor, or replace the runtime CLIs. The `capture` and `transcribe` binaries must already be installed on the same Mac and available on `PATH`.

## Setup

```bash
npm run setup:capture
npm run setup:transcribe
```

The helper scripts live in `plugins/record/scripts` and can be invoked from any working directory when called by path.

## Skill Surface

Do not add a top-level `record` skill. The plugin should expose the two real product surfaces: `capture` and `transcribe`.

## Validation

```bash
python3 "$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py" plugins/record/skills/capture
python3 "$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py" plugins/record/skills/transcribe
python3 "$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py" plugins/record
plugins/record/scripts/smoke-test.sh
```

The smoke test checks manifest validation, skill validation, helper executability, missing-binary failures, missing input handling, and conflicting source flags.

## Privacy

Recordings, source media, transcripts, metadata, configuration, and run output stay local to the machine by default. Agents must not upload, paste, summarize, move, or delete those artifacts unless the user explicitly asks.

## Terms

This plugin is a local adapter around user-installed command line tools. It provides no hosted service and does not change the setup, licensing, or operating requirements of `capture`, `transcribe`, OBS Studio, whisper.cpp, or local models.
