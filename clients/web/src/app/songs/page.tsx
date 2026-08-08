"use client";

import { useMemo, useState } from "react";
import { ArrowUpDown, Heart, Music4, Shuffle } from "lucide-react";

import { MoreLikeThis } from "@/components/more-like-this";
import { PageShell } from "@/components/page-shell";
import { TrackRow } from "@/components/track-row";
import { Button } from "@/components/ui/button";
import { EmptyState, Skeleton } from "@/components/ui/primitives";
import { VirtualList } from "@/components/virtual-list";
import { useCatalog } from "@/lib/catalog/store";
import { sortTracks, type SongSort } from "@/lib/catalog/derive";
import { usePlayback } from "@/lib/playback/controller";
import { cn } from "@/lib/utils";

const SORTS: { value: SongSort; label: string }[] = [
  { value: "title", label: "Title" },
  { value: "artist", label: "Artist" },
  { value: "album", label: "Album" },
  { value: "recent", label: "Year" },
  { value: "duration", label: "Length" },
];

/** The whole library, the phone counterpart to the macOS song table. */
export default function SongsPage() {
  const { tracks, loading } = useCatalog();
  const playback = usePlayback();
  const [sort, setSort] = useState<SongSort>("title");
  const [favouritesOnly, setFavouritesOnly] = useState(false);
  const [sortOpen, setSortOpen] = useState(false);

  const visible = useMemo(() => {
    const filtered = favouritesOnly
      ? tracks.filter((track) => track.favourite)
      : tracks;
    return sortTracks(filtered, sort);
  }, [tracks, sort, favouritesOnly]);

  if (loading && tracks.length === 0) {
    return (
      <PageShell title="Songs">
        <div className="grid gap-2">
          {Array.from({ length: 8 }).map((_, index) => (
            <Skeleton key={index} className="h-16 w-full" />
          ))}
        </div>
      </PageShell>
    );
  }

  return (
    <PageShell
      title="Songs"
      subtitle={`${visible.length.toLocaleString()} tracks`}
      actions={
        <>
          <button
            type="button"
            onClick={() => setFavouritesOnly((value) => !value)}
            aria-label="Show favourites only"
            aria-pressed={favouritesOnly}
            className={cn(
              "rounded-full p-2 transition-colors",
              favouritesOnly ? "text-primary" : "text-muted-foreground",
            )}
          >
            <Heart className={cn("size-5", favouritesOnly && "fill-current")} />
          </button>
          <button
            type="button"
            onClick={() => setSortOpen((value) => !value)}
            aria-label="Sort"
            className="text-muted-foreground rounded-full p-2"
          >
            <ArrowUpDown className="size-5" />
          </button>
        </>
      }
    >
      {sortOpen ? (
        <div className="hide-scrollbar -mx-4 mb-3 flex gap-2 overflow-x-auto px-4">
          {SORTS.map((option) => (
            <button
              key={option.value}
              type="button"
              onClick={() => {
                setSort(option.value);
                setSortOpen(false);
              }}
              className={cn(
                "shrink-0 rounded-full px-3.5 py-1.5 text-xs font-medium transition-colors",
                sort === option.value
                  ? "bg-primary text-primary-foreground"
                  : "bg-muted text-muted-foreground",
              )}
            >
              {option.label}
            </button>
          ))}
        </div>
      ) : null}

      {visible.length === 0 ? (
        <EmptyState
          icon={<Music4 className="size-10" />}
          title={favouritesOnly ? "No Favourites Yet" : "Nothing Here Yet"}
          description={
            favouritesOnly
              ? "Tap the heart on a track and it will show up here."
              : "Add a folder to your hub and Aro will fill this in."
          }
        />
      ) : (
        <>
          <div className="mb-3 flex gap-2">
            <Button onClick={() => playback.play(visible)} className="flex-1">
              Play All
            </Button>
            <Button
              variant="outline"
              onClick={() => {
                playback.play(visible);
                void playback.toggleShuffle();
              }}
              className="flex-1"
            >
              <Shuffle className="size-4" />
              Shuffle
            </Button>
          </div>

          <VirtualList
            items={visible}
            estimatedItemHeight={64}
            getKey={(track) => track.track_id}
            renderItem={(track, index) => (
              <TrackRow
                track={track}
                onPlay={() => playback.play(visible, index)}
              />
            )}
          />

          {/* Tracks whatever is actually playing, falling back to the top of the list so
              the shelf is populated before playback starts. */}
          <MoreLikeThis
            seed={playback.current ?? visible.find((track) => track.content_hash)}
          />
        </>
      )}
    </PageShell>
  );
}
