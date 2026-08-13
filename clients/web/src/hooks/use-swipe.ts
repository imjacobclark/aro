"use client";

import { useCallback, useRef, useState } from "react";

/**
 * Follow-the-finger drag handling, in the shape the player controls need.
 *
 * Pointer events rather than touch events, because they are the one input model every
 * engine agrees on — the same handlers cover a finger on a phone, a trackpad drag, and a
 * mouse, and there is no separate code path to forget about.
 *
 * The part that makes a gesture feel native rather than merely present is that the thing
 * being dragged moves *with* the finger and settles by itself: `offset` is exposed while a
 * drag is live so the caller can translate its own element, and the decision to commit or
 * spring back is taken on release from distance and speed together. A slow long drag and a
 * quick flick both read as intent, which is how iOS behaves and why a pure distance
 * threshold always feels sticky.
 */
export interface SwipeHandlers {
  onPointerDown: (event: React.PointerEvent) => void;
  onPointerMove: (event: React.PointerEvent) => void;
  onPointerUp: (event: React.PointerEvent) => void;
  onPointerCancel: (event: React.PointerEvent) => void;
}

export interface SwipeState {
  /** Live displacement, or zero when nothing is being dragged. */
  offset: { x: number; y: number };
  dragging: boolean;
  handlers: SwipeHandlers;
}

export function useSwipe({
  onSwipeLeft,
  onSwipeRight,
  onSwipeUp,
  onSwipeDown,
  axis = "both",
  threshold = 60,
  enabled = true,
}: {
  onSwipeLeft?: () => void;
  onSwipeRight?: () => void;
  onSwipeUp?: () => void;
  onSwipeDown?: () => void;
  /** Restricts which way the element may follow the finger. */
  axis?: "x" | "y" | "both";
  threshold?: number;
  enabled?: boolean;
}): SwipeState {
  const start = useRef<{ x: number; y: number; at: number } | null>(null);
  const [offset, setOffset] = useState({ x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);

  const reset = useCallback(() => {
    start.current = null;
    setDragging(false);
    setOffset({ x: 0, y: 0 });
  }, []);

  const onPointerDown = useCallback(
    (event: React.PointerEvent) => {
      if (!enabled) return;
      // Only a real drag input. A mouse wheel or a stylus hover should not arm this.
      if (event.pointerType === "mouse" && event.button !== 0) return;
      // Capture, or the gesture is only recognised when it ends over the element it began
      // on. Pointer events go to whatever is under the finger, and any swipe worth making
      // travels outside a 66px-tall player — so the `pointerup` that decides the gesture
      // landed on whichever track row happened to be there and this never fired at all.
      try {
        event.currentTarget.setPointerCapture(event.pointerId);
      } catch {
        // Capture is best-effort: a browser that refuses it still gets the gesture as long
        // as the finger happens to end where it started.
      }
      start.current = { x: event.clientX, y: event.clientY, at: Date.now() };
      setDragging(true);
    },
    [enabled],
  );

  const onPointerMove = useCallback(
    (event: React.PointerEvent) => {
      const from = start.current;
      if (!from) return;
      const dx = event.clientX - from.x;
      const dy = event.clientY - from.y;

      // Until the gesture has committed to a direction, let the page keep scrolling —
      // stealing every touch would make a list impossible to scroll past the player.
      if (axis === "y" && Math.abs(dx) > Math.abs(dy)) return;
      if (axis === "x" && Math.abs(dy) > Math.abs(dx)) return;

      setOffset({
        x: axis === "y" ? 0 : dx,
        y: axis === "x" ? 0 : dy,
      });
    },
    [axis],
  );

  const onPointerUp = useCallback(
    (event: React.PointerEvent) => {
      try {
        event.currentTarget.releasePointerCapture(event.pointerId);
      } catch {
        // Already released, or never held.
      }
      const from = start.current;
      if (!from) return;
      const dx = event.clientX - from.x;
      const dy = event.clientY - from.y;
      const elapsed = Math.max(Date.now() - from.at, 1);
      // Pixels per second. A flick covers little ground quickly and should still count.
      const speedX = (Math.abs(dx) / elapsed) * 1000;
      const speedY = (Math.abs(dy) / elapsed) * 1000;
      const FLICK = 450;

      const horizontal = Math.abs(dx) > Math.abs(dy);
      if (horizontal && axis !== "y") {
        if (dx < 0 && (Math.abs(dx) > threshold || speedX > FLICK)) onSwipeLeft?.();
        else if (dx > 0 && (Math.abs(dx) > threshold || speedX > FLICK)) onSwipeRight?.();
      } else if (!horizontal && axis !== "x") {
        if (dy < 0 && (Math.abs(dy) > threshold || speedY > FLICK)) onSwipeUp?.();
        else if (dy > 0 && (Math.abs(dy) > threshold || speedY > FLICK)) onSwipeDown?.();
      }
      reset();
    },
    [axis, threshold, onSwipeLeft, onSwipeRight, onSwipeUp, onSwipeDown, reset],
  );

  return {
    offset,
    dragging,
    handlers: {
      onPointerDown,
      onPointerMove,
      onPointerUp,
      onPointerCancel: reset,
    },
  };
}
