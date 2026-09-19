# Ties — an MCP server, so an agent can ask who you know

**Status:** proposed, unimplemented. Targets 0.3.
**Relation to earlier specs:** extends `2026-09-16-ties-0.2-design.md` §10 (privacy) and §7 (AI).
This document adds the first way data leaves Ties on somebody else's initiative, so §5 here binds
tighter than anything above it.

## 1. The ask

Ties answers *who do I know that can help with X* — but only to a person typing into its own
search field. Meanwhile the user is in Claude Code planning a project, and the question that
matters is the same one: *who do I know who has shipped payments in Saudi*, *who can introduce me
to someone at this company*, *is there a designer in my network for this*.

An agent cannot ask, because the answer lives in a SQLite file it has never heard of. The ask is
an MCP server that exposes the network to agents, plus a skill that teaches an agent when the
question is worth asking at all.

## 2. Why this is cheap to build

Everything the server needs already exists and is already in the package, not the app target.

- **The search.** `SearchService.ask(_:limit:terms:)` is the exact query behind the main window's
  ask box: FTS5 over `profile_fts`, semantic search over `Profile.embedding`, fused by
  `RankFusion.rrf`. The server calls the same function. It does not reimplement search, and it
  cannot drift from what the app shows.
- **The embedder.** `NLContextualEmbedder` lives in `TiesCore/Search/Embedder.swift`, not in the
  app, so a second binary can build the identical query vectors.
- **Concurrent reads.** The store is a GRDB `DatabasePool`, which is WAL, so another process can
  read while the app writes. The server opens the file **read-only**, with a busy timeout, and a
  bug in it therefore cannot corrupt anything.

So the server is a new executable target in `TiesCore/Package.swift`, a few hundred lines of
stdio JSON-RPC, and a thin mapping from MCP tool calls onto store calls that are already tested.

One correctness trap is worth naming now. `AppModel` falls back from `NLContextualEmbedder` to
`HashEmbedder` when the on-device model will not load, and the comment beside it gets the reason
exactly right — *"a fallback can never leave searching and indexing on different vectors"*. A
second process makes that fallback invisible: the app may have indexed with one embedder while
the server queries with the other, and the semantic half of every answer becomes noise. The fix is
to write which embedder produced a vector next to the vector — an `embedderId` column beside
`Profile.embedding` — and have the server use that one or skip the semantic half and say so. This
is a small change to the schema and it should land before the server, not after.

## 3. The tools

Six, read-only, named for the question rather than the table:

| Tool | Answers |
| --- | --- |
| `find_people(query, limit)` | *Who do I know that can help with X* — `SearchService.ask`, with the matched phrases returned as the reason |
| `get_person(id)` | One person in full: occupation, summary, companies, skills, sources, last contact |
| `list_groups()` | The smart lists already built — Doctors, Founders, Engineers in Riyadh |
| `people_in_group(id)` | Who is in one |
| `recently_active(days)` | Who the user has actually talked to lately, strongest tie first |
| `suggest_for(description)` | A project or problem described in prose; returns the three or four people whose profiles answer it, each with what they can help with and why they matched |

`suggest_for` is the one that makes this worth building. It is `find_people` with the query
expansion 0.2 already ships (`QueryExpander` turns "help with taxes" into accountant, CPA, tax
advisor) run first, so an agent describing a project in a paragraph gets the same expansion a
person typing a question gets.

A seventh, `add_note(person_id, text)`, is the only write, and it is off unless the user turns it
on. An agent that noticed something worth remembering about a person should be able to leave it
where the user will see it — and notes are already user-owned prose (`Store.upsertNote`), so
nothing the agent writes can be mistaken for something the research found.

## 4. The skill

A server on its own gets used when an agent thinks to look. A skill is what makes it think to look.

`skills/ties/SKILL.md`, shipped in the repo and installable in one line, tells an agent:

