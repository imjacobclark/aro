"use client";

import { useState } from "react";
import {
  ChevronDown,
  Heart,
  ListMusic,
  Loader2,
  Pause,
  Pencil,
  Play,
  Radio,
  Repeat,
  Repeat1,
  Shuffle,
  SkipBack,
  SkipForward,
  Volume2,
} from "lucide-react";

import { Artwork } from "@/components/artwork";
import { MetadataEditor } from "@/components/metadata-editor";
import { QueueSheet } from "@/components/player/queue-sheet";
import { Badge, Slider } from "@/components/ui/primitives";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { useSwipe } from "@/hooks/use-swipe";
import { useCatalog } from "@/lib/catalog/store";
import { api } from "@/lib/hub/api";
import { formatDuration, formatQuality, isHighResolution } from "@/lib/format";
import {
  usePlayback,
  usePlaybackProgress,
} from "@/lib/playback/controller";
import { cn } from "@/lib/utils";

/**
 * The full-screen player: the macOS `PlayerBar` unfolded.
 *
 * On a Mac the transport, timeline, favourite and output controls all fit on one 92px bar
 * beside the library. A phone has no such width, so the same controls become a screen —
 * cover first, then title, then transport, in the order a listener's eye already expects
 * from every music app they own.
 *
 * It closes by being dragged downwards as well as by the chevron. A full-screen sheet that
 * can only be dismissed by finding a small control in a corner is the one thing that most
 * marks a web app out from a native one, because every iOS sheet has been dismissible this
 * way for years and the hand tries it without asking.
 */
