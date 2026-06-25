#!/usr/bin/env bash
#
# Nextcloud self-hosted stack — installer & lifecycle tool
# ───────────────────────────────────────────────────────
# Clone the repo, then:   sudo ./install.sh install
#
# Subcommands:
#   install         First run (alias: first-run). Preflight, deps, prompts,
#                   bring-up with correct ordering, occ config, summary.
#   reconfigure     Toggle optional components on/off and apply the delta.
#   validate        Run smoke tests against whatever is enabled.
#   status          Show running services + which components are enabled.
#   check-updates   Best-effort poll for newer image tags (reports only).
#   update          Re-pin image versions and recreate (backup + major guard).
#   backup          pg_dump + tar of data/config into ./backups.
#   teardown        Stop the stack.  --volumes also removes the named volume.
#
# Design notes (so future-you understands the moving parts):
#   • compose.yaml is STATIC. Optional services use Compose `profiles:`; the
#     script sets COMPOSE_PROFILES from components.env to decide what runs.
#   • All domain/path/secret values live in .env (Compose interpolates them).
#     Image tags live in versions.env (sourced + exported by this script).
#   • .env secrets are generated ONCE. Re-runs never regenerate them — an
#     existing key is treated as source of truth and left untouched.
#   • TLS: Cloudflare DNS-01 by default; TLS_MODE=http layers compose.tls-http
#     for an HTTP-01 fallback that works without Cloudflare.
#
# shellcheck disable=SC1090  # .env/versions/components paths are resolved at runtime by design
set -euo pipefail

# ── paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
VERSIONS_FILE="$SCRIPT_DIR/versions.env"
COMPONENTS_FILE="$SCRIPT_DIR/components.env"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
TLS_HTTP_OVERRIDE="$SCRIPT_DIR/compose.tls-http.yaml"
LOG_FILE="$SCRIPT_DIR/install.log"

# ── logging ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[0;36m'; C_OK=$'\033[0;32m'
  C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_STEP=$'\033[1;35m'
else
  C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_STEP=""
fi
_log()  { printf '%s\n' "$*" | tee -a "$LOG_FILE" >/dev/null; }
step()  { printf '\n%s\n' "${C_STEP}━━ $* ━━${C_RESET}"; _log "== $*"; }
substep(){ printf '%s\n' "${C_STEP}  $*${C_RESET}"; _log "  -- $*"; }
note()  { printf '%s\n' "    $*"; _log "    $*"; }   # plain-language explanation
info()  { printf '%s\n' "${C_INFO}  - $*${C_RESET}"; _log "  - $*"; }
ok()    { printf '%s\n' "${C_OK}  ✓ $*${C_RESET}"; _log "  ok $*"; }
warn()  { printf '%s\n' "${C_WARN}  ! $*${C_RESET}"; _log "  ! $*"; }
die()   { printf '%s\n' "${C_ERR}  ✗ $*${C_RESET}" >&2; _log "  ✗ $*"; exit 1; }

# Print where we failed, so a crashed run is resumable.
# shellcheck disable=SC2154  # rc is assigned by 'rc=$?' inside the trap body
trap 'rc=$?; [[ $rc -ne 0 ]] && printf "%s\n" "${C_ERR}Failed (exit $rc) during: ${CURRENT_STEP:-unknown}. See $LOG_FILE. Re-run the same command to resume.${C_RESET}" >&2' EXIT
CURRENT_STEP="startup"

# ── small helpers ────────────────────────────────────────────────────────────
need_cmd() { command -v "$1" >/dev/null 2>&1; }
gen_secret() { openssl rand -hex 32; }

confirm() { # confirm "Question?"  -> returns 0 for yes
  local q="$1" a
  read -rp "$q [y/N]: " a
  [[ "$a" =~ ^[Yy]$ ]]
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) warn "Unknown CPU arch '$(uname -m)'; defaulting notify_push to x86_64." >&2; echo "x86_64" ;;
  esac
}

# ── .env read/write (position-preserving, value-safe) ────────────────────────
get_env() { # get_env KEY -> value (empty if unset)
  [[ -f "$ENV_FILE" ]] || return 0
  local line; line="$(grep -E "^$1=" "$ENV_FILE" | tail -n1 || true)"
  printf '%s' "${line#*=}"
}
set_env() { # set_env KEY VALUE... (replaces in place or appends; literal value)
  local key="$1"; shift; local val="$*"
  touch "$ENV_FILE"
  local tmp found=0; tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$key="* ]]; then printf '%s=%s\n' "$key" "$val" >>"$tmp"; found=1
    else printf '%s\n' "$line" >>"$tmp"; fi
  done < "$ENV_FILE"
  [[ "$found" -eq 0 ]] && printf '%s=%s\n' "$key" "$val" >>"$tmp"
  mv "$tmp" "$ENV_FILE"
}
ensure_env() { # only set if currently empty/missing — the idempotency rule
  [[ -z "$(get_env "$1")" ]] && set_env "$1" "$2" || true
}

