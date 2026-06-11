#!/usr/bin/env bash
set +e

if [[ ! -x packages/capture/dist/index.js || ! -x packages/transcribe/dist/index.js ]]; then
  npm run build:bundle
fi

node packages/capture/dist/index.js doctor
capture_status=$?

node packages/transcribe/dist/index.js doctor
transcribe_status=$?

if [[ "$capture_status" -ne 0 || "$transcribe_status" -ne 0 ]]; then
  exit 1
fi

exit 0
