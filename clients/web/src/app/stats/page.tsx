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
  formatDuration,
  formatLongDuration,
} from "@/lib/format";

/**
 * `StatsView`, sourced from the hub instead of a local SQLite file.
 *
 * On macOS these numbers come from the client's own database; here they come from
 * `/v1/library/stats`, which returns the hub's whole `dashboard_stats()` — library
 * composition, listening history, fidelity and metadata completeness in one call. Same
 * figures, one fewer copy of the truth.
 *
 * Every field name here is a field the hub actually sends. That is worth stating because
 * this page previously read a shape nobody produced — `total_plays`, `most_played_tracks`,
 * `library.lossless_tracks` — and since `LibraryStats` marked them all optional, the
 * mistake compiled, the numbers came out empty, and the entire Listening section was gated
 * on a value that was permanently `undefined`, so it never rendered once. Check the wire
 * before adding to it.
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
  const fidelity = stats.fidelity ?? {};
  const listening = stats.listening ?? {};
  const metadata = stats.metadata ?? {};
  const range = fidelity.dynamic_range ?? {};
  const hasListened = Boolean(
    listening.logged_plays || listening.total_seconds,
  );

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
              value={formatLongDuration(library.total_duration)}
            />
            <Stat label="On Disk" value={formatBytes(library.file_size_bytes)} />
            <Stat
              label="Lossless"
              value={
                fidelity.lossless_fraction === undefined
                  ? formatCount(fidelity.lossless_tracks)
                  : `${Math.round(fidelity.lossless_fraction * 100)}%`
              }
              detail={
                fidelity.lossless_tracks
                  ? `${formatCount(fidelity.lossless_tracks)} songs · ${formatBytes(fidelity.lossless_bytes)}`
                  : undefined
              }
            />
          </div>
        </section>

        {fidelity.high_resolution_tracks ? (
          <Card className="orbit-surface border-none p-4">
            <p className="text-2xl font-bold">
              {formatCount(fidelity.high_resolution_tracks)}
            </p>
            <p className="text-sm opacity-90">
              tracks above CD quality — more than 16-bit, or faster than 48 kHz
            </p>
          </Card>
        ) : null}

        <section>
          <SectionHeader
            title="Listening"
            subtitle={hasListened ? undefined : "Nothing played yet"}
          />
          {hasListened ? (
            <>
              <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                <Stat label="Plays" value={formatCount(listening.logged_plays)} />
                <Stat
                  label="Time Listened"
                  value={formatLongDuration(listening.total_seconds)}
                />
                <Stat
                  label="Songs Heard"
                  value={formatCount(listening.unique_tracks_played)}
                  detail={
                    library.track_count && listening.unique_tracks_played
                      ? `${Math.round((listening.unique_tracks_played / library.track_count) * 100)}% of the library`
                      : undefined
                  }
                />
                <Stat
                  label="Last 30 Days"
                  value={formatLongDuration(listening.last_30_days_seconds)}
                />
                <Stat
                  label="Streak"
                  value={
                    listening.current_streak === 1
                      ? "1 day"
                      : `${formatCount(listening.current_streak)} days`
                  }
                  detail="consecutive days with a play"
                />
              </div>
              <DailyChart days={listening.daily} />
            </>
          ) : (
            <Card className="text-muted-foreground p-4 text-sm">
              Play something and it will show up here — the hub records listening
              itself, so plays from this browser, the Mac app and any other device
              all land in the same history.
            </Card>
          )}
        </section>

        <PlayCountList title="Most Played Songs" entries={listening.top_tracks} />
        <PlayCountList
          title="Most Played Artists"
          entries={listening.top_artists}
        />
        <PlayCountList
          title="Recently Played"
          entries={listening.recent}
          showTime
        />

        <BreakdownList title="Format Breakdown" values={library.formats} />
        <BreakdownList title="Top Genres" values={library.genres} />
        <BreakdownList title="By Decade" values={library.decades} />

        <TallyList
          title="Sample Rates"
          tally={library.sample_rates}
          format={(key) => `${(Number(key) / 1000).toFixed(1).replace(/\.0$/, "")} kHz`}
        />
        <TallyList
          title="Bit Depths"
          tally={library.bit_depths}
          format={(key) => `${key}-bit`}
        />

        {range.analyzed_tracks ? (
          <section>
            <SectionHeader
              title="Dynamic Range"
              subtitle={`Measured on ${formatCount(range.analyzed_tracks)} songs`}
            />
            <div className="grid grid-cols-3 gap-3">
              <Stat label="Quietest" value={decibels(range.min_crest_db)} />
              <Stat label="Average" value={decibels(range.mean_crest_db)} />
              <Stat label="Widest" value={decibels(range.max_crest_db)} />
            </div>
            <p className="text-muted-foreground mt-2 px-1 text-xs">
              Crest factor: the gap between a song&rsquo;s peaks and its average
              level. Higher means more room to breathe; heavily compressed
              masters sit low.
            </p>
          </section>
        ) : null}

        <section>
          <SectionHeader title="Metadata" />
          <Card className="divide-hairline divide-y">
            <Coverage label="Titles" fraction={metadata.title_coverage} />
            <Coverage label="Artists" fraction={metadata.artist_coverage} />
            <Coverage label="Albums" fraction={metadata.album_coverage} />
          </Card>
        </section>

        <section>
          <SectionHeader title="Right Now" />
          <div className="grid grid-cols-2 gap-3">
            <Stat
              label="Listening"
              value={formatCount(stats.live?.active_listeners ?? 0)}
              detail={`${formatCount(stats.live?.connected_devices ?? 0)} devices connected`}
            />
            <Stat
              label="Sources"
              value={formatCount(stats.sources?.total ?? 0)}
              detail={
                stats.sources?.unavailable
                  ? `${formatCount(stats.sources.unavailable)} unavailable`
                  : "all reachable"
              }
            />
          </div>
        </section>

        {stats.generated_at ? (
          <p className="text-muted-foreground px-1 text-xs">
            Measured by the hub at{" "}
            {new Date(stats.generated_at).toLocaleTimeString([], {
              hour: "numeric",
              minute: "2-digit",
            })}
            .
          </p>
        ) : null}
      </div>
    </PageShell>
  );
}

function decibels(value: number | undefined): string {
  return value === undefined ? "—" : `${value.toFixed(1)} dB`;
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

/**
 * The last month of listening, one column per day.
 *
 * A single "time listened" figure says how much but not *when*, and the hub already
 * computes the daily series — it was simply never asked for.
 */
