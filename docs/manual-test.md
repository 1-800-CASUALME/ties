# Manual test checklist

The things that can only be checked by a person, grouped by the screen they belong to. Walk the
whole list before tagging a release; walk the affected sections before opening a pull request.

**Before you start**

- [ ] `make test` passes and `make build` finishes with zero warnings.
- [ ] To test the wizard from scratch, reset state first:
      `defaults delete com.asim.ties` and
      `rm -rf ~/Library/Application\ Support/Ties` (this deletes the database — back it up first).
- [ ] `make run` launches the app.

## Welcome

- [ ] The window opens on Welcome with the app icon, title and the three Scan / Research / Find
      labels.
- [ ] The icon animates in at launch.
- [ ] Return advances to the next step.

## Access

- [ ] **Grant Access** shows the system contacts prompt.
- [ ] After granting, the contact count appears with a green checkmark.
- [ ] Back returns to Welcome with a reverse push animation.
- [ ] If access is denied: **Open System Settings** opens the Contacts privacy pane, and
      **Import .vcf…** imports a vCard file instead.

## Sources

- [ ] Four rows — Contacts, Messages, WhatsApp, Mail — each with the real app icon, a status glyph
      and a toggle. **Continue** is enabled even with every toggle off.
- [ ] Contacts is ready without any extra permission.
- [ ] Without Full Disk Access, Messages, WhatsApp and Mail show an orange lock and "Needs Full
      Disk Access", and **Open Privacy Settings** opens Privacy & Security › Full Disk Access.
- [ ] Granting it there and coming back turns those rows green (macOS may ask to quit and reopen
      Ties first); revoking it turns them back to the lock.
- [ ] With WhatsApp not installed, its row is a gray `minus.circle` and "Not installed", and its
      toggle changes nothing. Same for Mail on a Mac that has never opened Mail.
- [ ] A mailbox too big to scan without Spotlight shows the Mail row's error state rather than
      sitting on "ready" and finding nothing.
- [ ] The research screen names the source stages first ("Reading your chats with Sara…"), then
      the web ones. A source left off produces no stage of its own.
- [ ] Turning every source off still researches people, from the web alone.
- [ ] Settings › Sources shows the same four rows, and **Collect again** re-runs collection for
      everyone with a progress pill.
- [ ] Review rows show "Known as" chips: the nickname, the WhatsApp display name, or the name
      other people use for them in your chats, plus the honorific where one was used ("Dr", "د.").
      A `link` chip appears where a link the person shared themselves verified the candidate.
- [ ] The chips match what was collected:
      `sqlite3 ~/Library/Application\ Support/Ties/ties.sqlite 'select aliases,honorifics,titles,companies,sources from signal limit 5'`
- [ ] Nothing was written to a source: the modification dates of `~/Library/Messages/chat.db` and
      WhatsApp's `ChatStorage.sqlite` are unchanged after a full run.

## Select

- [ ] Rows are grouped under letter headers.
- [ ] Contacts with a photo show it; the rest show a monogram.
- [ ] Typing a name filters the list.
- [ ] Typing digits (for example `0501`) filters by phone number.
- [ ] **Select All** toggles every visible row and the footer count updates.
- [ ] Return advances only when at least one person is selected.

## Scan

Use 5–10 real contacts for this section.

- [ ] The progress caption names the person currently being researched and the completed/total
      count.
- [ ] Pause and resume work; cancel stops the run.
- [ ] Rows show a shimmering placeholder until that person is done, then a confidence pill.
- [ ] **Continue with partial results** appears once at least one person has finished.

## Review

- [ ] Each row shows a confidence pill, and a "2" badge where there is more than one candidate.
- [ ] The `info.circle` popover lists the pages found, with title, snippet and a working link.
- [ ] The refresh button re-runs the scan for that person only.
- [ ] People with at least one candidate are pre-selected for extraction.

## Candidate picker

- [ ] The sheet shows each candidate with an avatar, headline, company, location, confidence pill
      and evidence chips.
- [ ] Choosing one candidate marks the others rejected. Verify with:
      `sqlite3 ~/Library/Application\ Support/Ties/ties.sqlite 'select displayName,status,score from candidate'`
- [ ] **None of these** rejects all of them.

## Provider

- [ ] Every tile renders its logo, grouped by tier with dividers.
- [ ] Providers detected on this Mac show a green dot.
- [ ] Apple Intelligence is pre-selected when it is available on this Mac, otherwise Gemini.
- [ ] Entering a wrong Groq key and pressing Continue shows an inline error under the tile.
- [ ] A valid key (or an available on-device/CLI provider) validates and advances.

## Extract