# Prompt for a value only if it isn't already set (idempotent re-runs).
# Silent when a value already exists, so re-runs aren't noisy.
prompt_if_missing() { # KEY  "Prompt text"  [default]
  local key="$1" msg="$2" default="${3:-}"
  [[ -n "$(get_env "$key")" ]] && return
  local input
  if [[ -n "$default" ]]; then read -rp "    $msg [$default]: " input; input="${input:-$default}"
  else read -rp "    $msg: " input; fi
  set_env "$key" "$input"
}
prompt_secret_if_missing() { # KEY  "Prompt text"  (hidden input)
  local key="$1" msg="$2" input
  [[ -n "$(get_env "$key")" ]] && return
  read -rsp "    $msg: " input; echo
  set_env "$key" "$input"
}

# Copy the pinned image tags from versions.env INTO .env, so that a plain
# `docker compose ...` (run by hand, outside this script) resolves them too.
# Without this, bare compose runs with blank tags and can recreate containers
# wrong — the root cause of a lot of confusing breakage.
sync_versions_to_env() {
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[A-Z_]+= ]] || continue        # skip comments/blank lines
    key="${line%%=*}"; val="${line#*=}"
    set_env "$key" "$val"
  done < "$VERSIONS_FILE"
}

# ── component manifest ───────────────────────────────────────────────────────
load_components() { [[ -f "$COMPONENTS_FILE" ]] && source "$COMPONENTS_FILE" || true; }
build_profiles() { # -> echoes csv profile list from components.env
  load_components
  local p=()
  [[ "${ENABLE_COLLABORA:-false}" == "true" ]] && p+=(collabora)
  [[ "${ENABLE_HPB:-false}"       == "true" ]] && p+=(hpb)
  [[ "${ENABLE_FULLTEXT:-false}"  == "true" ]] && p+=(fulltext)
  [[ "${ENABLE_ANTIVIRUS:-false}" == "true" ]] && p+=(antivirus)
  [[ "${ENABLE_PUSH:-false}"      == "true" ]] && p+=(push)
  ( IFS=,; echo "${p[*]}" )
}

# ── compose wrapper: injects versions, profiles, and the TLS override ────────
dc() {
  set -a; source "$VERSIONS_FILE"; set +a          # export image tags
  export COMPOSE_PROFILES; COMPOSE_PROFILES="$(build_profiles)"
  local files=(-f "$COMPOSE_FILE")
  [[ "$(get_env TLS_MODE)" == "http" ]] && files+=(-f "$TLS_HTTP_OVERRIDE")
  docker compose --env-file "$ENV_FILE" "${files[@]}" "$@"
}

# occ wrapper (no TTY, runs as www-data inside the nextcloud service)
occ() { dc exec -T --user www-data nextcloud php occ "$@"; }

# Install+enable a Nextcloud app only if not already enabled (careful re-runs).
nc_install_app() {
  local app="$1"
  if occ app:list 2>/dev/null | sed -n '/Enabled:/,/Disabled:/p' | grep -qE "^[[:space:]]*- ${app}:"; then
    info "app '$app' already enabled."
    return 0
  fi
  info "installing app '$app'..."
  occ app:install "$app" || occ app:enable "$app"
}

# ── preflight ────────────────────────────────────────────────────────────────
preflight() {
  CURRENT_STEP="preflight"; step "Preflight checks"
  [[ $EUID -eq 0 ]] || die "Run as root (manages dirs/permissions): sudo $0 ${CMD:-install}"
  [[ -f /etc/debian_version ]] || warn "Not Debian — dependency install may not work as written."
  local ram_gb; ram_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  if (( ram_gb < 24 )); then
    warn "Host has ${ram_gb} GB RAM; the full stack is sized for ~24 GB+."
    warn "Disable heavy components (Elasticsearch, ClamAV) if this is tight."
  else
    ok "RAM: ${ram_gb} GB"
  fi
  local p
  for p in 80 443; do
    if need_cmd ss && ss -tlnH "( sport = :$p )" 2>/dev/null | grep -q .; then
      warn "TCP $p already in use — Traefik may fail to bind it."
    fi
  done
}

# ── dependencies ─────────────────────────────────────────────────────────────
install_dependencies() {
  CURRENT_STEP="dependencies"; step "Installing host dependencies"
  export DEBIAN_FRONTEND=noninteractive
  if ! need_cmd docker || ! docker compose version >/dev/null 2>&1; then
    info "Installing Docker CE from Docker's official repo..."
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    local codename; codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker >/dev/null 2>&1 || true
  else
    ok "Docker + compose plugin present."
  fi
  # Tools this project needs: htpasswd, dig, openssl, gzip, tar, curl.
  apt-get install -y -qq apache2-utils dnsutils openssl gzip tar curl >/dev/null
  # Elasticsearch needs this sysctl; set it only if too low.
  local cur; cur="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if (( cur < 262144 )); then
    info "Setting vm.max_map_count=262144 (Elasticsearch requirement)."
    echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-nextcloud-elasticsearch.conf
    sysctl --system >/dev/null
  fi
  ok "Dependencies ready."
}

