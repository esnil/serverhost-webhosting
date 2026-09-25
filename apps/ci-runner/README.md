# ci-runner — self-hosted GitHub Actions-runner för bus-analyzer

**En** full runner-container som kör bus-analyzers (`esnil/bus-analyzer`) CI-jobb på VPS:en,
plus en liten **prose-runner** som bara tar docs-/prosa-PR:ernas gate (se nedan).
Ingen webbtjänst: inga portar, ingen Traefik-label, ingen URL. Runnern long-pollar GitHub
**utåt** och tar aldrig emot inkommande trafik.

| | |
|---|---|
| | Full runner | Prose-runner (RM924) |
|---|---|---|
| Container | `ci-runner` | `ci-runner-gate` |
| Image | `bus-analyzer-runner:local` (target `full`, ~5,4 GB) | `bus-analyzer-runner-gate:local` (target `gate`) |
| Resurstak | 3.0 av 4 vCPU, 4 GB av 7,7 GB RAM | 1.0 vCPU, 2 GB |
| Labels | `e2e,ci2,gate` (tar allt; `gate` som reserv) | `gate` (enbart — satt i compose, inte `.env`) |
| Namn i GitHub | `vps-ci-runner` | `vps-ci-runner-gate` |

Gemensamt: byggs på VPS:en och finns i inget register, nätverket `ci-runner` (172.30.0.0/24,
**inte** `proxy`), namnen kräver `hostname:` i compose (`container_name` sätter det inte).

| | |
|---|---|
| Katalog på VPS | `/opt/hosting/apps/ci-runner/` |

Imagen och entrypointen **ägs av bus-analyzer-repot** (`../bus-analyzer/docker/runner/`) och
finns inte här. Det här repot äger värdens halva: taggar, resurstak, nätverk, brandvägg, deploy.

## Hur den fungerar

Runnern registreras **efemärt** (`--ephemeral`): containern tar **ett** jobb i en ren workspace,
avslutas, och `restart: unless-stopped` startar en färsk. Paketcachar (uv, pnpm, cargo,
Playwright, actions tool cache) ligger i namngivna volymer och överlever, så "ren workspace"
kostar sekunder och inte minuter.

`GH_PAT` används **bara** för att mynta en registreringstoken (giltig en timme — därför måste
myntningen ske i containern, inte på värden). Direkt efter registreringen `exec`ar entrypointen
om sig själv med `env -u GH_PAT`, så PAT:en är borta ur `/proc/1/environ` innan jobbkoden
startar; det som finns kvar är en *remove token* som bara kan avregistrera runners
(bus-analyzer RM514). Ett `unset` hade inte räckt — `environ` är regionen kärnan byggde vid
`execve`, och PID 1 delar uid med varje jobbsteg.

## Deploy

```bash
cp apps/ci-runner/.env.example apps/ci-runner/.env   # fyll i GH_PAT
./apps/ci-runner/deploy.sh
```

`deploy.sh`: pipar build-kontexten (två filer, några kB) över SSH → `docker build` **på VPS:en**
→ `scp compose.yaml` + `.env` (chmod 600) → `docker compose up -d` → väntar på
`Listening for Jobs`.

Första bygget tar några minuter och ger en ~5,4 GB image; efterföljande bygger på cachade lager.
Build-kontexten skickas och byggs i **två** steg (fil först, bygge sen) och inte som en enda
`tar | ssh docker build -`: delar överföringen och byggloggen samma SSH-kanal går det inte att
skilja "bygget hänger" från "kopplingen dog". Mätt 2026-09-08 — bygget blev klart på VPS:en
(imagen taggad 07:45:49) medan det lokala kommandot hängde kvar utan utdata i minuter.
Av samma skäl kör alla ssh/scp med `ServerAliveInterval`.

**Inget `docker restart traefik`** — repots stale-connection-regel gäller appar bakom Traefik,
och Traefik vet inte att runnern finns.

### Acceptanstest: första körningen av VARJE jobbtyp

Att runnern står `Idle` bevisar bara att den registrerade sig. bus-analyzers erfarenhet är att
rättighetsluckor på en **ny flottmedlem** dyker upp först vid första körningen av en jobbtyp —
root-ägda volym-mountpoints och `/opt/pw-browsers`-dirlocken hittades båda så (mätt 2026-08-20).
Grön historik på de andra maskinerna bevisar ingenting om den här. Titta alltså på första
`backend`, första `bridge` och första `frontend` som landar här:

```bash
ssh deploy@217.154.83.127 \
  'docker logs ci-runner 2>&1 | grep -E "Running job|completed with result"'
```

Ett `completed with result: Canceled` är normalt och inte ett fel på maskinen — `ci.yml` har
`cancel-in-progress`, så en ersatt körning avbryts med flit.

Engångssteg efter första deployen, **på VPS:en som root** (nätverksisolering, se nedan):

```bash
scp scripts/05-ci-runner-firewall.sh deploy@217.154.83.127:/tmp/
ssh deploy@217.154.83.127 'sudo /tmp/05-ci-runner-firewall.sh'
```

### Bygga om imagen

