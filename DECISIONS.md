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
| 2026-08-15 | 1 | **First tier-1 token row: `surface.window` → `NSColor.windowBackgroundColor`, first consumer the settings window.** The token layer is `Sotto/Design/Token.swift` — `enum Token` with nested `Surface`, `Text`, `Border`, `Accent`, `Material` namespaces, tier 2 present as an empty `Token.Authored` and nothing else. It also carries one geometry helper, `Token.shape(radius:)`, returning `.rect(cornerRadius:style:.continuous)`. `Text`, `Border`, `Accent`, and `Material` ship empty. | The row earns itself: `.windowBackgroundColor` picks up the macOS 26 window-background wallpaper tint, which a drawn fill would not, and the settings window is built this slice. The four empty namespaces are the closed role set §14.2 names, encoded so a sixth namespace has to be argued for rather than added. `shape(radius:)` exists because `RoundedRectangle(cornerRadius:)` defaults to a circular arc and §14.1's continuous-corner rule is the one most likely to be broken by a call site written in a hurry — the radius stays a parameter because no radius has a consumer yet and `radius.surface` is still open (tokens §4). | Token sheet §1, which reads "**Empty.** No feature has been built" and now has one row. §2 is still genuinely empty | No |
| 2026-08-15 | 1 | **Every view is SwiftUI. AppKit is confined to three jobs: the app delegate, the status item and its `NSMenu`, and the `NSWindow`/`NSPanel` objects that host SwiftUI through `NSHostingView`.** The main window is SwiftUI as well, not only the floating surfaces. The Xcode project is created from the AppKit (XIB) template accordingly. | Pure SwiftUI is not available, so the real choice was where the seam falls rather than whether there is one. Three requirements have no SwiftUI form: the HUD must be a **non-activating** `NSPanel`, because it appears while the user is dictating into another app and a panel that takes key status destroys the focused element the AX write targets — the failure is silent, and every dictation degrades to the clipboard path (§3, §4.5); the event tap is `CGEventTap` on a dedicated thread (§2.5); insertion is `AXUIElement` (§3). The SwiftUI `App` lifecycle would therefore not remove the split but scatter it — `NSApplicationDelegateAdaptor` to recover the delegate, launch-window suppression, manual activation-policy calls fighting scene management — and still require `NSPanel` for the HUD and overlay. **What decides the remaining question is §12's own objection**: an AppKit main window beside SwiftUI floating surfaces would force every §14.2 role to carry both a `Color` and an `NSColor` form, two definitions of one role free to drift. Pushing the main window into SwiftUI answers it — one `Color` per token, and the AppKit layer draws nothing at all. | §12 open issue 2 — resolves it. Also settles the §14.2 token-form question the issue raised | No |