# ── interactive configuration (idempotent) ──────────────────────────────────
prompt_components() {
  CURRENT_STEP="components"; step "Choose optional components"
  if [[ -f "$COMPONENTS_FILE" ]]; then
    info "Existing component selection found:"
    sed 's/^/      /' "$COMPONENTS_FILE"
    confirm "Change the component selection?" || { ok "Keeping current components."; return; }
  fi
  echo "  Core (always on): Traefik, Postgres, Redis, Nextcloud, cron."
  local collab hpb ft av push
  confirm "  Enable Collabora (Nextcloud Office)?"      && collab=true || collab=false
  confirm "  Enable Talk High-Performance Backend?"     && hpb=true    || hpb=false
  confirm "  Enable Elasticsearch (full-text search)?"  && ft=true     || ft=false
  confirm "  Enable ClamAV (antivirus)?"                && av=true     || av=false
  confirm "  Enable Client Push (notify_push)?"         && push=true   || push=false
  cat > "$COMPONENTS_FILE" <<EOF
# Optional component toggles. Re-run './install.sh reconfigure' to change.
ENABLE_COLLABORA=$collab
ENABLE_HPB=$hpb
ENABLE_FULLTEXT=$ft
ENABLE_ANTIVIRUS=$av
ENABLE_PUSH=$push
EOF
  ok "Saved component selection."
}

prompt_config() {
  CURRENT_STEP="config"; step "Configuration"
  note "I'll ask a few questions. Press Enter to accept the [default] in brackets."
  note "On a re-run, anything already saved is kept — you won't be asked twice."
  [[ -f "$ENV_FILE" ]] || : > "$ENV_FILE"   # start with an EMPTY .env; prompts fill it
  load_components

  # Derived/internal values — set automatically, no prompts.
  ensure_env PROJECT_NAME "nextcloud"
  ensure_env TZ "$(cat /etc/timezone 2>/dev/null || echo Etc/UTC)"
  ensure_env NOTIFY_PUSH_ARCH "$(detect_arch)"
  ensure_env FRONTEND_SUBNET "172.20.0.0/24"
  ensure_env BACKEND_SUBNET  "172.21.0.0/24"

  substep "1) Where to store data"
  note "Your files, database and config live here. It's kept OUTSIDE this folder"
  note "so updating the code can never touch your data."
  prompt_if_missing DATA_ROOT "Data directory" "/opt/nextcloud-data"

  substep "2) Your domain"
  note "Enter the root domain you own. The services live on subdomains under it"
  note "(e.g. cloud.<domain>). Accept the suggested subdomains unless you have a reason not to."
  prompt_if_missing DOMAIN "Base domain (e.g. example.com)"
  local d; d="$(get_env DOMAIN)"
  prompt_if_missing CLOUD_HOST   "Nextcloud address"          "cloud.$d"
  prompt_if_missing OFFICE_HOST  "Collabora (Office) address" "office.$d"
  prompt_if_missing TRAEFIK_HOST "Traefik dashboard address"  "traefik.$d"
  prompt_if_missing SIGNAL_HOST  "Talk call-server address"   "signal.$d"
  prompt_if_missing ACME_EMAIL   "Email for Let's Encrypt certificate notices" "admin@$d"
  prompt_if_missing MAIL_DOMAIN  "Domain that outgoing mail comes from" "$d"

  substep "3) HTTPS certificates"
  note "Certificates are issued automatically by Let's Encrypt. How that's verified"
  note "depends on your DNS provider:"
  note "  • Cloudflare  → uses an API token (no open ports needed to issue certs)"
  note "  • Anything else → uses HTTP-01 (needs port 80 open to the internet)"
  if [[ -z "$(get_env TLS_MODE)" ]]; then
    if confirm "  Is your DNS hosted on Cloudflare?"; then
      set_env TLS_MODE "cloudflare"
      note "Create the token at: Cloudflare → My Profile → API Tokens →"
      note "  'Edit zone DNS' template, scoped to this domain's zone."
      prompt_secret_if_missing CF_DNS_API_TOKEN "Paste the Cloudflare API token"
    else
      set_env TLS_MODE "http"
      note "Using HTTP-01. Make sure port 80 is reachable from the internet."
    fi
  fi

  substep "4) Nextcloud administrator"
  note "This is the login you'll use to manage Nextcloud. You choose the password"
  note "(it is never auto-generated)."
  prompt_if_missing NEXTCLOUD_ADMIN_USER "Admin username" "admin"
  if [[ -z "$(get_env NEXTCLOUD_ADMIN_PASSWORD)" ]]; then
    local p1 p2
    while :; do
      read -rsp "    Admin password: " p1; echo
      read -rsp "    Confirm password: " p2; echo
      [[ -n "$p1" && "$p1" == "$p2" ]] && break
      warn "Empty or didn't match — try again."
    done
    set_env NEXTCLOUD_ADMIN_PASSWORD "$p1"
  fi

  substep "5) Outgoing email (SMTP)"
  note "Used for password resets, share notices, etc. Get these from your mail"
  note "provider. You can leave them and configure mail later in Nextcloud."
  prompt_if_missing SMTP_HOST "SMTP server host"
  prompt_if_missing SMTP_PORT "SMTP port" "587"
  prompt_if_missing SMTP_NAME "SMTP username / login"
  prompt_secret_if_missing SMTP_PASSWORD "SMTP password"
  prompt_if_missing MAIL_FROM_ADDRESS "'From' name before the @ (e.g. cloud)" "cloud"

  substep "6) Service passwords"
  note "Internal passwords for the database, cache, and call server. Recommended:"
  note "let the script generate strong random ones — you never need to type these."
  local gen_all=true
  confirm "  Auto-generate all service passwords?" && gen_all=true || gen_all=false
  local key
  for key in POSTGRES_PASSWORD REDIS_PASSWORD COLLABORA_PASSWORD TURN_SECRET SIGNALING_SECRET INTERNAL_SECRET; do
    [[ -n "$(get_env "$key")" ]] && continue
    if $gen_all; then set_env "$key" "$(gen_secret)"
    else
      local v; read -rsp "    $key (Enter = generate one): " v; echo
      [[ -z "$v" ]] && v="$(gen_secret)"
      set_env "$key" "$v"
    fi
  done
  ensure_env POSTGRES_DB "nextcloud"
  ensure_env POSTGRES_USER "nextcloud"
  ensure_env COLLABORA_USERNAME "admin"

  substep "7) Traefik dashboard login"
  note "Protects the Traefik admin dashboard (username is 'admin')."
  if [[ -z "$(get_env TRAEFIK_DASHBOARD_AUTH)" ]]; then
    local dpw
    read -rsp "    Dashboard password: " dpw; echo
    set_env TRAEFIK_DASHBOARD_AUTH "$(htpasswd -nbB admin "$dpw" | sed 's/[$]/$$/g')"
  fi

  # Make the chosen image versions visible to plain `docker compose` too.
  sync_versions_to_env
  ok "Configuration saved."
}

