# Ties — the lookup slot

**Status:** implemented in 0.2.1.
**Relation to earlier specs:** extends `2026-09-16-ties-0.2-design.md` §3 (Sources) and §10
(Privacy). Where this document is silent, 0.2 binds.

## 1. The ask, and the answer

The 0.2 spec declined crowd-sourced "who is this number" services in one line: they are built by
uploading everybody's address book, and Ties does the opposite. The request came back sharper —
*there has to be a way to use that kind of database* — and it deserves a real answer rather than
the same refusal.

The answer is a **slot, not an integration**. Ties does not ship any vendor's database, does not
reverse-engineer any phone app's private API, and does not upload a single contact to earn access
to one. It ships the place where a service the user already has access to plugs in, and it treats
what comes back with the scepticism a crowd-sourced label deserves.

Three catalogue entries ship, across two backends:

- **Twilio Lookup** — documented, paid, consented. `caller_name` is CNAM, the same record a phone
  shows when it rings, and is United States only. `line_type_intelligence` answers worldwide.
- **Custom** — a URL template, a header, and two paths into the response. Anything with an HTTP
  endpoint and an API key, described by the user rather than coded by Ties.
- **GetContact** — the same backend with a **preset**: the mapping a tag-style reply needs
  (`result.tags[]` → `tag`, `count`, crowd-sourced) filled in, and the endpoint left empty. A
  preset is not an integration. It ships no URL and no token, and `isUsable` is false until the
  user supplies one, so choosing the row on its own calls nothing. It exists because the mapping
  is the tedious half and the access is the half only the user can hold.

Entries with `usesCustomEndpoint` keep their endpoint under `lookup.config.<id>`, one per service,
so choosing a second row never inherits the first one's URL. `CustomLookupProvider` carries the
catalogue id it is standing in for, so a result says which service answered.

## 2. Where it sits

A lookup is a `SourceCollector` with id `lookup`, so it runs inside the existing collection pass
beside Messages, WhatsApp and Mail, writes the same `LocalSignals`, and gets the same row and
switch. Three things make it the odd one out, and each is deliberate:

1. **It is off by default.** Every other source is read from this Mac; this one sends a phone
   number somewhere else. `SourcesModel.Source.defaultsOn` is false for it alone.
2. **It is absent from the wizard.** Setup shows the four local sources. A first run should not put
   "send your contacts' numbers to a service" in front of someone who came to read their own chats.
3. **Its status is `unavailable` until configured**, with the row's grey glyph reading "No lookup
   service set up yet" rather than "Not installed".

## 3. What an answer is worth

`LookupName.kind` decides, and it is the whole verification argument:

- `.registered` — the line is registered under this name (CNAM, a verified business record).
  Merged into `strongAliases`, which §4.2 of the 0.2 spec already defines as strong enough to admit
  a web profile.
- `.crowd` — other people saved the number under this name. Merged into `aliases` only. It becomes
  a "known as" chip and a search seed, and an honorific read out of it ("Dr Sara" → `dr`) feeds the
  profession rules. It never admits a profile on its own, because a crowd is confidently wrong
  about a common name as often as it is right, and a number two years old is labelled with whoever
  had it before.

Tags that canonicalise to an honorific become one; the rest become titles.

`carrier`, `lineType` and `nameMatch` are read and shown in the Try-a-number row, but not stored:
`LocalSignals` has no column for them and adding one is a migration this change does not need.

## 4. What a pass may spend

A lookup is billed per call and an address book is long. `LookupBudget` is one actor per pass and
enforces three rules:

- a cap the user sets (default 250, range 25–5000);
- one call per distinct number, however many contacts share it;
- at most two numbers per person — the first two cover a mobile and a work line.

A refused key **halts the whole pass** rather than being refused, and billed, once per remaining
person. That is the only lookup error that stops anything; everything else is recorded against that
person and the pass continues.

## 5. Privacy

The number is the only thing sent. Not the name, not the signals, not the address book. The key
lives in the Keychain under `lookup.<id>.secret`, never in `UserDefaults` and never in the URL.
Responses are never cached on disk (`bypassCache: true`): a cached answer about a phone number is a
stale answer that was paid for once.

The README's Privacy section names this as the third exception to "what Ties learns stays on this
Mac", alongside search seeds and the cloud-AI switch.

## 6. What is deliberately not here

- No bundled endpoint, token format or private API for any consumer caller-ID app.
- No upload of the user's address book in exchange for access to anyone's database.
- No email lookup yet: the two shipped backends answer about numbers, and `LookupQuery` carries an
  `email` field so a backend that answers about addresses needs no protocol change.
