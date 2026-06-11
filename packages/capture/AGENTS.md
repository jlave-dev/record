# Capture Package Notes

This package owns the `capture` CLI only. Keep it independent from `transcribe`; shared workflows belong at the workspace or plugin layer.

## Validation

```bash
npm --workspace capture run capture -- --help
npm --workspace capture run build
```

Doctor failures caused by missing OBS, inactive OBS WebSocket, or macOS permissions are environment failures and should be reported plainly.
