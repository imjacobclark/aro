"use client";

import { useEffect, useRef, useState } from "react";

/**
 * Renders only the rows near the viewport.
 *
 * A library of ten thousand tracks is ten thousand DOM nodes if rendered naively, which a
 * phone will not scroll smoothly and may not survive at all. The macOS app reaches for
 * `NSTableView` for the same reason; this is the browser's equivalent, kept deliberately
 * small — fixed-height rows and a window of them, with no dependency to carry.
 */
export function VirtualList<T>({
  items,
  estimatedItemHeight,
  renderItem,
  getKey,
  overscan = 8,
}: {
  items: T[];
  estimatedItemHeight: number;
  renderItem: (item: T, index: number) => React.ReactNode;
  getKey: (item: T, index: number) => string;
  overscan?: number;
}) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [range, setRange] = useState({ start: 0, end: 40 });

  useEffect(() => {
    const element = containerRef.current;
    if (!element) return;

    const update = () => {
      // The list scrolls with the page rather than in its own box, so the visible window
      // is measured from where the container sits relative to the viewport.
      const top = element.getBoundingClientRect().top;
      const first = Math.floor(Math.max(-top, 0) / estimatedItemHeight);
      const visible = Math.ceil(window.innerHeight / estimatedItemHeight);

      setRange({
        start: Math.max(first - overscan, 0),
        end: Math.min(first + visible + overscan, items.length),
      });
    };

    update();
    window.addEventListener("scroll", update, { passive: true });
    window.addEventListener("resize", update);
    return () => {
      window.removeEventListener("scroll", update);
      window.removeEventListener("resize", update);
    };
  }, [items.length, estimatedItemHeight, overscan]);

  const visible = items.slice(range.start, range.end);

  return (
    <div
      ref={containerRef}
      style={{ height: items.length * estimatedItemHeight }}
      className="relative"
    >
      <div
        style={{
          transform: `translateY(${range.start * estimatedItemHeight}px)`,
        }}
      >
        {visible.map((item, index) => (
          <div
            key={getKey(item, range.start + index)}
            style={{ height: estimatedItemHeight }}
          >
            {renderItem(item, range.start + index)}
          </div>
        ))}
      </div>
    </div>
  );
}
