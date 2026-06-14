# serverhost-webhosting

Dockeriserad VPS-hostingplattform. En enkel, reproducerbar och Git-styrd VPS där varje app är en Docker Compose-app bakom Traefik.

## Arkitektur

```
GitHub repo → GitHub Actions → GHCR → VPS (Docker Compose + Traefik)
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

## Repostruktur

```
serverhost-webhosting/
  README.md
  docs/
    runbook.md
    security.md
    backup.md
    app-template.md
  scripts/
    01-create-deploy-user.sh
    02-install-docker.sh
    03-create-docker-networks.sh
    04-install-traefik.sh
  traefik/
    compose.yaml
    traefik.yaml
    dynamic/
    letsencrypt/
      .gitkeep
  apps/
    hello/
      compose.yaml
      .env.example
  templates/
    app/
      Dockerfile
      compose.yaml
      compose.prod.yaml
      .env.example
      .github/
        workflows/
          ci.yml
          deploy.yml
          ghcr-retention.yml
```

På VPS:en lever allt under `/opt/hosting/`.

## Nyckelprinciper

**Bygg inte på VPS:en.** Inga build-tools på servern — bara `docker` och `docker compose`.

**Secrets:** `.env.example` checkas in, `.env` aldrig. GitHub Secrets: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_KNOWN_HOSTS`. Ingen `StrictHostKeyChecking=no`.

**Image-taggar:** `latest`, `main`, `<commit-sha>`, `v*`. Rollback = manuell deploy med äldre commit-sha-tagg.

**Databas:** Börja med en container per app (isolerat, lätt att flytta/ta bort).

**Retention:** Tre nivåer — GHCR (behåll latest/main/v*, senaste 20 SHA), VPS (`docker image prune -f --filter "until=168h"` efter deploy), GitHub Actions artifacts (7–14 dagar).

## Traefik-labels (standardmönster)

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<app>.rule=Host(`<app>.example.com`)"
  - "traefik.http.routers.<app>.entrypoints=websecure"
  - "traefik.http.routers.<app>.tls.certresolver=letsencrypt"
  - "traefik.http.services.<app>.loadbalancer.server.port=3000"
```

Alla appar kopplas till det externa nätverket `proxy`.

## Deploy-flöde

Lokalt: `docker compose up --build`

Produktion: `docker compose -f compose.yaml -f compose.prod.yaml up -d`

Manuell deploy triggas via `workflow_dispatch` i GitHub Actions med input `image_tag`.

## Rekommenderad byggnadsordning

1. Scripts för VPS-bas (användare, Docker, nätverk)
2. Traefik-konfiguration
3. Testapp `hello` (verifierar DNS, HTTPS, Traefik, logs)
4. App-template
5. CI-workflow (bygg + push till GHCR)
6. Deploy-workflow (SSH + `workflow_dispatch`)
7. GHCR-retention workflow
8. Backup-script
9. Enkel övervakning (Uptime Kuma)
