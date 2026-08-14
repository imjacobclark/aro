"use client";

/**
 * The slow drift over a generated mix's cover.
 *
 * Apple's trick with Made For You is that the *presentation* is a persistent editorial
 * identity while the songs underneath change constantly. The motion belongs to the kind of
 * mix, not to whatever happens to be in it today — which is why it can sit over a cover
 * borrowed from the first track and still feel like the mix's own artwork rather than that
 * track's.
 *
 * Their published motion rules are the constraints worth keeping:
 *
 * - **It starts from the static cover.** This is an overlay, and every layer begins at the
 *   position it holds at rest, so there is no jump when the animation starts and nothing to
 *   wait for before the shelf looks right.
 * - **The loop closes.** Every keyframe set ends exactly where it began, so there is no
 *   seam to notice on repeat.
 * - **Movement is atmospheric, not narrative.** Colour fields drift across tens of seconds.
 *   Nothing enters, exits, flashes, or asks to be watched.
 * - **The words stay put.** The title and the play button are above this and never move;
 *   the drift is confined to the artwork behind the existing scrim.
 *
 * A still cover is the correct fallback, so `prefers-reduced-motion` stops the drift rather
 * than replacing it with something else — the layers simply hold their opening position.
 */
export function MixMotion({ playing = false }: { playing?: boolean }) {
  return (
    <div
      aria-hidden
      className="pointer-events-none absolute inset-0 overflow-hidden rounded-2xl mix-blend-soft-light"
    >
      {/* Three fields at different periods and directions. Coprime-ish durations mean the
          combination takes far longer to visibly repeat than any single layer does. */}
      <span className="aro-mix-drift aro-mix-drift-a" />
      <span className="aro-mix-drift aro-mix-drift-b" />
      <span className="aro-mix-drift aro-mix-drift-c" />
      {/* A sheen that only runs while this mix is the one playing, so the shelf shows at a
          glance which cover is live without adding a badge to read. */}
      {playing ? <span className="aro-mix-sheen" /> : null}
    </div>
  );
}
