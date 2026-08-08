"use client";

import Link from "next/link";
import { Users } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { PageShell } from "@/components/page-shell";
import { EmptyState, Skeleton } from "@/components/ui/primitives";
import { useCatalog } from "@/lib/catalog/store";

/** `ArtistsView`: a list rather than a grid, because artist names are what identify them. */
export default function ArtistsPage() {
  const { artists, loading } = useCatalog();

  if (loading && artists.length === 0) {
    return (
      <PageShell title="Artists">
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
      title="Artists"
      subtitle={`${artists.length.toLocaleString()} artists`}
    >
      {artists.length === 0 ? (
        <EmptyState
          icon={<Users className="size-10" />}
          title="No Artists Yet"
          description="Add a folder to your hub and the artists in it will appear here."
        />
      ) : (
        <div className="flex flex-col">
          {artists.map((artist) => (
            <Link
              key={artist.id}
              href={`/artists/${artist.id}`}
              className="hover:bg-muted flex items-center gap-3 rounded-xl px-2 py-2 transition-colors"
            >
              <Artwork
                hash={artist.artworkHash}
                alt={artist.name}
                className="size-12 shrink-0"
                rounded="rounded-full"
              />
              <span className="min-w-0 flex-1">
                <span className="block truncate font-medium">{artist.name}</span>
                <span className="text-muted-foreground block truncate text-xs">
                  {artist.albums.length}{" "}
                  {artist.albums.length === 1 ? "album" : "albums"} ·{" "}
                  {artist.trackCount}{" "}
                  {artist.trackCount === 1 ? "track" : "tracks"}
                </span>
              </span>
            </Link>
          ))}
        </div>
      )}
    </PageShell>
  );
}
