"use client";

import { useState } from "react";
import {
  Heart,
  ListEnd,
  ListStart,
  MoreVertical,
  Pencil,
  Radio,
  Trash2,
} from "lucide-react";

import { Artwork } from "@/components/artwork";
import { Badge } from "@/components/ui/primitives";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { useCatalog } from "@/lib/catalog/store";
import { api } from "@/lib/hub/api";
import type { CatalogTrack } from "@/lib/hub/types";
import { formatDuration, formatQuality, isHighResolution } from "@/lib/format";
import { usePlayback } from "@/lib/playback/controller";
import { cn } from "@/lib/utils";

/**
 * One track in a list — the phone equivalent of the macOS app's song table row.
 *
 * A table with sortable columns is the right shape for a mouse and 1400px of width, and
 * the wrong one for a thumb. The same information is here, just stacked: cover, title,
 * artist, and the quality badge that tells a listener this is the lossless copy.
 */
export function TrackRow({
  track,
  index,
  onPlay,
  showArtwork = true,
  showArtist = true,
}: {
  track: CatalogTrack;
  index?: number;
  onPlay: () => void;
  showArtwork?: boolean;
  showArtist?: boolean;
}) {
  const playback = usePlayback();
  const [actionsOpen, setActionsOpen] = useState(false);
  const isCurrent = playback.current?.track_id === track.track_id;

  return (
    <div
      className={cn(
        "group flex items-center gap-3 rounded-xl px-2 py-2 transition-colors",
        isCurrent && "bg-[var(--selected)]",
      )}
    >
      <button
        type="button"
        onClick={onPlay}
        disabled={!track.available || !track.content_hash}
        className="press active:bg-muted/50 -mx-1 flex min-w-0 flex-1 items-center gap-3 rounded-xl px-1 text-left active:scale-[0.985] disabled:opacity-45"
      >
        {showArtwork ? (
          <Artwork
            hash={track.artwork_hash}
            alt={track.album ?? track.title}
            className="size-12 shrink-0"
            rounded="rounded-lg"
          />
        ) : (
          <span
            className={cn(
              "w-6 shrink-0 text-right text-sm tabular-nums",
              isCurrent ? "text-primary font-semibold" : "text-muted-foreground",
            )}
          >
            {index ?? track.track_number ?? "–"}
          </span>
        )}

        <span className="min-w-0 flex-1">
          <span
            className={cn(
              "block truncate text-[0.95rem] leading-tight font-medium",
              isCurrent && "text-primary",
            )}
          >
            {track.title}
          </span>
          <span className="text-muted-foreground mt-0.5 flex items-center gap-1.5 text-xs">
            {showArtist ? (
              <span className="truncate">
                {track.artist ?? "Unknown Artist"}
              </span>
            ) : (
              <span className="truncate">{formatQuality(track)}</span>
            )}
            {isHighResolution(track) ? (
              <Badge tone="hires" className="shrink-0">
                Hi-Res
              </Badge>
            ) : null}
            {!track.available ? (
              <Badge className="shrink-0">Unavailable</Badge>
            ) : null}
          </span>
        </span>

        <span className="text-muted-foreground shrink-0 text-xs tabular-nums">
          {formatDuration(track.duration_seconds)}
        </span>
      </button>

      <button
        type="button"
        aria-label={`Actions for ${track.title}`}
        onClick={() => setActionsOpen(true)}
        className="text-muted-foreground hover:text-foreground -mr-1 shrink-0 rounded-lg p-2"
      >
        <MoreVertical className="size-4" />
      </button>

      <TrackActionsSheet
        track={track}
        open={actionsOpen}
        onOpenChange={setActionsOpen}
      />
    </div>
  );
}

/** Everything the macOS row's context menu offers, as a bottom sheet. */
export function TrackActionsSheet({
  track,
  open,
  onOpenChange,
  onEdit,
}: {
  track: CatalogTrack;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onEdit?: () => void;
}) {
  const playback = usePlayback();
  const { patchTrack, removeTrack } = useCatalog();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const close = () => onOpenChange(false);

  const toggleFavourite = async () => {
    if (!track.content_hash) return;
    const next = !track.favourite;
    // Optimistic: a heart that waits for a Raspberry Pi to answer feels broken.
    patchTrack(track.content_hash, { favourite: next });
    setBusy(true);
    try {
      await api.setFavourite(track.content_hash, next);
      close();
    } catch (cause) {
      patchTrack(track.content_hash, { favourite: !next });
      setError(cause instanceof Error ? cause.message : "That did not save.");
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    if (!track.content_hash) return;
    setBusy(true);
    try {
      await api.removeTrack(track.content_hash);
      removeTrack(track.content_hash);
      close();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "That did not work.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent
        title={track.title}
        description="Actions for this track"
        className="pb-[var(--safe-bottom)]"
      >
        <div className="border-hairline flex items-center gap-3 border-b px-5 py-4">
          <Artwork
            hash={track.artwork_hash}
            alt={track.album ?? track.title}
            className="size-14"
            rounded="rounded-lg"
          />
          <div className="min-w-0">
            <p className="truncate font-semibold">{track.title}</p>
            <p className="text-muted-foreground truncate text-sm">
              {track.artist ?? "Unknown Artist"}
            </p>
            <p className="text-muted-foreground truncate text-xs">
              {formatQuality(track)}
            </p>
          </div>
        </div>

        <div className="flex flex-col py-2">
          <SheetAction
            icon={<Heart className={cn("size-5", track.favourite && "fill-current text-primary")} />}
            label={track.favourite ? "Remove from Favourites" : "Add to Favourites"}
            onClick={toggleFavourite}
            disabled={busy || !track.content_hash}
          />
          <SheetAction
            icon={<ListStart className="size-5" />}
            label="Play Next"
            onClick={() => {
              playback.playNext(track);
              close();
            }}
          />
          <SheetAction
            icon={<ListEnd className="size-5" />}
            label="Add to Queue"
            onClick={() => {
              playback.addToQueue(track);
              close();
            }}
          />
          <SheetAction
            icon={<Radio className="size-5" />}
            label="Start Radio"
            onClick={() => {
              void playback.startRadio(track);
              close();
            }}
          />
          {onEdit ? (
            <SheetAction
              icon={<Pencil className="size-5" />}
              label="Edit Metadata"
              onClick={() => {
                close();
                onEdit();
              }}
            />
          ) : null}
          <SheetAction
            icon={<Trash2 className="size-5" />}
            label="Remove from Library"
            tone="destructive"
            onClick={remove}
            disabled={busy}
          />
        </div>

        {error ? (
          <p className="text-destructive px-5 pb-4 text-sm">{error}</p>
        ) : null}
      </SheetContent>
    </Sheet>
  );
}

function SheetAction({
  icon,
  label,
  onClick,
  disabled,
  tone = "default",
}: {
  icon: React.ReactNode;
  label: string;
  onClick: () => void;
  disabled?: boolean;
  tone?: "default" | "destructive";
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={cn(
        "flex items-center gap-4 px-5 py-3.5 text-left text-[0.95rem] transition-colors active:bg-muted disabled:opacity-40",
        tone === "destructive" && "text-destructive",
      )}
    >
      {icon}
      {label}
    </button>
  );
}
