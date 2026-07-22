#!/usr/bin/env bash
set -euo pipefail

input_path="${1:-}"
seconds="${2:-30}"
if [[ -n "$input_path" && "$input_path" != /* && -n "${INIT_CWD:-}" ]]; then
  input_path="$INIT_CWD/$input_path"
fi
[[ -n "$input_path" && -f "$input_path" ]] || {
  echo "Usage: npm --workspace live run test:prerecorded -- INPUT [SECONDS]" >&2
  exit 2
}
[[ "$seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "SECONDS must be a positive integer." >&2
  exit 2
}
command -v ffmpeg >/dev/null 2>&1 || {
  echo "ffmpeg is required for the prerecorded live integration test." >&2
  exit 127
}

package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
worker="$package_dir/dist/live-worker"
[[ -x "$worker" ]] || "$package_dir/scripts/build.sh" >/dev/null

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/record-live-prerecorded.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

ffmpeg -hide_banner -loglevel error -re -t "$seconds" -i "$input_path" \
  -vn -ac 1 -ar 16000 -f f32le pipe:1 |
  /usr/bin/ruby -e '
    frame_bytes = 5120 * 4
    source_ms = 0
    buffered = "".b
    begin
      loop do
        buffered << STDIN.readpartial(65536)
        while buffered.bytesize >= frame_bytes
          payload = buffered.slice!(0, frame_bytes)
          STDOUT.write([0x524c4956, 1, source_ms, 5120].pack("VVq<V"))
          STDOUT.write(payload)
          STDOUT.flush
          source_ms += 320
        end
      end
    rescue EOFError
    end
  ' |
  "$worker" stream --events "$test_dir/events.jsonl" --ready "$test_dir/ready"

node --input-type=module - "$test_dir/events.jsonl" <<'NODE'
import { readFileSync } from "node:fs";

const events = readFileSync(process.argv[2], "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));
const finals = events.filter((event) => event.type === "transcript.final");
if (events.at(0)?.type !== "live.started") throw new Error("missing live.started event");
if (finals.length === 0) throw new Error("prerecorded sample produced no committed transcript");
if (events.at(-1)?.type !== "live.stopped") throw new Error("missing live.stopped event");
const maximumLatencyMs = Math.max(...finals.map((event) => event.delivery_latency_ms));
if (maximumLatencyMs > 5000) throw new Error(`delivery latency exceeded 5 seconds: ${maximumLatencyMs}`);
console.log(JSON.stringify({ finals: finals.length, maximum_delivery_latency_ms: maximumLatencyMs }));
NODE
