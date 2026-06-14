# VPS Docker Hosting Platform

Förslag på repo-namn: **`hosting-server`**

Alternativ om du vill vara mer explicit:

- `vps-hosting-platform`
- `docker-hosting-server`
- `selfhosted-app-platform`
- `personal-hosting-vps`

Jag skulle välja **`hosting-server`** om repot bara ska innehålla VPS-plattformen, scripts, Traefik-konfiguration och mallar.  
Om du vill att namnet tydligt ska visa att detta är Docker/Compose-baserat är **`vps-hosting-platform`** bättre.

---

## Syfte

Det här repot beskriver och innehåller grunden för en dockeriserad hostingserver på en tom VPS.

Målet är att kunna:

- hosta flera små webbappar på samma VPS
- utveckla och provköra appar lokalt med Docker Compose
- bygga Docker-images i GitHub Actions
- publicera images till GitHub Container Registry, GHCR
- deploya manuellt eller automatiskt till VPS via GitHub Actions
- köra appar bakom reverse proxy med HTTPS
- ha retention/rensning för gamla images, backups och GitHub Actions-artifacts
- använda OpenAI Codex som hjälp för att bygga plattformen och apparna

---

## Övergripande arkitektur

```text
GitHub repo
  ├─ app-kod
  ├─ Dockerfile
  ├─ compose.yaml
  ├─ compose.prod.yaml
  └─ .github/workflows/

GitHub Actions
  ├─ testar appen
  ├─ bygger Docker image
  ├─ pushar image till GHCR
  └─ deployar till VPS via SSH

VPS
  ├─ Ubuntu Server
  ├─ Docker Engine
  ├─ Docker Compose plugin
  ├─ Traefik reverse proxy
  ├─ appar som Docker-containers
  ├─ Docker-volymer för data
  ├─ backupjobb
  └─ logg- och image-retention
```

---

## Vald teknik

| Del | Val | Kommentar |
|---|---|---|
| Operativsystem | Ubuntu Server LTS | Stabilt och vanligt för Docker-hosting |
| Containerdrift | Docker Engine | Räcker bra för en ensam VPS |
| Orkestrering | Docker Compose | Enklare än Kubernetes för småprojekt |
| Reverse proxy | Traefik | Bra Docker-integration via labels |
| HTTPS | Let's Encrypt via Traefik | Automatisk certifikathantering |
| Registry | GitHub Container Registry, GHCR | Passar bra ihop med GitHub Actions |
| CI/CD | GitHub Actions | Bygger image och deployar till VPS |
| AI-kodning | OpenAI Codex | Används lokalt mot repo, inte oövervakat i produktion |

---

## Rekommenderad repostruktur

För plattformsrepot:

```text
hosting-server/
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

På VPS:en:

```text
/opt/hosting/
  traefik/
    compose.yaml
    traefik.yaml
    dynamic/
    letsencrypt/
  apps/
    hello/
      compose.yaml
      .env
    app1/
      compose.yaml
      .env
    app2/
      compose.yaml
      .env
  backups/
  scripts/
```

---

## Grundprinciper

### Bygg inte på VPS:en

VPS:en ska helst inte behöva Node, Rust, .NET SDK eller liknande utvecklingsverktyg.

Rätt flöde:

```text
GitHub Actions bygger image
GitHub Actions pushar image till GHCR
VPS:en hämtar färdig image
Docker Compose startar om appen
```

Fördelar:

- renare VPS
- enklare rollback
- färre byggberoenden i produktion
- samma image kan köras lokalt, i test och i produktion

---

## Fas 1: Säkra VPS:en

Gör detta först.

1. Skapa en vanlig deploy-användare, exempelvis `deploy`.
2. Stäng av SSH-login för root.
3. Stäng av lösenordsinloggning via SSH.
4. Tillåt bara SSH-nycklar.
5. Aktivera brandvägg.
6. Öppna endast nödvändiga portar:
   - `22/tcp` eller vald SSH-port
   - `80/tcp`
   - `443/tcp`
7. Uppdatera servern.
8. Installera Docker Engine.
9. Installera Docker Compose plugin.
10. Sätt Docker-loggrotation.

Exempel på Docker-loggrotation:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

Läggs normalt i:

```text
/etc/docker/daemon.json
```

Starta sedan om Docker:

```bash
sudo systemctl restart docker
```

---

## Fas 2: Skapa Docker-nätverk

Skapa ett gemensamt nätverk för reverse proxy och appar:

```bash
docker network create proxy
```

Alla publika appar kopplas till detta nätverk.

---

## Fas 3: Sätt upp Traefik

Traefik används som reverse proxy och hanterar HTTPS.

Exempelstruktur:

```text
/opt/hosting/traefik/
  compose.yaml
  traefik.yaml
  letsencrypt/
