# Models and network — loading, memory, and every byte that leaves the machine

**Open this before loading a model, estimating memory, gating anything on hardware, adding an outbound connection, or touching MCP or the updater.** `CLAUDE.md` §0.1 routes you here. The consent rule itself is short enough to live in `CLAUDE.md` §2; this file is the reasoning and the mechanics.

---

## 1. Predict, don't gate (principle 3)

Memory pressure produces an **estimate and an amber row, never a disabled control**. Rows turn amber past ~60 % of physical RAM and stay selectable; loading past that is the user's call.

**Hardware never gates a feature.** The one exception is model *capability*: **vision is the only gate, and it gates on the model, not the machine** (§7.2). A text-only model cannot see an image — that is a fact about the model, not a judgment about the user's hardware.

**§1.1 adds a nuance rather than an exception: the machine may determine the *default*, never whether a feature exists.** `deviceNotEligible` is genuinely machine-determined, and it decides only which model is selected out of the box. The feature stays present and the user picks another model — which is §7.2's own stated pattern, not a new one.

| | |
|---|---|
| Memory estimate | `weights + KV + ~15 % overhead`; amber past ~60 % of physical RAM; always advisory |
| Reference machine | MacBook Neo, 8 GB unified memory — the development target, **not a runtime floor** |
| LLM | `mlx-swift` embedded; OpenAI-compatible adapter for Ollama `:11434`, `llama-server`, LM Studio |

A model download that fails surfaces in the model list where it started (§7.4), not anywhere else — `.claude/rules/design.md` §10.

---

## 1.1 Apple's on-device model is the default for both cleanup and chat

**Decided 2026-08-19 (`DECISIONS.md`): `SystemLanguageModel` from `FoundationModels` is the default cleanup model and the default chat model**, so Sotto works at first run with nothing downloaded. It remains one row among many — §2.2's "roles, not products" — and the user can switch at any time.

**When `availability` is not `.available`, Sotto opens the model picker in the owning settings pane** — Dictation for cleanup, Chat for chat — **with a banner naming the reason**: `deviceNotEligible`, `appleIntelligenceNotEnabled`, or `modelNotReady`. It is never a HUD error and never a modal; see `rules/design.md` §10 for why unavailable is not a failure.

**Verified against the installed SDK and on the reference machine, 2026-08-19.** These are measurements, not documentation:

| Fact | Value |
|---|---|
| `contextSize` | **4096, total — prompt *and* output.** Confirmed at runtime, not just in the interface |
| Warm latency | ~850 ms median for a ~40-word cleanup pass (min 756, max 3358) |
| Cold latency | ~3.5 s on the first request after launch — hence prewarm, `rules/audio-and-transcription.md` §3.1 |
| `rateLimited` | **Does not fire** for a never-frontmost `.accessory` app: 40/40 clean, `selfIsFront` 0/40, against a 40/40 frontmost control. Being background costs no latency |
| Guardrails | `.permissiveContentTransformations` exists for exactly the transform-the-user's-own-content case. Zero `guardrailViolation` on dictated content with it |

**The rate-limit result is bounded and should not be oversold.** Burst only — 120 requests in three ~40 s windows, so a longer-window quota would not have shown.

**`concurrentRequests` is now tested, and it is a rule about sessions, not about load** (2026-08-19, `DECISIONS.md`):

- **One `LanguageModelSession` per concurrent operation.** Cleanup owns one, chat owns one, neither reuses the other's. Two distinct sessions fired simultaneously both complete; that held to **six concurrent sessions over twelve rounds** with no `concurrentRequests` and no `rateLimited`.
- **Reusing a single session for two simultaneous requests throws `concurrentRequests`**, deterministically — 4 of 4 trials, one arm failing while the other completes.
- **There is no parallel speedup.** Requests serialise at the model level: concurrent totals 889–1231 ms against sequential 1025–1106 ms for the same pair, and n scales flat — 2 → 345 ms, 4 → 750 ms, 6 → 1030 ms. Overlapping cleanup with a generating chat response buys nothing and costs roughly a full request on whichever the user is waiting for. **Do not overlap for throughput; overlap only when the two demands genuinely arrive together.**

