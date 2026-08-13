"use client";

import { useCallback, useMemo, useState } from "react";
import {
  AlertTriangle,
  AudioLines,
  Check,
  FileWarning,
  Loader2,
  Sparkles,
} from "lucide-react";

import { PageShell, SectionHeader } from "@/components/page-shell";
import { Button } from "@/components/ui/button";
import { Card, EmptyState, Skeleton, Switch } from "@/components/ui/primitives";
import { useAsyncRefresh } from "@/hooks/use-async-refresh";
import { useCatalog } from "@/lib/catalog/store";
import { api, ApiError } from "@/lib/hub/api";
import type {
  FieldDelta,
  IdentificationQueueStatus,
  TrackDelta,
} from "@/lib/hub/types";
import { cn } from "@/lib/utils";

/**
 * What Aro knows about each track versus what the files themselves say.
 *
 * The hub identifies music in the background through AcoustID and MusicBrainz, and those
 * corrections live in Aro's database rather than in the files — so a library can be
 * perfectly tidy in Aro while every file on disk still carries whatever tags it shipped
 * with. This page is where that gap is visible and where it gets closed.
 *
 * Comparing costs one file open per track, so the hub bounds the scope and this asks per
 * artist rather than for everything at once.
 */
export default function MetadataPage() {
  const { tracks } = useCatalog();
  const [artist, setArtist] = useState<string | null>(null);
  const [deltas, setDeltas] = useState<TrackDelta[]>([]);
  const [status, setStatus] = useState<IdentificationQueueStatus | null>(null);
  const [writeBackEnabled, setWriteBackEnabled] = useState<boolean | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loadingDeltas, setLoadingDeltas] = useState(false);

  const artists = useMemo(() => {
    const names = new Set<string>();
    for (const track of tracks) {
      if (track.artist) names.add(track.artist);
    }
    return [...names].sort((a, b) => a.localeCompare(b));
  }, [tracks]);

  const loadStatus = useCallback(async () => {
    const [queue, writeBack] = await Promise.allSettled([
      api.identificationStatus(),
      api.writeBackEnabled(),
    ]);
    if (queue.status === "fulfilled") setStatus(queue.value);
    if (writeBack.status === "fulfilled")
      setWriteBackEnabled(writeBack.value.enabled);
  }, []);

  // The identification queue moves on its own, so this polls while the page is open.
  useAsyncRefresh(loadStatus, { intervalMs: 10_000 });

  const loadDeltas = async (name: string) => {
    setArtist(name);
    setLoadingDeltas(true);
    setError(null);
    try {
      setDeltas(await api.metadataDeltas({ artist: name, limit: 200 }));
    } catch (cause) {
      setError(describe(cause));
      setDeltas([]);
    } finally {
      setLoadingDeltas(false);
    }
  };

  const run = async (key: string, action: () => Promise<unknown>) => {
    setBusy(key);
    setError(null);
    try {
      await action();
      if (artist) await loadDeltas(artist);
      await loadStatus();
    } catch (cause) {
      setError(describe(cause));
    } finally {
      setBusy(null);
    }
  };

  const differing = deltas.filter((delta) => delta.difference_count > 0);
  const writable = differing.filter((delta) => delta.writable);

  return (
    <PageShell
      title="Metadata"
      subtitle="Background identification via AcoustID and MusicBrainz"
    >
      <div className="flex flex-col gap-7 pb-4">
        <section>
          <SectionHeader title="Identification" />
          <Card className="divide-hairline divide-y">
            <div className="px-4 py-3.5">
              <div className="grid grid-cols-3 gap-3">
                <Stat label="Queued" value={status?.queued ?? 0} />
                <Stat label="Processed" value={status?.processed ?? 0} />
                <Stat label="Failed" value={status?.failed ?? 0} />
              </div>
              {status?.in_flight ? (
                // Named rather than merely counted, as on macOS: identification works a
                // folder at a time, so "Everyday Life — 24 tracks" says what a ticking
                // counter cannot, and the hub has been sending it all along.
                <p className="text-muted-foreground mt-3 flex items-center gap-2 text-sm">
                  <AudioLines className="size-4 shrink-0 animate-pulse" />
                  <span className="truncate">
                    {status.last_group?.release_title ??
                      folderName(status.last_group?.folder) ??
                      "Identifying…"}
                  </span>
                  {status.last_group ? (
                    <span className="text-muted-foreground shrink-0 tabular-nums">
                      {status.last_group.member_count} tracks
                    </span>
                  ) : null}
                </p>
              ) : null}
              {status?.last_error ? (
                <p className="text-muted-foreground mt-3 flex items-start gap-2 text-sm">
                  <AlertTriangle className="mt-0.5 size-4 shrink-0" />
                  <span className="min-w-0">{status.last_error}</span>
                </p>
              ) : null}
            </div>
            <div className="flex items-center gap-3 px-4 py-3">
              <span className="min-w-0 flex-1 text-sm font-medium">
                Sync all music metadata
              </span>
              <Button
                variant="outline"
                size="sm"
                disabled={busy === "sweep"}
                onClick={() =>
                  void run("sweep", () => api.identifySweep({}))
                }
              >
                {busy === "sweep" ? (
                  <Loader2 className="size-4 animate-spin" />
                ) : (
                  <Sparkles className="size-4" />
                )}
                Sync All
              </Button>
            </div>
            {writeBackEnabled !== null ? (
              <div className="flex items-center gap-4 px-4 py-3.5">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium">
                    Write corrections into files
                  </p>
                  <p className="text-muted-foreground mt-1 text-xs leading-relaxed">
                    Off by default. Aro keeps its corrections in its own database
                    until you allow it to rewrite your files.
                  </p>
                </div>
                <Switch
                  checked={writeBackEnabled}
                  disabled={busy === "write-back-toggle"}
                  onCheckedChange={(checked) =>
                    void run("write-back-toggle", async () => {
                      await api.setWriteBackEnabled(checked);
                      setWriteBackEnabled(checked);
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
            title="Compare With Your Files"
            subtitle="Reading tags opens every file, so this works one artist at a time"
          />
          <div className="hide-scrollbar -mx-4 flex gap-2 overflow-x-auto px-4 pb-1">
            {artists.slice(0, 60).map((name) => (
              <button
                key={name}
                type="button"
                onClick={() => void loadDeltas(name)}
                className={cn(
                  "shrink-0 rounded-full px-3.5 py-1.5 text-xs font-medium transition-colors",
                  artist === name
                    ? "bg-primary text-primary-foreground"
                    : "bg-muted text-muted-foreground",
                )}
              >
                {name}
              </button>
            ))}
          </div>
        </section>

        {loadingDeltas ? (
          <div className="grid gap-2">
            {Array.from({ length: 4 }).map((_, index) => (
              <Skeleton key={index} className="h-20 w-full" />
            ))}
          </div>
        ) : artist === null ? (
          <EmptyState
            icon={<FileWarning className="size-10" />}
            title="Pick an Artist"
            description="Aro will compare what it holds against the tags in your actual files."
          />
        ) : differing.length === 0 ? (
          <EmptyState
            icon={<Check className="size-10" />}
            title="Nothing Differs"
            description={`Aro and your files agree on everything for ${artist}.`}
          />
        ) : (
          <section>
            <SectionHeader
              title={`${differing.length} ${differing.length === 1 ? "track differs" : "tracks differ"}`}
              subtitle={artist}
              action={
                writable.length > 0 && writeBackEnabled ? (
                  <Button
                    size="sm"
                    disabled={busy === "write-all"}
                    onClick={() =>
                      void run("write-all", () =>
                        api.writeBack(
                          writable.map((delta) => delta.content_hash),
                        ),
                      )
                    }
                  >
                    {busy === "write-all" ? (
                      <Loader2 className="size-4 animate-spin" />
                    ) : null}
                    Write {writable.length} to Files
                  </Button>
                ) : null
              }
            />
            <div className="flex flex-col gap-3">
              {differing.map((delta) => (
                <DeltaCard
                  key={delta.content_hash}
                  delta={delta}
                  canWrite={Boolean(writeBackEnabled)}
                  busy={busy === delta.content_hash}
                  onWrite={() =>
                    void run(delta.content_hash, () =>
                      api.writeBack([delta.content_hash]),
                    )
                  }
                />
              ))}
            </div>
          </section>
        )}

        {error ? <p className="text-destructive text-sm">{error}</p> : null}
      </div>
    </PageShell>
  );
}

function DeltaCard({
  delta,
  canWrite,
  busy,
  onWrite,
}: {
  delta: TrackDelta;
  canWrite: boolean;
  busy: boolean;
  onWrite: () => void;
}) {
  const interesting = delta.fields.filter(
    (field) => field.verdict !== "agrees" && field.verdict !== "absent",
  );

  return (
    <Card className="overflow-hidden">
      <div className="border-hairline flex items-start gap-3 border-b px-4 py-3">
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium">
            {delta.title ?? "Unknown Track"}
          </p>
          <p className="text-muted-foreground truncate text-xs">
            {delta.album ?? delta.artist ?? ""}
          </p>
        </div>
        {delta.writable ? (
          canWrite ? (
            <Button size="sm" variant="outline" disabled={busy} onClick={onWrite}>
              {busy ? <Loader2 className="size-4 animate-spin" /> : null}
              Write to File
            </Button>
          ) : null
        ) : (
          // Aro's own copy is derived; rewriting it would leave the listener's original
          // untouched while silently diverging from it.
          <span className="text-muted-foreground flex shrink-0 items-center gap-1.5 text-xs">
            <AlertTriangle className="size-3.5" />
            {delta.availability === "copy_only"
              ? "Original unreachable"
              : "Not writable"}
          </span>
        )}
      </div>

      <div className="text-muted-foreground grid grid-cols-[6rem_1fr_1fr] gap-x-3 px-4 pt-2 text-[0.65rem] font-semibold tracking-wide uppercase">
        <span />
        <span>Aro</span>
        <span>File on disk</span>
      </div>
      <div className="divide-hairline divide-y">
        {interesting.map((field) => (
          <FieldRow key={field.field} field={field} />
        ))}
      </div>
    </Card>
  );
}

function FieldRow({ field }: { field: FieldDelta }) {
  return (
    <div className="grid grid-cols-[6rem_1fr_1fr] items-baseline gap-x-3 px-4 py-2 text-sm">
      <span className="text-muted-foreground truncate text-xs capitalize">
        {field.field.replace(/_/g, " ")}
      </span>
      <span className="truncate">{field.aro ?? "—"}</span>
      <span
        className={cn(
          "truncate",
          field.verdict === "differs" && "text-destructive",
        )}
      >
        {field.file ?? "—"}
      </span>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <p className="text-muted-foreground text-[0.65rem] font-semibold tracking-wide uppercase">
        {label}
      </p>
      <p className="mt-0.5 text-lg font-bold tabular-nums">{value}</p>
    </div>
  );
}

/** Last path component of a hub-side folder, which is a POSIX path on the hub's disk. */
function folderName(folder: string | undefined): string | undefined {
  if (!folder) return undefined;
  const name = folder.replace(/\/+$/, "").split("/").pop();
  return name || undefined;
}

function describe(cause: unknown): string {
  if (cause instanceof ApiError) return cause.message;
  return cause instanceof Error ? cause.message : "That did not work.";
}