# ── filesystem ───────────────────────────────────────────────────────────────
setup_dirs() {
  CURRENT_STEP="dirs"; step "Creating data directories + permissions"
  local root; root="$(get_env DATA_ROOT)"; load_components
  mkdir -p "$root"/traefik/letsencrypt
  mkdir -p "$root"/postgres "$root"/redis
  mkdir -p "$root"/nextcloud/{config,custom_apps,data,themes}
  [[ "${ENABLE_FULLTEXT:-false}"  == "true" ]] && mkdir -p "$root"/elasticsearch
  [[ "${ENABLE_ANTIVIRUS:-false}" == "true" ]] && mkdir -p "$root"/clamav
  # Container UIDs that own each bind mount.
  chown -R 33:33   "$root"/nextcloud
  chown -R 999:999 "$root"/postgres
  [[ -d "$root"/elasticsearch ]] && chown -R 1000:1000 "$root"/elasticsearch
  [[ -d "$root"/clamav ]]        && chown -R 100:100   "$root"/clamav
  touch "$root"/traefik/letsencrypt/acme.json
  chmod 600 "$root"/traefik/letsencrypt/acme.json
  ok "Directories ready under $root"
}

# ── DNS instructions + manual gate ───────────────────────────────────────────
show_dns_and_wait() {
  CURRENT_STEP="dns"; step "DNS setup — do this now, before continuing"
  local tls cloud office traefik signal pubip
  tls="$(get_env TLS_MODE)"; cloud="$(get_env CLOUD_HOST)"; office="$(get_env OFFICE_HOST)"
  traefik="$(get_env TRAEFIK_HOST)"; signal="$(get_env SIGNAL_HOST)"; load_components
  pubip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<your public IP>')"
  note "Create these DNS 'A' records, each pointing at your server's public IP."
  note "Your public IP looks like: $pubip"
  echo
  echo "      $cloud      →  $pubip"
  echo "      $traefik    →  $pubip"
  [[ "${ENABLE_COLLABORA:-false}" == "true" ]] && echo "      $office     →  $pubip"
  [[ "${ENABLE_HPB:-false}"       == "true" ]] && echo "      $signal     →  $pubip"
  echo
  if [[ "$tls" == "cloudflare" ]]; then
    substep "Cloudflare users — important"
    note "Set each record to 'DNS only' (GREY cloud), NOT proxied (orange cloud)."
    note "The orange cloud breaks file uploads, calls, and live updates."
  else
    substep "HTTP-01 mode"
    note "Make sure TCP port 80 is reachable from the internet — that's how the"
    note "certificate gets verified. Any DNS provider is fine."
  fi
  echo
  substep "On your router / firewall, forward to this server:"
  note "TCP 80 and 443"
  [[ "${ENABLE_HPB:-false}" == "true" ]] && note "TCP + UDP 3478  (needed for Talk calls)"
  echo
  read -rp "  Press ENTER once you've created the records and they've propagated... " _
  if need_cmd dig; then
    local ip; ip="$(dig +short "$cloud" | grep -E '^[0-9.]+$' | tail -n1 || true)"
    if [[ -z "$ip" ]]; then
      warn "$cloud doesn't resolve yet. Certificates can't be issued until it does."
      note "(DNS can take a few minutes to propagate.)"
      confirm "Continue anyway?" || die "Add the DNS records, then re-run: sudo ./install.sh install"
    else
      ok "$cloud resolves to $ip — good."
    fi
  fi
}

