import Image from "next/image";
import {
  ArrowDown,
  Check,
  Download,
  ExternalLink,
  Music2,
  ShieldCheck,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { buttonVariants } from "@/components/ui/button";
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import { Separator } from "@/components/ui/separator";
import { CopyCommand } from "@/components/copy-command";
import { FeatureIndex } from "@/components/feature-index";
import { Reveal } from "@/components/reveal";
import { SiteHeader } from "@/components/site-header";
import { groupFeatures, loadFeatures } from "@/lib/features";
import { releaseDownload } from "@/lib/release";
import { cn } from "@/lib/utils";

const installCommand = `ditto -x -k Sonora-v*-macos-*.zip .
xattr -dr com.apple.quarantine Sonora.app
codesign --force --sign - --timestamp=none \\
  --identifier com.imjacobclark.sonora.server \\
  Sonora.app/Contents/MacOS/sonora-server
codesign --force --deep --sign - --timestamp=none \\
  --preserve-metadata=identifier Sonora.app
mkdir -p "$HOME/Applications"
ditto Sonora.app "$HOME/Applications/Sonora.app"
open "$HOME/Applications/Sonora.app"`;

const stories = [
  {
    id: "ownership",
    number: "01",
    eyebrow: "Ownership",
    title: "A real home for your music.",
    copy: "Your collection is more than access to a catalogue. Sonora starts with the files you chose, keeps them in their original quality, and never quietly edits or deletes the source.",
    points: [
      "Original files remain exactly as you added them",
      "FLAC, ALAC, AAC, MP3, WAV, AIFF, and OGG Vorbis together",
      "Stored or linked libraries, depending on how you keep music",
    ],
    tone: "",
    visual: "formats",
  },
  {
    id: "sound",
    number: "02",
    eyebrow: "Listening",
    title: "Hear the recording, not the player.",
    copy: "Bit-perfect playback is the starting point. Sonora matches native sample rates, can take exclusive control of wired equipment, and shows the whole signal path when you want to look closer.",
    points: [
      "Native sample-rate matching up to 192 kHz",
      "Gapless albums and optional loudness matching",
      "Choose a DAC, headphones, HomePod, TV, or AirPlay speaker",
    ],
    tone: "dark",
    visual: "resolution",
  },
  {
    id: "library",
    number: "03",
    eyebrow: "Collection",
    title: "Your shelves, alive again.",
    copy: "Add a folder and Sonora turns it into a library made for browsing. Artwork, artists, albums, listening history, and library health bring order and rediscovery without turning music into a feed.",
    points: [
      "Folders stay updated as your files change",
      "Find duplicates, alternate copies, moved songs, and gaps",
      "See listening time, favourites, formats, genres, and decades",
    ],
    tone: "",
    visual: "library",
  },
  {
    id: "home",
    number: "04",
    eyebrow: "Around home",
    title: "One collection. Your devices.",
    copy: "Share a Sonora privately around your home. A QR code or six digits connects another device, and nothing enters the library until you approve it.",
    points: [
      "No Sonora cloud account",
      "Approve, limit, or remove each connected device",
      "Keep local and connected libraries clearly separate",
    ],
    tone: "coral",
    visual: "connect",
  },
  {
    id: "offline",
    number: "05",
    eyebrow: "Offline",
    title: "Keep the albums that matter close.",
    copy: "Listen from a connected collection when you need it, then choose favourites, albums, or everything to keep on your Mac. Sonora handles storage without removing what is playing or queued.",
    points: [
      "Every download is complete and checked before playback",
      "Interrupted transfers continue where they stopped",
      "Automatic or personal storage limits",
    ],
    tone: "amber",
    visual: "offline",
  },
  {
    id: "recovery",
    number: "06",
    eyebrow: "Portability",
    title: "You can always take it with you.",
    copy: "A collection should never feel trapped. Export the entire library into tidy Artist and Album folders, carry recoverable removals with it, or move Sonora’s Library Data when your storage changes.",
    points: [
      "Repeatable, resumable whole-library exports",
      "Existing files are respected, never silently overwritten",
      "Sharing can continue after the Sonora window closes",
    ],
    tone: "dark",
    visual: "export",
  },
] as const;

function StoryVisual({ visual, number }: { visual: string; number: string }) {
  if (visual === "formats") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">Original masters</span>
        <div className="format-stack">
          <span>FLAC <small>UNCHANGED</small></span>
          <span>ALAC <small>UNCHANGED</small></span>
          <span>WAV <small>UNCHANGED</small></span>
        </div>
        <div className="visual-footer"><span>Sonora library</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "resolution") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">Native output</span>
        <div className="visual-large">24<br />192</div>
        <div className="visual-footer"><span>bit</span><span>kHz</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "connect") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">Private connection</span>
        <div className="orbit-pair"><span>Approved devices</span></div>
        <div className="visual-footer"><span>Home network</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "export") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">Your whole library</span>
        <div className="folder-tree">
          <span>sonora-library/</span>
          <span className="indent-1">Artist/</span>
          <span className="indent-2">Album/</span>
          <span className="indent-2">01 — Song.flac</span>
        </div>
        <div className="visual-footer"><span>Complete</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "offline") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">Kept for you</span>
        <div className="visual-large">100<span className="text-[0.32em] tracking-normal">%</span></div>
        <div className="visual-footer"><span>Downloaded</span><span>Checked</span><span>{number}</span></div>
      </div>
    );
  }
  return (
    <div className="story-visual" aria-hidden="true">
      <span className="visual-kicker">Your collection</span>
      <div className="visual-large">∞</div>
      <div className="visual-footer"><span>Artists</span><span>Albums</span><span>{number}</span></div>
    </div>
  );
}

