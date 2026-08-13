/**
 * Wire types for the hub's sync API, mirroring `aro-sync-protocol` on the Rust side.
 *
 * Hand-written rather than generated: `server/openapi/aro-sync-v2.json` is the reference,
 * but only the slice this client actually reads is worth carrying, and a hand-written type
 * can say *why* a field is optional in a way a generator cannot.
 */

/** One track as the hub's catalogue reports it — `aro_sync_protocol::CatalogTrack`. */
export interface CatalogTrack {
  track_id: string;
  source_id?: string | null;
  source_name?: string | null;
  /** Absent only for a record whose file the hub has never seen; such a track cannot play. */
  content_hash: string | null;
  title: string;
  artist: string | null;
  album: string | null;
  genre: string | null;
  release_year: number | null;
  duration_seconds: number | null;
  byte_count: number | null;
  codec: string | null;
  sample_rate: number | null;
  bit_depth: number | null;
  channel_count: number | null;
  bitrate: number | null;
  integrated_lufs: number | null;
  peak_amplitude: number | null;
  loudness_analyzed_at: number | null;
  loudness_algorithm_version: number | null;
  track_number: number | null;
  disc_number: number | null;
  /** Blob hash of the cover, if the hub has one — fetch it from `/api/artwork/{hash}`. */
  artwork_hash: string | null;
  favourite: boolean;
  /** False when the hub knows the track but cannot currently reach its bytes. */
  available: boolean;
}

export interface CatalogPage {
  tracks: CatalogTrack[];
  next_cursor: string | null;
  /** Bumps whenever the library changes; the client caches a whole catalogue against it. */
  revision: number;
}

/**
 * A hub-generated playlist — `aro_server::playlists::GeneratedPlaylist`.
 *
 * Note there is no artwork field: a playlist is a list of content hashes and nothing more,
 * so its cover is whichever of its tracks the client resolves first. That is deliberate on
 * the hub's side — it means a playlist costs nothing to generate and never goes stale
 * against artwork that changed.
 */
export interface GeneratedPlaylist {
  /** Stable slug (`"heavy-rotation"`, `"mood-relaxed"`), usable as a view identity. */
  id: string;
  title: string;
  subtitle: string;
  kind: PlaylistKind;
  /** Content hashes, not track ids: the only identifier clients and the hub share. */
  content_hashes: string[];
  /** Seconds since epoch of the most recent play among these tracks, if any. */
  last_played_at?: number | null;
}

/**
 * `aro_server::playlists::PlaylistKind`, serialized snake_case. Widened with `string`
 * on purpose: a hub newer than this client will send kinds it has never heard of, and
 * those should still render and play rather than disappear — the macOS client decodes
 * them leniently for the same reason.
 */
export type PlaylistKind =
  | "for_you"
  | "recently_played_track"
  | "recently_played_album"
  | "mood"
  | "artist_mix"
  | "favourite_artist"
  | "hits_by_year"
  | "replay_month"
  | "replay_all_time"
  | "time_capsule"
  | (string & {});

export interface HubInfo {
  hub_id: string;
  display_name: string;
  library_name?: string | null;
  version?: string | null;
  identification_available?: boolean;
}

/** The shape of `HubStore::dashboard_stats()`, served at `/v1/library/stats`. */
/**
 * The hub's own numbers, exactly as `dashboard_stats` reports them.
 *
 * Named to match the wire, which sounds obvious and was not: this described a shape nobody
 * sends — `total_plays` for `logged_plays`, `most_played_tracks` for `top_tracks`, fidelity
 * counts hanging off `library` rather than `fidelity` — and because every field was
 * optional, TypeScript was satisfied and the Stats screen quietly rendered almost nothing.
 * The whole Listening section was gated behind a field that never existed, so it never
 * appeared at all. Anything added here should be checked against a real response.
 */
