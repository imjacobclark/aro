"use client";

import { useCallback, useMemo, useState } from "react";
import Link from "next/link";
import { Play, Radio, Sparkles } from "lucide-react";

import { Artwork } from "@/components/artwork";
import { Carousel, PageShell, SectionHeader } from "@/components/page-shell";
import { useAsyncRefresh } from "@/hooks/use-async-refresh";
import { useClientValue } from "@/hooks/use-client-value";
import { TrackRow } from "@/components/track-row";
import { EmptyState, Skeleton } from "@/components/ui/primitives";
import { useCatalog } from "@/lib/catalog/store";
import { api } from "@/lib/hub/api";
import type { CatalogTrack, GeneratedPlaylist } from "@/lib/hub/types";
import { usePlayback } from "@/lib/playback/controller";
import { cn } from "@/lib/utils";

/**
 * Home: the hub's own editorial, rendered.
 *
 * Every playlist here is generated server-side from listening history, favourites, artist
 * and year groupings, and MusicBrainz mood tags — this screen only maps the returned
 * content hashes onto the local catalogue and groups them into the same four sections the
 * macOS `HomeView` shows. Nothing is computed here that the hub does not already know,
 * which is exactly why a second client can exist at all.
 */

/**
 * The `for_you` recipes reserved for "Made For Your Library" rather than the hero row —
 * the same three the macOS Home screen holds back. `lost-albums` spans several albums, so
 * it belongs with the library-intelligence mixes rather than beside a Daily Mix.
 */
const MADE_FOR_LIBRARY_IDS = new Set([
  "recently-loved",
  "deep-cuts",
  "lost-albums",
]);

/** Kinds Home groups explicitly. Anything else falls through to the catch-all shelf. */
const KNOWN_KINDS = new Set([
  "for_you",
  "mood",
  "hits_by_year",
  "artist_mix",
  "favourite_artist",
  "recently_played_album",
  "recently_played_track",
  "replay_month",
]);

/**
 * The last playlists the hub gave this session.
 *
 * Module scope rather than state because it has to outlive the component: Home is
 * unmounted every time the listener opens another tab and remounted when they come back,
 * and re-showing a skeleton for data that is seconds old is worse than showing it slightly
 * stale. Not persisted to disk — a fresh launch should ask.
 */
let lastPlaylists: GeneratedPlaylist[] = [];

