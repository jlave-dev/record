# record Plugin

This plugin packages two adapter skills for the Homebrew-installed `record` CLI:

- `capture`: run `record capture` for ScreenCaptureKit Mac app recording.
- `transcribe`: run `record transcribe` for local whisper.cpp transcription.

The plugin does not install native dependencies. Install the CLI first:

## Setup

```bash
brew tap jlave-dev/record https://github.com/jlave-dev/record.git
brew install jlave-dev/record/record
record plugin install
```

The Homebrew release bundles this plugin and installs the matching version through `record plugin install`. The helper scripts can be invoked from any working directory when called by path.

## Skill Surface

Do not add a top-level `record` skill. The plugin exposes the two task surfaces, while the CLI uses `record capture` and `record transcribe`.

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

This plugin is a local adapter around the user-installed `record` command. It provides no hosted service and does not change the setup, licensing, or operating requirements of ScreenCaptureKit, whisper.cpp, or local models.
