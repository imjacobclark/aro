import { NextRequest, NextResponse } from "next/server";

import { hubFetch } from "@/lib/hub/server";

export const dynamic = "force-dynamic";

const HASH = /^[0-9a-f]{64}$/;

/**
 * Cover art, from the same content-addressed blob store the audio comes from.
 *
 * Content addressing is what makes the aggressive caching safe: the bytes behind a hash
 * can never change, so a cover fetched once on a phone never needs revalidating. That is
 * most of what makes a scrolling grid of albums feel instant over a home network.
 */
export async function GET(
  _request: NextRequest,
  context: { params: Promise<{ hash: string }> },
) {
  const { hash } = await context.params;
  if (!HASH.test(hash)) {
    return NextResponse.json(
      { error: "invalid_hash", message: "Not a content hash." },
      { status: 400 },
    );
  }

  const response = await hubFetch({ path: `blobs/${hash}` });
  if (!response.ok) {
    return new NextResponse(null, { status: response.status });
  }

  const headers = new Headers();
  // As with audio, the hub serves a blob as `application/octet-stream` because it stores
  // bytes rather than file types. Covers come from the Cover Art Archive or from a file's
  // embedded art, which is overwhelmingly JPEG; a PNG mislabelled this way still renders,
  // since browsers sniff image bytes for `<img>`.
  const declared = response.headers.get("content-type");
  headers.set(
    "content-type",
    !declared || declared === "application/octet-stream"
      ? "image/jpeg"
      : declared,
  );
  const length = response.headers.get("content-length");
  if (length) headers.set("content-length", length);
  headers.set("cache-control", "public, max-age=31536000, immutable");

  return new NextResponse(response.body, { status: 200, headers });
}
