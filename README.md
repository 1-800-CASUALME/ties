# Ties

[![CI](https://github.com/1-800-CASUALME/ties/actions/workflows/ci.yml/badge.svg)](https://github.com/1-800-CASUALME/ties/actions/workflows/ci.yml)

Ties turns your Mac's address book into a network you can actually ask questions of.
A setup wizard researches each contact from public sources — no AI involved — and then an AI
provider of your choice reads what it found and writes a short profile for each person.
After that you search in plain language: *"who do I know that can help with X"*.

Native macOS 15+, SwiftUI, one local SQLite file, MIT licensed.

> **Screenshots coming** — the wizard and the main window will be shown here once 0.1.0 ships.

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

## How long does research take?

Quick — the default — is about 5–10 seconds a person with DuckDuckGo, and faster with a Tavily
or Exa key, since those search several people at once instead of one query at a time. Thorough
is around 30 seconds a person: four searches, forty username sites and every page it can reach.
Switch between them with the hare and the tortoise on the research screen, or in Settings ›
Research. Nothing is lost either way — you can leave a long run going, pause it, or change depth
or engine half way through, and whoever has already been researched stays researched.

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
