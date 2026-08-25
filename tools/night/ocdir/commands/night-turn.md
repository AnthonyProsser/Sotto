---
description: One overnight backend unit
agent: lead
model: opencode/x-preview-f-free
---

One overnight turn. Do exactly one coherent backend unit. Then stop.

Read `tools/night/state/STATE.md` if it exists. Inspect Slice 7 first. If nothing justified and non-visual remains, write `tools/night/state/STOP` and do not edit sources.

Otherwise pick ONE unit, write `tools/night/state/justification.md`, implement the smallest change, run targeted tests, and write `tools/night/state/proposed-commit.md`.

Do not start a second unit. Do not commit. Do not push.

If $ARGUMENTS includes a FIX directive, do not pick new work. Address only the named failure, then stop.
