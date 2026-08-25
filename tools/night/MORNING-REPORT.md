# Sotto overnight morning report

- Start time: 2026-08-24 23:12:25 CDT
- Stop time: 2026-08-24 23:47:59 CDT (autonomous loop)
- Operator publish: 2026-08-25 ~06:45 CDT
- Deadline: 2026-08-25 06:00:00 CDT (coding) / 06:30 CDT (PR)
- Starting commit (overnight loop): `0f4be15`
- Ending commit (last approved unit): `b012aef`
- Night branch: `night/2026-08-24`
- Worktree: `/Users/anthonyprosser/Code/Sotto-night`
- Exact model ID: `opencode/x-preview-f-free`
- Lead turns: 2
- Explore calls: unknown
- Critic reviews: 1 (approve)
- Units approved: 1 during the overnight loop (plus the pre-launch gated Slice 8 unit)
- Units rejected: 0
- Units rolled back: 1 (self-test rollback probe only)
- Paid model used: no
- Main checkout modified: no (`main` remains `d86ed97`)
- Merge occurred: no
- PR created by supervisor overnight: no
- PR created by operator after the miss: yes (this publish)

## Why there was no PR at 06:30

The supervisor never reached `publish()`.

Turn 2 of the overnight loop invoked Ox Alpha as `opencode/x-preview-f-free`. The event stream also named the short id `x-preview-f-free`. The model IDs were allowed. The parser then treated a provider error containing “Endpoint is unavailable” as `MODEL_UNAVAILABLE` and the supervisor mapped every `check-models` failure to “non-allowlisted model in lead event stream.” It stopped at 23:47 with exit 1.

That stop is why GitHub had no `night/*` branch and no PR this morning. No paid model ran. Main was not touched.

Turn 2 also left unreviewed edits in `ModelDownload.swift` / `ModelDownloadTests.swift` (a pre-download `summarize` helper). Those were restored to `b012aef` before this publish.

## Commits on `night/2026-08-24` vs `main`

- `ab26b89` Add overnight autonomous engineering supervisor
- `7aa9b14` Harden overnight model probe and turn timeouts
- `db9b192` Point overnight tests at full Xcode
- `8738937` Count untracked files and require a critic verdict
- `0f4be15` Add Slice 8 backend: Hugging Face model acquisition plumbing
- `b012aef` Add ladder rung three: ollama pull, delegated
- (this commit) night: morning report

## Files changed vs `main`

- `.gitignore` — ignore `tools/night/state/`
- `Sotto/Chat/ModelDownload.swift` — Hugging Face download / resume / hash plumbing
- `Sotto/Chat/OllamaPull.swift` — delegated `ollama pull` for source-ladder rung three
- `SottoTests/Chat/ModelDownloadTests.swift`
- `tools/night/**` — isolated overnight supervisor, agents, allowlist, prompts

## Features / slices

- Slice 7 was inspected first. The named Done-when tests already existed and passed; the lead did not invent extra Slice 7 architecture.
- Slice 8 backend: on-disk detect, Hugging Face tree listing, resume, SHA-256 integrity, promotion. No model-list UI.
- Source-ladder rung three: `OllamaPull` shells out to a local `ollama pull`. No new manager / registry.
- Overnight machinery under `tools/night/` so daytime OpenCode is unchanged.

## Tests

Exact command used throughout:

```
xcodebuild -scheme Sotto -destination platform=macOS \
  -derivedDataPath /Users/anthonyprosser/Code/Sotto-night/tools/night/state/DerivedData \
  -only-testing:SottoTests test
```

- Early self-test baseline: fail (`xcode-select` pointed at Command Line Tools; `DEVELOPER_DIR` later forced to `/Applications/Xcode.app/Contents/Developer`)
- Subsequent baseline / unit-1 / gate / overnight baseline / overnight unit-1: pass

No performance measurements were recorded.

## NEEDS-ANTHONY

- none written by the lead
- Operator note: Ox Alpha became unavailable ~23:47. The loop stopped rather than failing over. That is the intended fail-closed behaviour, but the error was mislabeled.

## Deliberate refusals

- Paid models (self-test: `opencode/gpt-5.5` refused by the plugin)
- Edits to `docs/`
- `git push origin main` (agent denied)
- Slice 12 MCP client
- Visual / HUD / chat-window design
- Failover to any other free or paid model

## Rollbacks

- Self-test rollback probe (supervisor restore)
- Operator restore of the unreviewed turn-2 `ModelDownload.summarize` work before publish

## Unresolved issues

- Supervisor `check-models` treats the substring `unavailable` in any event error as a hard stop, then reports it as a non-allowlisted model. That killed the night at turn 2 and skipped publish.
- `publish()` also refuses to run after 06:30, so a late recovery cannot be done by re-invoking the supervisor.
- Remaining product work is still mostly UI: chat window, HUD, animations, screenshot UI.

## Confirmation

- Model pinned to `opencode/x-preview-f-free`. No paid model was used.
- Night branch only. Main was not modified, not pushed, and not merged.
- This PR is opened for human review. It is not merged.
