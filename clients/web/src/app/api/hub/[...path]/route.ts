import { NextRequest, NextResponse } from "next/server";

import { HubError, hubFetch } from "@/lib/hub/server";
import { isAllowed } from "@/lib/hub/routes";

export const dynamic = "force-dynamic";

/**
 * The JSON side of the proxy: `/api/hub/library/catalog` becomes `/v1/library/catalog` on
 * the hub, with the admin token attached here rather than anywhere the browser can see.
 * Audio and artwork have their own routes because they stream and cache differently.
 */
async function proxy(
  request: NextRequest,
  context: { params: Promise<{ path: string[] }> },
) {
  const { path } = await context.params;
  const target = path.join("/");

  if (!isAllowed(target, request.method)) {
    return NextResponse.json(
      {
        error: "path_not_permitted",
        message: `The web client does not proxy ${request.method} /v1/${target}.`,
      },
      { status: 403 },
    );
  }

  const query = Object.fromEntries(request.nextUrl.searchParams.entries());
  const hasBody = request.method !== "GET" && request.method !== "DELETE";

  try {
    const response = await hubFetch({
      method: request.method,
      path: target,
      query,
      body: hasBody ? await readJson(request) : undefined,
    });

    // Pass the hub's status through untouched — a 403 from the hub means something
    // different to the UI than a 404, and flattening them would cost that.
    const headers = new Headers();
    const contentType = response.headers.get("content-type");
    if (contentType) headers.set("content-type", contentType);
    headers.set("cache-control", "no-store");

    return new NextResponse(response.body, {
      status: response.status,
      headers,
    });
  } catch (error) {
    return errorResponse(error);
  }
}

async function readJson(request: NextRequest): Promise<unknown> {
  const text = await request.text();
  if (!text) return undefined;
  try {
    return JSON.parse(text);
  } catch {
    throw new HubError(400, "invalid_json", "The request body was not JSON.");
  }
}

function errorResponse(error: unknown) {
  if (error instanceof HubError) {
    return NextResponse.json(
      { error: error.code, message: error.message },
      { status: error.status },
    );
  }
  return NextResponse.json(
    {
      error: "proxy_failed",
      message: error instanceof Error ? error.message : "Unknown failure.",
    },
    { status: 502 },
  );
}

export const GET = proxy;
export const POST = proxy;
export const PUT = proxy;
export const DELETE = proxy;
