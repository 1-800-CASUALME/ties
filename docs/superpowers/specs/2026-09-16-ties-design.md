# Ties — Design Spec

**Date:** 2026-09-16
**Status:** Approved by Asim (name, macOS 15 minimum, no Developer ID, no Python sidecar)
**Repo:** `~/ties` → GitHub (MIT)

## 1. Purpose

Ties is an open-source, native macOS app that turns your Apple Contacts into a searchable network. It reads your contacts, researches each person on the public web, builds a profile (occupation, companies, achievements, certificates, experience, "can help with" tags), and lets you ask "who do I know that can help with X?". Results are people you can call, message, or share with one click.

Everything stays on the Mac: one SQLite file, no server, no account. Research requests go from the user's own IP straight to public endpoints or to an AI provider the user chose.

## 2. Non-goals (v1)

- No LinkedIn page fetching or session-cookie use. LinkedIn data comes only from search-engine snippets.
- No Python sidecar, no bundled OSINT tools. 100% Swift.
- No Mail/Calendar/iMessage ingestion.
- No writing back to Apple Contacts.
- No cloud sync, no public profiles, no telemetry.
- No App Store build. Distribution is a GitHub Release DMG (unsigned, since there is no Developer ID) plus a Homebrew tap.

## 3. Platform and stack

| Concern | Decision |
|---|---|
| Language / UI | Swift 6, SwiftUI, AppKit only where SwiftUI lacks a control |
| Minimum OS | macOS 15 Sequoia. Foundation Models used only when `#available(macOS 26)` and `SystemLanguageModel.default.availability == .available` |
| Project | Xcode project generated from an `xcodegen` spec (`project.yml`) so the repo has no binary `.pbxproj` churn; SPM for dependencies |
| Storage | GRDB 7 (SQLite) with FTS5 for keyword search; embedding vectors stored as BLOB |
| Semantic search | `NLContextualEmbedding` (macOS 14+) mean-pooled per profile; cosine over all rows in memory |
| HTML parsing | SwiftSoup |
| Networking | `URLSession` with a browser-like User-Agent, per-host throttle, disk cache |
| Web search | Off-screen `WKWebView` loading DuckDuckGo (default, keyless). Verified 2026-09-16: bare `URLSession` requests to DuckDuckGo, Brave and Mojeek get bot challenges or 403, Bing returns junk; a real WebKit view returns full results on the first try. Optional keyed backends: Tavily, Exa |
| Phone parsing | `PhoneNumberKit` for E.164 normalisation and digit search |
| Secrets | API keys in the login Keychain via `Security` framework, never in the DB |
| Updates | No Sparkle (needs a signing identity to be safe). "Check for Updates…" compares the running version with the latest GitHub release tag and opens the release page |
| Dependencies | Exactly three: GRDB.swift 7.11, SwiftSoup 2.13, PhoneNumberKit 4.3 |
| Sandbox | **Off.** Hardened runtime on. Entitlements: `com.apple.security.personal-information.addressbook`, `com.apple.security.network.client`. Sandbox off is required to run `claude`, `codex`, `gemini` CLIs and to detect local runners |
| Signing | Ad-hoc (`-`) signature. README documents "right-click → Open" on first launch. If a Developer ID appears later, only `project.yml` and the release workflow change |
| Preferences | `@AppStorage` |
| Tests | XCTest via `swift test` for the core package; UI tested manually |

### Package layout

```
ties/
├── project.yml                  # xcodegen
├── Ties/                        # app target (SwiftUI)
│   ├── TiesApp.swift
│   ├── Onboarding/              # wizard screens
│   ├── Main/                    # three-column app
│   ├── Components/              # reusable views: ContactRow, Avatar, LogoTile, ProgressCaption…
│   └── Resources/               # Assets.xcassets, ProviderLogos/, LOGOS-LICENSE.md, wmn-data.json
├── TiesCore/                    # SPM package, no UI, fully testable
│   ├── Sources/TiesCore/
│   │   ├── Contacts/            # ContactsService (CNContactStore wrapper)
│   │   ├── Store/               # GRDB schema, migrations, repositories
│   │   ├── Research/            # Scanner pipeline, probes, scoring
│   │   ├── Providers/           # AI provider catalogue + clients
│   │   ├── Search/              # FTS + embeddings + fusion
│   │   └── Model/               # Person, Profile, Candidate, Evidence, ProviderSpec…
│   └── Tests/TiesCoreTests/
├── docs/
├── scripts/                     # build-dmg.sh, fetch-logos.sh
└── .github/workflows/           # ci.yml (build + test), release.yml (DMG + appcast)
```

