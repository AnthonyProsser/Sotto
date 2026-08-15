# Open questions — do not invent answers to these

**Eight things are genuinely undecided.** If your work needs one, **ask Anthony**. Inventing an answer produces something that looks settled and is not.

`CLAUDE.md` §2 lists the titles so they stay visible without opening this file. The reasoning is here.

---

## Known gaps

### Gap 1 — decision 04, the in-app chat, has no home in the spec

`designs/Design.pdf` locks an edge-anchored, full-height wash with no panel edge, no chat picker, and a 390 × 81 pt glass composer (`sotto-tokens.md` §6.4). Spec §5.8 describes something different: a bounded floating panel, 600 pt bar, growth to 180 pt, cap at the lesser of 720 pt and 70 % of usable height. They may be one surface in two states or two surfaces; **the spec does not say, because it predates the decision.** Slice 9 or 10 has to reconcile them, and the reconciliation belongs in spec §5 rather than in the token sheet. **Do not pick one and build it.**

**There is a third shape, and it is the one nothing else records.** `docs/sotto-chat-response-concept.svg` draws a **local blurred fade** around the conversation — not full height, not an edge wash, no panel edge either — with the composer floating in it. So: bounded panel (§5.8), full-height wash (decision 04), local fade (the SVG). The SVG is not locked and carries no measurements, so it does not outrank the other two; it is evidence that the question was still live after the PDF was drawn. **The reconciliation is three-way.**

The SVG's turn anatomy — speaker labels, quoted selection, no assistant bubble — is separable from the wash question and survives whichever container wins. See `.claude/rules/design.md` §11.

### Gap 2 — the two anchor numbers are still not constants, but the overlay's now decomposes

`Design.pdf` quotes the overlay's **118 pt** bottom offset alongside an **84 pt Dock** and a **34 pt clearance**, each with its own ratio — 118 = 84 + 34, which is the shape of an invariant rather than a coincidence. The likely token is therefore *"clears the Dock's current height by 34 pt (0.654 bar heights),"* not the constant.

**Two cases that decomposition does not cover:** a Dock positioned left or right, where there is no bottom occlusion at all, and an auto-hidden Dock, where occlusion is zero until it is not.

The HUD's **8 %** top position does not decompose — it came from an assumed 1512 × 982 screen with a 24 pt menu bar, and a notched MacBook Pro menu bar is taller than 24 pt. **Decide per anchor whether it is a fixed value or a rule, and record which.**

### Gap 3 — the send button's volume contradicts §14.3

§14.3 rejects "a saturated send button — the loudest thing in Gemini's bar and the first thing that makes it feel intrusive," and §5.8 restores the button but explicitly "not its volume." `Design.pdf` decisions 01 and 04 both draw it as a **filled 26 pt accent circle**, the most saturated element in either surface. Either the drawn treatment is what §14.3 warned against, or §14.3's objection was to size or position rather than fill.

**Slice 9 decides, and whichever way it goes, one of the two documents needs amending.** Do not resolve this by picking the drawing over the spec because the drawing is more recent.

`sotto-chat-response-concept.svg` takes a third position: it draws the `+` and **no send button**. Its composer is empty, so this may be hide-until-non-empty rather than deletion — the drawing does not say, and there is no prose with it to ask. Worth putting to Anthony alongside the other two, not worth inferring from.

### Open but gating nothing — the app icon layer breakdown

For Icon Composer. The mark is locked — two capsules forming an S, lower occluding upper. The layer split is an asset decision, not a token.

---

## Open issues (spec §12)

1. **MCP Swift SDK lags the protocol.** `modelcontextprotocol/swift-sdk` 0.12.1 (May 2026) implements 2025-11-25; Sotto targets 2026-07-28, which removes the handshake and sessions and adds Multi Round-Trip Requests. Wait, fork, or write the client directly against the spec. **Decide before writing a line of slice 12.**
2. ~~**SwiftUI / AppKit split.**~~ **Closed 2026-08-15 — see `DECISIONS.md`.** Every view is SwiftUI, including the main window; AppKit is confined to the app delegate, the status item and its `NSMenu`, and the `NSWindow`/`NSPanel` objects hosting SwiftUI via `NSHostingView`. **Consequence: each §14.2 role has exactly one `Color` form, never a paired `NSColor`** — that pairing was the objection, and pushing the main window into SwiftUI is what removed it. The number is kept and not reused; spec §12's numbering is referenced elsewhere.
3. **Focus changes mid-transcription.** User dictates into a field, then clicks away before transcription finishes. Original target, or clipboard? Routing to the original risks writing into a window the user has left; the clipboard is safe but surprising when the field is still right there.
4. **Cleanup reasoning: toggle, and default.** May help punctuation on ambiguous prosody; multiplies latency on the step between speaking and seeing text. §8.1 currently defaults it open. Lands in slice 11.
5. **Bare compose bar growth.** The full panel grows, then caps and scrolls. Whether a standalone bar with no conversation above it does the same or caps sooner is undecided — a bar that grows to 180 pt with nothing above it may read as broken rather than accommodating. **Decide in slice 9's design pass, not in code.**