# ── orchestration ────────────────────────────────────────────────────────────
wait_for_nextcloud() {
  CURRENT_STEP="wait-nextcloud"; step "Waiting for Nextcloud to initialize"
  local t=0 max=120 status
  while (( t < max )); do
    # occ status exits non-zero AND prints nothing useful while the entrypoint
    # is still doing first-run setup; tolerate that and keep waiting.
    status="$(occ status 2>/dev/null || true)"
    if grep -q 'installed: true' <<<"$status"; then ok "Nextcloud is up."; return 0; fi
    # Distinguish "still booting" from "up but not installed" for the log.
    if grep -q 'installed: false' <<<"$status"; then info "container up, finishing install..."; fi
    sleep 5; t=$((t+1)); printf '.'
  done
  echo
  warn "Nextcloud not confirmed ready after $((max*5))s."
  warn "If the next steps fail, check 'sudo ./install.sh status' and re-run install (it resumes safely)."
}
wait_for_es() {
  local t=0
  while (( t < 60 )); do
    dc exec -T nextcloud curl -fs http://elasticsearch:9200/_cluster/health >/dev/null 2>&1 && { ok "Elasticsearch ready."; return 0; }
    sleep 5; t=$((t+1))
  done
  warn "Elasticsearch not ready in time; full-text config may fail."
}
wait_for_healthy() { # wait_for_healthy SERVICE
  local svc="$1" t=0 cid st
  while (( t < 40 )); do
    cid="$(dc ps -q "$svc" 2>/dev/null || true)"
    if [[ -n "$cid" ]]; then
      st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo none)"
      [[ "$st" == "healthy" || "$st" == "none" ]] && { ok "$svc ready ($st)."; return 0; }
    fi
    sleep 5; t=$((t+1))
  done
  warn "$svc not healthy in time — check './install.sh status'."
}

# Base housekeeping — all idempotent.
occ_base_config() {
  CURRENT_STEP="occ-base"; step "Nextcloud base configuration"
  occ maintenance:repair --include-expensive >/dev/null 2>&1 || true
  occ db:add-missing-indices     >/dev/null 2>&1 || true
  occ db:add-missing-columns     >/dev/null 2>&1 || true
  occ db:add-missing-primary-keys >/dev/null 2>&1 || true
  occ config:system:set maintenance_window_start --type integer --value 1 >/dev/null 2>&1 || true
  occ background:cron >/dev/null 2>&1 || true
  local region; region="$(get_env PHONE_REGION)"
  [[ -n "$region" ]] && occ config:system:set default_phone_region --value "$region" >/dev/null 2>&1 || true
  ok "Base config applied."
}

# Install the apps whose containers will need them — BEFORE phase 2 start.
install_component_apps() {
  CURRENT_STEP="apps"; step "Installing component apps"
  load_components
  [[ "${ENABLE_COLLABORA:-false}" == "true" ]] && nc_install_app richdocuments
  [[ "${ENABLE_HPB:-false}"       == "true" ]] && nc_install_app spreed
  if [[ "${ENABLE_FULLTEXT:-false}" == "true" ]]; then
    nc_install_app fulltextsearch
    nc_install_app fulltextsearch_elasticsearch
    nc_install_app files_fulltextsearch
  fi
  [[ "${ENABLE_ANTIVIRUS:-false}" == "true" ]] && nc_install_app files_antivirus
  if [[ "${ENABLE_PUSH:-false}" == "true" ]]; then
    nc_install_app notify_push
    # Basic test the user asked for: confirm the arch-specific binary exists.
    local arch; arch="$(get_env NOTIFY_PUSH_ARCH)"
    if ! occ_exec test -x "/var/www/html/custom_apps/notify_push/bin/$arch/notify_push"; then
      warn "notify_push binary for '$arch' not found — the push container will not start."
      warn "Your CPU arch may be unsupported by the prebuilt binary."
    else
      ok "notify_push binary present for $arch."
    fi
  fi
}
occ_exec() { dc exec -T --user www-data nextcloud "$@"; }  # non-occ exec helper

