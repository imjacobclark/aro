const releasesUrl = "https://github.com/imjacobclark/sonora/releases";

export type ReleaseDownload = {
  version: string;
  arm64Url: string;
  intelUrl: string;
  arm64ChecksumUrl?: string;
  intelChecksumUrl?: string;
  usesDirectAssets: boolean;
};

export function releaseDownload(): ReleaseDownload {
  const version = process.env.NEXT_PUBLIC_SONORA_VERSION?.trim();
  const arm64Url = process.env.NEXT_PUBLIC_ARM64_DOWNLOAD_URL?.trim();
  const intelUrl = process.env.NEXT_PUBLIC_INTEL_DOWNLOAD_URL?.trim();

  return {
    version: version || "Latest preview",
    arm64Url: arm64Url || releasesUrl,
    intelUrl: intelUrl || releasesUrl,
    arm64ChecksumUrl:
      process.env.NEXT_PUBLIC_ARM64_CHECKSUM_URL?.trim() || undefined,
    intelChecksumUrl:
      process.env.NEXT_PUBLIC_INTEL_CHECKSUM_URL?.trim() || undefined,
    usesDirectAssets: Boolean(version && arm64Url && intelUrl),
  };
}
