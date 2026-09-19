# Ties — a small model for the easy people, a smart one for the hard

**Status:** proposed, unimplemented. Targets 0.3.
**Relation to earlier specs:** extends `2026-09-16-ties-0.2-design.md` §7 (AI) and §8
(providers). Where this document is silent, 0.2 binds.

## 1. The ask

Every AI call in Ties goes to one model. `ProviderConfig` holds a single `model` string,
`ProviderFactory.make` reads it once, and the instance it returns serves extraction, the candidate
judge, the fact check, query expansion, smart lists and message drafts alike
(`TiesCore/Providers/ProviderFactory.swift:20-41`).

That single choice has to be good enough for the hardest person in the address book, so it is
paid for on the easiest. A contact with one GitHub profile, a matching email hash and a one-line
bio is a formatting job; a contact named Mohammed Ali with four plausible LinkedIn pages and
conflicting employers is genuine reasoning. Sending both to the same model means either paying
frontier prices for the formatting or failing the reasoning — usually the first, since a user
picks the model that handles their worst case.

A network is mostly easy people. The right shape is: **the small fast model by default, the
smarter model only where the work is actually hard**, decided automatically, per person.

## 2. What "hard" is, and how Ties already knows

The difficulty signal does not need a model to compute — it falls out of the scoring that already
runs before any AI is called.

`CandidateScorer` scores each grouped identity and sorts them against `autoThreshold` and
`pendingThreshold` (`ScoringWeights`, `TiesCore/Research/CandidateScorer.swift:22-26`), and
`CandidateJudge` already encodes the first half of the rule it needs:

```swift
guard pending.count >= 2 || best.score < Self.confidentScore else { return nil }
```

Two or more candidates still pending, or one that did not score convincingly, is exactly "the
scorer could not settle this". A `Difficulty` type makes it explicit and adds the other things
that make an extraction hard:

| Signal | Where it comes from | Means |
| --- | --- | --- |
| Candidate margin | top score − second score, from `CandidateScorer` | Two identities too close to separate |
| Below `confidentScore` | the existing 3.0 gate | Nothing scored convincingly |
| Conflicts present | `Evidence.kind == .conflict` | The evidence disagrees with itself |
| Page volume | `SourcePage` count and total characters | Long input, more to get wrong |
| Script and name shape | non-Latin script, or a name with very high frequency | A namesake problem search cannot solve |
| Thin input | one short page | Little to work with, and easy to hallucinate over |

`Difficulty.of(person:candidates:pages:)` returns `.easy` or `.hard`, is pure, and belongs in
`TiesCore` with tests beside it. Nothing about it is a model call, so the routing decision itself
is free.

## 3. Roles, not models

Each AI job asks for a **role**, and the provider config maps roles to models:

| Role | Jobs | Default |
| --- | --- | --- |
| `.fast` | Extraction of an easy person, query expansion, smart-list naming, fact check | the provider's small model |
| `.deep` | Extraction of a hard person, the candidate judge, a draft the user asked for | the provider's larger model |

Query expansion is a thesaurus with a schema and runs on every question typed into the search
field — it is the clearest case for the small model. The candidate judge is the opposite: it runs
only where the scorer already failed, so by construction every call is a hard one, and it should
never have been on the cheap model.

`ProviderConfig` grows `fastModel` and `deepModel` beside the existing `model`, which stays as the
single-model fallback so every stored config keeps working untouched. `ProviderSpec` grows
`defaultFastModel` alongside `defaultModel`, filled in per catalogue entry. A provider with only
one model — Apple Intelligence on-device, most local servers — maps both roles to it and this whole
design costs nothing and changes nothing.

`ProviderFactory.make(spec:config:role:…)` takes the role and picks the model. Nothing else in the
call path changes: `AIProvider.complete` still sends a system prompt, a user prompt and a schema.

## 4. Escalation

Routing by difficulty guesses; escalation checks. Three cases send an easy person's work back to
the `.deep` model:

1. **The schema came back wrong.** `JSONExtractor` fails, or the model names a candidate that was
   not offered — which `CandidateJudge` already treats as `badResponse` rather than guessing.
   Retry once on the bigger model before failing the person.
2. **The fact check knocks out most of it.** `FactChecker` already re-checks every extracted fact
   against its pages and marks `Fact.supported`. When the majority of a person's facts come back
   unsupported, the small model invented them; re-extract on the deep model and keep whichever
   result survives the check better.
3. **`contextTooLarge`.** Already a defined `ProviderError`, already retried with less text.
   Retrying on a model with a bigger window is strictly better than dropping pages.

Escalation is what makes the small default safe: the failure mode of "too small" becomes one extra
call on a minority of people rather than a worse profile the user never learns about.

## 5. What it is worth

For a thousand-person address book where roughly one person in six is hard, the provider bill is
the small model on ~830 people plus the large one on ~170, against the large model on all 1000.
With a typical small/large price gap of 10–20×, that is a reduction of about 80% in extraction
spend, and the hard people — the ones where the answer was in doubt — get a *better* model than
they do today, not a worse one.

Wall-clock improves for the same reason: small models are faster, and extraction is the serial
part of a scan that the research phase cannot hide.

The claim needs measuring, not asserting. A `make bench-routing` target over a fixture set of
people with known correct profiles, reporting accuracy and token count for single-model versus
routed, is the thing that decides the default thresholds. Ship it with the feature.

## 6. What the user sees

One row in Settings › Providers, under the provider tile:

> **Use a smaller model where it's easy** — *on*
> Fast model: `⟨picker⟩`  Smart model: `⟨picker⟩`

And, on a person's detail view, the existing sparkle carries the truth: which model wrote this
profile. `Profile.model` is already stored and already per-profile
(`TiesCore/Model/Profile.swift:8`) — the field exists, it just isn't shown. A person whose profile
came from the fast model and looks wrong gets a **Redo with the smart model** button, which is the
manual version of §4 and the honest answer to "why is this one thin".

## 7. What this changes in the repo

- `TiesCore/AI/Difficulty.swift` *(new)* — the signal; pure, tested.
- `TiesCore/Providers/ProviderSpec.swift` — `defaultFastModel`; `ProviderConfig.fastModel`/`deepModel`.
- `TiesCore/Providers/ProviderFactory.swift` — `role:` parameter.
- `TiesCore/Providers/ProviderCatalog.swift` — a fast model per entry.
- `TiesCore/Research/Extractor.swift` — route, then escalate on the three §4 conditions.
- `TiesCore/AI/CandidateJudge.swift` — always `.deep`.
- `TiesCore/AI/QueryExpander.swift`, `SmartListBuilder.swift` — always `.fast`.
- `Ties/Main/SettingsView.swift`, `PersonDetailView.swift` — the switch, the two pickers, the
  model badge and the redo button.
- `docs/manual-test.md` — a provider with one model, a routed scan, a forced escalation.

## 8. Privacy

Routing changes which model sees a prompt, never what is in it. The `shareSignals` switch and
`LocalSignals.publicSafe` keep deciding that, unchanged, for both roles. One line is worth adding
to Settings: both models are the same provider, under the same key — routing never introduces a
second vendor behind the user's back.

## 9. Shipping order

1. **Roles with both mapped to the current model.** Pure refactor, no behaviour change, ships safe.
2. **`Difficulty` and the fast default for extraction**, plus escalation on a bad schema. The
   saving lands here.
3. **Fact-check-driven re-extraction.** Needs §2's measurements to pick the threshold.
4. **The bench target**, alongside 2 and 3, because the defaults should be evidence.
