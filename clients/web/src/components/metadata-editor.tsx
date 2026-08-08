"use client";

import { useState } from "react";
import { Check, Loader2, RotateCcw, Sparkles } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { Button } from "@/components/ui/button";
import { Input, Label } from "@/components/ui/primitives";
import { Sheet, SheetContent } from "@/components/ui/sheet";
import { useCatalog } from "@/lib/catalog/store";
import { api, ApiError } from "@/lib/hub/api";
import type { ArtworkCandidate, CatalogTrack } from "@/lib/hub/types";
import { cn } from "@/lib/utils";

/**
 * Correcting what the hub thinks a track is — the macOS `MetadataEditorView` on a phone.
 *
 * These edits are Aro's golden master: the hub stores them as `manual_*` fields that
 * identification and rescans must never overwrite. That is why "Reset" exists as its own
 * action rather than as clearing a box — an empty field means "this is genuinely blank",
 * while reset means "forget I said anything and go and identify it again".
 */
export function MetadataEditor({
  track,
  open,
  onOpenChange,
}: {
  track: CatalogTrack;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      {/* Keyed by track and by openness so every visit starts from the track's current
          values. Resetting the form in an effect instead would render the previous
          track's text for a frame before replacing it. */}
      {open ? (
        <EditorForm
          key={`${track.track_id}-${track.content_hash ?? ""}`}
          track={track}
          onClose={() => onOpenChange(false)}
        />
      ) : null}
    </Sheet>
  );
}

