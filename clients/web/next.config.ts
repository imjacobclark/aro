import type { NextConfig } from "next";

/**
 * Identifies this build to the service worker.
 *
 * It has to change whenever the app changes, because the worker's cache names and its own
 * script URL are derived from it — a constant here is what let an installed PWA keep
 * serving a previous deploy's JavaScript indefinitely. The deploy script may pin it (a
 * rebuild of identical source then stays identical); otherwise the build time is enough,
 * since a build is exactly the event that needs a new identity.
 */
const buildId = process.env.ARO_BUILD_ID ?? `b${Date.now().toString(36)}`;

const nextConfig: NextConfig = {
  generateBuildId: () => buildId,
  // Read by the registration to version the worker's URL. Must be `NEXT_PUBLIC_` to reach
  // the browser at all.
  env: { NEXT_PUBLIC_BUILD_ID: buildId },
  // The deployment target is a 32-bit ARM Raspberry Pi with under a gigabyte of RAM, and
  // the container is cross-built from a Mac. `standalone` emits a self-contained server
  // with only the modules it actually traced, which is what keeps the runtime image small
  // enough to be worth shipping over SSH.
  output: "standalone",
  images: {
    // Next's optimizer needs `sharp`, a native module that would have to be compiled for
    // armv7. There is nothing here to optimize anyway: every image is a cover already
    // sized by whoever embedded it, served from a content-addressed blob.
    unoptimized: true,
  },
};

export default nextConfig;
