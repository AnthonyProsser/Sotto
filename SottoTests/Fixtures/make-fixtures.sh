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

# Language-detection spike set (LanguageDetectionProbe): short sentences, two or three
# voices per language, each language with a 2-3 word utterance (the hard case).
# name|voice|text
sentences=(
  "en-q1|Samantha|Please send me the quarterly report by Friday."
  "en-q2|Daniel|I think we should move the meeting to Thursday afternoon because half the team is travelling."
  "en-q3|Reed (English (US))|The new build is ready for testing."
  "en-short1|Samantha|Sounds good, thanks."
  "en-short2|Daniel|Call me later."
  "en-long|Samantha|When you get a chance, could you look over the draft and let me know whether the second section makes sense, since I want to send it to the client before the end of the day."
  "es-q1|Mónica|Por favor envíame el informe trimestral antes del viernes."
  "es-q2|Paulina|Creo que deberíamos mover la reunión al jueves por la tarde porque la mitad del equipo está de viaje."
  "es-q3|Reed (Spanish (Mexico))|La nueva versión está lista para las pruebas."
  "es-short1|Mónica|Suena bien, gracias."
  "es-short2|Paulina|Llámame luego."
  "es-long|Mónica|Cuando tengas un momento, ¿podrías revisar el borrador y decirme si la segunda sección tiene sentido? Quiero enviarlo al cliente antes de que termine el día."
)
for row in "${sentences[@]}"; do
  name=${row%%|*}; rest=${row#*|}; voice=${rest%%|*}; text=${rest#*|}
  say -v "$voice" -o "$tmp/$name.aiff" "$text"
  caf "$tmp/$name.aiff" "$name.caf"
done

ls -l *.caf
