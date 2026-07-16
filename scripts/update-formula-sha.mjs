#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const archivePath = process.argv[2];
if (!archivePath) {
  throw new Error("Usage: update-formula-sha.mjs ARCHIVE");
}

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const formulaPath = path.join(repoRoot, "Formula", "record.rb");
const archive = await readFile(archivePath);
const sha256 = createHash("sha256").update(archive).digest("hex");
const formula = await readFile(formulaPath, "utf8");
if (!/  sha256 "[a-f0-9]{64}"/.test(formula)) {
  throw new Error("Formula sha256 line was not found.");
}
const updated = formula.replace(/  sha256 "[a-f0-9]{64}"/, `  sha256 "${sha256}"`);

if (updated !== formula) {
  await writeFile(formulaPath, updated);
}

console.log(`Updated Formula/record.rb sha256 to ${sha256}.`);
