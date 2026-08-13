"use client";

import { use } from "react";
import Link from "next/link";
import { Play, Radio, Shuffle } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { MoreLikeThis } from "@/components/more-like-this";
import { PageShell } from "@/components/page-shell";
import { TrackRow } from "@/components/track-row";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/primitives";
import { useCatalog } from "@/lib/catalog/store";
import { artistId } from "@/lib/catalog/derive";
import { formatLongDuration } from "@/lib/format";
import { usePlayback } from "@/lib/playback/controller";

export default function AlbumPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  const { albums, loading } = useCatalog();
  const playback = usePlayback();

  const album = albums.find((candidate) => candidate.id === id);

  if (!album) {
    return (
      <PageShell title="Album" backHref="/albums">
        {loading ? null : (
          <EmptyState
            title="Album Not Found"
            description="It may have been removed from the library, or renamed by an edit."
          />
        )}
      </PageShell>
    );
  }

  return (
    <PageShell title={album.name} subtitle={album.artist} backHref="/albums">
      <div className="mb-5 flex flex-col items-center gap-4 sm:flex-row sm:items-end">
        <Artwork
          hash={album.artworkHash}
          alt={album.name}
          eager
          className="w-44 shadow-xl sm:w-52"
          rounded="rounded-2xl"
        />
        <div className="min-w-0 flex-1 text-center sm:text-left">
          <Link
            href={`/artists/${artistId(album.artist)}`}
            className="text-primary text-sm font-medium hover:underline"
          >
            {album.artist}
          </Link>
          <p className="text-muted-foreground mt-1 text-xs">
            {album.year ? `${album.year} · ` : ""}
            {album.tracks.length}{" "}
            {album.tracks.length === 1 ? "track" : "tracks"} ·{" "}
            {formatLongDuration(album.durationSeconds)}
          </p>

          <div className="mt-4 flex gap-2">
            <Button
              onClick={() => playback.play(album.tracks)}
              className="flex-1 sm:flex-none"
            >
              <Play className="size-4 fill-current" />
              Play
            </Button>
            <Button
              variant="outline"
              onClick={() => {
                playback.play(album.tracks);
                void playback.toggleShuffle();
              }}
              className="flex-1 sm:flex-none"
            >
              <Shuffle className="size-4" />
              Shuffle
            </Button>
            {/* An album page could show you what it sounds like and offer no way to hear
                any of it: the shelf below has been listing similar music with nothing to
                press, while artists and playlists both had this control. Seeded by the
                record, matching the shelf. */}
            <Button
              variant="outline"
              onClick={() => {
                const seed = album.tracks.find((track) => track.content_hash);
                if (seed) void playback.startRadio(seed);
              }}
              className="flex-1 sm:flex-none"
            >
              <Radio className="size-4" />
              Radio
            </Button>
          </div>
        </div>
      </div>

      <div className="flex flex-col">
        {album.tracks.map((track, index) => (
          <TrackRow
            key={track.track_id}
            track={track}
            index={track.track_number ?? index + 1}
            showArtwork={false}
            showArtist={false}
            onPlay={() => playback.play(album.tracks, index)}
          />
        ))}
      </div>

      {/* Seeded by the record rather than by whatever happens to be playing: here the
          interesting question is "what sounds like *this album*". */}
      <MoreLikeThis
        seed={album.tracks.find((track) => track.content_hash)}
        seedLabel={album.name}
        besideCollection
      />
    </PageShell>
  );
}