- [ ] The progress caption advances through the selected people.
- [ ] Occupations fill into the rows as each profile arrives (checked with Apple Intelligence
      on-device).

## Done

- [ ] The three counts — profiles, unsure, nothing found — match what the run produced.
- [ ] **Review unsure** goes back to Review filtered to the unsure people.
- [ ] **Start searching** closes the wizard and opens the main window.

## Main window

- [ ] Three columns: sidebar, people list, detail.
- [ ] Typing in the search field filters the list as you type.
- [ ] `?growth`, or typing a question and pressing Return, ranks people by relevance with the
      matching phrases highlighted in the "why" line.
- [ ] Selecting a person shows the detail pane; the avatar animates between the row and the header.
- [ ] The sidebar filters (All, Researched, Unsure, Manual) each show the right people.

## Person detail

- [ ] **Call** opens FaceTime and **Message** opens Messages with the right number.
- [ ] **Mail** opens a new message to the right address.
- [ ] **Share** shows the system share picker with a vCard containing the researched note.
- [ ] Control-clicking an action with several phones or emails lists all of them.
- [ ] The Researched section shows can-help-with capsules, and the link icon on a fact opens its
      source page.
- [ ] A note typed in **Yours** is still there after quitting and relaunching.
- [ ] **Refresh** re-runs the scan and extraction for that person with a progress pill.

## AI

Needs a provider configured. Walk it once with Apple Intelligence on-device, then repeat the last
two checks with a cloud provider.

- [ ] Review: a `sparkle` chip with a one-line reason appears only on people with more than one
      candidate, or one weak one — never on a person whose candidate was accepted automatically.
- [ ] The chip picks; it does not accept. The row stays unsure until you choose in the candidate
      picker, where the same reason shows on the row the AI picked.
- [ ] The Review footer shows the judge's progress while it runs, and the screen stays usable.
- [ ] Sidebar: smart lists appear under a `sparkle` header after extraction, each with its own
      icon, and selecting one shows the people in it.
- [ ] The refresh button rebuilds the lists; a list of one person never appears.
- [ ] Ask: typing a question and pressing Return shows the expansion as chips under the field
      within about two seconds. With no provider, or a slow one, the search still runs on what you
      typed.
- [ ] Removing a chip re-runs the search without that term, and the results change.
- [ ] Person detail: **Draft** opens the popover, asks what you need, and comes back with a short
      message.
- [ ] **Messages** opens Messages with the right person and the text prefilled, **WhatsApp** opens
      WhatsApp with the text prefilled, **Mail** opens a new mail with the text in the body.
      Nothing is sent by Ties in any of the three.
- [ ] A fact the sources do not support has a dotted underline and a `questionmark.circle` help
      reading "Not found in the sources"; the supported facts are plain.
- [ ] Person detail: the Relationship row reads "Talked 3 weeks ago" with the right channel icon,
      and the strength bar matches how much you actually talk to that person.
- [ ] Sidebar: **Reconnect** lists people with a useful profile and no contact for three months,
      strongest tie first.
- [ ] Settings › Providers: "Let cloud AI see local signals" is off on a fresh install and the
      provider tile shows a closed lock; turning it on shows an open lock.
- [ ] With the switch off and a cloud provider selected, what the judge sends carries no collected
      signal — no alias, no honorific, no signature title or company — only the page snippets and
      what Apple Contacts holds. With it on, those four appear and nothing else does: no message
      text, no subject line, no phone number, no email address. (Check against a local
      OpenAI-compatible endpoint, or Ollama's request log, selected as a custom provider.)
- [ ] With Apple Intelligence selected, the signals are used whatever the switch says, and no
      request leaves the Mac.

## Add and edit

- [ ] **+** (or ⌘N) creates a manual person, who then appears under **Manual**.
- [ ] Editing a person saves the changed fields and they survive a relaunch.

## Settings

- [ ] General shows the database path and size; **Show in Finder** reveals it.
- [ ] **Export JSON…** writes a file that contains the people and their profiles.
- [ ] **Check for Updates…** reports up to date, or offers the newer release.
- [ ] Providers: changing the provider and key takes effect on the next research run.
- [ ] Research: switching the search backend (DuckDuckGo / Tavily / Exa) and saving keys works.
- [ ] **Add more contacts…** re-enters the wizard at the Select step.
- [ ] **Delete Everything** empties the list and brings back the wizard.

## Release build

- [ ] `scripts/build-dmg.sh` produces `build/Ties.dmg`.
- [ ] The DMG mounts and shows Ties next to an Applications shortcut.
- [ ] After dragging to Applications, the first launch needs right-click → Open (the build is
      unsigned), and the app then opens normally.
