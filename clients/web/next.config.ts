import type { NextConfig } from "next";

const nextConfig: NextConfig = {
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
