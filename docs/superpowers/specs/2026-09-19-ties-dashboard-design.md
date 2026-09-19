# Ties — the dashboard: a network you want to look at

**Status:** proposed, unimplemented. Targets 0.3.
**Relation to earlier specs:** extends `2026-09-16-ties-0.2-design.md` §9 (main window). Where
this document is silent, 0.2 binds.

## 1. The ask

The main window is three columns: a sidebar of smart lists, `PeopleListView` in the middle, and
`PersonDetailView` on the right. It is a competent address book, and it is the wrong shape for
what Ties actually produces.

Ties spends minutes per person and real money building something no address book has: an occupation,
a summary, the companies someone has worked at, what they can help with, and the sources that back
all of it. Then it renders that as a list row with a name and a subtitle, exactly like the Contacts
app that knows none of it. The value is invisible until you click a row, and then it is visible for
one person at a time.

The ask is a dashboard: pick between a **compact list** and a **gallery**, see the profile —
name, description, sources, companies, skills — on the card itself, act on it (call, message,
email, WhatsApp) without opening anything, scroll it like a feed, and take it full screen.

## 2. Two densities, one data source

A segmented control in the toolbar, remembered in `UserDefaults`, switching the middle of the
window between:

**Compact** — what exists today, tightened. One line per person: avatar, name, occupation,
company, a right-aligned last-contact stamp. For scanning a thousand people by name. The
alphabetical sections `ContactSectioner` already builds stay.

**Gallery** — a responsive grid of cards, three to five across depending on window width, each card
carrying the whole profile at a glance:

- the avatar, large, with the initials fallback `AvatarView` already draws;
- the name, and under it the occupation;
- two lines of the summary, truncated with a fade rather than an ellipsis;
- **companies** as chips, from `ProfileFacts.companies`;
- **skills** as chips, from `ProfileFacts.canHelpWith` — the field that answers "who do I know
  that can help with X", and the most useful thing on the card;
- **sources** as small favicons with a count — `PersonDetailView.sourceNames` already turns a host
  into a readable site name, so the logic exists and only needs a smaller presentation;
- a `ConfidencePill` when the match was not certain, and the dotted underline the fact check
  already gives an unsupported claim, so a card never over-claims;
- action buttons, revealed on hover.

The switch is presentational. Both densities take the same `[Person]`, `[String: Profile]` and
`[String: Candidate]` that `PeopleListView` is handed today, so search, smart lists and the ask
flow keep working across both without a second code path.

## 3. Actions on the card

`Ties/Main/Actions.swift` already routes `tel:`, `sms:`, `facetime:` and `mailto:` through macOS,
so the buttons are a presentation of something that works. Four circular buttons appear on hover,
each disabled — not hidden — when the person has no channel for it, because a button that vanishes
teaches nothing and a greyed one says "no number saved":

**Call** · **Message** · **Mail** · **WhatsApp**

WhatsApp is the one that does not exist yet and should. Ties already reads WhatsApp as a source and
already knows the person's number in E.164 in `Channel.normalized` — which is exactly the format
`https://wa.me/<number>` wants. It is a one-function addition to `Actions`, and it closes the loop
on the source that contributed the most local signal for most users.

A person with two numbers gets a menu on long-press, the way `PersonDetailView.menuTitle` already
labels them. **Draft** stays where it is, in the detail view, because it opens a popover and a
popover does not belong on a card in a grid.

## 4. The feed

A third mode, and the one worth building for its own sake: **Discover**, a single-column,
full-width vertical feed of large cards, one person at a time, scrolled like a timeline.

It is not the same people in a different width. A grid answers "show me everyone"; the feed
answers "who should I be thinking about". Its order is a mix of:

- people whose profile answers the question currently in the search field;
- **Reconnect** — already specified in 0.2 §7: people whose profile matches what you are looking
  for and whom you have not talked to in three months, strongest tie first;
- newly extracted people, so a scan that finishes has somewhere to be seen;
- people with an unresolved candidate, which is one swipe away from being fixed by the triage deck.

