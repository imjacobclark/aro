"use client";

import * as React from "react";
import { Dialog } from "radix-ui";
import { X } from "lucide-react";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

const Sheet = Dialog.Root;
const SheetTrigger = Dialog.Trigger;
const SheetClose = Dialog.Close;

const sheetVariants = cva(
  "bg-background fixed z-50 flex flex-col shadow-2xl transition ease-in-out data-[state=closed]:duration-200 data-[state=open]:duration-300",
  {
    variants: {
      side: {
        // A full-height sheet rising from the bottom is the phone idiom for "more about
        // this"; the macOS app uses a popover in the same places.
        bottom:
          "inset-x-0 bottom-0 max-h-[92dvh] rounded-t-3xl border-t data-[state=closed]:slide-out-to-bottom data-[state=open]:slide-in-from-bottom",
        full: "inset-0 data-[state=closed]:slide-out-to-bottom data-[state=open]:slide-in-from-bottom",
        right:
          "inset-y-0 right-0 w-3/4 max-w-sm border-l data-[state=closed]:slide-out-to-right data-[state=open]:slide-in-from-right",
      },
    },
    defaultVariants: { side: "bottom" },
  },
);

function SheetContent({
  className,
  children,
  side = "bottom",
  showClose = true,
  title,
  description,
  ...props
}: React.ComponentProps<typeof Dialog.Content> &
  VariantProps<typeof sheetVariants> & {
    showClose?: boolean;
    title: string;
    description?: string;
  }) {
  return (
    <Dialog.Portal>
      <Dialog.Overlay className="fixed inset-0 z-50 bg-black/45 backdrop-blur-[2px] data-[state=closed]:animate-out data-[state=closed]:fade-out data-[state=open]:animate-in data-[state=open]:fade-in" />
      <Dialog.Content
        className={cn(
          sheetVariants({ side }),
          "data-[state=closed]:animate-out data-[state=open]:animate-in",
          className,
        )}
        {...props}
      >
        {/* Radix requires an accessible name; most sheets show their own heading, so this
            stays visually hidden rather than being duplicated on screen. */}
        <Dialog.Title className="sr-only">{title}</Dialog.Title>
        {description ? (
          <Dialog.Description className="sr-only">
            {description}
          </Dialog.Description>
        ) : null}
        {children}
        {showClose ? (
          <Dialog.Close className="ring-offset-background focus:ring-ring absolute top-4 right-4 rounded-full p-2 opacity-70 transition hover:bg-muted hover:opacity-100 focus:ring-2 focus:outline-none">
            <X className="size-5" />
            <span className="sr-only">Close</span>
          </Dialog.Close>
        ) : null}
      </Dialog.Content>
    </Dialog.Portal>
  );
}

export { Sheet, SheetTrigger, SheetClose, SheetContent };
