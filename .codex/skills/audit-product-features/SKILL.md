---
name: audit-product-features
description: Audit Aro's repository for shipped, user-visible product capabilities and regenerate the root features.md as an evidence-backed marketing list. Use when cataloguing features, refreshing product positioning, preparing website or release copy, checking that marketing reflects the current app, or identifying Aro's differentiators for non-technical music listeners and collectors.
---

# Audit Product Features

Create or replace `./features.md` with a complete, defensible inventory of
Aro's shipped product value. Write for people who love, collect, and listen
to music—not for developers.

Read [references/audience-and-voice.md](references/audience-and-voice.md)
before auditing or writing.

## Audit the product

Work from the repository root. Treat implementation and tests as stronger
evidence than plans or comments.

1. Read the root and platform READMEs for product vocabulary and scope.
2. Inventory user-facing surfaces:
   - macOS navigation, views, sheets, menus, settings, empty states, alerts,
     buttons, and onboarding
   - shared domain models and application use cases
   - playback, library, health, statistics, devices, offline music, import,
     migration, recovery, and export code
   - standalone server commands only where they create a benefit visible to a
     Aro listener
3. Search tests for behaviours that are easy to miss in the UI: safety,
   resumability, deduplication, verification, recovery, deterministic sync,
   cache protection, reconnection, and failure handling.
4. Inspect build or release configuration only for genuine customer-facing
   availability, platform, or packaging claims.
5. Search terminology broadly, including synonyms and historical names. The
   code may still say `track`, `hub`, `server`, `host`, or `sync`; translate
   these into Aro's current customer vocabulary.
6. Reconcile conflicting evidence. Prefer currently reachable UI plus passing
   tests. Exclude a capability when it exists only in a plan, TODO, disabled
   control, fixture, preview, future-facing comment, unused model, or
   unconnected backend endpoint.

Use `rg --files` and `rg` first. Open the implementation behind every material
claim. Do not infer a shipped feature from a filename alone.

## Build an evidence ledger

Keep a temporary ledger while auditing. For every candidate record:

- capability
- user outcome
- implementation evidence
- test evidence, when available
- confidence: shipped, ambiguous, or planned
- possible overlap with another candidate

Do not write the ledger to `features.md`. Include only shipped capabilities.
Resolve ambiguous candidates by reading more code; omit unresolved claims.

Group low-level mechanisms into the strongest honest customer promise. For
example:

- Bonjour discovery + authenticated pairing + credential storage becomes
  effortless, private library connection.
- SHA-256 verification + resumable download becomes dependable offline music
  that arrives intact.
- SQLite isolation + logical synchronization becomes safe sharing without
  putting the original library at risk.

Keep separate bullets when customers would recognize separate reasons to
choose or keep using Aro.

## Determine the audience

Re-evaluate the audience from current product evidence on every run, using the
reference as the baseline. Look for:

- the collection they own and how they currently store it
- the listening equipment and quality they care about
- the frustrations Aro removes
- the emotional benefit: ownership, confidence, continuity, discovery, or
  calm
- the level of technical knowledge the interface expects

Use that audience model to prioritize and phrase every bullet. Do not turn
`features.md` into a persona document unless explicitly asked.

## Write `features.md`

Replace the file rather than appending to stale claims. Use this exact shape:

```markdown
# Aro Features

- **Snappy USP or Differentiator** — Marketing description.
- **Another Customer Benefit** — Marketing description.
```

Apply all of these rules:

- Use one bullet per distinct product-level capability.
- Start each bullet with a short, memorable, title-cased promise, normally
  two to six words.
- Follow it with an em dash and one or two benefit-led sentences.
- Explain what the listener gains before how Aro delivers it.
- Use plain, warm language that makes sense without technical knowledge.
- Say `songs`, never `tracks`.
- Say `Aro`, `library`, `Library Data`, `Background Service`,
  `Connect to a Aro`, and `Share this Aro` where those nouns are needed.
- Avoid `hub`, `daemon`, `helper`, `blob`, `endpoint`, `protocol`, `SQLite`,
  `WAL`, `hash`, `cursor`, `mDNS`, `LAN`, `HLC`, `cache`, `replica`, and
  similar implementation language in customer-facing copy.
- Translate unavoidable audio terms immediately into an audible or practical
  benefit.
- Avoid empty superlatives such as revolutionary, ultimate, seamless, best,
  stunning, magical, or audiophile-grade.
- Avoid competitive claims that the repository cannot substantiate.
- Avoid promises about iPhone, cloud access, internet access, progressive
  streaming, notarization, or future work unless they are actually shipped.
- Do not mention developer commands, architecture, CI, APIs, or source code.
- Do not repeat the same differentiator under multiple titles.
- Order bullets by selling power: ownership and sound, effortless library
  experience, private multi-device access, safety and recovery, insight and
  control.
- Keep every claim supportable by the evidence ledger.

## Verify

Before finishing:

1. Re-read every bullet and point to concrete repository evidence for it.
2. Remove duplicates, implementation trivia, roadmap claims, and features
   relevant only to operators.
3. Check that a non-technical music lover can understand every line.
4. Check current product terminology with:

   ```sh
   rg -n -i '\b(track|hub|daemon|helper|blob|sqlite|mdns|lan|cache|replica)\b' features.md
   ```

   Rewrite any match unless it occurs inside an ordinary non-technical phrase
   whose replacement would be less clear. `track` is never an exception.
5. Confirm format with:

   ```sh
   rg -n -v '^(# Aro Features|$|- \*\*[^*]+\*\* — .+)$' features.md
   ```

   The command must return no lines.
6. Report the number of verified feature bullets and summarize any material
   capabilities deliberately excluded as unshipped or ambiguous.
