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

import { api, artworkUrl, streamUrl } from "@/lib/hub/api";
import type { CatalogTrack, StreamQuality } from "@/lib/hub/types";
import { useSettings } from "@/lib/settings";
import { ActivityReporter } from "./activity";
import {
  effectiveQuality,
  isUndecodable,
  rememberUndecodable,
} from "./support";

export type RepeatMode = "off" | "all" | "one";

interface PlaybackValue {
  current: CatalogTrack | null;
  queue: CatalogTrack[];
  queueIndex: number;
  isPlaying: boolean;
  isBuffering: boolean;
  elapsed: number;
  duration: number;
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

const PlaybackContext = createContext<PlaybackValue | null>(null);

/** Below this many seconds in, "previous" means the previous track rather than a restart. */
const RESTART_THRESHOLD_SECONDS = 3;

export function PlaybackProvider({ children }: { children: React.ReactNode }) {
  const settings = useSettings();
  const audioRef = useRef<HTMLAudioElement | null>(null);

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
  const shuffleRef = useRef(shuffle);
  const repeatRef = useRef(repeat);
  const isPlayingRef = useRef(isPlaying);
  const qualityRef = useRef(settings.quality);
  /** The source currently loaded into the element, so a reload can be skipped. */
  const loadedRef = useRef<string | null>(null);

  useEffect(() => {
    queueRef.current = { queue, index: queueIndex };
    shuffleRef.current = shuffle;
    repeatRef.current = repeat;
    isPlayingRef.current = isPlaying;
    qualityRef.current = settings.quality;
  }, [queue, queueIndex, shuffle, repeat, isPlaying, settings.quality]);

  // One reporter for the app's lifetime: it owns the session id that ties a listen
  // together, so recreating it per render would split every play into fragments.
  const [reporter] = useState(() => new ActivityReporter());
  const reporterRef = useRef(reporter);

  useEffect(() => {
    reporter.setEnabled(settings.reportListening);
  }, [reporter, settings.reportListening]);

  // One element for the whole app's life. Recreating it per track would drop the user
  // gesture that unlocked audio on iOS, and playback would silently stop working.
  useEffect(() => {
    const audio = new Audio();
    audio.preload = "auto";
    audioRef.current = audio;
    return () => {
      audio.pause();
      audio.src = "";
      audioRef.current = null;
    };
  }, []);

  /**
   * Points the element at a track and, if asked, starts it.
   *
   * Deliberately callable straight from a click handler rather than only from an effect:
   * iOS honours `play()` only when it happens synchronously inside the gesture that caused
   * it, and an effect runs a render later, by which point the browser has forgotten a
   * human was involved. Every tap therefore loads and starts here, and the effect below
   * only covers the cases nobody tapped for — a track ending, or the quality changing
   * mid-listen.
   */
  const loadTrack = useCallback(
    (track: CatalogTrack, quality: StreamQuality, start: boolean) => {
      const audio = audioRef.current;
      if (!audio || !track.content_hash) return;

      // Not necessarily the quality the listener picked: a browser that cannot decode this
      // format gets the hub's transcode instead of silence. See `lib/playback/support`.
      const resolved = effectiveQuality(track, quality);
      const source = streamUrl(track, resolved);
      if (loadedRef.current !== source) {
        loadedRef.current = source;
        audio.src = source;
        audio.load();
        setElapsed(0);
        setDuration(track.duration_seconds ?? 0);
        reporterRef.current.beginTrack(track.content_hash);
      }

      if (start) {
        void audio.play().catch((cause: DOMException) => {
          // Autoplay refusal is browser policy, not a failure: the next tap starts it.
          if (cause.name !== "NotAllowedError") {
            setError(`This track could not be played: ${cause.message}`);
          }
          setIsPlaying(false);
        });
      }
    },
    [],
  );

  /**
   * Moves to another position in the queue and, unless told otherwise, starts it.
   *
   * Starting is explicit here rather than inferred from `isPlaying`, and that is the whole
   * point: when a track reaches its end the browser fires `pause` *before* `ended`, so by
   * the time the queue advances, `isPlaying` has already been set false by the element
   * itself. Reading it would mean every track loaded the next one and then sat there in
   * silence. Playing outside a user gesture is allowed because the element was unlocked by
   * the tap that began the queue and has not been replaced since.
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
      loadTrack(track, qualityRef.current, start);
      return true;
    },
    [loadTrack],
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
    const audio = audioRef.current;
    const position = audio?.currentTime ?? 0;
    const wasPlaying = isPlayingRef.current;

    loadTrack(current, settings.quality, wasPlaying);
    if (audio && position > 0) audio.currentTime = position;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settings.quality]);

  useEffect(() => {
    const audio = audioRef.current;
    if (!audio) return;

    const onTime = () => setElapsed(audio.currentTime);
    const onDuration = () => {
      if (Number.isFinite(audio.duration)) setDuration(audio.duration);
    };
    const onPlay = () => {
      setIsPlaying(true);
      setError(null);
    };
    const onPause = () => {
      // Reaching the end of a track pauses the element and fires this *before* `ended`.
      // Treating that as "the listener stopped" is what used to strand the queue, so a
      // pause at the very end is left for `onEnded` to interpret.
      if (!audio.ended) setIsPlaying(false);
    };
    const onWaiting = () => setIsBuffering(true);
    const onPlaying = () => setIsBuffering(false);
    const onEnded = () => {
      const finished = queueRef.current.queue[queueRef.current.index];
      if (finished?.content_hash) {
        reporterRef.current.report({
          contentHash: finished.content_hash,
          state: "stopped",
          positionSeconds: audio.currentTime,
          durationSeconds: Number.isFinite(audio.duration)
            ? audio.duration
            : null,
          bufferedFraction: 1,
          completed: true,
        });
      }

      if (repeatRef.current === "one") {
        audio.currentTime = 0;
        void audio.play();
        return;
      }
      advance(1);
    };
    const onError = () => {
      setIsBuffering(false);

      const track = queueRef.current.queue[queueRef.current.index];
      const unsupported =
        audio.error?.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED;

      // A format this browser cannot decode is not a broken track — it is a track that has
      // to arrive re-encoded. Remember the format so every later track of the same kind
      // goes straight to the transcode, and retry this one where the listener left off.
      if (unsupported && track && !isUndecodable(track)) {
        rememberUndecodable(track);
        const position = audio.currentTime;
        loadedRef.current = null;
        loadTrack(track, qualityRef.current, isPlayingRef.current);
        if (position > 0) audio.currentTime = position;
        return;
      }

      setError(
        unsupported
          ? "This browser cannot play this track, even re-encoded."
          : "This track could not be played.",
      );
    };

    audio.addEventListener("timeupdate", onTime);
    audio.addEventListener("loadedmetadata", onDuration);
    audio.addEventListener("durationchange", onDuration);
    audio.addEventListener("play", onPlay);
    audio.addEventListener("pause", onPause);
    audio.addEventListener("waiting", onWaiting);
    audio.addEventListener("playing", onPlaying);
    audio.addEventListener("ended", onEnded);
    audio.addEventListener("error", onError);

    return () => {
      audio.removeEventListener("timeupdate", onTime);
      audio.removeEventListener("loadedmetadata", onDuration);
      audio.removeEventListener("durationchange", onDuration);
      audio.removeEventListener("play", onPlay);
      audio.removeEventListener("pause", onPause);
      audio.removeEventListener("waiting", onWaiting);
      audio.removeEventListener("playing", onPlaying);
      audio.removeEventListener("ended", onEnded);
      audio.removeEventListener("error", onError);
    };
  }, [advance, loadTrack]);

  // Periodic progress, so a long track still counts as listened-to if the app is closed
  // before it ends.
  useEffect(() => {
    if (!isPlaying || !current?.content_hash) return;
    const hash = current.content_hash;

    const send = (state: "playing" | "stopped", completed = false) => {
      const audio = audioRef.current;
      if (!audio) return;
      const buffered =
        audio.buffered.length > 0 && audio.duration
          ? audio.buffered.end(audio.buffered.length - 1) / audio.duration
          : null;
      reporter.report({
        contentHash: hash,
        state,
        positionSeconds: audio.currentTime,
        durationSeconds: Number.isFinite(audio.duration) ? audio.duration : null,
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
  }, [isPlaying, current?.content_hash, reporter]);

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
    const audio = audioRef.current;
    if (!audio || !current) return;
    if (audio.paused) {
      void audio.play().catch(() => setIsPlaying(false));
    } else {
      audio.pause();
    }
  }, [current]);

  const seek = useCallback((seconds: number) => {
    const audio = audioRef.current;
    if (!audio) return;
    audio.currentTime = seconds;
    setElapsed(seconds);
  }, []);

  const next = useCallback(() => advance(1), [advance]);

  const previous = useCallback(() => {
    const audio = audioRef.current;
    // Part-way into a track, "previous" means "start this one again" — the convention
    // every music player shares, and the macOS transport's behaviour too.
    if (audio && audio.currentTime > RESTART_THRESHOLD_SECONDS) {
      audio.currentTime = 0;
      return;
    }
    advance(-1);
  }, [advance]);

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
      setQueue(playable);
      setQueueIndex(index);
      setIsPlaying(true);
      // Before the state update, not after: this call is still inside the tap.
      loadTrack(playable[index], qualityRef.current, true);
    },
    [loadTrack],
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

  const setVolume = useCallback((value: number) => {
    const audio = audioRef.current;
    if (audio) audio.volume = value;
    setVolumeState(value);
  }, []);

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
        const lookup = new Map(queue.map((item) => [item.content_hash ?? "", item]));
        lookup.set(track.content_hash, track);
        const tracks = playlist.content_hashes
          .map((hash) => lookup.get(hash))
          .filter((item): item is CatalogTrack => Boolean(item));
        play(tracks.length > 0 ? tracks : [track]);
      } catch {
        play([track]);
      }
    },
    [play, queue],
  );

  const jumpTo = useCallback(
    (index: number) => {
      const track = queueRef.current.queue[index];
      if (!track) return;
      setQueueIndex(index);
      setIsPlaying(true);
      loadTrack(track, qualityRef.current, true);
    },
    [loadTrack],
  );

  const clearQueue = useCallback(() => {
    audioRef.current?.pause();
    // Forget what was loaded, so queueing the same track again reloads rather than
    // silently resuming where the cleared one left off.
    loadedRef.current = null;
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
      isBuffering,
      elapsed,
      duration,
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
      isBuffering,
      elapsed,
      duration,
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

  return (
    <PlaybackContext.Provider value={value}>{children}</PlaybackContext.Provider>
  );
}

export function usePlayback(): PlaybackValue {
  const value = useContext(PlaybackContext);
  if (!value) {
    throw new Error("usePlayback must be used inside a PlaybackProvider");
  }
  return value;
}