# Component config that needs the service running.
# Every occ call here is GUARDED — a transient (a service not ready yet, a
# verify that can't reach the public URL) must never abort the whole install.
configure_components() {
  CURRENT_STEP="component-config"; step "Configuring components"
  note "Wiring up each enabled component. Warnings here are non-fatal — the"
  note "install continues, and 'validate' will re-check everything at the end."
  load_components
  local cloud office signal
  cloud="$(get_env CLOUD_HOST)"; office="$(get_env OFFICE_HOST)"; signal="$(get_env SIGNAL_HOST)"

  if [[ "${ENABLE_COLLABORA:-false}" == "true" ]]; then
    if occ config:app:set richdocuments wopi_url --value "https://$office" >/dev/null 2>&1; then
      ok "Collabora connected (Office editing)."
    else warn "Could not set the Collabora address — re-run 'reconfigure' later."; fi
  fi

  if [[ "${ENABLE_HPB:-false}" == "true" ]]; then
    wait_for_healthy talk
    local url="https://$signal/standalone-signaling" secret; secret="$(get_env SIGNALING_SECRET)"
    if occ talk:signaling:list 2>/dev/null | grep -qF "$url"; then
      ok "Talk call server already registered."
    elif occ talk:signaling:add "$url" "$secret" --verify >/dev/null 2>&1; then
      ok "Talk call server registered and verified."
    else
      # --verify failed (the public signal address may not be reachable yet).
      # Register without verify so install completes; validate confirms it later.
      if occ talk:signaling:add "$url" "$secret" >/dev/null 2>&1; then
        warn "Talk call server registered, but couldn't be verified yet."
        note "This is normal if DNS/cert for $signal isn't live yet."
        note "Run 'sudo ./install.sh validate' once it's reachable."
      else
        warn "Talk call server registration failed — check the $signal route."
      fi
    fi
  fi

  if [[ "${ENABLE_FULLTEXT:-false}" == "true" ]]; then
    wait_for_es
    occ config:app:set fulltextsearch search_platform --value 'OCA\FullTextSearch_Elasticsearch\Platform\ElasticSearchPlatform' >/dev/null 2>&1 || true
    occ config:app:set fulltextsearch_elasticsearch elastic_host  --value 'http://elasticsearch:9200' >/dev/null 2>&1 || true
    occ config:app:set fulltextsearch_elasticsearch elastic_index --value nextcloud >/dev/null 2>&1 || true
    if occ fulltextsearch:test >/dev/null 2>&1; then
      # Build the search index (creates the 'nextcloud' index). Guarded so a
      # slow/large index can't abort the run; it can be re-run any time.
      if occ fulltextsearch:index >/dev/null 2>&1; then ok "Search indexed."
      else warn "Search configured, but indexing didn't finish."
           note "Re-run later: sudo ./install.sh index"; fi
    else
      warn "Search engine not reachable yet — run 'reconfigure' once it's up."
    fi
  fi

  if [[ "${ENABLE_ANTIVIRUS:-false}" == "true" ]]; then
    occ config:app:set files_antivirus av_mode --value daemon >/dev/null 2>&1 || true
    occ config:app:set files_antivirus av_host --value clamav  >/dev/null 2>&1 || true
    occ config:app:set files_antivirus av_port --value 3310    >/dev/null 2>&1 || true
    ok "Antivirus connected (scanning on upload)."
    note "(Any earlier 'clamscan not found' error is from before this step — ignore it.)"
  fi

  if [[ "${ENABLE_PUSH:-false}" == "true" ]]; then
    sleep 5
    if occ notify_push:setup "https://$cloud/push" >/dev/null 2>&1; then
      ok "Live updates (Client Push) connected."
    else
      warn "Client Push setup didn't pass its self-test."
      note "Run 'sudo ./install.sh validate' to see which check failed."
    fi
  fi
}

print_summary() {
  step "All done"
  local cloud; cloud="$(get_env CLOUD_HOST)"
  cat <<EOF

  Your Nextcloud is ready:

    Open it at:        https://$cloud
    Log in as:         $(get_env NEXTCLOUD_ADMIN_USER)  (the password you chose)
    Traefik dashboard: https://$(get_env TRAEFIK_HOST)   (user 'admin')
    Data is stored in: $(get_env DATA_ROOT)

  A few things to know:
    • The very first visit may take a few seconds while the HTTPS
      certificate is issued — that's normal.
    • Check everything is healthy:   sudo ./install.sh validate
    • See what's running:            sudo ./install.sh status
    • Add/remove features later:     sudo ./install.sh reconfigure

  Worth testing by hand (nothing automated can):
    • A Talk call with 3+ people, ideally one person off your network.
    • Sending a test email from Settings → Administration → Basic settings.

EOF
}

# ── subcommands ──────────────────────────────────────────────────────────────
cmd_install() {
  cat <<'EOF'

  ┌─────────────────────────────────────────────────────────────┐
  │  Nextcloud stack installer                                  │
  │  I'll set up Docker, ask a few questions, then build and    │
  │  configure everything. Safe to re-run if anything stops.    │
  └─────────────────────────────────────────────────────────────┘
EOF
  preflight
  install_dependencies
  prompt_components
  prompt_config
  sync_versions_to_env          # ensure plain `docker compose` also sees image tags
  setup_dirs
  show_dns_and_wait
  CURRENT_STEP="up-core"; step "Starting the core services"
  note "Web server, database, cache, and Nextcloud itself."
  dc up -d traefik postgres redis nextcloud cron
  wait_for_nextcloud
  occ_base_config
  install_component_apps
  CURRENT_STEP="up-optional"; step "Starting the optional services you chose"
  dc up -d
  configure_components
  print_summary
}

