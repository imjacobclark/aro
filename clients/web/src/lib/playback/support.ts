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

let opusSupport: boolean | null = null;

/**
 * Whether this browser can decode the fallback at all.
 *
 * The fallback ladder is Ogg Opus, and Safari does not support the Ogg container — so on an
 * iPhone, routing a track to the fallback is not a rescue, it is a guaranteed failure with
 * "This track could not be played" at the end of it. Nothing checked this before: the code
 * knew the browser could not read the *source* and simply assumed it could read the
 * replacement. Chromium can, which is why every test run missed it.
 */
export function canPlayFallback(): boolean {
  if (typeof document === "undefined") return true;
  if (opusSupport !== null) return opusSupport;
  const element = document.createElement("audio");
  // Both spellings, because a browser may recognise the codec but not the container.
  opusSupport =
    element.canPlayType('audio/ogg; codecs="opus"') !== "" ||
    element.canPlayType("audio/ogg") !== "";
  return opusSupport;
}

// Versioned, and the version is a reset button. What lives here is a permanent judgement
// about a browser, written from a single failure — so when a release changes *why* things
// fail, the old judgements have to go. Cached transcodes were briefly served mislabelled as
// `audio/mp4`, which made Safari report the one error this file treats as proof, and every
// phone used in that window recorded "this browser cannot play lossless m4a" for good.
// Bumping the key is what unpoisons them.
const STORAGE_KEY = "aro.undecodable.v2";

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
  // Even a deliberately chosen tier is no use if this browser cannot decode what it
  // produces. Safari asked for Saver would otherwise get silence and an error.
  if (chosen !== "original") return canPlayFallback() ? chosen : "original";
  if (isUndecodable(track) || refusesUpFront(track)) {
    return canPlayFallback() ? FALLBACK_QUALITY : "original";
  }
  return "original";
}

/**
 * Tracks whose compatible copy the hub turned out not to have yet.
 *
 * Deliberately per-track and deliberately not persisted. A library part-way through
 * converting has copies for some tracks and not others, so remembering this per *codec*
 * would switch the whole format back to lossy on the first miss; and forgetting it on
 * reload is what lets a track start using its copy as soon as one exists.
 */
const withoutCompatibleCopy = new Set<string>();

export function rememberNoCompatibleCopy(track: CatalogTrack): void {
  if (track.content_hash) withoutCompatibleCopy.add(track.content_hash);
}

/**
 * Whether to ask the hub for its lossless compatibility copy instead of the stored file.
 *
 * This is the better answer to a format the browser cannot decode. The Opus fallback above
 * exists because there was nothing else; where a hub has made a FLAC copy, a listener who
 * asked for lossless should get lossless rather than a 192 kbps stand-in. Only sent when the
 * browser has actually shown it cannot cope — a browser that reads ALAC still gets the exact
 * bytes the listener owns.
 *
 * Harmless against a hub that has never heard of it: an unknown query parameter is ignored
 * and the original comes back, which is precisely the old behaviour.
 */
export function prefersCompatibleCopy(
  track: CatalogTrack,
  chosen: StreamQuality,
): boolean {
  if (chosen !== "original") return false;
  if (track.content_hash && withoutCompatibleCopy.has(track.content_hash)) {
    return false;
  }
  return isUndecodable(track) || refusesUpFront(track);
}

/**
 * What to actually ask the hub for: which quality, and whether to request the lossless
 * compatible copy.
 *
 * One function because the two answers are not independent, and computing them separately
 * is what broke this the first time. A browser that cannot decode the stored format was
 * asking for the Opus tier *and* the compatible copy in the same URL — and since the hub
 * only reaches for a compatible copy when the request is for `original`, the lossy tier won
 * every time and the lossless copies were never served at all.
 *
 * So: if a compatible copy is wanted, the quality stays `original`, because that copy *is*
 * the lossless original in a format this browser can read. The Opus ladder is what happens
 * when there is no copy to have.
 */
export function resolveSource(
  track: CatalogTrack,
  chosen: StreamQuality,
): { quality: StreamQuality; compatible: boolean } {
  const compatible = prefersCompatibleCopy(track, chosen);
  if (compatible) return { quality: "original", compatible: true };

  // A browser with no Opus is out of substitutes, so ask for the compatible copy even
  // where the source has not failed yet: FLAC is the only thing left that is both lossless
  // and playable, and if the hub has not made one the original comes back unchanged.
  if (!canPlayFallback() && chosen === "original" && refusesUpFront(track)) {
    return { quality: "original", compatible: true };
  }
  return { quality: effectiveQuality(track, chosen), compatible: false };
}
