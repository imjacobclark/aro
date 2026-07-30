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
import { Separator } from "@/components/ui/separator";
import { CopyCommand } from "@/components/copy-command";
import { Reveal } from "@/components/reveal";
import { SiteHeader } from "@/components/site-header";
import { SpectrumWave } from "@/components/spectrum-wave";
import { releaseDownload } from "@/lib/release";
import { cn } from "@/lib/utils";

const installCommand = `ditto -x -k Aro-v*-macos-*.zip .
xattr -dr com.apple.quarantine Aro.app
codesign --force --sign - --timestamp=none \\
  --identifier com.imjacobclark.aro.server \\
  Aro.app/Contents/MacOS/aro-server
codesign --force --deep --sign - --timestamp=none \\
  --preserve-metadata=identifier Aro.app
mkdir -p "$HOME/Applications"
ditto Aro.app "$HOME/Applications/Aro.app"
open "$HOME/Applications/Aro.app"`;

const stories = [
  {
    id: "resilience",
    number: "01",
    eyebrow: "Redundancy",
    title: "Your library gets safer with every Aro.",
    copy: "Choose which albums—or the entire library—each Aro should keep. Every copy is complete, verified against the original, and independently playable when another device goes offline.",
    points: [
      "Keep full, playable copies on the devices you choose",
      "Every copied song is checked against the original",
      "Interrupted replication continues where it stopped",
    ],
    tone: "amber",
    visual: "copies",
  },
  {
    id: "fidelity",
    number: "02",
    eyebrow: "Playback",
    title: "Every song, complete and bit-perfect.",
    copy: "Aro verifies the complete song before it reaches the player, then plays it without recompression or added processing. Native sample rates follow the music whenever the audio path supports them.",
    points: [
      "No partial playback and no transcoded substitute",
      "Bit-perfect, native-rate playback by default",
      "See the complete path from the song to your output",
    ],
    tone: "dark",
    visual: "resolution",
  },
  {
    id: "system",
    number: "03",
    eyebrow: "Complete by design",
    title: "Hosting, playback, and organisation in one system.",
    copy: "Point Aro at a music folder and start listening. Aro hosts the library, plays it, watches for changes, identifies incomplete metadata, and keeps the collection organised without a separate server, client, or plugin stack.",
    points: [
      "Browse albums, artists, artwork, and listening history",
      "Identify songs with AcoustID and MusicBrainz",
      "macOS now, with Linux and Windows clients coming soon",
    ],
    tone: "coral",
    visual: "system",
  },
  {
    id: "export",
    number: "04",
    eyebrow: "No lock-in",
    title: "Easy to join. Easy to leave.",
    copy: "Your collection never becomes dependent on Aro. Export the whole library into ordinary Artist and Album folders, in the original formats, with a manifest that records what came with you.",
    points: [
      "Repeatable, resumable whole-library exports",
      "Existing songs are respected, never silently overwritten",
      "Recently removed music stays recoverable for export",
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
        <div className="visual-footer"><span>Aro library</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "resolution") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">The direct path</span>
        <div className="signal-path">
          <span>Original song</span>
          <b>→</b>
          <span>Your output</span>
        </div>
        <div className="visual-footer"><span>No forced resampling</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "host") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">Place it anywhere</span>
        <div className="host-map">
          <span className="host-core">ARO</span>
          <span>MAC</span>
          <span>LINUX</span>
          <span>NAS</span>
        </div>
        <div className="visual-footer"><span>Any reachable network</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "system") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">One complete system</span>
        <div className="system-stack">
          <span>HOST <small>YOUR LIBRARY</small></span>
          <span>PLAY <small>EVERY SONG</small></span>
          <span>ORGANISE <small>AUTOMATICALLY</small></span>
        </div>
        <div className="visual-footer"><span>Ready out of the box</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "export") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">Your whole library</span>
        <div className="folder-tree">
          <span>aro-library/</span>
          <span className="indent-1">Artist/</span>
          <span className="indent-2">Album/</span>
          <span className="indent-2">01 — Song.flac</span>
        </div>
        <div className="visual-footer"><span>Complete</span><span>{number}</span></div>
      </div>
    );
  }
  if (visual === "copies") {
    return (
      <div className="story-visual" aria-hidden="true">
        <span className="visual-kicker">A library that endures</span>
        <div className="copy-stack">
          <span>HOST <small>COMPLETE</small></span>
          <span>MAC <small>COMPLETE</small></span>
          <span>MAC <small>COMPLETE</small></span>
        </div>
        <div className="visual-footer"><span>Independent verified copies</span><span>{number}</span></div>
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
  const release = releaseDownload();

  const structuredData = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "Aro",
    applicationCategory: "MultimediaApplication",
    operatingSystem: "macOS 26 or later",
    description:
      "A complete music system that hosts, plays, organises, replicates, and exports the songs you own.",
    downloadUrl: release.arm64Url,
    softwareVersion: release.version.replace(/^v/, ""),
  };

  return (
    <>
      <SiteHeader />
      <main id="top">
        <section className="hero" aria-labelledby="hero-title">
          <div className="site-shell hero-grid">
            <Reveal className="hero-copy">
              <p className="eyebrow">Meet Aro</p>
              <h1 id="hero-title" className="display-title balanced">
                A music library built to last.
              </h1>
              <p className="hero-definition balanced">
                Aro is a complete music system for people who own their music.
              </p>
              <p className="hero-lede balanced">
                Aro hosts your library, organises it automatically, plays every
                song bit-perfect, and keeps verified copies across the Aros you
                choose. If you ever want to leave, export the whole collection.
              </p>
              <div className="hero-hosts" aria-label="Aro hosting options">
                <span>macOS now</span>
                <span>Linux soon</span>
                <span>Windows next</span>
                <span>Original songs</span>
              </div>
              <div className="hero-actions">
                <a
                  href="#download"
                  className={cn(
                    buttonVariants({ size: "lg" }),
                    "h-12 rounded-none bg-[#121733] px-6 text-xs font-bold text-white shadow-none hover:bg-[#7359e0]",
                  )}
                >
                  <Download aria-hidden="true" data-icon="inline-start" />
                  Download Aro
                </a>
                <a
                  href="#resilience"
                  className={cn(
                    buttonVariants({ variant: "outline", size: "lg" }),
                    "h-12 rounded-none border-[#121733] bg-transparent px-6 text-xs font-bold shadow-none hover:bg-[#121733] hover:text-white",
                  )}
                >
                  How Aro works
                  <ArrowDown aria-hidden="true" data-icon="inline-end" />
                </a>
              </div>
            </Reveal>
            <Reveal className="sleeve" delay={120}>
              <div className="sleeve-icon">
                <Image
                  src="/app-icon.png"
                  alt="Aro app icon"
                  width={220}
                  height={220}
                  priority
                />
              </div>
              <span className="sleeve-label">Host it. Play it. Replicate it. Export it.</span>
            </Reveal>
          </div>
        </section>

        <section
          id="inside"
          className="product-section"
          aria-labelledby="inside-title"
        >
          <div className="site-shell">
            <Reveal className="product-heading">
              <div>
                <p className="eyebrow">Inside Aro</p>
                <h2 id="inside-title" className="section-title balanced">
                  Your complete music library, ready to play.
                </h2>
              </div>
              <p>
                Add a folder and Aro does the rest: artwork, albums, artists,
                listening history, library health, and playback in one app.
              </p>
            </Reveal>
            <Reveal className="product-stage" delay={100}>
              <div className="product-glow" aria-hidden="true" />
              <Image
                src="/aro-library.png"
                alt="Aro for macOS showing a connected music library, offline resiliency controls, the player bar, and playback visualizer"
                width={1400}
                height={850}
                className="product-screenshot"
              />
              <div className="product-secondary-card">
                <Image
                  src="/aro-stats.png"
                  alt="Aro for macOS showing listening time, a 30-day listening chart, and most-played music"
                  width={1400}
                  height={850}
                />
                <span>Your listening story, kept with your library</span>
              </div>
              <div className="product-wave-card">
                <div className="wave-copy">
                  <span>Now playing</span>
                  <strong>The sound of your library</strong>
                </div>
                <SpectrumWave />
              </div>
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

        <section id="download" className="download-section" aria-labelledby="download-title">
          <div className="site-shell download-grid">
            <Reveal>
              <p className="eyebrow">Development preview</p>
              <h2 id="download-title" className="section-title balanced">
                Download the macOS preview.
              </h2>
              <p className="download-copy balanced">
                Start listening with the early preview for macOS 26 and later.
                Linux and Windows clients are coming soon.
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
                Only download Aro from this official repository.
              </p>
              <Separator className="my-6 bg-[rgba(18,23,51,0.14)]" />
              <div className="preview-instructions">
                <h3>Open the preview</h3>
                <p>
                  Open Terminal in your Downloads folder, paste this block,
                  and press Return. It verifies and installs Aro in your
                  personal Applications folder.
                </p>
                <div className="command-block">
                  <CopyCommand command={installCommand} />
                  {installCommand}
                </div>
              </div>
              <div className="mt-6 flex items-center gap-2 text-[0.66rem] font-semibold text-[#67697c]">
                <ShieldCheck className="size-4 text-[#7359e0]" aria-hidden="true" />
                No account. No subscription. No Aro cloud.
              </div>
            </Reveal>
          </div>
        </section>
      </main>
      <footer className="site-footer">
        <div className="site-shell footer-inner">
          <span>© 2026 Aro. Built for the songs you own.</span>
          <div className="footer-links">
            <a
              href="https://github.com/imjacobclark/aro"
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1.5"
            >
              GitHub
            </a>
            <a
              href="https://github.com/imjacobclark/aro/releases"
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
