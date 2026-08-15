# Sotto — Decisions log

**Newest first. Append, never rewrite.**

## How this file works

`docs/` holds read-only copies of the spec, the build order, and the token sheet. The originals live in `/Users/anthonyprosser/Documents/Sotto/`. Nothing in `docs/` is ever edited here — see `CLAUDE.md` §0.

Decisions get made during build sessions, because a spec that survives contact with Swift unchanged was not a spec. When one happens:

1. **Claude Code appends an entry below** — newest at the top of the table, using the template.
2. **Claude Code says so in its reply**, naming the spec section it contradicts if there is one. A decision logged silently is a decision nobody folds back.
3. **Anthony folds the entry into the real spec** in `Documents/Sotto`, then re-syncs `docs/` with the `cp` line in `docs/README.md`.
4. **Anthony flips the last column to Yes** and notes the resulting spec version.

Until step 4, the copies in `docs/` are out of date on that point. That is fine as long as everyone knows it — which is what this file is for. **A `No` in the last column means the spec copy is wrong about that thing right now.**

**What belongs here:** anything that contradicts, extends, or resolves the spec. A new tier-2 token row. A constant that turned out wrong in practice. A rule that could not be implemented as written. An open issue from §12 that got settled. A number that was a placeholder and is now real.

**What does not:** ordinary implementation choices the spec does not speak to. Naming a Swift type, splitting a file, picking a collection type. If the spec has no opinion, neither does this file.

## Entry template

```
| YYYY-MM-DD | N | <the decision, one sentence> | <why — name what lost and why it lost> | §X.Y or — | No |
```

Columns: **Date · Slice · Decision · Reason · Supersedes · Folded back into spec?**

---

## Decisions

| Date | Slice | Decision | Reason | Supersedes | Folded back? |
|---|---|---|---|---|---|
| *(example — delete when the first real entry lands)* | | | | | |
| 2026-08-13 | 1 | **EXAMPLE ENTRY — NOT A REAL DECISION.** The idle/not-idle signal is an `@Observable` `ActivityMonitor` holding a counted set of named contributors, not a `Bool`. | A `Bool` cannot survive two overlapping contributors: closing the main window while a file transcription is still running would clear the flag and the icon would go hollow while Sotto was working. A counted set makes each contributor's raise and lower independent, and the names make the contributor list auditable in one place — which is what §14.8's list of seven contributors demands and what the build order warns turns into seven sources of truth. | §14.8 — adds an implementation constraint, contradicts nothing | No |

---

*The row above exists to make the format unambiguous. Delete it when the first real decision is logged.*