Each card is a screenful: the avatar large, the summary in full rather than truncated, all the
skills and companies, the sources as real rows with their titles, and the four actions at a size
meant for a pointer. Scrolling snaps card to card, so the feed has the rhythm the user asked for
rather than the drift of a long scroll view.

## 5. Full screen

`TiesApp` declares `.windowResizability(.contentSize)`
(`Ties/TiesApp.swift:12`). That ties the window's resizing to the content's own size limits, which
is the wrong constraint for a window that should be able to fill a display — full screen and a
content-sized window are in direct tension, and a grid that cannot grow past its content's ideal
width wastes every pixel of a large monitor.

The change is small and deliberate: `.contentMinSize`, so the window keeps a sensible floor and is
free above it. Then the gallery's column count becomes a function of width — three columns at
1000pt, five at 1800 — and full screen means more people, not bigger whitespace.

Full screen also earns a presentation mode worth having: **⌃⌘F** with the sidebar and search
hidden, which is the feed, alone, on the whole display.

## 6. Motion, in the amount that helps

Animation should make a change legible, not perform. Ties already animates deliberately —
`ContactListView` uses `.animation(.snappy, value: filtered.map(\.id))`, and the wizard's icon
animates in at launch. The dashboard follows the same restraint:

- **Density switch** — cards `matchedGeometryEffect` between list row and grid card, so a person
  visibly becomes their card rather than the whole view being replaced.
- **Filtering and asking** — the existing `.snappy` on the id list; cards that survive a filter
  move, cards that do not fade.
- **Hover** — a card lifts two points with a softened shadow, 120 ms. Buttons fade in over it.
- **Arrival** — a card whose profile was just extracted fades in with the sparkle, once. This is
  the only animation that exists to be noticed, and it marks the moment the app did its work.
- **Feed** — snap paging with the system's own scroll physics, plus a one-frame parallax on the
  avatar. Nothing that moves when the user is not moving it.

`prefers-reduced-motion` is not a suggestion: with **Reduce Motion** on in System Settings, every
one of these becomes a cross-fade or nothing at all.

## 7. What this changes in the repo

- `Ties/Main/MainWindow.swift` — the density control, the mode, `UserDefaults` for both.
- `Ties/Main/GalleryView.swift` *(new)* — the responsive grid.
- `Ties/Main/FeedView.swift` *(new)* — the snapping single-column feed and its ordering.
- `Ties/Components/PersonCard.swift` *(new)* — one card, three sizes; the piece both new views and
  the triage deck draw.
- `Ties/Components/SkillChips.swift` *(new)* — `canHelpWith` and companies as chips; the sibling of
  `KnownAsChips`.
- `Ties/Main/Actions.swift` — `whatsapp(_:)` over `wa.me` and the normalized number.
- `Ties/TiesApp.swift` — `.contentMinSize`, and the full-screen command.
- `TiesCore/Store/Store+People.swift` — one query that returns people with their profile and best
  candidate together; a grid that renders a hundred cards must not make three calls per card.
- `docs/manual-test.md` — both densities, a card with no profile yet, a person with no phone, the
  feed at 1000pt and full screen, and every animation with Reduce Motion on.

## 8. Privacy

Nothing new is read, fetched or sent. Every field on a card is already in the local database and
already shown in the detail view; this document only changes how many of them can be seen at once.
One consequence is worth naming: a gallery shows more people per screenshot than a list does, so
the full-screen presentation mode is also the mode most likely to end up in one. That is the user's
call to make, and no reason to keep the profile hidden from its owner.

## 9. Shipping order

1. **`PersonCard` and the gallery.** The change that makes the research visible, and the component
   the triage deck reuses.
2. **Actions on the card, WhatsApp included.** Small, and it is what turns looking into doing.
3. **`.contentMinSize` and responsive columns.** Two lines, and full screen starts paying.
4. **The feed.** The most new design and the least certain; worth building last, on top of a card
   that has already proven itself in the grid.
