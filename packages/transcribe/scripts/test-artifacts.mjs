import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

const cli = resolve(import.meta.dirname, '../dist/index.js');
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'transcribe-test-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const dir of ['bin', 'config/transcribe', 'scratch', 'output']) mkdirSync(join(root, dir), { recursive: true });
  const input = join(root, 'input.wav');
  const output = join(root, 'output');
  writeFileSync(input, 'original media');
  writeFileSync(join(root, 'model.bin'), 'fixture model');
  writeFileSync(join(root, 'config/transcribe/config.toml'), `whisper_command = "whisper-cli"\nwhisper_model = "${root}/model.bin"\n`);
  function executable(name, body) {
    const path = join(root, 'bin', name);
    writeFileSync(path, '#!/bin/bash\nset -eu\n' + body);
    chmodSync(path, 0o755);
  }
  executable('ffprobe', 'exit 0\n');
  executable('ffmpeg', 'printf "temporary audio" > "${!#}"\nexit "\${MOCK_FFMPEG_EXIT:-0}"\n');
  executable('whisper-cli', `
while [[ "$1" != -of ]]; do shift; done
base="$2"
if [[ "\${MOCK_NO_OUTPUT:-0}" == 1 ]]; then echo 'diagnostic output only'; exit 0; fi
printf '{"transcription":[{"text":"fresh transcript","timestamps":{"from":"00:00:00.000","to":"00:00:01.000"}}]}' > "$base.json"
printf 'fresh transcript' > "$base.txt"
if [[ -n "\${MOCK_COLLISION:-}" ]]; then printf 'concurrent file' > "$MOCK_COLLISION"; fi
exit "\${MOCK_WHISPER_EXIT:-0}"
`);
  return {
    input, output,
    preload(code) {
      const path = join(root, 'inject.cjs');
      writeFileSync(path, code);
      return { NODE_OPTIONS: `--require=${path}` };
    },
    run(flags = [], extra = {}) {
      const result = spawnSync(process.execPath, [cli, '--input', input, '--output', output, '--json', ...flags], {
        encoding: 'utf8', timeout: 10_000,
        env: { ...process.env, PATH: `${root}/bin:/usr/bin:/bin`, XDG_CONFIG_HOME: `${root}/config`, TMPDIR: `${root}/scratch`, ...extra },
      });
      assert.ifError(result.error);
      return result;
    },
    assertClean() {
      assert.deepEqual(readdirSync(join(root, 'scratch')), []);
      assert.equal(readdirSync(output).some(name => name.startsWith('.transcribe-')), false);
    },
  };
}

test('refuses existing capture metadata and old transcripts without changing them', t => {
  for (const name of ['metadata.json', 'transcript.json', 'transcript.txt']) {
    const f = fixture(t);
    writeFileSync(join(f.output, name), 'existing artifact');
    const result = f.run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Refusing to overwrite existing artifact/);
    assert.equal(readFileSync(join(f.output, name), 'utf8'), 'existing artifact');
    assert.deepEqual(readdirSync(f.output), [name]);
    f.assertClean();
  }
});

test('a successful recognizer without new output cannot turn diagnostics into a transcript', t => {
  const f = fixture(t);
  const result = f.run([], { MOCK_NO_OUTPUT: '1' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /no usable transcript/);
  assert.deepEqual(readdirSync(f.output), []);
  f.assertClean();
});

test('extraction and recognizer failures remove temporary audio and preserve the source', t => {
  for (const failure of [{ MOCK_FFMPEG_EXIT: '42' }, { MOCK_WHISPER_EXIT: '42' }]) {
    const f = fixture(t);
    assert.notEqual(f.run(['--move-source'], failure).status, 0);
    assert.equal(readFileSync(f.input, 'utf8'), 'original media');
    assert.deepEqual(readdirSync(f.output), []);
    f.assertClean();
  }
});

test('successful copy and move publish fresh transcripts and accurate metadata', t => {
  for (const action of ['copy', 'move']) {
    const f = fixture(t);
    const result = f.run([`--${action}-source`]);
    assert.equal(result.status, 0, result.stderr);
    const transcript = JSON.parse(readFileSync(join(f.output, 'transcript.json'), 'utf8'));
    const metadata = JSON.parse(readFileSync(join(f.output, 'metadata.json'), 'utf8'));
    assert.equal(transcript.text, 'fresh transcript');
    assert.equal(metadata.source_action, action === 'copy' ? 'copied' : 'moved');
    assert.equal(metadata.temporary_extracted_audio_removed, true);
    assert.equal(readFileSync(join(f.output, 'input.wav'), 'utf8'), 'original media');
    assert.equal(existsSync(f.input), action === 'copy');
    f.assertClean();
  }
});

test('late metadata collision preserves competing data and reports a completed source move', t => {
  const f = fixture(t);
  const collision = join(f.output, 'metadata.json');
  const result = f.run(['--move-source'], { MOCK_COLLISION: collision });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Source action moved completed at/);
  assert.ok(result.stderr.includes(join(f.output, 'input.wav')));
  assert.equal(readFileSync(collision, 'utf8'), 'concurrent file');
  assert.equal(readFileSync(join(f.output, 'input.wav'), 'utf8'), 'original media');
  assert.equal(existsSync(f.input), false);
  assert.equal(JSON.parse(readFileSync(join(f.output, 'transcript.json'), 'utf8')).text, 'fresh transcript');
  f.assertClean();
});

