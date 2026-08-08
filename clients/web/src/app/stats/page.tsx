"use client";

import { useCallback, useState } from "react";

import { PageShell, SectionHeader } from "@/components/page-shell";
import { useAsyncRefresh } from "@/hooks/use-async-refresh";
import { Card, EmptyState, Skeleton } from "@/components/ui/primitives";
import { useCatalog } from "@/lib/catalog/store";
import { api } from "@/lib/hub/api";
import type { Breakdown, LibraryStats, PlayCount } from "@/lib/hub/types";
import {
  formatBytes,
  formatCount,
  formatLongDuration,
} from "@/lib/format";

/**
 * `StatsView`, sourced from the hub instead of a local SQLite file.
 *
 * On macOS these numbers come from the client's own database; here they come from
 * `/v1/library/stats`, which returns the hub's whole `dashboard_stats()` — library
 * composition, listening history, and metadata completeness in one call. Same figures,
 * one fewer copy of the truth.
 */
export default function StatsPage() {
  const { tracks } = useCatalog();
  const [stats, setStats] = useState<LibraryStats | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setStats(await api.stats());
      setError(null);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Unavailable.");
    }
  }, []);

  // Slower than Home's 15 seconds: statistics move at the pace of a whole library, and
  // this page is often left open.
  useAsyncRefresh(load, { intervalMs: 60_000 });

  if (!stats) {
    return (
      <PageShell title="Stats">
        {error ? (
          <EmptyState title="Statistics Unavailable" description={error} />
        ) : (
          <div className="grid grid-cols-2 gap-3">
            {Array.from({ length: 6 }).map((_, index) => (
              <Skeleton key={index} className="h-24" />
            ))}
          </div>
        )}
      </PageShell>
    );
  }

  const library = stats.library ?? {};
  const listening = stats.listening ?? {};

  return (
    <PageShell title="Stats" subtitle="What your library is made of">
      <div className="flex flex-col gap-7 pb-4">
        <section>
          <SectionHeader title="Library" />
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
            <Stat
              label="Songs"
              value={formatCount(library.track_count ?? tracks.length)}
            />
            <Stat label="Albums" value={formatCount(library.album_count)} />
            <Stat label="Artists" value={formatCount(library.artist_count)} />
            <Stat
              label="Playing Time"
              value={formatLongDuration(library.total_duration_seconds)}
            />
            <Stat label="On Disk" value={formatBytes(library.file_size_bytes)} />
            <Stat
              label="Lossless"
              value={formatCount(library.lossless_tracks)}
              detail={
                library.lossless_bytes
                  ? formatBytes(library.lossless_bytes)
                  : undefined
              }
            />
          </div>
        </section>

        {library.high_resolution_tracks ? (
          <Card className="orbit-surface border-none p-4">
            <p className="text-2xl font-bold">
              {formatCount(library.high_resolution_tracks)}
            </p>
            <p className="text-sm opacity-90">
              tracks above CD quality — more than 16-bit, or faster than 48 kHz
            </p>
          </Card>
        ) : null}

        {listening.total_plays ? (
          <section>
            <SectionHeader title="Listening" />
            <div className="grid grid-cols-2 gap-3">
              <Stat label="Plays" value={formatCount(listening.total_plays)} />
              <Stat
                label="Time Listened"
                value={formatLongDuration(listening.listening_seconds)}
              />
            </div>
          </section>
        ) : null}

        <PlayCountList
          title="Most Played Songs"
          entries={listening.most_played_tracks}
        />
        <PlayCountList
          title="Most Played Artists"
          entries={listening.most_played_artists}
        />

        <BreakdownList title="Format Breakdown" values={library.formats} />
        <BreakdownList title="Top Genres" values={library.genres} />
        <BreakdownList title="By Decade" values={library.decades} />
      </div>
    </PageShell>
  );
}

function Stat({
  label,
  value,
  detail,
}: {
  label: string;
  value: string;
  detail?: string;
}) {
  return (
    <Card className="p-3.5">
      <p className="text-muted-foreground text-[0.7rem] font-semibold tracking-wide uppercase">
        {label}
      </p>
      <p className="mt-1.5 text-xl leading-tight font-bold">{value}</p>
      {detail ? (
        <p className="text-muted-foreground mt-0.5 text-xs">{detail}</p>
      ) : null}
    </Card>
  );
}

function BreakdownList({
  title,
  values,
}: {
  title: string;
  values?: Breakdown[];
}) {
  if (!values || values.length === 0) return null;

  const total = values.reduce((sum, value) => sum + (value.count ?? 0), 0) || 1;

  return (
    <section>
      <SectionHeader title={title} />
      <Card className="divide-hairline divide-y">
        {values.slice(0, 8).map((value, index) => {
          const count = value.count ?? 0;
          return (
            <div key={`${value.name ?? value.label ?? index}`} className="px-4 py-3">
              <div className="flex items-baseline justify-between gap-3">
                <span className="truncate text-sm font-medium">
                  {value.name ?? value.label ?? "Unknown"}
                </span>
                <span className="text-muted-foreground shrink-0 text-xs tabular-nums">
                  {formatCount(count)}
                </span>
              </div>
              {/* The bar is the point: a list of numbers does not show a library's shape. */}
              <div className="bg-muted mt-2 h-1.5 overflow-hidden rounded-full">
                <div
                  className="orbit-surface h-full rounded-full"
                  style={{ width: `${Math.max((count / total) * 100, 2)}%` }}
                />
              </div>
            </div>
          );
        })}
      </Card>
    </section>
  );
}

function PlayCountList({
  title,
  entries,
}: {
  title: string;
  entries?: PlayCount[];
}) {
  if (!entries || entries.length === 0) return null;

  return (
    <section>
      <SectionHeader title={title} />
      <Card className="divide-hairline divide-y">
        {entries.slice(0, 8).map((entry, index) => (
          <div
            key={`${entry.content_hash ?? entry.title ?? index}`}
            className="flex items-center gap-3 px-4 py-3"
          >
            <span className="text-muted-foreground w-5 text-sm tabular-nums">
              {index + 1}
            </span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-medium">
                {entry.title ?? entry.artist ?? "Unknown"}
              </span>
              {entry.title && entry.artist ? (
                <span className="text-muted-foreground block truncate text-xs">
                  {entry.artist}
                </span>
              ) : null}
            </span>
            <span className="text-muted-foreground shrink-0 text-xs tabular-nums">
              {formatCount(entry.plays)} plays
            </span>
          </div>
        ))}
      </Card>
    </section>
  );
}
