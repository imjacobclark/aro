"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useSyncExternalStore,
} from "react";

import type { StreamQuality } from "@/lib/hub/types";

export type ThemePreference = "system" | "light" | "dark";

export interface Settings {
  quality: StreamQuality;
  theme: ThemePreference;
  /** Whether to tell the hub what is playing, so Home's playlists learn from this device. */
  reportListening: boolean;
}

const DEFAULTS: Settings = {
  // Original, not Opus: every format the hub holds — FLAC, ALAC, MP3, AAC — decodes
  // natively in Safari and Chrome, while Ogg/Opus support is the less certain of the two.
  // Data Saver is a choice a listener makes, not one made for them.
  quality: "original",
  theme: "system",
  reportListening: true,
};

const STORAGE_KEY = "aro.settings";

/**
 * Preferences live in `localStorage`, which is an external store React has to be
 * subscribed to rather than copied from: reading it into state inside an effect would
 * render the defaults first and the real values a frame later, and on a prerendered page
 * that difference is a hydration mismatch. `useSyncExternalStore` exists for exactly this
 * shape — a server snapshot of the defaults, a client snapshot of what was saved.
 */
const listeners = new Set<() => void>();

/** Cached so `getSnapshot` returns a referentially stable value between changes. */
let snapshot: Settings = DEFAULTS;
let parsedFor: string | null = null;

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  // Another tab changing a preference should be honoured here too.
  window.addEventListener("storage", listener);
  return () => {
    listeners.delete(listener);
    window.removeEventListener("storage", listener);
  };
}

function getSnapshot(): Settings {
  let raw: string | null = null;
  try {
    raw = window.localStorage.getItem(STORAGE_KEY);
  } catch {
    // Private browsing, or storage disabled: the defaults apply for this session.
  }

  if (raw !== parsedFor) {
    parsedFor = raw;
    try {
      snapshot = raw ? { ...DEFAULTS, ...JSON.parse(raw) } : DEFAULTS;
    } catch {
      snapshot = DEFAULTS;
    }
  }
  return snapshot;
}

function getServerSnapshot(): Settings {
  return DEFAULTS;
}

interface SettingsValue extends Settings {
  update: (changes: Partial<Settings>) => void;
}

const SettingsContext = createContext<SettingsValue | null>(null);

export function SettingsProvider({ children }: { children: React.ReactNode }) {
  const settings = useSyncExternalStore(
    subscribe,
    getSnapshot,
    getServerSnapshot,
  );

  const update = useCallback((changes: Partial<Settings>) => {
    const next = { ...getSnapshot(), ...changes };
    try {
      window.localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
    } catch {
      // Nothing persisted, but the in-memory snapshot below still applies this session.
    }
    snapshot = next;
    parsedFor = JSON.stringify(next);
    for (const listener of listeners) listener();
  }, []);

  // The theme class lives on <html> so it survives navigation; an inline script in the
  // document head sets it before first paint, and this keeps it in step afterwards.
  useEffect(() => {
    const root = document.documentElement;
    const media = window.matchMedia("(prefers-color-scheme: dark)");

    const apply = () => {
      const dark =
        settings.theme === "dark" ||
        (settings.theme === "system" && media.matches);
      root.classList.toggle("dark", dark);
      document
        .querySelector('meta[name="theme-color"]')
        ?.setAttribute("content", dark ? "#181717" : "#faf9f6");
    };

    apply();
    media.addEventListener("change", apply);
    return () => media.removeEventListener("change", apply);
  }, [settings.theme]);

  const value = useMemo(() => ({ ...settings, update }), [settings, update]);

  return (
    <SettingsContext.Provider value={value}>
      {children}
    </SettingsContext.Provider>
  );
}

export function useSettings(): SettingsValue {
  const value = useContext(SettingsContext);
  if (!value) {
    throw new Error("useSettings must be used inside a SettingsProvider");
  }
  return value;
}
