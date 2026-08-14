"use client";

import { use, useCallback, useState } from "react";
import { Play, Radio, Shuffle } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { MoreLikeThis } from "@/components/more-like-this";
import { PageShell } from "@/components/page-shell";
import { TrackRow } from "@/components/track-row";
import { Button } from "@/components/ui/button";
import { EmptyState, Skeleton } from "@/components/ui/primitives";
import { useAsyncRefresh } from "@/hooks/use-async-refresh";
import { useCatalog } from "@/lib/catalog/store";
import { api } from "@/lib/hub/api";
import type { CatalogTrack, GeneratedPlaylist } from "@/lib/hub/types";
import { formatLongDuration } from "@/lib/format";
import { usePlayback } from "@/lib/playback/controller";

/**
 * A generated playlist's contents.
 *
 * Home used to play a playlist the moment it was tapped, with no way to see what was in it
 * first — the one place this client was blinder than the Mac app, which has had a detail
 * view all along. Playlists are generated per request rather than stored, so this refetches
 * and finds by id instead of reading a record.
 */
export default function PlaylistPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  const { byHash, loading: catalogueLoading } = useCatalog();
  const playback = usePlayback();
  const [playlist, setPlaylist] = useState<GeneratedPlaylist | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    try {
      const playlists = await api.playlists();
      setPlaylist(playlists.find((candidate) => candidate.id === id) ?? null);
    } catch {
      // Leave whatever is on screen; the poll below tries again.
    } finally {
      setLoading(false);
    }
  }, [id]);

  // The hub regenerates playlists as listening changes, so this follows the same 15-second
  // cadence Home does rather than freezing whatever was true on arrival.
  useAsyncRefresh(load, { intervalMs: 15_000 });

  // See Home's `resolve`: a hash the catalogue has not reached yet is not a missing track,
  // and dropping it silently renders a playlist as a fraction of itself.
  const hashes = playlist?.content_hashes ?? [];
  const resolved: CatalogTrack[] = hashes
    .map((hash) => byHash.get(hash))
    .filter((track): track is CatalogTrack => Boolean(track));
  const settling = catalogueLoading && resolved.length < hashes.length;
  const tracks: CatalogTrack[] = settling ? [] : resolved;

  // `settling` too: the playlist is known but the catalogue has not caught up with it, and
  // a half-resolved track list is worse than a skeleton for the moment it takes.
  if (!playlist || settling) {
    return (
      <PageShell title={playlist?.title ?? "Playlist"} backHref="/">
        {loading || settling ? (
          <Skeleton className="h-40 w-full rounded-2xl" />
        ) : (
          <EmptyState
            title="Playlist Not Available"
            description="Your hub rebuilds these as you listen, so this one may simply no longer be one of them."
          />
        )}
      </PageShell>
    );
  }

  const duration = tracks.reduce(
    (total, track) => total + (track.duration_seconds ?? 0),
    0,
  );

  return (
    <PageShell title={playlist.title} subtitle={playlist.subtitle} backHref="/">
      <div className="mb-5 flex flex-col items-center gap-4 sm:flex-row sm:items-end">
        <Artwork
          hash={tracks.find((track) => track.artwork_hash)?.artwork_hash}
          alt={playlist.title}
          eager
          className="w-44 shadow-xl sm:w-52"
          rounded="rounded-2xl"
        />
        <div className="min-w-0 flex-1 text-center sm:text-left">
          <p className="text-muted-foreground text-xs">
            {tracks.length} {tracks.length === 1 ? "track" : "tracks"} ·{" "}
            {formatLongDuration(duration)}
          </p>

          <div className="mt-4 flex gap-2">
            <Button
              onClick={() => playback.play(tracks)}
              disabled={tracks.length === 0}
              className="flex-1 sm:flex-none"
            >
              <Play className="size-4 fill-current" />
              Play
            </Button>
            <Button
              variant="outline"
              onClick={() => {
                playback.play(tracks);
                void playback.toggleShuffle();
              }}
              disabled={tracks.length === 0}
              className="flex-1 sm:flex-none"
            >
              <Shuffle className="size-4" />
              Shuffle
            </Button>
            <Button
              variant="outline"
              onClick={() => void playback.startRadio(tracks[0])}
              disabled={tracks.length === 0}
              className="flex-1 sm:flex-none"
            >
              <Radio className="size-4" />
              Radio
            </Button>
          </div>
        </div>
      </div>

      {tracks.length === 0 ? (
        <EmptyState
          title="Nothing Here Yet"
          description="Your hub picked tracks this device does not hold. They may still be syncing."
        />
      ) : (
        <div className="flex flex-col">
          {tracks.map((track, index) => (
            <TrackRow
              key={`${track.track_id}-${index}`}
              track={track}
              onPlay={() => playback.play(tracks, index)}
            />
          ))}
        </div>
      )}

      <MoreLikeThis seed={tracks[0]} seedLabel={playlist.title} />
    </PageShell>
  );
}
