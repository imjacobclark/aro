import { NextRequest, NextResponse } from "next/server";

import { hubFetch } from "@/lib/hub/server";

export const dynamic = "force-dynamic";

const HASH = /^[0-9a-f]{64}$/;

/**
 * Asks the hub to have a track's encode ready before anyone plays it.
 *
 * The hub can encode while streaming, but that first play is degraded in a way the browser
 * cannot work around: the length is unknown until the encode finishes, so the response
 * cannot answer a range request, and an `<audio>` element with no length has no duration
 * and no working scrub bar. Warming the next track in the queue while the current one
 * plays means it is a finished, seekable blob by the time it is reached.
 *
 * Its own route rather than the JSON proxy's allowlist, for the same reason the stream
 * itself has one: this is about a blob, and the hash sits mid-path where that allowlist
 * only wildcards a trailing segment.
 */
export async function POST(
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

  const response = await hubFetch({
    method: "POST",
    path: `blobs/${hash}/transcode`,
    query: { quality },
    signal: request.signal,
  });

  return new NextResponse(response.body, {
    status: response.status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
