#!/usr/bin/env bash
#
# check.sh — runnerflottans hälsa, KÖRS PÅ VPS:en. En källa till sanning för två konsumenter:
#
#   ./apps/ci-runner/health.sh            # lokalt: pipar den här filen över ssh, läsbar utskrift
#   check.sh --push   (cron, var 5:e min) # på VPS:en: samma kollar → Uptime Kuma push → Telegram
#
# Två frågor, två push-monitorer, för de har olika livslängd:
#
#   HÄLSA   — "tar runnerna jobb just nu?" Container igång, ingen omstartsloop, GitHub säger
#             online, GitHub vägrar inte versionen. Fel här är akuta.
#   VERSION — "måste imagen byggas om snart?" Runnern startas med --disableupdate och kan inte
#             uppdatera sig själv; GitHub slutar ta emot gamla versioner. Fel här är en deadline.
#
# Separata monitorer därför att Uptime Kuma bara larmar vid ÖVERGÅNG till down: en VERSION-varning
# som ligger röd i tre veckor får inte svälja ett akut HÄLSA-larm under tiden.
#
# Push-URL:erna bor i $DIR/monitor.env (chmod 600, bara på servern), INTE i .env — .env är
# env_file för containrarna, och jobbkod som ser push-URL:en kan förfalska "allt grönt".
#
#   UPTIME_PUSH_HEALTH=https://uptime.vps.encab.se/api/push/<token>
#   UPTIME_PUSH_VERSION=https://uptime.vps.encab.se/api/push/<token>
#
# Exit: 0 grönt, 1 något att titta på.
set -uo pipefail

DIR=/opt/hosting/apps/ci-runner
CONTAINERS="ci-runner ci-runner-gate"
STATE="$DIR/.check-failstreak"
PUSH=0
[ "${1:-}" = "--push" ] && PUSH=1

set -a
. "$DIR/.env"
[ -f "$DIR/monitor.env" ] && . "$DIR/monitor.env"
set +a
GH_REPO="${GH_REPO:-esnil/bus-analyzer}"
RUNNER_NAME_PREFIX="${RUNNER_NAME_PREFIX:-vps}"

health=()    # akuta fel, larmas efter två körningar i rad (deploy/efemära varv ger korta glapp)
urgent=()    # akuta fel som larmas DIREKT (GitHub har uttryckligen vägrat runnern)
version=()   # ombyggnad behövs snart

gh_api() {
    curl -fsS -m 20 -H "Authorization: Bearer $GH_PAT" \
        -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
}

# ── 1. Containrar ────────────────────────────────────────────────────────────────────────────
echo "── 1. Containrar ────────────────────────────────────────────"
now=$(date +%s)
for c in $CONTAINERS; do
    st="$(docker inspect -f '{{.State.Status}} {{.RestartCount}} {{.Config.Image}}' "$c" 2>/dev/null)"
    if [ -z "$st" ]; then
        echo "  $c: SAKNAS"; health+=("$c saknas — kör deploy.sh"); continue
    fi
    read -r status restarts image <<<"$st"
    # Omstartsloop: RestartCount duger inte, den stiger med flit — runnerna är efemära, varje
    # jobb = ett containervarv. Starter per 10 min skiljer: ett jobb tar minuter, en krasch-loop
    # (2026-11-05: GitHub vägrade 2.336.0) gav ett varv var 13:e sekund ≈ 45 per 10 min.
    starts=$(docker events --since "$((now - 600))" --until "$now" \
        --filter "container=$c" --filter event=start --format x 2>/dev/null | wc -l)
    echo "  $c: $status  (${image}, $starts starter senaste 10 min, $restarts totalt)"
    [ "$status" = "running" ] || health+=("$c är $status")
    [ "$starts" -gt 15 ] && health+=("$c omstartsloop: $starts starter på 10 min")

    # GitHubs uttryckliga vägran. Larmas direkt: den läker aldrig av sig själv.
    if docker logs --since 15m "$c" 2>&1 | grep -q 'is deprecated and cannot receive messages'; then
        urgent+=("$c: GitHub vägrar runnerversionen — bygg om (se README § Runnerversionen)")
    fi
done

