# docs/ — synced copies

The three markdown files beside this one are **copies**. They came from:

```
/Users/anthonyprosser/Documents/Sotto/
```

which is the source of truth and the only place they get edited.

**Synced: 2026-08-13** (`sotto-tokens.md` re-synced later the same day, after Design.pdf was folded into §6). At sync time all three were byte-identical to their originals (verified by `md5sum`).

| File | Original |
|---|---|
| `sotto-spec.md` | `Documents/Sotto/sotto-spec.md` — v0.18 |
| `sotto-build-order.md` | `Documents/Sotto/sotto-build-order.md` — sixteen slices, 0–15 |
| `sotto-tokens.md` | `Documents/Sotto/sotto-tokens.md` — the token template |

## Not to be edited here

**Nothing in this directory is edited.** Not a typo, not a status marker, not a decision. The whole value of a copy is that it is provably identical to the original; the moment it diverges, nobody can tell which file is real.

Decisions made during a build session go in `../DECISIONS.md`. Anthony folds them into the originals, then re-syncs.

## Re-sync

```sh
cp /Users/anthonyprosser/Documents/Sotto/{sotto-spec.md,sotto-build-order.md,sotto-tokens.md} /Users/anthonyprosser/Code/Sotto/docs/
```

Then update the sync date above, and flip the folded-back column in `../DECISIONS.md` for everything the new spec now covers.

## Not copied

`Documents/Sotto/designs/Design.pdf` holds the four locked design decisions (overlay bar, waveform and HUD, icons, in-app chat), locked 2026-08-11. **Every measurement in it has been transcribed into `sotto-tokens.md` §6 with both points and ratios**, so the PDF is a source rather than a dependency. It is not duplicated here — it is a binary that would go stale silently.
