#!/usr/bin/env python3
"""Parse OpenCode JSON event streams and write the morning report."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def load_events(path: Path) -> list[object]:
    text = path.read_text(errors="replace")
    events: list[object] = []
    decoder = json.JSONDecoder()
    idx = 0
    n = len(text)
    while idx < n:
        while idx < n and text[idx].isspace():
            idx += 1
        if idx >= n:
            break
        try:
            obj, end = decoder.raw_decode(text, idx)
        except json.JSONDecodeError:
            nl = text.find("\n", idx)
            if nl < 0:
                break
            idx = nl + 1
            continue
        events.append(obj)
        idx = end
    if not events:
        for line in text.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def walk(node: object):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


def model_from(value: object) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    if isinstance(value, dict):
        provider = value.get("providerID") or value.get("provider")
        ident = value.get("id") or value.get("modelID") or value.get("modelId")
        if provider and ident:
            return f"{provider}/{ident}"
        if isinstance(value.get("model"), str):
            return value["model"]
    return None


def extract_models(events: list[object]) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    keys = {"model", "modelID", "modelId"}
    for event in events:
        for obj in walk(event):
            for key in keys:
                if key not in obj:
                    continue
                ident = model_from(obj[key])
                if ident and ident not in seen:
                    seen.add(ident)
                    found.append(ident)
    return found


def extract_session(events: list[object]) -> str | None:
    for event in events:
        for obj in walk(event):
            for key in ("sessionID", "sessionId", "session_id"):
                value = obj.get(key)
                if isinstance(value, str) and value:
                    return value
            info = obj.get("info")
            if isinstance(info, dict):
                ident = info.get("id") or info.get("sessionID")
                if isinstance(ident, str) and ident and obj.get("type") in {
                    "session.created",
                    "session.updated",
                    "session.status",
                }:
                    return ident
    return None


def extract_text(events: list[object]) -> str:
    parts: list[str] = []
    for event in events:
        if not isinstance(event, dict):
            continue
        etype = event.get("type") or event.get("event")
        props = event.get("properties") if isinstance(event.get("properties"), dict) else event
        if etype in {"text", "message", "message.updated"}:
            for key in ("text", "part", "delta", "content"):
                value = props.get(key) if isinstance(props, dict) else None
                if isinstance(value, str) and value:
                    parts.append(value)
        part = props.get("part") if isinstance(props, dict) else None
        if isinstance(part, dict) and part.get("type") in {"text", "output"}:
            text = part.get("text") or part.get("content")
            if isinstance(text, str) and text:
                parts.append(text)
        if isinstance(event.get("text"), str):
            parts.append(event["text"])
    return "\n".join(parts)


def extract_errors(events: list[object]) -> list[str]:
    errors: list[str] = []
    for event in events:
        for obj in walk(event):
            etype = str(obj.get("type") or "")
            if "error" in etype.lower() or obj.get("error"):
                err = obj.get("error") or obj.get("message") or obj
                errors.append(err if isinstance(err, str) else json.dumps(err)[:500])
    return errors


def load_allowlist(path: Path) -> set[str]:
    allowed: set[str] = set()
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            allowed.add(line)
    return allowed


def model_allowed(model: str, allowed: set[str]) -> bool:
    if model in allowed:
        return True
    if f"opencode/{model}" in allowed:
        return True
    return False


def verdict_of(text: str) -> str:
    if re.search(r"VERDICT:\s*APPROVE", text, re.I):
        return "APPROVE"
    if re.search(r"VERDICT:\s*REJECT", text, re.I):
        return "REJECT"
    return "UNKNOWN"


def cmd_check_models(event_path: Path, allow_path: Path) -> int:
    events = load_events(event_path)
    allowed = load_allowlist(allow_path)
    models = extract_models(events)
    print("models:", ", ".join(models) if models else "(none found)")
    bad = [m for m in models if not model_allowed(m, allowed)]
    if bad:
        print("NON_ALLOWLISTED:", ", ".join(bad), file=sys.stderr)
        return 3
    errors = extract_errors(events)
    joined = " ".join(errors).lower()
    if any(s in joined for s in ("401", "402", "403", "429", "unavailable", "payment", "quota")):
        print("MODEL_UNAVAILABLE", file=sys.stderr)
        return 4
    return 0


def cmd_session(event_path: Path) -> int:
    session = extract_session(load_events(event_path))
    if not session:
        return 1
    print(session)
    return 0


def cmd_text(event_path: Path) -> int:
    sys.stdout.write(extract_text(load_events(event_path)))
    return 0


def cmd_verdict(event_path: Path) -> int:
    text = extract_text(load_events(event_path))
    verdict = verdict_of(text)
    print(verdict)
    return 0 if verdict != "UNKNOWN" else 1


def cmd_require_text(event_path: Path, needle: str) -> int:
    text = extract_text(load_events(event_path))
    if needle.lower() in text.lower():
        print("ok")
        return 0
    print(text[-2000:])
    return 1


def cmd_write_report(state_dir: Path, dest: Path) -> int:
    ledger_path = state_dir / "ledger.json"
    ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else {}
    dest.write_text(render_report(ledger))
    print(dest)
    return 0


def render_report(ledger: dict) -> str:
    commits = ledger.get("commits") or []
    units = ledger.get("units") or []
    tests = ledger.get("tests") or []
    refusals = ledger.get("refusals") or []
    needs = ledger.get("needs_anthony") or []
    rollbacks = ledger.get("rollbacks") or []
    lines = [
        "# Sotto overnight morning report",
        "",
        f"- Start time: {ledger.get('start_time', 'unknown')}",
        f"- Stop time: {ledger.get('stop_time', 'unknown')}",
        f"- Deadline: {ledger.get('deadline', 'unknown')}",
        f"- Starting commit: {ledger.get('start_commit', 'unknown')}",
        f"- Ending commit: {ledger.get('end_commit', 'unknown')}",
        f"- Night branch: {ledger.get('branch', 'unknown')}",
        f"- Worktree: {ledger.get('worktree', 'unknown')}",
        f"- Exact model ID: {ledger.get('model', 'unknown')}",
        f"- Lead turns: {ledger.get('lead_turns', 0)}",
        f"- Explore calls (approx): {ledger.get('explore_calls', 'unknown')}",
        f"- Critic reviews: {ledger.get('critic_reviews', 0)}",
        f"- Units approved: {ledger.get('approved', 0)}",
        f"- Units rejected: {ledger.get('rejected', 0)}",
        f"- Units rolled back: {len(rollbacks)}",
        f"- Paid model used: {ledger.get('paid_model_used', 'no')}",
        f"- Main checkout modified: {ledger.get('main_modified', 'no')}",
        f"- Merge occurred: no",
        "",
        "## Commits created",
    ]
    if commits:
        lines.extend(f"- `{c}`" for c in commits)
    else:
        lines.append("- none")
    lines += ["", "## Files changed", f"- {ledger.get('diffstat', 'none')}"]
    lines += ["", "## Features / slices"]
    if units:
        for unit in units:
            lines.append(
                f"- [{unit.get('result', '?')}] {unit.get('title', '(untitled)')} "
                f"— {unit.get('justification', '').strip() or 'no justification recorded'}"
            )
    else:
        lines.append("- none landed")
    lines += ["", "## Tests"]
    if tests:
        for test in tests:
            lines.append(
                f"- `{test.get('command', '')}` → {test.get('result', '?')}"
            )
    else:
        lines.append("- none recorded")
    lines += ["", "## NEEDS-ANTHONY"]
    lines.extend(f"- {item}" for item in needs) if needs else lines.append("- none")
    lines += ["", "## Deliberate refusals"]
    lines.extend(f"- {item}" for item in refusals) if refusals else lines.append("- none recorded")
    lines += ["", "## Rollbacks"]
    lines.extend(f"- {item}" for item in rollbacks) if rollbacks else lines.append("- none")
    lines += [
        "",
        "## Unresolved issues",
        f"- {ledger.get('stop_reason', 'see stop time')}",
        "",
        "## Confirmation",
        f"- Model pinned to `{ledger.get('model', 'unknown')}`.",
        "- Supervisor refuses any other model ID.",
        "- Night branch only. Main was not merged and was not pushed to.",
    ]
    extra = ledger.get("notes")
    if extra:
        lines += ["", "## Notes", extra]
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: night-parse.py <command> [args]", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "check-models":
        return cmd_check_models(Path(argv[2]), Path(argv[3]))
    if cmd == "session":
        return cmd_session(Path(argv[2]))
    if cmd == "text":
        return cmd_text(Path(argv[2]))
    if cmd == "verdict":
        return cmd_verdict(Path(argv[2]))
    if cmd == "require-text":
        return cmd_require_text(Path(argv[2]), argv[3])
    if cmd == "write-report":
        return cmd_write_report(Path(argv[2]), Path(argv[3]))
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
