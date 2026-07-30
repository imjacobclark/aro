import Image from "next/image";
import {
  ArrowDown,
  Check,
  Download,
  ExternalLink,
  Heart,
  Music2,
  Radio,
  ShieldCheck,
  Sparkles,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { buttonVariants } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";
import { CopyCommand } from "@/components/copy-command";
import { FeatureIndex } from "@/components/feature-index";
import { Reveal } from "@/components/reveal";
import { SiteHeader } from "@/components/site-header";
import { SpectrumWave } from "@/components/spectrum-wave";
import { loadFeatures } from "@/lib/features";
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
    number: "02",
    eyebrow: "One private library",
    title: "Every Aro makes your music more available.",
    copy: "Press play from another Mac and the song starts as it arrives. Keep recent listening, favourite albums, or a complete independently playable copy wherever you choose.",
    points: [
      "Private, encrypted connections with no Aro cloud",
      "Fast read-ahead for playback, seeking, and the next song",
      "Complete copies stay playable when another device is offline",
    ],
    tone: "amber",
    visual: "copies",
  },
  {
    id: "fidelity",
    number: "03",
    eyebrow: "Playback",
    title: "Hear the file you chose. Not a substitute.",
    copy: "Aro plays your original format without a transcoded stand-in or hidden processing. Native sample rates follow the music whenever the audio path supports them.",
    points: [
      "Bit-perfect, native-rate playback by default",
      "Optional measured loudness matching for mixed queues",
      "See the complete signal path to your output",
    ],
    tone: "dark",
    visual: "resolution",
  },
  {
    id: "system",
    number: "04",
    eyebrow: "Collection intelligence",
    title: "Aro does the archaeology. You enjoy the collection.",
    copy: "Point Aro at a folder. It watches for changes, identifies incomplete music by sound, restores useful details and artwork, and shows where duplicates or missing songs need attention.",
    points: [
      "Canonical albums, artwork, genres, and mood signals",
      "Exact duplicates and alternate encodings surfaced clearly",
      "Your originals change only when you explicitly choose",
    ],
    tone: "coral",
    visual: "system",
  },
  {
    id: "export",
    number: "05",
    eyebrow: "No lock-in",
    title: "A library with an exit door.",
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

const mixes = [
  {
    title: "Heavy Rotation",
    subtitle: "The songs you keep coming back to",
    className: "violet",
  },
  {
    title: "Deep Cuts",
    subtitle: "Music waiting to be heard again",
    className: "coral",
  },
  {
    title: "Recently Loved",
    subtitle: "Every favourite, close at hand",
    className: "amber",
  },
  {
    title: "Quiet Hours",
    subtitle: "A mood found inside your library",
    className: "night",
  },
] as const;

const spotlightFeatureTitles = new Set([
  "Press Play Without Waiting",
  "Know Every Recording",
  "A Health Check for Music",
  "Your Listening Story",
  "Pair in Seconds",
  "See Aro at a Glance",
]);

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
  const spotlightFeatures = loadFeatures().filter((feature) =>
    spotlightFeatureTitles.has(feature.title),
  );

  const structuredData = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "Aro",
    applicationCategory: "MultimediaApplication",
    operatingSystem: "macOS 26 or later",
    description:
      "A private, intelligent music system that makes the collection you own feel alive again.",
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
              <p className="eyebrow">The music you own, fully alive</p>
              <h1 id="hero-title" className="display-title balanced">
                Your collection deserves more.
              </h1>
              <p className="hero-definition balanced">
                Aro turns a folder of music into a private, intelligent
                listening system.
              </p>
              <p className="hero-lede balanced">
                Hear every song in its original quality. Get mixes made from
                your own listening. Reach one library across your Macs. Keep
                complete copies where you choose—and take everything back out
                whenever you want.
              </p>
              <div className="hero-hosts" aria-label="What makes Aro different">
                <span>Original quality</span>
                <span>Made-for-you mixes</span>
                <span>Private by design</span>
                <span>No subscription</span>
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
                  href="#intelligence"
                  className={cn(
                    buttonVariants({ variant: "outline", size: "lg" }),
                    "h-12 rounded-none border-[#121733] bg-transparent px-6 text-xs font-bold shadow-none hover:bg-[#121733] hover:text-white",
                  )}
                >
                  See what Aro does
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
              <span className="sleeve-label">Own it. Hear it. Rediscover it.</span>
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
                  Not a folder of files. A living collection.
                </h2>
              </div>
              <p>
                Home, albums, artists, listening history, collection health,
                metadata, connected devices, and serious playback live together
                in one native Mac app.
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
                <span>Your listening story belongs to your library</span>
              </div>
              <div className="product-wave-card">
                <div className="wave-copy">
                  <span>Original signal</span>
                  <strong>44.1 kHz · 16-bit · Bit-perfect</strong>
                </div>
                <SpectrumWave />
              </div>
            </Reveal>
          </div>
        </section>

        <section
          id="intelligence"
          className="intelligence-section"
          aria-labelledby="intelligence-title"
        >
          <div className="site-shell intelligence-grid">
            <Reveal className="intelligence-copy">
              <p className="eyebrow">01 / Made from your music</p>
              <h2 id="intelligence-title" className="section-title balanced">
                Aro listens to your listening.
              </h2>
              <p className="story-copy balanced">
                Your favourites, play history, moods, and forgotten corners
                become a Home that changes with you—not a feed designed to keep
                you inside somebody else’s catalogue.
              </p>
              <div className="intelligence-principle">
                <Sparkles aria-hidden="true" />
                <div>
                  <strong>Your data makes your playlists.</strong>
                  <span>Your library stays private and under your control.</span>
                </div>
              </div>
            </Reveal>
            <Reveal className="mix-board" delay={100}>
              <div className="mix-board-header">
                <span>Made for you</span>
                <span>From your Aro</span>
              </div>
              <div className="mix-grid">
                {mixes.map((mix, index) => (
                  <article className={`mix-card ${mix.className}`} key={mix.title}>
                    <div className="mix-art" aria-hidden="true">
                      {index === 0 && <Radio />}
                      {index === 1 && <Music2 />}
                      {index === 2 && <Heart />}
                      {index === 3 && <Sparkles />}
                    </div>
                    <span>{mix.subtitle}</span>
                    <h3>{mix.title}</h3>
                  </article>
                ))}
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

        <section className="feature-index" aria-labelledby="feature-title">
          <div className="site-shell">
            <Reveal className="feature-heading">
              <div>
                <p className="eyebrow">More than a player</p>
                <h2 id="feature-title" className="section-title balanced">
                  Built around the whole life of a collection.
                </h2>
              </div>
              <p>
                From the first folder you add to the day you export everything,
                Aro keeps sound, history, metadata, storage, and private access
                working as one system.
              </p>
            </Reveal>
            <Reveal delay={80}>
              <FeatureIndex features={spotlightFeatures} />
            </Reveal>
          </div>
        </section>

        <section id="download" className="download-section" aria-labelledby="download-title">
          <div className="site-shell download-grid">
            <Reveal>
              <p className="eyebrow">Development preview</p>
              <h2 id="download-title" className="section-title balanced">
                Download the macOS preview.
              </h2>
              <p className="download-copy balanced">
                Bring your collection back to life with the early preview for
                macOS 26 and later. A standalone Aro can host the library from
                an always-on Linux computer or compatible NAS.
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
