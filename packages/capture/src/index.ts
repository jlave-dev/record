#!/usr/bin/env node
import { Command } from "commander";
import OBSWebSocket from "obs-websocket-js";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

type JsonObject = Record<string, unknown>;

type CaptureConfig = {
  obs_host: string;
  obs_port: number;
  obs_password?: string;
  obs_profile: string;
  obs_scene_collection: string;
  obs_scene: string;
  output_root: string;
  output_width?: number;
  output_height?: number;
  video_bitrate: number;
};

type ResolvedApp = {
  display_name: string;
  bundle_id?: string;
  app_path?: string;
  aliases?: string[];
};

type VideoDetails = {
  width: number;
  height: number;
  bitrate: number;
  sizing_mode: string;
  source_width?: number;
  source_height?: number;
  capture_mode: string;
};

type CaptureMetadata = {
  schema_version: 1;
  artifact_type: "capture_recording";
  active: boolean;
  app: ResolvedApp;
  obs: {
    profile: string;
    scene_collection: string;
    scene: string;
  };
  video: VideoDetails;
  output_dir: string;
  started_at: string;
  stopped_at?: string;
  output_path?: string;
  metadata_path: string;
};

type CaptureState = {
  active: boolean;
  metadata_path: string;
  output_dir: string;
  started_at: string;
  app: ResolvedApp;
  obs: CaptureMetadata["obs"];
  video: VideoDetails;
};

type FinalizedCaptureMetadata = CaptureMetadata & {
  error?: string;
};

type DoctorCheck = {
  name: string;
  ok: boolean;
  details: string;
};

class CliError extends Error {
  exitCode: number;
  payload?: JsonObject;

  constructor(message: string, exitCode = 1, payload?: JsonObject) {
    super(message);
    this.exitCode = exitCode;
    this.payload = payload;
  }
}

const DEFAULT_CONFIG: CaptureConfig = {
  obs_host: "localhost",
  obs_port: 4455,
  obs_profile: "Capture",
  obs_scene_collection: "Capture",
  obs_scene: "App Capture",
  output_root: "~/Movies/capture",
  output_width: 1920,
  output_height: 1080,
  video_bitrate: 6000
};

const CONFIG_KEYS = new Set<keyof CaptureConfig>([
  "obs_host",
  "obs_port",
  "obs_password",
  "obs_profile",
  "obs_scene_collection",
  "obs_scene",
  "output_root",
  "output_width",
  "output_height",
  "video_bitrate"
]);

const APP_ALIASES: ResolvedApp[] = [
  {
    display_name: "Firefox",
    bundle_id: "org.mozilla.firefox",
    app_path: "/Applications/Firefox.app",
    aliases: ["firefox"]
  },
  {
    display_name: "Google Chrome",
    bundle_id: "com.google.Chrome",
    app_path: "/Applications/Google Chrome.app",
    aliases: ["chrome", "google chrome"]
  },
  {
    display_name: "zoom.us",
    bundle_id: "us.zoom.xos",
    app_path: "/Applications/zoom.us.app",
    aliases: ["zoom", "zoom.us"]
  }
];

function expandHome(value: string): string {
  if (value === "~") return homedir();
  if (value.startsWith("~/")) return join(homedir(), value.slice(2));
  return value;
}

function configDir(): string {
  return process.env.XDG_CONFIG_HOME ? resolve(expandHome(process.env.XDG_CONFIG_HOME)) : join(homedir(), ".config");
}

function configPath(): string {
  return join(configDir(), "capture", "config.toml");
}

function statePath(): string {
  return join(homedir(), ".local", "share", "capture", "state.json");
}

function obsAppPath(): string | undefined {
  const candidates = ["/Applications/OBS.app", "/Applications/OBS Studio.app"];
  return candidates.find((candidate) => existsSync(candidate));
}

function obsConfigRoot(): string {
  return join(homedir(), "Library", "Application Support", "obs-studio");
}

function obsWebSocketConfigPath(): string {
  return join(obsConfigRoot(), "plugin_config", "obs-websocket", "config.json");
}

function ensureDir(path: string): void {
  mkdirSync(path, { recursive: true });
}

function writeJsonFile(path: string, data: unknown): void {
  ensureDir(dirname(path));
  writeFileSync(path, `${JSON.stringify(data, null, 2)}\n`);
}