function EditorForm({
  track,
  onClose,
}: {
  track: CatalogTrack;
  onClose: () => void;
}) {
  const { patchTrack, refresh } = useCatalog();
  const [fields, setFields] = useState({
    title: track.title,
    artist: track.artist ?? "",
    album: track.album ?? "",
    genre: track.genre ?? "",
    release_year: track.release_year?.toString() ?? "",
    track_number: track.track_number?.toString() ?? "",
    disc_number: track.disc_number?.toString() ?? "",
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [candidates, setCandidates] = useState<ArtworkCandidate[] | null>(null);
  const [searchingArt, setSearchingArt] = useState(false);

  const save = async () => {
    if (!track.content_hash) return;
    setBusy(true);
    setError(null);

    try {
      await api.setMetadata(
        [track.content_hash],
        {
          title: fields.title,
          artist: fields.artist,
          album: fields.album,
          genre: fields.genre,
          // The hub's fields are numbers; an empty box means "leave it unset", which is
          // different from zero.
          ...numeric("release_year", fields.release_year),
          ...numeric("track_number", fields.track_number),
          ...numeric("disc_number", fields.disc_number),
        },
      );

      patchTrack(track.content_hash, {
        title: fields.title,
        artist: fields.artist || null,
        album: fields.album || null,
        genre: fields.genre || null,
        release_year: toNumber(fields.release_year),
        track_number: toNumber(fields.track_number),
        disc_number: toNumber(fields.disc_number),
      });
      onClose();
    } catch (cause) {
      setError(describe(cause));
    } finally {
      setBusy(false);
    }
  };

  const reset = async () => {
    if (!track.content_hash) return;
    setBusy(true);
    try {
      await api.setMetadata([track.content_hash], {}, true);
      await refresh();
      onClose();
    } catch (cause) {
      setError(describe(cause));
    } finally {
      setBusy(false);
    }
  };

  /**
   * Artwork search is a job on the hub, not an answer: it queries MusicBrainz and the
   * Cover Art Archive behind a rate limiter, so the request returns a job id and this
   * polls it. Cached candidates come back immediately on a second look.
   */
  const findArtwork = async () => {
    if (!track.content_hash) return;
    setSearchingArt(true);
    setError(null);

    try {
      const cached = await api.artworkCandidates(track.content_hash);
      if (cached.length > 0) {
        setCandidates(cached);
        return;
      }

      const job = await api.discoverArtwork(track.content_hash);
      for (let attempt = 0; attempt < 30; attempt += 1) {
        await sleep(1000);
        const status = await api.job(job.id);
        if (status.state !== "running") break;
      }
      setCandidates(await api.artworkCandidates(track.content_hash));
    } catch (cause) {
      setError(describe(cause));
    } finally {
      setSearchingArt(false);
    }
  };

  const chooseArtwork = async (candidate: ArtworkCandidate) => {
    if (!track.content_hash) return;
    setBusy(true);
    try {
      // The hub fetches the full image (it is the only side allowed to talk to the Cover
      // Art Archive) and hands back bytes, which go straight into the metadata write.
      const resolved = await api.resolveArtwork(candidate.url);
      await api.setMetadata([track.content_hash], {
        artwork_base64: resolved.image_base64,
      });
      await refresh();
      onClose();
    } catch (cause) {
      setError(describe(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <SheetContent
      title="Edit metadata"
      description={`Correct the details Aro holds for ${track.title}`}
      className="max-h-[92dvh]"
    >
        <div className="border-hairline flex items-center gap-3 border-b px-5 py-4">
          <Artwork
            hash={track.artwork_hash}
            alt={track.album ?? track.title}
            className="size-14"
            rounded="rounded-lg"
          />
          <div className="min-w-0">
            <h2 className="truncate font-semibold">Edit Metadata</h2>
            <p className="text-muted-foreground truncate text-xs">
              Your corrections outrank anything Aro identifies later.
            </p>
          </div>
        </div>

        <div className="flex-1 overflow-y-auto overscroll-contain px-5 py-4">
          <div className="grid gap-4">
            <Field
              label="Title"
              value={fields.title}
              onChange={(value) => setFields({ ...fields, title: value })}
            />
            <Field
              label="Artist"
              value={fields.artist}
              onChange={(value) => setFields({ ...fields, artist: value })}
            />
            <Field
              label="Album"
              value={fields.album}
              onChange={(value) => setFields({ ...fields, album: value })}
            />
            <Field
              label="Genre"
              value={fields.genre}
              onChange={(value) => setFields({ ...fields, genre: value })}
            />
            <div className="grid grid-cols-3 gap-3">
              <Field
                label="Year"
                inputMode="numeric"
                value={fields.release_year}
                onChange={(value) =>
                  setFields({ ...fields, release_year: value })
                }
              />
              <Field
                label="Track"
                inputMode="numeric"
                value={fields.track_number}
                onChange={(value) =>
                  setFields({ ...fields, track_number: value })
                }
              />
              <Field
                label="Disc"
                inputMode="numeric"
                value={fields.disc_number}
                onChange={(value) =>
                  setFields({ ...fields, disc_number: value })
                }
              />
            </div>
          </div>

          <div className="mt-6">
            <Button
              variant="outline"
              onClick={findArtwork}
              disabled={searchingArt || busy}
              className="w-full"
            >
              {searchingArt ? (
                <Loader2 className="size-4 animate-spin" />
              ) : (
                <Sparkles className="size-4" />
              )}
              {searchingArt ? "Searching for artwork…" : "Find Artwork"}
            </Button>

            {candidates ? (
              candidates.length === 0 ? (
                <p className="text-muted-foreground mt-3 text-center text-sm">
                  No covers found for this release.
                </p>
              ) : (
                <div className="mt-3 grid grid-cols-3 gap-2">
                  {candidates.slice(0, 9).map((candidate) => (
                    <button
                      key={candidate.url}
                      type="button"
                      onClick={() => void chooseArtwork(candidate)}
                      disabled={busy}
                      className="border-hairline focus-visible:ring-ring overflow-hidden rounded-lg border transition hover:opacity-85 focus-visible:ring-2 disabled:opacity-50"
                    >
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img
                        src={candidate.thumbnail_url ?? candidate.url}
                        alt={candidate.title ?? "Cover candidate"}
                        className="aspect-square w-full object-cover"
                        loading="lazy"
                      />
                    </button>
                  ))}
                </div>
              )
            ) : null}
          </div>

          {error ? (
            <p className="text-destructive mt-4 text-sm">{error}</p>
          ) : null}
        </div>

        <div className="border-hairline flex gap-2 border-t px-5 py-4 pb-[max(1rem,env(safe-area-inset-bottom))]">
          <Button
            variant="ghost"
            onClick={reset}
            disabled={busy}
            className="text-muted-foreground"
          >
            <RotateCcw className="size-4" />
            Reset
          </Button>
          <Button onClick={save} disabled={busy} className="flex-1">
            {busy ? (
              <Loader2 className="size-4 animate-spin" />
            ) : (
              <Check className="size-4" />
            )}
            Save
          </Button>
        </div>
    </SheetContent>
  );
}

function Field({
  label,
  value,
  onChange,
  inputMode,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  inputMode?: "numeric" | "text";
}) {
  return (
    <div className={cn("grid gap-1.5")}>
      <Label>{label}</Label>
      <Input
        value={value}
        inputMode={inputMode}
        onChange={(event) => onChange(event.target.value)}
      />
    </div>
  );
}

function numeric(field: string, value: string): Record<string, number> {
  const parsed = toNumber(value);
  return parsed === null ? {} : { [field]: parsed };
}

function toNumber(value: string): number | null {
  const parsed = Number.parseInt(value, 10);
  return Number.isFinite(parsed) ? parsed : null;
}

function describe(cause: unknown): string {
  if (cause instanceof ApiError) return cause.message;
  return cause instanceof Error ? cause.message : "That did not work.";
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