test('late source collision never overwrites media or removes the original', t => {
  const f = fixture(t);
  const collision = join(f.output, 'input.wav');
  assert.notEqual(f.run(['--move-source'], { MOCK_COLLISION: collision }).status, 0);
  assert.deepEqual(readdirSync(f.output).sort(), ['input.wav', 'transcript.json', 'transcript.txt']);
  assert.equal(existsSync(join(f.output, 'metadata.json')), false);
  assert.equal(readFileSync(collision, 'utf8'), 'concurrent file');
  assert.equal(readFileSync(f.input, 'utf8'), 'original media');
  f.assertClean();
});


test('publishes and moves sources when hard links are unsupported', t => {
  for (const flags of [[], ['--copy-source'], ['--move-source']]) {
    const f = fixture(t);
    const injected = f.preload(`
      const fs = require('node:fs');
      fs.linkSync = () => { throw Object.assign(new Error('hard links unsupported'), { code: 'ENOTSUP' }); };
    `);
    const result = f.run(flags, injected);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(readFileSync(join(f.output, 'transcript.json'), 'utf8')).text, 'fresh transcript');
    if (flags.length) assert.equal(readFileSync(join(f.output, 'input.wav'), 'utf8'), 'original media');
    assert.equal(existsSync(f.input), !flags.includes('--move-source'));
    f.assertClean();
  }
});

test('late failure never deletes a competing replacement of a published file', t => {
  const f = fixture(t);
  const injected = f.preload(`
    const fs = require('node:fs');
    const path = require('node:path');
    for (const name of ['linkSync', 'copyFileSync']) {
      const original = fs[name];
      fs[name] = (source, destination, ...args) => {
        if (path.basename(destination) === 'metadata.json') {
          const transcript = path.join(path.dirname(destination), 'transcript.txt');
          fs.unlinkSync(transcript);
          fs.writeFileSync(transcript, 'other writer data');
          fs.writeFileSync(destination, 'competing metadata');
        }
        return original(source, destination, ...args);
      };
    }
  `);
  assert.notEqual(f.run([], injected).status, 0);
  assert.equal(readFileSync(join(f.output, 'transcript.txt'), 'utf8'), 'other writer data');
  assert.equal(readFileSync(join(f.output, 'metadata.json'), 'utf8'), 'competing metadata');
  assert.equal(readFileSync(f.input, 'utf8'), 'original media');
  f.assertClean();
});


test('source unlink failure retains both copies and publishes no success metadata', t => {
  const f = fixture(t);
  const injected = f.preload(`
    const fs = require('node:fs');
    const original = fs.rmSync;
    fs.rmSync = (path, ...args) => {
      if (path === ${JSON.stringify(f.input)}) throw Object.assign(new Error('cannot remove source'), { code: 'EACCES' });
      return original(path, ...args);
    };
  `);
  const result = f.run(['--move-source'], injected);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Source was copied to/);
  assert.equal(readFileSync(f.input, 'utf8'), 'original media');
  assert.equal(readFileSync(join(f.output, 'input.wav'), 'utf8'), 'original media');
  assert.equal(existsSync(join(f.output, 'metadata.json')), false);
  f.assertClean();
});
