"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import {
  BarChart3,
  Disc3,
  FileSearch,
  Home,
  Library,
  Search,
  Settings,
  ShieldCheck,
  Users,
} from "lucide-react";

import { MiniPlayer } from "@/components/player/mini-player";
import { cn } from "@/lib/utils";

/**
 * Mobile-first navigation: a bottom tab bar within thumb reach, promoted to the macOS
 * app's left sidebar once there is a desktop's worth of width. Both list the same
 * destinations in the same order as `Destination` in the Swift app, so muscle memory
 * carries between them.
 */

const DESTINATIONS = [
  { href: "/", label: "Home", icon: Home },
  { href: "/songs", label: "Songs", icon: Library },
  { href: "/albums", label: "Albums", icon: Disc3 },
  { href: "/artists", label: "Artists", icon: Users },
  { href: "/search", label: "Search", icon: Search },
];

const SECONDARY = [
  { href: "/stats", label: "Stats", icon: BarChart3 },
  { href: "/health", label: "Library Health", icon: ShieldCheck },
  { href: "/metadata", label: "Metadata", icon: FileSearch },
  { href: "/settings", label: "Settings", icon: Settings },
];

/** Tabs are limited to five: more than that and each target gets too narrow to hit. */
const TABS = [...DESTINATIONS.slice(0, 4), SECONDARY[0]];

export function AppShell({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-dvh flex-col lg:flex-row">
      <DesktopSidebar />

      <div className="flex min-w-0 flex-1 flex-col">
        <main
          className="pb-player flex-1"
          style={{ ["--player-clearance" as string]: "10.5rem" }}
        >
          {children}
        </main>
      </div>

      <MiniPlayer />
      <TabBar />
    </div>
  );
}

function DesktopSidebar() {
  const pathname = usePathname();

  return (
    <aside className="bg-sidebar border-hairline sticky top-0 hidden h-dvh w-60 shrink-0 flex-col border-r px-3 py-5 lg:flex">
      <Link href="/" className="mb-6 flex items-center gap-2.5 px-2">
        <span className="orbit-surface flex size-8 items-center justify-center rounded-full text-sm font-bold">
          A
        </span>
        <span className="text-lg font-bold tracking-tight">Aro</span>
      </Link>

      <nav className="flex flex-col gap-0.5">
        {[...DESTINATIONS, ...SECONDARY].map((item) => (
          <SidebarLink
            key={item.href}
            {...item}
            active={isActive(pathname, item.href)}
          />
        ))}
      </nav>

      <p className="text-muted-foreground/60 mt-auto px-3 text-[0.7rem] leading-relaxed">
        Playing from your hub. Everything you hear is your own library.
      </p>
    </aside>
  );
}

function SidebarLink({
  href,
  label,
  icon: Icon,
  active,
}: {
  href: string;
  label: string;
  icon: typeof Home;
  active: boolean;
}) {
  return (
    <Link
      href={href}
      className={cn(
        "flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors",
        active
          ? "bg-[var(--selected)] text-primary"
          : "text-muted-foreground hover:bg-muted hover:text-foreground",
      )}
    >
      <Icon className="size-[1.15rem]" />
      {label}
    </Link>
  );
}

function TabBar() {
  const pathname = usePathname();

  return (
    <nav className="bg-sidebar/92 border-hairline fixed inset-x-0 bottom-0 z-40 border-t pb-[env(safe-area-inset-bottom)] backdrop-blur-xl lg:hidden">
      <div className="flex">
        {TABS.map((item) => {
          const active = isActive(pathname, item.href);
          return (
            <Link
              key={item.href}
              href={item.href}
              aria-current={active ? "page" : undefined}
              className={cn(
                "flex flex-1 flex-col items-center gap-1 py-2.5 text-[0.65rem] font-medium transition-colors",
                active ? "text-primary" : "text-muted-foreground",
              )}
            >
              <item.icon
                className="size-[1.35rem]"
                strokeWidth={active ? 2.4 : 1.8}
              />
              {item.label}
            </Link>
          );
        })}
      </div>
    </nav>
  );
}

function isActive(pathname: string, href: string): boolean {
  return href === "/" ? pathname === "/" : pathname.startsWith(href);
}
