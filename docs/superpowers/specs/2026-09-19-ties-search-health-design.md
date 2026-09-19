# Ties — search health, and more than one engine at a time

**Status:** proposed, unimplemented. Targets 0.3. Contains one live bug (§1).
**Relation to earlier specs:** extends `2026-09-16-ties-0.2-design.md` §5 (research) and the
search-pool behaviour described in the README. Where this document is silent, 0.2 binds.

## 1. The bug: a wrong key looks exactly like a quiet network

`SearchProbe.run` loops the queries for one person and handles a failure like this
(`TiesCore/Sources/TiesCore/Research/SearchProbe.swift:27-38`):

```swift
} catch SearchBackendError.challenge {
    throw SearchBackendError.challenge
} catch {
    // Any other per-query failure (timeout, transport, unauthorized) doesn't stop
    // the other queries from running.
    continue
}
```

Skipping one timed-out query is right. Skipping `.unauthorized` is not. A Tavily or Exa key that
is mistyped, expired, revoked or out of credit returns 401/403 on **every** query, `mapSearchHTTPError`
turns each into `.unauthorized`, and the probe quietly `continue`s past all of them. The scan runs
to the end, every progress bar fills, and the user is told research finished — on a run where the
web contributed nothing at all. The only trace is that people come out with thin profiles, which
looks like "the internet doesn't know my contacts" rather than "your key was refused".

The same silence covers a key with no credit left, which some engines report with a status of
their own rather than 401 — that maps to `.transport` and is swallowed by the identical `continue`.

Worse, nothing before the scan would have caught it. `SearchBackendChoice.hasKey`
(`Ties/Components/SearchBackendPicker.swift:26-29`) is the whole of Ties' idea of whether an engine
works:

```swift
var hasKey: Bool {
    guard let keyAccount else { return true }
    return !(Keychain.get(account: keyAccount) ?? "").isEmpty
}
```

Non-empty is not the same as valid. Paste a key with a trailing space, or one from the wrong
service, and every screen in the app shows the engine as ready.

## 2. Three fixes, cheapest first

### 2.1 Test the key when it is given

A **Test** button beside the key field, in Settings › Research and in `SearchBackendKeySheet`,
that runs one real query (`"Ada Lovelace"`) against the engine and reports in a line:

- *Working — 8 results in 0.4s*
- *That key was refused (401).*
- *Key accepted, but no credit left.*
- *Couldn't reach Tavily. Check the connection.*

One request, free or near-free on every engine, at the exact moment the user can still fix it.
The result is cached as a `SearchHealth` row — engine id, verdict, when — so the Scan screen can
show the engine's state without testing again.

### 2.2 Stop swallowing `.unauthorized`

`.unauthorized` and out-of-credit failures are not per-query problems, they are per-key problems,
and a per-key problem must stop the loop. `SearchProbe` rethrows them the way it already rethrows
`.challenge`; the scanner counts them, and after **three consecutive** authorization failures
across the whole run it:

1. stops sending queries to that engine,
2. falls back to DuckDuckGo automatically, which needs no key and is what the app used before any
   key was pasted, and
3. shows one banner on the Scan screen — *Tavily refused your key. Continuing with DuckDuckGo.* —
   with a button to Settings.

Three, not one: a single 403 can be a rate-limit wearing the wrong status code. Falling back
rather than failing is the right call, because a scan that keeps going with a free engine is worth
more than a scan that stops, and a scan that silently finds nothing is worth less than both.

### 2.3 A health row wherever an engine is shown

The picker rows stop reading "has a key" and start reading what the last real call did: a green
dot and *Working*, an amber dot and *Not tested*, a red dot and *Key refused*. `hasKey` stays as
the gate for whether an engine can be *chosen*; health is what says whether it is *working*.

## 3. More than one engine at a time

