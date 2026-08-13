"use client";

import { useState } from "react";
import { Disc3 } from "lucide-react";

import { artworkUrl, type ArtworkSize } from "@/lib/hub/api";
import { cn } from "@/lib/utils";

/**
 * A cover, or the placeholder that stands in for one.
 *
 * `<img>` rather than `next/image`: the optimizer is off (no `sharp` on a 32-bit Pi), the
 * covers are already sized, and every one of them is content-addressed and immutably
 * cached by the browser after its first fetch.
 */
export function Artwork({
  hash,
  alt,
  className,
  rounded = "rounded-xl",
  eager = false,
  size = "grid",
}: {
  hash: string | null | undefined;
  alt: string;
  className?: string;
  rounded?: string;
  eager?: boolean;
  /**
   * Defaults to the small copy, because almost every cover on screen is a list row or a
   * grid cell. Only the surfaces that fill a phone — the full screen player, an album
   * header — need `detail`, and they ask for it.
   */
  size?: ArtworkSize;
}) {
  const [failed, setFailed] = useState(false);
  const source = artworkUrl(hash, size);

  if (!source || failed) {
    return (
      <div
        className={cn(
          "bg-album text-muted-foreground/40 border-hairline flex aspect-square items-center justify-center border",
          rounded,
          className,
        )}
        aria-label={alt}
        role="img"
      >
        <Disc3 className="size-1/3" strokeWidth={1.25} />
      </div>
    );
  }

  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={source}
      alt={alt}
      /*
       * A cover is scenery, not something to pick up. Left draggable, starting a swipe on
       * one begins a native image drag instead — which cancels the pointer stream, so the
       * gesture that was meant to dismiss the player silently does nothing. On a phone the
       * same default is what makes a long press offer to save the image mid-swipe.
       */
      draggable={false}
      loading={eager ? "eager" : "lazy"}
      decoding="async"
      /*
       * Covers used to be served at whatever size they were embedded or fetched at — 10 KB
       * to well over 20 MB — and a grid of them would occupy every connection the browser
       * allows per origin, leaving audio from that same origin waiting behind them. The hub
       * now sends a copy sized for the box, which fixes the cause; this stays because
       * ordering still matters when a grid and a track start at the same moment.
       */
      fetchPriority={eager ? "high" : "low"}
      onError={() => setFailed(true)}
      className={cn(
        "bg-album border-hairline aspect-square w-full border object-cover",
        rounded,
        className,
      )}
    />
  );
}
