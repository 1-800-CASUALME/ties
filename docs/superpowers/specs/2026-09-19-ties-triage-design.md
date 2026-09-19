# Ties — triage: picking people, fast

**Status:** proposed, unimplemented. Targets 0.3.
**Relation to earlier specs:** extends `2026-09-16-ties-0.2-design.md` §2 (setup), §3 (Sources)
and §6 (candidates), and `2026-09-17-ties-lookup-slot-design.md` where it touches cost. Where
this document is silent, 0.2 binds.

## 1. The ask

Two screens in Ties ask the user to pick, and both of them ask badly.

**Select** (`Ties/Onboarding/SelectView.swift`) hands over every contact on the Mac as one
alphabetical list with a search field and a Select All checkbox. An address book of two thousand
rows — most of them a delivery driver, a landlord from 2019, three cards for the same cousin —
is a wall. The honest options are *scroll for twenty minutes* or *select all and pay for the
whole thing*. Research is billed in seconds per person and, with Lookup or a cloud provider
switched on, in money per person, so Select All is the expensive answer and the one everybody
picks.

**Review** (`Ties/Onboarding/CandidatePickerSheet.swift`) shows every identity the research
turned up for one person as a vertical list of rows, each with a Choose button, behind a sheet
the user has to open per person. Confirming forty ambiguous people is forty sheet openings, forty
scrolls, forty aimed clicks.

The ask is: make picking fast, drop the duplicates, drop the people there has never been any
contact with, and let the ambiguous ones be judged one card at a time — *left is not them, right
is them* — instead of by aiming at rows.

## 2. Why it cannot just be a better list

The data that would make Select smart does not exist yet when Select is drawn.

`SignalCollector.run(personIds:)` — the pass that reads Messages, WhatsApp and Mail and fills
`LocalSignals.lastContact`, `.interactions`, `.emails` — is started by the **Scan** step, on the
people the user has already chosen (`Ties/Onboarding/ScanView.swift:275`). At Select time the app
knows a name, maybe an organization, and the channels on the card. It does not know who the user
actually talks to. That ordering is the whole problem: the one fact that would let Ties pre-select
for you arrives one screen too late.

Duplicates have a matching gap. `ContactSync.sync` upserts one `Person` per `CNContact`, keyed by
`cnIdentifier`. Two cards for the same human — the work address book and the personal one, a
vCard import beside the iCloud card — are two people, researched twice, billed twice, and shown
twice forever after. Nothing in the store groups them; `CandidateGrouper` does exactly this kind
of union-find over *findings*, and nothing does it over *people*.

So triage needs three things: an earlier pass, a group, and a deck.

## 3. The triage pass

A new, cheap, local-only pass that runs between **Sources** and **Select**, over every imported
person, and collects two numbers and nothing else: **when did we last talk** and **how many times
in the last year**, per channel kind.

It is the existing collectors in a cheaper mode. `MessagesCollector`, `WhatsAppCollector` and
`MailCollector` already open a temporary read-only copy of each store and walk it; the triage mode
asks them for recency and counts only — no message bodies, no aliases, no honorifics, no link
extraction, no 500-message window. A `SourceCollector.triage(personIds:)` alongside `collect`,
returning `(lastContact, interactions, kinds)`, keeps the file handling and the Full Disk Access
rules exactly where they already are.

Budget: it must finish in a few seconds for a few thousand contacts, because it sits in front of a
screen the user is waiting on. Two properties make that reachable — it is one indexed sweep per
store rather than per person, and it never fetches anything. If a source is off, or Full Disk
Access was refused, triage simply has less to say and the screen degrades to what §4 calls Thin
and Unknown.

Nothing leaves the Mac. No provider is called. No number is looked up. Triage is strictly cheaper
than the pass that already runs, and it replaces part of it: the Scan step's signal pass reuses
what triage already wrote rather than reading the stores twice.

## 4. Select, rebuilt as tiers

With recency in hand, Select stops being an alphabet and becomes four tiers, strongest first,
each a collapsible section with a count and a single checkbox:

| Tier | Who is in it | Ships |
| --- | --- | --- |
| **Close** | Talked within 90 days, or 10+ interactions in the last year. | Selected |
| **Known** | Some contact ever, or a card rich enough to research (email plus employer). | Selected |
| **Silent** | A real card with channels, but no message, mail or WhatsApp ever, in either direction. | Off, collapsed |
| **Thin** | Nothing to go on: no email, no messageable number, no employer — a name and a landline. | Off, collapsed |

The thresholds are defaults, not law: a stepper reading *"talked in the last ⟨90⟩ days"* and a
switch for *"include people I've never talked to"* sit above the list, and the tiers redraw live.
Somebody researching a network they have deliberately never messaged — a conference list, a
board — switches Silent on in one click and is no worse off than today.

The button keeps counting what it will do, and gains what it will cost: **Research 214** with,
underneath, *about 20 minutes, 214 lookups* when Lookup is configured. Cost is the reason this
screen exists; hiding it would be strange.