export interface LibraryStats {
  generated_at?: string;
  scope?: string;
  library?: {
    track_count?: number;
    album_count?: number;
    artist_count?: number;
    /** Seconds. */
    total_duration?: number;
    file_size_bytes?: number;
    formats?: Breakdown[];
    genres?: Breakdown[];
    decades?: Breakdown[];
    /** Keyed by rate in Hz, e.g. `{ "44100": 417 }`. */
    sample_rates?: Record<string, number>;
    /** Keyed by depth in bits. Lossy files have none, so these need not sum to the total. */
    bit_depths?: Record<string, number>;
  };
  fidelity?: {
    lossless_tracks?: number;
    lossless_bytes?: number;
    lossless_fraction?: number;
    lossy_tracks?: number;
    high_resolution_tracks?: number;
    mean_lossy_bitrate?: number;
    dynamic_range?: {
      analyzed_tracks?: number;
      mean_crest_db?: number;
      min_crest_db?: number;
      max_crest_db?: number;
    };
  };
  listening?: {
    logged_plays?: number;
    unique_tracks_played?: number;
    total_seconds?: number;
    last_30_days_seconds?: number;
    current_streak?: number;
    top_tracks?: PlayCount[];
    top_artists?: PlayCount[];
    recent?: PlayCount[];
    /** One entry per day for the last 30. `date` is an ISO instant at midnight UTC. */
    daily?: { date?: string; seconds?: number }[];
  };
  metadata?: {
    title_coverage?: number;
    artist_coverage?: number;
    album_coverage?: number;
  };
  live?: {
    active_listeners?: number;
    connected_devices?: number;
  };
  sources?: {
    total?: number;
    unavailable?: number;
  };
}

export interface Breakdown {
  name?: string;
  track_count?: number;
  file_size_bytes?: number;
}

export interface PlayCount {
  id?: string;
  title?: string;
  /** "Artist — Album" for a track, or "12 songs" for an artist. The hub composes it. */
  subtitle?: string;
  play_count?: number;
  played_at?: string;
}

export interface SourceHealth {
  source_id: string;
  name: string;
  mode: string;
  available: boolean;
  track_count?: number;
  missing_count?: number;
  /** The machine the folder belongs to, so an unreachable one can say whose it is. */
  device_name?: string | null;
}

export interface HubDevice {
  device_id: string;
  name?: string | null;
  platform?: string | null;
  last_seen_at?: string | null;
  can_contribute?: boolean;
}

export interface WatchedFolder {
  source_id: string;
  path: string;
  name?: string | null;
  available?: boolean;
  track_count?: number;
}

export interface ArtworkCandidate {
  url: string;
  thumbnail_url?: string | null;
  source?: string | null;
  width?: number | null;
  height?: number | null;
  title?: string | null;
  artist?: string | null;
}

export interface SyncJob {
  id: string;
  kind: string;
  total: number;
  completed: number;
  state: "running" | "completed" | "failed" | "cancelled" | string;
  error?: string | null;
}

/** `aro_track_id::GroupSummary` — identification works a folder at a time. */
export interface IdentificationGroupSummary {
  folder: string;
  member_count: number;
  accepted: boolean;
  release_title?: string | null;
}

/**
 * `aro_track_id::QueueStatus`. Note `in_flight` is a *boolean* — whether a worker is
 * running right now, not a count of anything. Typing it as a number rendered it as a
 * blank stat, because `false ?? 0` is `false` and React draws nothing for that.
 */
export interface IdentificationQueueStatus {
  queued?: number;
  in_flight?: boolean;
  processed?: number;
  failed?: number;
  last_error?: string | null;
  groups_queued?: number;
  last_group?: IdentificationGroupSummary | null;
}

/** `aro_sync_protocol::PlaybackActivitySnapshot`. */
export interface PlaybackActivitySnapshot {
  session_id: string;
  revision: number;
  content_hash: string;
  state: "playing" | "buffering" | "stopped";
  position_seconds: number;
  duration_seconds: number | null;
  buffered_fraction: number | null;
  observed_at: string;
  started_at: string;
  completed: boolean;
  output?: {
    route_name?: string | null;
    playback_mode?: string | null;
    sample_rate?: number | null;
    bit_depth?: number | null;
    exclusive?: boolean | null;
  } | null;
}

