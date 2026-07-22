# Live Package Notes

This package owns the native `live` CLI and FluidAudio worker. Keep capture integration behind the framed stdin protocol; do not import FluidAudio into the capture package or invoke an agent provider from this runtime.

## Validation

```bash
npm --workspace live run build
npm --workspace live test
```