function readJsonFile<T>(path: string): T | undefined {
  if (!existsSync(path)) return undefined;
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function parseTomlConfig(contents: string): Partial<CaptureConfig> {
  const result: Partial<CaptureConfig> = {};
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = /^([A-Za-z0-9_]+)\s*=\s*(.+)$/.exec(line);
    if (!match) continue;
    const key = match[1] as keyof CaptureConfig;
    if (!CONFIG_KEYS.has(key)) continue;
    const rawValue = match[2].trim();
    if (rawValue.startsWith('"') && rawValue.endsWith('"')) {
      result[key] = rawValue.slice(1, -1).replace(/\\"/g, '"') as never;
    } else if (/^-?\d+$/.test(rawValue)) {
      result[key] = Number(rawValue) as never;
    } else if (rawValue === "null") {
      result[key] = undefined as never;
    }
  }
  return result;
}

function formatTomlConfig(config: CaptureConfig): string {
  const lines = [
    `obs_host = ${tomlValue(config.obs_host)}`,
    `obs_port = ${config.obs_port}`,
    config.obs_password ? `obs_password = ${tomlValue(config.obs_password)}` : undefined,
    `obs_profile = ${tomlValue(config.obs_profile)}`,
    `obs_scene_collection = ${tomlValue(config.obs_scene_collection)}`,
    `obs_scene = ${tomlValue(config.obs_scene)}`,
    `output_root = ${tomlValue(config.output_root)}`,
    config.output_width ? `output_width = ${config.output_width}` : undefined,
    config.output_height ? `output_height = ${config.output_height}` : undefined,
    `video_bitrate = ${config.video_bitrate}`
  ].filter(Boolean);
  return `${lines.join("\n")}\n`;
}

function tomlValue(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function loadConfig(): CaptureConfig {
  const path = configPath();
  if (!existsSync(path)) return { ...DEFAULT_CONFIG };
  return normalizeConfig({ ...DEFAULT_CONFIG, ...parseTomlConfig(readFileSync(path, "utf8")) });
}

function normalizeConfig(config: CaptureConfig): CaptureConfig {
  return {
    ...config,
    obs_port: numberOrDefault(config.obs_port, DEFAULT_CONFIG.obs_port),
    output_width: optionalPositiveInteger(config.output_width),
    output_height: optionalPositiveInteger(config.output_height),
    video_bitrate: numberOrDefault(config.video_bitrate, DEFAULT_CONFIG.video_bitrate)
  };
}

function numberOrDefault(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : fallback;
}

function optionalPositiveInteger(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : undefined;
}

function writeConfig(config: CaptureConfig): void {
  const path = configPath();
  ensureDir(dirname(path));
  writeFileSync(path, formatTomlConfig(normalizeConfig(config)));
}

function readState(): CaptureState | undefined {
  return readJsonFile<CaptureState>(statePath());
}

function writeState(state: CaptureState): void {
  writeJsonFile(statePath(), state);
}

function clearState(): void {
  if (existsSync(statePath())) rmSync(statePath());
}

function finalizeStateMetadata(state: CaptureState | undefined, options: { stoppedAt: string; outputPath?: string; error?: string }): FinalizedCaptureMetadata | undefined {
  if (!state?.metadata_path || !existsSync(state.metadata_path)) return undefined;
  const metadata = readJsonFile<CaptureMetadata>(state.metadata_path);
  if (!metadata) return undefined;
  const finalized: FinalizedCaptureMetadata = {
    ...metadata,
    active: false,
    stopped_at: options.stoppedAt,
    output_path: options.outputPath ?? metadata.output_path,
    error: options.error
  };
  if (!finalized.output_path) delete finalized.output_path;
  if (!finalized.error) delete finalized.error;
  writeJsonFile(state.metadata_path, finalized);
  return finalized;
}

function printJson(data: unknown): void {
  process.stdout.write(`${JSON.stringify(data, null, 2)}\n`);
}

function printHuman(message: string): void {
  process.stdout.write(`${message}\n`);
}

function fail(message: string, payload?: JsonObject): never {
  throw new CliError(message, 1, payload);
}

function errorMessage(error: unknown): string {
  const message = error instanceof Error ? error.message : String(error);
  return message.trim() || "unknown error";
}

function commandExists(command: string): boolean {
  if (command.includes("/")) return existsSync(expandHome(command));
  const pathEntries = (process.env.PATH ?? "").split(":").filter(Boolean);
  return pathEntries.some((entry) => existsSync(join(entry, command)));
}

function run(command: string, args: string[], options: { input?: string; timeoutMs?: number } = {}): { status: number | null; stdout: string; stderr: string; timedOut: boolean } {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    input: options.input,
    timeout: options.timeoutMs,
    stdio: ["pipe", "pipe", "pipe"]
  });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    timedOut: result.error?.message.includes("ETIMEDOUT") ?? false
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, ms));
}

function sanitizeName(value: string): string {
  return value.replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "app";
}

function timestampForPath(date = new Date()): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z").replace(/[:]/g, "-");
}

function isMac(): boolean {
  return process.platform === "darwin";
}

function pathIsReadable(path: string): boolean {
  try {
    statSync(path);
    return true;
  } catch {
    return false;
  }
}

function bundleIdForApp(appPath: string): string | undefined {
  const infoPlist = join(appPath, "Contents", "Info.plist");
  if (!existsSync(infoPlist)) return undefined;
  const result = run("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleIdentifier", infoPlist]);
  return result.status === 0 ? result.stdout.trim() || undefined : undefined;
}

function displayNameForApp(appPath: string): string {
  const infoPlist = join(appPath, "Contents", "Info.plist");
  if (existsSync(infoPlist)) {
    for (const key of ["CFBundleDisplayName", "CFBundleName"]) {
      const result = run("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, infoPlist]);
      if (result.status === 0 && result.stdout.trim()) return result.stdout.trim();
    }
  }
  return basename(appPath, ".app");
}

function installedApps(): ResolvedApp[] {
  const roots = ["/Applications", join(homedir(), "Applications")];
  const apps = new Map<string, ResolvedApp>();
  for (const root of roots) {
    if (!existsSync(root)) continue;
    const find = run("/usr/bin/find", [root, "-maxdepth", "2", "-name", "*.app", "-type", "d"]);
    if (find.status !== 0) continue;
    for (const appPath of find.stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)) {
      const displayName = displayNameForApp(appPath);
      const bundleId = bundleIdForApp(appPath);
      const key = (bundleId ?? appPath).toLowerCase();
      apps.set(key, {
        display_name: displayName,
        bundle_id: bundleId,
        app_path: appPath
      });
    }
  }
  for (const alias of APP_ALIASES) {
    if (alias.app_path && existsSync(alias.app_path)) {
      const key = (alias.bundle_id ?? alias.app_path).toLowerCase();
      apps.set(key, { ...alias });
    }
  }
  return [...apps.values()].sort((a, b) => a.display_name.localeCompare(b.display_name));
}

function resolveApp(input: string): ResolvedApp | undefined {
  const wanted = input.trim().toLowerCase();
  if (!wanted) return undefined;

  const alias = APP_ALIASES.find((app) => {
    return app.aliases?.some((candidate) => candidate.toLowerCase() === wanted) ||
      app.display_name.toLowerCase() === wanted ||
      app.bundle_id?.toLowerCase() === wanted;
  });
  if (alias && (!alias.app_path || existsSync(alias.app_path))) return { ...alias };

  if (input.endsWith(".app") && existsSync(expandHome(input))) {
    const appPath = resolve(expandHome(input));
    return {
      display_name: displayNameForApp(appPath),
      bundle_id: bundleIdForApp(appPath),
      app_path: appPath
    };
  }

  for (const app of installedApps()) {
    const candidates = [app.display_name, app.bundle_id, app.app_path].filter(Boolean).map((value) => value!.toLowerCase());
    if (candidates.includes(wanted)) return app;
  }

  return undefined;
}