export default function Home() {
  const features = loadFeatures();
  const groups = groupFeatures(features);
  const release = releaseDownload();
  const basePath = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

  const structuredData = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "Sonora",
    applicationCategory: "MultimediaApplication",
    operatingSystem: "macOS 26 or later",
    description:
      "A private Mac music library for people who care about ownership, sound, and their collection.",
    downloadUrl: release.arm64Url,
    softwareVersion: release.version.replace(/^v/, ""),
  };

  return (
    <>
      <SiteHeader basePath={basePath} />
      <main id="top">
        <section className="hero" aria-labelledby="hero-title">
          <div className="site-shell hero-grid">
            <Reveal className="hero-copy">
              <p className="eyebrow">A private home for your music</p>
              <h1 id="hero-title" className="display-title balanced">
                Your music.<br />Fully yours.
              </h1>
              <p className="hero-lede balanced">
                Sonora brings the files you own back to life—with uncompromised
                playback, a library worth exploring, and private access around
                your home.
              </p>
              <div className="hero-actions">
                <a
                  href="#download"
                  className={cn(
                    buttonVariants({ size: "lg" }),
                    "h-12 rounded-none bg-[#121733] px-6 text-xs font-bold text-white shadow-none hover:bg-[#7359e0]",
                  )}
                >
                  <Download aria-hidden="true" data-icon="inline-start" />
                  Download preview
                </a>
                <a
                  href="#ownership"
                  className={cn(
                    buttonVariants({ variant: "outline", size: "lg" }),
                    "h-12 rounded-none border-[#121733] bg-transparent px-6 text-xs font-bold shadow-none hover:bg-[#121733] hover:text-white",
                  )}
                >
                  Explore Sonora
                  <ArrowDown aria-hidden="true" data-icon="inline-end" />
                </a>
              </div>
            </Reveal>
            <Reveal className="sleeve" delay={120}>
              <div className="sleeve-icon">
                <Image
                  src={`${basePath}/app-icon.png`}
                  alt="Sonora app icon"
                  width={220}
                  height={220}
                  priority
                />
              </div>
              <span className="sleeve-label">Designed for your collection</span>
            </Reveal>
          </div>
        </section>

        <div>
          {stories.map((story) => (
            <section
              key={story.id}
              id={story.id}
              className={`story-section ${story.tone}`}
              aria-labelledby={`${story.id}-title`}
            >
              <div className="site-shell story-grid">
                <Reveal>
                  <p className="eyebrow">{story.number} / {story.eyebrow}</p>
                  <h2 id={`${story.id}-title`} className="section-title balanced">
                    {story.title}
                  </h2>
                  <p className="story-copy balanced">{story.copy}</p>
                  <ul className="story-points">
                    {story.points.map((point) => (
                      <li key={point}>
                        <Check aria-hidden="true" />
                        {point}
                      </li>
                    ))}
                  </ul>
                </Reveal>
                <Reveal delay={100}>
                  <StoryVisual visual={story.visual} number={story.number} />
                </Reveal>
              </div>
            </section>
          ))}
        </div>

        <section id="features" className="feature-index" aria-labelledby="features-title">
          <div className="site-shell">
            <Reveal className="feature-heading">
              <div>
                <p className="eyebrow">The full collection</p>
                <h2 id="features-title" className="section-title balanced">
                  Every reason to choose Sonora.
                </h2>
              </div>
              <p>
                {features.length} verified capabilities, drawn directly from
                the product—not a roadmap, and not a list of technical
                internals.
              </p>
            </Reveal>
            <Reveal delay={100}>
              <FeatureIndex groups={groups} />
            </Reveal>
          </div>
        </section>

        <section id="download" className="download-section" aria-labelledby="download-title">
          <div className="site-shell download-grid">
            <Reveal>
              <p className="eyebrow">Development preview</p>
              <h2 id="download-title" className="section-title balanced">
                Bring your collection home.
              </h2>
              <p className="download-copy balanced">
                Sonora is available now as an early preview for macOS 26 and
                later. Choose the build that matches your Mac.
              </p>
              <div className="mt-8 flex flex-wrap gap-2">
                <Badge className="rounded-none border-white/25 bg-white/10 text-white">
                  {release.version}
                </Badge>
                <Badge className="rounded-none border-white/25 bg-transparent text-white">
                  macOS 26+
                </Badge>
                <Badge className="rounded-none border-white/25 bg-transparent text-white">
                  Free preview
                </Badge>
              </div>
            </Reveal>
            <Reveal className="download-panel" delay={100}>
              <div className="flex items-start gap-3">
                <Music2 className="mt-0.5 size-5 text-[#7359e0]" aria-hidden="true" />
                <div>
                  <h3 className="font-bold tracking-[-0.025em]">Choose your Mac</h3>
                  <p className="mt-1 text-xs leading-6 text-[#67697c]">
                    Apple Silicon covers M1 and every newer M-series Mac.
                    Intel is for older Macs with an Intel processor.
                  </p>
                </div>
              </div>
              <div className="download-buttons">
                <a
                  href={release.arm64Url}
                  className={cn(
                    buttonVariants({ size: "lg" }),
                    "h-12 w-full justify-between rounded-none bg-[#7359e0] px-5 text-xs font-bold text-white shadow-none hover:bg-[#6149c6]",
                  )}
                >
                  <span>Apple Silicon</span>
                  <Download aria-hidden="true" />
                </a>
                <a
                  href={release.intelUrl}
                  className={cn(
                    buttonVariants({ variant: "outline", size: "lg" }),
                    "h-12 w-full justify-between rounded-none border-[#121733] bg-transparent px-5 text-xs font-bold shadow-none hover:bg-[#121733] hover:text-white",
                  )}
                >
                  <span>Intel Mac</span>
                  <Download aria-hidden="true" />
                </a>
              </div>
              {release.usesDirectAssets && (
                <div className="flex flex-wrap gap-x-4 gap-y-1 text-[0.66rem] font-semibold">
                  {release.arm64ChecksumUrl && (
                    <a className="underline underline-offset-4" href={release.arm64ChecksumUrl}>
                      Apple Silicon checksum
                    </a>
                  )}
                  {release.intelChecksumUrl && (
                    <a className="underline underline-offset-4" href={release.intelChecksumUrl}>
                      Intel checksum
                    </a>
                  )}
                </div>
              )}
              <p className="preview-note">
                Preview builds are ad-hoc signed rather than Apple-notarized.
                Only download Sonora from this official repository.
              </p>
              <Separator className="my-6 bg-[rgba(18,23,51,0.14)]" />
              <Accordion type="single" collapsible>
                <AccordionItem value="open" className="border-none">
                  <AccordionTrigger className="py-0 text-left text-sm font-bold hover:no-underline">
                    How to open the preview
                  </AccordionTrigger>
                  <AccordionContent className="pb-0 pt-4">
                    <p className="text-xs leading-6 text-[#67697c]">
                      Open Terminal in your Downloads folder, paste this block,
                      and press Return. It verifies and installs Sonora in your
                      personal Applications folder.
                    </p>
                    <div className="command-block">
                      <CopyCommand command={installCommand} />
                      {installCommand}
                    </div>
                  </AccordionContent>
                </AccordionItem>
              </Accordion>
              <div className="mt-6 flex items-center gap-2 text-[0.66rem] font-semibold text-[#67697c]">
                <ShieldCheck className="size-4 text-[#7359e0]" aria-hidden="true" />
                No account. No subscription. No Sonora cloud.
              </div>
            </Reveal>
          </div>
        </section>
      </main>
      <footer className="site-footer">
        <div className="site-shell footer-inner">
          <span>© 2026 Sonora. Your music, fully yours.</span>
          <div className="footer-links">
            <a
              href="https://github.com/imjacobclark/sonora"
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1.5"
            >
              GitHub
            </a>
            <a
              href="https://github.com/imjacobclark/sonora/releases"
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1.5"
            >
              Releases
              <ExternalLink className="size-3.5" aria-hidden="true" />
            </a>
          </div>
        </div>
      </footer>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(structuredData) }}
      />
    </>
  );
}
