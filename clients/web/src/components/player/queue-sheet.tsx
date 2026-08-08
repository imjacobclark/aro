"use client";

import { Trash2 } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/primitives";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { formatDuration } from "@/lib/format";
import { usePlayback } from "@/lib/playback/controller";
import { cn } from "@/lib/utils";

/** What is playing next — the phone's version of the macOS player bar's queue popover. */
export function QueueSheet({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const playback = usePlayback();

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent title="Queue" description="Tracks queued to play">
        <div className="border-hairline flex items-center justify-between border-b px-5 py-4">
          <h2 className="text-lg font-semibold">Queue</h2>
          {playback.queue.length > 0 ? (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                playback.clearQueue();
                onOpenChange(false);
              }}
              className="text-muted-foreground mr-10"
            >
              <Trash2 className="size-4" />
              Clear
            </Button>
          ) : null}
        </div>

        <div className="overflow-y-auto overscroll-contain px-2 pb-[max(1rem,env(safe-area-inset-bottom))]">
          {playback.queue.length === 0 ? (
            <EmptyState
              title="Nothing Queued"
              description="Play an album or start radio from a track, and what comes next shows up here."
            />
          ) : (
            playback.queue.map((track, index) => (
              <button
                key={`${track.track_id}-${index}`}
                type="button"
                onClick={() => {
                  playback.jumpTo(index);
                  onOpenChange(false);
                }}
                className={cn(
                  "flex w-full items-center gap-3 rounded-xl px-3 py-2 text-left transition-colors",
                  index === playback.queueIndex && "bg-[var(--selected)]",
                  index < playback.queueIndex && "opacity-45",
                )}
              >
                <Artwork
                  hash={track.artwork_hash}
                  alt={track.album ?? track.title}
                  className="size-10 shrink-0"
                  rounded="rounded-md"
                />
                <span className="min-w-0 flex-1">
                  <span
                    className={cn(
                      "block truncate text-sm font-medium",
                      index === playback.queueIndex && "text-primary",
                    )}
                  >
                    {track.title}
                  </span>
                  <span className="text-muted-foreground block truncate text-xs">
                    {track.artist ?? "Unknown Artist"}
                  </span>
                </span>
                <span className="text-muted-foreground shrink-0 text-xs tabular-nums">
                  {formatDuration(track.duration_seconds)}
                </span>
              </button>
            ))
          )}
        </div>
      </SheetContent>
    </Sheet>
  );
}
