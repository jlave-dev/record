# record Plugins

This payload packages Codex and Claude Code adapter skills for the Homebrew-installed `record` CLI:

- `capture`: run `record capture` for ScreenCaptureKit Mac app recording.
- `transcribe`: run `record transcribe` for local whisper.cpp transcription.
- `live`: stream app audio through local transcription so the active agent can surface timestamp-grounded context and questions.

The plugins do not install native dependencies. Install the CLI first:

## Setup

```bash
brew install jlave-dev/tap/record
record plugin install --codex
record plugin install --claude
```

Use `record plugin install` without a flag when both agent CLIs are installed. Record tracks successfully installed hosts and refreshes stale plugins automatically on the first runtime command after a CLI upgrade.

## Skill Surface

Do not add a top-level `record` skill. Each host exposes the same three task surfaces:

- Codex loads `$capture`, `$transcribe`, and `$live` from `skills/`; its helpers can run from any working directory.
- Claude Code loads `/record:capture`, `/record:transcribe`, and `/record:live` from `claude/skills/` and invokes the same public CLI contract.

## Validation

```bash
python3 "$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py" plugins/record/skills/capture
python3 "$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py" plugins/record/skills/transcribe
python3 "$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py" plugins/record/skills/live
python3 "$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py" plugins/record
claude plugin validate --strict plugins/record/claude
claude plugin validate --strict .
npm run test:record
plugins/record/scripts/smoke-test.sh
plugins/record/scripts/test-live-adapters.sh
```

The smoke test validates both plugin formats, skills, helper executability, missing-binary failures, missing input handling, conflicting source flags, and the shared live cursor/grounding/privacy contract. The CLI test covers default and selective installs, automatic refresh, migration, and manual uninstall handling.

## Privacy

Recordings, source media, transcripts, metadata, configuration, and run output stay local to the machine by default. Agents must not upload, paste, summarize, move, or delete those artifacts unless the user explicitly asks.

## Terms

These plugins are local adapters around the user-installed `record` command. They provide no hosted service and do not change the setup, licensing, or operating requirements of ScreenCaptureKit, whisper.cpp, or local models.