function appWindowSize(app: ResolvedApp): { width?: number; height?: number; visibleWindowCount?: number } {
  if (!isMac()) return {};
  const processName = app.display_name.replace(/"/g, '\\"');
  const script = [
    'tell application "System Events"',
    `  set targetProcesses to processes whose name is "${processName}"`,
    "  if (count of targetProcesses) is 0 then return \"0\"",
    "  tell item 1 of targetProcesses",
    "    try",
    "      if visible is false then return \"0\"",
    "    end try",
    "    set usableWindowCount to 0",
    "    set bestWidth to 0",
    "    set bestHeight to 0",
    "    set bestArea to 0",
    "    repeat with candidateWindow in windows",
    "      set isUsable to true",
    "      try",
    "        if visible of candidateWindow is false then set isUsable to false",
    "      end try",
    "      try",
    "        if value of attribute \"AXMinimized\" of candidateWindow is true then set isUsable to false",
    "      end try",
    "      try",
    "        set windowSize to size of candidateWindow",
    "        set currentWidth to item 1 of windowSize",
    "        set currentHeight to item 2 of windowSize",
    "        if currentWidth <= 0 or currentHeight <= 0 then set isUsable to false",
    "      on error",
    "        set isUsable to false",
    "      end try",
    "      if isUsable then",
    "        set usableWindowCount to usableWindowCount + 1",
    "        set currentArea to currentWidth * currentHeight",
    "        if currentArea > bestArea then",
    "          set bestArea to currentArea",
    "          set bestWidth to currentWidth",
    "          set bestHeight to currentHeight",
    "        end if",
    "      end if",
    "    end repeat",
    "    if usableWindowCount is 0 then return \"0\"",
    "    return (usableWindowCount as text) & \",\" & (bestWidth as text) & \",\" & (bestHeight as text)",
    "  end tell",
    "end tell"
  ].join("\n");
  const result = run("/usr/bin/osascript", ["-e", script], { timeoutMs: 3000 });
  if (result.status !== 0 || result.timedOut) return {};
  const parts = result.stdout.trim().split(",").map((part) => Number(part));
  if (parts.length === 1) return { visibleWindowCount: parts[0] };
  const [visibleWindowCount, width, height] = parts;
  return {
    visibleWindowCount,
    width: optionalPositiveInteger(width),
    height: optionalPositiveInteger(height)
  };
}

function positiveInteger(value: unknown, label: string): number | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) fail(`${label} must be a positive integer.`);
  return parsed;
}

function computeVideoDetails(config: CaptureConfig, options: { width?: string; height?: string; videoBitrate?: string }, source: { width?: number; height?: number }): VideoDetails {
  const requestedWidth = positiveInteger(options.width, "Width");
  const requestedHeight = positiveInteger(options.height, "Height");
  const requestedBitrate = positiveInteger(options.videoBitrate, "Video bitrate");
  const sourceWidth = source.width ?? 1920;
  const sourceHeight = source.height ?? 1080;
  const aspectRatio = sourceWidth / sourceHeight;

  let width = requestedWidth ?? config.output_width;
  let height = requestedHeight ?? config.output_height;
  let sizingMode = "auto";

  if (requestedWidth && requestedHeight) {
    sizingMode = "explicit";
  } else if (requestedWidth && !requestedHeight) {
    height = Math.max(1, Math.round(requestedWidth / aspectRatio));
    sizingMode = "width-derived-height";
  } else if (!requestedWidth && requestedHeight) {
    width = Math.max(1, Math.round(requestedHeight * aspectRatio));
    sizingMode = "height-derived-width";
  } else if (width && !height) {
    height = Math.max(1, Math.round(width / aspectRatio));
    sizingMode = "configured-width-derived-height";
  } else if (!width && height) {
    width = Math.max(1, Math.round(height * aspectRatio));
    sizingMode = "configured-height-derived-width";
  } else if (!width && !height) {
    const maxWidth = 2560;
    const maxHeight = 1440;
    const scale = Math.min(1, maxWidth / sourceWidth, maxHeight / sourceHeight);
    width = Math.max(1, Math.round(sourceWidth * scale));
    height = Math.max(1, Math.round(sourceHeight * scale));
  }

  if (!width || !height) fail("Unable to determine recording dimensions.");

  return {
    width,
    height,
    bitrate: requestedBitrate ?? config.video_bitrate,
    sizing_mode: sizingMode,
    source_width: source.width,
    source_height: source.height,
    capture_mode: "macos-application"
  };
}

