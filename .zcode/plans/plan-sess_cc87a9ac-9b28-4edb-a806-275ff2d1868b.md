## Decision being implemented

The docked chat panel's light/dark polarity gets keyed to **sampled backdrop luminance** — the fix the 2026-09-02 `DECISIONS.md` row explicitly reserved for your ruling. A new row goes in `DECISIONS.md` superseding that row (polarity stays keyed to system appearance → keyed to the backdrop sample; Screen Recording grant acquired at first docked-panel open). The bare bar is untouched — it stays unpinned glass, flipping per frame.

## Changes

1. **New file `Sotto/App/BackdropSample.swift`** — one purpose, ~40 lines:
   - `luminance(behind rect:belowWindow:) -> CGFloat?`: one-shot `CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, panelWindowNumber, …)`, drawn into a small (32×32) context, returns the sRGB mean (0–1). Averaging in sRGB deliberately matches how the render server itself reads the backdrop (`rules/design.md` §4.3). The below-window option excludes Sotto's own windows by construction, so the wash and HUD never sample themselves.
   - `isLight(_ luminance:) -> Bool`: threshold 0.5, a local constant, one edit to change (not a token — single consumer, §9).
   - Permission: preflight `CGPreflightScreenCaptureAccess` before each sample; `CGRequestScreenCaptureAccess` once at the first docked open. Ungranted → nil → callers fall back to today's system-appearance behaviour. Never prompts while the bare bar is showing.
   - **Named rejection of SCScreenshotManager (§1):** it is async-only and needs SCShareableContent enumeration plus a per-display filter; the synchronous below-window capture can complete *before* the panel orders front, preventing a wrong-polarity flash at open. The seam is one function if it must move later.

2. **`OverlayPanel`** owns the pin:
   - On show with a docked target: sample first, then set `panel.appearance` to aqua/darkAqua, then order front.
   - Re-sample off-main at ~1 Hz while the docked panel is visible; apply on main only when the polarity actually changes; timer stops on hide.
   - On hide, and whenever the target switches to the bare bar: `panel.appearance = nil` — the window-wide pin must not govern the bare state.

3. **`WashView.swift`** — comment rewrite only. `resolveTint()`'s "platform limit" paragraph now describes the real driver: the window's appearance is pinned from a backdrop sample, so `effectiveAppearance` resolves to the sampled polarity. The logic is unchanged — and the 2026-09-02 measurement that the glass's own flip is unreadable in-process still stands and keeps governing the bare bar.

4. **`OverlayView.swift`** — header comment touch-up only. The intended visual change (§0.4) is exactly the panel's polarity; nothing else drawn.

5. **`DECISIONS.md`** — append the row.

6. **Tests `SottoTests/BackdropSampleTests.swift`** — the pure mapping only: synthetic white/black `CGImage`s → luminance ≈ 1/0 → light/dark. The capture itself is verified on screen, not in unit tests.

## Done when

In system Dark Mode: the docked panel over a white document renders the **light** wash with dark transcript text and a light ask-bar; over a dark backdrop it renders **dark**. The bare bar still flips per frame over the same white doc. Both verified by window-rect screenshots (build with explicit `DEVELOPER_DIR`; Sotto left running per §0.8), §14 grep run, tests green.

## Notes and named risks

- First-ever docked open triggers the TCC prompt for users; on this machine Screen Recording is already granted (design.md §8.1), so testing sees no prompt.
- A backdrop split half light/half dark resolves to the majority side — the same sRGB averaging the glass itself does. Pathological splits can disagree with the bar; threshold is one edit.
- If a wrong-polarity flash still appears at open despite sampling-first, that is the named suspicion to chase, not a value to tune.