```

Exempel på `compose.yaml` för Traefik:

```yaml
services:
  traefik:
    image: traefik:v3
    container_name: traefik
    restart: unless-stopped
    command:
      - "--api.dashboard=false"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.email=admin@example.com"
      - "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./letsencrypt:/letsencrypt"
    networks:
      - proxy

networks:
  proxy:
    external: true
```

Start:

```bash
cd /opt/hosting/traefik
docker compose up -d
```

---

## Fas 4: Testapp

Innan riktiga appar publiceras ska en enkel testapp publiceras.

Exempel: `hello.example.com`

Testappen ska verifiera:

- DNS pekar rätt
- port 80 fungerar
- port 443 fungerar
- Traefik hittar containern
- Let's Encrypt-certifikat skapas
- logs fungerar
- deploy via SSH fungerar

Exempel på app med Traefik-labels:

```yaml
services:
  hello:
    image: traefik/whoami
    restart: unless-stopped
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hello.rule=Host(`hello.example.com`)"
      - "traefik.http.routers.hello.entrypoints=websecure"
      - "traefik.http.routers.hello.tls.certresolver=letsencrypt"
      - "traefik.http.services.hello.loadbalancer.server.port=80"

networks:
  proxy:
    external: true
```

---

## Appstandard

Varje app bör ha ungefär denna struktur:

```text
my-app/
  src/
  Dockerfile
  compose.yaml
  compose.prod.yaml
  .env.example
  README.md
  .github/
    workflows/
      ci.yml
      deploy.yml
      ghcr-retention.yml
```

Lokalt:

```bash
docker compose up --build
```

Produktion:

```bash
docker compose -f compose.yaml -f compose.prod.yaml up -d
```

---

## Image-taggar

Rekommenderat taggmönster:

```text
ghcr.io/<owner>/<app>:latest
ghcr.io/<owner>/<app>:main
ghcr.io/<owner>/<app>:<commit-sha>
ghcr.io/<owner>/<app>:v1.0.0
```

Princip:

- `latest` används för senaste stabila version
- `main` används för senaste från main-branch
- `<commit-sha>` används för exakt deploybar version
- `v*` används för manuella releaser

---

## CI-workflow

Exempel på `ci.yml`:

```yaml
name: ci

on:
  push:
    branches: [ main ]
  pull_request:

permissions:
  contents: read
  packages: write

jobs:
  build:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Login to GHCR
        run: echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Build image
        run: |
          docker build             -t ghcr.io/${{ github.repository }}:${{ github.sha }}             -t ghcr.io/${{ github.repository }}:main             .

      - name: Push image
        if: github.ref == 'refs/heads/main'
        run: |
          docker push ghcr.io/${{ github.repository }}:${{ github.sha }}
          docker push ghcr.io/${{ github.repository }}:main
```

---

## Manuell deploy

Deploy bör kunna triggas manuellt via `workflow_dispatch`.

Exempel på `deploy.yml`:

```yaml
name: deploy

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: "Image tag att deploya, exempelvis main eller commit-sha"
        required: true
        default: "main"
      environment:
        description: "Miljö"
        required: true
        default: "production"

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}

    steps:
      - name: Configure SSH
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.VPS_SSH_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          echo "${{ secrets.VPS_KNOWN_HOSTS }}" > ~/.ssh/known_hosts

      - name: Deploy over SSH
        run: |
          ssh -i ~/.ssh/deploy_key ${{ secrets.VPS_USER }}@${{ secrets.VPS_HOST }} '
            cd /opt/hosting/apps/my-app &&
            IMAGE_TAG=${{ inputs.image_tag }} docker compose pull &&
            IMAGE_TAG=${{ inputs.image_tag }} docker compose up -d &&
            docker image prune -f --filter "until=168h"
          '