export default function HomePage() {
  const { tracks, byHash, loading } = useCatalog();
  const playback = usePlayback();
  // Seeded from the last set this session produced, so coming back to Home shows what was
  // here before rather than collapsing to a skeleton while the hub is asked again. Home is
  // remounted on every visit — the tab bar is real navigation — and without this the whole
  // screen blanked each time, which is what it did on a phone between one screenshot and
  // the next. The macOS client keeps the same last-known-good set for the same reason.
  const [playlists, setPlaylists] = useState<GeneratedPlaylist[]>(lastPlaylists);
  const [loadingPlaylists, setLoadingPlaylists] = useState(
    lastPlaylists.length === 0,
  );

  const refresh = useCallback(async () => {
    try {
      const fresh = await api.playlists();
      lastPlaylists = fresh;
      setPlaylists(fresh);
    } catch {
      // A hub that is busy or briefly unreachable simply leaves the last set on screen.
    } finally {
      setLoadingPlaylists(false);
    }
  }, []);

  // Same 15-second cadence as the macOS Home screen, plus a refresh whenever the track
  // changes — playing something is the event most likely to change what Home should say.
  useAsyncRefresh(refresh, {
    intervalMs: 15_000,
    key: playback.current?.track_id ?? null,
  });

  const resolve = useCallback(
    (playlist: GeneratedPlaylist): CatalogTrack[] =>
      playlist.content_hashes
        .map((hash) => byHash.get(hash))
        .filter((track): track is CatalogTrack => Boolean(track)),
    [byHash],
  );

  const sections = useMemo(() => {
    // A playlist whose tracks this library does not hold is not shown at all — the hub
    // generates against its own catalogue, and a card that plays nothing is worse than
    // no card.
    const visible = playlists.filter((playlist) => resolve(playlist).length > 0);

    return {
      // Daily Mixes lead: they are k-means clusters over this listener's own analyzed
      // audio, so they are the most personal of the recipes and earn first billing.
      hero: visible
        .filter(
          (playlist) =>
            playlist.kind === "for_you" &&
            !MADE_FOR_LIBRARY_IDS.has(playlist.id),
        )
        .sort(
          (a, b) =>
            Number(b.id.startsWith("daily-mix")) -
            Number(a.id.startsWith("daily-mix")),
        ),

      topPicks: visible.filter(
        (playlist) => playlist.kind === "mood" || playlist.kind === "hits_by_year",
      ),

      // Only artists spanning more than one album earn a row of their own: a
      // single-album artist's tracks would all show the same cover.
      artistMixes: visible.filter(
        (playlist) =>
          playlist.kind === "artist_mix" &&
          new Set(resolve(playlist).map((track) => track.album)).size > 1,
      ),

      jumpBackIn: visible.filter(
        (playlist) =>
          playlist.kind === "recently_played_album" ||
          playlist.kind === "replay_month",
      ),

      // Library intelligence, plus the catch-all: a kind this build predates still gets
      // shown and stays playable rather than being silently dropped.
      madeForLibrary: visible.filter(
        (playlist) =>
          MADE_FOR_LIBRARY_IDS.has(playlist.id) ||
          playlist.kind === "time_capsule" ||
          playlist.kind === "replay_all_time" ||
          !KNOWN_KINDS.has(playlist.kind),
      ),

      any: visible.length > 0,
    };
  }, [playlists, resolve]);

  const greeting = useGreeting();

  if (loading && tracks.length === 0) {
    return (
      <PageShell title="Home">
        <div className="grid gap-3">
          <Skeleton className="h-44 w-full rounded-2xl" />
          <Skeleton className="h-40 w-full rounded-2xl" />
        </div>
      </PageShell>
    );
  }

  return (
    <PageShell title={greeting} subtitle="Built entirely from your own library">
      {!sections.any ? (
        loadingPlaylists ? (
          <Skeleton className="h-44 w-full rounded-2xl" />
        ) : (
          <EmptyState
            icon={<Sparkles className="size-10" />}
            title="No Playlists Yet"
            description="Keep listening and favouriting songs — Aro will start making playlists for you here."
          />
        )
      ) : (
        <div className="flex flex-col gap-8 pb-4">
          {sections.hero.length > 0 ? (
            <section>
              <SectionHeader title="Your Mixes" />
              <Carousel>
                {sections.hero.map((playlist) => (
                  <HeroMixCard
                    key={playlist.id}
                    playlist={playlist}
                    tracks={resolve(playlist)}
                  />
                ))}
              </Carousel>
            </section>
          ) : null}

          <PlaylistSection
            title="Top Picks For You"
            subtitle="Because of what you've been playing"
            playlists={sections.topPicks}
            resolve={resolve}
          />

          {sections.artistMixes.slice(0, 3).map((playlist) => (
            <ArtistRow
              key={playlist.id}
              playlist={playlist}
              tracks={resolve(playlist)}
            />
          ))}

          <PlaylistSection
            title="Jump Back In"
            subtitle="Pick up where you left off"
            playlists={sections.jumpBackIn}
            resolve={resolve}
          />

          <PlaylistSection
            title="Made For Your Library"
            subtitle="Intelligence built entirely from your own collection"
            playlists={sections.madeForLibrary}
            resolve={resolve}
          />
        </div>
      )}
    </PageShell>
  );
}

