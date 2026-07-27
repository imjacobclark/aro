import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const featurePath = resolve(import.meta.dirname, "../../features.md");
const source = await readFile(featurePath, "utf8");
const featurePattern = /^- \*\*(.+?)\*\* — (.+)$/gm;
const features = [...source.matchAll(featurePattern)].map((match) => ({
  title: match[1].trim(),
  description: match[2].trim(),
}));

const bulletLines = source
  .split("\n")
  .filter((line) => line.startsWith("- "));
const titles = new Set(features.map((feature) => feature.title));

if (features.length !== 37) {
  throw new Error(
    `Expected all 37 audited features, found ${features.length} in ${featurePath}`,
  );
}

if (bulletLines.length !== features.length) {
  throw new Error(
    "Every bullet in features.md must use: - **Title** — Marketing description",
  );
}

if (titles.size !== features.length) {
  throw new Error("Feature titles in features.md must be unique");
}

for (const feature of features) {
  if (!feature.title || !feature.description) {
    throw new Error("Feature titles and descriptions cannot be empty");
  }
}

console.log(`Validated ${features.length} Aro product features.`);
