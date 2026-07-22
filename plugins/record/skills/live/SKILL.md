---
name: live
description: Use when the user wants real-time local meeting transcription, live context, or questions generated while a visible Mac meeting or media app plays.
---

# live

Use the local `record live` stream as evidence for timely meeting feedback. The transcription runtime is local; the agent itself supplies the semantic context and questions.

## Commands

Resolve the plugin root from this `SKILL.md`, then invoke its helper by absolute path:

```bash
<plugin-root>/scripts/run-live.sh start --app APP [--output DIR]
<plugin-root>/scripts/run-live.sh next --after CURSOR [--timeout SECONDS]
<plugin-root>/scripts/run-live.sh status
<plugin-root>/scripts/run-live.sh stop
<plugin-root>/scripts/run-live.sh setup
<plugin-root>/scripts/run-live.sh doctor
```

## Live loop

1. Infer the visible meeting/media app when possible, start live capture, and set the local cursor to `0`.
2. Repeatedly call `next --after CURSOR --timeout 20`. Replace the cursor with `next_cursor` after every response, including empty responses.
3. Consume only `transcript.final` events. Keep a concise rolling meeting context; do not treat changing partial hypotheses as evidence.
4. Surface a question only when it would clarify a decision, owner, requirement, risk, or next step. Debounce semantic repeats across the rolling context.
5. Attach the supporting event's `source_audio_ms` to every context update or question. Say when the transcript is uncertain rather than inventing detail.
6. Continue until `terminal` is true or the user asks to stop. On user stop, run `stop`, then drain `next` until terminal.

Keep feedback short enough to be useful during the meeting. Do not invoke a second model or send transcript content anywhere else.

## Privacy

Recording, audio frames, transcripts, metadata, and event logs are sensitive local artifacts. Do not upload, paste, move, delete, or retain their content outside the active task unless the user explicitly asks.
