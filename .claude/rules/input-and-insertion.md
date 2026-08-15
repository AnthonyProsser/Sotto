# Input and insertion — the tap, the gestures, and getting text into another app

**Open this before touching the event tap, a gesture, a hotkey, the Escape key, the activation policy, or anything that writes text into another application.** `CLAUDE.md` §0.1 routes you here.

Each rule below has a reason attached. The reason is load-bearing: a rule without one gets rationalised away at 2am.

---

## 1. The event tap

**The tap runs on a dedicated thread, never the main runloop (§2.5).** Hard requirement, not an optimization. If a tap callback blocks the main thread the menu bar goes unresponsive, which breaks quit-as-panic (§10.5) — and quitting is the only reliable shutdown path, because event taps are per-process and die with the process. A wedged tap must never take the UI down with it.

**The tap observes modifier keycodes only** — 54/55 for Right/Left Cmd, 58/61 for Option. Carbon's `RegisterEventHotKey` cannot distinguish left from right, which is why there is a tap at all. No key content is read, buffered, or stored, and the code should make that obvious to someone auditing it.

**Right Command is never consumed (§4.1).** It stays a live modifier, so Right-Cmd+C keeps copying.

**Synthetic events are tagged and filtered (§2.6).** Sotto posts Cmd+C (selection fallback) and Cmd+V (clipboard paste). Both must be tagged or the app's own hotkey detector fires on its own output:

```swift
let src = CGEventSource(stateID: .privateState)
event.setIntegerValueField(.eventSourceUserData, value: MAGIC)
event.post(tap: .cgAnnotatedSessionEventTap)
```

Post to `.cgAnnotatedSessionEventTap`, **not** the HID tap — that is what delivers reliably to the frontmost app.

---

## 2. Insertion

**Two strategies, in order (§3): Accessibility, then clipboard paste.** AX writes to `AXValue`/`AXSelectedText` on the focused element — atomic and most robust. Paste is the fallback, second because save-and-restore of `NSPasteboard` is lossy: promised/lazy data cannot be captured, and anything that copies during the window clobbers the restore.

**No focused field → clipboard and stop (§3).** Never paste into whatever happens to be frontmost. The HUD's waveform morphs into "Copied to clipboard" and fades — that confirmation is the entire reason this path is safe.

**The CGEvent Unicode strategy is deleted — do not resurrect it.** It existed to serve the human-typing MCP, which is now a separate unrelated project. As an out-of-process MCP it cannot post keystrokes under Sotto's Accessibility grant anyway, so there was nothing left for the strategy to serve.

---

## 3. Keys the app claims

**`Cmd+,` for settings, never `Cmd+.` (§8.3).** `Cmd+.` is the historical macOS cancel binding; registering it globally would break cancel everywhere else on the machine.

**The Escape priority stack (§10.4).** Exactly one action fires, resolved top-down:

1. Abort in-flight gesture → discard audio, insert nothing, **and disarm the gesture** — slice **2**
2. Cancel transcription in progress — slice **3**
3. Stop chat generation — slice **9**
4. Close overlay — slice **9**

Slice **13**'s scrim preempts all four while it is up. The global monitor installs **only while app UI is live** — Escape is never swallowed system-wide.

This is one of the four cross-slice threads; see `.claude/rules/slices.md`.

---

## 4. Activation policy

**The overlay must never flip the activation policy (§10.2).** The main window opening flips to `.regular` and back to `.accessory` on close, and that transition steals focus — usually desired there, never for the overlay. **Build the guard in slice 1**, before there is an overlay to forget it in.

---

## 5. The gestures, for reference

| Gesture | Does |
|---|---|
| Hold or double-tap **Right Cmd** | Dictate — routes to chat if text is selected |
| Double-tap **Option** | Overlay |

---

## 6. Open question that lands here

**Focus changes mid-transcription** — open issue 3 in `.claude/rules/open-questions.md`. User dictates into a field, then clicks away before transcription finishes. Original target, or clipboard? Undecided; ask, do not pick.