async function connectObs(config: CaptureConfig, options: { launchIfNeeded?: boolean } = {}): Promise<OBSWebSocket> {
  const obs = new OBSWebSocket();
  const url = `ws://${config.obs_host}:${config.obs_port}`;
  try {
    await obs.connect(url, config.obs_password || undefined);
    return obs;
  } catch (firstError) {
    if (!options.launchIfNeeded || !isMac()) {
      throw firstError;
    }
    const app = obsAppPath();
    if (!app) throw firstError;
    spawn("/usr/bin/open", [app], { detached: true, stdio: "ignore" }).unref();
    const deadline = Date.now() + 15_000;
    let lastError = firstError;
    while (Date.now() < deadline) {
      await new Promise((resolveDelay) => setTimeout(resolveDelay, 1000));
      try {
        await obs.connect(url, config.obs_password || undefined);
        return obs;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError;
  }
}

async function obsRecordingStatus(obs: OBSWebSocket): Promise<JsonObject> {
  return await obs.call("GetRecordStatus") as JsonObject;
}

function isObsRecording(status: JsonObject): boolean {
  return Boolean(status.outputActive || status.outputPaused);
}

async function currentObsVideoSettings(obs: OBSWebSocket): Promise<{ outputWidth?: number; outputHeight?: number } | undefined> {
  try {
    const settings = await obs.call("GetVideoSettings") as { outputWidth?: number; outputHeight?: number };
    return {
      outputWidth: optionalPositiveInteger(settings.outputWidth),
      outputHeight: optionalPositiveInteger(settings.outputHeight)
    };
  } catch {
    return undefined;
  }
}

async function currentObsProfile(obs: OBSWebSocket): Promise<string | undefined> {
  const profiles = await obs.call("GetProfileList") as { currentProfileName?: string };
  return profiles.currentProfileName;
}

async function currentObsSceneCollection(obs: OBSWebSocket): Promise<string | undefined> {
  const collections = await obs.call("GetSceneCollectionList") as { currentSceneCollectionName?: string };
  return collections.currentSceneCollectionName;
}

async function configureAudioRouting(obs: OBSWebSocket, inputName: string): Promise<void> {
  await ignoreObsFailure(obs.call("SetInputMute", { inputName, inputMuted: false }), "SetInputMute");
  await ignoreObsFailure(obs.call("SetInputVolume", { inputName, inputVolumeMul: 1 }), "SetInputVolume");
  await ignoreObsFailure(obs.call("SetInputAudioTracks", {
    inputName,
    inputAudioTracks: {
      "1": true,
      "2": true,
      "3": true,
      "4": true,
      "5": true,
      "6": true
    }
  }), "SetInputAudioTracks");
}

async function defaultDisplayUuid(obs: OBSWebSocket): Promise<string | undefined> {
  for (const inputKind of ["screen_capture", "display_capture"]) {
    try {
      const defaults = await obs.call("GetInputDefaultSettings", { inputKind }) as { defaultInputSettings?: { display_uuid?: string } };
      const displayUuid = defaults.defaultInputSettings?.display_uuid;
      if (typeof displayUuid === "string" && displayUuid.trim()) return displayUuid;
    } catch {
      // Some OBS builds omit legacy display capture sources.
    }
  }
  return undefined;
}

async function defaultApplicationCaptureSettings(obs: OBSWebSocket, app: ResolvedApp): Promise<Record<string, string | number | boolean>> {
  if (!app.bundle_id) {
    fail(`Unable to configure application video for ${app.display_name} because no bundle identifier was resolved.`);
  }
  const displayUuid = await defaultDisplayUuid(obs);
  if (!displayUuid) {
    fail("Unable to determine the OBS display UUID required for macOS application capture.");
  }
  const settings: Record<string, string | number | boolean> = {
    type: 2,
    application: app.bundle_id,
    display_uuid: displayUuid,
    show_cursor: true,
    show_hidden_windows: true
  };
  return settings;
}

async function waitForVideoSourceReady(obs: OBSWebSocket, sceneName: string, sourceName: string, timeoutMs = 3000): Promise<{ width: number; height: number } | undefined> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const itemList = await obs.call("GetSceneItemList", { sceneName }) as { sceneItems?: Array<{ sourceName?: string; sceneItemTransform?: { sourceWidth?: number; sourceHeight?: number } }> };
      const item = itemList.sceneItems?.find((candidate) => candidate.sourceName === sourceName);
      const width = optionalPositiveInteger(item?.sceneItemTransform?.sourceWidth);
      const height = optionalPositiveInteger(item?.sceneItemTransform?.sourceHeight);
      if (width && height) return { width, height };
    } catch {
      // Retry briefly while OBS initializes the source.
    }
    await sleep(200);
  }
  return undefined;
}

