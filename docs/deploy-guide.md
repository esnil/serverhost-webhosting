# Deploy-guide för encab.se VPS

Den här guiden beskriver hur appar byggs, publiceras och körs på vår Docker-hostingserver. Läs igenom helt innan du skapar filer.

---

## Serveröversikt

| Egenskap | Värde |
|---|---|
| VPS-IP | `217.154.83.127` |
| OS | Ubuntu Server |
| Deploy-användare | `deploy` |
| App-sökväg | `/opt/hosting/apps/<appnamn>/` |
| Container registry | GitHub Container Registry (GHCR) |
| Reverse proxy | Traefik v3 med automatisk Let's Encrypt |

**Grundprincipen:** Appen byggs aldrig på VPS:en. GitHub Actions bygger Docker-imagen, pushar till GHCR, och VPS:en hämtar den färdiga imagen.

```
kod → GitHub Actions → GHCR → VPS (docker compose pull + up)
```

---

## Nätverkskrav

Alla publika appar **måste** kopplas till det externa Docker-nätverket `proxy`. Det är det nätverket Traefik lyssnar på.

```yaml
networks:
  proxy:
    external: true
```

---

## Traefik-labels (obligatoriska)

Varje app-service som ska vara publikt tillgänglig behöver dessa labels. Byt ut `<appnamn>` och `<subdomän>` mot faktiska värden.

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<appnamn>.rule=Host(`<subdomän>.vps.encab.se`)"
  - "traefik.http.routers.<appnamn>.entrypoints=websecure"
  - "traefik.http.routers.<appnamn>.tls.certresolver=letsencrypt"
  - "traefik.http.services.<appnamn>.loadbalancer.server.port=<intern-port>"
```

HTTP→HTTPS-redirect sköts automatiskt av Traefik. Certifikat hämtas automatiskt via Let's Encrypt.

### Lösenordsskydd (valfritt)

Om appen ska skyddas med BasicAuth, lägg till:

```yaml
labels:
  - "traefik.http.routers.<appnamn>.middlewares=<appnamn>-auth@file"
```

Och skapa `/opt/hosting/traefik/dynamic/<appnamn>-auth.yaml` på VPS:en:

```yaml
http:
  middlewares:
    <appnamn>-auth:
      basicAuth:
        users:
          - "admin:$2y$05$..."   # generera med: htpasswd -nbB admin lösenord
```

**Viktigt:** Lägg aldrig BasicAuth-hashar i compose.yaml eller .env-filer — `$`-tecken i hashar tolkas som variabler av Docker Compose. Använd alltid Traefik dynamic config-filer.

---

## Filstruktur per app

```
my-app/
  Dockerfile
  compose.yaml          # lokal utveckling
  compose.prod.yaml     # production override (valfri)
  .env.example          # mall, checkas in
  .github/
    workflows/
      ci.yml            # bygger och pushar image till GHCR
      deploy.yml        # deployar till VPS via SSH
```

---

## Dockerfile

Multi-stage build. Appen ska **inte** exponera port utåt — det sköter Traefik.

```dockerfile
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
```

Anpassa för din stack (Python, Go, etc.). Principen är densamma.

---

## compose.yaml (produktion)

```yaml
services:
  <appnamn>:
    image: ghcr.io/esnil/<repo>/<appnamn>:${IMAGE_TAG:-main}
    restart: unless-stopped
    env_file:
      - .env
    networks:
      - proxy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<appnamn>.rule=Host(`<subdomän>.vps.encab.se`)"
      - "traefik.http.routers.<appnamn>.entrypoints=websecure"
      - "traefik.http.routers.<appnamn>.tls.certresolver=letsencrypt"
      - "traefik.http.services.<appnamn>.loadbalancer.server.port=<intern-port>"

networks:
  proxy:
    external: true
```

**Byt ut:**
- `esnil/<repo>/<appnamn>` → korrekt GHCR-sökväg (matchar GitHub-repot)
- `<appnamn>` → unikt namn, används i alla Traefik-labels
- `<subdomän>` → önskat subdomän under `vps.encab.se`
- `<intern-port>` → den port appen lyssnar på inuti containern

---

## GitHub Actions: CI

Sökväg: `.github/workflows/ci.yml`

```yaml
name: ci

on:
  push:
    branches: [main]
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

      - name: Build and push
        run: |
          docker build . \
            -t ghcr.io/${{ github.repository }}:${{ github.sha }} \
            -t ghcr.io/${{ github.repository }}:main
          if [ "${{ github.ref }}" = "refs/heads/main" ]; then
            docker push ghcr.io/${{ github.repository }}:${{ github.sha }}
            docker push ghcr.io/${{ github.repository }}:main
          fi
```

Om `Dockerfile` inte ligger i repo-roten, byt `docker build .` mot `docker build <sökväg>`.

**Viktigt för Node-projekt:** Committa `package-lock.json` innan du pushar — `npm ci` i Dockerfile kräver den och CI-bygget kraschar annars. Kör `npm install` lokalt och committa filen.

---

## GitHub Actions: Deploy

Sökväg: `.github/workflows/deploy.yml`

```yaml
name: deploy

