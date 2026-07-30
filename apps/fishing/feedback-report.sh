#!/usr/bin/env bash
#
# feedback-report.sh — applicera feedback-STATUS till Öppen-driften på begäran, precis efter
# triage, UTAN att bygga/deploya någon image (jlsk RM254). Kör INGEN build/compose/traefik.
#
# Policy (Eskils beslut): planned + declined appliceras DIREKT (bekräftar deltagaren snabbt;
# ingen version inblandad). `done`-rader LÄMNAS KVAR i kön — de appliceras av deployen som
# faktiskt skeppar fixen (då blir resolved_version rätt). deploy.sh fortsätter applicera ALLT.
#
# Kön/manifestet bor i jlsk-repot: <APP_DIR>/feedback/pending-status.jsonl resp. manifest.json.
# Efter apply: COMMITTA den uppdaterade kön + det färska manifestet.
#
# Användning (från serverhost-webhosting/):
#   ./apps/fishing/feedback-report.sh
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_env.sh"

JF_QUEUE="$APP_DIR/feedback/pending-status.jsonl"
JF_MANIFEST="$APP_DIR/feedback/manifest.json"

if [ ! -f "$JF_QUEUE" ]; then
    echo "Ingen kö-fil ($JF_QUEUE) — inget att applicera."
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
APPLY_FILE="$TMP_DIR/apply.jsonl"   # planned + declined → appliceras nu
KEEP_FILE="$TMP_DIR/keep.jsonl"     # done (m.fl.) → behålls i kön

# Splittra kön ROBUST med python3 (riktig JSONL-parsning, INTE grep — statusord kan förekomma
# i fritext/note-fält). Varje rad bevaras ORDAGRANT (samma JSON, inkl. ev. note/version).
python3 - "$JF_QUEUE" "$APPLY_FILE" "$KEEP_FILE" <<'PY'
import json
import sys

src, apply_path, keep_path = sys.argv[1], sys.argv[2], sys.argv[3]
apply_lines: list[str] = []
keep_lines: list[str] = []

with open(src, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            # Okänd/trasig rad: behåll den hellre än att tappa den.
            keep_lines.append(line)
            continue
        status = obj.get("status")
        if status in ("planned", "declined"):
            apply_lines.append(line)   # bevara raden ordagrant
        else:
            keep_lines.append(line)    # done (och allt annat) behålls i kön

with open(apply_path, "w", encoding="utf-8") as fh:
    if apply_lines:
        fh.write("\n".join(apply_lines) + "\n")
with open(keep_path, "w", encoding="utf-8") as fh:
    if keep_lines:
        fh.write("\n".join(keep_lines) + "\n")

print(f"    planned/declined att applicera: {len(apply_lines)}", file=sys.stderr)
print(f"    done att behålla i kön:         {len(keep_lines)}", file=sys.stderr)
PY

if [ -s "$APPLY_FILE" ]; then
    echo "==> Applicerar planned + declined DIREKT mot driften (ingen deploy, ingen version)"
    if "$SCRIPT_DIR/feedback-sync.sh" "$APPLY_FILE"; then
        # Skriv om lokala kön så att BARA de kvarvarande raderna (done m.fl.) blir kvar.
        # KEEP_FILE innehåller dem ordagrant; en tom KEEP_FILE ger en tömd kö (allt applicerades).
        mv "$KEEP_FILE" "$JF_QUEUE"
        echo ""
        echo "    Applicerat: planned + declined. Kön innehåller nu bara kvarvarande done-rader"
        echo "    (de appliceras av deployen som skeppar fixen)."
        echo "    ➜ COMMITTA: uppdaterad $JF_QUEUE + färskt $JF_MANIFEST"
    else
        echo "    VARNING: apply misslyckades — lokala kön LÄMNAS ORÖRD (idempotent, försök igen)." >&2
        exit 1
    fi
else
    echo "==> Inga planned/declined-rader i kön — inget destruktivt görs."
    echo "    Re-exporterar bara manifestet från driften."
    # Tom apply-fil ⇒ feedback-sync.sh hoppar över apply och re-exporterar bara manifestet.
    if ! "$SCRIPT_DIR/feedback-sync.sh" "$APPLY_FILE"; then
        echo "    VARNING: manifest-export misslyckades — behåller föregående manifest." >&2
    fi
    echo "    ➜ COMMITTA det färska $JF_MANIFEST om det ändrats."
fi

echo "==> Klart."
