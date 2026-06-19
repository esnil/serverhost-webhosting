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
```

På VPS:en lever allt under `/opt/hosting/`.

## Produktionsmiljö

| Tjänst | URL | Beskrivning |
|---|---|---|
| Status-frontend | `hello.vps.encab.se` | React-app med Uptime Kuma-data, BasicAuth |
| Uptime Kuma | `uptime.vps.encab.se` | Monitoringpanel, egen autentisering |

Uptime Kuma och status-appen deployas tillsammans via `apps/status/compose.yaml`.

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

**OBS:** `docker restart traefik` är obligatoriskt efter varje app-deploy. `docker compose up -d` återskapar containern med ny intern IP — Traefik håller kvar TCP-connections till gamla IP:n och hänger utan timeout. Traefik-omstarten rensar connection pool och förhindrar att sidan ser ut att vara nere direkt efter deploy.

## Nyckelprinciper

**Bygg inte på VPS:en.** Inga build-tools på servern — bara `docker` och `docker compose`.

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

## Viktiga sökvägar

| Sökväg | Innehåll |
|---|---|
| `/opt/hosting/traefik/` | Traefik-konfiguration |
| `/opt/hosting/traefik/dynamic/auth.yaml` | BasicAuth-middleware |
| `/opt/hosting/apps/<app>/` | compose.yaml + .env per app |
