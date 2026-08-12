"use client";

import { use } from "react";
import Link from "next/link";
import { Play, Radio } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { MoreLikeThis } from "@/components/more-like-this";
import { PageShell } from "@/components/page-shell";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/primitives";
import { useCatalog } from "@/lib/catalog/store";
import { usePlayback } from "@/lib/playback/controller";

export default function ArtistPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  const { artists, loading } = useCatalog();
  const playback = usePlayback();

  const artist = artists.find((candidate) => candidate.id === id);

  if (!artist) {
    return (
      <PageShell title="Artist" backHref="/artists">
        {loading ? null : (
          <EmptyState
            title="Artist Not Found"
            description="They may have been removed from the library, or renamed by an edit."
          />
        )}
      </PageShell>
    );
  }

  const everything = artist.albums.flatMap((album) => album.tracks);

  return (
    <PageShell
      title={artist.name}
      subtitle={`${artist.albums.length} ${
        artist.albums.length === 1 ? "album" : "albums"
      } · ${artist.trackCount} tracks`}
      backHref="/artists"
    >
      <div className="mb-5 flex gap-2">
        <Button onClick={() => playback.play(everything)} className="flex-1">
          <Play className="size-4 fill-current" />
          Play
        </Button>
        <Button
          variant="outline"
          onClick={() => void playback.startRadio(everything[0])}
          className="flex-1"
        >
          <Radio className="size-4" />
          Radio
        </Button>
      </div>

      <div className="grid grid-cols-2 gap-x-4 gap-y-5 sm:grid-cols-3 lg:grid-cols-4">
        {artist.albums.map((album) => (
          <Link key={album.id} href={`/albums/${album.id}`} className="min-w-0">
            <Artwork hash={album.artworkHash} alt={album.name} className="w-full" />
            <p className="mt-2 truncate text-sm leading-tight font-medium">
              {album.name}
            </p>
            <p className="text-muted-foreground truncate text-xs">
              {album.year ?? `${album.tracks.length} tracks`}
            </p>
          </Link>
        ))}
      </div>

      <MoreLikeThis
        seed={everything.find((track) => track.content_hash)}
        seedLabel={artist.name}
        besideCollection
      />
    </PageShell>
  );
}
