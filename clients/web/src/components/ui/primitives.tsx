"use client";

import * as React from "react";
import { Slider as SliderPrimitive, Switch as SwitchPrimitive } from "radix-ui";

import { cn } from "@/lib/utils";

/**
 * The handful of shadcn-shaped primitives this app needs, kept in one file rather than one
 * per component: each is small, and they are always read together.
 */

export function Card({
  className,
  ...props
}: React.ComponentProps<"div">) {
  return (
    <div
      className={cn(
        "bg-card text-card-foreground border-hairline rounded-2xl border",
        className,
      )}
      {...props}
    />
  );
}

export function Input({ className, ...props }: React.ComponentProps<"input">) {
  return (
    <input
      className={cn(
        "border-input bg-background placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-ring/40 h-11 w-full rounded-xl border px-3.5 text-base outline-none transition focus-visible:ring-3 disabled:opacity-50",
        className,
      )}
      {...props}
    />
  );
}

export function Label({ className, ...props }: React.ComponentProps<"label">) {
  return (
    <label
      className={cn("text-sm leading-none font-medium", className)}
      {...props}
    />
  );
}

export function Badge({
  className,
  tone = "muted",
  ...props
}: React.ComponentProps<"span"> & { tone?: "muted" | "accent" | "hires" }) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-2 py-0.5 text-[0.65rem] font-semibold tracking-wide uppercase",
        tone === "muted" && "bg-muted text-muted-foreground",
        tone === "accent" && "bg-primary/12 text-primary",
        // High resolution earns the brand gradient: it is the one badge worth noticing.
        tone === "hires" && "orbit-surface",
        className,
      )}
      {...props}
    />
  );
}

export function Separator({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      role="separator"
      className={cn("bg-hairline h-px w-full", className)}
      {...props}
    />
  );
}

export function Skeleton({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      className={cn("bg-muted animate-pulse rounded-xl", className)}
      {...props}
    />
  );
}

export function Slider({
  className,
  ...props
}: React.ComponentProps<typeof SliderPrimitive.Root>) {
  return (
    <SliderPrimitive.Root
      className={cn(
        "relative flex w-full touch-none items-center select-none",
        className,
      )}
      {...props}
    >
      <SliderPrimitive.Track className="bg-muted relative h-1.5 w-full grow overflow-hidden rounded-full">
        {/* The filled portion carries the orbit gradient — the same violet→coral→amber the
            macOS scrubber uses. */}
        <SliderPrimitive.Range className="orbit-surface absolute h-full" />
      </SliderPrimitive.Track>
      <SliderPrimitive.Thumb className="border-background bg-foreground focus-visible:ring-ring/50 block size-4 rounded-full border-2 shadow-md transition focus-visible:ring-4 focus-visible:outline-none" />
    </SliderPrimitive.Root>
  );
}

export function Switch({
  className,
  ...props
}: React.ComponentProps<typeof SwitchPrimitive.Root>) {
  return (
    <SwitchPrimitive.Root
      className={cn(
        "data-[state=checked]:bg-primary data-[state=unchecked]:bg-muted focus-visible:ring-ring/50 inline-flex h-7 w-12 shrink-0 items-center rounded-full transition-colors focus-visible:ring-3 focus-visible:outline-none disabled:opacity-50",
        className,
      )}
      {...props}
    >
      <SwitchPrimitive.Thumb className="pointer-events-none block size-6 translate-x-0.5 rounded-full bg-white shadow-sm transition-transform data-[state=checked]:translate-x-[1.375rem]" />
    </SwitchPrimitive.Root>
  );
}

export function EmptyState({
  icon,
  title,
  description,
  action,
}: {
  icon?: React.ReactNode;
  title: string;
  description?: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex min-h-60 flex-col items-center justify-center gap-3 px-8 py-12 text-center">
      {icon ? <div className="text-muted-foreground/60">{icon}</div> : null}
      <p className="text-lg font-semibold">{title}</p>
      {description ? (
        <p className="text-muted-foreground max-w-sm text-sm leading-relaxed">
          {description}
        </p>
      ) : null}
      {action}
    </div>
  );
}