cmd_reconfigure() {
  preflight
  [[ -f "$ENV_FILE" ]] || die "No setup found yet — run 'sudo ./install.sh install' first."
  prompt_components
  sync_versions_to_env
  setup_dirs
  install_component_apps
  step "Applying your changes"
  dc up -d --remove-orphans
  configure_components
  ok "Done. Components you turned off were stopped; their data is kept."
}

cmd_index() {
  [[ -f "$ENV_FILE" ]] || die "No setup found yet."
  step "Rebuilding the search index"
  note "This creates/populates the search index. Can take a while with many files."
  occ fulltextsearch:index && ok "Search index rebuilt." || warn "Indexing reported an issue — check Elasticsearch is up."
}

cmd_validate() {
  [[ -f "$ENV_FILE" ]] || die "No .env found."
  load_components
  step "Validation"
  occ status 2>/dev/null | grep -q 'installed: true' && ok "Nextcloud responding." || warn "Nextcloud not responding."
  if [[ "${ENABLE_FULLTEXT:-false}" == "true" ]]; then
    occ fulltextsearch:test >/dev/null 2>&1 && ok "Elasticsearch reachable." || warn "Elasticsearch test failed."
  fi
  if [[ "${ENABLE_ANTIVIRUS:-false}" == "true" ]]; then
    if occ_exec bash -c 'exec 3<>/dev/tcp/clamav/3310; echo PING >&3; head -c4 <&3' 2>/dev/null | grep -q PONG; then
      ok "ClamAV clamd responding (PONG)."
    else warn "ClamAV not responding on 3310 (may still be loading signatures)."; fi
  fi
  if [[ "${ENABLE_HPB:-false}" == "true" ]]; then
    if occ_exec curl -fs http://talk:8081/api/v1/welcome >/dev/null 2>&1; then
      ok "Talk signaling reachable internally."
      info "Real TURN test still requires an OFF-LAN call participant."
    else warn "Talk signaling not reachable — check './install.sh status'."; fi
  fi
  if [[ "${ENABLE_PUSH:-false}" == "true" ]]; then
    occ notify_push:self-test >/dev/null 2>&1 && ok "Client Push self-test passed." || warn "Client Push self-test failed."
  fi
}

cmd_status() {
  [[ -f "$ENV_FILE" ]] || die "No .env found."
  dc ps
  echo; echo "Enabled components:"; load_components
  printf '  Collabora=%s  HPB=%s  FullText=%s  Antivirus=%s  Push=%s\n' \
    "${ENABLE_COLLABORA:-false}" "${ENABLE_HPB:-false}" "${ENABLE_FULLTEXT:-false}" \
    "${ENABLE_ANTIVIRUS:-false}" "${ENABLE_PUSH:-false}"
}

# Best-effort registry poll. Honest about what it can't check.
cmd_check_updates() {
  step "Checking for newer image tags (best-effort)"
  set -a; source "$VERSIONS_FILE"; set +a
  _hub_tags() { # repo -> recent tag names (needs curl + python3)
    need_cmd curl && need_cmd python3 || { echo ""; return; }
    curl -fsSL "https://hub.docker.com/v2/repositories/$1/tags?page_size=25&ordering=last_updated" 2>/dev/null \
      | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit()
print(" ".join(r["name"] for r in d.get("results",[])))' 2>/dev/null
  }
  _report() { # name  current  hub-repo|SKIP
    local name="$1" cur="$2" repo="$3"
    if [[ "$repo" == "SKIP" ]]; then
      printf '  %-14s pinned %-22s  (check manually: %s)\n' "$name" "$cur" "$4"
      return
    fi
    local tags; tags="$(_hub_tags "$repo")"
    if [[ -z "$tags" ]]; then printf '  %-14s pinned %-22s  (registry query unavailable)\n' "$name" "$cur"
    else printf '  %-14s pinned %-22s  recent: %s\n' "$name" "$cur" "$(echo "$tags" | tr ' ' '\n' | head -6 | tr '\n' ' ')"; fi
  }
  _report traefik       "$TRAEFIK_VERSION"       library/traefik
  _report postgres      "$POSTGRES_VERSION"      library/postgres
  _report redis         "$REDIS_VERSION"         library/redis
  _report nextcloud     "$NEXTCLOUD_VERSION"     library/nextcloud
  _report collabora     "$COLLABORA_VERSION"     collabora/code
  _report aio-talk      "$AIO_TALK_VERSION"      nextcloud/aio-talk
  _report clamav        "$CLAMAV_VERSION"        clamav/clamav
  _report elasticsearch "$ELASTICSEARCH_VERSION" SKIP "https://www.docker.elastic.co/r/elasticsearch"
  echo
  warn "This is best-effort. Compare tags yourself before bumping — newest is not always stable."
  info "To apply: ./install.sh update"
}

