#!/usr/bin/env bash
#
# feedback-sync.sh — applicera EN given feedback-kö-fil mot Öppen-driften och
# re-exportera manifestet till git-arbetskopian. Delad kärna som BÅDE deploy.sh och
# feedback-report.sh anropar (jlsk RM144/RM254) — en enda implementation, ingen dubblering.
#
# Användning (från serverhost-webhosting/):
#   ./apps/fishing/feedback-sync.sh <kö-fil>
#
# Gör:
#   1. Skeppar <kö-fil> in i containern (lokal fil → stdin → /tmp) — men bara om filen är icke-tom.
#   2. Kör `feedback.php apply-pending /tmp/jf-pending.jsonl` i containern (idempotent).
#   3. Re-exporterar ALLTID manifestet till <APP_DIR>/feedback/manifest.json (atomisk mv,
#      best-effort — lämnar aldrig ett trasigt manifest).
#
# RÖR INTE någon lokal kö — anroparen bestämmer vad som töms/behålls.
# Exit 0 om apply lyckades eller inget fanns att applicera; icke-noll om apply-steget misslyckades.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_env.sh"

QUEUE_FILE="${1:-}"
if [ -z "$QUEUE_FILE" ]; then
    echo "FEL: feedback-sync.sh kräver en kö-fil som argument." >&2
    exit 2
fi

JF_MANIFEST="$APP_DIR/feedback/manifest.json"
apply_rc=0

if [ -s "$QUEUE_FILE" ]; then
    echo "==> Feedback-synk (RM144): applicerar köade statusövergångar ($QUEUE_FILE)"
    # Skeppa kön in i containern (lokal fil → stdin → /tmp) och applicera (idempotent, best-effort).
    $SSH "docker exec -i fishing sh -c 'cat > /tmp/jf-pending.jsonl'" < "$QUEUE_FILE" || true
    if $SSH "docker exec fishing php /app/bin/feedback.php apply-pending /tmp/jf-pending.jsonl"; then
        echo "    kön applicerad i driften"
    else
        apply_rc=1
        echo "    VARNING: apply-pending misslyckades (idempotent — kön behålls av anroparen)"
    fi
else
    echo "==> Feedback-synk (RM144): tom kö-fil — inget att applicera"
fi

# Re-exportera manifestet till git-arbetskopian. `manifest -` skriver REN JSON till stdout →
# strömma genom SSH direkt till arbetskopian. Skriv till en temp och flytta atomiskt bara vid
# lyckad export, så ett fel aldrig lämnar ett trasigt manifest.
echo "==> Feedback-synk (RM144): exporterar manifestet till git-arbetskopian"
mkdir -p "$(dirname "$JF_MANIFEST")"
if $SSH "docker exec -e JF_MANIFEST_SOURCE=open:fiske.ostersundarn.se fishing php /app/bin/feedback.php manifest -" > "$JF_MANIFEST.tmp"; then
    mv "$JF_MANIFEST.tmp" "$JF_MANIFEST"
    echo "    manifest → $JF_MANIFEST"
else
    rm -f "$JF_MANIFEST.tmp"
    echo "    VARNING: manifest-export misslyckades — behåller föregående manifest"
fi

exit "$apply_rc"
