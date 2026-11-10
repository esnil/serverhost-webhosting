# serverhost-webhosting

Dockeriserad VPS-hostingplattform. En enkel, reproducerbar och Git-styrd VPS där varje app är en Docker Compose-app bakom Traefik.

## Arkitektur

```
GitHub repo → GitHub Actions (lint + build + push) → GHCR → VPS (docker compose pull + up + traefik restart)
```

VPS:en bygger aldrig images själv. GitHub Actions bygger, pushar till GHCR, VPS:en hämtar färdig image och startar om appen.

## Tech stack

| Del | Val |
|---|---|
| OS | Ubuntu Server LTS |
| Containers | Docker Engine + Compose plugin |
| Reverse proxy | Traefik v3 (labels-baserad routing) |
| HTTPS | Let's Encrypt via Traefik |
| Registry | GitHub Container Registry (GHCR) |
| CI/CD | GitHub Actions |
| Övervakning | Uptime Kuma på `uptime.vps.encab.se` |

## Faktisk repostruktur

```
serverhost-webhosting/
  CLAUDE.md
  docs/
    deploy-guide.md        # Guide för att driftsätta ny app
  scripts/
    01-create-deploy-user.sh
    02-install-docker.sh
    03-create-docker-networks.sh
    04-install-traefik.sh
    05-ci-runner-firewall.sh   # nätverksisolering för CI-runnern (körs som root på VPS:en)
  apps/
    status/                # React-statusfrontend, live på hello.vps.encab.se
      Dockerfile
      compose.yaml
      nginx.conf
      eslint.config.js
      package.json
      src/
        App.jsx
        App.module.css
        index.css
        main.jsx
      .github/
        workflows/
          status-ci.yml    # lint + docker build + push till GHCR
          status-deploy.yml # workflow_dispatch deploy via SSH
    hello/                 # Arkiverat nginx-exempel (används ej i produktion)
      compose.yaml
    uptime-kuma/           # Uptime Kuma (ingår i apps/status/compose.yaml, inte egen deploy)
      compose.yaml
    fishing/               # JLSK Fisketävling, källkod i separat repo, deploy via docker save/load
      compose.yaml
      deploy.sh
      README.md
    ci-runner/             # Self-hosted GitHub Actions-runner för bus-analyzer (ingen webbtjänst)
      compose.yaml
      deploy.sh
      health.sh
      check.sh             # hälsa + versionskoll; körs på VPS:en (health.sh och cron → Uptime Kuma)
      README.md
```

På VPS:en lever allt under `/opt/hosting/`.

## Produktionsmiljö

| Tjänst | URL | Beskrivning |
|---|---|---|
| Status-frontend | `hello.vps.encab.se` | React-app med Uptime Kuma-data, BasicAuth |
| Uptime Kuma | `uptime.vps.encab.se` | Monitoringpanel, egen autentisering |
| CI-runner | *(ingen URL)* | Self-hosted GitHub Actions-runner för `esnil/bus-analyzer` (full + liten prose-runner) |

Uptime Kuma och status-appen deployas tillsammans via `apps/status/compose.yaml`.

CI-runnern är ingen webbtjänst: inga portar, ingen Traefik-label, inte på `proxy`. Se
`apps/ci-runner/README.md` och avsnittet "CI-runner" nedan.

## Deploy-flöde

**GitHub Actions är primär deploy-metod. Använd alltid det i första hand.**

```
push till main → status-ci.yml → lint → docker build → push till GHCR
                                                              ↓
                                         status-deploy.yml (workflow_dispatch)
                                         → SSH → docker compose pull + up -d + docker restart traefik
```

Trigga deploy: GitHub → Actions → status-deploy → Run workflow → image_tag: `main`

SSH-deploy (fallback om Actions inte är tillgängligt):
```bash
ssh deploy@217.154.83.127 '
  cd /opt/hosting/apps/status &&
  IMAGE_TAG=main docker compose pull &&
  IMAGE_TAG=main docker compose up -d &&
  docker image prune -f --filter "until=168h" &&
  docker restart traefik
'
```

**OBS: deploy-workflow:en uppdaterar bara Docker-imagen, inte `compose.yaml` på servern.** Vid ändringar i `compose.yaml` — portnummer, nya env-variabler, volymer, Traefik-labels — måste filen kopieras manuellt till VPS:en innan deploy:

```bash
scp apps/<app>/compose.yaml deploy@217.154.83.127:/opt/hosting/apps/<app>/compose.yaml
ssh deploy@217.154.83.127 'cd /opt/hosting/apps/<app> && docker compose up -d && docker restart traefik'
```

Om detta missas och `compose.yaml` på servern är inaktuell kan appen starta med fel port, saknade volymer eller saknade env-variabler — symptom är bad gateway eller crash i containern.

**OBS:** `docker restart traefik` är obligatoriskt efter varje app-deploy. `docker compose up -d` återskapar containern med ny intern IP — Traefik håller kvar TCP-connections till gamla IP:n och hänger utan timeout. Traefik-omstarten rensar connection pool och förhindrar att sidan ser ut att vara nere direkt efter deploy.

