"use client";

import { useState } from "react";
import { Loader2, Pause, Play, SkipForward } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { NowPlayingSheet } from "@/components/player/now-playing-sheet";
import { useSwipe } from "@/hooks/use-swipe";
import {
  usePlayback,
  usePlaybackProgress,
} from "@/lib/playback/controller";

/**
 * The bar above the tabs, and the tap target that opens the full player.
 *
 * It mirrors the macOS `PlayerBar`'s look — a translucent rounded card with a hairline
 * border and a soft shadow — compressed to what a phone can spare: cover, title, artist, a
 * play/pause, and a hairline progress line along the top edge. Everything else lives one
 * tap away in the sheet, exactly as the transport, timeline and output controls sit side
 * by side on a Mac.
 *
 * It also takes gestures, because on a phone this bar is the player most of the time and
 * reaching for a 44px button to skip a track is the slow way to do something people do
 * constantly. Swipe up to open it, swipe across to move through the queue — the same
 * vocabulary every iOS music app has trained people to expect, so it needs no affordance
 * to be discovered.
 */
export function MiniPlayer() {
  const playback = usePlayback();
  const { elapsed, duration, isBuffering } = usePlaybackProgress();
  const [expanded, setExpanded] = useState(false);

  const swipe = useSwipe({
    onSwipeUp: () => setExpanded(true),
    onSwipeLeft: playback.next,
    onSwipeRight: playback.previous,
  });

  if (!playback.current) return null;

  const track = playback.current;
  const progress = duration > 0 ? (elapsed / duration) * 100 : 0;

  // The card follows the finger, damped, and never further than it needs to to read as
  // movement — a bar that slid the full width would look like it was being thrown away
  // rather than nudged.
  const followX = Math.max(-56, Math.min(56, swipe.offset.x * 0.5));
  const followY = Math.min(0, Math.max(-40, swipe.offset.y * 0.5));

  return (
    <>
      <div className="fixed inset-x-0 bottom-[calc(3.75rem+env(safe-area-inset-bottom))] z-40 px-2 lg:bottom-4 lg:left-auto lg:right-4 lg:w-[26rem] lg:px-0">
        <div
          {...swipe.handlers}
          style={{
            transform: `translate3d(${followX}px, ${followY}px, 0)`,
            // Only animate the settle. Following the finger has to be immediate, or the
            // card lags behind the touch and the whole thing feels broken.
            transition: swipe.dragging
              ? "none"
              : "transform 260ms cubic-bezier(0.22, 1, 0.36, 1)",
            touchAction: "pan-y",
          }}
          className="drag-surface bg-card/85 border-hairline relative overflow-hidden rounded-2xl border shadow-[0_5px_14px_rgba(0,0,0,0.09)] backdrop-blur-xl motion-reduce:transition-none">
          <div
            className="orbit-surface absolute inset-x-0 top-0 h-0.5 transition-[width] duration-300"
            style={{ width: `${progress}%` }}
            aria-hidden
          />

          <div className="flex items-center gap-3 p-2.5">
            <button
              type="button"
              onClick={() => setExpanded(true)}
              className="flex min-w-0 flex-1 items-center gap-3 text-left"
              aria-label={`Now playing: ${track.title}. Open the player.`}
            >
              <Artwork
                hash={track.artwork_hash}
                alt={track.album ?? track.title}
                className="size-11 shrink-0"
                rounded="rounded-lg"
              />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-sm leading-tight font-medium">
                  {track.title}
                </span>
                <span className="text-muted-foreground block truncate text-xs">
                  {track.artist ?? "Unknown Artist"}
                </span>
              </span>
            </button>

            <button
              type="button"
              onClick={playback.toggle}
              aria-label={playback.isPlaying ? "Pause" : "Play"}
              className="hover:bg-muted shrink-0 rounded-full p-2.5 transition-colors"
            >
              {isBuffering ? (
                <Loader2 className="size-5 animate-spin" />
              ) : playback.isPlaying ? (
                <Pause className="size-5 fill-current" />
              ) : (
                <Play className="size-5 fill-current" />
              )}
            </button>

            <button
              type="button"
              onClick={playback.next}
              aria-label="Next track"
              className="hover:bg-muted mr-0.5 hidden shrink-0 rounded-full p-2.5 transition-colors sm:block"
            >
              <SkipForward className="size-5 fill-current" />
            </button>
          </div>
        </div>
      </div>

      <NowPlayingSheet open={expanded} onOpenChange={setExpanded} />
    </>
  );
}