Ties runs exactly one backend: `AppModel.searchBackend` is a single instance chosen by
`searchBackendId`. `SearchPool` already fans queries across several workers and already fails over
— but only among the scraped web-view engines (DuckDuckGo, Yahoo), and only on `.challenge`. Two
API backends never help each other, and an engine that is simply *weaker on this person* is never
noticed at all.

The engines have genuinely different strengths, which is the argument for using more than one:
Exa's embedding search finds a person from a description when the exact name is ambiguous; Tavily
is better at fresh, news-shaped pages; DuckDuckGo is free and unlimited and knows the obvious
profile pages. On a hard person — a common name, a non-Latin name, no employer — the second engine
is where the answer is.

### 3.1 `FanOutSearchBackend`

A `SearchBackend` that holds several others and merges what they return. It conforms to the same
protocol, so `SearchProbe`, `Scanner` and everything else stay untouched — this is the same trick
`SearchPool` already plays.

Merging is not a concatenation. `Search/RankFusion.swift` already implements reciprocal rank
fusion for exactly this shape of problem ("blends several ranked id lists … without needing the
lists' scores to be on comparable scales"), and a search hit's canonical URL is its id. A URL that
two engines both return, each at rank 3, outranks one that a single engine put first — which is
precisely the signal wanted, because two independent engines agreeing on a profile is evidence in
a way one engine's confidence is not.

RRF over canonical URLs also deduplicates for free: `ProbeFinding.canonical` is already the
normalizer, and the same profile found twice becomes one finding with two engines behind it.

### 3.2 When to fan out

Fanning out on every query doubles the cost of every scan, so it is aimed, not default:

- **Quick mode** — one engine, the chosen one. Unchanged.
- **Thorough mode** — the chosen engine plus DuckDuckGo, which is free, so thorough costs no more
  in money than it does today and gains a second opinion.
- **Escalation, any mode** — when a person's first engine comes back with nothing that clears the
  name gate, or with two candidates too close to separate, that person alone is re-queried on the
  other engines. This is the same "spend more only where it is hard" rule that the model-routing
  design applies to the provider, and it costs a handful of extra queries per scan rather than one
  per person.

Settings › Research gains one control for this: **Ask a second engine when the first finds nothing**,
on by default, since its fallback is the free engine.

## 4. What this changes in the repo

- `TiesCore/Research/SearchProbe.swift` — rethrow `.unauthorized`; leave timeouts as they are.
- `TiesCore/Research/SearchBackend.swift` — an `outOfCredit` case, mapped from the statuses the
  engines actually use, so it can be told apart from a network problem.
- `TiesCore/Research/SearchHealth.swift` *(new)* — the verdict type and the one-query probe.
- `TiesCore/Research/FanOutSearchBackend.swift` *(new)* — RRF over canonical URLs; pure, testable
  against stub backends the way the existing backends are.
- `TiesCore/Research/Scanner.swift` — count authorization failures, fall back, report.
- `Ties/Components/SearchBackendPicker.swift` — Test button, health dot.
- `Ties/Onboarding/ScanView.swift` — the fallback banner.
- `docs/manual-test.md` — a deliberately wrong key, a key with trailing whitespace, and a scan
  that starts on Tavily and has to finish on DuckDuckGo.

## 5. Privacy

A test query is the string `"Ada Lovelace"` — no contact, no number, nothing from this Mac. Fan-out
sends the same queries `SearchQueryBuilder` already builds to one more engine, under the user's own
key, and those queries are already bounded by `LocalSignals.publicSafe`. Nothing here widens what
leaves the Mac; it only changes which of the user's own engines is asked.

## 6. Shipping order

1. **Rethrow `.unauthorized` and fall back to DuckDuckGo.** The bug fix. Small, and it turns the
   worst failure in the app from silent into obvious.
2. **Test button and health dots.** Catches the same problem before a scan instead of during one.
3. **Fan-out on thorough.** Free second opinion, one new file, reuses `RankFusion`.
4. **Escalation on hard people.** The part that needs the difficulty signal the model-routing
   design defines, and best built alongside it.
