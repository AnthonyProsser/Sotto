# Models and network — loading, memory, and every byte that leaves the machine

**Open this before loading a model, estimating memory, gating anything on hardware, adding an outbound connection, or touching MCP or the updater.** `CLAUDE.md` §0.1 routes you here. The consent rule itself is short enough to live in `CLAUDE.md` §2; this file is the reasoning and the mechanics.

---

## 1. Predict, don't gate (principle 3)

Memory pressure produces an **estimate and an amber row, never a disabled control**. Rows turn amber past ~60 % of physical RAM and stay selectable; loading past that is the user's call.

**Hardware never gates a feature.** The one exception is model *capability*: **vision is the only gate, and it gates on the model, not the machine** (§7.2). A text-only model cannot see an image — that is a fact about the model, not a judgment about the user's hardware.

| | |
|---|---|
| Memory estimate | `weights + KV + ~15 % overhead`; amber past ~60 % of physical RAM; always advisory |
| Reference machine | MacBook Neo, 8 GB unified memory — the development target, **not a runtime floor** |
| LLM | `mlx-swift` embedded; OpenAI-compatible adapter for Ollama `:11434`, `llama-server`, LM Studio |

A model download that fails surfaces in the model list where it started (§7.4), not anywhere else — `.claude/rules/design.md` §10.

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
