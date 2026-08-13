"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import { useCatalog } from "@/lib/catalog/store";
import { api, artworkUrl, streamUrl, warmTranscode } from "@/lib/hub/api";
import type { CatalogTrack, StreamQuality } from "@/lib/hub/types";
import { useSettings } from "@/lib/settings";
import { ActivityReporter } from "./activity";
import {
  isUndecodable,
  rememberNoCompatibleCopy,
  rememberUndecodable,
  resolveSource,
} from "./support";

export type RepeatMode = "off" | "all" | "one";

interface PlaybackValue {
  current: CatalogTrack | null;
  queue: CatalogTrack[];
  queueIndex: number;
  isPlaying: boolean;
  volume: number;
  repeat: RepeatMode;
  shuffle: boolean;
  error: string | null;

  play: (tracks: CatalogTrack[], startIndex?: number) => void;
  playNow: (track: CatalogTrack) => void;
  playNext: (track: CatalogTrack) => void;
  addToQueue: (track: CatalogTrack) => void;
  toggle: () => void;
  next: () => void;
  previous: () => void;
  seek: (seconds: number) => void;
  setVolume: (value: number) => void;
  setRepeat: (mode: RepeatMode) => void;
  toggleShuffle: () => Promise<void>;
  startRadio: (track: CatalogTrack) => Promise<void>;
  jumpTo: (index: number) => void;
  clearQueue: () => void;
}

/**
 * Everything that changes several times a second, kept apart from everything that does not.
 *
 * `timeupdate` fires roughly four times a second for as long as music plays. When these
 * three values lived on the context above, every one of those ticks produced a new context
 * value and re-rendered every component that reads playback state — including each visible
 * row of a song list, none of which care what second the track is at. Scrolling a library
 * while listening was doing four full list renders a second for nothing.
 */
interface PlaybackProgressValue {
  elapsed: number;
  duration: number;
  isBuffering: boolean;
}

const PlaybackContext = createContext<PlaybackValue | null>(null);
const PlaybackProgressContext = createContext<PlaybackProgressValue | null>(
  null,
);

/** Below this many seconds in, "previous" means the previous track rather than a restart. */
const RESTART_THRESHOLD_SECONDS = 3;

/** How the two elements are addressed. Positions are fixed; only which one is live moves. */
type PlayerSlot = 0 | 1;

const other = (slot: PlayerSlot): PlayerSlot => (slot === 0 ? 1 : 0);

/** How close to the end of a station's queue to get before asking the hub for more. */
const STATION_REFILL_THRESHOLD = 5;

/** What a station remembers between refills: where it came from and how far it has walked. */
interface Station {
  seed: string;
  consumed: number;
  /** Set once the hub says there is nothing further out, so it stops being asked. */
  exhausted: boolean;
}

