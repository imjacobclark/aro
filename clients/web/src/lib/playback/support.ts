import type { CatalogTrack, StreamQuality } from "@/lib/hub/types";

/**
 * What this browser can actually decode, and what to do when it cannot.
 *
 * Aro's hub stores whatever the listener owns, and browsers disagree sharply about lossless
 * formats. The case that motivated this: an `.m4a` holding ALAC plays in Safari and is
 * simply unsupported in Chrome, which has never shipped an Apple Lossless decoder. The
 * catalogue cannot tell the two apart — the hub reports a `codec` of `"m4a"` for both ALAC
 * and AAC, because that field is the file's extension — so guessing from metadata alone is
 * not possible.
 *
 * The answer is to stop guessing. Try the original; if the element rejects it as
 * unsupported, remember that and route this codec through the hub's Opus transcoder from
 * then on. The hub already encodes on demand and caches the result, so the cost is one
 * failed load, once per format, per browser.
 */

/** Quality used when a browser cannot decode the original. Opus at 192k is transparent. */
export const FALLBACK_QUALITY: StreamQuality = "high";

const STORAGE_KEY = "aro.undecodable";

/**
 * Groups tracks that will succeed or fail together. Bit depth is the discriminator that
 * metadata does offer: a lossy file has no meaningful one, so `m4a` carrying a bit depth is
 * almost certainly ALAC while `m4a` without one is AAC. Getting this wrong costs a single
 * retry, never a track that will not play.
 */
export function codecKey(track: CatalogTrack): string {
  const codec = (track.codec ?? "unknown").toLowerCase();
  return track.bit_depth ? `${codec}-lossless` : codec;
}

function load(): Set<string> {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    return new Set(raw ? (JSON.parse(raw) as string[]) : []);
  } catch {
    return new Set();
  }
}

let undecodable: Set<string> | null = null;

function known(): Set<string> {
  undecodable ??= typeof window === "undefined" ? new Set() : load();
  return undecodable;
}

/** True when this browser has already proved it cannot play this kind of file. */
export function isUndecodable(track: CatalogTrack): boolean {
  return known().has(codecKey(track));
}

export function rememberUndecodable(track: CatalogTrack): void {
  const key = codecKey(track);
  const set = known();
  if (set.has(key)) return;

  set.add(key);
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify([...set]));
  } catch {
    // Not persisted, but still remembered for the rest of this session.
  }
}

/**
 * A cheap up-front check for the one case worth pre-empting, so the common library does not
 * pay a failed request per format on first run. `canPlayType` is only ever advisory —
 * an empty string is a definite no, while "maybe" is not a yes — so this reports only the
 * definite refusals and leaves everything else to be discovered by trying.
 */
const refusals = new Map<string, boolean>();

export function refusesUpFront(track: CatalogTrack): boolean {
  if (typeof document === "undefined") return false;

  const probe = probeType(track);
  if (!probe) return false;

  // Memoized by codec key, because the answer is a property of the browser and cannot
  // change while the page is open — and this sits on the path a tap takes to start audio,
  // where it was creating a throwaway `<audio>` element on every single track load.
  const key = codecKey(track);
  const remembered = refusals.get(key);
  if (remembered !== undefined) return remembered;

  const element = document.createElement("audio");
  const refuses = element.canPlayType(probe) === "";
  refusals.set(key, refuses);
  return refuses;
}

function probeType(track: CatalogTrack): string | null {
  const codec = (track.codec ?? "").toLowerCase();
  const lossless = Boolean(track.bit_depth);

  switch (codec) {
    case "m4a":
    case "mp4":
    case "m4b":
      // The distinction Chrome cares about: it decodes `mp4a.40.2` and refuses `alac`.
      return lossless
        ? 'audio/mp4; codecs="alac"'
        : 'audio/mp4; codecs="mp4a.40.2"';
    case "flac":
      return "audio/flac";
    case "mp3":
      return "audio/mpeg";
    case "wav":
      return "audio/wav";
    case "aiff":
    case "aif":
      return "audio/aiff";
    case "ogg":
    case "oga":
    case "opus":
      return 'audio/ogg; codecs="opus"';
    default:
      return null;
  }
}

/**
 * The quality to actually request for a track, given what the listener asked for and what
 * this browser has been able to play.
 */
export function effectiveQuality(
  track: CatalogTrack,
  chosen: StreamQuality,
): StreamQuality {
  if (chosen !== "original") return chosen;
  if (isUndecodable(track) || refusesUpFront(track)) return FALLBACK_QUALITY;
  return "original";
}
