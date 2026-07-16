#!/usr/bin/env node
import { Command } from "commander";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { basename, dirname, extname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { createInterface } from "node:readline/promises";
import { stdin as input, stdout as output } from "node:process";

type TranscribeConfig = {
  whisper_command: string;
  whisper_model: string;
};

type DoctorCheck = {
  name: string;
  ok: boolean;
  details: string;
};

type InputKind = "audio" | "video";
type SourceAction = "none" | "copied" | "moved" | "already_co-located";

type TranscriptSegment = {
  id: string;
  start: number | null;
  end: number | null;
  text: string;
};

type TranscriptJson = {
  schema_version: 1;
  artifact_type: "transcript";
  engine: string;
  model: string;
  audio_file: string;
  text: string;
  segments: TranscriptSegment[];
  raw?: unknown;
};

type Metadata = {
  schema_version: 1;
  artifact_type: "transcription_run";
  created_at: string;
  original_input_file: string;
  input_kind: InputKind;
  source_action: SourceAction;
  co_located_source_file?: string;
  transcription_engine: string;
  transcript_model: string;
  audio_file_used: string;
  temporary_extracted_audio_used: boolean;
  temporary_extracted_audio_removed: boolean;
  transcript_reference_count: number;
  artifacts: {
    transcript_text: string;
    transcript_json: string;
    metadata_json: string;
    co_located_source_file?: string;
  };
};

type JsonObject = Record<string, unknown>;

class CliError extends Error {
  exitCode: number;

  constructor(message: string, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

const DEFAULT_CONFIG: TranscribeConfig = {
  whisper_command: "whisper-cli",
  whisper_model: "~/.local/share/transcribe/models/ggml-large-v3-turbo.bin"
};

const CONFIG_KEYS = new Set<keyof TranscribeConfig>(["whisper_command", "whisper_model"]);
const AUDIO_EXTENSIONS = new Set([".aac", ".aiff", ".aif", ".flac", ".m4a", ".mp3", ".ogg", ".opus", ".wav", ".weba", ".wma"]);
const VIDEO_EXTENSIONS = new Set([".avi", ".m4v", ".mkv", ".mov", ".mp4", ".mpeg", ".mpg", ".webm", ".wmv"]);
const MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin";
const DEFAULT_MODEL_BYTES = 1_624_555_275;
const DEFAULT_MODEL_SHA256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69";

function expandHome(value: string): string {
  if (value === "~") return homedir();
  if (value.startsWith("~/")) return join(homedir(), value.slice(2));
  return value;
}

function configDir(): string {
  return process.env.XDG_CONFIG_HOME ? resolve(expandHome(process.env.XDG_CONFIG_HOME)) : join(homedir(), ".config");
}

function configPath(): string {
  return join(configDir(), "transcribe", "config.toml");
}

function modelDir(): string {
  return join(homedir(), ".local", "share", "transcribe", "models");
}

function defaultModelPath(): string {
  return join(modelDir(), "ggml-large-v3-turbo.bin");
}

function ensureDir(path: string): void {
  mkdirSync(path, { recursive: true });
}

function printJson(data: unknown): void {
  process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
}

function printHuman(message: string): void {
  process.stdout.write(`${message}\n`);
}

function fail(message: string): never {
  throw new CliError(message);
}

function tomlValue(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function parseToml(contents: string): Partial<TranscribeConfig> {
  const result: Partial<TranscribeConfig> = {};
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = /^([A-Za-z0-9_]+)\s*=\s*(.+)$/.exec(line);
    if (!match) continue;
    const key = match[1] as keyof TranscribeConfig;
    if (!CONFIG_KEYS.has(key)) continue;
    const rawValue = match[2].trim();
    result[key] = (rawValue.startsWith('"') && rawValue.endsWith('"')
      ? rawValue.slice(1, -1).replace(/\\"/g, '"')
      : rawValue) as never;
  }
  return result;
}

function formatToml(config: TranscribeConfig): string {
  return [
    `whisper_command = ${tomlValue(config.whisper_command)}`,
    `whisper_model = ${tomlValue(config.whisper_model)}`
  ].join("\n") + "\n";
}

function loadConfig(): TranscribeConfig {
  const path = configPath();
  const loaded = existsSync(path) ? parseToml(readFileSync(path, "utf8")) : {};
  return {
    whisper_command: loaded.whisper_command ?? DEFAULT_CONFIG.whisper_command,
    whisper_model: loaded.whisper_model ?? DEFAULT_CONFIG.whisper_model
  };
}

function writeConfig(config: TranscribeConfig): void {
  ensureDir(dirname(configPath()));
  writeFileSync(configPath(), formatToml(config));
}

function commandExists(command: string): boolean {
  if (command.includes("/")) return existsSync(expandHome(command));
  const pathEntries = (process.env.PATH ?? "").split(":").filter(Boolean);
  return pathEntries.some((entry) => existsSync(join(entry, command)));
}

function pathIsReadable(path: string): boolean {
  try {
    statSync(path);
    return true;
  } catch {
    return false;
  }
}

function modelAvailability(modelPath: string): { ok: boolean; details: string; size?: number; expected_size?: number } {
  let stats;
  try {
    stats = statSync(modelPath);
  } catch {
    return { ok: false, details: `Model was not readable at ${modelPath}.` };
  }

  if (modelPath === defaultModelPath() && stats.size !== DEFAULT_MODEL_BYTES) {
    return {
      ok: false,
      details: `Model at ${modelPath} is ${stats.size} bytes; expected ${DEFAULT_MODEL_BYTES}. Run transcribe setup to refresh it.`,
      size: stats.size,
      expected_size: DEFAULT_MODEL_BYTES
    };
  }

  return {
    ok: true,
    details: modelPath === defaultModelPath()
      ? `Model is readable at ${modelPath} and has the expected size.`
      : `Model is readable at ${modelPath}.`,
    size: stats.size,
    expected_size: modelPath === defaultModelPath() ? DEFAULT_MODEL_BYTES : undefined
  };
}

function run(command: string, args: string[], options: { cwd?: string } = {}): { status: number | null; stdout: string; stderr: string } {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? ""
  };
}

function splitCommandLine(commandLine: string): string[] {
  const tokens: string[] = [];
  let current = "";
  let quote: "'" | '"' | undefined;
  let escaping = false;
  for (const character of commandLine) {
    if (escaping) {
      current += character;
      escaping = false;
      continue;
    }
    if (character === "\\") {
      escaping = true;
      continue;
    }
    if (quote) {
      if (character === quote) quote = undefined;
      else current += character;
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (/\s/.test(character)) {
      if (current) {
        tokens.push(current);
        current = "";
      }
      continue;
    }
    current += character;
  }
  if (current) tokens.push(current);
  if (quote) fail("Unclosed quote in whisper_command config.");
  return tokens;
}

function commandDisplayName(commandLine: string): string {
  return splitCommandLine(commandLine)[0] ?? commandLine;
}

function includeInheritedJson<T extends { json?: boolean }>(options: T, command: Command): T {
  return { ...options, json: Boolean(options.json || command.parent?.opts().json) };
}

function inputKindForPath(path: string): InputKind | undefined {
  const extension = extname(path).toLowerCase();
  if (AUDIO_EXTENSIONS.has(extension)) return "audio";
  if (VIDEO_EXTENSIONS.has(extension)) return "video";
  return undefined;
}

function secondsFromTimestamp(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value !== "string") return null;
  const parts = value.trim().replace(",", ".").split(":").map(Number);
  if (parts.some((part) => Number.isNaN(part))) return null;
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  if (parts.length === 1) return parts[0];
  return null;
}

function formatTimestamp(seconds: number | null): string {
  if (seconds === null) return "--:--.---";
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const wholeSeconds = Math.floor(seconds % 60);
  const millis = Math.round((seconds - Math.floor(seconds)) * 1000);
  return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(wholeSeconds).padStart(2, "0")}.${String(millis).padStart(3, "0")}`;
}

function writeJson(path: string, data: unknown): void {
  ensureDir(dirname(path));
  writeFileSync(path, `${JSON.stringify(data, null, 2)}\n`);
}

function extractSegments(raw: unknown): TranscriptSegment[] {
  const rawSegments = candidateSegmentArrays(raw)[0] ?? [];
  return rawSegments
    .map((segment, index) => normalizeSegment(segment, index))
    .filter((segment) => segment.text.length > 0);
}

function candidateSegmentArrays(raw: unknown): unknown[][] {
  if (!raw || typeof raw !== "object") return [];
  const object = raw as JsonObject;
  const candidates = [object.segments, object.transcription, object.results, object.items];
  return candidates.filter((candidate): candidate is unknown[] => Array.isArray(candidate));
}

function normalizeSegment(segment: unknown, index: number): TranscriptSegment {
  if (!segment || typeof segment !== "object") {
    return { id: `seg-${String(index + 1).padStart(4, "0")}`, start: null, end: null, text: String(segment ?? "").trim() };
  }
  const object = segment as JsonObject;
  const timestamps = object.timestamps && typeof object.timestamps === "object" ? object.timestamps as JsonObject : {};
  const start = secondsFromTimestamp(object.start ?? object.start_time ?? timestamps.from);
  const end = secondsFromTimestamp(object.end ?? object.end_time ?? timestamps.to);
  const text = String(object.text ?? object.content ?? "").trim();
  return {
    id: String(object.id ?? `seg-${String(index + 1).padStart(4, "0")}`),
    start,
    end,
    text
  };
}

function textFromRaw(raw: unknown): string {
  if (!raw || typeof raw !== "object") return "";
  const object = raw as JsonObject;
  for (const key of ["text", "transcript", "result"]) {
    const value = object[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return extractSegments(raw).map((segment) => segment.text).join(" ").trim();
}

function textFileFromSegments(segments: TranscriptSegment[], fallbackText: string): string {
  if (!segments.length) return `${fallbackText.trim()}\n`;
  return segments.map((segment) => {
    return `[${segment.id} ${formatTimestamp(segment.start)}-${formatTimestamp(segment.end)}] ${segment.text}`;
  }).join("\n") + "\n";
}

function sameDirectory(pathA: string, pathB: string): boolean {
  try {
    return realpathSync(dirname(pathA)) === realpathSync(pathB);
  } catch {
    return resolve(dirname(pathA)) === resolve(pathB);
  }
}

function samePath(pathA: string, pathB: string): boolean {
  try {
    return realpathSync(pathA) === realpathSync(pathB);
  } catch {
    return resolve(pathA) === resolve(pathB);
  }
}

function prepareSourceAction(inputPath: string, outputDir: string, copySource: boolean, moveSource: boolean): { action: SourceAction; destination?: string; apply: () => void } {
  if (copySource && moveSource) fail("Pass only one of --copy-source or --move-source, not both.");
  if (!copySource && !moveSource) return { action: "none", apply: () => undefined };

  const destination = join(outputDir, basename(inputPath));
  if (sameDirectory(inputPath, outputDir)) {
    return { action: "already_co-located", destination: inputPath, apply: () => undefined };
  }
  if (existsSync(destination) && !samePath(inputPath, destination)) {
    fail(`Refusing to overwrite existing source file at ${destination}.`);
  }
  if (copySource) {
    return {
      action: "copied",
      destination,
      apply: () => copyFileSync(inputPath, destination)
    };
  }
  return {
    action: "moved",
    destination,
    apply: () => renameSync(inputPath, destination)
  };
}

function extractAudio(inputPath: string, outputDir: string): string {
  const tempRoot = join(tmpdir(), "transcribe-audio-");
  const tempDir = mkdtempSync(tempRoot);
  const audioPath = join(tempDir, "audio.wav");
  const result = run("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-i",
    inputPath,
    "-vn",
    "-ac",
    "1",
    "-ar",
    "16000",
    audioPath
  ], { cwd: outputDir });
  if (result.status !== 0) {
    fail(`ffmpeg could not extract audio: ${result.stderr.trim() || result.stdout.trim() || "unknown error"}`);
  }
  return audioPath;
}

function removeTempAudio(audioPath: string): boolean {
  try {
    rmSync(dirname(audioPath), { recursive: true, force: true });
    return !existsSync(audioPath);
  } catch {
    return false;
  }
}

function runWhisper(config: TranscribeConfig, audioPath: string, outputBase: string): { stdout: string; stderr: string } {
  const tokens = splitCommandLine(config.whisper_command);
  const executable = tokens.shift();
  if (!executable) fail("whisper_command config is empty.");
  if (!commandExists(executable)) fail(`Whisper command "${executable}" was not found. Run transcribe setup or transcribe config set whisper_command PATH.`);
  const model = resolve(expandHome(config.whisper_model));
  const modelCheck = modelAvailability(model);
  if (!modelCheck.ok) fail(`${modelCheck.details} Run transcribe setup or transcribe config set whisper_model PATH.`);
  const args = [...tokens, "-m", model, "-f", audioPath, "-otxt", "-oj", "-of", outputBase];
  const result = run(executable, args);
  if (result.status !== 0) {
    fail(`Whisper exited non-zero: ${result.stderr.trim() || result.stdout.trim() || "unknown error"}`);
  }
  return { stdout: result.stdout, stderr: result.stderr };
}

function readWhisperOutputs(textPath: string, jsonPath: string, stdout: string): { text: string; raw?: unknown; segments: TranscriptSegment[] } {
  let raw: unknown;
  if (existsSync(jsonPath)) {
    try {
      raw = JSON.parse(readFileSync(jsonPath, "utf8"));
    } catch {
      raw = undefined;
    }
  }

  const segments = raw ? extractSegments(raw) : [];
  const textFromJson = raw ? textFromRaw(raw) : "";
  const textFromFile = existsSync(textPath) ? readFileSync(textPath, "utf8").trim() : "";
  const text = (textFromJson || textFromFile || stdout.trim()).trim();
  if (!text) fail("Whisper finished but produced no usable transcript.");
  return { text, raw, segments };
}

async function commandTranscribe(options: { input?: string; output?: string; copySource?: boolean; moveSource?: boolean; json?: boolean }): Promise<void> {
  if (!options.input) fail("Missing --input PATH.");
  if (!options.output) fail("Missing --output DIR.");
  if (options.copySource && options.moveSource) fail("Pass only one of --copy-source or --move-source, not both.");

  const inputPath = resolve(expandHome(options.input));
  const outputDir = resolve(expandHome(options.output));
  if (!pathIsReadable(inputPath)) fail(`Input path does not exist or is not readable: ${inputPath}`);
  if (existsSync(outputDir) && !statSync(outputDir).isDirectory()) fail(`Output path exists and is not a directory: ${outputDir}`);

  const inputKind = inputKindForPath(inputPath);
  if (!inputKind) fail("Unsupported input type. Pass a local audio or video file.");

  if (!commandExists("ffmpeg")) fail("ffmpeg was not found on PATH.");
  if (!commandExists("ffprobe")) fail("ffprobe was not found on PATH.");

  ensureDir(outputDir);
  const sourcePlan = prepareSourceAction(inputPath, outputDir, Boolean(options.copySource), Boolean(options.moveSource));
  const config = loadConfig();
  const textPath = join(outputDir, "transcript.txt");
  const transcriptJsonPath = join(outputDir, "transcript.json");
  const metadataPath = join(outputDir, "metadata.json");
  const whisperOutputBase = join(outputDir, "transcript");
  const audioPath = extractAudio(inputPath, outputDir);
  let tempRemoved = false;

  try {
    const whisperResult = runWhisper(config, audioPath, whisperOutputBase);
    const outputs = readWhisperOutputs(textPath, transcriptJsonPath, whisperResult.stdout);
    const transcript: TranscriptJson = {
      schema_version: 1,
      artifact_type: "transcript",
      engine: commandDisplayName(config.whisper_command),
      model: resolve(expandHome(config.whisper_model)),
      audio_file: audioPath,
      text: outputs.text,
      segments: outputs.segments,
      raw: outputs.raw
    };

    writeFileSync(textPath, textFileFromSegments(outputs.segments, outputs.text));
    writeJson(transcriptJsonPath, transcript);
    sourcePlan.apply();

    tempRemoved = removeTempAudio(audioPath);
    const metadata: Metadata = {
      schema_version: 1,
      artifact_type: "transcription_run",
      created_at: new Date().toISOString(),
      original_input_file: inputPath,
      input_kind: inputKind,
      source_action: sourcePlan.action,
      co_located_source_file: sourcePlan.destination,
      transcription_engine: commandDisplayName(config.whisper_command),
      transcript_model: resolve(expandHome(config.whisper_model)),
      audio_file_used: audioPath,
      temporary_extracted_audio_used: true,
      temporary_extracted_audio_removed: tempRemoved,
      transcript_reference_count: outputs.segments.length,
      artifacts: {
        transcript_text: textPath,
        transcript_json: transcriptJsonPath,
        metadata_json: metadataPath,
        co_located_source_file: sourcePlan.destination
      }
    };
    writeJson(metadataPath, metadata);

    const payload = {
      output_dir: outputDir,
      artifacts: metadata.artifacts,
      metadata
    };
    if (options.json) printJson(payload);
    else {
      printHuman(`Transcript text: ${textPath}`);
      printHuman(`Transcript JSON: ${transcriptJsonPath}`);
      printHuman(`Metadata: ${metadataPath}`);
      if (sourcePlan.destination) printHuman(`Source: ${sourcePlan.destination}`);
    }
  } finally {
    if (!tempRemoved && existsSync(audioPath)) removeTempAudio(audioPath);
  }
}

function gatherDoctorChecks(config = loadConfig()): DoctorCheck[] {
  const whisperExecutable = splitCommandLine(config.whisper_command)[0] ?? config.whisper_command;
  const modelPath = resolve(expandHome(config.whisper_model));
  const modelCheck = modelAvailability(modelPath);
  return [
    {
      name: "ffmpeg",
      ok: commandExists("ffmpeg"),
      details: commandExists("ffmpeg") ? "ffmpeg is available." : "ffmpeg was not found on PATH."
    },
    {
      name: "ffprobe",
      ok: commandExists("ffprobe"),
      details: commandExists("ffprobe") ? "ffprobe is available." : "ffprobe was not found on PATH."
    },
    {
      name: "whisper_command",
      ok: commandExists(whisperExecutable),
      details: commandExists(whisperExecutable) ? `${whisperExecutable} is available.` : `${whisperExecutable} was not found.`
    },
    {
      name: "whisper_model",
      ok: modelCheck.ok,
      details: modelCheck.details
    }
  ];
}

function commandDoctor(options: { json?: boolean }): void {
  const checks = gatherDoctorChecks();
  const ok = checks.every((check) => check.ok);
  if (options.json) {
    printJson({ ok, checks });
  } else {
    for (const check of checks) printHuman(`${check.ok ? "OK" : "FAIL"} ${check.name}: ${check.details}`);
  }
  if (!ok) process.exitCode = 1;
}

function commandConfig(options: { json?: boolean }): void {
  const config = loadConfig();
  const payload = {
    config,
    paths: {
      config: configPath(),
      models: modelDir()
    }
  };
  if (options.json) {
    printJson(payload);
  } else {
    printHuman(`Config: ${configPath()}`);
    for (const [key, value] of Object.entries(config)) printHuman(`${key}=${value}`);
  }
}

function commandConfigSet(key: string, value: string): void {
  if (!CONFIG_KEYS.has(key as keyof TranscribeConfig)) {
    fail(`Unsupported config key "${key}". Supported keys: ${[...CONFIG_KEYS].join(", ")}`);
  }
  const config = loadConfig();
  config[key as keyof TranscribeConfig] = value;
  writeConfig(config);
  printJson({ key, value, config_path: configPath() });
}

async function commandInit(): Promise<void> {
  const current = loadConfig();
  const readline = createInterface({ input, output });
  try {
    const whisperCommand = (await readline.question(`Whisper command [${current.whisper_command}]: `)).trim() || current.whisper_command;
    const whisperModel = (await readline.question(`Whisper model [${current.whisper_model}]: `)).trim() || current.whisper_model;
    const config = { whisper_command: whisperCommand, whisper_model: whisperModel };
    writeConfig(config);
    printHuman(`Wrote ${configPath()}`);
  } finally {
    readline.close();
  }
}

function downloadFile(url: string, destination: string): void {
  ensureDir(dirname(destination));
  const tempDestination = join(dirname(destination), `.${basename(destination)}.download-${process.pid}-${Date.now()}`);
  try {
    const curl = spawnSync("curl", ["-L", "--fail", "--progress-bar", "-o", tempDestination, url], {
      stdio: ["ignore", "inherit", "pipe"],
      encoding: "utf8"
    });
    if (curl.status !== 0) {
      fail(`Could not download model: ${curl.stderr?.trim() || "curl failed"}`);
    }

    const stats = statSync(tempDestination);
    if (destination === defaultModelPath() && stats.size !== DEFAULT_MODEL_BYTES) {
      fail(`Downloaded model was ${stats.size} bytes; expected ${DEFAULT_MODEL_BYTES}.`);
    }
    if (destination === defaultModelPath()) {
      const checksum = run("/usr/bin/shasum", ["-a", "256", tempDestination]);
      const actual = checksum.stdout.trim().split(/\s+/)[0];
      if (checksum.status !== 0 || actual !== DEFAULT_MODEL_SHA256) {
        fail(`Downloaded model checksum did not match. Expected ${DEFAULT_MODEL_SHA256}, received ${actual || "no checksum"}.`);
      }
    }

    renameSync(tempDestination, destination);
  } catch (error) {
    rmSync(tempDestination, { force: true });
    if (error instanceof CliError) throw error;
    throw error;
  }
}

async function commandSetup(options: { force?: boolean; dryRun?: boolean; json?: boolean }): Promise<void> {
  const loadedConfig = loadConfig();
  const config = {
    ...loadedConfig,
    whisper_model: loadedConfig.whisper_model === DEFAULT_CONFIG.whisper_model ? defaultModelPath() : loadedConfig.whisper_model
  };
  const whisperExecutable = splitCommandLine(config.whisper_command)[0] ?? config.whisper_command;
  const modelPath = resolve(expandHome(config.whisper_model));
  const brewAvailable = commandExists("brew");
  const ffmpegAvailable = commandExists("ffmpeg") && commandExists("ffprobe");
  const whisperAvailable = commandExists(whisperExecutable);
  const modelCheck = modelAvailability(modelPath);
  const modelAvailable = modelCheck.ok;
  const actions = [
    { action: "verify_homebrew", required: true, status: brewAvailable ? "ok" : "missing" },
    { action: "install_ffmpeg", required: !ffmpegAvailable, command: "brew install ffmpeg" },
    { action: "install_whisper_cpp", required: !whisperAvailable, command: "brew install whisper-cpp" },
    { action: "write_transcribe_config", path: configPath() },
    { action: "download_model", required: options.force || !modelAvailable, url: MODEL_URL, path: modelPath, current_status: modelCheck.details }
  ];

  if (!brewAvailable && !options.dryRun) fail("Homebrew was not found on PATH. Install Homebrew before running transcribe setup.");

  if (!options.dryRun) {
    if (!ffmpegAvailable) {
      const install = run("brew", ["install", "ffmpeg"]);
      if (install.status !== 0) fail(`brew install ffmpeg failed: ${install.stderr.trim() || install.stdout.trim()}`);
    }
    if (!whisperAvailable) {
      const install = run("brew", ["install", "whisper-cpp"]);
      if (install.status !== 0) fail(`brew install whisper-cpp failed: ${install.stderr.trim() || install.stdout.trim()}`);
    }
    writeConfig(config);
    if (options.force || !modelAvailable) {
      downloadFile(MODEL_URL, modelPath);
    }
  }

  const doctorChecks = options.dryRun ? undefined : gatherDoctorChecks(config);
  const doctorOk = doctorChecks?.every((check) => check.ok);
  const payload = {
    status: options.dryRun ? "dry-run" : doctorOk ? "ok" : "failed",
    actions,
    config_path: configPath(),
    config,
    doctor: doctorChecks ? { ok: doctorChecks.every((check) => check.ok), checks: doctorChecks } : undefined
  };

  if (options.json) {
    printJson(payload);
  } else {
    printHuman(options.dryRun ? "transcribe setup dry run:" : doctorOk ? "transcribe setup complete." : "transcribe setup failed doctor checks.");
    for (const action of actions) printHuman(`- ${action.action}${"path" in action ? `: ${action.path}` : ""}`);
  }
  if (doctorOk === false) process.exitCode = 1;
}

function unknownCommand(name: string): never {
  fail(`"${name}" is not part of the transcribe product surface. Use transcribe --input PATH --output DIR.`);
}

function installErrorHandler(program: Command): void {
  program.exitOverride();
  process.on("uncaughtException", (error) => {
    if (error instanceof CliError) {
      process.stderr.write(`${error.message}\n`);
      process.exit(error.exitCode);
    }
    if ((error as { code?: string }).code === "commander.helpDisplayed") process.exit(0);
    if ((error as { code?: string }).code?.startsWith("commander.")) {
      process.stderr.write(`${error.message}\n`);
      process.exit(1);
    }
    process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
    process.exit(1);
  });
}

async function main(): Promise<void> {
  const program = new Command();
  installErrorHandler(program);
  program
    .name("transcribe")
    .description("Transcribe a local audio or video file with local whisper.cpp.")
    .version("0.2.1")
    .argument("[operands...]", "unsupported legacy command or positional operand")
    .option("--input <path>", "local audio or video input file")
    .option("--output <dir>", "output directory for transcript artifacts")
    .option("--copy-source", "copy source media into the output directory")
    .option("--move-source", "move source media into the output directory")
    .option("--json", "print machine-readable output")
    .action((operands: string[] | undefined, options) => {
      if (operands?.length) unknownCommand(operands.join(" "));
      return commandTranscribe(options);
    });

  program.command("setup")
    .option("--force", "refresh model/configuration when appropriate")
    .option("--dry-run", "report intended setup actions without writing files")
    .option("--json", "print machine-readable output")
    .action((options, command) => commandSetup(includeInheritedJson(options, command)));

  program.command("init")
    .description("run an interactive configuration wizard")
    .action(() => commandInit());

  const config = program.command("config")
    .option("--json", "print machine-readable output")
    .action((options, command) => commandConfig(includeInheritedJson(options, command)));

  config.command("set")
    .argument("<key>")
    .argument("<value>")
    .action((key, value) => commandConfigSet(key, value));

  program.command("doctor")
    .option("--json", "print machine-readable output")
    .action((options, command) => commandDoctor(includeInheritedJson(options, command)));

  program.configureOutput({
    writeErr: (str) => process.stderr.write(str)
  });
  program.on("command:*", (operands) => unknownCommand(operands[0]));

  await program.parseAsync(process.argv);
}

main().catch((error) => {
  const commanderCode = (error as { code?: string }).code;
  if (commanderCode === "commander.helpDisplayed" || commanderCode === "commander.version") process.exit(0);
  if (commanderCode?.startsWith("commander.")) {
    if (error instanceof Error && error.message !== "(outputHelp)") process.stderr.write(`${error.message}\n`);
    process.exit((error as { exitCode?: number }).exitCode ?? 1);
  }
  if (error instanceof CliError) throw error;
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(1);
});