När en pinnad `ARG` i bus-analyzers `docker/runner/Dockerfile` flyttas (`PLAYWRIGHT_VERSION`
följer `frontend/package.json`, `NODE_MAJOR` följer `ci.yml`:s setup-node, `UV_VERSION` /
`RUST_TOOLCHAIN` efter behov): `./apps/ci-runner/deploy.sh` igen. Drift självläker annars
långsamt — verktygen laddas ner i cachevolymerna i stället för att ligga i imagen.

Varje bygge taggas `<datum>-<bus-analyzer-sha>` **och** `local`. Rollback till en tidigare tagg:

```bash
ssh deploy@217.154.83.127 'docker images bus-analyzer-runner --format "{{.Tag}}\t{{.CreatedAt}}"'
./apps/ci-runner/deploy.sh 20260908-44ab19b
```

`./apps/ci-runner/deploy.sh --no-build` startar om på nuvarande image — det man vill efter en
ren `.env`-ändring (nya labels, ny PAT).

## Prose-runnern (`gate`, bus-analyzer RM924)

bus-analyzers `ci.yml` låter `backend` fråga efter labeln `gate` i stället för `ci2` när **varje**
ändrad fil är prosa. Då köar en docs- eller ledger-PR inte bakom en full svit på den fulla runnern.
`ci-runner-gate` bär bara `gate` och får därför bara `guard` (som flyter till valfri self-hosted
Linux-runner) och prosa-`backend`, aldrig bridge, frontend/e2e eller hela backend-sviten. Imagen
är Dockerfilens `gate`-target: runner-basen plus git, curl, jq, python3, uv och CPython 3.12.
Ingen Node, Playwright, Rust eller kompilator.

Den fulla runnern bär `gate` också (`RUNNER_LABELS=e2e,ci2,gate` i `.env`). Är den lilla nere
körs docs-PR:en ändå, bara långsammare. Labeln måste stå i `.env`: en efemär runner registrerar
om sig ur sin env före varje jobb, så en label som läggs till i GitHubs UI är borta efter ett jobb.

Värdens version bor i `compose.yaml` som service `gate-runner`, inte som bus-analyzers
`compose.gate.yaml`. Då delar den nätverk (och därmed brandvägg) med den fulla, och får fast namn.

```bash
./apps/ci-runner/deploy.sh --gate   # bygg + starta bara prose-runnern; rör inte ci-runner
```

`--gate` finns för att en vanlig `deploy.sh` kör `up -d` på båda, och ändrad env eller image
återskapar `ci-runner`. Det dödar ett pågående jobb. Driftsätt den fulla när den är idle
(`health.sh` visar `busy=`).

**Kontrollera efter första prosa-PR:en** att `backend` landade på `vps-ci-runner-gate` (eller en
annan `gate`-runner): `gh run view <id> --json jobs`.

## Hälsokoll

```bash
./apps/ci-runner/health.sh
```

Kollar båda runnerna i tre lager, för de fallerar var för sig: containern kör (`docker ps`), agenten är
registrerad (`Listening for Jobs` i loggen), och **GitHub håller med** (runners-API:et).

Det tredje lagret är det som inte går att gissa sig till. En runner kan vara offline medan VPS:en
mår perfekt — och då blir bus-analyzers pipeline inte **röd**, den **köar tyst**. En körning som
aldrig startar är omöten, inte trasig; leta efter runnern, inte i diffen.

## Varför exakt en FULL runner

*(Prose-runnern ovan ändrar inte det här. Resonemanget gäller två runners som delar på e2e-
och fullsvitslasten. `ci-runner-gate` tar bara ett jobb vars tyngsta steg, mypy, toppar på
~475 MB (mätt 2026-09-25 i bus-analyzer). Taken summerar till 4.0 CPU och 6 GB, alltså alla
kärnor, men ett tak är ingen reservation. Även om båda skenar samtidigt blir ~1,7 GB kvar åt
produktionens ~310 MB.)*

VPS:en har 4 vCPU, 7,7 GB RAM och **ingen swap**, delade med produktion. Två runners hade blivit
2 kärnor styck — precis den maskin bus-analyzers gamla LENOVO-E-låda var, och vars huvudvärk
`ci.yml`:s label-uppdelning (`e2e` vs `ci2`, RM491) finns för. RM527 mätte dessutom att
Playwright-e2e **flakar under parallell last**: 3 av 6 PR:er i en omgång krävde omkörning av
frontend-jobbet, varje gång en annan spec. Två runners här hade återskapat den maskinen, inte
lagt till kapacitet.

**Mätt 2026-09-08, under ett skarpt `frontend`-jobb på den här VPS:en:** runnern låg på 301 %
CPU (dvs. exakt taket 3.0 kärnor — cgroup-gränsen håller) och 2,4 GB av sina 4 GB. Samtidigt
svarade alla fyra produktionssajterna (`hello.`/`uptime.vps.encab.se`, `ostersundarn.se`,
`fiske.ostersundarn.se`) på under 310 ms. Marginalen finns alltså, men den är RAM-marginalen som
är knappast: 2,4 av 4 GB i det tyngsta jobbet är ~60 % av taket, inte 20 %.