**Traefik idleConnTimeout:** Konfigurerad till `3s` i `traefik.yaml` (`serversTransport.forwardingTimeouts.idleConnTimeout`). Backends som Node.js/uptime-kuma stänger idle keep-alive-connections efter ~5s. Traefiks default är 90s → stale connections → 504/hang för externa requests trots att backend mår bra. Symtom: TLS-handshake lyckas, 0 bytes tar emot, direkttester mot backend funkar. Fix: `docker restart traefik`.

## Nyckelprinciper

**Bygg inte på VPS:en.** Inga build-tools på servern — bara `docker` och `docker compose`.
Regeln gäller **appar**: de byggs i GitHub Actions och hämtas som färdig image. Ett medvetet
undantag finns, `apps/ci-runner`, och skälet står i dess README — CI-runner-imagen är ~5,4 GB,
består i praktiken bara av nedladdningar, och bus-analyzer är privat så GHCR-lagringen på
gratisplanen räcker inte. Inget build-tool landar på värden: bygget sker i `docker build`.

**Secrets:** `.env.example` checkas in, `.env` aldrig. GitHub Secrets: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_KNOWN_HOSTS`. Ingen `StrictHostKeyChecking=no`.

**Image-taggar:** `main` (senaste main-build), `<commit-sha>` (exakt version). Rollback = manuell deploy med äldre commit-sha-tagg.

**BasicAuth:** Lägg aldrig hash i Docker-labels eller `.env` — `$`-tecken expanderas av Docker Compose. Använd alltid Traefik dynamic config: `/opt/hosting/traefik/dynamic/<app>-auth.yaml` med `@file`-referens i labels.

**Linting:** Alla frontend-appar ska ha ESLint konfigurerat. CI-jobbet kör lint INNAN Docker-build för snabb feedback. `npm run lint` ska vara rent innan push.

**Databas:** SQLite per app med bind mount. Enkelt, isolerat och lätt att flytta/ta bort.

**Persistens:** Använd bind mounts till `/opt/hosting/apps/<app>/data/`, inte named volumes. Bind mounts är lättare att inspektera, säkerhetskopiera och flytta. Se avsnittet nedan.

## Persistens

Appar som behöver spara data (uppladdade filer, databaser, konfiguration) använder bind mounts till en `data/`-katalog bredvid `compose.yaml`.

### Katalogstruktur på VPS

```
/opt/hosting/apps/<app>/
  compose.yaml
  .env
  data/
    media/    # uppladdade filer (bilder, filmer)
    db/       # databasfiler (SQLite-fil eller Postgres-data)
```

Skapa datakatalogerna manuellt vid första setup — detta sker inte automatiskt via GitHub Actions:

```bash
mkdir -p /opt/hosting/apps/<app>/data/{media,db}
```

### compose.yaml-mönster med bind mounts

```yaml
services:
  app:
    volumes:
      - /opt/hosting/apps/<app>/data/media:/app/media
      - /opt/hosting/apps/<app>/data/db:/app/db
    environment:
      DATABASE_URL: sqlite:////app/db/app.db
```

### Backup

Backup-lösning för persistenta volymer är planerad (utan molntjänster). Tills vidare: känn till vad som lever under `/opt/hosting/apps/<app>/data/` och ta manuell backup innan riskfyllda operationer (tex deploy med schema-migreringar).

## Traefik-labels (standardmönster)

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<app>.rule=Host(`<app>.vps.encab.se`)"
  - "traefik.http.routers.<app>.entrypoints=websecure"
  - "traefik.http.routers.<app>.tls.certresolver=letsencrypt"
  - "traefik.http.services.<app>.loadbalancer.server.port=<port>"
```

Alla appar kopplas till det externa nätverket `proxy`.

## CI/CD-mönster per app

Varje app har två workflows:

**`<app>-ci.yml`** — triggas på push till main:
1. `lint` — kör `npm run lint` (eller motsvarande)
2. `build` (behöver lint) — `docker build` + `docker push` till GHCR

**`<app>-deploy.yml`** — `workflow_dispatch` med `image_tag`-input:
1. SSH till VPS
2. `docker compose pull && docker compose up -d`
3. `docker image prune`
4. `docker restart traefik`

### Pre-byggd base-image för Node.js-appar med native-moduler

Appar som kompilerar native-moduler (t.ex. `better-sqlite3`) tar lång tid att bygga i CI eftersom det kräver python3/make/g++. Lösningen är en separat `Dockerfile.base` som bygger production-deps och pushas som `<app>-base:main` till GHCR — huvud-`Dockerfile` kopierar bara kod ovanpå base-imagen.

**Filer:**
- `Dockerfile.base` — `FROM node:22-alpine`, installerar build-tools, kör `npm ci --omit=dev`
- `Dockerfile` — multi-stage: bygger kod i `node:22-alpine`, sen `FROM ${BASE_IMAGE}` (via `ARG BASE_IMAGE`) och kopierar dist

