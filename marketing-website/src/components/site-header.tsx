import Image from "next/image";
import { Download } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import { cn } from "@/lib/utils";

export function SiteHeader() {
  return (
    <header className="fixed inset-x-0 top-0 z-50 border-b border-[rgba(18,23,51,0.12)] bg-[#f5f2eb]/90 backdrop-blur-xl">
      <div className="site-shell flex h-[4.6rem] items-center justify-between">
        <a
          href="#top"
          className="flex items-center gap-2.5 text-sm font-extrabold tracking-[-0.03em]"
          aria-label="Aro home"
        >
          <Image
            src="/app-icon.png"
            alt=""
            width={30}
            height={30}
            className="rounded-[22%]"
            priority
          />
          Aro
        </a>
        <nav
          aria-label="Primary navigation"
          className="hidden items-center gap-7 text-[0.72rem] font-semibold md:flex"
        >
          <a className="transition-colors hover:text-[#7359e0]" href="#intelligence">
            Made for you
          </a>
          <a className="transition-colors hover:text-[#7359e0]" href="#fidelity">
            Sound
          </a>
          <a className="transition-colors hover:text-[#7359e0]" href="#resilience">
            Your library
          </a>
          <a className="transition-colors hover:text-[#7359e0]" href="#export">
            No lock-in
          </a>
        </nav>
        <a
          href="#download"
          className={cn(
            buttonVariants({ size: "sm" }),
            "rounded-none bg-[#121733] px-4 text-[0.7rem] font-bold text-white shadow-none hover:bg-[#7359e0]",
          )}
        >
          <Download aria-hidden="true" data-icon="inline-start" />
          Download Aro
        </a>
      </div>
    </header>
  );
}