```

Rekommenderade GitHub-secrets:

```text
VPS_HOST
VPS_USER
VPS_SSH_KEY
VPS_KNOWN_HOSTS
```

Undvik:

```text
StrictHostKeyChecking=no
```

Det är bekvämt men sämre ur säkerhetssynpunkt.

---

## Exempel på produktions-compose för app

```yaml
services:
  app:
    image: ghcr.io/example-owner/my-app:${IMAGE_TAG:-main}
    restart: unless-stopped
    env_file:
      - .env
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-app.rule=Host(`app.example.com`)"
      - "traefik.http.routers.my-app.entrypoints=websecure"
      - "traefik.http.routers.my-app.tls.certresolver=letsencrypt"
      - "traefik.http.services.my-app.loadbalancer.server.port=3000"

networks:
  proxy:
    external: true
```

---

## Secrets

### I GitHub Actions

Exempel:

```text
VPS_HOST
VPS_USER
VPS_SSH_KEY
VPS_KNOWN_HOSTS
```

### På VPS

Per app:

```text
/opt/hosting/apps/my-app/.env
```

Exempel:

```env
DATABASE_URL=postgres://...
OPENAI_API_KEY=...
SESSION_SECRET=...
```

### I Git-repot

Endast mall:

```text
.env.example
```

Riktiga `.env`-filer ska inte checkas in.

---

## Databaser

Två enkla modeller är rimliga.

### Alternativ A: En databascontainer per app

```text
my-app
  app-container
  postgres-container
  docker volume
```

Fördelar:

- enkelt att förstå
- isolerat per app
- lätt att flytta eller ta bort en app

Nackdelar:

- fler containers
- mer backupjobb

### Alternativ B: Gemensam PostgreSQL-container

```text
postgres
  database_app1
  database_app2
  database_app3
```

Fördelar:

- färre containers
- centraliserad backup

Nackdelar:

- mer koppling mellan appar
- kräver bättre ordning på användare och rättigheter

Startrekommendation:

```text
Börja med en databascontainer per app.
```

---

## Backup

Backup ska täcka minst:

- databasdump
- `.env`-filer
- compose-filer
- uppladdade filer
- Docker-volymer med persistent data
- Traefik ACME-data

Exempelpolicy:

```text
Dagliga backups: behåll 7 dagar
Veckobackups: behåll 4 veckor
Månadsbackups: behåll 3-6 månader
```

Exempelstruktur:

```text
/opt/hosting/backups/
  daily/
  weekly/
  monthly/
```

Viktigt:

```text
Docker-volym är inte samma sak som backup.
```

---

## Retention

Retention ska hanteras på tre nivåer:

1. GHCR
2. VPS
3. GitHub Actions

---

### GHCR-retention

Rekommenderad policy:

```text
Behåll:
  latest
  main
  v*
  senaste 10-20 commit-SHA-taggarna

Ta bort:
  untagged images
  gamla testtaggar
  gamla feature-taggar
  commit-SHA-taggar över retentiongränsen
```

Exempel på separat workflow `ghcr-retention.yml`:

```yaml
name: ghcr-retention

on:
  workflow_dispatch:
  schedule:
    - cron: "30 2 * * 0"

permissions:
  packages: write
  contents: read

jobs:
  cleanup:
    runs-on: ubuntu-latest

    steps:
      - name: Cleanup GHCR
        uses: dataaxiom/ghcr-cleanup-action@v1
        with:
          keep-n-tagged: 20
          delete-untagged: true
          delete-partial-images: true
          exclude-tags: latest,main,v*
