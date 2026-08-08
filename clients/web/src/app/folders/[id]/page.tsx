"use client";

import { use, useMemo } from "react";
import { Play, Shuffle } from "lucide-react";

import { PageShell } from "@/components/page-shell";
import { TrackRow } from "@/components/track-row";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/primitives";
import { VirtualList } from "@/components/virtual-list";
import { useCatalog } from "@/lib/catalog/store";
import { sortTracks } from "@/lib/catalog/derive";
import { formatLongDuration } from "@/lib/format";
import { usePlayback } from "@/lib/playback/controller";

/**
 * One watched folder's tracks — the macOS sidebar has a row per folder, and this is the
 * same idea. No fetch is involved: every `CatalogTrack` already carries the `source_id` it
 * came from, so this is a filter over the catalogue already in memory.
 */
export default function FolderPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  const { tracks, loading } = useCatalog();
  const playback = usePlayback();

  const { songs, name } = useMemo(() => {
    const inFolder = tracks.filter((track) => track.source_id === id);
    return {
      songs: sortTracks(inFolder, "title"),
      // The hub names sources, but only on the tracks themselves, so the name comes from
      // whichever track carries one.
      name: inFolder.find((track) => track.source_name)?.source_name ?? "Folder",
    };
  }, [tracks, id]);

  const duration = songs.reduce(
    (total, track) => total + (track.duration_seconds ?? 0),
    0,
  );

  return (
    <PageShell
      title={name}
      subtitle={
        songs.length > 0
          ? `${songs.length.toLocaleString()} tracks · ${formatLongDuration(duration)}`
          : undefined
      }
      backHref="/settings"
    >
      {songs.length === 0 ? (
        loading ? null : (
          <EmptyState
            title="Nothing In This Folder"
            description="Your hub has not catalogued any playable tracks here yet."
          />
        )
      ) : (
        <>
          <div className="mb-3 flex gap-2">
            <Button onClick={() => playback.play(songs)} className="flex-1">
              <Play className="size-4 fill-current" />
              Play
            </Button>
            <Button
              variant="outline"
              onClick={() => {
                playback.play(songs);
                void playback.toggleShuffle();
              }}
              className="flex-1"
            >
              <Shuffle className="size-4" />
              Shuffle
            </Button>
          </div>

          <VirtualList
            items={songs}
            estimatedItemHeight={64}
            getKey={(track) => track.track_id}
            renderItem={(track, index) => (
              <TrackRow
                track={track}
                onPlay={() => playback.play(songs, index)}
              />
            )}
          />
        </>
      )}
    </PageShell>
  );
}