## 4. Data model

All tables in one SQLite file at `~/Library/Application Support/Ties/ties.sqlite`.

```
person
  id            TEXT PK          -- UUID
  cnIdentifier  TEXT UNIQUE NULL -- CNContact.identifier; NULL for manually added people
  givenName, familyName, displayName TEXT
  organization, jobTitle TEXT NULL   -- as stored in Contacts
  thumbnail     BLOB NULL
  createdAt, updatedAt REAL
  source        TEXT             -- 'contacts' | 'manual'

person_channel                    -- phones, emails, urls copied from Contacts (read-only mirror)
  personId, kind ('phone'|'email'|'url'), label, value, normalized  -- E.164 / lowercase

candidate                         -- one possible online identity for a person
  id TEXT PK, personId, score REAL, status ('auto'|'pending'|'accepted'|'rejected')
  displayName, headline, avatarURL, primaryURL TEXT NULL

evidence                          -- why a candidate scored what it did
  id, candidateId, kind ('email_hash'|'phone'|'company'|'location'|'name'|'username'|'avatar'|'conflict')
  weight REAL, detail TEXT, sourceURL TEXT NULL

source_page                       -- fetched/collected text per candidate
  id, candidateId, url, title, snippet, bodyText, fetchedAt, kind ('gravatar'|'github'|'serp'|'page'|'username')

profile                           -- AI-extracted, one per person
  personId PK, facts JSON (ProfileFacts: occupation, summary, companies[], achievements[],
  certificates[], experience[], canHelpWith[]), confidence REAL, providerId, model, extractedAt
  embedding BLOB NULL             -- [Float32] little-endian

profile_fts (FTS5, contentless)   -- personId UNINDEXED, content TEXT
                                  -- content = displayName + organization + jobTitle + every ProfileFacts
                                  -- string + note body; rewritten by Store whenever profile or note changes

note                              -- user-written, per person, Markdown
  personId PK, body, updatedAt

provider_config
  id TEXT PK, enabled INT, baseURL, model, extraHeaders JSON  -- apiKey lives in Keychain under "Ties.<id>"

job                               -- research jobs for progress/resume
  id, kind ('scan'|'extract'), personId, state ('queued'|'running'|'done'|'failed'|'skipped'), error, updatedAt
```

Rules:
- Contacts data is a read-only mirror. Re-sync replaces `person` rows by `cnIdentifier` and never touches `profile`, `note`, `candidate`.
- Deleting a person deletes everything under it. "Delete Everything" removes the DB file and Keychain items.
- Every AI-extracted fact keeps the `source_page` ids it came from (stored inside the JSON arrays as `{ "text": ..., "sources": [ids] }`).

## 5. Setup wizard

A single `NavigationStack` inside a fixed 720×520 window, driven by `@Observable WizardState`. One primary button per screen, Return advances, Esc = skip where allowed. Transitions use `.transition(.push(from: .trailing))` with `.snappy` animation. Progress dots at the bottom. No body text longer than one sentence; icons (SF Symbols) carry meaning.

