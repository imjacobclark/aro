"use client";

import { useMemo, useState } from "react";
import Link from "next/link";
import { Search as SearchIcon } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { PageShell, SectionHeader } from "@/components/page-shell";
import { TrackRow } from "@/components/track-row";
import { EmptyState, Input } from "@/components/ui/primitives";
import { searchTracks } from "@/lib/catalog/derive";
import { useCatalog } from "@/lib/catalog/store";
import { usePlayback } from "@/lib/playback/controller";

/**
 * Search runs against the catalogue already in memory rather than against the hub. The
 * whole library is here, so results appear as fast as someone can type — and they keep
 * working on a phone that has lost the network mid-search.
 */
export default function SearchPage() {
  const { tracks, albums, artists } = useCatalog();
  const playback = usePlayback();
  const [query, setQuery] = useState("");

  const results = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return null;

    return {
      tracks: searchTracks(tracks, query).slice(0, 40),
      albums: albums
        .filter(
          (album) =>
            album.name.toLowerCase().includes(needle) ||
            album.artist.toLowerCase().includes(needle),
        )
        .slice(0, 12),
      artists: artists
        .filter((artist) => artist.name.toLowerCase().includes(needle))
        .slice(0, 12),
    };
  }, [query, tracks, albums, artists]);

  const empty =
    results !== null &&
    results.tracks.length === 0 &&
    results.albums.length === 0 &&
    results.artists.length === 0;

  return (
    <PageShell title="Search">
      <div className="relative mb-5">
        <SearchIcon className="text-muted-foreground pointer-events-none absolute top-1/2 left-3.5 size-4 -translate-y-1/2" />
        <Input
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Songs, albums, artists, genres"
          autoComplete="off"
          className="pl-10"
          aria-label="Search the library"
        />
      </div>

      {results === null ? (
        <EmptyState
          icon={<SearchIcon className="size-10" />}
          title="Search Your Library"
          description="Everything is already on this device, so results appear as you type."
        />
      ) : empty ? (
        <EmptyState
          title="Nothing Found"
          description={`No songs, albums, or artists match “${query.trim()}”.`}
        />
      ) : (
        <div className="flex flex-col gap-7">
          {results.artists.length > 0 ? (
            <section>
              <SectionHeader title="Artists" />
              <div className="flex flex-col">
                {results.artists.map((artist) => (
                  <Link
                    key={artist.id}
                    href={`/artists/${artist.id}`}
                    className="hover:bg-muted flex items-center gap-3 rounded-xl px-2 py-2"
                  >
                    <Artwork
                      hash={artist.artworkHash}
                      alt={artist.name}
                      className="size-10 shrink-0"
                      rounded="rounded-full"
                    />
                    <span className="truncate font-medium">{artist.name}</span>
                  </Link>
                ))}
              </div>
            </section>
          ) : null}

          {results.albums.length > 0 ? (
            <section>
              <SectionHeader title="Albums" />
              <div className="grid grid-cols-3 gap-x-3 gap-y-4 sm:grid-cols-4">
                {results.albums.map((album) => (
                  <Link key={album.id} href={`/albums/${album.id}`} className="min-w-0">
                    <Artwork
                      hash={album.artworkHash}
                      alt={album.name}
                      className="w-full"
                    />
                    <p className="mt-1.5 truncate text-xs font-medium">
                      {album.name}
                    </p>
                    <p className="text-muted-foreground truncate text-[0.7rem]">
                      {album.artist}
                    </p>
                  </Link>
                ))}
              </div>
            </section>
          ) : null}

          {results.tracks.length > 0 ? (
            <section>
              <SectionHeader title="Songs" />
              <div className="flex flex-col">
                {results.tracks.map((track, index) => (
                  <TrackRow
                    key={track.track_id}
                    track={track}
                    onPlay={() => playback.play(results.tracks, index)}
                  />
                ))}
              </div>
            </section>
          ) : null}
        </div>
      )}
    </PageShell>
  );
}