export function NowPlayingSheet({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const playback = usePlayback();
  const { elapsed, duration, isBuffering } = usePlaybackProgress();
  const { patchTrack } = useCatalog();
  const [scrubbing, setScrubbing] = useState<number | null>(null);
  const [queueOpen, setQueueOpen] = useState(false);
  const [editorOpen, setEditorOpen] = useState(false);

  const track = playback.current;

  const dismiss = useSwipe({
    axis: "y",
    threshold: 110,
    onSwipeDown: () => onOpenChange(false),
  });

  if (!track) return null;

  const position = scrubbing ?? elapsed;
  const total = duration || track.duration_seconds || 0;

  const toggleFavourite = async () => {
    if (!track.content_hash) return;
    const next = !track.favourite;
    patchTrack(track.content_hash, { favourite: next });
    try {
      await api.setFavourite(track.content_hash, next);
    } catch {
      patchTrack(track.content_hash, { favourite: !next });
    }
  };

  return (
    <Sheet
      open={open}
      onOpenChange={(next) => {
        // Closing mid-drag would otherwise leave the scrubber pinned where the thumb was.
        if (!next) setScrubbing(null);
        onOpenChange(next);
      }}
    >
      <SheetContent
        side="full"
        showClose={false}
        title={`${track.title} by ${track.artist ?? "Unknown Artist"}`}
        description="Playback controls"
        className="bg-background"
      >
        <div
          {...dismiss.handlers}
          style={{
            transform: `translate3d(0, ${Math.max(0, dismiss.offset.y)}px, 0)`,
            // Dragging past the threshold visibly dims the sheet, so the gesture reports
            // what it is about to do before the finger lifts.
            opacity: 1 - Math.min(Math.max(dismiss.offset.y, 0) / 700, 0.35),
            transition: dismiss.dragging
              ? "none"
              : "transform 300ms cubic-bezier(0.22, 1, 0.36, 1), opacity 200ms ease-out",
            touchAction: "pan-y",
          }}
          className="drag-surface mx-auto flex h-full w-full max-w-md flex-col px-6 pt-[calc(1rem+var(--safe-top))] pb-[calc(1.5rem+var(--safe-bottom))] motion-reduce:transition-none"
        >
          {/* The grabber every iOS sheet has. It is not a control — it is the hint that
              tells a hand the sheet can be pulled, which is what makes the gesture
              discoverable at all. */}
          <div
            aria-hidden
            className="bg-muted-foreground/30 mx-auto mb-1 h-1 w-9 shrink-0 rounded-full"
          />
          <div className="flex items-center justify-between py-2">
            <button
              type="button"
              onClick={() => onOpenChange(false)}
              aria-label="Close the player"
              className="hover:bg-muted -ml-2 rounded-full p-2"
            >
              <ChevronDown className="size-6" />
            </button>
            <p className="text-muted-foreground text-[0.7rem] font-semibold tracking-[0.12em] uppercase">
              {track.album ?? "Now Playing"}
            </p>
            <button
              type="button"
              onClick={() => setEditorOpen(true)}
              aria-label="Edit metadata"
              className="hover:bg-muted -mr-2 rounded-full p-2"
            >
              <Pencil className="size-5" />
            </button>
          </div>

          <div className="flex flex-1 flex-col justify-center gap-7 py-4">
            <Artwork
              hash={track.artwork_hash}
              alt={track.album ?? track.title}
              eager
              size="detail"
              className="mx-auto w-full max-w-[min(78vw,20rem)] shadow-2xl"
              rounded="rounded-3xl"
            />

            <div className="flex items-start gap-3">
              <div className="min-w-0 flex-1">
                <h2 className="truncate text-xl leading-tight font-bold">
                  {track.title}
                </h2>
                <p className="text-muted-foreground mt-1 truncate">
                  {track.artist ?? "Unknown Artist"}
                </p>
                <p className="text-muted-foreground mt-1.5 flex items-center gap-2 text-xs">
                  <span className="truncate">{formatQuality(track)}</span>
                  {isHighResolution(track) ? (
                    <Badge tone="hires">Hi-Res</Badge>
                  ) : null}
                </p>
              </div>
              <button
                type="button"
                onClick={toggleFavourite}
                aria-label={
                  track.favourite ? "Remove from favourites" : "Add to favourites"
                }
                aria-pressed={track.favourite}
                className="hover:bg-muted mt-1 rounded-full p-2.5"
              >
                <Heart
                  className={cn(
                    "size-6 transition-colors",
                    track.favourite && "fill-current text-primary",
                  )}
                />
              </button>
            </div>

            <div>
              <Slider
                value={[Math.min(position, total || position)]}
                max={total || 1}
                step={1}
                aria-label="Playback position"
                onValueChange={([value]) => setScrubbing(value)}
                onValueCommit={([value]) => {
                  playback.seek(value);
                  setScrubbing(null);
                }}
              />
              <div className="text-muted-foreground mt-2 flex justify-between text-xs tabular-nums">
                <span>{formatDuration(position)}</span>
                <span>-{formatDuration(Math.max(total - position, 0))}</span>
              </div>
            </div>

            <div className="flex items-center justify-between">
              <button
                type="button"
                onClick={() => void playback.toggleShuffle()}
                aria-label="Smart shuffle"
                aria-pressed={playback.shuffle}
                className={cn(
                  "rounded-full p-3",
                  playback.shuffle ? "text-primary" : "text-muted-foreground",
                )}
              >
                <Shuffle className="size-5" />
              </button>

              <button
                type="button"
                onClick={playback.previous}
                aria-label="Previous track"
                className="rounded-full p-3"
              >
                <SkipBack className="size-8 fill-current" />
              </button>

              <button
                type="button"
                onClick={playback.toggle}
                aria-label={playback.isPlaying ? "Pause" : "Play"}
                className="orbit-surface flex size-16 items-center justify-center rounded-full shadow-lg transition-transform active:scale-95"
              >
                {isBuffering ? (
                  <Loader2 className="size-7 animate-spin" />
                ) : playback.isPlaying ? (
                  <Pause className="size-7 fill-current" />
                ) : (
                  <Play className="ml-0.5 size-7 fill-current" />
                )}
              </button>

              <button
                type="button"
                onClick={playback.next}
                aria-label="Next track"
                className="rounded-full p-3"
              >
                <SkipForward className="size-8 fill-current" />
              </button>

              <button
                type="button"
                onClick={() =>
                  playback.setRepeat(
                    playback.repeat === "off"
                      ? "all"
                      : playback.repeat === "all"
                        ? "one"
                        : "off",
                  )
                }
                aria-label={`Repeat: ${playback.repeat}`}
                className={cn(
                  "rounded-full p-3",
                  playback.repeat === "off"
                    ? "text-muted-foreground"
                    : "text-primary",
                )}
              >
                {playback.repeat === "one" ? (
                  <Repeat1 className="size-5" />
                ) : (
                  <Repeat className="size-5" />
                )}
              </button>
            </div>

            {/* A phone's own volume keys are the real control; this only appears where a
                pointer exists, matching the macOS bar's volume slider. */}
            <div className="hidden items-center gap-3 [@media(pointer:fine)]:flex">
              <Volume2 className="text-muted-foreground size-4 shrink-0" />
              <Slider
                value={[playback.volume]}
                max={1}
                step={0.01}
                aria-label="Volume"
                onValueChange={([value]) => playback.setVolume(value)}
              />
            </div>
          </div>

          <div className="flex items-center justify-center gap-2 pt-2">
            <FooterAction
              icon={<ListMusic className="size-4" />}
              label={`Queue · ${playback.queue.length}`}
              onClick={() => setQueueOpen(true)}
            />
            <FooterAction
              icon={<Radio className="size-4" />}
              label="Start Radio"
              onClick={() => void playback.startRadio(track)}
            />
          </div>

          {playback.error ? (
            <p className="text-destructive pt-3 text-center text-sm">
              {playback.error}
            </p>
          ) : null}
        </div>
      </SheetContent>

      <QueueSheet open={queueOpen} onOpenChange={setQueueOpen} />
      <MetadataEditor
        track={track}
        open={editorOpen}
        onOpenChange={setEditorOpen}
      />
    </Sheet>
  );
}

function FooterAction({
  icon,
  label,
  onClick,
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="text-muted-foreground hover:bg-muted hover:text-foreground flex items-center gap-2 rounded-full px-4 py-2 text-xs font-medium transition-colors"
    >
      {icon}
      {label}
    </button>
  );
}
