# Ties

[![CI](https://github.com/1-800-CASUALME/ties/actions/workflows/ci.yml/badge.svg)](https://github.com/1-800-CASUALME/ties/actions/workflows/ci.yml)

Ties turns your Mac's address book into a network you can actually ask questions of.
A setup wizard researches each contact from public sources — no AI involved — and then an AI
provider of your choice reads what it found and writes a short profile for each person.
After that you search in plain language: *"who do I know that can help with X"*.

Native macOS 15+, SwiftUI, one local SQLite file, MIT licensed.

> **Screenshots coming** — the wizard and the main window will be shown here once the 0.2
> screens are final.

## Install

1. Download `Ties.dmg` from the [latest release](https://github.com/1-800-CASUALME/ties/releases/latest).
2. Open the DMG and drag **Ties** to **Applications**.
3. The build is unsigned, so the first launch needs **right-click → Open** (then *Open* in the
   dialog). Alternatively, run `xattr -d com.apple.quarantine /Applications/Ties.app` once.

Requires macOS 15 or later. Apple Intelligence as a provider needs macOS 26 on a supported Mac.

## How it works

1. **Scan, without AI.** Ties reads your contacts (read-only) and looks each person up against
   Gravatar, GitHub, a web search and a long list of username sites, then fetches the public pages
   it found. Deterministic code, no model involved.
2. **Pick the right person.** Every match is scored against the evidence you already have — email,
   phone, employer, location. Confident matches are accepted automatically; the rest are shown to
   you as candidates to confirm or reject.
3. **Extract with your provider.** Only now does an AI read the collected pages and turn them into
   a profile: occupation, company, summary, and what this person can help with.
4. **Search.** Type a name or a phone fragment to filter, or ask a question and Ties ranks people
   by how well their profile answers it, with the matching phrases highlighted.

## Sources

Ties reads four places on this Mac. Each one is optional and shown as a row on the **Sources** step
of the wizard and in Settings › Sources, where you can switch any of them off. Nothing is read until
you grant Full Disk Access, and Contacts needs its own permission. A fifth row, **Lookup**, is not
read on this Mac at all — see [Lookup](#lookup) — and is off until you set it up.

| Source | What it adds |
| --- | --- |
| Contacts | The nickname you saved, the note you wrote, the city on the postal address — other names this person goes by, honorifics, and where they are. |
| Messages | How other people address them in your chats ("Dr Sara"), group names, links they sent you, when you last talked and how often. |
| WhatsApp | The display name they set for themselves, group names, links they shared, when you last talked and how often. |
| Mail | The signature block under their own mail — title, company, phone, website, LinkedIn — and when you last wrote. |

Contacts needs nothing extra. Messages, WhatsApp and Mail live behind Full Disk Access:

1. Move Ties to your Applications folder first, and grant access to that copy. macOS grants Full
   Disk Access to one particular copy of an app, so a copy on your Desktop, in Downloads, or in a
   build folder is a different app as far as the system is concerned.
2. On the Sources step, or in Settings › Sources, click **Show This Copy** and then **Open Privacy
   Settings**, and drag the revealed app into the Full Disk Access list (or switch on the **Ties**
   already there, if it is the same copy — the Sources screen prints the path it is running from).
3. Quit Ties and open it again. macOS only reads this permission when an app launches, so a grant
   made while Ties is running does nothing until the next launch. This is the usual reason it looks
   like the switch did not work.
4. The rows turn green. Continue works either way — a source that is off simply contributes nothing.

If you build Ties yourself, expect to repeat this after a rebuild: an unsigned build gets a new
identity every time it is compiled, and the old grant no longer matches. Signing the app with a
certificate that stays the same, or downloading the released DMG and leaving that copy in place,
avoids it.

Ties never opens the live chat or mail store. It copies the file to a temporary folder, opens the
copy read-only, reads at most the last 500 messages a person and the 50 most recent mails an
address, and deletes the copy when the pass ends. Nothing is written back to Messages, WhatsApp,
Mail or Contacts. What is read stays on this Mac except where the Privacy section says otherwise.
Revoke Full Disk Access whenever you like; Ties carries on with what the web says.

## Lookup

Everything above is something your Mac already has. Lookup is the one thing that isn't: a service
you choose, that answers *whose number is this, and what do other people call it?*

Ties ships no such database and integrates with no crowd-sourced one. Those databases exist because
every user uploads their whole address book — which is how your friends' names got into one without
ever agreeing to it, and it is the one thing Ties promises never to do. What Ties ships is the slot:

| Service | What it answers |
| --- | --- |
| Twilio Lookup | The name registered to the line (CNAM, United States only), plus carrier and line type worldwide. Documented, paid per lookup, your own key. |
| Custom | Any HTTP service you already have access to. You give the URL, the header your key goes in, and where the names and labels sit in the answer. No code. |

The custom slot is the honest answer to "there must be a way": if you have your own access to a
service — a business account, an API key, anything with an HTTP endpoint — you describe it in
Settings › Lookup and Ties uses it. Ties will not reverse-engineer a phone app's private API to get
at a database you have not been given access to.

What comes back is used the way it deserves. A name **registered to the line** counts as strongly as
a name someone set on their own WhatsApp account: it can settle which web profile is theirs. A name
**other people saved** becomes a "known as" chip and an honorific — "Dr", "م", "Eng." — that seeds
better searches, and never accepts a profile on its own. Numbers are asked about once each however
many contacts share them, at most two per person, and never more than the per-pass cap you set,
because a lookup is billed per call. Settings › Lookup has a **Try a number** box that shows you
exactly what a service answers before you spend anything across your whole address book.

## AI

AI sits where an assistant would sit, never in front of you. Everything it produces carries a small
sparkle, can be dismissed, and runs through the provider you chose — on-device first.

- **Judge.** When a person has more than one plausible match, the provider reads the evidence and
  says which one, in a line. You still click.
- **Smart lists.** Your network grouped in the sidebar — Doctors, Founders, Engineers in Riyadh —
  built after extraction, rebuilt on demand.
- **Ask, better.** "Help with taxes" is expanded into accountant, CPA, tax advisor, bookkeeper,
  shown as chips under the field. Remove a chip and the search forgets that term.
- **Draft.** Say what you need; Ties writes a short message in your own register, learned from your
  last twenty messages to that person, and opens Messages, WhatsApp or Mail with it prefilled. The
  sample reaches a cloud provider only with the privacy switch on. Nothing is sent by Ties.
- **Reconnect.** People whose profile answers what you are looking for and who you have not talked
  to in three months, strongest tie first.
- **Fact check.** Every extracted fact is re-checked against the pages it came from; the ones those
  pages do not support get a dotted underline instead of your trust.

Settings › Providers holds one switch: **Let cloud AI see local signals**, off by default. Off, a
cloud provider sees only public pages and what Apple Contacts holds. On, it also sees the aliases,
titles, companies and honorifics collected from your Mac, and — when you ask for a draft — your own
last twenty messages to that person, so the draft sounds like you. It never sees a message someone
sent you, a subject line, or your address book. Apple Intelligence runs on this Mac and is never
gated. The switch shows as a lock next to the provider tile.

## How long does research take?

Quick — the default — is about 5–10 seconds a person on the built-in engines, and faster with a
Tavily or Exa key, since those search several people at once instead of one query at a time.
Thorough is around 30 seconds a person: four searches, forty username sites and every page it can
reach. Switch between them with the hare and the tortoise on the research screen, or in Settings ›
Research. Nothing is lost either way — you can leave a long run going, pause it, or change depth
or engine half way through, and whoever has already been researched stays researched.

Without a key, Ties searches in hidden web views — two at once by default, up to four in Settings ›
Research, each pacing itself. Two engines are scraped: DuckDuckGo first, then Yahoo. When one of
them starts asking a view to prove it is not a robot, that view moves to the other engine for ten
minutes instead of waiting. Quick mode also caps a person at 25 seconds, and skips the search
altogether when a link the person shared already says who they are.

## Providers

Pick any one of 26 providers in the wizard, or change it later in Settings. Free options come
first; the CLI options reuse a subscription you already pay for, and the local ones never leave
your Mac.

| Provider | Where it runs | Cost |
| --- | --- | --- |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/apple.imageset/apple.svg" height="20"> Apple Intelligence | On this Mac | Free — on-device, needs macOS 26 |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/gemini.imageset/gemini.svg" height="20"> Gemini | Cloud | Free tier, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/groq.imageset/groq.svg" height="20"> Groq | Cloud | Free tier, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/openrouter.imageset/openrouter.svg" height="20"> OpenRouter | Cloud | Free models, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/claude-cli.imageset/claude-cli.svg" height="20"> Claude Code | Local CLI | Your existing login |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/codex-cli.imageset/codex-cli.svg" height="20"> Codex CLI | Local CLI | Your existing login |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/gemini-cli.imageset/gemini-cli.svg" height="20"> Gemini CLI | Local CLI | Your existing login |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/ollama.imageset/ollama.svg" height="20"> Ollama | localhost | Free |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/lmstudio.imageset/lmstudio.svg" height="20"> LM Studio | localhost | Free |
| llama.cpp | localhost | Free |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/mlx.imageset/mlx.svg" height="20"> MLX | localhost | Free |
| Jan | localhost | Free |
| GPT4All | localhost | Free |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/openai.imageset/openai.svg" height="20"> OpenAI | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/anthropic.imageset/anthropic.svg" height="20"> Anthropic | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/perplexity.imageset/perplexity.svg" height="20"> Perplexity | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/xai.imageset/xai.svg" height="20"> xAI | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/mistral.imageset/mistral.svg" height="20"> Mistral | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/deepseek.imageset/deepseek.svg" height="20"> DeepSeek | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/cohere.imageset/cohere.svg" height="20"> Cohere | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/fireworks.imageset/fireworks.svg" height="20"> Fireworks AI | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/together.imageset/together.svg" height="20"> Together AI | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/cloudflare.imageset/cloudflare.svg" height="20"> Cloudflare Workers AI | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/huggingface.imageset/huggingface.svg" height="20"> Hugging Face | Cloud | Pay per token, your key |
| <img src="Ties/Resources/Assets.xcassets/ProviderLogos/sambanova.imageset/sambanova.svg" height="20"> SambaNova | Cloud | Pay per token, your key |
| Custom | Anywhere | Any OpenAI-compatible endpoint |

Keys are stored in the macOS Keychain, never in the database or in a config file.

## Privacy

Everything lives in one SQLite file in `~/Library/Application Support/Ties`. Ties never uploads your
address book. Research goes straight from this Mac to public endpoints; during extraction, one
person's name, company, title and email addresses are sent to the AI provider you chose with your own
key — or stay on this Mac with Apple Intelligence. Any person, fact, or the whole database can be
deleted instantly. Ties prefers official APIs and search snippets, fetches public pages one at a
time, never logs in anywhere, and never writes to Apple Contacts.

What Ties learns from your chats and mail stays on this Mac, with two deliberate exceptions, both
of which are the feature working. First, searching: a name, an employer, a job title or another
name someone goes by can appear in a web search, the same way a contact's name and company already
did in 0.1 — that is how a person is found at all. Second, the AI: with "Let cloud AI see local
signals" switched off, a cloud provider is sent only what your address book already held; switch it
on and it also sees aliases, titles, companies and honorifics, plus — only when you ask for a draft
— your own last twenty messages to that person. It is never sent a message anyone sent you, a
subject line, or your address book, and Apple Intelligence on this Mac sends nothing anywhere.

There is a third exception, and it only exists if you switch it on: **Lookup** sends a contact's
phone number to the service you chose, because asking whose number it is means saying which number.
It ships off, it stays off until you have picked a service and given it your own key, and switching
the Lookup row off stops it. Nothing else about a person is sent with the number.

Ties opens your Messages, WhatsApp and Mail stores read-only, from a temporary copy, and
never modifies them. Full Disk Access can be revoked at any time; Ties keeps working with what the
web says.

## What's next

0.3 is being planned in the open. The roadmap post for this release, and the discussion of what
comes after it, is
[Ties 0.2: your Mac already knows who they are](https://github.com/1-800-CASUALME/ties/discussions/1).

## Build from source

```sh
brew install xcodegen
make run
```

`make gen` regenerates `Ties.xcodeproj`, `make build` builds Debug, `make test` runs the TiesCore
test suite, and `scripts/build-dmg.sh` produces `build/Ties.dmg`. The app icon is generated by
`swift scripts/make-icon.swift`.

## Contributing

Issues and pull requests are welcome. Please keep `make test` and `make build` green and warning
free, put logic in `TiesCore` with a Swift Testing test next to it, and keep the SwiftUI layer thin.
Before opening a pull request, walk the relevant sections of
[`docs/manual-test.md`](docs/manual-test.md). Never commit a contact, a key or a database file.

## License

Ties is MIT licensed — see [LICENSE](LICENSE).

- Provider logos are trademarks of their respective owners, used only to identify the service
  (nominative use), and are not covered by the MIT license. Sourced from
  [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons) (MIT) and
  [simple-icons](https://github.com/simple-icons/simple-icons) (CC0). See
  [`Ties/Resources/LOGOS-LICENSE.md`](Ties/Resources/LOGOS-LICENSE.md).
- The username site list is
  [WhatsMyName](https://github.com/WebBreacher/WhatsMyName) data, © Micah Hoffman, used under
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). See
  [`TiesCore/Sources/TiesCore/Resources/WMN-LICENSE.txt`](TiesCore/Sources/TiesCore/Resources/WMN-LICENSE.txt).