export function PlaybackProvider({ children }: { children: React.ReactNode }) {
  const settings = useSettings();
  const { byHash } = useCatalog();

  /**
   * Two elements, not one.
   *
   * A single element has to be pointed at the next track when the current one ends, which
   * makes every track change a cold start: connect, request, buffer, and only then sound.
   * With two, the next track is already loaded and buffering in the one that isn't playing,
   * and finishing a track is a swap rather than a fetch.
   *
   * Both live for the app's lifetime and neither is ever recreated. iOS grants permission
   * to play to an *element*, in response to a gesture, and a replacement element does not
   * inherit it — which is why both are unlocked together inside the first tap.
   */
  const playersRef = useRef<HTMLAudioElement[]>([]);
  const activeSlotRef = useRef<PlayerSlot>(0);
  /** The source loaded into each slot, so a reload can be skipped. Indexed by slot. */
  const loadedRef = useRef<(string | null)[]>([null, null]);
  const unlockedRef = useRef<boolean[]>([false, false]);
  const unlockingRef = useRef<boolean[]>([false, false]);

  const [queue, setQueue] = useState<CatalogTrack[]>([]);
  const [queueIndex, setQueueIndex] = useState(-1);
  const [isPlaying, setIsPlaying] = useState(false);
  const [isBuffering, setIsBuffering] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [duration, setDuration] = useState(0);
  const [volume, setVolumeState] = useState(1);
  const [repeat, setRepeat] = useState<RepeatMode>("off");
  const [shuffle, setShuffle] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const current = queueIndex >= 0 ? (queue[queueIndex] ?? null) : null;

  // Mirrors of the state the callbacks below need to read *at the moment they run* rather
  // than as it was when they were created: some resume after a network round trip, and
  // some are called straight from a click handler before React has re-rendered.
  const queueRef = useRef({ queue, index: queueIndex });
  /** The station this queue came from, if it came from one. */
  const stationRef = useRef<Station | null>(null);
  const refillingRef = useRef(false);
  const shuffleRef = useRef(shuffle);
  const repeatRef = useRef(repeat);
  const isPlayingRef = useRef(isPlaying);
  const qualityRef = useRef(settings.quality);
  const volumeRef = useRef(volume);

  useEffect(() => {
    queueRef.current = { queue, index: queueIndex };
    shuffleRef.current = shuffle;
    repeatRef.current = repeat;
    isPlayingRef.current = isPlaying;
    qualityRef.current = settings.quality;
    volumeRef.current = volume;
  }, [queue, queueIndex, shuffle, repeat, isPlaying, settings.quality, volume]);

  // One reporter for the app's lifetime: it owns the session id that ties a listen
  // together, so recreating it per render would split every play into fragments.
  const [reporter] = useState(() => new ActivityReporter());
  const reporterRef = useRef(reporter);

  useEffect(() => {
    reporter.setEnabled(settings.reportListening);
  }, [reporter, settings.reportListening]);

  useEffect(() => {
    const players = [new Audio(), new Audio()];
    for (const player of players) player.preload = "auto";
    playersRef.current = players;
    return () => {
      for (const player of players) {
        player.pause();
        player.src = "";
      }
      playersRef.current = [];
    };
  }, []);

  const playerAt = useCallback(
    (slot: PlayerSlot): HTMLAudioElement | null =>
      playersRef.current[slot] ?? null,
    [],
  );

  const activePlayer = useCallback(
    () => playerAt(activeSlotRef.current),
    [playerAt],
  );

  /**
   * Spends the current user gesture on the element that is *not* about to play.
   *
   * iOS decides whether an element may produce sound the first time `play()` is called on
   * it, and only accepts that call from inside a gesture. The idle element's first real
   * `play()` happens when a track ends, long after any tap — so without this it would be
   * refused and the queue would stop at the end of the first track. Muted, immediately
   * paused, and rewound, so the listener never hears the nudge.
   */
  const unlock = useCallback(
    (slot: PlayerSlot) => {
      const player = playerAt(slot);
      if (!player || unlockedRef.current[slot] || unlockingRef.current[slot]) {
        return;
      }
      // An element with no source cannot be played, and a `play()` refused for that reason
      // would look exactly like a granted one here. Rather than latch a permission that was
      // never given, leave it for the next transport tap — by which point the preload
      // effect has given this element a track and the nudge means something.
      if (!player.src) return;

      unlockingRef.current[slot] = true;
      player.muted = true;
      void player
        .play()
        .then(() => {
          // Only now: the browser has actually let this element make sound.
          unlockedRef.current[slot] = true;
          player.pause();
          player.currentTime = 0;
        })
        .catch(() => {})
        .finally(() => {
          player.muted = false;
          unlockingRef.current[slot] = false;
        });
    },
    [playerAt],
  );

  /**
   * Points a slot at a track and, if asked, starts it.
   *
   * Deliberately callable straight from a click handler rather than only from an effect:
   * iOS honours `play()` only when it happens synchronously inside the gesture that caused
   * it, and an effect runs a render later, by which point the browser has forgotten a
   * human was involved. Every tap therefore loads and starts here, and the effect below
   * only covers the cases nobody tapped for — a track ending, or the quality changing
   * mid-listen.
   */
  const loadInto = useCallback(
    (
      slot: PlayerSlot,
      track: CatalogTrack,
      quality: StreamQuality,
      start: boolean,
    ) => {
      const player = playerAt(slot);
      if (!player || !track.content_hash) return;

      // Not necessarily the quality the listener picked: a browser that cannot decode this
      // format gets the hub's transcode instead of silence. See `lib/playback/support`.
      const { quality: resolved, compatible } = resolveSource(track, quality);
      const source = streamUrl(track, resolved, compatible);
      const isActive = slot === activeSlotRef.current;

      if (loadedRef.current[slot] !== source) {
        loadedRef.current[slot] = source;
        player.volume = volumeRef.current;
        player.src = source;
        player.load();
        if (isActive) {
          setElapsed(0);
          setDuration(track.duration_seconds ?? 0);
          reporterRef.current.beginTrack(track.content_hash);
        }
      }

      if (start) {
        void player.play().catch((cause: DOMException) => {
          // Autoplay refusal is browser policy, not a failure: the next tap starts it.
          if (cause.name !== "NotAllowedError") {
            setError(`This track could not be played: ${cause.message}`);
          }
          setIsPlaying(false);
        });
      }
    },
    [playerAt],
  );

  const loadTrack = useCallback(
    (track: CatalogTrack, quality: StreamQuality, start: boolean) => {
      loadInto(activeSlotRef.current, track, quality, start);
    },
    [loadInto],
  );

  /**
   * Hands playback to the idle element when it is already holding the track being asked
   * for, which is the whole point of loading it early. Returns false when it is not, and
   * the caller loads normally.
   */
  const adoptPreloaded = useCallback(
    (track: CatalogTrack, quality: StreamQuality, start: boolean): boolean => {
      const idleSlot = other(activeSlotRef.current);
      const idle = playerAt(idleSlot);
      if (!idle || !track.content_hash) return false;

      const { quality: resolved, compatible } = resolveSource(track, quality);
      const source = streamUrl(track, resolved, compatible);
      if (loadedRef.current[idleSlot] !== source) return false;

      const outgoing = activePlayer();
      if (outgoing) {
        outgoing.pause();
        // Rewound rather than cleared: the element keeps its source so the same track can
        // be swapped back to instantly, which is what "previous" does within a queue.
        outgoing.currentTime = 0;
      }

      activeSlotRef.current = idleSlot;
      idle.volume = volumeRef.current;
      idle.currentTime = 0;
      setElapsed(0);
      setDuration(
        Number.isFinite(idle.duration) && idle.duration > 0
          ? idle.duration
          : (track.duration_seconds ?? 0),
      );
      reporterRef.current.beginTrack(track.content_hash);

      if (start) {
        void idle.play().catch((cause: DOMException) => {
          if (cause.name !== "NotAllowedError") {
            setError(`This track could not be played: ${cause.message}`);
          }
          setIsPlaying(false);
        });
      }
      return true;
    },
    [activePlayer, playerAt],
  );

  /**
   * Moves to another position in the queue and, unless told otherwise, starts it.
   *
   * Starting is explicit here rather than inferred from `isPlaying`, and that is the whole
   * point: when a track reaches its end the browser fires `pause` *before* `ended`, so by
   * the time the queue advances, `isPlaying` has already been set false by the element
   * itself. Reading it would mean every track loaded the next one and then sat there in
   * silence. Playing outside a user gesture is allowed because both elements were unlocked
   * by the tap that began the queue and neither has been replaced since.
   */
  const goTo = useCallback(
    (index: number, start: boolean) => {
      const { queue: current } = queueRef.current;
      const track = current[index];
      if (!track) return false;

      // Written straight to the ref as well as to state: a listener hitting next twice in
      // quick succession would otherwise have the second press read a stale index.
      queueRef.current = { queue: current, index };
      setQueueIndex(index);
      if (start) setIsPlaying(true);
      if (!adoptPreloaded(track, qualityRef.current, start)) {
        loadTrack(track, qualityRef.current, start);
      }
      return true;
    },
    [adoptPreloaded, loadTrack],
  );

  /** Where the queue goes when the current track finishes or the listener skips on. */
  const advance = useCallback(
    (direction: 1 | -1, start = true) => {
      const { queue: current, index } = queueRef.current;
      if (current.length === 0) return;

      const next = index + direction;
      if (next < 0) {
        goTo(0, start);
        return;
      }
      if (next >= current.length) {
        // The end of the queue: wrap if asked to, otherwise stop rather than restart.
        if (repeatRef.current === "all") goTo(0, start);
        else setIsPlaying(false);
        return;
      }
      goTo(next, start);
    },
    [goTo],
  );

  // Covers the one transition nobody asked for: the listener changing quality mid-track.
  // Every other change of track comes through `goTo` or `play`, which load and start in
  // the same breath — this only has to catch up the source, keeping the listener's place.
  useEffect(() => {
    if (!current) return;
    const player = activePlayer();
    const position = player?.currentTime ?? 0;
    const wasPlaying = isPlayingRef.current;

    // The preloaded track is at the old quality and is now the wrong bytes.
    loadedRef.current[other(activeSlotRef.current)] = null;

    loadTrack(current, settings.quality, wasPlaying);
    if (player && position > 0) player.currentTime = position;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settings.quality]);

  useEffect(() => {
    const players = playersRef.current;
    if (players.length === 0) return;

    /** Whether an event came from the element the listener is actually hearing. */
    const isActive = (event: Event) => event.target === players[activeSlotRef.current];

    const onTime = (event: Event) => {
      if (!isActive(event)) return;
      setElapsed((event.target as HTMLAudioElement).currentTime);
    };
    const onDuration = (event: Event) => {
      if (!isActive(event)) return;
      const value = (event.target as HTMLAudioElement).duration;
      if (Number.isFinite(value)) setDuration(value);
    };
    const onPlay = (event: Event) => {
      if (!isActive(event)) return;
      setIsPlaying(true);
      setError(null);
    };
    const onPause = (event: Event) => {
      if (!isActive(event)) return;
      // Reaching the end of a track pauses the element and fires this *before* `ended`.
      // Treating that as "the listener stopped" is what used to strand the queue, so a
      // pause at the very end is left for `onEnded` to interpret.
      if (!(event.target as HTMLAudioElement).ended) setIsPlaying(false);
    };
    const onWaiting = (event: Event) => {
      if (isActive(event)) setIsBuffering(true);
    };
    const onPlaying = (event: Event) => {
      if (isActive(event)) setIsBuffering(false);
    };
    const onEnded = (event: Event) => {
      if (!isActive(event)) return;
      const player = event.target as HTMLAudioElement;
      const finished = queueRef.current.queue[queueRef.current.index];
      if (finished?.content_hash) {
        reporterRef.current.report({
          contentHash: finished.content_hash,
          state: "stopped",
          positionSeconds: player.currentTime,
          durationSeconds: Number.isFinite(player.duration)
            ? player.duration
            : null,
          bufferedFraction: 1,
          completed: true,
        });
      }

      if (repeatRef.current === "one") {
        player.currentTime = 0;
        void player.play();
        return;
      }
      advance(1);
    };
    const onError = (event: Event) => {
      const player = event.target as HTMLAudioElement;
      const slot: PlayerSlot = player === players[0] ? 0 : 1;

      // A failure while preloading is not the listener's problem yet. Forgetting what the
      // idle element holds is enough: reaching that track loads it through the active
      // element, where the fallback below can deal with it properly.
      if (slot !== activeSlotRef.current) {
        loadedRef.current[slot] = null;
        return;
      }

      setIsBuffering(false);
      const track = queueRef.current.queue[queueRef.current.index];
      const unsupported =
        player.error?.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED;

      // A format this browser cannot decode is not a broken track — it is a track that has
      // to arrive re-encoded. Remember the format so every later track of the same kind
      // goes straight to the transcode, and retry this one where the listener left off.
      if (unsupported && track) {
        const { compatible } = resolveSource(track, qualityRef.current);
        // Asking for a copy the hub has not made yet gets the stored file back — the very
        // format that cannot be decoded here. Note it for this track and drop to the Opus
        // tier, rather than telling the listener their browser is at fault.
        if (compatible) {
          rememberNoCompatibleCopy(track);
        } else if (!isUndecodable(track)) {
          rememberUndecodable(track);
        } else {
          setError("This browser cannot play this track, even re-encoded.");
          return;
        }
        const position = player.currentTime;
        loadedRef.current[slot] = null;
        loadTrack(track, qualityRef.current, isPlayingRef.current);
        if (position > 0) player.currentTime = position;
        return;
      }

      setError("This track could not be played.");
    };

    const listeners: [string, EventListener][] = [
      ["timeupdate", onTime],
      ["loadedmetadata", onDuration],
      ["durationchange", onDuration],
      ["play", onPlay],
      ["pause", onPause],
      ["waiting", onWaiting],
      ["playing", onPlaying],
      ["ended", onEnded],
      ["error", onError],
    ];

    for (const player of players) {
      for (const [event, handler] of listeners) {
        player.addEventListener(event, handler);
      }
    }

    return () => {
      for (const player of players) {
        for (const [event, handler] of listeners) {
          player.removeEventListener(event, handler);
        }
      }
    };
  }, [advance, loadTrack]);

  /**
   * Loads the next track into the idle element while the current one plays, and asks the
   * hub to have its encode ready if it needs one.
   *
   * Both halves are about the same moment: the gap when one track ends and the next has
   * not started. The element handles the connection and the first bytes; the warm request
   * handles the hub's encoder, which would otherwise begin work only when the listener
   * arrives — and until it finishes, that track has no duration and cannot be seeked.
   */
  useEffect(() => {
    if (!isPlaying || repeat === "one") return;
    const upcoming = queue[queueIndex + 1];
    if (!upcoming?.content_hash) return;

    // Only worth warming an encode the next track will actually use: one that will be
    // served its lossless compatible copy needs no Opus made for it at all.
    const { quality, compatible } = resolveSource(upcoming, settings.quality);
    if (!compatible) warmTranscode(upcoming.content_hash, quality);
    loadInto(other(activeSlotRef.current), upcoming, settings.quality, false);
  }, [isPlaying, queue, queueIndex, repeat, settings.quality, loadInto]);

  /**
   * Resolves station hashes against the whole library.
   *
   * This used to look them up in the playback queue, which meant a station started with
   * nothing playing had only its own seed to resolve against and produced a "station" of
   * exactly one track. The hub answers with hashes from the entire library, so the
   * catalogue is the only lookup that can actually receive that answer.
   */
  const resolve = useCallback(
    (hashes: string[], seed?: CatalogTrack): CatalogTrack[] => {
      const lookup = new Map(byHash);
      if (seed?.content_hash) lookup.set(seed.content_hash, seed);
      return hashes
        .map((hash) => lookup.get(hash))
        .filter((item): item is CatalogTrack => Boolean(item));
    },
    [byHash],
  );

  /**
   * Keeps a station playing.
   *
   * Radio used to be a thirty-track playlist that simply stopped, which is the one thing a
   * station must never do. The hub ranks the whole library against the seed in a stable
   * order, so continuing is a matter of asking for the next page before the queue runs out
   * — far enough ahead that the join is never audible, and only once at a time.
   */
  useEffect(() => {
    const station = stationRef.current;
    if (!station || station.exhausted || refillingRef.current) return;
    if (queueIndex < 0 || queue.length - queueIndex > STATION_REFILL_THRESHOLD) return;

    refillingRef.current = true;
    void (async () => {
      try {
        const next = await api.radio(station.seed, undefined, station.consumed);
        const additions = resolve(next.content_hashes).filter(
          (track) =>
            track.content_hash &&
            !queueRef.current.queue.some(
              (existing) => existing.content_hash === track.content_hash,
            ),
        );
        if (next.content_hashes.length === 0) {
          station.exhausted = true;
        } else {
          station.consumed += next.content_hashes.length;
        }
        if (additions.length > 0) setQueue((current) => [...current, ...additions]);
      } catch {
        // The hub has nothing more to offer, or could not be reached. Either way the queue
        // stands and the music keeps playing to its end.
        station.exhausted = true;
      } finally {
        refillingRef.current = false;
      }
    })();
  }, [queue.length, queueIndex, resolve]);

  // Periodic progress, so a long track still counts as listened-to if the app is closed
  // before it ends.
  useEffect(() => {
    if (!isPlaying || !current?.content_hash) return;
    const hash = current.content_hash;

    const send = (state: "playing" | "stopped", completed = false) => {
      const player = activePlayer();
      if (!player) return;
      const buffered =
        player.buffered.length > 0 && player.duration
          ? player.buffered.end(player.buffered.length - 1) / player.duration
          : null;
      reporter.report({
        contentHash: hash,
        state,
        positionSeconds: player.currentTime,
        durationSeconds: Number.isFinite(player.duration)
          ? player.duration
          : null,
        bufferedFraction: buffered,
        completed,
      });
    };

    send("playing");
    const timer = window.setInterval(() => send("playing"), 15_000);
    return () => {
      window.clearInterval(timer);
      send("stopped");
    };
  }, [isPlaying, current?.content_hash, reporter, activePlayer]);

  // Lock screen, Bluetooth buttons, and the car stereo. This is most of what separates a
  // web app that plays audio from one that feels like a music player on a phone.
  useEffect(() => {
    if (!("mediaSession" in navigator) || !current) return;

    const cover = artworkUrl(current.artwork_hash);
    navigator.mediaSession.metadata = new MediaMetadata({
      title: current.title,
      artist: current.artist ?? "Unknown Artist",
      album: current.album ?? "",
      artwork: cover
        ? [
            { src: cover, sizes: "512x512", type: "image/jpeg" },
            { src: cover, sizes: "256x256", type: "image/jpeg" },
          ]
        : [],
    });
    navigator.mediaSession.playbackState = isPlaying ? "playing" : "paused";
  }, [current, isPlaying]);

  const toggle = useCallback(() => {
    const player = activePlayer();
    if (!player || !current) return;
    // Every transport control is a gesture, and a gesture is the only currency that buys
    // the idle element permission to play. Spending each one costs nothing when it is
    // already unlocked and saves the queue stalling at a track boundary when it is not.
    unlock(other(activeSlotRef.current));
    if (player.paused) {
      void player.play().catch(() => setIsPlaying(false));
    } else {
      player.pause();
    }
  }, [activePlayer, current, unlock]);

  const seek = useCallback(
    (seconds: number) => {
      const player = activePlayer();
      if (!player) return;
      player.currentTime = seconds;
      setElapsed(seconds);
    },
    [activePlayer],
  );

  const next = useCallback(() => advance(1), [advance]);

  const previous = useCallback(() => {
    const player = activePlayer();
    // Part-way into a track, "previous" means "start this one again" — the convention
    // every music player shares, and the macOS transport's behaviour too.
    if (player && player.currentTime > RESTART_THRESHOLD_SECONDS) {
      player.currentTime = 0;
      return;
    }
    advance(-1);
  }, [activePlayer, advance]);

  useEffect(() => {
    if (!("mediaSession" in navigator)) return;
    const session = navigator.mediaSession;

    session.setActionHandler("play", toggle);
    session.setActionHandler("pause", toggle);
    session.setActionHandler("nexttrack", next);
    session.setActionHandler("previoustrack", previous);
    session.setActionHandler("seekto", (details) => {
      if (details.seekTime !== undefined) seek(details.seekTime);
    });

    return () => {
      session.setActionHandler("play", null);
      session.setActionHandler("pause", null);
      session.setActionHandler("nexttrack", null);
      session.setActionHandler("previoustrack", null);
      session.setActionHandler("seekto", null);
    };
  }, [toggle, next, previous, seek]);

  const play = useCallback(
    (tracks: CatalogTrack[], startIndex = 0) => {
      const playable = tracks.filter((track) => track.content_hash);
      if (playable.length === 0) return;

      const index = Math.min(Math.max(startIndex, 0), playable.length - 1);
      // Whatever this queue is, it is not the station that was playing — `startRadio`
      // sets it again straight after calling this.
      stationRef.current = null;
      setQueue(playable);
      setQueueIndex(index);
      setIsPlaying(true);
      // Before the state update, not after: this call is still inside the tap.
      loadTrack(playable[index], qualityRef.current, true);
      // And so is this. The element that will play the *second* track has to be given its
      // permission now, while a human is demonstrably present — by the time it is needed,
      // no gesture is in scope and the browser would refuse.
      unlock(other(activeSlotRef.current));
    },
    [loadTrack, unlock],
  );

  const playNow = useCallback((track: CatalogTrack) => play([track]), [play]);

  const playNext = useCallback(
    (track: CatalogTrack) => {
      setQueue((current) => {
        const copy = [...current];
        copy.splice(queueIndex + 1, 0, track);
        return copy;
      });
    },
    [queueIndex],
  );

  const addToQueue = useCallback((track: CatalogTrack) => {
    setQueue((current) => [...current, track]);
  }, []);

  const setVolume = useCallback(
    (value: number) => {
      // Both elements, so a track that starts from the preloaded one does not jump back to
      // whatever the volume was when it was loaded.
      for (const slot of [0, 1] as PlayerSlot[]) {
        const player = playerAt(slot);
        if (player) player.volume = value;
      }
      setVolumeState(value);
    },
    [playerAt],
  );

  /**
   * Shuffle by asking the hub, not by randomising locally: `POST /v1/shuffle` walks the
   * queue so consecutive tracks sound alike. The hub answers only with hashes it knows, so
   * anything it leaves out is appended rather than dropped — a queue must never lose a
   * track just because the hub has not analyzed it yet.
   */
  const toggleShuffle = useCallback(async () => {
    if (shuffleRef.current) {
      setShuffle(false);
      return;
    }
    setShuffle(true);

    // Read through the ref rather than the closure: the round trip to the hub takes long
    // enough that the queue may have moved on, and reordering a snapshot would put back
    // tracks the listener has since cleared.
    const snapshot = queueRef.current;
    if (snapshot.queue.length < 2) return;

    const hashes = snapshot.queue
      .map((track) => track.content_hash)
      .filter((hash): hash is string => Boolean(hash));
    const startHash =
      snapshot.queue[snapshot.index]?.content_hash ?? undefined;

    try {
      const ordered = await api.shuffle(hashes, startHash);
      const lookup = new Map(
        snapshot.queue.map((track) => [track.content_hash ?? "", track]),
      );
      const known = new Set(ordered);
      const reordered = ordered
        .map((hash) => lookup.get(hash))
        .filter((track): track is CatalogTrack => Boolean(track));
      const missing = snapshot.queue.filter(
        (track) => !known.has(track.content_hash ?? ""),
      );

      setQueue([...reordered, ...missing]);
      setQueueIndex(0);
    } catch {
      // A hub that cannot reorder is not a reason to stop the music; the queue stands.
    }
  }, []);

  /** Seed-track radio: the hub picks what sounds like this one. */
  const startRadio = useCallback(
    async (track: CatalogTrack) => {
      if (!track.content_hash) return;
      try {
        const playlist = await api.radio(track.content_hash);
        const tracks = resolve(playlist.content_hashes, track);
        stationRef.current = {
          seed: track.content_hash,
          // What has been taken from the ranking so far, which is where the next page
          // starts. The seed itself leads the list and is not part of the ranking.
          consumed: Math.max(playlist.content_hashes.length - 1, 0),
          exhausted: false,
        };
        play(tracks.length > 0 ? tracks : [track]);
      } catch {
        stationRef.current = null;
        play([track]);
      }
    },
    [play, resolve],
  );

  const jumpTo = useCallback(
    (index: number) => {
      const track = queueRef.current.queue[index];
      if (!track) return;
      setQueueIndex(index);
      setIsPlaying(true);
      if (!adoptPreloaded(track, qualityRef.current, true)) {
        loadTrack(track, qualityRef.current, true);
      }
      unlock(other(activeSlotRef.current));
    },
    [adoptPreloaded, loadTrack, unlock],
  );

  const clearQueue = useCallback(() => {
    stationRef.current = null;
    for (const player of playersRef.current) player.pause();
    // Forget what was loaded, so queueing the same track again reloads rather than
    // silently resuming where the cleared one left off.
    loadedRef.current = [null, null];
    setQueue([]);
    setQueueIndex(-1);
    setIsPlaying(false);
  }, []);

  const value = useMemo<PlaybackValue>(
    () => ({
      current,
      queue,
      queueIndex,
      isPlaying,
      volume,
      repeat,
      shuffle,
      error,
      play,
      playNow,
      playNext,
      addToQueue,
      toggle,
      next,
      previous,
      seek,
      setVolume,
      setRepeat,
      toggleShuffle,
      startRadio,
      jumpTo,
      clearQueue,
    }),
    [
      current,
      queue,
      queueIndex,
      isPlaying,
      volume,
      repeat,
      shuffle,
      error,
      play,
      playNow,
      playNext,
      addToQueue,
      toggle,
      next,
      previous,
      seek,
      setVolume,
      toggleShuffle,
      startRadio,
      jumpTo,
      clearQueue,
    ],
  );

  const progress = useMemo<PlaybackProgressValue>(
    () => ({ elapsed, duration, isBuffering }),
    [elapsed, duration, isBuffering],
  );

  return (
    <PlaybackContext.Provider value={value}>
      <PlaybackProgressContext.Provider value={progress}>
        {children}
      </PlaybackProgressContext.Provider>
    </PlaybackContext.Provider>
  );
}

export function usePlayback(): PlaybackValue {
  const value = useContext(PlaybackContext);
  if (!value) {
    throw new Error("usePlayback must be used inside a PlaybackProvider");
  }
  return value;
}

/**
 * Position, length, and whether audio is stalled — for the scrubber and the buffering
 * indicator, and nothing else. Reading this subscribes a component to several updates a
 * second, so anything that only needs to know *what* is playing wants `usePlayback`.
 */
export function usePlaybackProgress(): PlaybackProgressValue {
  const value = useContext(PlaybackProgressContext);
  if (!value) {
    throw new Error(
      "usePlaybackProgress must be used inside a PlaybackProvider",
    );
  }
  return value;
}