| # | Screen | Content | Advance when |
|---|---|---|---|
| 1 | Welcome | App icon (animated scale-in), name, one sentence, three icon rows (Scan · Research · Find) | Continue |
| 2 | Access | `person.crop.circle.badge.checkmark` icon, one sentence why, **Grant Access** triggers `CNContactStore.requestAccess`. On grant: live checkmark and "1,284 contacts". On deny: link to System Settings and "Import .vcf instead" | Granted or .vcf imported |
| 3 | Select | Contacts.app-style list: search field (name or digits), letter section headers, 40pt round photos/monograms, checkbox per row, **Select All** toggle, live count in the button ("Research 312") | ≥1 selected |
| 4 | Scan | No AI. Determinate `ProgressView` captioned "Researching Sara Ahmed · 143 of 312", Pause / Cancel, rows fill in below as they finish (skeleton → filled) | Scan finishes or user taps Continue with partial results |
| 5 | Review | List: photo · name · occupation (from best candidate) · confidence pill. Trailing icon buttons: `info.circle` (show collected), `arrow.clockwise` (research again), `person.crop.circle.badge.questionmark` (choose candidate). Rows with >1 candidate show a badge count; tapping opens the candidate picker (sheet) with evidence chips. Multi-select checkboxes for who goes to AI step | Continue |
| 6 | AI provider | Logo grid (`LazyVGrid`, 80pt tiles, logo only, name on hover/selection). Order in §7. Detected local/CLI providers show a green dot. Selecting a cloud provider reveals one masked key field + "Get a key ↗" link; inline validation call. Apple on-device is preselected if available | Provider validated |
| 7 | Extract | Same progress UI as Scan. Runs the provider per person and writes `profile` | Done |
| 8 | Done | "612 profiles · 88 unsure · 200 nothing found" with **Review unsure** and **Start searching** | Opens main window |

The wizard is re-runnable from Settings ("Add more contacts…") starting at screen 3.

## 6. Research pipeline (no AI)

Run by `Scanner` as a `TaskGroup` with concurrency 4, per-host throttles, and a disk cache keyed by URL for 7 days. Every probe is a `struct` conforming to `Probe` (`func run(_ person: Person) async throws -> [ProbeResult]`).

Order per person:

1. **Identity probes (exact, keyless)**
   - Gravatar Profiles API: `GET https://api.gravatar.com/v3/profiles/{sha256(email)}` → name, job title, company, location, verified accounts, avatar. Unauth limit 100/h; optional key in Settings.
   - GitHub: `GET /search/commits?q=author-email:{email}` → login; `GET /users/{login}` → name, company, blog, location. Unauth 60/h (search 10/min); optional PAT in Settings.
   - Each hit becomes a candidate with `email_hash` evidence, weight high enough to auto-accept if nothing conflicts.
2. **Search snippets** through a `SearchBackend` protocol. Default `WebKitSearchBackend`: one off-screen `WKWebView` (main actor, serial, 2.5 s spacing, 25 s timeout) loads `https://duckduckgo.com/?ia=web&q=…` and reads `[data-testid="result"]` rows (`a[data-testid="result-title-a"]` for URL/title, `[data-result="snippet"]` for snippet) with `evaluateJavaScript`, polling once a second until rows exist. If a bot challenge appears (no rows after 12 polls) the backend pauses 5 minutes and reports "Waiting for DuckDuckGo…". Optional keyed backends `TavilySearchBackend` (`POST https://api.tavily.com/search`) and `ExaSearchBackend` (`POST https://api.exa.ai/search`). Queries:
   - `"First Last" "Company"` (if company known)
   - `"First Last" site:linkedin.com/in`
   - `"First Last" site:github.com`, `site:x.com`, `site:twitter.com`
   - `"First Last"` plain (only if name has ≥2 tokens)
   Parse `a.result__a` (title, URL) and `.result__snippet`. LinkedIn results are stored as snippet-only candidates; never fetched.
3. **Username enumeration** (WhatsMyName `wmn-data.json`, bundled, refreshed by `scripts/fetch-wmn.sh`): usernames derived from email local-parts, URL fields in the contact, and `first.last`/`firstlast`/`flast`. Only sites in the dataset's "professional/social" categories; ≤40 sites per user, 2 concurrent. A hit is verified by fetching the page `<title>`/`og:title` and requiring a fuzzy name match ≥0.8.
4. **Page fetch** for non-LinkedIn candidate URLs (personal site, GitHub, company bio): `URLSession` + SwiftSoup, keep readable text (`<main>`, `<article>`, `<p>` ≥ 40 chars), cap 20 KB per page, require an `NLTagger` personal-name hit matching the contact.