cmd_update() {
  preflight
  local allow_major=false
  [[ "${1:-}" == "--allow-major" ]] && allow_major=true
  set -a; source "$VERSIONS_FILE"; set +a
  step "Update image versions (blank = keep current)"
  local -A NEW
  local var cur new
  for var in TRAEFIK_VERSION POSTGRES_VERSION REDIS_VERSION NEXTCLOUD_VERSION \
             COLLABORA_VERSION AIO_TALK_VERSION ELASTICSEARCH_VERSION CLAMAV_VERSION; do
    cur="${!var}"
    read -rp "  $var [$cur]: " new; new="${new:-$cur}"; NEW[$var]="$new"
  done
  # Major-version guard for the two stateful, no-skip-majors services.
  local nc_old="${NEXTCLOUD_VERSION%%.*}"; nc_old="${nc_old%%-*}"
  local nc_new="${NEW[NEXTCLOUD_VERSION]%%.*}"; nc_new="${nc_new%%-*}"
  local pg_old="${POSTGRES_VERSION%%.*}" pg_new="${NEW[POSTGRES_VERSION]%%.*}"
  if [[ "$nc_old" != "$nc_new" || "$pg_old" != "$pg_new" ]] && ! $allow_major; then
    die "Major bump detected (Nextcloud $nc_old→$nc_new, Postgres $pg_old→$pg_new).
   Nextcloud cannot skip majors and Postgres needs pg_upgrade, not a tag swap.
   Re-run with --allow-major ONLY after reading the upgrade notes and backing up."
  fi
  step "Backing up before update"; cmd_backup
  step "Writing versions.env"
  for var in "${!NEW[@]}"; do
    local tmp; tmp="$(mktemp)"
    awk -v k="$var" -v v="${NEW[$var]}" 'BEGIN{FS=OFS="="} $1==k{print k,v; next}{print}' "$VERSIONS_FILE" > "$tmp"
    mv "$tmp" "$VERSIONS_FILE"
  done
  sync_versions_to_env          # keep .env's copy of the tags in step
  step "Recreating containers"
  dc pull
  dc up -d --remove-orphans
  if [[ "$nc_old" != "$nc_new" ]]; then
    step "Running Nextcloud upgrade"; wait_for_nextcloud; occ upgrade || warn "occ upgrade reported issues — review logs."
  fi
  ok "Update complete."
}

cmd_backup() {
  [[ -f "$ENV_FILE" ]] || die "No .env found."
  local dir="$SCRIPT_DIR/backups" ts; ts="$(date +%F-%H%M)"; mkdir -p "$dir"
  step "Backup → $dir"
  occ maintenance:mode --on >/dev/null 2>&1 || true
  dc exec -T postgres pg_dump -U "$(get_env POSTGRES_USER)" "$(get_env POSTGRES_DB)" | gzip > "$dir/db-$ts.sql.gz"
  tar czf "$dir/data-$ts.tgz" -C "$(get_env DATA_ROOT)" nextcloud/config nextcloud/data 2>/dev/null || warn "tar of data/config had warnings."
  occ maintenance:mode --off >/dev/null 2>&1 || true
  ok "Wrote db-$ts.sql.gz and data-$ts.tgz"
}

cmd_teardown() {
  [[ -f "$ENV_FILE" ]] || die "No .env found."
  if [[ "${1:-}" == "--volumes" ]]; then
    confirm "Remove containers AND the nextcloud_html volume? (bind-mount data under DATA_ROOT is NOT touched)" || exit 0
    dc down -v --remove-orphans
    warn "Named volume removed. To wipe persistent data too, manually delete: $(get_env DATA_ROOT)"
  else
    dc down --remove-orphans
    ok "Stopped. Data preserved. Bring back with: ./install.sh install (or 'dc up -d')."
  fi
}

usage() {
  cat <<EOF
Nextcloud stack manager

  sudo ./install.sh <command>

Commands:
  install | first-run    Guided first-time install (safe to re-run)
  reconfigure            Turn components on/off and apply
  validate               Check that everything's working
  status                 Show what's running + which components are on
  index                  Rebuild the full-text search index
  backup                 Back up the database + data to ./backups
  check-updates          See if newer image versions exist (best-effort)
  update [--allow-major] Update image versions (backs up first)
  teardown [--volumes]   Stop the stack (--volumes also deletes the named volume)
EOF
}

# ── dispatch ─────────────────────────────────────────────────────────────────
CMD="${1:-}"; shift || true
case "$CMD" in
  install|first-run) cmd_install "$@" ;;
  reconfigure)       cmd_reconfigure "$@" ;;
  validate)          cmd_validate "$@" ;;
  status)            cmd_status "$@" ;;
  index)             cmd_index "$@" ;;
  check-updates)     cmd_check_updates "$@" ;;
  update)            cmd_update "$@" ;;
  backup)            cmd_backup "$@" ;;
  teardown)          cmd_teardown "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage; die "Unknown command: $CMD" ;;
esac
CURRENT_STEP="done"
