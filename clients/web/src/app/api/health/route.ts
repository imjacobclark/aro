import { NextResponse } from "next/server";

import { HubError, hubConfig, hubJson } from "@/lib/hub/server";
import type { HubInfo } from "@/lib/hub/types";

export const dynamic = "force-dynamic";

/**
 * What the container's HEALTHCHECK and the deploy script both poll.
 *
 * A reachable hub is reported but not required for health: the web process being up is a
 * separate fact from the hub being up, and conflating them would have systemd restart this
 * container every time `aro-server` was itself restarting.
 */
export async function GET() {
  let hub: { reachable: boolean; name?: string; error?: string };

  try {
    const info = await hubJson<HubInfo>({ path: "hub" });
    hub = { reachable: true, name: info.display_name };
  } catch (error) {
    hub = {
      reachable: false,
      error:
        error instanceof HubError
          ? `${error.code}: ${error.message}`
          : "unknown",
    };
  }

  return NextResponse.json(
    {
      status: "ok",
      hub: { ...hub, url: hubConfig.url, configured: hubConfig.hasToken() },
    },
    { headers: { "cache-control": "no-store" } },
  );
}
