/** Presentation helpers shared by the player, the lists, and the stats page. */

/** `3:07`, or `1:02:44` once an hour is involved. */
export function formatDuration(seconds: number | null | undefined): string {
  if (!seconds || !Number.isFinite(seconds) || seconds < 0) return "--:--";

  const whole = Math.floor(seconds);
  const hours = Math.floor(whole / 3600);
  const minutes = Math.floor((whole % 3600) / 60);
  const remainder = whole % 60;

  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`
    : `${minutes}:${String(remainder).padStart(2, "0")}`;
}

/** `18 hours`, `6 days` — for library totals, where seconds are meaningless. */
export function formatLongDuration(seconds: number | null | undefined): string {
  if (!seconds || seconds <= 0) return "0 minutes";

  const days = seconds / 86_400;
  if (days >= 1) return `${round(days)} ${plural(round(days), "day")}`;
  const hours = seconds / 3600;
  if (hours >= 1) return `${round(hours)} ${plural(round(hours), "hour")}`;
  const minutes = Math.round(seconds / 60);
  return `${minutes} ${plural(minutes, "minute")}`;
}

/**
 * Conventional units, matching the hub dashboard's own formatter — a library is measured
 * in GB by everyone who owns one, not in gibibytes.
 */
export function formatBytes(bytes: number | null | undefined): string {
  if (!bytes || bytes <= 0) return "0 KB";

  const units = ["KB", "MB", "GB", "TB", "PB"];
  let value = bytes / 1000;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit += 1;
  }
  return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

export function formatCount(value: number | null | undefined): string {
  return (value ?? 0).toLocaleString();
}

/** `FLAC · 24-bit/96 kHz` — the line that tells a listener what they are actually hearing. */
export function formatQuality(track: {
  codec?: string | null;
  bit_depth?: number | null;
  sample_rate?: number | null;
  bitrate?: number | null;
}): string {
  const parts: string[] = [];
  if (track.codec) parts.push(track.codec.toUpperCase());

  if (track.bit_depth && track.sample_rate) {
    parts.push(`${track.bit_depth}-bit/${(track.sample_rate / 1000).toFixed(track.sample_rate % 1000 === 0 ? 0 : 1)} kHz`);
  } else if (track.sample_rate) {
    parts.push(`${(track.sample_rate / 1000).toFixed(1)} kHz`);
  } else if (track.bitrate) {
    parts.push(`${Math.round(track.bitrate / 1000)} kbps`);
  }

  return parts.join(" · ");
}

/** True for anything past CD quality, which is what the app marks as high resolution. */
export function isHighResolution(track: {
  bit_depth?: number | null;
  sample_rate?: number | null;
}): boolean {
  return (track.bit_depth ?? 0) > 16 || (track.sample_rate ?? 0) > 48_000;
}

function round(value: number): number {
  return Math.round(value * 10) / 10;
}

function plural(value: number, word: string): string {
  return value === 1 ? word : `${word}s`;
}
