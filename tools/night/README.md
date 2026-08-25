# Sotto overnight supervisor

External loop. Not a model. Runs in the `Sotto-night` worktree on `night/2026-08-24` only.

## What it is

- Supervisor: `bin/sotto-night`
- Isolated OpenCode config: `opencode.json` via `OPENCODE_CONFIG`
- Isolated plugin/command dir: `ocdir/` via `OPENCODE_CONFIG_DIR`
- Team: `lead` (implements), `explore` (read-only), `critic` (read-only, supervisor-invoked)
- Model: `opencode/x-preview-f-free` only. No failover.

Do not add a project-root `opencode.json` or `.opencode/`. Those would change daytime sessions.

## Deadlines (local)

- No new implementation after 05:35
- Hard stop 06:00
- Push + PR by 06:30, never merged

## Commands

```bash
# safety checks (does not start the night)
/Users/anthonyprosser/Code/Sotto-night/tools/night/bin/sotto-night --self-test

# one turn, no push
MAX_TURNS=1 /Users/anthonyprosser/Code/Sotto-night/tools/night/bin/sotto-night --no-publish --max-turns 1

# overnight
/Users/anthonyprosser/Code/Sotto-night/tools/night/bin/sotto-night
```

## Morning

```bash
cd /Users/anthonyprosser/Code/Sotto-night
less tools/night/MORNING-REPORT.md
git log --oneline main..HEAD
```

The PR is the review boundary. Do not merge it automatically.

## Runtime

`tools/night/state/` is gitignored. It holds event streams, test logs, and the ledger. Do not commit it.