```

Första gångerna bör cleanup köras manuellt via `workflow_dispatch` så att loggarna kan kontrolleras.

---

### VPS-retention

Efter deploy:

```bash
docker image prune -f --filter "until=168h"
```

Det tar bort oanvända images äldre än 7 dagar.

Undvik att börja med:

```bash
docker system prune -a -f
```

Det kan ta bort mer än önskat.

---

### GitHub Actions-retention

För uppladdade artifacts:

```yaml
- name: Upload artifact
  uses: actions/upload-artifact@v4
  with:
    name: build-output
    path: dist/
    retention-days: 14
```

Rimlig policy:

```text
Build-artifacts: 7-14 dagar
Testresultat: 14-30 dagar
Release-artifacts: längre, om de används
```

---

## Drift och övervakning

Starta enkelt.

Miniminivå:

```bash
docker ps
docker compose logs -f
df -h
docker system df
```

Bra tillägg:

- Uptime Kuma som container
- daglig backupkontroll
- kontroll av ledigt diskutrymme
- enkel varning via e-post eller annan notifiering
- healthchecks i Compose där det är rimligt

---

## Rollback

Eftersom varje deploy använder image-tag kan rollback göras genom att deploya en äldre tag.

Exempel:

```text
image_tag = tidigare commit-sha
```

Kör sedan manuell deploy igen via GitHub Actions.

Viktigt:

```text
Kodrollback är enkelt.
Databasrollback är inte alltid enkelt.
```

Databasmigreringar bör därför vara bakåtkompatibla där det går.

---

## OpenAI Codex-arbetsflöde

Använd Codex lokalt mot repot.

Bra användning:

- skapa scripts
- skapa Compose-mallar
- skapa GitHub Actions-workflows
- skapa README/runbook
- skapa app-template
- granska Dockerfile
- föreslå förenklingar
- bygga små appar enligt standardmallen

Undvik:

- att låta Codex köra root-kommandon direkt på VPS utan granskning
- att låta Codex hantera production-secrets
- att låta Codex ändra servern utan Git-spårbarhet
- att lägga API-nycklar i frontendkod

Exempelprompt till Codex för plattformsrepot:

```text
Du arbetar i ett repo för en Docker-baserad VPS-hostingplattform.

Målet är:
- Ubuntu Server
- Docker Engine
- Docker Compose
- Traefik
- GitHub Actions deploy via SSH
- GHCR som container registry
- retention för GHCR, Docker-images och artifacts
- tydliga scripts och dokumentation

Skapa eller uppdatera filer enligt befintlig struktur.
Gör små, granskbara ändringar.
Förklara vilka kommandon jag ska köra manuellt.
Kör inte antaganden om hemligheter.
```

Exempelprompt till Codex för ny app:

```text
Bygg en liten webbapp som kan köras lokalt och publiceras på min VPS.

Krav:
- Dockerfile för produktion
- docker compose för lokal körning
- compose.prod.yaml för produktion
- appen ska lyssna internt på port 3000
- stöd för Traefik-labels
- .env.example men inga riktiga secrets
- GitHub Actions för CI
- manuell deploy med workflow_dispatch
- GHCR-retention workflow
- README med lokal körning och deploy
```

---

## Rekommenderad ordning

1. Skapa repot `hosting-server`.
2. Lägg in denna plan som `README.md`.
3. Skapa scripts för VPS-bas.
4. Installera Docker på VPS.
5. Skapa Docker-nätverket `proxy`.
6. Starta Traefik.
7. Publicera testappen `hello`.
8. Skapa app-template.
9. Skapa första riktiga appen.
10. Lägg till manuell deploy via GitHub Actions.
11. Lägg till GHCR-retention.
12. Lägg till backupjobb.
13. Lägg till enkel övervakning.

---

## Kort slutsats

Målet är inte att bygga en stor plattform från början.

Målet är:

```text
En enkel, reproducerbar och Git-styrd VPS där varje app är en Docker Compose-app bakom Traefik.
```

När grundmönstret sitter blir varje ny app mekanisk:

```text
skapa app
bygg lokalt
pusha till GitHub
bygg image i Actions
deploya manuellt till VPS
rensa gamla images enligt retention
```
