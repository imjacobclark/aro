"use client";

import { useCallback, useState } from "react";
import Link from "next/link";
import {
  AlertTriangle,
  Check,
  FolderPlus,
  HardDrive,
  Loader2,
  RefreshCw,
  Trash2,
} from "lucide-react";

import { PageShell, SectionHeader } from "@/components/page-shell";
import { formatBytes, formatDuration } from "@/lib/format";
import { useAsyncRefresh } from "@/hooks/use-async-refresh";
import { Button } from "@/components/ui/button";
import { Card, Input, Label, Switch } from "@/components/ui/primitives";
import { useCatalog } from "@/lib/catalog/store";
import { clearCachedCatalog } from "@/lib/catalog/cache";
import { api } from "@/lib/hub/api";
import { STREAM_QUALITIES } from "@/lib/hub/types";
import type {
  CompatibilityPlan,
  HubDevice,
  HubInfo,
  SourceHealth,
  WatchedFolder,
} from "@/lib/hub/types";
import { useSettings, type ThemePreference } from "@/lib/settings";
import { cn } from "@/lib/utils";

/**
 * Settings, plus the hub administration the macOS app puts behind Devices and Advanced.
 *
 * Nothing here is per-user, because the app has no users: these are the hub's own
 * settings, reachable by anyone who can reach this page. Playback quality and theme are
 * the exceptions — they are per-browser, and stay in local storage.
 */