function DailyChart({ days }: { days?: { date?: string; seconds?: number }[] }) {
  if (!days || days.length === 0) return null;
  const peak = Math.max(...days.map((day) => day.seconds ?? 0), 1);
  if (peak <= 1) return null;

  const total = days.reduce((sum, day) => sum + (day.seconds ?? 0), 0);
  const label = (date?: string) =>
    date
      ? new Date(`${date}T00:00:00`).toLocaleDateString([], {
          month: "short",
          day: "numeric",
        })
      : "";

  return (
    <Card className="mt-3 p-4">
      <div className="flex items-end gap-[3px]" style={{ height: 72 }}>
        {days.map((day, index) => {
          const seconds = day.seconds ?? 0;
          return (
            <div
              key={day.date ?? index}
              // A day with nothing played keeps a hairline, so the empty days are
              // legible as days rather than as gaps in the axis.
              className={
                seconds > 0
                  ? "orbit-surface min-h-[2px] flex-1 rounded-sm"
                  : "bg-muted min-h-[2px] flex-1 rounded-sm"
              }
              style={{ height: `${Math.max((seconds / peak) * 100, 3)}%` }}
              title={`${label(day.date)} — ${formatDuration(seconds)}`}
            />
          );
        })}
      </div>
      <div className="text-muted-foreground mt-2 flex justify-between text-xs">
        <span>{label(days[0]?.date)}</span>
        <span>{formatLongDuration(total)} over {days.length} days</span>
        <span>{label(days[days.length - 1]?.date)}</span>
      </div>
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

  const total =
    values.reduce((sum, value) => sum + (value.track_count ?? 0), 0) || 1;

  return (
    <section>
      <SectionHeader title={title} />
      <Card className="divide-hairline divide-y">
        {values.slice(0, 8).map((value, index) => {
          const count = value.track_count ?? 0;
          return (
            <div key={value.name ?? index} className="px-4 py-3">
              <div className="flex items-baseline justify-between gap-3">
                <span className="truncate text-sm font-medium">
                  {value.name ?? "Unknown"}
                </span>
                <span className="text-muted-foreground shrink-0 text-xs tabular-nums">
                  {formatCount(count)}
                  {value.file_size_bytes
                    ? ` · ${formatBytes(value.file_size_bytes)}`
                    : ""}
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

/**
 * Sample rates and bit depths arrive as maps keyed by the value itself, not as the
 * `Breakdown` lists everything else uses, so they get their own renderer rather than a
 * conversion that would have to invent a sort order anyway. Numeric keys sort numerically.
 */
function TallyList({
  title,
  tally,
  format,
}: {
  title: string;
  tally?: Record<string, number>;
  format: (key: string) => string;
}) {
  const entries = Object.entries(tally ?? {}).sort(
    (a, b) => Number(a[0]) - Number(b[0]),
  );
  if (entries.length === 0) return null;

  const total = entries.reduce((sum, [, count]) => sum + count, 0) || 1;

  return (
    <section>
      <SectionHeader title={title} />
      <Card className="divide-hairline divide-y">
        {entries.map(([key, count]) => (
          <div
            key={key}
            className="flex items-center justify-between gap-3 px-4 py-3"
          >
            <span className="text-sm font-medium">{format(key)}</span>
            <span className="text-muted-foreground text-xs tabular-nums">
              {formatCount(count)} · {Math.round((count / total) * 100)}%
            </span>
          </div>
        ))}
      </Card>
    </section>
  );
}

function Coverage({
  label,
  fraction,
}: {
  label: string;
  fraction?: number;
}) {
  if (fraction === undefined) return null;
  const percent = Math.round(fraction * 100);
  return (
    <div className="flex items-center gap-3 px-4 py-3">
      <span className="w-16 text-sm font-medium">{label}</span>
      <div className="bg-muted h-1.5 flex-1 overflow-hidden rounded-full">
        <div
          className="orbit-surface h-full rounded-full"
          style={{ width: `${Math.max(percent, 2)}%` }}
        />
      </div>
      <span className="text-muted-foreground w-14 text-right text-xs tabular-nums">
        {percent}%
      </span>
    </div>
  );
}

function PlayCountList({
  title,
  entries,
  showTime = false,
}: {
  title: string;
  entries?: PlayCount[];
  /** Recently-played wants when, not how many. */
  showTime?: boolean;
}) {
  if (!entries || entries.length === 0) return null;

  return (
    <section>
      <SectionHeader title={title} />
      <Card className="divide-hairline divide-y">
        {entries.slice(0, 8).map((entry, index) => (
          <div
            key={`${entry.id ?? entry.title ?? index}-${index}`}
            className="flex items-center gap-3 px-4 py-3"
          >
            <span className="text-muted-foreground w-5 text-sm tabular-nums">
              {index + 1}
            </span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-medium">
                {entry.title ?? "Unknown"}
              </span>
              {entry.subtitle ? (
                <span className="text-muted-foreground block truncate text-xs">
                  {entry.subtitle}
                </span>
              ) : null}
            </span>
            <span className="text-muted-foreground shrink-0 text-xs tabular-nums">
              {showTime
                ? relativeTime(entry.played_at)
                : `${formatCount(entry.play_count)} plays`}
            </span>
          </div>
        ))}
      </Card>
    </section>
  );
}

/** "4m", "3h", "2d" — enough to place a play in time without a full timestamp. */
function relativeTime(iso?: string): string {
  if (!iso) return "";
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "";
  const minutes = Math.max(Math.round((Date.now() - then) / 60_000), 0);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}