on:
  workflow_dispatch:
    inputs:
      image_tag:
        description: "Image tag (t.ex. main eller commit-sha)"
        required: true
        default: "main"

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Configure SSH
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.VPS_SSH_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          echo "${{ secrets.VPS_KNOWN_HOSTS }}" > ~/.ssh/known_hosts

      - name: Deploy
        run: |
          ssh -i ~/.ssh/deploy_key ${{ secrets.VPS_USER }}@${{ secrets.VPS_HOST }} '
            cd /opt/hosting/apps/<appnamn> &&
            IMAGE_TAG=${{ inputs.image_tag }} docker compose pull &&
            IMAGE_TAG=${{ inputs.image_tag }} docker compose up -d &&
            docker image prune -f --filter "until=168h" &&
            docker restart traefik
          '
```

**Byt ut** `<appnamn>` mot appens katalognamn på VPS:en.

---

## GitHub Secrets (måste finnas i repot)

| Secret | Värde |
|---|---|
| `VPS_HOST` | `217.154.83.127` |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Privat SSH-nyckel — se instruktion nedan |
| `VPS_KNOWN_HOSTS` | Host key för VPS:en — se instruktion nedan |

Läggs till under: `GitHub repo → Settings → Secrets and variables → Actions → New repository secret`

### VPS_SSH_KEY

Kör lokalt i WSL och kopiera hela utskriften inklusive `-----BEGIN`- och `-----END`-raderna:

```bash
cat ~/.ssh/id_ed25519
```

Klistra in exakt som det ser ut — radbrytningar måste vara med. Om formatet är fel får du felet `error in libcrypto` i Actions.

### VPS_KNOWN_HOSTS

Kör lokalt i WSL:

```bash
ssh-keyscan -t ed25519 217.154.83.127 2>/dev/null
```

Kopiera raden som börjar med `217.154.83.127 ssh-ed25519 ...` (inte kommentarsraden med `#`). En enda plain-rad räcker — använd inte det hashade formatet (`|1|...`) som `ssh-keyscan` kan producera med flaggan `-H`.

---

## Förbered VPS för ny app

Kör som deploy-användaren via SSH:

```bash
# Skapa katalog
ssh deploy@217.154.83.127 "mkdir -p /opt/hosting/apps/<appnamn>"

# Kopiera compose.yaml
scp compose.yaml deploy@217.154.83.127:/opt/hosting/apps/<appnamn>/

# Skapa .env med appens variabler (använd printf — inte heredoc i SSH)
printf 'DATABASE_URL=%s\nSECRET_KEY=%s\n' "$DB_URL" "$SECRET" \
  | ssh deploy@217.154.83.127 "cat > /opt/hosting/apps/<appnamn>/.env"
```

Secrets och miljövariabler läggs i `/opt/hosting/apps/<appnamn>/.env`. Den filen checkas aldrig in i Git — bara `.env.example` med tomma värden.

---

## DNS

Varje app behöver en A-record hos Loopia:

```
<subdomän>.vps  →  217.154.83.127
```

Let's Encrypt-certifikatet skapas automatiskt första gången Traefik ser en request mot domänen.

---

## Manuell deploy (utan GitHub Actions)

```bash
ssh deploy@217.154.83.127 '
  cd /opt/hosting/apps/<appnamn> &&
  IMAGE_TAG=main docker compose pull &&
  IMAGE_TAG=main docker compose up -d
'
```

---

## Rollback

Byt `main` mot en specifik commit-SHA:

```bash
ssh deploy@217.154.83.127 '
  cd /opt/hosting/apps/<appnamn> &&
  IMAGE_TAG=<commit-sha> docker compose pull &&
  IMAGE_TAG=<commit-sha> docker compose up -d
'
```

---

## Checklista för ny app

- [ ] `Dockerfile` skapad och testad lokalt
- [ ] `compose.yaml` med korrekta Traefik-labels och `proxy`-nätverket
- [ ] `.env.example` med alla variabler (tomma värden)
- [ ] `package-lock.json` (eller motsvarande lock-fil) committat
- [ ] `.github/workflows/ci.yml` och `deploy.yml` skapade
- [ ] GitHub Secrets `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_KNOWN_HOSTS` inlagda
- [ ] DNS-record skapad hos Loopia
- [ ] Katalog `/opt/hosting/apps/<appnamn>/` skapad på VPS
- [ ] `compose.yaml` kopierad till VPS (`scp compose.yaml deploy@217.154.83.127:/opt/hosting/apps/<appnamn>/`)
- [ ] `.env` skapad på VPS med riktiga värden (via `printf ... | ssh ...`)
- [ ] Första push till `main` → CI bygger och pushar image
- [ ] Deploy via `Actions → deploy → Run workflow` med image_tag `main`
