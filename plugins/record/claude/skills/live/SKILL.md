---
name: live
description: Follow a visible Mac meeting or media app with local real-time transcription and surface timestamp-grounded context and questions.
argument-hint: "[start APP|follow|status|stop|setup|doctor]"
allowed-tools: Bash(record live *)
---

# Live

Use `record live` as the local evidence stream. The transcription runtime is local; you supply the semantic context and questions.

```bash
record live start --app APP [--output DIR] --json
record live next --after CURSOR --timeout 20 --json
record live status --json
record live stop --json
record live setup --json
record live doctor --json
```

1. Infer the visible meeting/media app when possible, start live capture, and set the local cursor to `0`.
2. Repeatedly call `next`. Replace the cursor with `next_cursor` after every response, including empty responses.
3. Consume only `transcript.final` events. Keep a concise rolling context and never treat changing partial hypotheses as evidence.
4. Surface a question only when it clarifies a decision, owner, requirement, risk, or next step. Debounce semantic repeats.
5. Attach the supporting `source_audio_ms` to every context update or question and state transcript uncertainty plainly.
6. Continue until `terminal` is true or the user asks to stop. On stop, run `record live stop --json`, then drain `next` until terminal.

Keep feedback short enough to use during the meeting. Do not invoke a second model or send transcript content elsewhere. Treat recordings, audio frames, transcripts, metadata, and event logs as sensitive local artifacts; do not upload, paste, move, delete, or retain them outside the active task unless explicitly asked.