Order inside a tier is strongest tie first, not alphabetical. The search field stays and searches
across all four tiers, because someone looking for one name should not have to know which tier
they landed in.

## 5. Duplicates

A `person_group` table — group id, person id, and how the two were joined — and one rule applied
before Select is drawn: union-find over people, where two people join when they share a
normalized phone (already stored as E.164 in `Channel.normalized`), a normalized email, or an
identical display name *and* a matching organization. Name alone never joins: two Mohammeds are
not one person, and the cost of a wrong merge is worse than the cost of a missed one.

In Select, a group is one row with a **3 cards** chip. Tapping it opens the group in the deck
(§6), where each pair is confirmed or split individually, so the automatic join is a proposal and
never a fact.

Grouping is **display and scheduling only**. Research runs once per group against the union of the
group's channels, the profile is written to the group's primary person, and the other cards point
at it. Apple Contacts is never touched: Ties does not write to the address book, and a merge that
edited the user's real cards would be exactly the kind of thing this app promises not to do. The
group can be split again at any time, and splitting restores two ordinary people.

The saving is immediate and is the cheapest kind: a network where one person in twelve is
duplicated researches, extracts and looks up eight percent fewer people for the same result.

## 6. The deck

The Review step, and the duplicate confirmations, and anything else that is a yes/no about one
person at a time, become one component: a **deck** of cards, one card filling the screen,
answered with the left and right halves of the keyboard.

A card carries what a decision actually needs, at a size that can be read without leaning in: the
avatar large, the name, the headline, company and location, the `ConfidencePill` the rows already
draw, up to four `EvidenceChip`s with conflicts first (the ordering `CandidatePickerSheet`
already gets right), and the Judge's line as a `SparkleChip` when the provider had an opinion. The
profile link is one click, and opens in the browser without losing the card.

Answers:

- **→ / click right** — that's them. Accepts, rejects the others in the group, next card.
- **← / click left** — not them. Rejects this candidate and, if it was the last plausible one,
  the person falls through to *none of these*.
- **↓ / space** — skip; the card returns at the end of the deck.
- **⌘Z** — undo, up to the last ten answers, because a swipe that went the wrong way is the one
  thing that makes people distrust a deck.

Order is by how much the answer is worth: people with two close-scoring candidates first (the
ambiguity the user is uniquely able to resolve), people with one weak candidate last, people the
scorer already accepted not in the deck at all. A progress counter reads **12 of 48** and the deck
can be left at any point — every answer is written as it is given, exactly as the sheet writes
today via `setCandidateStatus`.

The deck is a presentation of the same store calls the sheet already makes. The existing sheet
stays for the one-off case of re-opening a single person from the main window; the deck is what
setup uses, and what the **Review all** button in the main window opens.

## 7. What this changes in the repo

- `TiesCore/Signals/SourceCollector.swift` — a `triage` mode beside `collect`.
- `TiesCore/Signals/{Messages,WhatsApp,Mail}Collector.swift` — recency and counts without bodies.
- `TiesCore/Contacts/PersonGrouper.swift` *(new)* — union-find over people; the sibling of
  `Research/CandidateGrouper.swift`, which is the model to copy.
- `TiesCore/Store/Migrations.swift`, `Store+People.swift` — `person_group`, and grouped reads.
- `TiesCore/Contacts/Tiering.swift` *(new)* — the four tiers, pure and tested, no UI.
- `Ties/Onboarding/SelectView.swift` — tiers, thresholds, cost estimate.
- `Ties/Onboarding/ReviewView.swift`, `Ties/Components/CardDeck.swift` *(new)* — the deck.
- `docs/manual-test.md` — triage timing, a tier with Full Disk Access refused, an undone swipe.

Tiering and grouping are pure functions over records: both belong in `TiesCore` with Swift Testing
tests next to them, and the SwiftUI layer stays thin, as `CONTRIBUTING` asks.

## 8. Privacy

Triage reads strictly less than the pass that already runs, from the same temporary read-only
copies, and sends nothing anywhere. `lastContact` and `interactions` are already the fields
`LocalSignals.publicSafe` strips before anything reaches a provider or a search query, and tiering
never widens that: a tier is computed on this Mac and is never part of a prompt. Grouping compares
normalized channels locally and writes a row of ids. Apple Contacts stays read-only.

## 9. Shipping order

1. **Tiers without triage.** The four tiers computed from the card alone — Thin is already
   decidable, and Select stops being a wall. Cheap, no new pass, no migration.
2. **Duplicate grouping.** The biggest saving per line of code, and the one users notice first.
3. **The triage pass.** Close and Silent become real, and the Scan step's signal pass gets
   cheaper by reusing what triage wrote.
4. **The deck.** Replaces Review, absorbs the duplicate confirmations, and earns the ⌘Z.

Each step is shippable on its own, and each one makes the next cheaper to run.