async function ensureObsCaptureScene(obs: OBSWebSocket, config: CaptureConfig, app: ResolvedApp, video: VideoDetails, outputDir: string): Promise<void> {
  const currentProfile = await currentObsProfile(obs).catch(() => undefined);
  if (currentProfile && currentProfile !== config.obs_profile) {
    await ignoreObsFailure(obs.call("SetCurrentProfile", { profileName: config.obs_profile }), "SetCurrentProfile");
  }

  const currentSceneCollection = await currentObsSceneCollection(obs).catch(() => undefined);
  if (currentSceneCollection && currentSceneCollection !== config.obs_scene_collection) {
    await ignoreObsFailure(obs.call("SetCurrentSceneCollection", { sceneCollectionName: config.obs_scene_collection }), "SetCurrentSceneCollection");
  }

  const obsVideo = await currentObsVideoSettings(obs);
  if (obsVideo?.outputWidth && obsVideo?.outputHeight && (obsVideo.outputWidth !== video.width || obsVideo.outputHeight !== video.height)) {
    fail(`OBS output is currently ${obsVideo.outputWidth}x${obsVideo.outputHeight}, but this capture requires ${video.width}x${video.height}. Run capture setup --force and restart OBS so the capture profile loads the requested dimensions.`);
  }

  await ignoreObsFailure(obs.call("SetCurrentProgramScene", { sceneName: config.obs_scene }), "SetCurrentProgramScene");

  try {
    const sceneList = await obs.call("GetSceneList") as { scenes?: Array<{ sceneName?: string }> };
    const hasScene = sceneList.scenes?.some((scene) => scene.sceneName === config.obs_scene);
    if (!hasScene) await obs.call("CreateScene", { sceneName: config.obs_scene });
  } catch {
    await obs.call("CreateScene", { sceneName: config.obs_scene });
  }

  await ignoreObsFailure(obs.call("SetCurrentProgramScene", { sceneName: config.obs_scene }), "SetCurrentProgramScene");
  await ignoreObsFailure(obs.call("SetProfileParameter", {
    parameterCategory: "SimpleOutput",
    parameterName: "FilePath",
    parameterValue: outputDir
  }), "SetProfileParameter:FilePath");
  await ignoreObsFailure(obs.call("SetProfileParameter", {
    parameterCategory: "SimpleOutput",
    parameterName: "VBitrate",
    parameterValue: String(video.bitrate)
  }), "SetProfileParameter:VBitrate");

  const inputName = `Capture - ${app.display_name}`;
  const audioInputName = `Capture Audio - ${app.display_name}`;
  const desktopAudioInputName = "Capture Desktop Audio";
  const inputSettings = await defaultApplicationCaptureSettings(obs, app);

  let inputExists = false;
  let inputKind: string | undefined;
  let audioInputExists = false;
  let desktopAudioInputExists = false;
  try {
    const inputList = await obs.call("GetInputList") as { inputs?: Array<{ inputName?: string; inputKind?: string }> };
    const existingInput = inputList.inputs?.find((input) => input.inputName === inputName);
    inputExists = Boolean(existingInput);
    inputKind = existingInput?.inputKind;
    audioInputExists = Boolean(inputList.inputs?.some((input) => input.inputName === audioInputName));
    desktopAudioInputExists = Boolean(inputList.inputs?.some((input) => input.inputName === desktopAudioInputName));
  } catch {
    inputExists = false;
    audioInputExists = false;
    desktopAudioInputExists = false;
  }

  if (inputExists && inputKind && inputKind !== "screen_capture") {
    await obs.call("RemoveInput", { inputName });
    inputExists = false;
  }

  if (!inputExists) {
    const kinds = ["screen_capture"];
    let created = false;
    const errors: string[] = [];
    for (const inputKind of kinds) {
      try {
        await obs.call("CreateInput", {
          sceneName: config.obs_scene,
          inputName,
          inputKind,
          inputSettings,
          sceneItemEnabled: true
        });
        created = true;
        break;
      } catch (error) {
        errors.push(`${inputKind}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    if (!created) {
      fail(`Unable to create an OBS application capture source for ${app.display_name}. ${errors.join("; ")}`);
    }
  } else {
    await ignoreObsFailure(obs.call("SetInputSettings", {
      inputName,
      inputSettings,
      overlay: false
    }), "SetInputSettings");
  }

  const sourceDimensions = await waitForVideoSourceReady(obs, config.obs_scene, inputName);
  if (!sourceDimensions) {
    fail(`OBS video source for ${app.display_name} did not produce visible frames. Bring the app window to the front and verify OBS has macOS Screen Recording permission.`);
  }

  if (!app.bundle_id) {
    fail(`Unable to configure application audio for ${app.display_name} because no bundle identifier was resolved.`);
  }

  const audioInputSettings = {
    type: 1,
    application: app.bundle_id
  };
  if (!audioInputExists) {
    try {
      await obs.call("CreateInput", {
        sceneName: config.obs_scene,
        inputName: audioInputName,
        inputKind: "sck_audio_capture",
        inputSettings: audioInputSettings,
        sceneItemEnabled: true
      });
    } catch (error) {
      fail(`Unable to create an OBS application audio capture source for ${app.display_name}. ${errorMessage(error)}`);
    }
  } else {
    await obs.call("SetInputSettings", {
      inputName: audioInputName,
      inputSettings: audioInputSettings,
      overlay: true
    });
  }
  await configureAudioRouting(obs, audioInputName);

  const desktopAudioInputSettings = {
    device_id: "default",
    enable_downmix: true
  };
  if (!desktopAudioInputExists) {
    try {
      await obs.call("CreateInput", {
        sceneName: config.obs_scene,
        inputName: desktopAudioInputName,
        inputKind: "coreaudio_output_capture",
        inputSettings: desktopAudioInputSettings,
        sceneItemEnabled: true
      });
    } catch (error) {
      fail(`Unable to create an OBS desktop audio fallback source. ${errorMessage(error)}`);
    }
  } else {
    await obs.call("SetInputSettings", {
      inputName: desktopAudioInputName,
      inputSettings: desktopAudioInputSettings,
      overlay: true
    });
  }
  await configureAudioRouting(obs, desktopAudioInputName);

  try {
    const item = await obs.call("GetSceneItemId", { sceneName: config.obs_scene, sourceName: inputName }) as { sceneItemId?: number };
    if (item.sceneItemId !== undefined) {
      await ignoreObsFailure(obs.call("SetSceneItemTransform", {
        sceneName: config.obs_scene,
        sceneItemId: item.sceneItemId,
        sceneItemTransform: {
          alignment: 5,
          boundsType: "OBS_BOUNDS_SCALE_INNER",
          boundsAlignment: 5,
          boundsWidth: video.width,
          boundsHeight: video.height,
          positionX: 0,
          positionY: 0
        }
      }), "SetSceneItemTransform");
    }
  } catch {
    // Fitting is best-effort because input kind names differ across OBS releases.
  }
}

async function ignoreObsFailure(promise: Promise<unknown>, _label: string): Promise<void> {
  try {
    await promise;
  } catch {
    // Compatibility calls are allowed to fail on older or differently configured OBS profiles.
  }
}

async function waitForRecordingFileReady(outputPath: string | undefined, timeoutMs = 5000): Promise<void> {
  if (!outputPath) return;
  const deadline = Date.now() + timeoutMs;
  const hasFfprobe = commandExists("ffprobe");
  let lastSize = -1;
  let stableSince = 0;

  while (Date.now() < deadline) {
    if (existsSync(outputPath)) {
      const size = statSync(outputPath).size;
      if (size > 0 && hasFfprobe) {
        const probe = run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "default=nokey=1:noprint_wrappers=1", outputPath], { timeoutMs: 1000 });
        if (probe.status === 0 && probe.stdout.trim()) return;
      }
      if (size > 0 && !hasFfprobe && size === lastSize) {
        if (!stableSince) stableSince = Date.now();
        if (Date.now() - stableSince >= 500) return;
      } else {
        stableSince = 0;
        lastSize = size;
      }
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 200));
  }
}

function setupFiles(config: CaptureConfig): Array<{ path: string; description: string; content: string }> {
  const profileDir = join(obsConfigRoot(), "basic", "profiles", sanitizeName(config.obs_profile));
  const scenePath = join(obsConfigRoot(), "basic", "scenes", `${sanitizeName(config.obs_scene_collection)}.json`);
  const websocketPath = obsWebSocketConfigPath();
  return [
    {
      path: join(profileDir, "basic.ini"),
      description: "OBS capture profile",
      content: [
        "[General]",
        `Name=${config.obs_profile}`,
        "",
        "[Video]",
        `BaseCX=${config.output_width ?? 1920}`,
        `BaseCY=${config.output_height ?? 1080}`,
        `OutputCX=${config.output_width ?? 1920}`,
        `OutputCY=${config.output_height ?? 1080}`,
        "FPSType=0",
        "FPSCommon=30",
        "",
        "[Output]",
        "Mode=Simple",
        "",
        "[SimpleOutput]",
        `FilePath=${expandHome(config.output_root)}`,
        "RecFormat2=mp4",
        `VBitrate=${config.video_bitrate}`
      ].join("\n")
    },
    {
      path: scenePath,
      description: "OBS capture scene collection",
      content: `${JSON.stringify({
        name: config.obs_scene_collection,
        current_scene: config.obs_scene,
        sources: [
          {
            name: config.obs_scene,
            id: "scene",
            settings: { items: [] },
            mixers: 0,
            sync: 0,
            flags: 0,
            volume: 1,
            balance: 0,
            enabled: true,
            hotkeys: {}
          }
        ]
      }, null, 2)}\n`
    },
    {
      path: websocketPath,
      description: "OBS WebSocket configuration",
      content: `${JSON.stringify({
        server_enabled: true,
        server_port: config.obs_port,
        auth_required: Boolean(config.obs_password),
        server_password: config.obs_password ?? ""
      }, null, 2)}\n`
    }
  ];
}

function writeSetupFile(file: { path: string; content: string }, force: boolean): { path: string; touched: boolean; backup_path?: string } {
  if (existsSync(file.path)) {
    const existing = readFileSync(file.path, "utf8");
    if (existing === file.content) return { path: file.path, touched: false };
    if (!force) return { path: file.path, touched: false };
    const backupPath = `${file.path}.bak-${timestampForPath()}`;
    renameSync(file.path, backupPath);
    ensureDir(dirname(file.path));
    writeFileSync(file.path, file.content);
    return { path: file.path, touched: true, backup_path: backupPath };
  }
  ensureDir(dirname(file.path));
  writeFileSync(file.path, file.content);
  return { path: file.path, touched: true };
}

function detectObsRunning(): boolean {
  if (!isMac()) return false;
  const result = run("/usr/bin/pgrep", ["-x", "OBS"]);
  return result.status === 0;
}

async function commandSetup(options: { force?: boolean; dryRun?: boolean; json?: boolean }): Promise<void> {
  if (!isMac()) fail("capture setup is only supported on macOS.");
  const appPath = obsAppPath();
  if (!appPath) fail("OBS Studio was not found in /Applications. Install OBS Studio before running capture setup.");

  const config = loadConfig();
  const files = setupFiles(config);
  const actions = [
    { action: "verify_obs_app", path: appPath, apply: false },
    { action: "write_capture_config", path: configPath(), apply: !options.dryRun },
    ...files.map((file) => ({ action: `write_${file.description.replace(/\s+/g, "_").toLowerCase()}`, path: file.path, apply: !options.dryRun }))
  ];

  let touched: Array<{ path: string; touched: boolean; backup_path?: string }> = [];
  if (!options.dryRun) {
    writeConfig(config);
    touched = files.map((file) => writeSetupFile(file, Boolean(options.force)));
  }

  const payload = {
    status: options.dryRun ? "dry-run" : "ok",
    actions,
    config_path: configPath(),
    config,
    obs_files: touched.length ? touched : files.map((file) => ({ path: file.path, touched: false })),
    restart_required: detectObsRunning()
  };

  if (options.json) {
    printJson(payload);
  } else {
    printHuman(options.dryRun ? "capture setup dry run:" : "capture setup complete.");
    for (const action of actions) printHuman(`- ${action.action}: ${action.path}`);
    if (payload.restart_required) printHuman("OBS is currently running. Restart OBS so setup changes are loaded.");
  }
}

async function commandDoctor(options: { json?: boolean }): Promise<void> {
  const checks: DoctorCheck[] = [];
  checks.push({
    name: "macos",
    ok: isMac(),
    details: isMac() ? "Running on macOS." : `Unsupported platform: ${process.platform}.`
  });

  const appPath = obsAppPath();
  checks.push({
    name: "obs_app",
    ok: Boolean(appPath),
    details: appPath ? `Found OBS at ${appPath}.` : "OBS Studio was not found in /Applications."
  });

  checks.push({
    name: "open_command",
    ok: existsSync("/usr/bin/open") || commandExists("open"),
    details: (existsSync("/usr/bin/open") || commandExists("open")) ? "macOS open command is available." : "open command was not found."
  });

  const websocketPath = obsWebSocketConfigPath();
  let websocketOk = false;
  let websocketDetails = `OBS WebSocket config was not found at ${websocketPath}.`;
  if (existsSync(websocketPath)) {
    try {
      const parsed = JSON.parse(readFileSync(websocketPath, "utf8")) as { server_enabled?: boolean; server_port?: number; auth_required?: boolean };
      websocketOk = parsed.server_enabled === true;
      websocketDetails = websocketOk
        ? `OBS WebSocket is configured on port ${parsed.server_port ?? "unknown"}. Authentication ${parsed.auth_required ? "is" : "is not"} required.`
        : "OBS WebSocket config exists but server_enabled is not true.";
    } catch (error) {
      websocketDetails = `OBS WebSocket config could not be parsed: ${error instanceof Error ? error.message : String(error)}`;
    }
  }
  checks.push({ name: "obs_websocket_config", ok: websocketOk, details: websocketDetails });

  checks.push({
    name: "local_capture_config",
    ok: existsSync(configPath()),
    details: existsSync(configPath()) ? `Found ${configPath()}.` : `Missing ${configPath()}; run capture setup.`
  });

  const config = loadConfig();
  try {
    const obs = await connectObs(config, { launchIfNeeded: false });
    const version = await obs.call("GetVersion") as JsonObject;
    await obs.disconnect();
    checks.push({
      name: "obs_websocket_connectivity",
      ok: true,
      details: `Connected to OBS WebSocket at ${config.obs_host}:${config.obs_port}${version.obsVersion ? `, OBS ${version.obsVersion}` : ""}.`
    });
  } catch (error) {
    checks.push({
      name: "obs_websocket_connectivity",
      ok: false,
      details: `Could not connect to OBS WebSocket at ${config.obs_host}:${config.obs_port}: ${errorMessage(error)}`
    });
  }

  const ok = checks.every((check) => check.ok);
  if (options.json) {
    printJson({ ok, checks });
  } else {
    for (const check of checks) {
      printHuman(`${check.ok ? "OK" : "FAIL"} ${check.name}: ${check.details}`);
    }
  }
  if (!ok) process.exitCode = 1;
}

function commandConfig(options: { json?: boolean }): void {
  const config = loadConfig();
  const payload = {
    config,
    paths: {
      config: configPath(),
      state: statePath(),
      obs_config_root: obsConfigRoot(),
      obs_websocket_config: obsWebSocketConfigPath()
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
  if (!CONFIG_KEYS.has(key as keyof CaptureConfig)) {
    fail(`Unsupported config key "${key}". Supported keys: ${[...CONFIG_KEYS].join(", ")}`);
  }
  const config = loadConfig();
  const typedKey = key as keyof CaptureConfig;
  if (["obs_port", "output_width", "output_height", "video_bitrate"].includes(key)) {
    const parsed = positiveInteger(value, key);
    config[typedKey] = parsed as never;
  } else {
    config[typedKey] = value as never;
  }
  writeConfig(config);
  printJson({ key, value: config[typedKey], config_path: configPath() });
}

function commandApps(options: { json?: boolean }): void {
  const apps = installedApps();
  if (options.json) {
    printJson({ apps });
  } else {
    for (const app of apps) {
      printHuman(`${app.display_name}${app.bundle_id ? ` (${app.bundle_id})` : ""}${app.app_path ? ` - ${app.app_path}` : ""}`);
    }
  }
}

async function commandStart(options: { app?: string; output?: string; width?: string; height?: string; videoBitrate?: string; profile?: string; scene?: string; json?: boolean }): Promise<void> {
  if (!options.app) fail("Missing required --app APP. Run capture apps to list installed apps.");
  const activeState = readState();
  if (activeState?.active) fail(`A local capture is already active for ${activeState.app.display_name}. Stop it before starting another recording.`);

  const config = {
    ...loadConfig(),
    obs_profile: options.profile ?? loadConfig().obs_profile,
    obs_scene: options.scene ?? loadConfig().obs_scene
  };
  const app = resolveApp(options.app);
  if (!app) fail(`Could not resolve app "${options.app}". Run capture apps to list installed apps.`);

  const windowInfo = appWindowSize(app);
  if (windowInfo.visibleWindowCount === 0) fail(`${app.display_name} has no visible capturable window.`);

  const video = computeVideoDetails(config, options, windowInfo);
  const outputDir = resolve(expandHome(options.output ?? join(config.output_root, `${timestampForPath()}-${sanitizeName(app.display_name).toLowerCase()}`)));
  ensureDir(outputDir);
  const startedAt = new Date().toISOString();
  const metadataPath = join(outputDir, "metadata.json");
  const metadata: CaptureMetadata = {
    schema_version: 1,
    artifact_type: "capture_recording",
    active: true,
    app,
    obs: {
      profile: config.obs_profile,
      scene_collection: config.obs_scene_collection,
      scene: config.obs_scene
    },
    video,
    output_dir: outputDir,
    started_at: startedAt,
    metadata_path: metadataPath
  };

  let obs: OBSWebSocket | undefined;
  try {
    obs = await connectObs(config, { launchIfNeeded: true });

    const recordStatus = await obsRecordingStatus(obs);
    if (isObsRecording(recordStatus)) fail("OBS is already recording. Stop the existing OBS recording before starting capture.");

    await ensureObsCaptureScene(obs, config, app, video, outputDir);
    await obs.call("StartRecord");
    writeJsonFile(metadataPath, metadata);
    const state: CaptureState = {
      active: true,
      metadata_path: metadataPath,
      output_dir: outputDir,
      started_at: startedAt,
      app,
      obs: metadata.obs,
      video
    };
    writeState(state);

    const payload = {
      status: "recording",
      app,
      output_dir: outputDir,
      metadata
    };
    if (options.json) printJson(payload);
    else {
      printHuman(`Recording ${app.display_name}.`);
      printHuman(`Output directory: ${outputDir}`);
      printHuman(`Metadata: ${metadataPath}`);
    }
  } catch (error) {
    const failedMetadata = { ...metadata, active: false, error: errorMessage(error) };
    writeJsonFile(metadataPath, failedMetadata);
    throw error;
  } finally {
    await obs?.disconnect().catch(() => undefined);
  }
}

async function commandStop(options: { json?: boolean }): Promise<void> {
  const state = readState();
  const config = loadConfig();
  let obs: OBSWebSocket;
  try {
    obs = await connectObs(config, { launchIfNeeded: false });
  } catch (error) {
    if (!state?.active) throw error;
    const stoppedAt = new Date().toISOString();
    const metadata = finalizeStateMetadata(state, {
      stoppedAt,
      error: `OBS was unreachable while stopping: ${errorMessage(error)}`
    });
    clearState();
    const payload = {
      status: "recovered",
      reason: "obs_unreachable",
      metadata
    };
    if (options.json) printJson(payload);
    else {
      printHuman("OBS was unreachable. Cleared stale local capture state.");
      if (metadata?.metadata_path) printHuman(`Metadata: ${metadata.metadata_path}`);
    }
    return;
  }
  try {
    const recordStatus = await obsRecordingStatus(obs);
    if (!isObsRecording(recordStatus)) {
      if (!state?.active) fail("OBS is not currently recording.");
      const stoppedAt = new Date().toISOString();
      const metadata = finalizeStateMetadata(state, {
        stoppedAt,
        error: "OBS was not recording when capture stop was requested."
      });
      clearState();
      const payload = {
        status: "recovered",
        reason: "obs_not_recording",
        metadata
      };
      if (options.json) printJson(payload);
      else {
        printHuman("OBS was not recording. Cleared stale local capture state.");
        if (metadata?.metadata_path) printHuman(`Metadata: ${metadata.metadata_path}`);
      }
      return;
    }
    const result = await obs.call("StopRecord") as { outputPath?: string };
    const outputPath = result.outputPath;
    await waitForRecordingFileReady(outputPath);
    const stoppedAt = new Date().toISOString();
    const metadata = finalizeStateMetadata(state, { stoppedAt, outputPath });
    clearState();
    const payload = {
      status: "stopped",
      output_path: outputPath,
      metadata
    };
    if (options.json) printJson(payload);
    else {
      printHuman("Recording stopped.");
      if (outputPath) printHuman(`Output: ${outputPath}`);
      if (metadata?.metadata_path) printHuman(`Metadata: ${metadata.metadata_path}`);
    }
  } finally {
    await obs.disconnect().catch(() => undefined);
  }
}

async function commandStatus(options: { json?: boolean }): Promise<void> {
  const state = readState();
  const config = loadConfig();
  let obs_status: JsonObject | undefined;
  let obs_error: string | undefined;
  try {
    const obs = await connectObs(config, { launchIfNeeded: false });
    obs_status = await obsRecordingStatus(obs);
    await obs.disconnect();
  } catch (error) {
    obs_error = errorMessage(error);
  }
  const payload = {
    state: state ?? { active: false },
    obs_recording_state: obs_status,
    obs_error
  };
  if (options.json) printJson(payload);
  else {
    printHuman(`Local state: ${state?.active ? `active (${state.app.display_name})` : "inactive"}`);
    if (obs_status) {
      printHuman(`OBS recording: ${isObsRecording(obs_status) ? "active" : "inactive"}`);
    } else {
      printHuman(`OBS recording: unknown (${obs_error})`);
    }
  }
}

async function commandPauseResume(action: "pause" | "resume", options: { json?: boolean }): Promise<void> {
  const config = loadConfig();
  const obs = await connectObs(config, { launchIfNeeded: false });
  try {
    await obs.call(action === "pause" ? "PauseRecord" : "ResumeRecord");
    const status = await obsRecordingStatus(obs);
    const payload = { status: action === "pause" ? "paused" : "recording", obs_recording_state: status };
    if (options.json) printJson(payload);
    else printHuman(action === "pause" ? "Recording paused." : "Recording resumed.");
  } finally {
    await obs.disconnect().catch(() => undefined);
  }
}

function installErrorHandler(program: Command): void {
  program.exitOverride();
  process.on("uncaughtException", (error) => {
    if (error instanceof CliError) {
      process.stderr.write(`${error.message}\n`);
      if (error.payload) process.stderr.write(`${JSON.stringify(error.payload, null, 2)}\n`);
      process.exit(error.exitCode);
    }
    const errorCode = (error as { code?: unknown }).code;
    if (errorCode === "commander.helpDisplayed") process.exit(0);
    if (typeof errorCode === "string" && errorCode.startsWith("commander.")) {
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
    .name("capture")
    .description("Record one visible macOS application through OBS Studio.")
    .version("0.1.0");

  program.command("setup")
    .option("--force", "refresh generated OBS/config assets")
    .option("--dry-run", "report intended setup actions without writing files")
    .option("--json", "print machine-readable output")
    .action((options) => commandSetup(options));

  program.command("doctor")
    .option("--json", "print machine-readable output")
    .action((options) => commandDoctor(options));

  const config = program.command("config")
    .option("--json", "print machine-readable output")
    .action((options) => commandConfig(options));

  config.command("set")
    .argument("<key>")
    .argument("<value>")
    .action((key, value) => commandConfigSet(key, value));

  program.command("apps")
    .option("--json", "print machine-readable output")
    .action((options) => commandApps(options));

  program.command("start")
    .requiredOption("--app <app>", "friendly alias, installed app name, bundle identifier, or .app path")
    .option("--output <dir>", "recording output directory")
    .option("--width <px>", "recording width")
    .option("--height <px>", "recording height")
    .option("--video-bitrate <kbps>", "recording video bitrate")
    .option("--profile <name>", "OBS profile name")
    .option("--scene <name>", "OBS scene name")
    .option("--json", "print machine-readable output")
    .action((options) => commandStart(options));

  program.command("stop")
    .option("--json", "print machine-readable output")
    .action((options) => commandStop(options));

  program.command("status")
    .option("--json", "print machine-readable output")
    .action((options) => commandStatus(options));

  program.command("pause")
    .option("--json", "print machine-readable output")
    .action((options) => commandPauseResume("pause", options));

  program.command("resume")
    .option("--json", "print machine-readable output")
    .action((options) => commandPauseResume("resume", options));

  await program.parseAsync(process.argv);
}

main().catch((error) => {
  const commanderCode = (error as { code?: unknown }).code;
  if (commanderCode === "commander.helpDisplayed" || commanderCode === "commander.version") process.exit(0);
  if (typeof commanderCode === "string" && commanderCode.startsWith("commander.")) {
    if (error instanceof Error && error.message !== "(outputHelp)") process.stderr.write(`${error.message}\n`);
    process.exit((error as { exitCode?: number }).exitCode ?? 1);
  }
  if (error instanceof CliError) throw error;
  process.stderr.write(`${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(1);
});