**One robustness item, open and uncharacterised — do not build on it either way.** An intermittent `SIGTRAP` inside FoundationModels itself: twice in ~13 runs under concurrent-session load, identical trap site (`EXC_BREAKPOINT`, `FoundationModels+269145 → +317xxx`, on a Swift concurrency thread), **not reproduced in eight subsequent runs**, no identified trigger. It matters because a trap kills the process rather than surfacing as an error `rules/design.md` §10 could route to a surface. **Two occurrences are not a characterised API failure and are not grounds to abandon separate-session concurrency** — they are grounds to look again before slice 9 ships.

**Three costs, accepted with the decision and written here so they are not rediscovered:**

- **It fits §2.2's role and breaks the tables built around it.** There are no weights, no `config.json`, and no KV geometry, so §2.3's `weights + KV + ~15 %` estimate has nothing to compute and the model row has no amber threshold. §7.2's registry can answer `tools` and nothing else — `max_ctx` is fixed at 4096 and `vision` is false.
- **`vision == false` on a fresh install.** Per §7.2 that disables image attachment in the `+` menu and puts §5.6's screenshot gesture behind the scrim until the user downloads something else. Correct behaviour, and the opposite of what "works out of the box" sounds like — the first-run copy has to say so.
- **The model is unversioned from Sotto's side and moves on OS updates.** Apple says as much by tying adapters to a model version and shipping `removeObsoleteAdapters()`. "Cleanup got worse after 26.6" is unreproducible and unfixable, which is why §4.6's raw-transcript retention matters more now, not less.

**It is text-only, permanently.** It cannot serve §2.2's audio-in-LLM path and never collapses the STT stage.

---

## 2. Principle 1 is a consent rule, not a count

**Every outbound connection is either something the user just did or something the user switched on.** Three exist:

| Connection | Consent |
|---|---|
| A model download | The user started it (§7.4) |
| An MCP server | The user enabled it (§6; **disabled out of the box**) |
| The update check | Default on, weekly, one toggle (§10.6) |

Earlier versions claimed zero outbound connections, then a closed list of two; both were the wrong shape, because the constraint was never about how many. **That test is what permanently rules out telemetry, crash reporting, analytics, and remote config** — not a list, but the fact that nobody asks for them, so they can never pass. Anything that would connect without the user having done something or turned something on does not get built.

**The updater's specifics are part of the rule, not configuration.** `SUEnableSystemProfiling` is written into `Info.plist` as an explicit `NO`, not left to Sparkle's default — enabled it appends CPU type, core count, RAM, OS version, model identifier, and preferred language to the appcast URL, a machine fingerprint on the only request Sotto sends. EdDSA verification is mandatory and the appcast is HTTPS-only.

---

## 3. MCP

**One bundled search MCP: Tavily, disabled by default.** SearXNG, DuckDuckGo, and a bring-your-own-key slot shipped in v0.16 — three surfaces for one capability, and the DuckDuckGo HTML scrape was the one that would break first. Exa was the closest call and lost on cost predictability at volume. **Do not reintroduce the other three.**

**No network badge on MCP-enabled features.** Cut after v0.17 — see `.claude/rules/design.md` §12 for why.

**The Swift SDK lags the protocol** — open issue 1 in `.claude/rules/open-questions.md`. **Decide before writing a line of slice 12.**

---

## 4. Deferred, decided in principle, not built

**An optional cloud model fallback.** Permitted by principle 1, because it cannot happen without the user pasting a key — an act at least as explicit as enabling an MCP. **Not in v1.** Recorded so a later version does not re-argue whether it is allowed. When built it inherits the rule: the user provides the credential, the user can see when a turn went to it, and there is no silent failover from a local model that is merely slow. Nothing in the harness should assume the model is local, which principle 6 already requires.