RAM-matten säger samma sak: e2e-jobbet (uvicorn + pnpm build + Vitest browser mode + Playwright
Chromium) tar 2–3 GB. En runner ryms med marginal i de ~6 GB som är lediga; två toppar på 4–6 GB
utan swap, och värdens OOM-killer väljer offer efter RSS — den vet inte att uptime-kuma betyder
mer än en pytest-process.

### Att lägga till en andra runner

Om genomströmningen någon gång inte räcker: lägg till ett **andra service-block** i
`compose.yaml` (inte `--scale` — `container_name` är satt med flit) med
**`RUNNER_LABELS=ci2` och inget `e2e`**, samt lägre tak (t.ex. `cpus: 1.5` / `mem_limit: 2g` på
båda). Då kan backend och bridge köra parallellt medan e2e-jobbet — det last-känsliga — aldrig
körs två åt gången på den här maskinen. Mät produktionens svarstider innan och efter.

## Säkerhet

- **Ingen inkommande trafik.** Long-poll utåt, noll öppna portar, inget `proxy`-nätverk.
- **Ingen docker-socket, inga privilegier, inga devices.** Ett CI-jobb kan inte styra
  dockerdaemonen och inte nå någon hårdvara.
- **Nätverksisolerad** via `scripts/05-ci-runner-firewall.sh`: eget subnät (172.30.0.0/24),
  REJECT mot alla RFC1918-mål (vilket täcker `proxy`, `status_monitoring` och default-bridgen
  samt publicerade portar, som DNAT:as till 172.16/12) och mot värdens ssh. Internet är öppet —
  runnern måste nå GitHub, apt, npm, crates.io, PyPI och Playwrights nedladdningar.
- **Resurstak** så ett skenande jobb dödas inne i containern i stället för att värdens OOM-killer
  tar en produktionscontainer.
- **PAT:en** ligger bara i `/opt/hosting/apps/ci-runner/.env` (chmod 600, deploy-ägd) och är
  borta ur processmiljön innan jobbkoden kör (se ovan). Håll den fine-grained, scopad till
  **enbart** `esnil/bus-analyzer`, behörighet `Administration: read & write`.
- **Aldrig ett publikt repo.** Self-hosted runners får inte peka på ett repo där fork-PR:er kan
  trigga körningar — då kör vem som helst kod på produktionsvärden. `esnil/bus-analyzer` är
  privat, och det är förutsättningen för hela den här uppsättningen.

## Felsökning

| Symptom | Sannolik orsak | Åtgärd |
|---|---|---|
| Körningar köar, ingen startar | Ingen matchande runner online | `./apps/ci-runner/health.sh` |
| Containern `Restarting` i loop | Utgången/återkallad PAT (registreringen faller) | `docker logs ci-runner`; ny PAT i `.env` → `deploy.sh --no-build` |
| `stale runner config found …` i loggen | Container dödad mitt i ett jobb | Inget — entrypointen städar själv (RM497) |
| `docker ps` säger Up, GitHub säger offline | Agenten tappade uppkopplingen | `ssh … 'docker restart ci-runner'` |
| Spök-runner kvar i GitHubs lista | Oren avslutning | Ta bort i repots Settings → Actions → Runners |
| Jobb dör med OOM / exit 137 | Slog i `mem_limit: 4g` | Höj taket **eller** sänk jobbets parallellitet — höj inte utan att räkna på produktionens marginal |
| Ett jobb kan nå en produktionscontainer | Brandväggsreglerna saknas | `sudo systemctl status ci-runner-firewall` på VPS:en |
| `image bus-analyzer-runner:local not found` | Imagen aldrig byggd på den här värden | `./apps/ci-runner/deploy.sh` |
| `image bus-analyzer-runner-gate:local not found` | Gate-imagen aldrig byggd | `./apps/ci-runner/deploy.sh --gate` |
| `deploy.sh` säger "saknar target 'gate'" | `BA_DIR` pekar på en bus-analyzer-commit före RM924 | Checka ut en commit med RM924 (`BA_DIR=<worktree>`) |
| Prosa-PR:s `backend` köar | Ingen `gate`-runner online (och den fulla saknar `gate` i `.env`) | `health.sh`; lägg `gate` i `RUNNER_LABELS` → `deploy.sh --no-build` |

Loggar: `ssh deploy@217.154.83.127 'docker logs --tail 50 ci-runner'` (resp. `ci-runner-gate`).
Resursanvändning under ett jobb: `ssh deploy@217.154.83.127 'docker stats --no-stream'`.

## Avveckling

```bash
ssh deploy@217.154.83.127 'cd /opt/hosting/apps/ci-runner && docker compose down'
```

`down` skickar TERM → entrypointens trap avregistrerar runnern hos GitHub, så ingen spök-runner
blir kvar. Rensa sedan om man vill:

```bash
ssh deploy@217.154.83.127 '
  docker volume rm $(docker volume ls -q --filter name=ci-runner) ;
  docker rmi $(docker images bus-analyzer-runner -q) $(docker images bus-analyzer-runner-gate -q) ;
  sudo systemctl disable --now ci-runner-firewall'
```
