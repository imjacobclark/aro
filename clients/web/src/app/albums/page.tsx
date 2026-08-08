"use client";

import Link from "next/link";
import { Disc3 } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { PageShell } from "@/components/page-shell";
import { EmptyState, Skeleton } from "@/components/ui/primitives";
import { useCatalog } from "@/lib/catalog/store";

/** Every album as a cover grid — `AlbumsView`, sized for a phone's two columns. */
export default function AlbumsPage() {
  const { albums, loading } = useCatalog();

  if (loading && albums.length === 0) {
    return (
      <PageShell title="Albums">
        <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4">
          {Array.from({ length: 6 }).map((_, index) => (
            <Skeleton key={index} className="aspect-square w-full" />
          ))}
        </div>
      </PageShell>
    );
  }

  return (
    <PageShell title="Albums" subtitle={`${albums.length.toLocaleString()} albums`}>
      {albums.length === 0 ? (
        <EmptyState
          icon={<Disc3 className="size-10" />}
          title="No Albums Yet"
          description="Add a folder to your hub and Aro will group what it finds into albums."
        />
      ) : (
        <div className="grid grid-cols-2 gap-x-4 gap-y-5 sm:grid-cols-3 lg:grid-cols-4">
          {albums.map((album) => (
            <Link
              key={album.id}
              href={`/albums/${album.id}`}
              className="group min-w-0"
            >
              <Artwork
                hash={album.artworkHash}
                alt={album.name}
                className="w-full transition-transform group-active:scale-[0.98]"
              />
              <p className="mt-2 truncate text-sm leading-tight font-medium">
                {album.name}
              </p>
              <p className="text-muted-foreground truncate text-xs">
                {album.artist}
                {album.year ? ` · ${album.year}` : ""}
              </p>
            </Link>
          ))}
        </div>
      )}
    </PageShell>
  );
}