# Disken. Containerns skrivlager växer per jobb: efemära varv återanvänder SAMMA container
# (restart-policyn), så _work och /tmp ackumuleras. 2026-11-06 hade ci-runner 38 GB efter 14 h.
# Mät med df, ALDRIG `docker ps -s` eller `docker diff`: de går igenom hela lagret inne i dockerd.
# Samma dag, mitt i ett `docker diff` av det lagret, dog dockerd och tog alla sajter med sig.
disk=$(df --output=pcent / | tail -1 | tr -dc 0-9)
echo "  disk /: ${disk}%"
[ "$disk" -ge 80 ] && health+=("disken är ${disk}% full — ci-runners skrivlager? docker compose up -d --force-recreate i $DIR")

# ── 2. GitHubs bild av flottan ──────────────────────────────────────────────────────────────
echo "── 2. GitHubs bild av flottan ───────────────────────────────"
if runners="$(gh_api "repos/$GH_REPO/actions/runners")"; then
    jq -r --arg p "$RUNNER_NAME_PREFIX-" '.runners[] |
        "  \(.name | . + " " * ([26 - length, 1] | max))\(.status)  busy=\(.busy)  [\([.labels[] | select(.type == "custom") | .name] | join(","))]\(if (.name | startswith($p)) then "  <- den här VPS:en" else "" end)"' \
        <<<"$runners"
    for c in $CONTAINERS; do
        n="$RUNNER_NAME_PREFIX-$c"
        s="$(jq -r --arg n "$n" '[.runners[] | select(.name == $n) | .status][0] // "saknas"' <<<"$runners")"
        [ "$s" = "online" ] || health+=("$n är $s hos GitHub")
    done
else
    echo "  KUNDE INTE FRÅGA GITHUB (PAT utgången/återkallad?)"
    health+=("GitHub-API:et svarar inte med PAT:en (utgången?)")
fi

# ── 3. Runnerversionen ──────────────────────────────────────────────────────────────────────
# GitHubs regel, härledd ur 2026-11-05: 2.336.0 vägrades 30 dagar efter att 2.338.0 släpptes
# (2.337.0 kom 71 dagar före och ändrade ingenting). Alltså: när det finns en release TVÅ minor
# över den vi kör, börjar en 30-dagarsklocka. Larmet går när klockan startar — 30 dagars
# framförhållning. Regeln är härledd, inte dokumenterad; därför finns vägran-kollen ovan kvar
# som backstopp.
echo "── 3. Runnerversionen ───────────────────────────────────────"
for c in $CONTAINERS; do
    v="$(docker exec "$c" grep -m1 -oE 'Runner.Listener/[0-9.]+' \
            /home/runner/bin/Runner.Listener.deps.json 2>/dev/null | cut -d/ -f2)"
    [ -n "$v" ] || v="$(docker logs "$c" 2>&1 | grep -oE "Current runner version: '[0-9.]+'" \
            | tail -1 | grep -oE '[0-9.]+')"
    echo "  $c: ${v:-okänd}"
    [ -n "$v" ] && running="$v"   # båda byggs ur samma Dockerfile-pin
done

if [ -z "${running:-}" ]; then
    version+=("kunde inte läsa runnerversionen ur containrarna")
elif releases="$(gh_api 'repos/actions/runner/releases?per_page=30')"; then
    verdict="$(jq -r --arg cur "$running" '
        def minor: ltrimstr("v") | split(".")[1] | tonumber;
        [.[] | select(.prerelease | not) | select(.draft | not)
             | {tag: .tag_name, m: (.tag_name | minor), d: .published_at[:10]}] as $r
        | ($cur | minor) as $cm
        | ($r | max_by(.tag | ltrimstr("v") | split(".") | map(tonumber))) as $latest
        | ($r | map(select(.m == $cm + 2)) | min_by(.d)) as $trigger
        | if $trigger == null then
              "OK senaste är \($latest.tag); kör 2.\($cm) — ingen deadline ännu"
                + (if $latest.m > $cm then " (klockan startar när 2.\($cm + 2) släpps)" else "" end)
          else
              "DUE \($trigger.tag) släpptes \($trigger.d); 2.\($cm) vägras troligen från "
                + (($trigger.d + "T00:00:00Z" | fromdateiso8601) + 30 * 86400 | strftime("%Y-%m-%d"))
                + " — senaste är \($latest.tag)"
          end' <<<"$releases")"
    echo "  ${verdict#* }"
    [[ "$verdict" == DUE* ]] \
        && version+=("Runner $running behöver byggas om: ${verdict#DUE }. Flytta RUNNER_IMAGE_TAG i bus-analyzer docker/runner/Dockerfile → deploy.sh")
