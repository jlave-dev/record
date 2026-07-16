# Capture Package Notes

This package owns the native macOS `capture` CLI and its on-demand `CaptureAgent.app`. Keep it independent from `transcribe`; shared workflows belong at the workspace or plugin layer.

## Validation

```bash
npm --workspace capture run capture -- --help
npm --workspace capture run build
npm --workspace capture test
```

Doctor failures caused by missing Screen & System Audio Recording permission are environment failures and should be reported plainly.
