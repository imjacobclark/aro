"use client";

import { useCallback, useState } from "react";

import { Artwork } from "@/components/artwork";
import { Carousel, SectionHeader } from "@/components/page-shell";
import { useAsyncRefresh } from "@/hooks/use-async-refresh";
import { useCatalog } from "@/lib/catalog/store";
import { api } from "@/lib/hub/api";
import type { CatalogTrack } from "@/lib/hub/types";
import { usePlayback } from "@/lib/playback/controller";

/**
 * A shelf of tracks the hub considers similar to a seed, measured from the audio itself —
 * tempo, energy, brightness, MFCC, chroma — rather than from tags or listening history.
 * The macOS app puts the same shelf under its song table and on album and artist pages;
 * this is the web half of that.
 *
 * Renders nothing at all when there is no seed, no reachable hub, or the seed has not been
 * analysed yet. That silence is deliberate and matches macOS: this is a discovery
 * affordance, and an empty shelf or an error row would be worse than simply not appearing.
 */
export function MoreLikeThis({
  seed,
  seedLabel,
}: {
  seed: CatalogTrack | undefined;
  /** What the subtitle calls the seed — an album or artist name where the shelf stands for
   *  a whole collection rather than one track. */
  seedLabel?: string;
}) {
  const { byHash } = useCatalog();
  const playback = usePlayback();
  const [similar, setSimilar] = useState<CatalogTrack[]>([]);
  const hash = seed?.content_hash ?? undefined;

  const load = useCallback(async () => {
    if (!hash) {
      setSimilar([]);
      return;
    }
    try {
      const station = await api.radio(hash);
      // The station always leads with its own seed, which would be a confusing first card
      // in a row headed "more like *this*".
      setSimilar(
        station.content_hashes
          .filter((candidate) => candidate !== hash)
          .map((candidate) => byHash.get(candidate))
          .filter((track): track is CatalogTrack => Boolean(track)),
      );
    } catch {
      setSimilar([]);
    }
  }, [hash, byHash]);

  useAsyncRefresh(load, { key: hash ?? null });

  if (similar.length === 0) return null;

  return (
    <section className="mt-8">
      <SectionHeader
        title="More Like This"
        subtitle={
          seedLabel ? `Sounds like ${seedLabel}` : "Measured from the audio itself"
        }
      />
      <Carousel>
        {similar.slice(0, 20).map((track) => (
          <button
            key={track.track_id}
            type="button"
            onClick={() => playback.play(similar, similar.indexOf(track))}
            className="w-32 shrink-0 snap-start text-left"
          >
            <Artwork
              hash={track.artwork_hash}
              alt={track.album ?? track.title}
              className="w-32"
            />
            <p className="mt-2 truncate text-xs font-medium">{track.title}</p>
            <p className="text-muted-foreground truncate text-[0.7rem]">
              {track.artist ?? "Unknown Artist"}
            </p>
          </button>
        ))}
      </Carousel>
    </section>
  );
}