/**
 * Stream qualities the hub's transcoder understands — `aro_track_id::transcode::StreamQuality`.
 * Everything but `original` is Ogg/Opus at a fixed bitrate: high 192k, balanced 128k,
 * saver 96k, minimum 64k.
 */
export type StreamQuality =
  | "original"
  | "high"
  | "balanced"
  | "saver"
  | "minimum";

export const STREAM_QUALITIES: {
  value: StreamQuality;
  label: string;
  detail: string;
}[] = [
  {
    value: "original",
    label: "Original",
    detail: "Exactly the file the hub holds",
  },
  { value: "high", label: "High", detail: "Opus, 192 kbps" },
  { value: "balanced", label: "Balanced", detail: "Opus, 128 kbps" },
  { value: "saver", label: "Data Saver", detail: "Opus, 96 kbps" },
  { value: "minimum", label: "Minimum", detail: "Opus, 64 kbps" },
];

/**
 * How Aro's value for one field compares with the file's own tag —
 * `aro_server::metadata_delta::FieldVerdict`.
 */
export type FieldVerdict =
  | "agrees"
  | "differs"
  | "missing_in_file"
  | "missing_in_aro"
  | "absent";

export interface FieldDelta {
  field: string;
  aro: string | null;
  file: string | null;
  verdict: FieldVerdict;
}

/**
 * Where a track's audio actually is. Three states rather than a boolean because they mean
 * different things: Aro holding a copy keeps the track playable, while only a reachable
 * *original* can have corrected tags written into it.
 */
export type TrackAvailability =
  | "original_and_copy"
  | "original_only"
  | "copy_only"
  | "missing";

/** `aro_server::metadata_delta::TrackDelta`. */
export interface TrackDelta {
  content_hash: string;
  track_id: string;
  title: string | null;
  artist: string | null;
  album: string | null;
  availability: TrackAvailability;
  /** Already encodes the availability rule — only a reachable original can be written. */
  writable: boolean;
  original_path: string | null;
  fields: FieldDelta[];
  /** Fields differing or missing on one side; zero means there is nothing to act on. */
  difference_count: number;
}

export interface WriteBackOutcome {
  content_hash: string;
  /** The hash after writing — a file's identity changes with its bytes. */
  new_content_hash: string | null;
  written: boolean;
  error: string | null;
}

/** `aro_server::library_health` — where a library has gone untidy. */
export type HealthRecommendationKind =
  | "exact_duplicate"
  | "alternate_encoding"
  | "moved"
  | "missing"
  | "fragmented_folder";

export interface HealthCopy {
  track_id: string;
  path: string;
  available: boolean;
  codec: string;
  sample_rate: number | null;
  bit_depth: number | null;
  bitrate: number | null;
  file_size_bytes: number;
}

export interface HealthRecommendation {
  id: string;
  kind: HealthRecommendationKind;
  title: string;
  artist: string;
  reason: string;
  copies: HealthCopy[];
  /** The copy worth keeping, where one is clearly better. */
  preferred_copy_id: string | null;
  potential_savings_bytes: number;
}

export interface HealthReport {
  exact_duplicates: HealthRecommendation[];
  alternate_encodings: HealthRecommendation[];
  moved_files: HealthRecommendation[];
  missing_files: HealthRecommendation[];
  fragmented_folders: HealthRecommendation[];
  recommendation_count: number;
  /** Only exact duplicates count: an alternate encoding is a judgement call, not a saving. */
  exact_reclaimable_bytes: number;
}

/**
 * What converting the library for cross-device compatibility would cost, and what it has
 * cost so far — see the hub's `compatibility_plan`.
 */
export interface CompatibilityPlan {
  tracks_already_compatible: number;
  tracks_pending: number;
  tracks_converted: number;
  pending_audio_seconds: number;
  estimated_seconds: number;
  estimated_bytes: number;
  used_bytes: number;
}
