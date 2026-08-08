import "server-only";

import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { Agent, fetch as undiciFetch, type Dispatcher } from "undici";

/**
 * The one place this app talks to the hub.
 *
 * Every route handler goes through here, and nothing in `src/app/(app)` or `components`
 * may import it: the admin token lives in this module's closure and must never be
 * serialized into a page. The browser reaches the hub only by asking this server to ask
 * it — which is also why the app needs no login of its own. Whoever can reach this port
 * on the LAN can already reach the library.
 */

const HUB_URL = process.env.ARO_HUB_URL ?? "https://127.0.0.1:4848";
const ADMIN_TOKEN = process.env.ARO_ADMIN_TOKEN ?? "";
const CERT_PATH = process.env.ARO_HUB_CERT;
/** Hex SHA-256 of the hub's DER certificate, as `/v1/hub` reports its fingerprint. */
const CERT_FINGERPRINT = process.env.ARO_HUB_FINGERPRINT?.toLowerCase().replace(
  /[^a-f0-9]/g,
  "",
);
const ALLOW_INSECURE = process.env.ARO_HUB_INSECURE === "true";

export class HubError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "HubError";
  }
}

/**
 * The hub presents a self-signed certificate it generated for itself, so there is no
 * public CA to check it against — the macOS client pins it instead, and so does this.
 *
 * Pinning, not skipping: the certificate is supplied out of band (the deploy script copies
 * `cert.pem` off the hub) and trusted as its own root. Hostname verification is the one
 * check deliberately dropped, because the certificate is issued for the hub's identity
 * rather than for "127.0.0.1", and a name mismatch against a certificate we already pinned
 * byte for byte proves nothing.
 */
function createDispatcher(): Dispatcher {
  if (ALLOW_INSECURE) {
    // Development only: pointing `npm run dev` at a hub whose certificate you have not
    // copied locally. Never set this in the container.
    console.warn(
      "ARO_HUB_INSECURE=true — the hub's certificate is not being verified.",
    );
    return new Agent({ connect: { rejectUnauthorized: false } });
  }

  const ca = CERT_PATH ? readFileSync(CERT_PATH) : undefined;
  if (!ca && !CERT_FINGERPRINT) {
    throw new Error(
      "Set ARO_HUB_CERT to the hub's cert.pem (or ARO_HUB_FINGERPRINT, or ARO_HUB_INSECURE=true for local development).",
    );
  }

  return new Agent({
    connect: {
      ca,
      // Trust the pinned certificate as its own authority rather than requiring a chain
      // back to a public root it will never have.
      rejectUnauthorized: ca !== undefined,
      checkServerIdentity: (_host, peer) => {
        if (!CERT_FINGERPRINT) return undefined;
        const raw = peer.raw ?? Buffer.alloc(0);
        const actual = createHash("sha256").update(raw).digest("hex");
        return actual === CERT_FINGERPRINT
          ? undefined
          : new Error(
              `hub certificate fingerprint ${actual} does not match the pinned ${CERT_FINGERPRINT}`,
            );
      },
    },
  });
}

let dispatcher: Dispatcher | undefined;

function hubDispatcher(): Dispatcher {
  dispatcher ??= createDispatcher();
  return dispatcher;
}

export interface HubRequest {
  method?: string;
  /** Path below `/v1`, e.g. `library/catalog`. */
  path: string;
  query?: Record<string, string | number | boolean | undefined | null>;
  body?: unknown;
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

function hubUrl(path: string, query?: HubRequest["query"]): string {
  const url = new URL(`/v1/${path.replace(/^\/+/, "")}`, HUB_URL);
  for (const [key, value] of Object.entries(query ?? {})) {
    if (value !== undefined && value !== null) {
      url.searchParams.set(key, String(value));
    }
  }
  return url.toString();
}

/**
 * Raw response, for the routes that stream bytes straight through to the browser.
 *
 * Deliberately undici's own `fetch` rather than the global one: a dispatcher has to come
 * from the same undici instance that will use it, and the global `fetch` carries Node's
 * bundled copy. Going through the installed package keeps the pinned agent and the call
 * that needs it on the same side of that line.
 */
export async function hubFetch(request: HubRequest): Promise<Response> {
  if (!ADMIN_TOKEN) {
    throw new HubError(
      503,
      "hub_token_missing",
      "ARO_ADMIN_TOKEN is not set, so this server cannot authenticate to the hub.",
    );
  }

  const headers: Record<string, string> = {
    authorization: `Bearer ${ADMIN_TOKEN}`,
    ...request.headers,
  };
  if (request.body !== undefined) {
    headers["content-type"] = "application/json";
  }

  const response = await undiciFetch(hubUrl(request.path, request.query), {
    method: request.method ?? "GET",
    headers,
    body: request.body === undefined ? undefined : JSON.stringify(request.body),
    signal: request.signal,
    dispatcher: hubDispatcher(),
  });

  const body =
    response.status === 204 || response.status === 304
      ? null
      : (response.body as ReadableStream<Uint8Array> | null);

  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: new Headers([...response.headers]),
  });
}

/** JSON call that turns the hub's own error envelope into a `HubError`. */
export async function hubJson<T>(request: HubRequest): Promise<T> {
  let response: Response;
  try {
    response = await hubFetch(request);
  } catch (error) {
    throw new HubError(
      502,
      "hub_unreachable",
      error instanceof Error ? error.message : "The hub could not be reached.",
    );
  }

  if (!response.ok) {
    const detail = await response.text();
    let code = "hub_error";
    let message = detail || response.statusText;
    try {
      const parsed = JSON.parse(detail) as { error?: string; message?: string };
      code = parsed.error ?? code;
      message = parsed.message ?? message;
    } catch {
      // A non-JSON body is still worth surfacing verbatim.
    }
    throw new HubError(response.status, code, message);
  }

  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

export const hubConfig = {
  url: HUB_URL,
  hasToken: () => ADMIN_TOKEN.length > 0,
  verifiesCertificate: () => !ALLOW_INSECURE,
};
