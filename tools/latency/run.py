#!/usr/bin/env python3
"""
Gesture-to-feedback latency harness — 2026-08-23.

Drives synthetic Right-Cmd holds against a running Sotto and reads the marks
back out of the unified log.

  warm  launch once, then N gestures a few seconds apart; the first is
        discarded because it is the cold one.
  cold  quit, wait, relaunch, one gesture. Repeated M times.

Traps this harness already accounts for, so they are not rediscovered:
  * Launch with `open`, never the binary inside the bundle — running the binary
    directly breaks TCC attribution and the tap then silently sees nothing.
  * zsh has a `log` builtin; /usr/bin/log is called explicitly.
  * The poster targets .cgSessionEventTap (see post-gesture.swift).
"""

import argparse, re, statistics, subprocess, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
POSTER = HERE / "post-gesture"
DEVDIR = "/Applications/Xcode.app/Contents/Developer"

# Marks in the order they should occur, so a run reads top to bottom.
ORDER = [
    "armed-signal", "armed-hud", "armed-first-frame",
    "cap-enter", "cap-permission", "cap-inputnode", "cap-armed", "cap-converter",
    "cap-engine-started", "armed-capture", "first-audio-buffer",
    "recognised", "main-hop", "hud-show-enter", "hud-ordered", "prewarm-returned",
    "capture-started", "hud-first-frame", "mic-closed",
]


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)


def app_path():
    out = sh(f"DEVELOPER_DIR={DEVDIR} xcodebuild -scheme Sotto -showBuildSettings").stdout
    for line in out.splitlines():
        if line.strip().startswith("BUILT_PRODUCTS_DIR ="):
            return Path(line.split("=", 1)[1].strip()) / "Sotto.app"
    sys.exit("could not resolve BUILT_PRODUCTS_DIR")


def quit_app():
    sh("pkill -x Sotto")
    time.sleep(1.5)


def launch(app):
    sh(f"open '{app}'")
    time.sleep(6)   # tap install + Dictation.prepare()'s async format resolve


def gesture(hold_ms):
    subprocess.run([str(POSTER), str(hold_ms)], capture_output=True)


def read_marks(since):
    """Every trial logged since `since`, as a list of {mark: ms}."""
    out = sh(
        "/usr/bin/log show --style compact --start '%s' "
        "--predicate 'subsystem == \"com.anthonyprosser.Sotto\" "
        "AND category == \"latency\"'" % since
    ).stdout
    trials, cur = [], None
    for line in out.splitlines():
        if "TRACE begin" in line:
            if cur:
                trials.append(cur)
            cur = {}
            continue
        m = re.search(r"TRACE (\S+) ([\d.]+)$", line.strip())
        if m and cur is not None and m.group(1) not in cur:
            cur[m.group(1)] = float(m.group(2))
    if cur:
        trials.append(cur)
    return trials


def table(title, trials):
    print(f"\n=== {title} — {len(trials)} trial(s) ===")
    if not trials:
        print("  no marks captured")
        return
    print(f"  {'mark':<22} {'median':>8} {'min':>8} {'max':>8}  n")
    prev = None
    for name in ORDER:
        vals = sorted(t[name] for t in trials if name in t)
        if not vals:
            continue
        med = statistics.median(vals)
        delta = f"  (+{med - prev:.1f})" if prev is not None else ""
        print(f"  {name:<22} {med:>8.1f} {vals[0]:>8.1f} {vals[-1]:>8.1f}  {len(vals)}{delta}")
        prev = med


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--warm", type=int, default=10, help="warm trials after the discarded cold one")
    ap.add_argument("--cold", type=int, default=5, help="quit/relaunch cycles")
    ap.add_argument("--hold", type=int, default=600, help="hold duration in ms")
    ap.add_argument("--settle", type=int, default=20, help="seconds quit before a cold launch")
    args = ap.parse_args()

    app = app_path()
    print(f"app: {app}")

    # ---- warm ----
    quit_app()
    start = time.strftime("%Y-%m-%d %H:%M:%S")
    launch(app)
    for i in range(args.warm + 1):
        gesture(args.hold)
        print(f"  warm gesture {i}/{args.warm}", flush=True)
        time.sleep(4)
    warm = read_marks(start)
    warm = warm[1:] if len(warm) > 1 else warm   # discard the cold first one

    # ---- cold ----
    cold = []
    for i in range(args.cold):
        quit_app()
        time.sleep(args.settle)
        start = time.strftime("%Y-%m-%d %H:%M:%S")
        launch(app)
        gesture(args.hold)
        print(f"  cold cycle {i + 1}/{args.cold}", flush=True)
        time.sleep(3)
        got = read_marks(start)
        if got:
            cold.append(got[0])
    quit_app()

    table("WARM (repeat dictation)", warm)
    table("COLD (first after launch)", cold)


if __name__ == "__main__":
    main()