else
    echo "  kunde inte hämta actions/runner-releaser"
    version+=("kunde inte hämta actions/runner-releaser")
fi

# ── 4. PAT:ens utgångsdatum ─────────────────────────────────────────────────────────────────
# Fine-grained PATs går ut. Då faller registreringen och flottan går ner exakt som vid en
# versionsvägran. GitHub skickar datumet i ett svarshuvud. Larmet går 14 dagar innan, på
# VERSION-monitorn ("underhåll behövs snart"), inte på HÄLSA.
echo "── 4. PAT ───────────────────────────────────────────────────"
exp="$(curl -sI -m 20 -H "Authorization: Bearer $GH_PAT" "https://api.github.com/repos/$GH_REPO" \
        | tr -d '\r' | awk -F': ' 'tolower($1) == "github-authentication-token-expiration" {print $2}')"
if [ -z "$exp" ]; then
    echo "  inget utgångsdatum rapporterat (PAT utan utgång, eller GitHub svarade inte)"
else
    days=$(( ( $(date -d "$exp" +%s) - now ) / 86400 ))
    echo "  går ut $exp (om $days dagar)"
    [ "$days" -lt 14 ] && version+=("GH_PAT går ut om $days dagar ($exp): ny PAT i apps/ci-runner/.env → deploy.sh --no-build")
fi

# ── Sammanfattning + push ───────────────────────────────────────────────────────────────────
# Debounce: HÄLSA-fel måste synas två körningar i rad (= 5–10 min) innan de larmas. En deploy
# eller ett efemärt varv ger ett glapp på sekunder som inte ska bli ett Telegram-meddelande.
streak=0
[ -f "$STATE" ] && streak="$(cat "$STATE" 2>/dev/null || echo 0)"
if [ ${#health[@]} -gt 0 ]; then streak=$((streak + 1)); else streak=0; fi
[ "$PUSH" = "1" ] && echo "$streak" > "$STATE"

alerts=("${urgent[@]}")
if [ ${#health[@]} -gt 0 ] && { [ "$PUSH" = "0" ] || [ "$streak" -ge 2 ]; }; then
    alerts+=("${health[@]}")
fi

join() { local IFS='; '; echo "$*"; }
push() {   # push <url> <up|down> <msg>
    [ -n "$1" ] || return 0
    curl -fsS -m 15 -o /dev/null \
        "$1?status=$2&msg=$(jq -rn --arg m "$3" '$m | @uri')&ping=" \
        || echo "  (push till Uptime Kuma misslyckades)" >&2
}

echo ""
rc=0
if [ ${#alerts[@]} -gt 0 ]; then
    echo "HÄLSA:   $(join "${alerts[@]}")"; rc=1
elif [ ${#health[@]} -gt 0 ]; then
    echo "HÄLSA:   väntar på bekräftelse ($streak/2): $(join "${health[@]}")"
else
    echo "HÄLSA:   grönt"
fi
if [ ${#version[@]} -gt 0 ]; then
    echo "VERSION: $(join "${version[@]}")"; rc=1
else
    echo "VERSION: grönt"
fi

if [ "$PUSH" = "1" ]; then
    if [ ${#alerts[@]} -gt 0 ]; then
        push "${UPTIME_PUSH_HEALTH:-}" down "$(join "${alerts[@]}")"
    else
        push "${UPTIME_PUSH_HEALTH:-}" up OK
    fi
    if [ ${#version[@]} -gt 0 ]; then
        push "${UPTIME_PUSH_VERSION:-}" down "$(join "${version[@]}")"
    else
        push "${UPTIME_PUSH_VERSION:-}" up "runner $running"
    fi
fi
exit "$rc"
