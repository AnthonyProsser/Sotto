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

**The AX write's return status is not evidence — measure it (2026-08-19).** Safari answers `kAXErrorSuccess` to an `AXSelectedText` write on a plain `<textarea>` reporting `AXTextArea`, and does nothing with it. Believing the status loses the transcript with no error anywhere, which is the one outcome §4.5 rules out. Read `AXNumberOfCharacters` before and after; unchanged means fall through to paste. Not `AXValue` — that copies the whole document across the AX boundary twice per dictation, and the document can be a book.

**An Electron app has no focused element until you switch its tree on — set `AXManualAccessibility` before believing "no field focused" (2026-08-19).** Chromium ships accessibility off, so `AXFocusedUIElement` returns `kAXErrorNoValue` and `AXWindows` is empty while the user is typing into a text box that is plainly there. Sotto read that correctly as §3's no-focused-field case and copied to the clipboard, which is how dictation into T3 Code copied instead of inserting. One `AXUIElementSetAttributeValue(app, "AXManualAccessibility", true)` on the frontmost app fixes it for the process lifetime; after it, the same element reports `AXTextArea` with `AXValue` settable. Not `AXEnhancedUserInterface` — same effect, but it is VoiceOver's flag and some apps change window behaviour when they see it. **Fire it when the gesture arms, never inline in `insert()`**: the tree takes about a second to build, and `insert()` runs on the main thread at the moment the user is waiting for their text.

**A space goes in front of the transcript when the caret sits hard against the previous word (2026-08-19).** Read the character before the caret with `AXSelectedTextRange` + `AXStringForRange` — one character, never `AXValue`, for the same document-can-be-a-book reason the write is measured with `AXNumberOfCharacters`. Space unless it is whitespace or an opener. **Compute it before the ladder picks a rung** so paste and AX agree, and **never on the clipboard path**. No read means no space: a missing space is one keystroke, a spurious one is an edit to text the user did not touch.

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

## 5.1 Testing the tap — three traps, each of which looks like a code bug

Learned by hitting all three on 2026-08-18, in slice 2. Every one of them produces a tap that appears broken while being correctly written, which is why they are here rather than in a commit message.

**Post synthetic test events to `.cgSessionEventTap`, never `.cgAnnotatedSessionEventTap`.** The annotated location is *downstream* of the session tap: events posted there reach the frontmost app but are invisible to Sotto's own tap. A harness using it will show the app receiving nothing and every keystroke passing through, which reads as "the tap does nothing" — note that §1's rule to post to the annotated tap is about **delivering** Sotto's own Cmd+C/Cmd+V, and is the opposite case.

**Launch with `open`, never by running the binary inside the bundle.** Running `.../Sotto.app/Contents/MacOS/Sotto` from a shell breaks TCC attribution, and the failure is silent in the worst way: `tapCreate` **succeeds** and the tap then receives no events. `open --env KEY=VAL` breaks it too; use `launchctl setenv` when a test needs a variable. Keep the posting process alive about a second after its last event — exiting immediately can drop it.

**macOS's own dictation answers a held Right Command on the reference machine.** Found 2026-08-19: a hold produces text from the system as well as from Sotto, and the first symptom is text appearing *twice*, which reads as a duplicated insertion in Sotto's own pipeline. It is not — quit Sotto and the text still appears. Test with the double-tap latch, which the system does not claim. The product question this raises is Anthony's and is logged in `DECISIONS.md`.

**A tap that installs but sees nothing is a permissions problem until proven otherwise.** Check the grant before reading the state machine. Signing, the `tccutil` reset, and why Input Monitoring's pane stays empty are in the project memory rather than here, because they are facts about Anthony's machine rather than about Sotto.

---

## 6. Focus changes mid-transcription — the clipboard (2026-08-27)

**The user dictates into a field, then clicks away before transcription finishes: the text goes to the clipboard.** Not to the original target. Open issue 3, closed by Anthony on 2026-08-27.

Routing to the original risks writing into a window the user has left, which is §4.5's one ruled-out failure — text arriving where nobody is looking, with no error anywhere. The clipboard is surprising when the field is still right there, and that cost is accepted because it is *visible*: §2's no-focused-field path already exists, and the HUD morph that confirms it is already built. **Reuse that path; do not write a second one.**
