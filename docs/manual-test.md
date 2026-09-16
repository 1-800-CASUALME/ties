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