**CI-logik i build-jobbet:**
1. Pulla befintlig base-image från GHCR
2. Om `package*.json` eller `Dockerfile.base` ändrats (eller image saknas) → bygg och pusha ny base-image
3. Bygg alltid huvud-imagen med `--build-arg BASE_IMAGE=ghcr.io/<repo>/<app>-base:main`

Base-imagen behöver bara byggas om när beroenden ändras. Vanliga code-pushes hoppar direkt till steg 3 och slipper kompilering av native-moduler. Använd `actions/checkout@v5` och `actions/setup-node@v5` (v4 ger Node.js 20-deprecation-varning i GHA).

## CI-runner (bus-analyzer)

VPS:en är också **self-hosted GitHub Actions-runner** för det separata repot `esnil/bus-analyzer`.
Två containrar som long-pollar GitHub utåt och kör CI-jobb: `ci-runner` (full, tar allt) och
`ci-runner-gate` (1 CPU / 2 GB, labeln `gate` enbart: bara `guard` och `backend` på rena
prosa-PR:er, bus-analyzer RM924). Detaljerna — hur de registreras, varför PAT:en försvinner ur
processmiljön, felsökningstabell — står i `apps/ci-runner/README.md`. Det som är värt att veta *här*, för att inte bli överraskad:

**Den delar maskin med produktion.** 4 vCPU, 7,7 GB RAM, ingen swap, samma låda som
ostersundarn.se, fiske.ostersundarn.se, statussidan och Uptime Kuma. Därför är den hårt
inhägnad, och de tre inhägnaderna hänger ihop — ta inte bort en utan att förstå de andra:

1. **Resurstak** i `compose.yaml`: `cpus: 3.0`, `mem_limit: 4g`. Utan mem_limit väljer värdens
   OOM-killer offer efter RSS, och den vet inte att uptime-kuma betyder mer än en pytest-process.
   Med taket dör jobbet inne i containern: CI blir rött, sajterna lever.
2. **Eget nätverk** (`ci-runner`, 172.30.0.0/24) — aldrig `proxy`, inga portar, ingen
   Traefik-label. Runnern är därför **undantagen från repots `docker restart traefik`-regel**:
   Traefik vet inte att den finns.
3. **Brandvägg** via `scripts/05-ci-runner-firewall.sh` — REJECT från CI-subnätet mot alla
   RFC1918-mål (täcker de andra Docker-nätverken *och* publicerade portar, som DNAT:as dit) samt
   mot värdens ssh. Internet är öppet; runnern måste nå GitHub, apt, npm, crates.io och PyPI.
   Reglerna ligger i en systemd-oneshot som är `PartOf=docker.service`, så de kommer tillbaka
   både vid boot och när dockerd startas om.

**Exakt en FULL runner, med flit.** Prose-runnern räknas inte hit: den kör aldrig e2e, bridge
eller hela backend-sviten, och dess tyngsta steg toppar på ~475 MB. Två fulla hade blivit 2 kärnor
styck — samma maskin som bus-analyzers RM491-huvudvärk och RM527:s mätta Playwright-flake under parallell last. Skälen och vad som
gäller om en andra ändå behövs står i `apps/ci-runner/README.md`.

**Aldrig mot ett publikt repo.** En self-hosted runner på en produktionsvärd förutsätter att
fork-PR:er inte kan trigga körningar. `esnil/bus-analyzer` är privat — det är förutsättningen.

Deploy och hälsokoll:

```bash
./apps/ci-runner/deploy.sh          # bygg båda imagen PÅ VPS:en + starta båda
./apps/ci-runner/deploy.sh --gate   # bara prose-runnern (rör inte ci-runner mitt i ett jobb)
./apps/ci-runner/health.sh          # container + omstartsloop + GitHubs bild + runnerversion
```

`check.sh` körs också av cron på VPS:en var 5:e minut och larmar via Uptime Kuma-push → Telegram
(monitorerna `CI-runner` och `CI-runner version`). Runnern startas med `--disableupdate`, så den
**måste byggas om** när GitHub slutar ta emot versionen: versionsmonitorn larmar cirka 30 dagar
innan. Se `apps/ci-runner/README.md` § Runnerversionen.

En bus-analyzer-körning som **köar** i stället för att bli röd betyder att ingen matchande runner
är online — leta i `health.sh`, inte i diffen.

## Viktiga sökvägar

| Sökväg | Innehåll |
|---|---|
| `/opt/hosting/traefik/` | Traefik-konfiguration |
| `/opt/hosting/traefik/dynamic/auth.yaml` | BasicAuth-middleware |
| `/opt/hosting/apps/<app>/` | compose.yaml + .env per app |
| `/opt/hosting/apps/ci-runner/` | CI-runnerns compose.yaml + .env (PAT, chmod 600) |
| `/etc/systemd/system/ci-runner-firewall.service` | Nätverksisolering för CI-runnern |
