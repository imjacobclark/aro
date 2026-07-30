import fs from "node:fs";
import path from "node:path";

export type ProductFeature = {
  title: string;
  description: string;
};

export type FeatureGroup = {
  title: string;
  features: ProductFeature[];
};

const groupTitles: Record<string, string[]> = {
  "Ownership & Storage": [
    "Your Music Stays Yours",
    "Originals Stay Original",
    "Plays the Collection You Have",
    "Add a Folder and Listen",
    "Always in Step",
    "Store It Your Way",
    "Safe Library Housekeeping",
    "Move Without Rebuilding",
  ],
  "Home & Rediscovery": [
    "Made From Your Listening",
    "Rediscover the Forgotten",
    "Your Listening Story",
    "Know Your Collection",
    "Know Every Recording",
    "Metadata Stays in Your Hands",
    "A Health Check for Music",
    "See Space You Could Reclaim",
  ],
  "Private Connection & Resilience": [
    "Your Aro, Everywhere",
    "Pair in Seconds",
    "Direct, Encrypted, Approved",
    "You Control Every Device",
    "Every Aro Carries the Library",
    "Keep What Matters Nearby",
    "Switch Libraries in One App",
    "Runs Beyond the App",
    "Host Aro Almost Anywhere",
    "See Aro at a Glance",
  ],
  "Sound & Playback": [
    "Bit-Perfect by Default",
    "Native-Rate Playback",
    "Exclusive Listening Mode",
    "Consistent Volume, Your Choice",
    "Albums Flow Without Gaps",
    "Your Output, Your Choice",
    "See the Signal Path",
    "Press Play Without Waiting",
    "Playback That Recovers",
    "Shuffle, Repeat, Favourite",
    "Browse Music as Music",
    "Find Artists and Albums Fast",
  ],
  "Offline & Recovery": [
    "Offline Music That Protects Itself",
    "Storage Without the Guesswork",
    "Completed Copies Are Checked",
    "Interrupted Transfers Recover",
    "Durability Without Waste",
    "Take the Whole Library Back",
    "Exports Respect What Exists",
  ],
};

function featuresPath(): string {
  const candidates = [
    path.resolve(process.cwd(), "..", "features.md"),
    path.resolve(process.cwd(), "features.md"),
  ];
  const match = candidates.find((candidate) => fs.existsSync(candidate));
  if (!match) {
    throw new Error("Unable to locate the root features.md");
  }
  return match;
}

export function loadFeatures(): ProductFeature[] {
  const source = fs.readFileSync(featuresPath(), "utf8");
  const lines = source.split(/\r?\n/);
  const features: ProductFeature[] = [];

  for (const [index, line] of lines.entries()) {
    if (!line.startsWith("- ")) {
      continue;
    }
    const match = line.match(/^- \*\*([^*]+)\*\* — (.+)$/);
    if (!match) {
      throw new Error(`Malformed feature on line ${index + 1}`);
    }
    features.push({
      title: match[1].trim(),
      description: match[2]
        .trim()
        .replace(/\bfiles\b/g, "songs")
        .replace(/\bfile\b/g, "song"),
    });
  }

  if (features.length === 0) {
    throw new Error("features.md contains no feature bullets");
  }

  const titles = new Set<string>();
  for (const feature of features) {
    if (titles.has(feature.title)) {
      throw new Error(`Duplicate feature title: ${feature.title}`);
    }
    titles.add(feature.title);
  }

  return features;
}

export function groupFeatures(features: ProductFeature[]): FeatureGroup[] {
  const byTitle = new Map(features.map((feature) => [feature.title, feature]));
  const assigned = new Set<string>();
  const groups = Object.entries(groupTitles).map(([title, requested]) => {
    const grouped = requested.flatMap((featureTitle) => {
      const feature = byTitle.get(featureTitle);
      if (!feature) {
        return [];
      }
      assigned.add(featureTitle);
      return [feature];
    });
    return { title, features: grouped };
  });

  const remaining = features.filter((feature) => !assigned.has(feature.title));
  if (remaining.length > 0) {
    groups.push({ title: "More from Aro", features: remaining });
  }

  return groups.filter((group) => group.features.length > 0);
}
