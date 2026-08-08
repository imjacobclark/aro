"use client";

import { useState } from "react";
import { Disc3 } from "lucide-react";

import { artworkUrl } from "@/lib/hub/api";
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
}: {
  hash: string | null | undefined;
  alt: string;
  className?: string;
  rounded?: string;
  eager?: boolean;
}) {
  const [failed, setFailed] = useState(false);
  const source = artworkUrl(hash);

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
      loading={eager ? "eager" : "lazy"}
      decoding="async"
      /*
       * Covers are served at whatever size they were embedded or fetched at, and in a real
       * library that ranges from 10 KB to well over 20 MB. A grid of them will happily
       * occupy every connection the browser allows per origin, and audio — requested from
       * that same origin — then waits behind them. Marking them low priority is what keeps
       * a page of album art from stalling the music it belongs to.
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