**Scoring** (Fellegi–Sunter style, additive, thresholds `auto ≥ 6`, `pending 2..6`, `discard < 2`):

| Evidence | Weight |
|---|---|
| Email hash match (Gravatar / GitHub commit email) | +8 |
| Phone in E.164 found on page | +6 |
| Company/organisation Jaro-Winkler ≥ 0.9 | +3 |
| Location matches contact city | +1.5 |
| Same avatar perceptual hash on ≥2 sites | +2 |
| Username reused on ≥2 sites | +1.5 |
| Name similarity ≥ 0.8 | gate (required), +0 |
| Conflicting company or location | −3 |

Candidates ranked by score. One `auto` candidate → accepted. Several above threshold or none → `pending`, user picks. Evidence rows are shown as chips in the picker ("Same email", "Works at Acme", "Different city").

## 7. AI providers

`protocol AIProvider { func extract(_ input: ExtractionInput) async throws -> ProfileFacts }` where `ExtractionInput` is the person's Contacts fields plus the concatenated source pages, and `ProfileFacts` is a fixed `Codable` schema (occupation, summary ≤2 sentences, companies[], achievements[], certificates[], experience[], canHelpWith[] ≤8 tags). Every provider must return that schema; the app never shows free text.

Chunking: source text is split into ≤2,500-token chunks; each chunk produces a partial `ProfileFacts`; a final merge call de-duplicates. Apple on-device uses a fresh `LanguageModelSession` per chunk with a `@Generable` mirror of the schema; HTTP providers use JSON-schema `response_format`; CLIs use `--json-schema` (Claude) or `--output-schema` (Codex) or prompt-only JSON (Gemini CLI).

`ProviderSpec` catalogue (static, ships in the app):

```swift
// Gemini, Groq, OpenRouter, Mistral, DeepSeek, xAI, Perplexity, Fireworks, Together, Cloudflare,
// Hugging Face, SambaNova, Ollama (/v1), LM Studio, llama.cpp, MLX, Jan and GPT4All all speak the
// OpenAI chat-completions protocol, so one client covers them. Anthropic has its own; the three CLIs
// shell out; Apple is in-process.
enum Transport { case appleFoundation, openAIChat, anthropic, claudeCLI, codexCLI, geminiCLI }
enum Tier { case onDevice, freeCloud, cli, local, paidCloud, custom }
struct ProviderSpec: Identifiable {
  let id: String; let name: String; let logo: String; let transport: Transport; let tier: Tier
  let defaultBaseURL: URL?; let defaultModel: String?; let apiKeyURL: URL?
  let detect: Detect?   // .appBundle("Ollama.app") | .executable("claude") | .http(URL) | .appleIntelligence
  let supportsJSONSchema: Bool
}
```

Picker order: Apple on-device · Google Gemini (AI Studio) · Groq · OpenRouter · Claude Code · Codex CLI · Gemini CLI · Ollama · LM Studio · llama.cpp · MLX · Jan · GPT4All · OpenAI · Anthropic · Perplexity · xAI · Mistral · DeepSeek · Cohere · Fireworks · Together · Cloudflare Workers AI · Hugging Face · SambaNova · Custom OpenAI-compatible.

Detection rules: CLIs via `/bin/zsh -lc 'command -v <bin>'` plus `~/.claude/local/claude`, `~/.local/bin`; local runners via app bundle in `/Applications` and a `GET /v1/models` (or `/api/tags`, `/health`) probe with 1 s timeout.

Logos: SVG/PNG from `lobehub/icons-static-svg` and `simple-icons` in `Ties/Resources/ProviderLogos/`, with `LOGOS-LICENSE.md` stating they are trademarks used nominatively and excluded from the MIT grant. Never recoloured.

## 8. Main app

`NavigationSplitView` in a resizable window (min 900×560):