- **When to ask.** The user is planning work and names a role, an expertise, a company, a city, or
  an introduction — *"I need someone who knows Stripe onboarding"*, *"who could review this
  contract"*, *"anyone in Dubai"*. Also when a project plan reaches a step no one in the room can
  do.
- **When not to.** Never on every message, never to pad an answer, and never for a task the agent
  can simply do itself. A network suggestion that arrives unasked, twice, stops being useful.
- **How to answer.** Name at most three people, each with one line of why — the skill or company
  that matched — and offer the intro rather than performing it. Never print a phone number or
  email unless the user asks for it in that turn; `get_person` returns them, and an agent pasting
  a friend's mobile into a shared terminal is the failure mode this rule exists to prevent.
- **What it is not.** Not a CRM, not a source of truth about people, and profiles are extracted
  from public pages and can be wrong — the fact check's `supported: false` is on every fact for a
  reason, and an agent should say "according to their GitHub" rather than stating it flat.

## 5. Privacy, which is the whole design

Every other feature in Ties reads the user's data on the user's instruction. This one hands it to
a program that acts on its own. The rules follow from that, and none of them are optional:

1. **Off by default**, like Lookup. Settings › Agents, one switch, with the address of the socket
   and a **Copy config** button for the agent's config file.
2. **Scoped, and the scope is visible.** Three levels, the middle one the default:
   - *Profiles only* — name, occupation, summary, companies, skills, sources. No channels, no
     recency, no notes.
   - *Profiles and relationship* — adds last contact and how often, so `recently_active` works.
   - *Everything* — adds phone numbers, emails and notes. The level an agent needs to actually
     send a message, and the one the user should have to choose deliberately.
   The scope is applied in the server, not requested by the client: an agent cannot ask for more
   than the switch grants.
3. **Message content never leaves.** Ties reads Messages, WhatsApp and Mail to build aliases,
   titles and recency. None of that raw text is in any tool's response at any scope. The server
   returns what `LocalSignals` *derived*, never what it read.
4. **One token per install**, generated by the app, required on every call, revocable from the
   same settings pane. The socket is a Unix domain socket in the app's container, not a TCP port:
   nothing off this Mac can reach it even by accident.
5. **An audit trail the user can read.** Every call logged with the tool, the query and the count
   of people returned — never the people. Settings › Agents shows the last hundred, and a button
   empties them. *Claude Code asked "who knows Stripe onboarding" — 3 people, 14:22* is the kind of
   line that makes this feature trustworthy instead of unsettling.
6. **Other people's data.** Everyone in this database is someone who did not agree to be in it.
   That is already true of the app, and true in a different way once a model reads it. The scope
   default, the no-raw-message rule and the skill's no-contact-details rule are the three places
   that limit gets enforced.

## 6. What this changes in the repo

- `TiesCore/Package.swift` — an `executableTarget` named `ties-mcp`.
- `TiesCore/Sources/ties-mcp/` *(new)* — stdio JSON-RPC, the tool schemas, the scope filter, the
  audit writer. No business logic: every tool is a call into `SearchService` or `Store`.
- `TiesCore/Store/Store+Profiles.swift`, `Migrations.swift` — `embedderId` beside the embedding
  (§2), and the audit table.
- `Ties/Main/SettingsView.swift` — the Agents pane: switch, scope, token, copy config, audit list.
- `skills/ties/SKILL.md` *(new)* — the skill.
- `README.md` — a section, written the way the Lookup one is: what it does, what it refuses to do.
- `docs/manual-test.md` — the server with the switch off, each scope, a revoked token, and the app
  writing while the server reads.

## 7. Shipping order

1. **`embedderId`.** A schema change that has to precede anything reading the index out of
   process, and a latent correctness bug worth closing regardless.
2. **The server, read-only, profiles-only scope, no token.** Enough to prove the shape against a
   real agent on the user's own Mac.
3. **Token, scopes, audit log, settings pane.** Everything in §5 lands before this is something
   anyone else should switch on.
4. **The skill, and `suggest_for`.** The part that makes an agent ask the question without being
   told to — worth doing once the answers it would get are already good.
