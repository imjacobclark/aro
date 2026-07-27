"use client";

import { Check, Copy } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";

export function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    await navigator.clipboard.writeText(command);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1800);
  }

  return (
    <Button
      type="button"
      size="sm"
      variant="secondary"
      onClick={copy}
      className="absolute right-2 top-2 h-8 rounded-none border border-white/20 bg-white/10 px-2.5 text-[0.65rem] text-white hover:bg-white/20 hover:text-white"
      aria-label="Copy launch commands"
    >
      {copied ? <Check aria-hidden="true" /> : <Copy aria-hidden="true" />}
      {copied ? "Copied" : "Copy"}
    </Button>
  );
}
