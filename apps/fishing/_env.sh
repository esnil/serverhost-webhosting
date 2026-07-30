# _env.sh — delad env-resolver för fishing deploy/feedback-skripten (jlsk RM254).
#
# SOURCEAS (aldrig körs direkt) av deploy.sh, feedback-sync.sh och feedback-report.sh.
# Resolvar exakt samma variabler som deploy.sh gjorde inline: SCRIPT_DIR, REPO_ROOT,
# .env-inläsning, VPS_HOST, VPS_USER, APP_DIR och SSH — så beteendet är oförändrat.

# Katalogen där skripten bor (apps/fishing) — härleds ur DENNA fils sökväg, oavsett
# vilket skript som sourceade den (alla tre ligger i samma katalog).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Ladda lokala hemligheter/overrides om de finns (checkas aldrig in).
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi

VPS_HOST="${VPS_HOST:-217.154.83.127}"
VPS_USER="${VPS_USER:-deploy}"
APP_DIR="${APP_DIR:-$REPO_ROOT/../jlsk/jlsk-fishing}"
SSH="ssh ${VPS_USER}@${VPS_HOST}"
