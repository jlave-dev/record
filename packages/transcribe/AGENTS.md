# Transcribe Package Notes

This package owns the `transcribe` CLI only. It transcribes local media files and writes local artifacts; it does not summarize, upload, redact, or manage source retention.

## Validation

```bash
npm --workspace transcribe run transcribe -- --help
npm --workspace transcribe run build
npm --workspace transcribe run build:binary:macos-arm64
npm --workspace transcribe test
```

Doctor failures caused by missing `ffmpeg`, `ffprobe`, whisper.cpp, or model files are environment failures and should be reported plainly.
