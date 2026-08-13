"use client";

import Link from "next/link";
import { ChevronLeft } from "lucide-react";

import { cn } from "@/lib/utils";

/**
 * The page frame every screen shares: a large title, an optional subtitle, and a scroll
 * area that clears the player. The macOS app gives every destination the same treatment
 * (title, `ScrollView`, periodic refresh), and keeping that consistent is most of why the
 * two clients feel like one product.
 */
export function PageShell({
  title,
  subtitle,
  actions,
  backHref,
  children,
  className,
}: {
  title: string;
  subtitle?: string;
  actions?: React.ReactNode;
  backHref?: string;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    // `viewport-fit=cover` plus `black-translucent` means iOS draws the status bar *over*
    // this content when the app is on a home screen, so the title has to move down out of
    // its way. Every other fixed edge in this app already pays `safe-area-inset-bottom`;
    // the top was simply never claimed, and the clock sat on top of the page title. `max`
    // rather than a sum so a desktop browser, where the inset is 0, keeps its original
    // spacing rather than losing it.
    <div
      className={cn(
        "mx-auto w-full max-w-5xl px-4 pt-[max(0.75rem,env(safe-area-inset-top))]",
        className,
      )}
    >
      <header className="flex items-start gap-3 py-3">
        {backHref ? (
          <Link
            href={backHref}
            aria-label="Back"
            className="text-muted-foreground hover:text-foreground -ml-2 mt-1 rounded-lg p-2"
          >
            <ChevronLeft className="size-6" />
          </Link>
        ) : null}
        <div className="min-w-0 flex-1">
          <h1 className="truncate text-[1.75rem] leading-tight font-bold tracking-tight">
            {title}
          </h1>
          {subtitle ? (
            <p className="text-muted-foreground mt-1 truncate text-sm">
              {subtitle}
            </p>
          ) : null}
        </div>
        {actions ? (
          <div className="flex shrink-0 items-center gap-2 pt-1">{actions}</div>
        ) : null}
      </header>
      {children}
    </div>
  );
}

export function SectionHeader({
  title,
  subtitle,
  action,
}: {
  title: string;
  subtitle?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex items-end justify-between gap-3 px-1 pb-3">
      <div className="min-w-0">
        <h2 className="truncate text-lg font-semibold tracking-tight">
          {title}
        </h2>
        {subtitle ? (
          <p className="text-muted-foreground truncate text-xs">{subtitle}</p>
        ) : null}
      </div>
      {action}
    </div>
  );
}

/** A horizontal rail. Snapping makes it feel like a native carousel under a thumb. */
export function Carousel({ children }: { children: React.ReactNode }) {
  return (
    <div className="hide-scrollbar -mx-4 flex snap-x snap-mandatory gap-3 overflow-x-auto px-4 pb-1">
      {children}
    </div>
  );
}
