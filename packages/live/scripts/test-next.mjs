import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const cli = resolve(import.meta.dirname, '../native/.build/debug/live');
function fixture(t, states, events = '') {
  const root = mkdtempSync(join(tmpdir(), 'live-next-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const log = join(root, 'events.jsonl');
  const capture = join(root, 'capture');
  writeFileSync(log, events);
  writeFileSync(join(root, 'states.json'), JSON.stringify(states.map(state => ({ liveEventsPath: log, ...state }))));
  writeFileSync(capture, `#!${process.execPath}\n` + String.raw`
const fs = require('node:fs');
const path = require('node:path');
const root = __dirname;
const countPath = path.join(root, 'count');
const count = fs.existsSync(countPath) ? Number(fs.readFileSync(countPath, 'utf8')) : 0;
const states = JSON.parse(fs.readFileSync(path.join(root, 'states.json'), 'utf8'));
fs.writeFileSync(countPath, String(count + 1));
console.log(JSON.stringify(states[Math.min(count, states.length - 1)]));
`);
  chmodSync(capture, 0o755);
  return {
    run(after = '0', timeout = '10') {
      const start = performance.now();
      const result = spawnSync(cli, ['next', '--after', after, '--timeout', timeout, '--json'], {
        encoding: 'utf8', timeout: 4_000, env: { ...process.env, RECORD_CAPTURE_RUNTIME: capture },
      });
      assert.ifError(result.error);
      return { ...result, elapsed: performance.now() - start };
    },
    calls() { return Number(readFileSync(join(root, 'count'), 'utf8')); },
  };
}

for (const state of [{ liveStatus: 'stopped' }, { liveStatus: 'failed' }, { status: 'failed', liveStatus: 'running' }]) {
  test(`terminal state returns immediately: ${JSON.stringify(state)}`, t => {
    const f = fixture(t, [state]);
    const result = f.run('7');
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), { events: [], next_cursor: 7, terminal: true });
    assert.equal(f.calls(), 1);
  });
}

test('refreshes state during a wait and exits when capture becomes terminal', t => {
  const f = fixture(t, [{ liveStatus: 'running' }, { liveStatus: 'stopped' }]);
  const result = f.run();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).terminal, true);
  assert.equal(f.calls(), 2);
});

test('does not follow a replacement session with unrelated cursors', t => {
  const f = fixture(t, [{ liveStatus: 'running' }, { liveStatus: 'running', liveEventsPath: '/replacement/events.jsonl' }]);
  const result = f.run('42');
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { events: [], next_cursor: 42, terminal: true });
});

test('zero timeout returns available committed events without waiting', t => {
  const events = [1, 2, 3].map(cursor => ({
    schema_version: 1, cursor, type: cursor === 2 ? 'transcript.partial' : 'transcript.final',
    source_audio_ms: 0, wall_elapsed_ms: 0, delivery_latency_ms: 0, created_at: 'fixture', text: 'hello',
  }));
  const f = fixture(t, [{ liveStatus: 'running' }], events.map(e => JSON.stringify(e) + '\n').join(''));
  const result = f.run('1', '0');
  assert.equal(result.status, 0, result.stderr);
  const payload = JSON.parse(result.stdout);
  assert.deepEqual(payload.events.map(e => e.cursor), [3]);
  assert.equal(payload.next_cursor, 3);
  assert.equal(payload.terminal, false);
});
