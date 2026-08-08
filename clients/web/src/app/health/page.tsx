"use client";

import { useCallback, useState } from "react";
import {
  Copy,
  FileQuestion,
  FolderTree,
  Layers,
  MoveRight,
  ShieldCheck,
} from "lucide-react";

import { PageShell, SectionHeader } from "@/components/page-shell";
import { Card, EmptyState, Skeleton } from "@/components/ui/primitives";
import { useAsyncRefresh } from "@/hooks/use-async-refresh";
import { api, ApiError } from "@/lib/hub/api";
import type { HealthRecommendation, HealthReport } from "@/lib/hub/types";
import { formatBytes } from "@/lib/format";
import { cn } from "@/lib/utils";

/**
 * What is untidy about the library.
 *
 * The analysis runs on the hub, not here. It is a question about *files* — the same bytes
 * in two places, a path that no longer resolves, a folder whose contents disagree about
 * their album — and the hub is the machine that actually holds them. A client only ever
 * sees the copies on its own disk, which for a remote client is almost none.
 */
export default function HealthPage() {
  const [report, setReport] = useState<HealthReport | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setReport(await api.health());
      setError(null);
    } catch (cause) {
      setError(
        cause instanceof ApiError ? cause.message : "Unavailable right now.",
      );
    }
  }, []);

  // Scanning changes what is here, but slowly — a folder rescan, not a keystroke.
  useAsyncRefresh(load, { intervalMs: 60_000 });

  if (!report) {
    return (
      <PageShell title="Library Health">
        {error ? (
          <EmptyState title="Health Unavailable" description={error} />
        ) : (
          <div className="grid gap-3">
            {Array.from({ length: 4 }).map((_, index) => (
              <Skeleton key={index} className="h-24 w-full" />
            ))}
          </div>
        )}
      </PageShell>
    );
  }

  if (report.recommendation_count === 0) {
    return (
      <PageShell title="Library Health">
        <EmptyState
          icon={<ShieldCheck className="size-10" />}
          title="Nothing To Tidy"
          description="No duplicates, no missing files, and every folder agrees with itself."
        />
      </PageShell>
    );
  }

  return (
    <PageShell
      title="Library Health"
      subtitle={`${report.recommendation_count} ${
        report.recommendation_count === 1 ? "thing" : "things"
      } worth a look`}
    >
      <div className="flex flex-col gap-7 pb-4">
        {report.exact_reclaimable_bytes > 0 ? (
          <Card className="orbit-surface border-none p-4">
            <p className="text-2xl font-bold">
              {formatBytes(report.exact_reclaimable_bytes)}
            </p>
            <p className="text-sm opacity-90">
              reclaimable by removing byte-for-byte duplicates. Alternate encodings
              are excluded — which of those to keep is your call, not arithmetic.
            </p>
          </Card>
        ) : null}

        <Group
          title="Exact Duplicates"
          subtitle="Identical content hash, so removing a copy loses nothing"
          icon={<Copy className="size-4" />}
          items={report.exact_duplicates}
        />
        <Group
          title="Alternate Encodings"
          subtitle="Same recording in more than one format — review before removing"
          icon={<Layers className="size-4" />}
          items={report.alternate_encodings}
        />
        <Group
          title="Moved Files"
          subtitle="A reachable copy matches a path that no longer resolves"
          icon={<MoveRight className="size-4" />}
          items={report.moved_files}
        />
        <Group
          title="Missing Files"
          subtitle="Nothing Aro scanned for these is reachable"
          icon={<FileQuestion className="size-4" />}
          items={report.missing_files}
        />
        <Group
          title="Fragmented Folders"
          subtitle="One folder whose tracks disagree about which album they are"
          icon={<FolderTree className="size-4" />}
          items={report.fragmented_folders}
        />
      </div>
    </PageShell>
  );
}

function Group({
  title,
  subtitle,
  icon,
  items,
}: {
  title: string;
  subtitle: string;
  icon: React.ReactNode;
  items: HealthRecommendation[];
}) {
  if (items.length === 0) return null;

  return (
    <section>
      <SectionHeader title={`${title} · ${items.length}`} subtitle={subtitle} />
      <div className="flex flex-col gap-3">
        {items.slice(0, 50).map((item) => (
          <Card key={item.id} className="overflow-hidden">
            <div className="border-hairline flex items-start gap-3 border-b px-4 py-3">
              <span className="text-muted-foreground mt-0.5 shrink-0">
                {icon}
              </span>
              <div className="min-w-0 flex-1">
                <p className="truncate text-sm font-medium">{item.title}</p>
                <p className="text-muted-foreground truncate text-xs">
                  {item.artist}
                </p>
              </div>
              {item.potential_savings_bytes > 0 ? (
                <span className="text-muted-foreground shrink-0 text-xs tabular-nums">
                  {formatBytes(item.potential_savings_bytes)}
                </span>
              ) : null}
            </div>

            <p className="text-muted-foreground px-4 py-2 text-xs leading-relaxed">
              {item.reason}
            </p>

            {item.copies.length > 0 ? (
              <div className="divide-hairline divide-y border-t border-[var(--hairline)]">
                {item.copies.map((copy) => {
                  const preferred = copy.track_id + "|" + copy.path === item.preferred_copy_id;
                  return (
                    <div
                      key={`${copy.track_id}|${copy.path}`}
                      className="flex items-baseline gap-2 px-4 py-2"
                    >
                      <span
                        className={cn(
                          "min-w-0 flex-1 truncate text-xs",
                          !copy.available && "text-muted-foreground line-through",
                        )}
                        title={copy.path}
                      >
                        {copy.path}
                      </span>
                      <span className="text-muted-foreground shrink-0 text-[0.65rem] uppercase">
                        {copy.codec}
                      </span>
                      {preferred ? (
                        <span className="text-primary shrink-0 text-[0.65rem] font-semibold uppercase">
                          Keep
                        </span>
                      ) : null}
                    </div>
                  );
                })}
              </div>
            ) : null}
          </Card>
        ))}
      </div>
    </section>
  );
}
