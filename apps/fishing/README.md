# fishing — JLSK Fisketävling (Öppen-driftfall)

Kör `jlsk-fishing`-appens **Öppen-läge** (utan WordPress) på VPS:en. Två appar ur
samma image bakom Traefik:

| App | URL | Container | Serverar |
|---|---|---|---|
| Deltagare (PWA) | `fiske.vps.encab.se` | `fishing` | `app/dist` + `/jf/v1`-API |
| Admin | `fiske-admin.vps.encab.se` | `fishing-admin` | `admin/dist` + `/jf/v1`-API |

Båda delar en **SQLite-fil** och en **uploads-katalog** under
`/opt/hosting/apps/fishing/data/`. Autentisering sköts av appens egna
admin-login (e-post + lösenord → bearer-token) — ingen Traefik-BasicAuth.

Appens källkod ligger i det separata repot `../jlsk/jlsk-fishing`. Byggfilerna
(`deploy/Dockerfile`, `deploy/nginx.conf`, `deploy/entrypoint.sh`) och
`bin/migrate-standalone.php` ligger där.

## Deploy från den här datorn (utan GitHub)

Imagen byggs lokalt och skeppas med `docker save | ssh docker load` — inget
register inblandat.

```bash
# första gången: sätt admin-uppgifter (skapar första admin-användaren)
cp apps/fishing/.env.example apps/fishing/.env   # fyll i JF_ADMIN_EMAIL/JF_ADMIN_PASSWORD
./apps/fishing/deploy.sh
```

`deploy.sh`: bygger imagen → laddar den på VPS:en → kopierar `compose.yaml` →
kör den idempotenta migreringen → `docker compose up -d` → `docker restart traefik`
(obligatoriskt efter varje deploy, enligt repots stale-connection-regel).

Vanlig omdeploy (admin finns redan) — behöver inga env-variabler:

```bash
./apps/fishing/deploy.sh
```

## Engångssteg vid första setup

1. **DNS (Loopia):** A-poster `fiske.vps` och `fiske-admin.vps` → `217.154.83.127`.
   Traefik hämtar Let's Encrypt-cert automatiskt när DNS pekar rätt.
2. **Admin-uppgifter** i `apps/fishing/.env` innan första `deploy.sh`.
3. **GPS-städning (cron)** på VPS:en — rensar positioner äldre än 24h. Lägg i
   deploy-användarens crontab (`crontab -e`):
   ```cron
   0 3 * * * docker exec fishing php /app/public-standalone/cron.php
   ```
   (`cron.php` ärver containerns `JF_DB_*`-miljö.)

## Persistens & backup

Allt föränderligt ligger under `/opt/hosting/apps/fishing/data/`:

```
data/
  db/        jlsk_fishing.sqlite   # hela databasen
  uploads/                         # fotouppladdningar (photo_path)
```

Ta manuell backup av hela `data/`-katalogen innan riskfyllda operationer
(SQLite kan kopieras säkert när apparna är stoppade, eller via `sqlite3 .backup`).

## Rollback

Varje deploy taggar imagen med app-repots `git describe`. Tidigare taggar finns
kvar på VPS:en tills de rensas (168h). Driftsätt en äldre tagg:

```bash
./apps/fishing/deploy.sh <tidigare-tagg>
```

## Felsökning

- **Bad gateway direkt efter deploy** → `docker restart traefik` (stale
  connection pool). `deploy.sh` gör detta automatiskt.
- **502/tom sida** → kolla containerloggar: `ssh deploy@217.154.83.127 'docker logs fishing --tail 50'`.
- **API 404 på allt** → `compose.yaml` på servern kan vara inaktuell; `deploy.sh`
  scp:ar alltid ny. `/jf/v1`-rutterna kräver att `REQUEST_URI` når PHP oförändrad
  (nginx.conf strippar inte prefixet).
- **Foton laddas inte** → kontrollera att `/opt/hosting/apps/fishing/data/uploads`
  finns och ägs av containerns `www-data` (entrypoint chownar vid start).