- **Sidebar**: All People, Researched, Unsure, Manual, then Smart Lists (saved searches). Bottom: gear → Settings.
- **List column**: search field in the toolbar (placeholder "Search or ask…"). Typing filters by name/company/phone digits instantly. Return, or a leading `?`, runs a "who can help" query. Letter section headers when unfiltered; ranked results with a one-line highlighted "why" when querying. `+` button bottom-left (New Person). Rows: 40pt photo · name · occupation grey.
- **Detail**: 96pt photo, name, occupation · company, confidence pill and "Sources" text. Pill actions: Message (`sms:`/`imessage:`), Call (`tel:`), FaceTime (`facetime:`), Mail (`mailto:`), Share (`ShareLink` with vCard + profile summary). Sections: Contacts fields (read-only), Researched (Can help with chips, summary with source dots, Work / Education / Achievements / Certificates disclosure groups, each fact with a link icon to its source), Yours (Notes Markdown, tags). Bottom-right: Refresh (re-run scan+extract), Edit (inline edit of researched fields and manual people). Header icon `person.crop.circle.badge.questionmark` opens the candidate picker.
- **Search ranking**: FTS5 BM25 over `profile_fts` and cosine over `embedding`, fused by reciprocal rank fusion (k=60). Top 50 shown. Optional Settings toggle "Let AI re-rank top 10 with a reason" (off by default, keeps search instant).
- **Settings** (`Settings` scene, tabs): General (database path, size, Export JSON, Delete Everything, Check for Updates…), Providers (same grid + keys), Research (search backend picker, optional Gravatar/GitHub/Exa/Tavily keys).

Animations: `.snappy` for list changes, `matchedGeometryEffect` for photo from row to detail, symbol effects (`.bounce`) on grant/success, skeleton shimmer while rows fill.

## 9. Error handling

- Every probe failure is per-person and non-fatal: logged to `job.error`, the person shows a warning icon with "Research again".
- Rate limits (HTTP 429/202 from DDG) pause that host with exponential backoff up to 5 min; the progress caption shows "Waiting for DuckDuckGo…".
- Provider errors (bad key, offline runner) surface inline on the provider tile and block Continue until fixed or another provider is chosen.
- Contacts access denied: wizard offers `.vcf` import (`CNContactVCardSerialization`).
- Foundation Models `exceededContextWindowSize`: halve the chunk and retry once.
- The app is usable at any time; scan/extract run in the background with a menu-bar-free in-window progress pill.

## 10. Privacy stance (shipped in README and Welcome → Privacy link)

Everything lives in one SQLite file in `~/Library/Application Support/Ties`. Ties never uploads your address book. Research goes straight from this Mac to public endpoints; during extraction, one person's name, company, title and email addresses are sent to the AI provider you chose with your own key — or stay on this Mac with Apple Intelligence. Any person, fact, or the whole database can be deleted instantly. Ties prefers official APIs and search snippets, fetches public pages one at a time, never logs in anywhere, and never writes to Apple Contacts.

## 11. Testing

- `TiesCore` unit tests: scoring (weights, thresholds, conflicts), name/company similarity, username derivation, DDG HTML parsing (fixture files), Gravatar/GitHub response decoding (fixtures), chunking, `ProfileFacts` merge, RRF fusion, FTS queries against an in-memory GRDB.
- Provider clients tested against a `URLProtocol` stub; CLI providers tested with a fake executable on PATH.
- CI (`ci.yml`, `macos-15` runner): `xcodegen`, `xcodebuild build`, `swift test` for TiesCore.
- Manual checklist for the wizard and main window in `docs/manual-test.md`.

## 12. Distribution

`release.yml` on tag `v*`: xcodegen → `xcodebuild archive` (ad-hoc sign) → `hdiutil` DMG → GitHub Release with `Ties.dmg`. README explains: download the DMG, drag to Applications, right-click → Open once (unsigned build). A Homebrew tap (`1-800-casualme/homebrew-ties`) is a follow-up once the first release exists.

## 13. Build order (milestones)

1. Project skeleton, xcodegen, TiesCore package, CI green.
2. Contacts service + Select screen (list, sections, search, select all).
3. GRDB store, migrations, mirror sync.
4. Scanner: probes, scoring, candidate picker, Scan + Review screens.
5. Provider catalogue, detection, Apple on-device + OpenAI-compatible + Claude CLI clients, provider screen, Extract screen.
6. Main window: three columns, search fusion, actions, add/edit, settings.
7. Release pipeline, README, logos, update check.