function HeroMixCard({
  playlist,
  tracks,
}: {
  playlist: GeneratedPlaylist;
  tracks: CatalogTrack[];
}) {
  const playback = usePlayback();
  // A playlist has no cover of its own; its first track's is the one the hub would
  // have picked anyway, since the list is already in the order the hub chose.
  const cover = tracks.find((track) => track.artwork_hash)?.artwork_hash;

  return (
    <article className="relative w-[17rem] shrink-0 snap-start overflow-hidden rounded-2xl">
      <Link
        href={`/playlists/${playlist.id}`}
        aria-label={`Open ${playlist.title}`}
        className="block"
      >
        <Artwork
          hash={cover}
          alt={playlist.title}
          className="h-44 w-full"
          rounded="rounded-2xl"
        />
      </Link>
      {/* The scrim is what keeps the title legible over any cover it lands on. It must not
          swallow the tap that opens the playlist behind it. */}
      <div className="pointer-events-none absolute inset-0 rounded-2xl bg-gradient-to-t from-black/80 via-black/25 to-transparent" />

      <div className="absolute inset-x-0 bottom-0 flex items-end gap-2 p-4">
        <div className="min-w-0 flex-1 text-white">
          <p className="truncate text-base leading-tight font-bold">
            {playlist.title}
          </p>
          <p className="mt-0.5 truncate text-xs text-white/75">
            {playlist.subtitle || `${tracks.length} tracks`}
          </p>
        </div>
        <button
          type="button"
          onClick={() => playback.play(tracks)}
          aria-label={`Play ${playlist.title}`}
          className="orbit-surface flex size-11 shrink-0 items-center justify-center rounded-full shadow-lg transition-transform active:scale-95"
        >
          <Play className="ml-0.5 size-5 fill-current" />
        </button>
      </div>
    </article>
  );
}

function PlaylistSection({
  title,
  subtitle,
  playlists,
  resolve,
}: {
  title: string;
  subtitle: string;
  playlists: GeneratedPlaylist[];
  resolve: (playlist: GeneratedPlaylist) => CatalogTrack[];
}) {
  if (playlists.length === 0) return null;

  return (
    <section>
      <SectionHeader title={title} subtitle={subtitle} />
      <Carousel>
        {playlists.map((playlist) => {
          const tracks = resolve(playlist);
          return (
            <Link
              key={playlist.id}
              href={`/playlists/${playlist.id}`}
              className="w-36 shrink-0 snap-start text-left"
            >
              <Artwork
                hash={tracks.find((track) => track.artwork_hash)?.artwork_hash}
                alt={playlist.title}
                className="w-36"
              />
              <p className="mt-2 truncate text-sm font-medium">
                {playlist.title}
              </p>
              <p className="text-muted-foreground truncate text-xs">
                {playlist.subtitle || `${tracks.length} tracks`}
              </p>
            </Link>
          );
        })}
      </Carousel>
    </section>
  );
}

/** An artist mix is worth showing as songs rather than as one more square. */
function ArtistRow({
  playlist,
  tracks,
}: {
  playlist: GeneratedPlaylist;
  tracks: CatalogTrack[];
}) {
  const playback = usePlayback();
  const shown = tracks.slice(0, 4);

  return (
    <section>
      <SectionHeader
        title={playlist.title}
        subtitle={playlist.subtitle || undefined}
        action={
          <button
            type="button"
            onClick={() => void playback.startRadio(tracks[0])}
            className={cn(
              "text-muted-foreground hover:text-foreground flex items-center gap-1.5 rounded-full px-2 py-1 text-xs",
            )}
          >
            <Radio className="size-3.5" />
            Radio
          </button>
        }
      />
      <div className="flex flex-col">
        {shown.map((track, index) => (
          <TrackRow
            key={track.track_id}
            track={track}
            onPlay={() => playback.play(tracks, index)}
          />
        ))}
      </div>
    </section>
  );
}

/** The hub already greets by time of day in its playlist titles; Home does the same. */
function useGreeting(): string {
  return useClientValue(() => {
    const hour = new Date().getHours();
    return hour < 5
      ? "Still Up"
      : hour < 12
        ? "Good Morning"
        : hour < 18
          ? "Good Afternoon"
          : "Good Evening";
  }, "Home");
}
