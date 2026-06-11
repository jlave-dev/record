# AGENTS.md

## Git Workflow

Use Conventional Commits for commit messages:

```text
<type>[optional scope]: <description>
```

Use Conventional Commit-style prefixes for branch names:

```text
<type>/<scope-or-short-description>
```

Prefer these scopes when they fit: `capture`, `transcribe`, `record-plugin`, `deps`, `build`, `ci`, and `docs`. Use short, lowercase, hyphen-separated branch names.

Examples:

```bash
feat/capture-window-selection
fix/transcribe-missing-model
docs/record-plugin-validation
feat(capture): add window selection
fix(transcribe): report missing model setup
docs(record-plugin): document smoke validation
```

Never include `codex` in branch names or commit messages.

## Software Defaults

Prefer TypeScript when creating new general-purpose software. When the software has special requirements, use the best tool for the job, even if that is a different language.

## Project Context

This is an npm workspace monorepo with two independent TypeScript CLIs: `packages/capture` for OBS-backed macOS app recording and `packages/transcribe` for local whisper.cpp transcription. The agent plugin source lives in `plugins/record`.

## Scope

These instructions apply to the whole repository. Read the nearest package `AGENTS.md` before editing scoped package code.

## Commands

```bash
npm install
npm run setup:capture
npm run setup:transcribe
npm run setup
npm run build:bundle
npm run build:binary:macos-arm64
npm run doctor
npm run install:local
npm run plugin:smoke
```

Run package CLIs in development:

```bash
npm --workspace capture run capture -- <args>
npm --workspace transcribe run transcribe -- <args>
```

## Context Loading

| Working On | Read First |
| --- | --- |
| Capture CLI | `packages/capture/AGENTS.md` |
| Transcribe CLI | `packages/transcribe/AGENTS.md` |
| Agent plugin | `plugins/record/README.md` and the relevant skill `SKILL.md` |

## Validation

- For CLI source changes, run the package help command and `npm run build:bundle`.
- For binary/install script changes, run `npm run build:binary:macos-arm64` when feasible.
- For plugin manifest, skill, helper script, or plugin README changes, run `npm run plugin:smoke`.
- Treat `doctor` failures from missing OBS, inactive OBS WebSocket, missing Whisper, or missing model as environment checks; report them instead of hiding them.

## Structure

- `packages/capture`: OBS recording CLI.
- `packages/transcribe`: local transcription CLI.
- `plugins/record`: local agent plugin manifests, skills, and helper scripts.
- `dist/`, `node_modules/`, `runs/`, recordings, transcripts, and local config are generated and must stay untracked.

## Boundaries

- Keep `capture` and `transcribe` as separate CLIs; do not add a combined `record` executable unless requested.
- Do not introduce private package registries, local absolute paths, or machine-specific plugin metadata files.
- Do not commit recordings, transcripts, local run output, build artifacts, dependencies, secrets, or environment files.
- Treat recording and transcription artifacts as sensitive by default.
