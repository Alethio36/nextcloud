# Self-hosted Nextcloud stack (Docker + Traefik)

A clone-and-run installer for a production-ish Nextcloud on a single Debian host:
Traefik (automatic TLS), Postgres, Redis, and optional Collabora, Talk HPB,
full-text search, antivirus, and Client Push — wired together and configured by
one script.

```bash
git clone <your-repo-url> nextcloud-stack
cd nextcloud-stack
sudo ./install.sh install
```

The installer asks what you need, generates secrets, brings everything up in the
right order, runs the post-install `occ` configuration, and prints a summary.

---

## What you get

**Core (always installed):** Traefik · PostgreSQL · Redis · Nextcloud · cron

**Optional (you pick at install, toggle later):**
- **Collabora** — Nextcloud Office (document editing)
- **Talk HPB** — High-Performance Backend for large/reliable calls (signaling + Janus + TURN, via the AIO `aio-talk` image)
- **Full-text search** — Elasticsearch 8 (note: real Elasticsearch, *not* OpenSearch — the Nextcloud client rejects OpenSearch)
- **Antivirus** — ClamAV on-access scanning
- **Client Push** — `notify_push`, real-time client updates over websocket

---

## Requirements

- A clean **Debian** host (the script installs Docker CE itself). ~24 GB RAM for the full stack; disable Elasticsearch/ClamAV if you have less.
- A **domain** you control, with the ability to create DNS records.
- Ports **80** and **443** forwarded to the host. Talk HPB also needs **3478 TCP+UDP**.
- Run the installer as **root** (`sudo`) — it manages directories and permissions.

---

## TLS / DNS

Two modes, chosen during install:

**Cloudflare (DNS-01, default).** You provide a Cloudflare API token (Zone → DNS → Edit). Certs issue without any inbound port. Set each DNS record to **DNS only (grey cloud)** — orange-cloud proxying breaks WebSockets, large uploads, and TURN.

**Any other DNS provider (HTTP-01 fallback).** No token needed; the installer layers an HTTP-01 config. Requirement: **port 80 reachable from the internet** so Let's Encrypt can validate.

The installer prints the exact A records to create (only for the components you enabled) and pauses until you confirm they resolve.

---

## Commands

```
sudo ./install.sh install          # full guided install (alias: first-run)
sudo ./install.sh reconfigure      # turn components on/off, apply the delta
sudo ./install.sh validate         # smoke-test what's enabled
sudo ./install.sh status           # services + enabled components
sudo ./install.sh check-updates    # report newer image tags (best-effort)
sudo ./install.sh update           # re-pin versions + recreate (backs up first)
sudo ./install.sh backup           # pg_dump + tar to ./backups
sudo ./install.sh teardown         # stop the stack (data preserved)
sudo ./install.sh teardown --volumes   # also remove the named volume
```

**Re-running is safe.** Existing secrets in `.env` are never regenerated, occ
steps are guarded, and `reconfigure` only applies what changed. Add the Talk HPB
six months later with `reconfigure` → enable it → done.

**Updating.** `check-updates` polls registries (best-effort; it clearly marks
what it can't check, e.g. Elasticsearch's registry). `update` re-pins
`versions.env`, backs up, and recreates — and **refuses to cross a Nextcloud or
Postgres major version** without `--allow-major`, because those need a real
upgrade path, not a tag swap.

---

## How it works (the short version)

- `compose.yaml` is **static**. Optional services use Compose `profiles:`; the
  script sets `COMPOSE_PROFILES` from your component choices to decide what runs.
- Domain, paths, and secrets live in **`.env`** (Compose interpolates them).
  Image tags live in **`versions.env`** (committed; this is the tested set).
  Your component toggles live in **`components.env`**.
- Bind-mount data lives under a **data root you choose** (default
  `/opt/nextcloud-data`), deliberately **outside this clone**, so a stray
  `git clean` can never delete your files.

### Files

| File | Committed? | Purpose |
|---|---|---|
| `compose.yaml` | yes | the stack (static, profile-gated) |
| `compose.tls-http.yaml` | yes | HTTP-01 override for non-Cloudflare |
| `versions.env` | yes | pinned image tags (the known-good set) |
| `.env.example` | yes | reference for every config key |
| `install.sh` | yes | installer / lifecycle tool |
| `.env` | **no** (gitignored) | generated secrets + config |
| `components.env` | **no** (gitignored) | your component selection |

`.env` holds every secret — **back it up somewhere safe and never commit it**.
The `.gitignore` already excludes it.

---

## Validation after install

Run `sudo ./install.sh validate` for automated checks. Three things only you can
verify:

1. A **3-way Talk call** holds (if HPB enabled).
2. A participant **off your LAN** — the only real test of TURN relay (internal
   DNS may resolve the signaling host to a LAN IP, so on-LAN calls skip the relay).
3. An **SMTP send** from Settings → Administration → Basic settings.

---

## Gotchas baked into this stack (so you don't rediscover them)

- **Talk HPB `TALK_PORT` is the TURN port and must be `3478`.** Setting it to a
  signaling-range value makes the bundled TURN (eturnal) collide with the
  signaling server. Signaling is always on container port 8081.
- **Traefik filters unhealthy containers** — a service whose healthcheck is
  failing gets no route (404). Fix the health cause, not the routing.
- **Multi-homed containers need a Traefik network pin** (`traefik.docker.network`)
  or Traefik may dial the wrong network and 504.
- **notify_push trusted proxy** — the push server reaches Nextcloud over the
  backend network, so the backend subnet must be in `TRUSTED_PROXIES` (both
  subnets are, by default).
- **Full-text search needs real Elasticsearch**, not OpenSearch.
- **Collabora and the Talk HPB take no volume** — they're configured purely by
  environment; mounting over their config crash-loops them.

---

## A note on this installer

It automates a stack that was assembled and debugged by hand. It's defensive
(preflight, error trap with resume hint, logging to `install.log`, idempotent
re-runs), but it's a large shell script orchestrating Docker, health-polling,
and Nextcloud's `occ` — first runs on a new host can surface an edge case.
Snapshot your VM before the first run so iteration is painless.