export default function SettingsPage() {
  const settings = useSettings();
  const { tracks, refresh, refreshing } = useCatalog();

  const [hub, setHub] = useState<HubInfo | null>(null);
  const [sources, setSources] = useState<SourceHealth[]>([]);
  const [folders, setFolders] = useState<WatchedFolder[]>([]);
  const [devices, setDevices] = useState<HubDevice[]>([]);
  const [writeBack, setWriteBack] = useState<boolean | null>(null);
  const [compatibility, setCompatibility] = useState<CompatibilityPlan | null>(
    null,
  );
  const [newFolder, setNewFolder] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    // Each of these is independent, and one failing (a hub without folders configured,
    // say) should not blank the rest of the page.
    const [info, health, watched, paired, writeBackState, compatibilityPlan] =
      await Promise.allSettled([
        api.hub(),
        api.sources(),
        api.folders(),
        api.devices(),
        api.writeBackEnabled(),
        api.compatibilityPlan(),
      ]);

    if (info.status === "fulfilled") setHub(info.value);
    if (health.status === "fulfilled") setSources(health.value);
    if (watched.status === "fulfilled") setFolders(watched.value);
    if (paired.status === "fulfilled") setDevices(paired.value);
    if (writeBackState.status === "fulfilled")
      setWriteBack(writeBackState.value.enabled);
    // A hub older than this feature answers 403 from the proxy allowlist; the section
    // simply does not appear rather than the page erroring.
    if (compatibilityPlan.status === "fulfilled")
      setCompatibility(compatibilityPlan.value);
  }, []);

  useAsyncRefresh(load);

  const run = async (key: string, action: () => Promise<unknown>) => {
    setBusy(key);
    setError(null);
    try {
      await action();
      await load();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "That did not work.");
    } finally {
      setBusy(null);
    }
  };

  return (
    <PageShell title="Settings">
      <div className="flex flex-col gap-7 pb-4">
        <section>
          <SectionHeader
            title="Playback"
            subtitle="Applies to this browser only"
          />
          <Card className="divide-hairline divide-y">
            {STREAM_QUALITIES.map((quality) => (
              <button
                key={quality.value}
                type="button"
                onClick={() => settings.update({ quality: quality.value })}
                className="flex w-full items-center gap-3 px-4 py-3.5 text-left"
              >
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-medium">
                    {quality.label}
                  </span>
                  <span className="text-muted-foreground block text-xs">
                    {quality.detail}
                  </span>
                </span>
                {settings.quality === quality.value ? (
                  <Check className="text-primary size-5 shrink-0" />
                ) : null}
              </button>
            ))}
          </Card>
          {settings.quality !== "original" ? (
            <p className="text-muted-foreground mt-2 px-1 text-xs leading-relaxed">
              Your hub re-encodes to Opus on demand, which saves data but costs it CPU.
              Safari&rsquo;s support for Opus is newer than its support for FLAC — if a track
              refuses to play, Original is the reliable choice.
            </p>
          ) : null}
        </section>

        {compatibility ? (
          <section>
            <SectionHeader
              title="Compatibility"
              subtitle="Applies to your whole library, on every device"
            />
            <Card className="flex flex-col gap-4 p-4">
              <div>
                <p className="text-sm font-medium">
                  Convert library for maximum cross-device compatibility
                </p>
                <p className="text-muted-foreground mt-1 text-xs leading-relaxed">
                  Some formats only play on some devices — Apple Lossless, for one, plays
                  on a Mac and in Safari but in no other browser. Aro can keep a second,
                  lossless FLAC copy of those tracks so every Aro can play them without
                  falling back to a lossy re-encode.
                </p>
                <p className="text-muted-foreground mt-2 text-xs leading-relaxed">
                  Your music is never modified or replaced. The copies live separately and
                  can be deleted at any time. At worst this uses about as much space again
                  as the tracks that need converting — not your whole library.
                </p>
              </div>

              <dl className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-4">
                <div>
                  <dt className="text-muted-foreground text-xs">Converted</dt>
                  <dd className="font-medium tabular-nums">
                    {compatibility.tracks_converted}
                  </dd>
                </div>
                <div>
                  <dt className="text-muted-foreground text-xs">To convert</dt>
                  <dd className="font-medium tabular-nums">
                    {compatibility.tracks_pending}
                  </dd>
                </div>
                <div>
                  <dt className="text-muted-foreground text-xs">
                    Already compatible
                  </dt>
                  <dd className="font-medium tabular-nums">
                    {compatibility.tracks_already_compatible}
                  </dd>
                </div>
                <div>
                  <dt className="text-muted-foreground text-xs">Space used</dt>
                  <dd className="font-medium tabular-nums">
                    {formatBytes(compatibility.used_bytes)}
                  </dd>
                </div>
              </dl>

              {compatibility.tracks_pending > 0 ? (
                <p className="text-muted-foreground text-xs leading-relaxed">
                  {formatDuration(compatibility.pending_audio_seconds)} of music to
                  convert, needing about {formatBytes(compatibility.estimated_bytes)}.
                  Your hub does this in the background, one track at a time, and stays
                  usable throughout.
                </p>
              ) : (
                <p className="text-muted-foreground text-xs leading-relaxed">
                  Everything that needs a compatible copy has one.
                </p>
              )}

              <div className="flex flex-wrap gap-2">
                <Button
                  onClick={() =>
                    run("compatibility", () => api.startCompatibility())
                  }
                  disabled={
                    busy === "compatibility" || compatibility.tracks_pending === 0
                  }
                >
                  {busy === "compatibility" ? (
                    <Loader2 className="size-4 animate-spin" />
                  ) : (
                    <HardDrive className="size-4" />
                  )}
                  Convert {compatibility.tracks_pending} tracks
                </Button>
                {compatibility.tracks_converted > 0 ? (
                  <Button
                    variant="ghost"
                    onClick={() =>
                      run("compatibility-cleanup", () =>
                        api.cleanupCompatibility(),
                      )
                    }
                    disabled={busy === "compatibility-cleanup"}
                  >
                    {busy === "compatibility-cleanup" ? (
                      <Loader2 className="size-4 animate-spin" />
                    ) : (
                      <Trash2 className="size-4" />
                    )}
                    Delete copies
                  </Button>
                ) : null}
              </div>
            </Card>
          </section>
        ) : null}

        <section>
          <SectionHeader title="Appearance" />
          <Card className="flex gap-2 p-2">
            {(["system", "light", "dark"] as ThemePreference[]).map((theme) => (
              <button
                key={theme}
                type="button"
                onClick={() => settings.update({ theme })}
                className={cn(
                  "flex-1 rounded-xl px-3 py-2.5 text-sm font-medium capitalize transition-colors",
                  settings.theme === theme
                    ? "bg-primary text-primary-foreground"
                    : "text-muted-foreground hover:bg-muted",
                )}
              >
                {theme}
              </button>
            ))}
          </Card>
        </section>

        <section>
          <SectionHeader title="Listening" />
          <Card className="flex items-center gap-4 px-4 py-3.5">
            <div className="min-w-0 flex-1">
              <Label>Contribute to your library&rsquo;s intelligence</Label>
              <p className="text-muted-foreground mt-1 text-xs leading-relaxed">
                Tells your hub what you play here, so the playlists on Home learn from this
                device as well as your Mac.
              </p>
            </div>
            <Switch
              checked={settings.reportListening}
              onCheckedChange={(checked) =>
                settings.update({ reportListening: checked })
              }
              aria-label="Report listening to the hub"
            />
          </Card>
        </section>

        <section>
          <SectionHeader
            title="Hub"
            subtitle={hub ? hub.display_name : "Connecting…"}
          />
          <Card className="divide-hairline divide-y">
            <Row label="Library" value={hub?.library_name ?? hub?.display_name ?? "—"} />
            <Row label="Tracks" value={tracks.length.toLocaleString()} />
            <div className="flex items-center gap-3 px-4 py-3">
              <span className="flex-1 text-sm font-medium">Catalogue</span>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => void refresh()}
                disabled={refreshing}
              >
                <RefreshCw
                  className={cn("size-4", refreshing && "animate-spin")}
                />
                Refresh
              </Button>
            </div>
            {writeBack !== null ? (
              <div className="flex items-center gap-4 px-4 py-3.5">
                <div className="min-w-0 flex-1">
                  <Label>Write corrections into files</Label>
                  <p className="text-muted-foreground mt-1 text-xs leading-relaxed">
                    When on, edits are saved into the audio files themselves, not just
                    Aro&rsquo;s database.
                  </p>
                </div>
                <Switch
                  checked={writeBack}
                  disabled={busy === "write-back"}
                  onCheckedChange={(checked) =>
                    void run("write-back", async () => {
                      await api.setWriteBackEnabled(checked);
                      setWriteBack(checked);
                    })
                  }
                  aria-label="Write metadata back to files"
                />
              </div>
            ) : null}
          </Card>
        </section>

        <section>
          <SectionHeader
            title="Folders"
            subtitle="What your hub watches for music"
            action={
              <Button
                variant="ghost"
                size="sm"
                onClick={() => void run("scan", () => api.scanFolders())}
                disabled={busy === "scan"}
              >
                {busy === "scan" ? (
                  <Loader2 className="size-4 animate-spin" />
                ) : (
                  <RefreshCw className="size-4" />
                )}
                Scan
              </Button>
            }
          />
          <Card className="divide-hairline divide-y">
            {folders.length === 0 ? (
              <p className="text-muted-foreground px-4 py-4 text-sm">
                No folders are being watched yet.
              </p>
            ) : (
              folders.map((folder) => (
                <div
                  key={folder.source_id}
                  className="flex items-center gap-3 px-4 py-3"
                >
                  <HardDrive className="text-muted-foreground size-4 shrink-0" />
                  <Link
                    href={`/folders/${folder.source_id}`}
                    className="min-w-0 flex-1"
                  >
                    <span className="block truncate text-sm font-medium">
                      {folder.name ?? folder.path}
                    </span>
                    <span className="text-muted-foreground block truncate text-xs">
                      {folder.path}
                    </span>
                  </Link>
                  <button
                    type="button"
                    aria-label={`Stop watching ${folder.path}`}
                    onClick={() =>
                      void run(folder.source_id, () =>
                        api.removeFolder(folder.source_id),
                      )
                    }
                    className="text-muted-foreground hover:text-destructive shrink-0 p-2"
                  >
                    <Trash2 className="size-4" />
                  </button>
                </div>
              ))
            )}
            <div className="flex gap-2 px-4 py-3">
              <Input
                value={newFolder}
                onChange={(event) => setNewFolder(event.target.value)}
                placeholder="/srv/mercury/Library"
                aria-label="Folder path on the hub"
              />
              <Button
                variant="outline"
                aria-label="Add folder"
                disabled={!newFolder.trim() || busy === "add-folder"}
                onClick={() =>
                  void run("add-folder", async () => {
                    await api.addFolder(newFolder.trim());
                    setNewFolder("");
                  })
                }
              >
                <FolderPlus className="size-4" />
              </Button>
            </div>
          </Card>
          <p className="text-muted-foreground mt-2 px-1 text-xs leading-relaxed">
            Paths are on the hub&rsquo;s own filesystem, not this device&rsquo;s.
          </p>
        </section>

        {sources.some((source) => !source.available) ? (
          <section>
            <SectionHeader title="Needs Attention" />
            <Card className="divide-hairline divide-y">
              {sources
                .filter((source) => !source.available)
                .map((source) => (
                  <div
                    key={source.source_id}
                    className="flex items-start gap-3 px-4 py-3"
                  >
                    <AlertTriangle className="text-destructive mt-0.5 size-4 shrink-0" />
                    <div className="min-w-0">
                      <p className="truncate text-sm font-medium">
                        {source.name}
                      </p>
                      <p className="text-muted-foreground text-xs">
                        Unreachable
                        {source.device_name ? ` on ${source.device_name}` : ""}
                        {source.missing_count
                          ? ` · ${source.missing_count} tracks affected`
                          : ""}
                      </p>
                    </div>
                  </div>
                ))}
            </Card>
          </section>
        ) : null}

        <section>
          <SectionHeader title="Devices" subtitle="Paired with this hub" />
          <Card className="divide-hairline divide-y">
            {devices.length === 0 ? (
              <p className="text-muted-foreground px-4 py-4 text-sm">
                No devices are paired.
              </p>
            ) : (
              devices.map((device) => (
                <div
                  key={device.device_id}
                  className="flex items-center gap-3 px-4 py-3"
                >
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm font-medium">
                      {device.name ?? "Unnamed device"}
                    </span>
                    <span className="text-muted-foreground block truncate text-xs">
                      {device.platform ?? "Unknown platform"}
                    </span>
                  </span>
                  <button
                    type="button"
                    aria-label={`Revoke ${device.name ?? "device"}`}
                    onClick={() =>
                      void run(device.device_id, () =>
                        api.revokeDevice(device.device_id),
                      )
                    }
                    className="text-muted-foreground hover:text-destructive shrink-0 p-2"
                  >
                    <Trash2 className="size-4" />
                  </button>
                </div>
              ))
            )}
          </Card>
        </section>

        <section>
          <SectionHeader title="This Device" />
          <Button
            variant="outline"
            onClick={() =>
              void clearCachedCatalog().then(() => window.location.reload())
            }
            className="w-full"
          >
            Clear cached library
          </Button>
          <p className="text-muted-foreground mt-2 px-1 text-xs leading-relaxed">
            Only the copy stored in this browser for offline browsing. Your library on the
            hub is untouched.
          </p>
        </section>

        {error ? <p className="text-destructive text-sm">{error}</p> : null}
      </div>
    </PageShell>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center gap-3 px-4 py-3">
      <span className="flex-1 text-sm font-medium">{label}</span>
      <span className="text-muted-foreground truncate text-sm">{value}</span>
    </div>
  );
}
