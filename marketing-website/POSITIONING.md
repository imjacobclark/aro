# Aro Positioning

## Category read

The self-hosted music market usually describes itself as a personal streaming
service:

- A server indexes the collection and streams it to separate web, mobile,
  desktop, TV, or Subsonic-compatible clients.
- Remote listening is an infrastructure task involving a public server,
  reverse proxy, tunnel, VPN, or port forwarding.
- Transcoding is treated as a benefit because it adapts songs to clients and
  networks.
- Metadata, scrobbling, lyrics, themes, discovery, and diagnostics often arrive
  through plugins, external services, or additional tools.
- The central server remains the authoritative dependency for its clients.

That pattern is represented throughout
[Awesome Self-Hosted Music](https://github.com/Tal0na/Awesome-SelfHosted-Music-Awesome),
particularly its separate server, client, deployment, remote-access, plugin,
and tools categories. Navidrome exemplifies the focused personal-streaming
server; Jellyfin exemplifies the broad media server; Plexamp exemplifies the
polished companion client; Roon exemplifies the premium whole-home music
system.

## Aro's opening

Aro should not market itself as another “personal Spotify.” It is a native
music system for people who regard their songs as a collection worth keeping.
Its value is built around four promises:

1. Aros replicate complete, verified songs across the devices the owner
   chooses, creating independent playable copies rather than disposable
   clients.
2. Complete songs are verified before bit-perfect, native-rate playback.
3. Hosting, playback, automatic organisation, identification, and collection
   care arrive as one system rather than a stack of unrelated parts.
4. The whole library can leave through a resumable export of original songs,
   ordinary folders, and a manifest.

The product-positioning summary is:

> Aro is a complete music system for people who own their music. It hosts,
> plays, organises, replicates, and exports the whole collection.

## Language-market-fit hypothesis

The first audience to test is someone who already has a meaningful folder of
downloaded or ripped music. They have considered a personal music server, but
dislike one or more parts of the usual arrangement: assembling several
components, depending on one always-online host, transcoding original songs,
or trusting a system without a clear way to export the collection. macOS is
the first available client, not the definition of the audience or product.

Their job is not “self-host music.” In plain language, it is:

> I want to browse and play the songs I own on my devices without building
> a server stack, reducing their quality, or making the collection depend on
> one machine.

The homepage should therefore pass this five-second comprehension test:

1. Aro is a complete music system for a collection the visitor owns.
2. Aros can keep independent, verified copies of that collection.
3. Aro plays complete songs bit-perfect and at their native rate.
4. Hosting, playback, and automatic organisation are included.
5. The whole collection can be exported without lock-in.

The hero should state this directly:

> A music library built to last.
>
> Aro is a complete music system for people who own their music.
>
> Aro hosts your library, organises it automatically, plays every song
> bit-perfect, and keeps verified copies across the Aros you choose. If you
> ever want to leave, export the whole collection.

## Message hierarchy

### Lead with

- “Your library gets safer with every Aro.”
- “Every song, complete and bit-perfect.”
- “Hosting, playback, and organisation in one system.”
- “Easy to join. Easy to leave.”

### Use as proof

- Bit-perfect and native-rate playback.
- No cloud account, subscription, or Aro relay.
- QR or six-digit pairing and explicit device approval.
- AcoustID and MusicBrainz identification without default write-back.
- Library health, listening history, resumable transfers, and checked songs.
- Optional Linux, Docker, and NAS hosting.

### Do not lead with

- “Self-hosted,” which describes an implementation before a benefit.
- “Your music, your way,” “seamless,” or “anywhere,” which are category
  clichés and blur important constraints.
- A list of formats, protocols, platforms, or server internals.
- “Audiophile-grade,” which invites gatekeeping and is less credible than
  naming bit-perfect playback and native sample rates.
- An unexplained brand slogan with no concrete supporting copy.

## Voice and rhythm

Aro should feel like a music product, not storage software or technical
documentation. The voice is warm and confident, but more grounded than a
large lifestyle brand.

- Lead each section with a specific product outcome.
- Follow immediately with a specific explanation of how Aro delivers it.
- Talk about songs, albums, artists, listening, and collections before
  infrastructure.
- Let technical proof appear where it earns trust: original quality, checked
  copies, native sample rates, direct connections, and export.
- Prefer flowing sentences to stacks of clipped commands.
- Avoid stacking poetic fragments, grand declarations, or repeated
  “Everything…” and “The best…” constructions.
- Avoid exaggerated superlatives and claims Aro cannot prove.

Apple Music and Spotify are useful references for warmth and rhythm, but Aro
should not imitate their lifestyle-brand gloss. Its own voice comes from
specificity: a personal collection, original-quality playback, independent
copies, and a clean way out.

## Copy-testing plan

The current page expresses the best evidence-backed hypothesis, not validated
language-market fit. Test it with people who recently installed a personal
music server, searched for an iTunes/Music replacement, or assembled a local
music workflow.

For qualitative comprehension, show only the hero for five seconds, hide it,
then ask:

1. What is Aro?
2. What would it let you do?
3. What songs or services does it work with?
4. What makes it different from another music player or server?

Record their exact words. A successful answer should mention a music
library/player, owned songs, and either original quality or copies across
devices without prompting.

For quantitative testing, compare one variable at a time:

- System-led: “A music system for people who own their music.”
- Redundancy-led: “Your library gets safer with every Aro.”
- Struggle-led: “I want my music on my devices—not trapped on one server.”

Use download-button clicks as the primary intent signal. Do not declare a
winner from page views alone; retain each message long enough to collect a
meaningful number of download intents from the same traffic source.

## Honest boundaries

Aro should not imply that it currently replaces the strengths of every
competitor. Do not claim:

- an iPhone, Android, web, TV, or car client;
- progressive streaming before a complete song is checked;
- multi-user household profiles;
- streaming-service integration;
- public share links, social discovery, lyrics, radio, podcasts, or smart
  playlists;
- automatic internet exposure or an Aro-operated relay;
- a notarized production release.

These omissions make the position clearer: Aro is currently strongest for a
collector who values song integrity, playback quality, resilience, and an
experience that does not feel assembled from server parts. The preview is
currently on macOS; Linux and Windows clients are on the near-term roadmap.

## Research sources

- [Awesome Self-Hosted Music overview](https://github.com/Tal0na/Awesome-SelfHosted-Music-Awesome)
- [Awesome Self-Hosted Music servers](https://github.com/Tal0na/Awesome-SelfHosted-Music-Awesome/tree/main/Servers)
- [Awesome Self-Hosted Music deployment](https://github.com/Tal0na/Awesome-SelfHosted-Music-Awesome/tree/main/deployment)
- [Awesome Self-Hosted Music remote access](https://github.com/Tal0na/Awesome-SelfHosted-Music-Awesome/tree/main/remote-access)
- [Navidrome overview](https://www.navidrome.org/docs/overview/)
- [Jellyfin](https://jellyfin.org/)
- [Roon](https://roon.app/en/)
