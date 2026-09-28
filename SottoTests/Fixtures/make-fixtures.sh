#!/bin/zsh
# Regenerates the checked-in speech fixtures. Synthetic `say` audio is a FLOOR for
# transcription accuracy, not a real-microphone figure (rules/audio-and-transcription.md §5).
# Needs the English (Samantha) and Spanish (Mónica, es_ES) voices: `say -v '?'`.
set -euo pipefail
cd "${0:A:h}"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# aiff -> 16 kHz mono 16-bit CAF
caf() { afconvert -f caff -d LEI16@16000 -c 1 "$1" "$2"; }

say -v Samantha -o "$tmp/fill.aiff" \
  "Um, uh, like, I I I think we should meet at three, no wait, actually four. [[slnc 1200]] Then we can review the budget."
caf "$tmp/fill.aiff" en-fillers.caf

say -v "Mónica" -o "$tmp/es.aiff" \
  "Buenos días, quiero reservar una mesa para cuatro personas. [[slnc 1200]] Gracias por su ayuda."
caf "$tmp/es.aiff" es-basic.caf

say -v Samantha -o "$tmp/cs-en.aiff" "Please send the report to the team today, and"
say -v "Mónica" -o "$tmp/cs-es.aiff" "también necesito la reunión de mañana"
caf "$tmp/cs-en.aiff" "$tmp/cs-en.caf"; caf "$tmp/cs-es.aiff" "$tmp/cs-es.caf"
python3 - "$tmp" <<'PY'
import sys, wave
t = sys.argv[1]
# CAF is not readable by `wave`; go through WAV.
import subprocess
for n in ("cs-en", "cs-es"):
    subprocess.check_call(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", f"{t}/{n}.caf", f"{t}/{n}.wav"])
frames = b""
params = None
for n in ("cs-en", "cs-es"):
    with wave.open(f"{t}/{n}.wav") as w:
        params = w.getparams(); frames += w.readframes(w.getnframes())
with wave.open(f"{t}/cs.wav", "wb") as o:
    o.setparams(params); o.writeframes(frames)
PY
afconvert -f caff -d LEI16@16000 -c 1 "$tmp/cs.wav" en-codeswitch.caf

say -v Samantha -o "$tmp/vocab.aiff" \
  "Please ask Quenthara to book the Zorbelix conference room for Friday."
caf "$tmp/vocab.aiff" en-vocab.caf

ls -l *.caf
