import { NextRequest, NextResponse } from "next/server";

import { hubFetch } from "@/lib/hub/server";

export const dynamic = "force-dynamic";

const HASH = /^[0-9a-f]{64}$/;

/**
 * Audio, proxied byte for byte.
 *
 * The `Range` header is the whole job. An `<audio>` element seeks by asking for a byte
 * range, and Safari will not even begin playing a file it cannot range-request — so the
 * header has to survive the trip out, and `Content-Range`, `Accept-Ranges` and the 206
 * status have to survive the trip back. Dropping any of them turns seeking into a silent
 * restart from zero.
 *
 * Nothing here is cached: original-quality FLAC is large, the hub is a Raspberry Pi, and
 * the service worker is told to keep its hands off this path for the same reason.
 */
export async function GET(
  request: NextRequest,
  context: { params: Promise<{ hash: string }> },
) {
  const { hash } = await context.params;
  if (!HASH.test(hash)) {
    return NextResponse.json(
      { error: "invalid_hash", message: "Not a content hash." },
      { status: 400 },
    );
  }

  const quality = request.nextUrl.searchParams.get("quality") ?? undefined;
  const codec = request.nextUrl.searchParams.get("codec") ?? undefined;
  const range = request.headers.get("range");

  const response = await hubFetch({
    path: `blobs/${hash}/stream`,
    query: { quality },
    headers: range ? { range } : undefined,
    signal: request.signal,
  });

  const headers = new Headers();
  for (const header of [
    "content-length",
    "content-range",
    "accept-ranges",
    // The hub's validator travels with the bytes: blobs are content-addressed, so the tag
    // it sends is the hash of exactly what came back and is safe to hand to the browser.
    "etag",
  ]) {
    const value = response.headers.get(header);
    if (value) headers.set(header, value);
  }

  // Blobs are content-addressed, so the hub serves an original at its natural
  // `application/octet-stream` — it stores bytes, not file types. A browser will not play
  // that: Safari in particular decides whether it can handle a stream from the declared
  // type, and refuses an opaque one outright. The catalogue knows the codec, so the client
  // sends it along and it is turned into a real media type here. Transcodes already come
  // back as `audio/ogg` and are passed through untouched.
  const declared = response.headers.get("content-type");
  headers.set(
    "content-type",
    !declared || declared === "application/octet-stream"
      ? mediaType(codec)
      : declared,
  );

  // A transcode is encoded on demand and cannot satisfy a range request until the cached
  // copy exists, which is why the hub answers `accept-ranges: none` for one. That must be
  // passed through honestly rather than replaced with an optimistic `bytes`.
  if (!headers.has("accept-ranges")) headers.set("accept-ranges", "bytes");
  headers.set("cache-control", cachePolicy(quality, headers.has("etag")));

  return new NextResponse(response.body, {
    status: response.status,
    headers,
  });
}

/**
 * How long the browser may keep a piece of audio.
 *
 * The original is deliberately never stored. A losslessly-ripped library averages around
 * 24 MB a track, and filling a phone's cache with those would evict everything else the
 * app needs to start offline — the size is the whole reason this app has a low data mode
 * in the first place.
 *
 * A transcode is a different object with different economics: the same track at 96 kbps is
 * a little over 2 MB, it is content-addressed, and it can never change. Refetching it on
 * every replay wastes the one thing the listener on a phone is short of. So the qualities
 * that exist to save bandwidth are allowed to actually save it.
 */
function cachePolicy(quality: string | undefined, hasValidator: boolean): string {
  if (!quality || quality === "original") return "no-store";
  // Without a validator there is nothing to revalidate against, and an encode still being
  // produced must never be stored as though it were the finished article.
  if (!hasValidator) return "no-store";
  return "private, max-age=31536000, immutable";
}

/**
 * The hub reports a codec as the source file's short name (`m4a`, `flac`, `mp3`), which is
 * what the catalogue carries and what the macOS app shows in its quality line.
 */
function mediaType(codec: string | undefined): string {
  switch (codec?.toLowerCase()) {
    case "mp3":
      return "audio/mpeg";
    case "m4a":
    case "mp4":
    case "aac":
    case "alac":
      return "audio/mp4";
    case "flac":
      return "audio/flac";
    case "ogg":
    case "oga":
    case "opus":
    case "vorbis":
      return "audio/ogg";
    case "wav":
      return "audio/wav";
    case "aiff":
    case "aif":
      return "audio/aiff";
    default:
      // Unknown to us but not to the browser: `audio/*` is enough for it to sniff, and
      // better than the opaque type that would make it refuse before trying.
      return "audio/*";
  }
}
