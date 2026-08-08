import { api } from "@/lib/hub/api";
import { randomUUID } from "@/lib/uuid";
import type { PlaybackActivitySnapshot } from "@/lib/hub/types";

/**
 * Tells the hub what this browser is playing.
 *
 * This is not telemetry — it is the input to everything Home shows. The hub builds its
 * playlists, its "Jump Back In", and its listening statistics from these snapshots, so a
 * track played on a phone has to count exactly as much as one played on the Mac. Without
 * this, the web client would consume the hub's intelligence while contributing nothing to
 * it, and a listener who mostly uses their phone would watch Home slowly stop describing
 * them.
 */
export class ActivityReporter {
  private sessionId = randomUUID();
  private revision = 0;
  private startedAt = new Date().toISOString();
  private currentHash: string | null = null;
  private enabled = true;

  setEnabled(enabled: boolean) {
    this.enabled = enabled;
  }

  /** A new track starts a new session, which is what the hub counts as one listen. */
  beginTrack(contentHash: string) {
    if (contentHash === this.currentHash) return;
    this.currentHash = contentHash;
    this.sessionId = randomUUID();
    this.revision = 0;
    this.startedAt = new Date().toISOString();
  }

  report(snapshot: {
    contentHash: string;
    state: "playing" | "buffering" | "stopped";
    positionSeconds: number;
    durationSeconds: number | null;
    bufferedFraction: number | null;
    completed: boolean;
  }) {
    if (!this.enabled) return;

    const payload: PlaybackActivitySnapshot = {
      session_id: this.sessionId,
      revision: ++this.revision,
      content_hash: snapshot.contentHash,
      state: snapshot.state,
      position_seconds: snapshot.positionSeconds,
      duration_seconds: snapshot.durationSeconds,
      buffered_fraction: snapshot.bufferedFraction,
      observed_at: new Date().toISOString(),
      started_at: this.startedAt,
      completed: snapshot.completed,
      output: {
        route_name: "Web",
        playback_mode: "browser",
      },
    };

    // Fire and forget: a snapshot that fails to land is a lost data point, never a reason
    // to interrupt what someone is listening to.
    void api.reportActivity(payload).catch(() => {});
  }
}
