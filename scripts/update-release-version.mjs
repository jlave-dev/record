#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const checkOnly = process.argv.includes("--check");
const requestedVersion = process.argv.find((argument) => argument !== "--check" && argument !== process.argv[0] && argument !== process.argv[1]);

function assertVersion(version) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error(`Expected a stable semantic version, received "${version ?? ""}".`);
  }
}

async function readJson(relativePath) {
  return JSON.parse(await readFile(path.join(repoRoot, relativePath), "utf8"));
}

async function writeJson(relativePath, value) {
  await writeFile(path.join(repoRoot, relativePath), `${JSON.stringify(value, null, 2)}\n`);
}

async function replace(relativePath, pattern, replacement) {
  const filePath = path.join(repoRoot, relativePath);
  const source = await readFile(filePath, "utf8");
  if (!pattern.test(source)) {
    throw new Error(`Version marker was not found in ${relativePath}.`);
  }
  const updated = source.replace(pattern, replacement);
  if (updated !== source) {
    await writeFile(filePath, updated);
  }
}

async function checkVersion(expectedVersion) {
  const checks = [];
  for (const relativePath of [
    "package.json",
    "packages/capture/package.json",
    "packages/transcribe/package.json",
    "plugins/record/.codex-plugin/plugin.json",
  ]) {
    checks.push([relativePath, (await readJson(relativePath)).version]);
  }

  const packageLock = await readJson("package-lock.json");
  checks.push(
    ["package-lock.json", packageLock.version],
    ["package-lock.json workspace root", packageLock.packages[""].version],
    ["package-lock.json capture workspace", packageLock.packages["packages/capture"].version],
    ["package-lock.json transcribe workspace", packageLock.packages["packages/transcribe"].version],
  );

  const textChecks = [
    ["scripts/record", "scripts/record", /^version="([^"]+)"/m],
    [
      "packages/capture/native/Sources/CaptureCLI/main.swift",
      "packages/capture/native/Sources/CaptureCLI/main.swift",
      /case "--version", "-V":\s+print\("([^"]+)"\)/m,
    ],
    ["packages/transcribe/src/index.ts", "packages/transcribe/src/index.ts", /\.version\("([^"]+)"\)/],
    ["Formula/record.rb", "Formula/record.rb", /^  version "([^"]+)"/m],
    ["Formula/record.rb release URL", "Formula/record.rb", /releases\/download\/v([^/]+)\//],
  ];
  for (const [label, relativePath, pattern] of textChecks) {
    const match = (await readFile(path.join(repoRoot, relativePath), "utf8")).match(pattern);
    checks.push([label, match?.[1]]);
  }

  const mismatches = checks.filter(([, actualVersion]) => actualVersion !== expectedVersion);
  if (mismatches.length > 0) {
    throw new Error(mismatches.map(([file, actual]) => `${file}: ${actual ?? "missing"} (expected ${expectedVersion})`).join("\n"));
  }
}

async function updateVersion(version) {
  assertVersion(version);

  for (const relativePath of [
    "package.json",
    "packages/capture/package.json",
    "packages/transcribe/package.json",
    "plugins/record/.codex-plugin/plugin.json",
  ]) {
    const value = await readJson(relativePath);
    value.version = version;
    await writeJson(relativePath, value);
  }

  const packageLock = await readJson("package-lock.json");
  packageLock.version = version;
  packageLock.packages[""].version = version;
  packageLock.packages["packages/capture"].version = version;
  packageLock.packages["packages/transcribe"].version = version;
  await writeJson("package-lock.json", packageLock);

  await replace("scripts/record", /^version="[^"]+"/m, `version="${version}"`);
  await replace(
    "packages/capture/native/Sources/CaptureCLI/main.swift",
    /(case "--version", "-V":\s+print\(")[^"]+("\))/m,
    `$1${version}$2`,
  );
  await replace("packages/transcribe/src/index.ts", /\.version\("[^"]+"\)/, `.version("${version}")`);
  await replace(
    "Formula/record.rb",
    /releases\/download\/v[^/]+\/record-[^/]+-macos-arm64\.tar\.gz/,
    `releases/download/v${version}/record-${version}-macos-arm64.tar.gz`,
  );
  await replace("Formula/record.rb", /^  version "[^"]+"/m, `  version "${version}"`);
  await checkVersion(version);
}

const packageVersion = (await readJson("package.json")).version;
if (checkOnly) {
  assertVersion(packageVersion);
  await checkVersion(packageVersion);
  console.log(`Release version ${packageVersion} is consistent.`);
} else {
  assertVersion(requestedVersion);
  await updateVersion(requestedVersion);
  console.log(`Updated release version to ${requestedVersion}.`);
}
