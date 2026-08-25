One overnight turn. Do exactly one coherent backend unit. Then stop.

## This turn

1. Read `tools/night/state/STATE.md` and `tools/night/state/ledger.json` if they exist.
2. Inspect the repository: Slice 7 first, then the next justified backend gap.
3. If nothing justified and non-visual remains, write `tools/night/state/STOP` with the reason and do not edit sources.
4. Otherwise pick ONE unit. Write `tools/night/state/justification.md` before editing.
5. Investigate. Use `@explore` if you need a map.
6. Implement the smallest change. Prefer modify-in-place.
7. Run targeted tests with `xcodebuild` for the test classes you touched.
8. Write `tools/night/state/proposed-commit.md`.
9. Do not start a second unit. Do not commit. Do not push.

If this message includes a FIX directive, do not pick new work. Address only the named test failure or critic reject, then stop.
