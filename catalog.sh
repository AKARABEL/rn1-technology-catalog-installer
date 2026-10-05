#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

###############################################################################
# CONFIGURE ONLY THIS SECTION
###############################################################################

ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"
COMPOSE_PROJECT_NAME=""

# General
TZ="Europe/Berlin"
BASEURL="http://catalog-web"

# Enable / Disable optional services
INSTALL_NGINX_PROXY_MANAGER="true"

# Image Tags
NGINX_PROXY_MANAGER_TAG="latest"
OPENSEARCH_TAG="2"
OPENSEARCH_DASHBOARDS_TAG="2"
MONGO_TAG="8"
MINIO_TAG="RELEASE.2025-10-15T17-29-55Z"
RABBITMQ_TAG="3-management-alpine"

CATALOG_VERSION="25.4.4191.133"
CATALOG_IMAGE_REPO="raynetgmbh/rayventory-catalog"
CATALOG_WORKER_IMAGE_REPO="raynetgmbh/rayventory-catalog-worker"
CHECK_FOR_UPDATES="true"

# Mongo
MONGO_INITDB_ROOT_USERNAME="raymaster_rc"
MONGO_INITDB_DATABASE="raymaster_rc"
MONGO_AUTH_DATABASE="admin"
MONGO_PORT_HOST="27017"

# MinIO
MINIO_ROOT_USER="rvc"
MINIO_API_PORT_HOST="9001"
MINIO_CONSOLE_PORT_HOST="9002"
MINIO_PORT_CONTAINER="9000"

# RabbitMQ
RABBITMQ_DEFAULT_USER="rvc"
RABBITMQ_AMQP_PORT="5672"
RABBITMQ_UI_PORT="15672"

# Catalog / App
CATALOG_WEB_PORT="8080"
CATALOG_LICENSE_PATH="/app/license"
CATALOG_CLOUD_URL="https://rayventorycatalog.raynet.de"
SYNC_MAX_UPLOAD="32GB"
HEALTH_TIMEOUT="600"
INSTALLER_URL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh"

# OpenSearch
OPENSEARCH_HEAP="-Xms512m -Xmx512m"
OPENSEARCH_URL="http://opensearch:9200"
OPENSEARCH_DASHBOARDS_PORT="5601"

# Nginx Proxy Manager
NPM_HTTP_PORT="80"
NPM_HTTPS_PORT="443"
NPM_ADMIN_PORT="81"
X_FRAME_OPTIONS="sameorigin"
DISABLE_IPV6="true"

# Shared app config
QUEUE_PREFIX="rvc"
FILESTORAGE_BUCKET="rvc"
FILESTORAGE_LOCATION="local"
AUTOSYNC_CRON="30 7 * * *"
VULNERABILITIES_CACHING_CRON="-"
ASPNETCORE_URLS="http://+:80"
ASPNETCORE_HTTP_PORTS="80"
LOG_LEVEL_DEFAULT="Information"

###############################################################################
# DO NOT CHANGE ANYTHING BELOW
###############################################################################

SCRIPT_NAME="$(basename -- "$0")"
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  # Resolve symlinks so the files always land next to the real script.
  SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null)" || SCRIPT_PATH=""
  if [ -z "$SCRIPT_PATH" ]; then
    SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
  fi
  WORK_DIR="$(dirname -- "$SCRIPT_PATH")"
else
  # Script is not a regular file (e.g. piped into bash): work in the current folder.
  SCRIPT_PATH=""
  WORK_DIR="$PWD"
fi

API_KEY_FILE="$WORK_DIR/.catalog_api_key"
LOCAL_KEY_FILE="$WORK_DIR/.catalog_local_api_key"
JOBS_DIR="$WORK_DIR/.jobs"
TUI_NOTICE=""
LAST_BACKUP=""
SCP_SECRET=""
INTERACTIVE="false"
GENERATE_CANCELLED="false"
TZ_CHANGED="false"
COMPOSE=()
COMPOSE_PROBLEM=""
LATEST_VERSION=""
HUB_STATUS="unchecked"
HUB_VERSIONS=""
HUB_STABLE=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YLW=$'\033[1;33m'; C_BLU=$'\033[1;34m'
  C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi

###############################################################################
# Helpers
###############################################################################

info() { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s OK%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%sWARN%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
err()  { printf '%sERROR%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

# confirm "Question" [y|n]  -> returns 0 for yes
confirm() {
  local prompt="$1" default="${2:-n}" hint answer
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  if ! read -r -p "$prompt $hint " answer; then
    return 1
  fi
  case "${answer:-$default}" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

pause() {
  local dummy
  read -r -p "Press Enter to return to the menu..." dummy || true
}

clear_screen() {
  if [ -t 1 ] && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
}

rand32() {
  set +o pipefail
  local v
  v="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  set -o pipefail
  printf '%s' "$v"
}

# Value of KEY in the generated env file (empty if missing).
env_value() {
  local key="$1"
  if [ -f "$ENV_FILE" ]; then
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
  fi
}

# Value of KEY as generated (from the env file), falling back to the setting above.
setting() {
  local key="$1" value
  value="$(env_value "$key")"
  if [ -z "$value" ]; then
    value="${!key-}"
  fi
  printf '%s' "$value"
}

editor_name() {
  printf '%s' "${VISUAL:-${EDITOR:-vi}}"
}

# open_editor FILE [LINE]
open_editor() {
  local file="$1" line="${2:-}" editor=()
  read -r -a editor <<< "$(editor_name)"
  if ! command -v "${editor[0]}" >/dev/null 2>&1; then
    err "Editor '${editor[0]}' not found. Install vi/vim or set EDITOR (e.g. EDITOR=nano)."
    return 1
  fi
  if [ -n "$line" ]; then
    "${editor[@]}" "+$line" "$file"
  else
    "${editor[@]}" "$file"
  fi
}

# Run a command and page its output when a terminal is attached.
page() {
  if [ -t 1 ] && command -v less >/dev/null 2>&1; then
    "$@" | less -R || true
  else
    "$@"
  fi
}

# Copies this script to SCRIPT.bak-<timestamp> (never over an existing backup) and prints the name.
script_backup() {
  local target n=1
  target="$SCRIPT_PATH.bak-$(date +%Y%m%d-%H%M%S)"
  while [ -e "$target" ]; do
    target="$SCRIPT_PATH.bak-$(date +%Y%m%d-%H%M%S)-$n"
    n=$((n + 1))
  done
  cp -p -- "$SCRIPT_PATH" "$target"
  printf '%s' "$target"
}

backup_file() {
  local file="$1" target
  if [ ! -f "$file" ]; then
    return 0
  fi
  target="${file}.bak-$(date +%Y%m%d-%H%M%S)"
  if [ -e "$target" ]; then
    target="${target}-$$"
  fi
  cp -p -- "$file" "$target"
  info "Backup created: $target"
}

# Newest backup of the env file (empty if there is none).
newest_env_backup() {
  local f newest=""
  for f in "$ENV_FILE".bak-*; do
    if [ -f "$f" ]; then
      newest="$f"
    fi
  done
  printf '%s' "$newest"
}

# Where to run a step: a menu option in the menu, a command on the command line.
# hint MENU_OPTION COMMAND
hint() {
  if [ "$INTERACTIVE" = "true" ]; then
    printf 'menu option %s' "$1"
  else
    printf "'%s %s'" "$0" "$2"
  fi
}

host_ip() {
  local addr=""
  addr="$(hostname -I 2>/dev/null | awk '{print $1}')" || addr=""
  if [ -z "$addr" ]; then
    addr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')" || addr=""
  fi
  printf '%s' "${addr:-<server-ip>}"
}

count_lines() {
  local n=0 l
  while IFS= read -r l; do
    if [ -n "$l" ]; then
      n=$((n + 1))
    fi
  done <<< "$1"
  printf '%s' "$n"
}

# Names of the settings that publish a port on the host.
port_settings() {
  echo CATALOG_WEB_PORT MONGO_PORT_HOST MINIO_API_PORT_HOST MINIO_CONSOLE_PORT_HOST \
    RABBITMQ_AMQP_PORT RABBITMQ_UI_PORT OPENSEARCH_DASHBOARDS_PORT
  if [ "$INSTALL_NGINX_PROXY_MANAGER" = "true" ]; then
    echo NPM_HTTP_PORT NPM_HTTPS_PORT NPM_ADMIN_PORT
  fi
}

###############################################################################
# Docker / Compose
###############################################################################

detect_compose() {
  local v
  if [ "${#COMPOSE[@]}" -gt 0 ]; then
    return 0
  fi
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    # The generated file has no "version:" key, which needs docker-compose 1.27 or newer.
    v="$(docker-compose version --short 2>/dev/null)" || v=""
    v="${v#v}"
    case "$v" in
      1.2[7-9]*|[2-9]*) COMPOSE=(docker-compose) ;;
      *)
        COMPOSE_PROBLEM="docker-compose ${v:-(unknown version)} is too old (1.27 or newer needed) - install the docker-compose-plugin package."
        return 1
        ;;
    esac
  else
    COMPOSE_PROBLEM="Docker Compose is not available (neither 'docker compose' nor 'docker-compose') - install the docker-compose-plugin package."
    return 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker is not installed (or not in PATH)."
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    err "Cannot reach the Docker daemon. Is Docker running, and is your user in the 'docker' group?"
    return 1
  fi
  if ! detect_compose; then
    err "$COMPOSE_PROBLEM"
    return 1
  fi
}

compose() {
  if [ -n "$COMPOSE_PROJECT_NAME" ]; then
    "${COMPOSE[@]}" -p "$COMPOSE_PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  else
    "${COMPOSE[@]}" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
  fi
}

require_files() {
  if [ ! -f "$ENV_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    err "$ENV_FILE and/or $COMPOSE_FILE not found in $WORK_DIR - generate them first ($(hint 2 generate))."
    return 1
  fi
}

# Docker volumes that already belong to this Compose project (empty if none
# or if Docker cannot be reached).
project_volumes() {
  local project="${COMPOSE_PROJECT_NAME:-$(basename -- "$WORK_DIR")}"
  project="$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  docker volume ls -q --filter "label=com.docker.compose.project=${project}" 2>/dev/null || true
}

# True when the generated files differ from what the current settings would
# produce (settings changed after generating, or the files were edited by hand).
settings_stale() {
  local tmp_env tmp_compose rc=1
  if [ ! -f "$ENV_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    return 1
  fi
  tmp_env="$(mktemp)" || return 1
  tmp_compose="$(mktemp)" || { rm -f "$tmp_env"; return 1; }
  (
    for var in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS; do
      printf -v "$var" '%s' "$(env_value "$var")"
    done
    ENV_FILE="$tmp_env"
    COMPOSE_FILE="$tmp_compose"
    write_env_file
    write_compose_file
  )
  if [ "$(cat "$tmp_env")" != "$(cat "$ENV_FILE")" ] || [ "$(cat "$tmp_compose")" != "$(cat "$COMPOSE_FILE")" ]; then
    rc=0
  fi
  rm -f "$tmp_env" "$tmp_compose"
  return "$rc"
}

###############################################################################
# Catalog versions (Docker Hub)
###############################################################################

http_get() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 5 --max-time 20 "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 20 -O - "$1"
  else
    return 127
  fi
}

# Tags of a Docker Hub repository, one "NAME DIGEST" line per tag ("-" if there is no digest).
hub_tags() {
  local url="https://hub.docker.com/v2/repositories/$1/tags?page_size=100" body pages=0
  while [ -n "$url" ] && [ "$pages" -lt 20 ]; do
    body="$(http_get "$url")" || return 1
    printf '%s\n' "$body" | grep -o '"name": *"[^"]*"[^}]*}' | awk '{
      name = $0; sub(/^"name": *"/, "", name); sub(/".*/, "", name)
      digest = "-"
      if (match($0, /"digest": *"[^"]*"/)) {
        digest = substr($0, RSTART, RLENGTH); sub(/^"digest": *"/, "", digest); sub(/"$/, "", digest)
      }
      print name, digest
    }' || true
    url="$(printf '%s\n' "$body" | grep -o '"next": *"[^"]*"' | sed 's/^"next": *"//; s/"$//; s/\\u0026/\&/g')" || url=""
    pages=$((pages + 1))
  done
}

# True when the configured MongoDB (8 or newer) refuses to start on the running
# kernel: MongoDB 8 stops on kernels 6.19 to 7.0.13 (SERVER-121912).
mongo_kernel_problem() {
  local tag
  tag="$(setting MONGO_TAG)"
  if [[ "$tag" =~ ^([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -lt 8 ]; then
    return 1
  fi
  kernel_blocks_mongo8
}

kernel_blocks_mongo8() {
  local release major minor patch
  release="$(uname -r 2>/dev/null)" || return 1
  if ! [[ "$release" =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
    return 1
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[4]:-0}"
  if [ "$major" -eq 6 ] && [ "$minor" -ge 19 ]; then
    return 0
  fi
  [ "$major" -eq 7 ] && [ "$minor" -eq 0 ] && [ "$patch" -lt 14 ]
}

is_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# version_gt A B -> true when version A is newer than version B
version_gt() {
  local IFS=.
  local -a a b
  local i
  a=($1)
  b=($2)
  for i in 0 1 2 3; do
    if [ "${a[i]:-0}" -gt "${b[i]:-0}" ]; then
      return 0
    fi
    if [ "${a[i]:-0}" -lt "${b[i]:-0}" ]; then
      return 1
    fi
  done
  return 1
}

# Only keeps X.Y.Z.B versions and sorts them newest first.
sort_versions() {
  grep -xE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr || true
}

# Sets HUB_VERSIONS (versions that exist for both the Catalog and the worker
# image, newest first) and HUB_STABLE (the version the "stable" tag points to).
fetch_hub_versions() {
  local web worker stable_digest
  HUB_VERSIONS=""
  HUB_STABLE=""
  web="$(hub_tags "$CATALOG_IMAGE_REPO")" || return 1
  worker="$(hub_tags "$CATALOG_WORKER_IMAGE_REPO")" || return 1
  HUB_VERSIONS="$(printf '%s\n' "$web" | cut -d' ' -f1 \
    | grep -xF -f <(printf '%s\n' "$worker" | cut -d' ' -f1 | sort_versions) | sort_versions)" || HUB_VERSIONS=""
  if [ -z "$HUB_VERSIONS" ]; then
    return 1
  fi
  stable_digest="$(printf '%s\n' "$web" | awk '$1 == "stable" && $2 != "-" { print $2; exit }')" || stable_digest=""
  if [ -n "$stable_digest" ]; then
    HUB_STABLE="$(printf '%s\n' "$web" | awk -v d="$stable_digest" '$2 == d { print $1 }' \
      | grep -xF -f <(printf '%s\n' "$HUB_VERSIONS") | sort_versions | head -n 1)" || HUB_STABLE=""
  fi
}

# Sets LATEST_VERSION and HUB_STATUS (ok / failed / disabled) once for the menu header.
check_latest_version() {
  if [ "$CHECK_FOR_UPDATES" != "true" ]; then
    HUB_STATUS="disabled"
    return 0
  fi
  if fetch_hub_versions; then
    LATEST_VERSION="${HUB_VERSIONS%%$'\n'*}"
    HUB_STATUS="ok"
  else
    HUB_STATUS="failed"
  fi
}

# "26.3.4789.148 (stable)" when the version is the one the "stable" tag points to.
version_with_tag() {
  if [ -n "$HUB_STABLE" ] && [ "$1" = "$HUB_STABLE" ]; then
    printf '%s (stable)' "$1"
  else
    printf '%s' "$1"
  fi
}

version_label() {
  local label="Catalog $CATALOG_VERSION"
  case "$HUB_STATUS" in
    ok)
      if [ "$LATEST_VERSION" = "$CATALOG_VERSION" ]; then
        label="$label - ${C_GRN}up to date${C_RST}"
      elif ! is_version "$CATALOG_VERSION"; then
        label="$label - newest on Docker Hub: $(version_with_tag "$LATEST_VERSION")"
      elif version_gt "$LATEST_VERSION" "$CATALOG_VERSION"; then
        label="$label - ${C_YLW}update available: $(version_with_tag "$LATEST_VERSION"), option 8${C_RST}"
      fi
      ;;
    failed)
      label="$label - newest version unknown (Docker Hub not reachable)"
      ;;
  esac
  printf '%s' "$label"
}

# The settings section of FILE, from '# CONFIGURE ONLY THIS SECTION' to '# DO NOT CHANGE ANYTHING
# BELOW'. Fails when one of the two lines is missing.
settings_section() {
  awk '/^# CONFIGURE ONLY THIS SECTION/ { s = 1 } s { print } s && /^# DO NOT CHANGE ANYTHING BELOW/ { e = 1; exit } END { exit !e }' "$1" 2>/dev/null
}

# NAME|VALUE for every setting of FILE, with the values bash reads (quotes, escapes and comments
# handled by bash itself; a later assignment wins). Fails when the settings section is damaged.
settings_pairs() {
  local sec names
  sec="$(settings_section "$1")" || return 1
  names="$(printf '%s\n' "$sec" | sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' | awk '!seen[$0]++')"
  (
    set +eu
    eval "$sec" >/dev/null 2>&1
    for n in $names; do
      printf '%s|%s\n' "$n" "${!n}"
    done
  )
}

# Value of a setting of this script file.
script_setting() {
  if [ -z "$SCRIPT_PATH" ]; then
    return 0
  fi
  settings_pairs "$SCRIPT_PATH" | sed -n "s/^$1|//p" | tail -n 1
}

# has_setting FILE NAME -> true when the settings section of FILE assigns NAME
has_setting() {
  local pairs
  pairs="$(settings_pairs "$1")" || return 1
  grep -q "^$2|" <<< "$pairs"
}

# set_setting NAME VALUE [FILE] -> writes NAME="VALUE" into the settings section of this script (or of FILE).
# Every assignment of NAME in the settings section is replaced, whatever its quotes.
set_setting() {
  local name="$1" value="$2" file="${3:-$SCRIPT_PATH}" tmp marked=0
  if [ -z "$file" ] || [ ! -w "$file" ]; then
    err "Cannot change ${file:-$SCRIPT_NAME} (not writable)."
    return 1
  fi
  if grep -q '^# CONFIGURE ONLY THIS SECTION' "$file"; then
    marked=1
    if ! settings_section "$file" >/dev/null; then
      err "The settings section of $file has no '# DO NOT CHANGE ANYTHING BELOW' line - not changed."
      return 1
    fi
  fi
  # inside double quotes, \ " $ and ` keep their meaning only when escaped
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"
  tmp="$(mktemp)"
  if ! SET_NAME="$name" SET_VALUE="$value" SET_MARKED="$marked" awk '
      BEGIN { n = ENVIRON["SET_NAME"]; v = ENVIRON["SET_VALUE"]; marked = ENVIRON["SET_MARKED"] + 0 }
      /^# CONFIGURE ONLY THIS SECTION/ { insec = 1 }
      /^# DO NOT CHANGE ANYTHING BELOW/ { insec = 0 }
      marked && insec && index($0, n "=") == 1 { print n "=\"" v "\""; done = 1; next }
      !marked && !done && index($0, n "=\"") == 1 { print n "=\"" v "\""; done = 1; next }
      { print }
      END { exit !done }' "$file" > "$tmp"; then
    rm -f -- "$tmp"
    err "$name not found in $file."
    return 1
  fi
  # Write the content back instead of moving the file, so owner and mode stay.
  if ! cat -- "$tmp" > "$file"; then
    rm -f -- "$tmp"
    err "Cannot write $file."
    return 1
  fi
  rm -f -- "$tmp"
}

# Prints the newest versions (at most 4), numbered when $1 is "numbered".
print_versions() {
  local style="${1:-}" generated v i=0 marker
  generated="$(env_value CATALOG_IMAGE)"
  generated="${generated##*:}"
  echo "Newest versions available for both $CATALOG_IMAGE_REPO and $CATALOG_WORKER_IMAGE_REPO:"
  while IFS= read -r v; do
    if [ "$i" -ge 4 ]; then
      break
    fi
    i=$((i + 1))
    marker=""
    if [ "$v" = "$CATALOG_VERSION" ]; then
      marker="$marker  (selected)"
    fi
    if [ -n "$generated" ] && [ "$v" = "$generated" ] && [ "$generated" != "$CATALOG_VERSION" ]; then
      marker="$marker  (in $ENV_FILE)"
    fi
    if [ "$style" = "numbered" ]; then
      printf '  %d) %s%s\n' "$i" "$(version_with_tag "$v")" "$marker"
    else
      printf '  %s%s\n' "$(version_with_tag "$v")" "$marker"
    fi
  done <<< "$HUB_VERSIONS"
}

# The newest versions (at most 4) as a numbered list with markers.
print_version_choices() {
  local generated="$1" v i=0 marker
  while IFS= read -r v; do
    if [ "$i" -ge 4 ]; then
      break
    fi
    i=$((i + 1))
    marker=""
    if [ -n "$HUB_STABLE" ] && [ "$v" = "$HUB_STABLE" ]; then
      marker="$marker  $C_YLW$UI_STAR stable$C_RST"
    fi
    if [ "$v" = "$CATALOG_VERSION" ]; then
      marker="$marker  $C_GRN$UI_DOT selected$C_RST"
    fi
    if [ -n "$generated" ] && [ "$v" = "$generated" ] && [ "$generated" != "$CATALOG_VERSION" ]; then
      marker="$marker  $C_DIM$UI_DOT in $ENV_FILE$C_RST"
    fi
    if is_version "$CATALOG_VERSION" && version_gt "$CATALOG_VERSION" "$v"; then
      marker="$marker  ${C_DIM}older$C_RST"
    fi
    printf '   %s  %s%s\n' "$C_BLD$i$C_RST" "$(ui_pad "$v" 16)" "$marker"
  done <<< "$HUB_VERSIONS"
}

# Menu: pick a version from Docker Hub, store it as CATALOG_VERSION and optionally apply it.
select_version() {
  local mode="${1:-}" choice selected="" generated count
  info "Reading the available versions from Docker Hub..."
  if ! fetch_hub_versions; then
    err "Could not read the versions from Docker Hub (no internet access, a proxy is needed, or the images are not on Docker Hub)."
    echo "CATALOG_VERSION can still be changed by hand with option 1."
    return 1
  fi
  count="$(count_lines "$HUB_VERSIONS")"
  if [ "$count" -gt 4 ]; then
    count=4
  fi
  generated="$(env_value CATALOG_IMAGE)"
  generated="${generated##*:}"

  while [ -z "$selected" ]; do
    echo
    ui_box "$(ui_width)" "Catalog version" \
      "Selected in $SCRIPT_NAME: $C_BLD$(ui_version "$CATALOG_VERSION")$C_RST$(if [ -n "$generated" ]; then printf '   %s %s in %s: %s%s' "$C_DIM" "$UI_SEP" "$ENV_FILE" "$generated" "$C_RST"; fi)" \
      "${C_DIM}catalog-web and all 4 workers use this version$C_RST"
    print_version_choices "$generated"
    printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}cancel$C_RST"
    echo
    ui_ask choice "Select a version [0]:" || choice="0"
    choice="${choice:-0}"
    if [ "$choice" = "0" ]; then
      info "Cancelled - nothing was changed."
      return 0
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      selected="$(sed -n "${choice}p" <<< "$HUB_VERSIONS")"
    elif grep -qxF -- "$choice" <<< "$HUB_VERSIONS"; then
      selected="$choice"
    else
      warn "Invalid choice: $choice"
    fi
  done

  if [ "$selected" = "$CATALOG_VERSION" ]; then
    info "$selected is already selected."
  else
    if is_version "$CATALOG_VERSION" && version_gt "$CATALOG_VERSION" "$selected"; then
      warn "$selected is OLDER than the selected $CATALOG_VERSION."
      warn "A downgrade can fail if the database was already updated by the newer version."
      if ! confirm "Select $selected anyway?" n; then
        info "Cancelled - nothing was changed."
        return 0
      fi
    fi
    set_setting CATALOG_VERSION "$selected"
    CATALOG_VERSION="$selected"
    ok "CATALOG_VERSION set to $selected - catalog-web and all workers will use this version."
  fi

  if [ "$mode" = "no-apply" ]; then
    return 0
  fi
  if [ -f "$ENV_FILE" ] && [ "$generated" = "$selected" ] && ! settings_stale; then
    return 0
  fi
  echo
  if confirm "Apply $selected now? (generate the files - passwords are kept - and start the stack)" y; then
    do_generate keep no-next
    if [ "$GENERATE_CANCELLED" = "true" ]; then
      return 0
    fi
    echo
    do_up
  else
    echo "Apply it later with option 2 (generate) and option 6 (start)."
  fi
}

list_versions() {
  if ! fetch_hub_versions; then
    err "Could not read the versions from Docker Hub."
    return 1
  fi
  print_versions
}

set_version_cli() {
  local wanted="${1:-}"
  if [ -z "$wanted" ]; then
    err "Usage: $0 set-version VERSION|stable"
    return 2
  fi
  if fetch_hub_versions; then
    if [ "$wanted" = "stable" ]; then
      if [ -z "$HUB_STABLE" ]; then
        err "The \"stable\" tag does not point to a version that exists for both images."
        return 1
      fi
      wanted="$HUB_STABLE"
    fi
    if ! grep -qxF -- "$wanted" <<< "$HUB_VERSIONS"; then
      err "$wanted is not available for both images - see '$0 versions'."
      return 1
    fi
  else
    if ! is_version "$wanted"; then
      err "Could not read the versions from Docker Hub - give an exact version (e.g. 26.3.4789.148)."
      return 1
    fi
    warn "Could not read the versions from Docker Hub - $wanted is not checked."
  fi
  if is_version "$CATALOG_VERSION" && version_gt "$CATALOG_VERSION" "$wanted"; then
    warn "$wanted is OLDER than $CATALOG_VERSION - a downgrade can fail if the database was already updated."
  fi
  set_setting CATALOG_VERSION "$wanted"
  CATALOG_VERSION="$wanted"
  ok "CATALOG_VERSION set to $wanted - catalog-web and all workers will use this version."
  echo "Apply it with:"
  echo "  $0 generate"
  echo "  $0 up"
}

###############################################################################
# Updates and offline bundle
###############################################################################

MANIFEST_TYPES="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"
UPD_KEYS=(opensearch mongo rabbitmq minio npm)
declare -A UPD_VERSIONS=() UPD_RESOLVED=()
UPD_CATALOG_OK="0"
UPD_CHECKED=""
REG_HOST=""
REG_REPO=""
REG_AUTH=()
C_LABEL=""
C_SETTINGS=""
C_IMAGES=""
C_KIND=""
ST_TEXT=""
ST_COLOR=""

component_info() {
  case "$1" in
    opensearch)
      C_LABEL="OpenSearch + Dashboards"
      C_SETTINGS="OPENSEARCH_TAG OPENSEARCH_DASHBOARDS_TAG"
      C_IMAGES="opensearchproject/opensearch opensearchproject/opensearch-dashboards"
      C_KIND="semver"
      ;;
    mongo)
      C_LABEL="MongoDB"
      C_SETTINGS="MONGO_TAG"
      C_IMAGES="mongo"
      C_KIND="semver"
      ;;
    rabbitmq)
      C_LABEL="RabbitMQ"
      C_SETTINGS="RABBITMQ_TAG"
      C_IMAGES="rabbitmq"
      C_KIND="rabbit"
      ;;
    minio)
      C_LABEL="MinIO (golithus fork)"
      C_SETTINGS="MINIO_TAG"
      C_IMAGES="ghcr.io/golithus/minio"
      C_KIND="minio"
      ;;
    npm)
      C_LABEL="Nginx Proxy Manager"
      C_SETTINGS="NGINX_PROXY_MANAGER_TAG"
      C_IMAGES="jc21/nginx-proxy-manager"
      C_KIND="semver"
      ;;
  esac
}

kind_regex() {
  case "$1" in
    semver) printf '%s' '^[0-9]+\.[0-9]+\.[0-9]+$' ;;
    rabbit) printf '%s' '^[0-9]+\.[0-9]+\.[0-9]+-management-alpine$' ;;
    minio) printf '%s' '^RELEASE\.[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z$' ;;
    catalog) printf '%s' '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ;;
  esac
}

# Newest first.
kind_sort() {
  if [ "$1" = "minio" ]; then
    sort -r
  else
    sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr
  fi
}

version_core() {
  printf '%s' "${1%-management-alpine}"
}

version_major() {
  local core
  core="$(version_core "$1")"
  printf '%s' "${core%%.*}"
}

# kind_newer KIND A B -> true when A is newer than B
kind_newer() {
  if [ "$1" = "minio" ]; then
    [[ "$2" > "$3" ]]
  else
    version_gt "$(version_core "$2")" "$(version_core "$3")"
  fi
}

is_exact_tag() {
  local kind
  for kind in semver rabbit minio catalog; do
    if [[ "$1" =~ $(kind_regex "$kind") ]]; then
      return 0
    fi
  done
  return 1
}

# Sets REG_HOST, REG_REPO and REG_AUTH (anonymous pull token) for an image name.
registry_session() {
  local image="$1" first="${1%%/*}" resp code challenge realm service token
  if [[ "$image" == */* ]] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = "localhost" ]; }; then
    REG_HOST="$first"
    REG_REPO="${image#*/}"
  elif [[ "$image" == */* ]]; then
    REG_HOST="registry-1.docker.io"
    REG_REPO="$image"
  else
    REG_HOST="registry-1.docker.io"
    REG_REPO="library/$image"
  fi
  REG_AUTH=()
  resp="$(curl -sS -o /dev/null -D - -w 'HTTP_CODE:%{http_code}' --connect-timeout 5 --max-time 20 "https://$REG_HOST/v2/" 2>/dev/null | tr -d '\r')" || resp=""
  code="${resp##*HTTP_CODE:}"
  if [ "$code" = "200" ]; then
    return 0
  fi
  if [ "$code" != "401" ]; then
    return 1
  fi
  challenge="$(grep -i '^www-authenticate: *bearer' <<< "$resp" | head -n 1)" || challenge=""
  realm="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<< "$challenge")"
  service="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<< "$challenge")"
  if [ -z "$realm" ]; then
    return 1
  fi
  token="$(curl -fsS --connect-timeout 5 --max-time 20 "${realm}?service=${service}&scope=repository:${REG_REPO}:pull" 2>/dev/null \
    | grep -o '"token": *"[^"]*"' | head -n 1 | sed 's/^"token": *"//; s/"$//')" || token=""
  if [ -z "$token" ]; then
    return 1
  fi
  REG_AUTH=(-H "Authorization: Bearer $token")
}

# All tags of the current registry session, one per line.
reg_tags() {
  local url="https://$REG_HOST/v2/$REG_REPO/tags/list?n=10000" tmp next pages=0
  tmp="$(mktemp -d)" || return 1
  while [ -n "$url" ] && [ "$pages" -lt 50 ]; do
    if ! curl -fsS --connect-timeout 5 --max-time 60 ${REG_AUTH[@]+"${REG_AUTH[@]}"} -D "$tmp/headers" -o "$tmp/body" "$url" 2>/dev/null; then
      rm -rf -- "$tmp"
      return 1
    fi
    grep -o '"tags": *\[[^]]*\]' "$tmp/body" | sed 's/^"tags": *\[//; s/\]$//' | tr ',' '\n' | sed 's/^ *"//; s/" *$//' | grep -v '^$' || true
    next="$(tr -d '\r' < "$tmp/headers" | sed -n 's/^[Ll][Ii][Nn][Kk]: *<\([^>]*\)>.*rel="next".*/\1/p' | head -n 1)" || next=""
    if [ -n "$next" ] && [ "${next#/}" != "$next" ]; then
      next="https://$REG_HOST$next"
    fi
    url="$next"
    pages=$((pages + 1))
  done
  rm -rf -- "$tmp"
}

# Manifest digest of TAG in the current registry session (empty if unknown).
reg_digest() {
  curl -fsS -I --connect-timeout 5 --max-time 20 ${REG_AUTH[@]+"${REG_AUTH[@]}"} -H "Accept: $MANIFEST_TYPES" \
    "https://$REG_HOST/v2/$REG_REPO/manifests/$1" 2>/dev/null \
    | tr -d '\r' | grep -i '^docker-content-digest:' | head -n 1 | sed 's/^[^:]*: *//' || true
}

# Digest of the linux/amd64 image behind TAG (for multi-platform tags), else the manifest digest.
reg_platform_digest() {
  local body
  body="$(curl -fsS --connect-timeout 5 --max-time 20 ${REG_AUTH[@]+"${REG_AUTH[@]}"} -H "Accept: $MANIFEST_TYPES" \
    "https://$REG_HOST/v2/$REG_REPO/manifests/$1" 2>/dev/null)" || return 0
  if [[ "$body" != *'"manifests"'* ]]; then
    reg_digest "$1"
    return 0
  fi
  tr -d ' \t\r\n' <<< "$body" | sed 's/},{/}\n{/g' | grep '"architecture":"amd64"' | grep '"os":"linux"' \
    | grep -o '"digest":"sha256:[0-9a-f]*"' | head -n 1 | sed 's/^"digest":"//; s/"$//' || true
}

# Fills UPD_VERSIONS[KEY] (exact versions that exist for all images of the
# component, newest first) and UPD_RESOLVED[KEY] (exact version of the current tag).
fetch_component() {
  local key="$1" image first tag regex all versions base digest cand checked fn other other_tags
  component_info "$key"
  UPD_VERSIONS[$key]=""
  UPD_RESOLVED[$key]=""
  image="${C_IMAGES%% *}"
  first="${C_SETTINGS%% *}"
  tag="${!first}"
  regex="$(kind_regex "$C_KIND")"
  registry_session "$image" || return 1
  all="$(reg_tags)" || return 1
  versions="$(grep -xE "$regex" <<< "$all" | kind_sort "$C_KIND")" || versions=""
  if [[ "$tag" =~ $regex ]]; then
    UPD_RESOLVED[$key]="$tag"
  else
    base="$(version_core "$tag")"
    for fn in reg_digest reg_platform_digest; do
      if [ -n "${UPD_RESOLVED[$key]}" ]; then
        break
      fi
      digest="$("$fn" "$tag")"
      if [ -z "$digest" ]; then
        continue
      fi
      checked=0
      while IFS= read -r cand; do
        if [ -z "$cand" ]; then
          continue
        fi
        if [[ "$base" =~ ^[0-9] ]] && [[ "${cand%-management-alpine}" != "$base".* ]]; then
          continue
        fi
        checked=$((checked + 1))
        if [ "$checked" -gt 3 ]; then
          break
        fi
        if [ "$("$fn" "$cand")" = "$digest" ]; then
          UPD_RESOLVED[$key]="$cand"
          break
        fi
      done <<< "$versions"
    done
  fi
  for other in ${C_IMAGES#"$image"}; do
    registry_session "$other" || return 1
    other_tags="$(reg_tags)" || return 1
    versions="$(grep -xF -f <(grep -xE "$regex" <<< "$other_tags" || true) <<< "$versions")" || versions=""
  done
  UPD_VERSIONS[$key]="$versions"
  [ -n "$versions" ]
}

# Checks all components in parallel; results come back through files.
collect_updates() {
  local key tmp
  info "Checking Docker Hub and GHCR for new versions..."
  tmp="$(mktemp -d)"
  trap 'kill $(jobs -p) 2>/dev/null; rm -rf -- "$tmp"; exit 130' INT TERM
  (
    if fetch_hub_versions; then
      printf '%s' "$HUB_VERSIONS" > "$tmp/catalog.versions"
      printf '%s' "$HUB_STABLE" > "$tmp/catalog.stable"
    fi
  ) &
  for key in "${UPD_KEYS[@]}"; do
    (
      if fetch_component "$key"; then
        printf '%s' "${UPD_VERSIONS[$key]}" > "$tmp/$key.versions"
      fi
      printf '%s' "${UPD_RESOLVED[$key]-}" > "$tmp/$key.resolved"
    ) &
  done
  wait
  trap - INT TERM
  UPD_CATALOG_OK="0"
  HUB_VERSIONS=""
  HUB_STABLE=""
  if [ -s "$tmp/catalog.versions" ]; then
    UPD_CATALOG_OK="1"
    HUB_VERSIONS="$(cat -- "$tmp/catalog.versions")"
    HUB_STABLE="$(cat -- "$tmp/catalog.stable")"
  fi
  for key in "${UPD_KEYS[@]}"; do
    UPD_VERSIONS[$key]=""
    UPD_RESOLVED[$key]=""
    if [ -s "$tmp/$key.versions" ]; then
      UPD_VERSIONS[$key]="$(cat -- "$tmp/$key.versions")"
    fi
    if [ -s "$tmp/$key.resolved" ]; then
      UPD_RESOLVED[$key]="$(cat -- "$tmp/$key.resolved")"
    fi
  done
  rm -rf -- "$tmp"
  UPD_CHECKED="$(date +%H:%M)"
}

# Sets ST_TEXT and ST_COLOR for a component row.
row_status() {
  local kind="$1" resolved="$2" versions="$3" newest same="" v core major
  ST_COLOR="$C_RED"
  if [ -z "$versions" ]; then
    ST_TEXT="unknown (registry not reachable)"
    return 0
  fi
  newest="${versions%%$'\n'*}"
  if [ -z "$resolved" ]; then
    ST_TEXT="current tag not found in the registry"
    return 0
  fi
  if [ "$resolved" = "$newest" ]; then
    ST_TEXT="up to date"
    ST_COLOR="$C_GRN"
    return 0
  fi
  ST_COLOR="$C_YLW"
  if [ "$kind" = "catalog" ] || [ "$kind" = "minio" ]; then
    if kind_newer "$kind" "$newest" "$resolved"; then
      ST_TEXT="update available"
    else
      ST_TEXT="up to date"
      ST_COLOR="$C_GRN"
    fi
    return 0
  fi
  major="$(version_major "$resolved")"
  while IFS= read -r v; do
    core="${v%-management-alpine}"
    if [ "${core%%.*}" = "$major" ]; then
      same="$v"
      break
    fi
  done <<< "$versions"
  if [ -n "$same" ] && kind_newer "$kind" "$same" "$resolved"; then
    ST_TEXT="update available: $(version_core "$same")"
  elif kind_newer "$kind" "$newest" "$resolved"; then
    ST_TEXT="major update"
  else
    ST_TEXT="up to date"
    ST_COLOR="$C_GRN"
  fi
}

# Current value of a component: the exact version, or the tag with the version it points to.
current_label() {
  local tag="$1" resolved="$2"
  if [ -n "$resolved" ] && [ "$resolved" != "$tag" ]; then
    printf '%s (= %s)' "$tag" "$(version_core "$resolved")"
  else
    printf '%s' "$tag"
  fi
}

show_updates() {
  local i=1 key first tag resolved versions newest cat_resolved w_cur=34 w_new=31 head
  local -a rows=()
  if [ "$(ui_width)" -lt 112 ]; then
    w_cur=26
    w_new=24
  fi

  cat_resolved="$CATALOG_VERSION"
  if ! is_version "$cat_resolved"; then
    cat_resolved=""
    if [ "$CATALOG_VERSION" = "stable" ]; then
      cat_resolved="$HUB_STABLE"
    fi
  fi
  if [ "$UPD_CATALOG_OK" = "1" ]; then
    row_status catalog "$cat_resolved" "$HUB_VERSIONS"
    if [ -z "$cat_resolved" ]; then
      ST_TEXT="version behind the tag unknown"
    fi
    newest="$(ui_version "${HUB_VERSIONS%%$'\n'*}")"
  else
    row_status catalog "" ""
    newest="-"
  fi
  rows+=("$(ui_pad "$C_BLD$i$C_RST" 4)$(ui_pad "Catalog + 4 workers" 26)$(ui_pad "$(ui_current "$CATALOG_VERSION" "${cat_resolved:-$CATALOG_VERSION}")" "$w_cur")$(ui_pad "$newest" "$w_new")$(ui_badge "$ST_TEXT" "$ST_COLOR")")

  for key in "${UPD_KEYS[@]}"; do
    i=$((i + 1))
    component_info "$key"
    first="${C_SETTINGS%% *}"
    tag="${!first}"
    versions="${UPD_VERSIONS[$key]-}"
    if [[ "$tag" =~ $(kind_regex "$C_KIND") ]]; then
      resolved="$tag"
    else
      resolved="${UPD_RESOLVED[$key]-}"
    fi
    row_status "$C_KIND" "$resolved" "$versions"
    newest="-"
    if [ -n "$versions" ]; then
      newest="$(version_core "${versions%%$'\n'*}")"
    fi
    if [ "$key" = "mongo" ] && [ -n "$versions" ] && [[ "$(version_major "${versions%%$'\n'*}")" =~ ^[0-9]+$ ]] \
      && [ "$(version_major "${versions%%$'\n'*}")" -ge 8 ] && kernel_blocks_mongo8; then
      ST_TEXT="$ST_TEXT - 8.0+ may fail on this kernel"
    fi
    if [ "$key" = "npm" ] && [ "$INSTALL_NGINX_PROXY_MANAGER" != "true" ]; then
      ST_TEXT="$ST_TEXT (disabled)"
    fi
    rows+=("$(ui_pad "$C_BLD$i$C_RST" 4)$(ui_pad "$C_LABEL" 26)$(ui_pad "$(ui_current "$tag" "$resolved")" "$w_cur")$(ui_pad "$newest" "$w_new")$(ui_badge "$ST_TEXT" "$ST_COLOR")")
  done

  head="Checked $UPD_CHECKED $UI_SEP Docker Hub and GHCR $UI_SEP linux/amd64"
  if [ -f "$ENV_FILE" ]; then
    head="$head $UI_SEP $ENV_FILE has Catalog $(env_value CATALOG_IMAGE | sed 's/.*://')"
  fi
  ui_screen "Updates" "$head"
  printf '  %s\n' "$C_DIM$(ui_pad "#" 4)$(ui_pad "COMPONENT" 26)$(ui_pad "CURRENT" "$w_cur")$(ui_pad "NEWEST" "$w_new")STATUS$C_RST"
  printf '  %s\n' "${rows[@]}"
}

# Up to 4 versions, newest first: the 2 newest of the current major, the newest
# of the next major (upgrades go one major at a time), the newest overall, then
# the next newest ones. With "x.0" the next major means its .0 series (MongoDB
# upgrades 7.0 -> 8.0 -> later 8.x).
pick_list() {
  awk -F. -v cur="$2" -v series="${3:-}" '
    { v[NR] = $0; m[NR] = $1 }
    END {
      for (i = 1; i <= NR && c < 2; i++) if (m[i] == cur) { pick[i] = 1; c++ }
      if (cur ~ /^[0-9]+$/) for (i = 1; i <= NR; i++) {
        if (series == "x.0" && index(v[i], (cur + 1) ".0.") != 1) continue
        if (m[i] == cur + 1) { pick[i] = 1; break }
      }
      if (NR > 0) pick[1] = 1
      for (i = 1; i <= NR; i++) if (pick[i]) n++
      for (i = 1; i <= NR && n < 4; i++) if (!pick[i]) { pick[i] = 1; n++ }
      for (i = 1; i <= NR; i++) if (pick[i]) print v[i]
    }' <<< "$1"
}

pick_component() {
  local key="$1" first tag resolved versions list choice selected="" count i=0 v marker cur_major sel_major setting last_series
  component_info "$key"
  first="${C_SETTINGS%% *}"
  tag="${!first}"
  versions="${UPD_VERSIONS[$key]-}"
  if [ -z "$versions" ]; then
    err "No versions known for $C_LABEL (registry not reachable) - try r) Check again."
    return 1
  fi
  if [[ "$tag" =~ $(kind_regex "$C_KIND") ]]; then
    resolved="$tag"
  else
    resolved="${UPD_RESOLVED[$key]-}"
  fi
  cur_major="$(version_major "${resolved:-$tag}")"
  if [ "$key" = "mongo" ]; then
    list="$(pick_list "$versions" "$cur_major" x.0)"
  else
    list="$(pick_list "$versions" "$cur_major")"
  fi
  count="$(count_lines "$list")"

  while [ -z "$selected" ]; do
    echo
    ui_box "$(ui_width)" "$C_LABEL" "Current: $C_BLD$(ui_current "$tag" "$resolved")$C_RST   $C_DIM$UI_SEP images: $C_IMAGES$C_RST"
    i=0
    while IFS= read -r v; do
      i=$((i + 1))
      marker=""
      if [ "$v" = "$resolved" ]; then
        marker="  $C_GRN$UI_DOT current$C_RST"
      elif [ "$C_KIND" != "minio" ] && [[ "$cur_major" =~ ^[0-9]+$ ]] && [ "$(version_major "$v")" -gt "$cur_major" ]; then
        marker="  $C_MAG$UI_MAJOR major update$C_RST"
      fi
      if [ "$key" = "mongo" ] && [ "$(version_major "$v")" -ge 8 ] && kernel_blocks_mongo8; then
        marker="$marker  $C_RED$UI_NO may fail on this kernel$C_RST"
      fi
      printf '   %s  %s%s\n' "$C_BLD$i$C_RST" "$(ui_pad "$(version_core "$v")" 30)" "$marker"
    done <<< "$list"
    printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}cancel$C_RST"
    echo
    ui_ask choice "Select a version [0]:" || choice="0"
    choice="${choice:-0}"
    if [ "$choice" = "0" ]; then
      info "Cancelled - nothing was changed."
      return 0
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      selected="$(sed -n "${choice}p" <<< "$list")"
    elif grep -qxF -- "$choice" <<< "$versions"; then
      selected="$choice"
    else
      warn "Invalid choice: $choice"
    fi
  done

  if [ "$selected" = "$tag" ]; then
    info "$selected is already selected."
    return 0
  fi
  sel_major="$(version_major "$selected")"
  if [ -n "$resolved" ] && kind_newer "$C_KIND" "$resolved" "$selected"; then
    warn "$(version_core "$selected") is OLDER than the current $(version_core "$resolved") - downgrades can fail with existing data."
    if ! confirm "Select it anyway?" n; then
      info "Cancelled - nothing was changed."
      return 0
    fi
  elif [ "$C_KIND" != "minio" ] && [[ "$cur_major" =~ ^[0-9]+$ ]] && [ "$sel_major" -gt "$cur_major" ]; then
    case "$key" in
      opensearch) warn "OpenSearch $cur_major.x -> $sel_major.x is a major upgrade: take a snapshot first, there is no way back." ;;
      mongo)
        warn "MongoDB upgrades one release series at a time (e.g. 7.0 -> 8.0); upgraded data cannot be downgraded."
        last_series="$(grep -E "^$cur_major\." <<< "$versions" | head -n 1 | cut -d. -f1-2)" || last_series=""
        case "$(cut -d. -f1-2 <<< "$resolved")" in
          "$cur_major.0"|"$last_series"|"") ;;
          *) warn "MongoDB $sel_major.0 can only be reached from $cur_major.0 or $last_series - upgrade to $(grep -F "$last_series." <<< "$versions" | head -n 1) first." ;;
        esac
        ;;
      rabbitmq) warn "Before RabbitMQ $cur_major.x -> $sel_major.x enable all feature flags: docker compose exec rabbitmq rabbitmqctl enable_feature_flag all" ;;
      *) warn "$C_LABEL $cur_major.x -> $sel_major.x is a major upgrade - check its release notes." ;;
    esac
    if ! confirm "Select $(version_core "$selected")?" n; then
      info "Cancelled - nothing was changed."
      return 0
    fi
  fi
  if [ "$key" = "mongo" ] && [[ "$sel_major" =~ ^[0-9]+$ ]] && [ "$sel_major" -ge 8 ] && kernel_blocks_mongo8; then
    warn "MongoDB $sel_major may not start on this machine's kernel ($(uname -r), SERVER-121912)."
    warn "Only choose it for a bundle that is installed on a machine with another kernel."
    if ! confirm "Select it anyway?" n; then
      info "Cancelled - nothing was changed."
      return 0
    fi
  fi
  for setting in $C_SETTINGS; do
    set_setting "$setting" "$selected"
    printf -v "$setting" '%s' "$selected"
  done
  ok "${C_SETTINGS// / and } set to $selected."
}

pin_floating_tags() {
  local key first tag resolved setting changed="false"
  for key in "${UPD_KEYS[@]}"; do
    component_info "$key"
    first="${C_SETTINGS%% *}"
    tag="${!first}"
    resolved="${UPD_RESOLVED[$key]-}"
    if is_exact_tag "$tag"; then
      continue
    fi
    if [ -z "$resolved" ]; then
      warn "$C_LABEL: the version behind \"$tag\" is unknown - not pinned."
    elif ! grep -qxF -- "$resolved" <<< "${UPD_VERSIONS[$key]-}"; then
      warn "$C_LABEL: $resolved is not available for all images ($C_IMAGES) - not pinned."
    else
      for setting in $C_SETTINGS; do
        set_setting "$setting" "$resolved"
        printf -v "$setting" '%s' "$resolved"
      done
      ok "$C_LABEL: $tag -> $resolved"
      changed="true"
    fi
  done
  if [ "$changed" = "false" ]; then
    info "Nothing to pin."
  fi
}

apply_updates() {
  if ! confirm "Generate the files (passwords are kept) and start the stack with these versions?" y; then
    info "Cancelled."
    return 0
  fi
  do_generate keep no-next
  if [ "$GENERATE_CANCELLED" = "true" ]; then
    return 0
  fi
  echo
  do_up
}

reload_settings() {
  local name value
  if [ -z "$SCRIPT_PATH" ]; then
    return 0
  fi
  while IFS='|' read -r name value; do
    case "$name" in
      CATALOG_VERSION|OPENSEARCH_TAG|OPENSEARCH_DASHBOARDS_TAG|MONGO_TAG|RABBITMQ_TAG|MINIO_TAG|NGINX_PROXY_MANAGER_TAG|TZ|AUTOSYNC_CRON|VULNERABILITIES_CACHING_CRON)
        printf -v "$name" '%s' "$value"
        ;;
    esac
  done < <(settings_pairs "$SCRIPT_PATH")
}

do_updates() {
  local choice
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is needed to check for updates (apt-get install curl)."
    return 1
  fi
  collect_updates
  while true; do
    show_updates
    echo
    ui_keys "1-6|pick a version" "p|pin floating tags" "r|check again" "s|apply (generate + start)" "d|offline bundle" "0|back"
    ui_ask choice "Select:" || choice="0"
    case "$choice" in
      1) run_action select_version no-apply; reload_settings; ui_pause_tty ;;
      [2-6]) run_action pick_component "${UPD_KEYS[$((choice - 2))]}"; reload_settings; ui_pause_tty ;;
      p|P) run_action pin_floating_tags; reload_settings; ui_pause_tty ;;
      r|R) collect_updates ;;
      s|S) run_action apply_updates; reload_settings; ui_pause_tty ;;
      d|D) run_action download_bundle; reload_settings; ui_pause_tty ;;
      0|"") return 0 ;;
      *) warn "Unknown option: $choice"; ui_pause_tty ;;
    esac
  done
}

show_updates_cli() {
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is needed to check for updates (apt-get install curl)."
    return 1
  fi
  collect_updates
  show_updates
}

# Offline bundle

container_engine() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf 'docker'
  elif command -v podman >/dev/null 2>&1; then
    printf 'podman'
  else
    return 1
  fi
}

stack_images() {
  printf '%s\n' \
    "$CATALOG_IMAGE_REPO:$CATALOG_VERSION" \
    "$CATALOG_WORKER_IMAGE_REPO:$CATALOG_VERSION" \
    "opensearchproject/opensearch:$OPENSEARCH_TAG" \
    "opensearchproject/opensearch-dashboards:$OPENSEARCH_DASHBOARDS_TAG" \
    "mongo:$MONGO_TAG" \
    "rabbitmq:$RABBITMQ_TAG" \
    "ghcr.io/golithus/minio:$MINIO_TAG" \
    "jc21/nginx-proxy-manager:$NGINX_PROXY_MANAGER_TAG"
}

human_size() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 1
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
  }'
}

progress_bar() {
  local label="$1" cur="$2" total="$3" width=30 pct fill bar pad
  if [ "$total" -le 0 ]; then
    total=1
  fi
  pct=$((cur * 100 / total))
  if [ "$pct" -gt 100 ]; then
    pct=100
  fi
  fill=$((pct * width / 100))
  printf -v bar '%*s' "$fill" ''
  printf -v pad '%*s' "$((width - fill))" ''
  printf '\r       %-5s [%s%s] %3d%%  %s / %s    ' "$label" "${bar// /#}" "${pad// /-}" "$pct" "$(human_size "$cur")" "$(human_size "$total")"
}

# save_image ENGINE REF FILE EXPECTED_BYTES [LABEL]
save_image() {
  local engine="$1" ref="$2" out="$3" total="$4" label="${5:-Saving}" pid cur
  if [ "$engine" = "podman" ]; then
    podman save --format docker-archive -o "$out" "$ref" &
  else
    docker save -o "$out" "$ref" &
  fi
  pid=$!
  if [ -n "$JOB_DIR" ]; then
    job_watch_bytes "$pid" "$out" "$total" "$label"
  else
    trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; exit 130' INT TERM
    while kill -0 "$pid" 2>/dev/null; do
      if [ -t 1 ]; then
        cur="$(stat -c %s -- "$out" 2>/dev/null)" || cur=0
        progress_bar save "${cur:-0}" "$total"
      fi
      sleep 1
    done
    trap - INT TERM
  fi
  if ! wait "$pid"; then
    echo
    err "Saving $ref failed."
    return 1
  fi
  cur="$(stat -c %s -- "$out")"
  if [ -z "$JOB_DIR" ]; then
    progress_bar save "$cur" "$cur"
    echo
  else
    echo "  saved $(human_size "$cur")"
  fi
}

write_import_script() {
  local file="$1" installer="$2"
  cat > "$file" <<'IMPORT_EOF'
#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail
cd -- "$(dirname -- "$(readlink -f -- "$0")")"

engine="${1:-}"
if [ -z "$engine" ]; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    engine="docker"
  elif command -v podman >/dev/null 2>&1; then
    engine="podman"
  else
    echo "ERROR Neither docker nor podman is available on this machine." >&2
    exit 1
  fi
fi
echo "==> Container engine: $engine"

if command -v sha256sum >/dev/null 2>&1; then
  echo "==> Verifying the image files (SHA256SUMS)"
  if ! awk '$2 ~ /^[*]?images(\/|\.txt$)/' SHA256SUMS | sha256sum -c --quiet -; then
    echo "ERROR Checksum mismatch - copy the bundle again." >&2
    exit 1
  fi
fi

loaded=0
failed=0
while IFS='|' read -r ref file id; do
  if [ -z "$ref" ]; then
    continue
  fi
  if [ ! -f "$file" ]; then
    echo "ERROR $file is missing - $ref not loaded" >&2
    failed=$((failed + 1))
    continue
  fi
  echo "==> $ref"
  if ! "$engine" load -i "$file" >/dev/null; then
    echo "ERROR Loading $file failed" >&2
    failed=$((failed + 1))
    continue
  fi
  if ! "$engine" image inspect "$ref" >/dev/null 2>&1; then
    "$engine" tag "$id" "$ref" >/dev/null 2>&1 || true
  fi
  if "$engine" image inspect "$ref" >/dev/null 2>&1; then
    echo " OK $ref"
    loaded=$((loaded + 1))
  else
    echo "ERROR $ref could not be tagged" >&2
    failed=$((failed + 1))
  fi
done < images.txt

echo
echo "$loaded image(s) loaded, $failed failed."
if [ "$failed" -gt 0 ]; then
  exit 1
fi
echo "Next: ./@INSTALLER@  (menu option 7: generate + validate + start)"
IMPORT_EOF
  sed -i "s/@INSTALLER@/$installer/" "$file"
  chmod +x "$file"
}

# make_archive DIR -> DIR.tar.gz next to DIR, with a progress bar
make_archive() {
  local dir="$1" base name archive total free_kb pid rchar compressor="gzip -1"
  base="$(dirname -- "$dir")"
  name="$(basename -- "$dir")"
  archive="$base/$name.tar.gz"
  total="$(du -sb -- "$dir" | cut -f1)"
  free_kb="$(df -Pk -- "$base" | awk 'NR == 2 { print $4 }')" || free_kb=0
  if [ "$total" -gt $((free_kb * 1024)) ]; then
    warn "Only $(human_size "$((free_kb * 1024))") free in $base; the archive can need up to $(human_size "$total")."
    if [ -n "$JOB_DIR" ]; then
      warn "No archive created - the bundle folder is complete and can be copied as it is."
      return 0
    fi
    if ! confirm "Create the archive anyway?" n; then
      return 0
    fi
  fi
  if command -v pigz >/dev/null 2>&1; then
    compressor="pigz -1"
  fi
  info "Creating $archive"
  BUNDLE_ARCHIVE="$archive"
  tar -C "$base" -cf - -- "$name" | $compressor > "$archive" &
  pid=$!
  if [ -n "$JOB_DIR" ]; then
    job_watch_bytes "$pid" "rchar:$pid" "$total" "Packing"
  else
    trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f -- "$archive"; exit 130' INT TERM
    while kill -0 "$pid" 2>/dev/null; do
      if [ -t 1 ] && [ -r "/proc/$pid/io" ]; then
        rchar="$(awk '/^rchar:/ { print $2 }' "/proc/$pid/io" 2>/dev/null)" || rchar=0
        progress_bar pack "${rchar:-0}" "$total"
      fi
      sleep 1
    done
    trap - INT TERM
  fi
  if ! wait "$pid"; then
    echo
    rm -f -- "$archive"
    BUNDLE_ARCHIVE=""
    err "Creating $archive failed."
    return 1
  fi
  if [ -z "$JOB_DIR" ]; then
    progress_bar pack "$total" "$total"
    echo
  fi
  job_step "Writing the archive checksum"
  (cd -- "$base" && sha256sum -- "$name.tar.gz" > "$name.tar.gz.sha256")
  BUNDLE_ARCHIVE=""
  ok "Archive: $archive ($(human_size "$(stat -c %s -- "$archive")")), checksum in $name.tar.gz.sha256"
}

SCP_HOST=""
SCP_SCPHOST=""
SCP_PORT=""
SCP_USER=""
SCP_TARGET=""
SCP_RT=""
SCP_AUTH=""
SCP_KEYFILE=""
SCP_CTL=""
SCP_USE_SSHPASS="false"
SCP_PW=""
SCP_OPTS=()
SCP_PASS=()

scp_build_opts() {
  SCP_OPTS=(-o "Port=$SCP_PORT" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$HOME/.ssh/known_hosts")
  if [ "$SCP_AUTH" = "key" ]; then
    if [ -n "$SCP_KEYFILE" ]; then
      SCP_OPTS+=(-i "$SCP_KEYFILE")
    fi
  else
    SCP_OPTS+=(-o PubkeyAuthentication=no)
  fi
  if [ -n "$SCP_CTL" ]; then
    SCP_OPTS+=(-o ControlMaster=auto -o "ControlPath=$SCP_CTL/%C" -o ControlPersist=12h)
  fi
  SCP_PASS=()
  if [ "$SCP_USE_SSHPASS" = "true" ]; then
    SCP_PASS=(sshpass -e)
  fi
}

# Asks for the scp target, confirms a new host key and opens the connection (the password is
# asked here, so the copy can run later in the background). Returns 0 ready, 1 error, 2 cancelled.
scp_prepare() {
  local host scp_host port user target rt auth key pw kh kf known="$HOME/.ssh/known_hosts"
  echo
  read -r -p "  Host (IP or DNS)  : " host || host=""
  if [ -z "$host" ]; then
    info "Cancelled."
    return 2
  fi
  host="${host#[}"
  host="${host%]}"
  scp_host="$host"
  if [[ "$host" == *:* ]]; then
    scp_host="[$host]"
  fi
  read -r -p "  Port [22]         : " port || port=""
  port="${port:-22}"
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    err "Invalid port: $port"
    return 1
  fi
  read -r -p "  Username [${USER:-root}]  : " user || user=""
  user="${user:-${USER:-root}}"
  if [[ "$host" == -* ]] || [[ "$user" == -* ]]; then
    err "Host and username must not start with '-'."
    return 1
  fi
  read -r -p "  Target folder [~] : " target || target=""
  target="${target:-~}"
  if [[ "$target" =~ [[:space:]\'\"\\\$\`] ]]; then
    err "Use a target folder without spaces or quotes."
    return 1
  fi
  case "$target" in
    "~") rt="." ;;
    "~/"*) rt="${target#\~/}" ;;
    *) rt="$target" ;;
  esac
  echo "  Authentication    : 1) SSH key  2) Password"
  read -r -p "  Choice [2]        : " auth || auth=""
  kh="$host"
  if [ "$port" != "22" ]; then
    kh="[$host]:$port"
  fi
  if ! ssh-keygen -F "$kh" -f "$known" >/dev/null 2>&1; then
    kf="$(mktemp)"
    ssh-keyscan -p "$port" -- "$host" > "$kf" 2>/dev/null || true
    if [ ! -s "$kf" ]; then
      rm -f -- "$kf"
      err "Could not read the SSH host key of $host:$port."
      return 1
    fi
    echo "  New host - SSH key fingerprint(s) of $host:"
    ssh-keygen -lf "$kf" | sed 's/^/    /'
    if ! confirm "  Do they match the target (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub there)?" n; then
      rm -f -- "$kf"
      info "Cancelled."
      return 2
    fi
    mkdir -p -- "$HOME/.ssh"
    chmod 700 -- "$HOME/.ssh"
    cat -- "$kf" >> "$known"
    rm -f -- "$kf"
  fi
  SCP_HOST="$host"
  SCP_SCPHOST="$scp_host"
  SCP_PORT="$port"
  SCP_USER="$user"
  SCP_TARGET="$target"
  SCP_RT="$rt"
  SCP_KEYFILE=""
  SCP_CTL=""
  SCP_USE_SSHPASS="false"
  SCP_PW=""
  if [ "${auth:-2}" = "1" ]; then
    SCP_AUTH="key"
    read -r -p "  Key file [default]: " key || key=""
    case "$key" in
      "~/"*) key="$HOME/${key#\~/}" ;;
    esac
    if [ -n "$key" ]; then
      SCP_KEYFILE="$(cd -- "$(dirname -- "$key")" 2>/dev/null && pwd -P)/$(basename -- "$key")" || SCP_KEYFILE="$key"
    fi
  else
    SCP_AUTH="password"
    if command -v sshpass >/dev/null 2>&1; then
      read -r -s -p "  Password          : " pw || pw=""
      echo
      SCP_PW="$pw"
      pw=""
      SCP_USE_SSHPASS="true"
    else
      info "sshpass is not installed - ssh asks for the password itself (once)."
    fi
  fi
  if [ "$SCP_USE_SSHPASS" != "true" ]; then
    SCP_CTL="$(mktemp -d)"
  fi
  scp_build_opts
  if [ "$SCP_USE_SSHPASS" = "true" ]; then
    export SSHPASS="$SCP_PW"
  fi
  info "Connecting to $user@$host:$port"
  if ! ${SCP_PASS[@]+"${SCP_PASS[@]}"} ssh "${SCP_OPTS[@]}" "$user@$host" "mkdir -p -- '$rt'"; then
    unset SSHPASS
    err "Could not connect to $host or create $target there."
    scp_close
    return 1
  fi
  unset SSHPASS
}

scp_close() {
  if [ -n "$SCP_CTL" ]; then
    ssh "${SCP_OPTS[@]}" -O exit "$SCP_USER@$SCP_HOST" >/dev/null 2>&1 || true
    rm -rf -- "$SCP_CTL"
    SCP_CTL=""
  fi
}

# scp_copy PATH... -> copies the paths to the prepared target and verifies the checksums there
scp_copy() {
  local f rc=0 verify name size pid
  local -a recursive=()
  scp_build_opts
  for f in "$@"; do
    recursive=()
    if [ -d "$f" ]; then
      recursive=(-r)
    fi
    info "Copying $(basename -- "$f")"
    if [ -n "$JOB_DIR" ]; then
      size="$(du -sb -- "$f" | cut -f1)"
      ${SCP_PASS[@]+"${SCP_PASS[@]}"} scp "${SCP_OPTS[@]}" ${recursive[@]+"${recursive[@]}"} -- "$f" "$SCP_USER@$SCP_SCPHOST:$SCP_RT/" &
      pid=$!
      job_watch_bytes "$pid" "proc:$pid:scp" "$size" "Copying $(basename -- "$f") to $SCP_HOST"
      wait "$pid" || rc=1
    else
      ${SCP_PASS[@]+"${SCP_PASS[@]}"} scp "${SCP_OPTS[@]}" ${recursive[@]+"${recursive[@]}"} -- "$f" "$SCP_USER@$SCP_SCPHOST:$SCP_RT/" || rc=1
    fi
    if [ "$rc" -ne 0 ]; then
      err "Copying $f failed."
      break
    fi
  done
  if [ "$rc" -eq 0 ]; then
    name="$(basename -- "$1")"
    if [ -d "$1" ]; then
      verify="cd -- '$SCP_RT/$name' && sha256sum -c --quiet SHA256SUMS"
    else
      verify="cd -- '$SCP_RT' && sha256sum -c --quiet -- '$name.sha256'"
    fi
    job_step "Verifying the copy on $SCP_HOST"
    info "Verifying the copy on $SCP_HOST"
    if ${SCP_PASS[@]+"${SCP_PASS[@]}"} ssh "${SCP_OPTS[@]}" "$SCP_USER@$SCP_HOST" "$verify"; then
      ok "Copied to $SCP_USER@$SCP_HOST:$SCP_TARGET - checksums match."
      if [ -d "$1" ]; then
        echo "  On $SCP_HOST: cd $SCP_TARGET/$name && ./import-images.sh"
      else
        echo "  On $SCP_HOST: cd $SCP_TARGET && tar -xzf $name && cd ${name%.tar.gz} && ./import-images.sh"
      fi
    else
      err "Checksum verification on $SCP_HOST failed - copy again."
      rc=1
    fi
  fi
  scp_close
  return "$rc"
}

# docker.io/library/mongo:7.0 for mongo:7.0 and so on (podman does not guess registries).
qualify_ref() {
  local first="${1%%/*}"
  if [[ "$1" == */* ]] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = "localhost" ]; }; then
    printf '%s' "$1"
  elif [[ "$1" == */* ]]; then
    printf 'docker.io/%s' "$1"
  else
    printf 'docker.io/library/%s' "$1"
  fi
}

# download_bundle [interactive|all]
download_bundle() {
  local mode="${1:-interactive}" engine ref choice tok base name dir count=0 i floating=0 archive_wanted="no" scp_wanted="no" scp_rc
  local -a images=() picked=() toks=() refs=()
  if ! engine="$(container_engine)"; then
    err "Downloading needs docker or podman on this machine."
    return 1
  fi
  while IFS= read -r ref; do
    images+=("$ref")
  done < <(stack_images)
  for ref in "${images[@]}"; do
    if ! is_exact_tag "${ref##*:}"; then
      floating=$((floating + 1))
    fi
  done
  if [ "$floating" -gt 0 ]; then
    warn "$floating image(s) use a floating tag (latest, 2, ...): the bundle gets what the tag points to today."
    if [ "$mode" = "interactive" ] && [ "${#UPD_RESOLVED[@]}" -gt 0 ] && confirm "Pin them to exact versions first?" y; then
      pin_floating_tags
      images=()
      while IFS= read -r ref; do
        images+=("$ref")
      done < <(stack_images)
    fi
  fi
  for i in "${!images[@]}"; do
    picked[i]=1
  done
  if [ "$INSTALL_NGINX_PROXY_MANAGER" != "true" ]; then
    picked[7]=0
  fi

  if [ "$mode" = "interactive" ]; then
    while true; do
      echo
      ui_box "$(ui_width)" "Download only $UI_SEP offline bundle" "Engine $engine $UI_SEP platform linux/amd64 $UI_SEP the images are saved with their checksums and an import script"
      for i in "${!images[@]}"; do
        if [ "${picked[i]}" = "1" ]; then
          printf '   %s %s  %s\n' "$C_GRN$UI_ON$C_RST" "$C_BLD$((i + 1))$C_RST" "${images[i]}"
        else
          printf '   %s %s  %s\n' "$C_DIM$UI_OFF$C_RST" "$C_BLD$((i + 1))$C_RST" "$C_DIM${images[i]}$C_RST"
        fi
      done
      echo
      ui_keys "1-${#images[@]}|toggle (e.g. 1 3)" "a|all" "n|none" "Enter|start" "0|cancel"
      ui_ask choice "Toggle, or Enter to start:" || choice="0"
      case "$choice" in
        "") break ;;
        0) info "Cancelled."; return 0 ;;
        a|A) for i in "${!images[@]}"; do picked[i]=1; done ;;
        n|N) for i in "${!images[@]}"; do picked[i]=0; done ;;
        *)
          read -r -a toks <<< "$choice"
          for tok in "${toks[@]}"; do
            if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#images[@]}" ]; then
              picked[tok - 1]=$((1 - picked[tok - 1]))
            else
              warn "Unknown entry: $tok"
            fi
          done
          ;;
      esac
    done
    read -r -p " Create the bundle folder in [$WORK_DIR]: " base || base=""
  fi
  for i in "${!images[@]}"; do
    if [ "${picked[i]}" = "1" ]; then
      refs+=("${images[i]}")
      count=$((count + 1))
    fi
  done
  if [ "$count" -eq 0 ]; then
    warn "Nothing selected."
    return 0
  fi

  base="${base:-$WORK_DIR}"
  case "$base" in
    "~") base="$HOME" ;;
    "~/"*) base="$HOME/${base#\~/}" ;;
  esac
  mkdir -p -- "$base"
  base="$(cd -- "$base" && pwd -P)"
  name="RN1-Technology-Catalog-$(date +%Y%m%d-%H%M%S)"
  dir="$base/$name"

  if [ "$mode" = "all" ]; then
    archive_wanted="yes"
  elif confirm "Create $name.tar.gz when the bundle is ready?" y; then
    archive_wanted="yes"
  fi
  if [ "$mode" = "interactive" ] && confirm "Copy the bundle to another machine with scp?" n; then
    scp_rc=0
    scp_prepare || scp_rc=$?
    if [ "$scp_rc" -eq 0 ]; then
      scp_wanted="yes"
    else
      info "The bundle is created without copying it."
    fi
  fi
  if [ "$mode" = "interactive" ] && [ -n "$SCRIPT_PATH" ]; then
    run_job "Offline bundle ($count image(s))" "$SCP_PW" -- bundle_build "$engine" "$dir" "$archive_wanted" "$scp_wanted" \
      "$SCP_HOST" "$SCP_SCPHOST" "$SCP_PORT" "$SCP_USER" "$SCP_TARGET" "$SCP_RT" "$SCP_AUTH" "$SCP_KEYFILE" "$SCP_CTL" "$SCP_USE_SSHPASS" \
      "${refs[@]}"
  else
    SCP_SECRET="$SCP_PW" bundle_build "$engine" "$dir" "$archive_wanted" "$scp_wanted" \
      "$SCP_HOST" "$SCP_SCPHOST" "$SCP_PORT" "$SCP_USER" "$SCP_TARGET" "$SCP_RT" "$SCP_AUTH" "$SCP_KEYFILE" "$SCP_CTL" "$SCP_USE_SSHPASS" \
      "${refs[@]}"
  fi
}

BUNDLE_PARTIAL=""
BUNDLE_ARCHIVE=""

bundle_cleanup() {
  if [ -n "$BUNDLE_ARCHIVE" ]; then
    rm -f -- "$BUNDLE_ARCHIVE"
    echo "Incomplete archive removed: $BUNDLE_ARCHIVE"
    BUNDLE_ARCHIVE=""
  fi
  if [ -n "$BUNDLE_PARTIAL" ]; then
    rm -rf -- "$BUNDLE_PARTIAL"
    echo
    warn "Incomplete bundle removed: $BUNDLE_PARTIAL"
    BUNDLE_PARTIAL=""
  fi
  scp_close
}

# Worker: bundle_build ENGINE DIR ARCHIVE SCP HOST SCPHOST PORT USER TARGET RT AUTH KEYFILE CTL SSHPASS REF...
bundle_build() {
  local engine="$1" dir="$2" archive_wanted="$3" scp_wanted="$4" base name ref pref id size free_kb file n=0 count installer archive="" secret
  SCP_HOST="$5"
  SCP_SCPHOST="$6"
  SCP_PORT="$7"
  SCP_USER="$8"
  SCP_TARGET="$9"
  SCP_RT="${10}"
  SCP_AUTH="${11}"
  SCP_KEYFILE="${12}"
  SCP_CTL="${13}"
  SCP_USE_SSHPASS="${14}"
  shift 14
  count=$#
  secret="$(job_secret_take)"
  secret="${secret:-${SCP_SECRET:-}}"
  if [ -n "$secret" ]; then
    export SSHPASS="$secret"
  fi
  scp_build_opts
  base="$(dirname -- "$dir")"
  name="$(basename -- "$dir")"
  mkdir -p -- "$dir/images"
  BUNDLE_PARTIAL="$dir"
  if [ -n "$JOB_DIR" ]; then
    JOB_CLEANUP="bundle_cleanup"
  else
    trap 'bundle_cleanup' EXIT
  fi
  : > "$dir/images.txt"
  free_kb="$(df -Pk -- "$base" | awk 'NR == 2 { print $4 }')" || free_kb=0
  info "Bundle folder: $dir (free space: $(human_size "$((free_kb * 1024))"))"

  for ref in "$@"; do
    n=$((n + 1))
    echo
    info "[$n/$count] $ref"
    pref="$(qualify_ref "$ref")"
    job_step "[$n/$count] Pulling $ref"
    if [ -n "$JOB_DIR" ]; then
      "$engine" pull -q --platform linux/amd64 "$pref"
    else
      "$engine" pull --platform linux/amd64 "$pref"
    fi
    id="$("$engine" image inspect --format '{{.Id}}' "$pref")"
    id="${id#sha256:}"
    size="$("$engine" image inspect --format '{{.Size}}' "$pref")"
    free_kb="$(df -Pk -- "$dir" | awk 'NR == 2 { print $4 }')" || free_kb=0
    if [ "$size" -gt $((free_kb * 1024)) ]; then
      err "Not enough free space in $base for $ref ($(human_size "$size") needed)."
      return 1
    fi
    file="images/$(printf '%s' "$ref" | tr '/:' '__').tar"
    save_image "$engine" "$pref" "$dir/$file" "$size" "[$n/$count] Saving $ref"
    printf '%s|%s|%s\n' "$ref" "$file" "$id" >> "$dir/images.txt"
  done

  installer=""
  if [ -n "$SCRIPT_PATH" ]; then
    installer="$(basename -- "$SCRIPT_PATH")"
    cp -- "$SCRIPT_PATH" "$dir/$installer"
    chmod u+w "$dir/$installer"
    set_setting CHECK_FOR_UPDATES false "$dir/$installer"
    chmod +x "$dir/$installer"
  fi
  write_import_script "$dir/import-images.sh" "${installer:-rn1-technology-catalog-installer.sh}"
  job_step "Writing SHA256SUMS"
  (cd -- "$dir" && sha256sum -- images/*.tar images.txt import-images.sh ${installer:+"$installer"} > SHA256SUMS)
  BUNDLE_PARTIAL=""
  if [ -z "$JOB_DIR" ]; then
    trap - EXIT
  fi
  echo
  ok "Bundle ready: $dir ($(du -sh -- "$dir" | cut -f1))"
  echo "  images/ ($count image(s)), images.txt, SHA256SUMS, import-images.sh${installer:+, $installer}"
  echo "  No $ENV_FILE / $COMPOSE_FILE inside - the target machine generates its own (with new passwords)."

  if [ "$archive_wanted" = "yes" ]; then
    make_archive "$dir"
    if [ -f "$base/$name.tar.gz" ]; then
      archive="$base/$name.tar.gz"
    fi
  fi
  if [ "$scp_wanted" = "yes" ]; then
    if [ -n "$archive" ]; then
      scp_copy "$archive" "$archive.sha256"
    else
      scp_copy "$dir"
    fi
  fi
}

###############################################################################
# Catalog snapshot from the online catalog, API key
###############################################################################

KEY_STATE=""
KEY_DETAIL=""
NEW_KEY=""
MANIFEST_FILE=""

api_key_stored() {
  if [ -s "$API_KEY_FILE" ]; then
    tr -d ' \r\n\t' < "$API_KEY_FILE"
  fi
}

api_key_mask() {
  local key="$1"
  if [ "${#key}" -le 12 ]; then
    printf '%s... (%d characters)' "${key:0:2}" "${#key}"
  else
    printf '%s...%s' "${key:0:7}" "${key: -4}"
  fi
}

# Removes blanks; upper-cases a key that has the Raynet format in lower case.
api_key_normalize() {
  local key
  key="$(printf '%s' "$1" | tr -d ' \r\n\t')"
  if [[ "$key" =~ ^[0-9A-Fa-f]{7}(-[0-9A-Fa-f]{7}){3}$ ]]; then
    key="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
  fi
  printf '%s' "$key"
}

api_key_save() {
  (umask 077 && printf '%s\n' "$1" > "$API_KEY_FILE")
  chmod 600 "$API_KEY_FILE"
}

# cloud_get KEY PATH OUTFILE [json|download] -> prints the HTTP status ("000" when unreachable).
# The key goes to curl through its stdin config, so it never shows up in the process list.
cloud_get() {
  local key="$1" path="$2" out="$3" mode="${4:-json}"
  local -a opts=()
  if [ "$mode" = "download" ]; then
    if [ -t 2 ]; then
      opts=(--progress-bar -H 'Accept: */*')
    else
      opts=(-sS -H 'Accept: */*')
    fi
  else
    opts=(-sS --max-time 60 -H 'Accept: application/json')
  fi
  printf 'header = "X-Api-Key: %s"\n' "$key" \
    | curl "${opts[@]}" -K - --proto '=https' --connect-timeout 10 --retry 2 --retry-delay 3 \
        -o "$out" -w '%{http_code}' "${CATALOG_CLOUD_URL%/}$path" || true
}

# api_key_check KEY -> KEY_STATE (valid / invalid / forbidden / error), KEY_DETAIL,
# and the snapshot manifest in MANIFEST_FILE (empty when there is none yet).
api_key_check() {
  local key="$1" code
  KEY_STATE="error"
  KEY_DETAIL=""
  if [[ "$CATALOG_CLOUD_URL" != https://* ]]; then
    KEY_DETAIL="CATALOG_CLOUD_URL must start with https://"
    return 0
  fi
  if [ -n "$MANIFEST_FILE" ]; then
    rm -f -- "$MANIFEST_FILE"
  fi
  MANIFEST_FILE="$(mktemp)"
  code="$(cloud_get "$key" /v3/synchronization/manifest "$MANIFEST_FILE")"
  case "$code" in
    200) KEY_STATE="valid" ;;
    404)
      if [ "$(curl -sS -o /dev/null -w '%{http_code}' --proto '=https' --connect-timeout 10 --max-time 30         "${CATALOG_CLOUD_URL%/}/v3/synchronization/manifest" || true)" = "401" ]; then
        KEY_STATE="valid"
        : > "$MANIFEST_FILE"
      else
        KEY_DETAIL="$CATALOG_CLOUD_URL offers no snapshot API (/v3/synchronization) - the Catalog there is older than 26.3"
      fi
      ;;
    401)
      KEY_STATE="invalid"
      KEY_DETAIL="$(sed -n 's/.*"detail" *: *"\([^"]*\)".*/\1/p' "$MANIFEST_FILE" | head -n 1)" || KEY_DETAIL=""
      ;;
    403) KEY_STATE="forbidden" ;;
    000) KEY_DETAIL="$CATALOG_CLOUD_URL is not reachable (network, DNS or proxy)" ;;
    *) KEY_DETAIL="unexpected answer HTTP $code" ;;
  esac
}

report_key_state() {
  case "$KEY_STATE" in
    valid) ok "The API key is valid." ;;
    invalid) err "The API key is not valid${KEY_DETAIL:+: $KEY_DETAIL}" ;;
    forbidden) err "The API key is valid but has no synchronization permission - ask Raynet for a key with the Synchronizer role." ;;
    *) err "The API key could not be checked: $KEY_DETAIL" ;;
  esac
}

# Asks for a key and tests it at once. On success the key is in NEW_KEY.
prompt_api_key() {
  local key tries=0
  NEW_KEY=""
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    read -r -s -p "  API key (input hidden, Enter = cancel): " key || key=""
    echo
    key="$(api_key_normalize "$key")"
    if [ -z "$key" ]; then
      info "Cancelled."
      return 1
    fi
    if [[ "$key" == *[\"\\]* ]]; then
      err "The key contains invalid characters."
      continue
    fi
    if ! [[ "$key" =~ ^[0-9A-F]{7}(-[0-9A-F]{7}){3}$ ]]; then
      warn "This does not look like a Raynet API key (XXXXXXX-XXXXXXX-XXXXXXX-XXXXXXX) - testing it anyway."
    fi
    info "Testing the key against $CATALOG_CLOUD_URL"
    api_key_check "$key"
    report_key_state
    case "$KEY_STATE" in
      valid)
        NEW_KEY="$key"
        return 0
        ;;
      error)
        if ! confirm "Try again?" y; then
          return 1
        fi
        ;;
    esac
  done
  return 1
}

api_key_menu() {
  local choice key lkey f
  while true; do
    key="$(api_key_stored)"
    lkey=""
    if [ -s "$LOCAL_KEY_FILE" ]; then
      lkey="$(tr -d ' \r\n\t' < "$LOCAL_KEY_FILE")"
    fi
    echo
    ui_box "$(ui_width)" "API keys" \
      "$(if [ -n "$key" ]; then printf '%s' "$C_GRN$UI_OK$C_RST"; else printf '%s' "$C_DIM$UI_NO$C_RST"; fi) Online catalog ($CATALOG_CLOUD_URL): $(if [ -n "$key" ]; then api_key_mask "$key"; else printf 'none'; fi)" \
      "$(if [ -n "$lkey" ]; then printf '%s' "$C_GRN$UI_OK$C_RST"; else printf '%s' "$C_DIM$UI_NO$C_RST"; fi) Local catalog  ($(local_url)): $(if [ -n "$lkey" ]; then api_key_mask "$lkey"; else printf 'none'; fi)" \
      "${C_DIM}Keys are stored readable only by $(id -un) and tested before they are saved.$C_RST"
    printf '  %s%s\n' "$C_CYN$(ui_pad "ONLINE CATALOG" 36)$C_RST" "${C_CYN}LOCAL CATALOG$C_RST"
    printf '   %s  %s%s  %s\n' "${C_BLD}1$C_RST" "$(ui_pad "Show the key" 33)" "${C_BLD}5$C_RST" "Show the key"
    printf '   %s  %s%s  %s\n' "${C_BLD}2$C_RST" "$(ui_pad "Add / change the key" 33)" "${C_BLD}6$C_RST" "Add / change the key"
    printf '   %s  %s%s  %s\n' "${C_BLD}3$C_RST" "$(ui_pad "Test the key" 33)" "${C_BLD}7$C_RST" "Test the key"
    printf '   %s  %s%s  %s\n' "${C_BLD}4$C_RST" "$(ui_pad "${C_RED}Delete the key$C_RST" 33)" "${C_BLD}8$C_RST" "${C_RED}Delete the key$C_RST"
    echo
    ui_keys "1-8|choose" "0|back"
    ui_ask choice "Select:" || choice="0"
    case "$choice" in
      1|5)
        if [ "$choice" = "5" ]; then key="$lkey"; fi
        if [ -z "$key" ]; then
          warn "No key stored."
        elif confirm "Show the full key on the screen?" n; then
          echo "   $key"
        fi
        ;;
      2)
        if prompt_api_key; then
          if confirm "Save the key in $API_KEY_FILE (readable only by $(id -un))?" y; then
            api_key_save "$NEW_KEY"
            ok "API key saved."
          fi
        fi
        ;;
      3)
        if [ -z "$key" ]; then
          warn "No online key stored."
        else
          info "Testing $(api_key_mask "$key") against $CATALOG_CLOUD_URL"
          api_key_check "$key"
          report_key_state
        fi
        ;;
      6)
        if [ -s "$LOCAL_KEY_FILE" ] && ! confirm "Replace the stored local key?" y; then
          continue
        fi
        rm -f -- "$LOCAL_KEY_FILE"
        local_auth_obtain || true
        ;;
      7)
        if [ -z "$lkey" ]; then
          warn "No local key stored."
        else
          LOCAL_AUTH="X-Api-Key: $lkey"
          info "Testing $(api_key_mask "$lkey") against $(local_url)"
          local_auth_check
          report_local_state
        fi
        ;;
      4|8)
        if [ "$choice" = "4" ]; then key="$key"; f="$API_KEY_FILE"; else key="$lkey"; f="$LOCAL_KEY_FILE"; fi
        if [ -z "$key" ]; then
          warn "No key stored."
        elif confirm "Delete the stored key?" n; then
          rm -f -- "$f"
          ok "Key deleted."
        fi
        ;;
      0|"")
        if [ -n "$MANIFEST_FILE" ]; then
          rm -f -- "$MANIFEST_FILE"
        fi
        return 0
        ;;
      *) warn "Unknown option: $choice" ;;
    esac
  done
}

# Manifest -> one line per snapshot (tab separated): kind, date (up to), size, checksum, path, from.
# kind is full, daily, cumulative-7d or cumulative-30d; "from" is the date the archive builds on
# (basedOnDate of a daily, rangeStart of a cumulative, empty for the full snapshot).
manifest_rows() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '([.latestFullSnapshot | select(.) | ["full", .date, (.sizeBytes | tostring), (.checksum // ""), .downloadPath, ""]]
      + [.dailyDeltas[]? | ["daily", .date, (.sizeBytes | tostring), (.checksum // ""), .downloadPath, (.basedOnDate // "")]]
      + [.cumulativeDeltas[]? | ["cumulative-" + (.window // "x"), (.rangeEnd // .date), (.sizeBytes | tostring), (.checksum // ""), .downloadPath, (.rangeStart // "")]])[] | @tsv'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
m = json.load(sys.stdin)
rows = []
f = m.get("latestFullSnapshot")
if f:
    rows.append(["full", f.get("date", ""), str(f.get("sizeBytes", 0)), f.get("checksum") or "", f.get("downloadPath", ""), ""])
for d in m.get("dailyDeltas") or []:
    rows.append(["daily", d.get("date", ""), str(d.get("sizeBytes", 0)), d.get("checksum") or "", d.get("downloadPath", ""), d.get("basedOnDate") or ""])
for c in m.get("cumulativeDeltas") or []:
    rows.append(["cumulative-" + (c.get("window") or "x"), c.get("rangeEnd") or c.get("date") or "", str(c.get("sizeBytes", 0)), c.get("checksum") or "", c.get("downloadPath", ""), c.get("rangeStart") or ""])
for r in rows:
    print("\t".join(r))
' | tr -d '\r'
  else
    err "Reading the snapshot list needs jq or python3 (apt-get install jq)."
    return 1
  fi
}

# snapshot_chain DATE < rows -> the deltas that bring a catalog with the data of DATE up to the newest
# date, in the order to apply them, and a last line "#END<TAB>reached<TAB>newest". A delta applies
# when it builds on a date not after the current one and reaches further; the one that reaches
# furthest wins (the smaller file on a tie), so the chain needs the fewest downloads.
snapshot_chain() {
  awk -F'\t' -v L="$1" '
    $1 != "full" && $1 != "" {
      n++; to[n] = $2; sz[n] = $3 + 0; fr[n] = $6; line[n] = $0
      if ($2 > newest) newest = $2
    }
    END {
      while (1) {
        best = 0
        for (i = 1; i <= n; i++) {
          if (used[i] || fr[i] > L || to[i] <= L) continue
          if (!best || to[i] > to[best] || (to[i] == to[best] && sz[i] < sz[best])) best = i
        }
        if (!best) break
        used[best] = 1
        print line[best]
        L = to[best]
      }
      printf "#END\t%s\t%s\n", L, newest
    }'
}

# "full 2026-10-04" / "daily 2026-10-05" / "weekly 2026-10-04" for a manifest row
snapshot_name() {
  local kind date
  IFS=$'\t' read -r kind date _ <<< "$1"
  case "$kind" in
    cumulative-7d) printf 'weekly %s' "$date" ;;
    cumulative-30d) printf 'monthly %s' "$date" ;;
    *) printf '%s %s' "$kind" "$date" ;;
  esac
}

# download_snapshot [daily|full|chain|since:YYYY-MM-DD] [interactive|cli]
download_snapshot() {
  local kind="${1:-}" mode="${2:-interactive}" key rows daily full row choice since="" chain plan planfile reached newest fdate
  local type date size checksum path based dir dest free_kb rc total count title chainfile
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is needed (apt-get install curl)."
    return 1
  fi
  key="$(api_key_stored)"
  if [ -n "$key" ]; then
    info "Testing the stored API key $(api_key_mask "$key")"
    api_key_check "$key"
    report_key_state
    if [ "$KEY_STATE" = "error" ]; then
      return 1
    fi
    if [ "$KEY_STATE" != "valid" ]; then
      if [ "$mode" != "interactive" ]; then
        return 1
      fi
      warn "Enter a new key (menu option 18 manages the stored key)."
      key=""
    fi
  fi
  if [ -z "$key" ]; then
    if [ "$mode" != "interactive" ]; then
      err "No API key stored - add one with menu option 18."
      return 1
    fi
    echo "  The snapshot download needs your API key for $CATALOG_CLOUD_URL."
    if ! prompt_api_key; then
      return 0
    fi
    key="$NEW_KEY"
    if confirm "Save the key for the next time (in $API_KEY_FILE, readable only by $(id -un))?" y; then
      api_key_save "$key"
      ok "API key saved."
    fi
  fi

  if [ ! -s "$MANIFEST_FILE" ]; then
    rm -f -- "$MANIFEST_FILE"
    warn "$CATALOG_CLOUD_URL has no snapshot yet."
    return 0
  fi
  rows="$(manifest_rows < "$MANIFEST_FILE")" || return 1
  rm -f -- "$MANIFEST_FILE"
  daily="$(grep $'^daily\t' <<< "$rows" | sort -t $'\t' -k2,2r | head -n 1)" || daily=""
  full="$(grep $'^full\t' <<< "$rows" | head -n 1)" || full=""

  if [ "$mode" = "interactive" ]; then
    snapshot_choose "$rows" "$full" "$daily" || return 0
    kind="$SNAP_KIND"
    since="$SNAP_SINCE"
  else
    case "${kind:-daily}" in
      since:*) since="${kind#since:}"; kind="since" ;;
    esac
  fi

  plan=""
  case "${kind:-daily}" in
    daily) plan="$daily" ;;
    full) plan="$full" ;;
    chain)
      if [ -z "$full" ]; then
        err "The manifest has no full snapshot."
        return 1
      fi
      IFS=$'\t' read -r _ fdate _ <<< "$full"
      chain="$(snapshot_chain "$fdate" <<< "$rows")"
      plan="$full"$'\n'"$(grep -v '^#END' <<< "$chain" || true)"
      ;;
    since)
      if ! [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        err "Give the date as YYYY-MM-DD (is \"$since\")."
        return 2
      fi
      chain="$(snapshot_chain "$since" <<< "$rows")"
      plan="$(grep -v '^#END' <<< "$chain" || true)"
      IFS=$'\t' read -r _ reached newest <<< "$(grep '^#END' <<< "$chain")"
      if [ -z "$plan" ] && [ "$reached" \< "$newest" ]; then
        err "No snapshot builds on $since - the deltas only reach back to the dates in the manifest."
        echo "  Use 'Full + all changes up to today' instead."
        return 1
      fi
      if [ -z "$plan" ]; then
        ok "A catalog with the data of $since is up to date ($newest is the newest snapshot)."
        return 0
      fi
      ;;
    *) err "Unknown snapshot type: $kind (daily, full, chain or since:YYYY-MM-DD)"; return 2 ;;
  esac
  plan="$(sed '/^$/d' <<< "$plan")"
  if [ -z "$plan" ]; then
    err "No ${kind:-daily} snapshot is available."
    return 1
  fi
  if [ "$kind" = "chain" ] || [ "$kind" = "since" ]; then
    IFS=$'\t' read -r _ reached newest <<< "$(grep '^#END' <<< "$chain")"
    if [ "$reached" \< "$newest" ]; then
      warn "The chain reaches $reached; newer snapshots ($newest) do not build on it and are left out."
    fi
  fi

  dir="$WORK_DIR/snapshots"
  mkdir -p -- "$dir"
  total=0
  count=0
  while IFS=$'\t' read -r type date size checksum path based; do
    if [[ "$path" == *..* ]] || ! [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      err "Unexpected snapshot path in the manifest: $path"
      return 1
    fi
    count=$((count + 1))
    dest="$dir/$date-$type.tar.gz"
    if ! { [ -f "$dest" ] && [ -n "$checksum" ] && [ "$(sha256sum -- "$dest" | cut -d' ' -f1)" = "${checksum#sha256:}" ]; } && [[ "$size" =~ ^[0-9]+$ ]]; then
      total=$((total + size))
    fi
  done <<< "$plan"
  free_kb="$(df -Pk -- "$dir" | awk 'NR == 2 { print $4 }')" || free_kb=0
  if [ "$total" -gt $((free_kb * 1024)) ]; then
    err "Not enough free space in $dir: $(human_size "$total") needed, $(human_size "$((free_kb * 1024))") free."
    return 1
  fi
  planfile="$dir/plan-$(date +%Y%m%d-%H%M%S)-$$.tsv"
  printf '%s\n' "$plan" > "$planfile"

  if [ "$mode" = "interactive" ] && [ -n "$SCRIPT_PATH" ]; then
    rc=0
    if [ "$count" -eq 1 ]; then
      IFS=$'\t' read -r type date size _ <<< "$plan"
      title="Snapshot download ($(snapshot_name "$plan"), $(human_size "$size"))"
    else
      title="Snapshot download ($count files up to $(tail -n 1 <<< "$plan" | cut -f2), $(human_size "$total"))"
    fi
    run_job "$title" "$key" -- snapshot_plan_fetch "$planfile" || rc=$?
    if [ "$rc" -ne 3 ]; then
      rm -f -- "$planfile"
    fi
    case "$rc" in
      0)
        chainfile="$(ls -1t -- "$dir"/chain-*.tsv 2>/dev/null | head -n 1)" || chainfile=""
        if [ "$count" -gt 1 ] && [ -n "$chainfile" ]; then
          if confirm "Import the $count files into the local catalog now, one after the other?" n; then
            import_chain "$chainfile"
          else
            echo "  Import them later with option 19 (it offers the whole chain)."
          fi
        else
          IFS=$'\t' read -r type date _ <<< "$plan"
          if confirm "Import $dir/$date-$type.tar.gz into the local catalog now?" n; then
            import_snapshot "$dir/$date-$type.tar.gz"
          else
            echo "  Import it later with option 19."
          fi
        fi
        ;;
      3) return 3 ;;
      *) return 1 ;;
    esac
  else
    rc=0
    trap 'snapshot_cleanup; exit 130' INT TERM
    SNAP_KEY="$key" snapshot_plan_fetch "$planfile" || rc=$?
    trap - INT TERM
    return "$rc"
  fi
}

# The choice of what to download. Sets SNAP_KIND (chain, since, daily, full) and SNAP_SINCE;
# fails when cancelled.
SNAP_KIND=""
SNAP_SINCE=""
snapshot_choose() {
  local rows="$1" full="$2" daily="$3" choice fdate fsize ddate dsize dbased chain reached newest n total line nd n7 n30
  SNAP_KIND=""
  SNAP_SINCE=""
  nd="$(grep -c $'^daily\t' <<< "$rows" || true)"
  n7="$(grep -c $'^cumulative-7d\t' <<< "$rows" || true)"
  n30="$(grep -c $'^cumulative-30d\t' <<< "$rows" || true)"
  echo
  if [ -n "$full" ]; then
    IFS=$'\t' read -r _ fdate fsize _ <<< "$full"
    chain="$(snapshot_chain "$fdate" <<< "$rows")"
    IFS=$'\t' read -r _ reached newest <<< "$(grep '^#END' <<< "$chain")"
    n=0
    total="$fsize"
    while IFS=$'\t' read -r _ _ dsize _; do
      n=$((n + 1))
      total=$((total + dsize))
    done < <(grep -v '^#END' <<< "$chain" || true)
    ui_box "$(ui_width)" "Catalog snapshots $UI_SEP $CATALOG_CLOUD_URL" \
      "Full snapshot $fdate ($(human_size "$fsize")) $UI_SEP $nd daily $UI_SEP $n7 weekly $UI_SEP $n30 monthly $UI_SEP newest data ${newest:-$fdate}"
    printf '   %s %s  %s  %s\n' "${C_BLD}1$C_RST" "$(menu_icon run)" "$(ui_pad "Full + all changes up to today" 34)" "full $fdate + $n delta(s) $UI_SEP $(human_size "$total") $C_DIM(new installation)$C_RST"
  else
    ui_box "$(ui_width)" "Catalog snapshots $UI_SEP $CATALOG_CLOUD_URL" "No full snapshot in the manifest $UI_SEP $nd daily $UI_SEP $n7 weekly $UI_SEP $n30 monthly"
    printf '   %s %s  %s  %s\n' "${C_BLD}1$C_RST" "$(menu_icon run)" "$(ui_pad "Full + all changes up to today" 34)" "${C_DIM}not available$C_RST"
  fi
  printf '   %s %s  %s  %s\n' "${C_BLD}2$C_RST" "$(menu_icon run)" "$(ui_pad "Changes since a date" 34)" "${C_DIM}deltas only, for a catalog that is behind$C_RST"
  if [ -n "$daily" ]; then
    IFS=$'\t' read -r _ ddate dsize _ _ dbased <<< "$daily"
    printf '   %s %s  %s  %s\n' "${C_BLD}3$C_RST" "$(menu_icon run)" "$(ui_pad "Latest daily snapshot   $ddate" 34)" "$(human_size "$dsize") $C_DIM(applies on top of ${dbased:-the previous state})$C_RST"
  else
    printf '   %s %s  %s  %s\n' "${C_BLD}3$C_RST" "$(menu_icon run)" "$(ui_pad "Latest daily snapshot" 34)" "${C_DIM}none available$C_RST"
  fi
  if [ -n "$full" ]; then
    printf '   %s %s  %s  %s\n' "${C_BLD}4$C_RST" "$(menu_icon run)" "$(ui_pad "Latest full snapshot    $fdate" 34)" "$(human_size "$fsize") $C_DIM(for a new installation)$C_RST"
  else
    printf '   %s %s  %s  %s\n' "${C_BLD}4$C_RST" "$(menu_icon run)" "$(ui_pad "Latest full snapshot" 34)" "${C_DIM}none available$C_RST"
  fi
  printf '   %s    %s\n' "${C_BLD}0$C_RST" "${C_DIM}cancel$C_RST"
  echo
  echo "  ${C_DIM}Servers with internet access: option 20 lets the Catalog fetch the changes itself every day.$C_RST"
  ui_ask choice "Select [1]:" || choice="0"
  case "${choice:-1}" in
    1) SNAP_KIND="chain" ;;
    2)
      ui_ask SNAP_SINCE "Date of the newest data in the local catalog (YYYY-MM-DD):" || SNAP_SINCE=""
      if [ -z "$SNAP_SINCE" ]; then
        info "Cancelled."
        return 1
      fi
      SNAP_KIND="since"
      ;;
    3) SNAP_KIND="daily" ;;
    4) SNAP_KIND="full" ;;
    *) info "Cancelled."; return 1 ;;
  esac
}

# Worker: snapshot_plan_fetch PLANFILE - downloads the archives of the plan in order and writes the
# chain file the import uses (key from the job secret or SNAP_KEY).
snapshot_plan_fetch() {
  local planfile="$1" key n=0 count dir type date size checksum path based chainfile line
  local -a lines=()
  key="$(job_secret_take)"
  SNAP_KEY="${key:-${SNAP_KEY:-}}"
  mapfile -t lines < "$planfile"
  rm -f -- "$planfile"
  count="${#lines[@]}"
  dir="$WORK_DIR/snapshots"
  for line in "${lines[@]}"; do
    n=$((n + 1))
    IFS=$'\t' read -r type date size checksum path based <<< "$line"
    if [ "$count" -gt 1 ]; then
      echo
      info "[$n/$count] $(snapshot_name "$line")"
    fi
    if ! snapshot_fetch "$type" "$date" "$size" "$checksum" "$path" "$based" "$(if [ "$count" -gt 1 ]; then printf '[%s/%s] %s' "$n" "$count" "$(snapshot_name "$line")"; else printf 'Downloading'; fi)"; then
      if [ "$count" -gt 1 ]; then
        err "Stopped at $(snapshot_name "$line") - the files after it were not downloaded."
      fi
      return 1
    fi
  done
  if [ "$count" -gt 1 ]; then
    IFS=$'\t' read -r type date _ <<< "${lines[0]}"
    chainfile="$dir/chain-$date-$type-to-$(cut -f2 <<< "${lines[count - 1]}").tsv"
    printf '%s\n' "${lines[@]}" > "$chainfile"
    echo
    ok "$count snapshots downloaded. Apply them in this order (option 19 does it):"
    n=0
    for line in "${lines[@]}"; do
      n=$((n + 1))
      IFS=$'\t' read -r type date _ <<< "$line"
      echo "   $n. $date-$type.tar.gz"
    done
  fi
}

SNAP_PART=""

snapshot_cleanup() {
  if [ -n "$SNAP_PART" ] && [ -e "$SNAP_PART" ]; then
    rm -f -- "$SNAP_PART"
    echo "Partial download removed: $SNAP_PART"
  fi
  SNAP_PART=""
}

# Worker: snapshot_fetch TYPE DATE SIZE CHECKSUM PATH BASED (key from the job secret or SNAP_KEY)
snapshot_fetch() {
  local type="$1" date="$2" size="$3" checksum="$4" path="$5" based="$6" label="${7:-Downloading}" key dir dest code actual pid codefile
  key="$(job_secret_take)"
  key="${key:-${SNAP_KEY:-}}"
  if [ -z "$key" ]; then
    err "No API key given."
    return 1
  fi
  dir="$WORK_DIR/snapshots"
  mkdir -p -- "$dir"
  dest="$dir/$date-$type.tar.gz"
  if [ -f "$dest" ] && [ -n "$checksum" ] && [ "$(sha256sum -- "$dest" | cut -d' ' -f1)" = "${checksum#sha256:}" ]; then
    ok "Already downloaded: $dest"
    return 0
  fi
  info "Downloading the $type snapshot of $date ($(human_size "$size")) to $dest"
  SNAP_PART="$dest.part"
  JOB_CLEANUP="snapshot_cleanup"
  codefile="$(mktemp)"
  curl -sS -K - --proto '=https' --connect-timeout 10 --retry 2 --retry-delay 3 -H 'Accept: */*' \
    -o "$dest.part" -w '%{http_code}' "${CATALOG_CLOUD_URL%/}/v3/synchronization/snapshot/$path" \
    <<< "header = \"X-Api-Key: $key\"" > "$codefile" &
  pid=$!
  job_watch_bytes "$pid" "$dest.part" "$size" "$label"
  wait "$pid" || true
  code="$(cat -- "$codefile")"
  rm -f -- "$codefile"
  if [ -t 1 ] && [ -z "$JOB_DIR" ]; then
    echo
  fi
  if [ "$code" != "200" ]; then
    snapshot_cleanup
    case "$code" in
      401|403) err "Download refused (HTTP $code) - check the API key (menu option 18)." ;;
      000) err "Download failed: $CATALOG_CLOUD_URL is not reachable." ;;
      *) err "Download failed (HTTP $code)." ;;
    esac
    return 1
  fi
  if [ -n "$checksum" ]; then
    job_progress "" "Verifying the sha256 checksum"
    info "Verifying the sha256 checksum"
    actual="$(sha256sum -- "$dest.part" | cut -d' ' -f1)"
    if [ "$actual" != "${checksum#sha256:}" ]; then
      snapshot_cleanup
      err "Checksum mismatch - the download is broken, try again."
      return 1
    fi
  else
    warn "The manifest has no checksum for this snapshot - not verified."
  fi
  if [ "$(head -c 2 -- "$dest.part" | od -An -tx1 | tr -d ' \n')" != "1f8b" ]; then
    snapshot_cleanup
    err "The download is not a .tar.gz archive."
    return 1
  fi
  mv -f -- "$dest.part" "$dest"
  JOB_CLEANUP=""
  ok "Snapshot saved: $dest ($(human_size "$(stat -c %s -- "$dest")"), sha256 verified)"
  if [ "$type" = "daily" ] && [ -z "$JOB_DIR" ]; then
    echo "  A daily snapshot applies on top of a catalog at ${based:-the previous day}; a new installation needs the full snapshot."
  fi
}

###############################################################################
# Import into the local catalog
###############################################################################

LOCAL_AUTH=""
LOCAL_STATE=""
LOCAL_ADMIN="no"

local_url() {
  printf 'http://localhost:%s' "$(setting CATALOG_WEB_PORT)"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  printf '%s' "$s"
}

new_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/'
  fi
}

# local_call METHOD PATH OUTFILE [curl args...] -> HTTP status of the local catalog ("000" when not reachable).
# The credentials go to curl through its stdin config.
local_call() {
  local method="$1" path="$2" out="$3"
  shift 3
  if [ -n "$LOCAL_AUTH" ]; then
    printf 'header = "%s"\n' "$LOCAL_AUTH"
  fi | curl -sS -K - -X "$method" -H 'Accept: application/json' --connect-timeout 5 --max-time 120 \
      -o "$out" -w '%{http_code}' "$@" "$(local_url)$path" || true
}

json_field() {
  sed -n "s/.*\"$1\" *: *\"\\{0,1\\}\\([^\",}]*\\).*/\\1/p" "$2" | head -n 1
}

# Checks LOCAL_AUTH: LOCAL_STATE valid / invalid / unreachable / error, LOCAL_ADMIN yes / no.
local_auth_check() {
  local out code
  out="$(mktemp)"
  code="$(local_call GET /v1/databaseconfiguration/synchronization "$out")"
  rm -f -- "$out"
  LOCAL_ADMIN="no"
  case "$code" in
    200) LOCAL_STATE="valid"; LOCAL_ADMIN="yes" ;;
    403) LOCAL_STATE="valid" ;;
    401) LOCAL_STATE="invalid" ;;
    000) LOCAL_STATE="unreachable" ;;
    *) LOCAL_STATE="error" ;;
  esac
}

report_local_state() {
  case "$LOCAL_STATE" in
    valid)
      if [ "$LOCAL_ADMIN" = "yes" ]; then
        ok "Access to the local catalog works (administrator)."
      else
        ok "Access to the local catalog works (no administrator rights)."
      fi
      ;;
    invalid) err "The local catalog rejected the key or login." ;;
    unreachable) err "The local catalog is not reachable at $(local_url) - is the stack running (option 6)?" ;;
    *) err "Unexpected answer from the local catalog." ;;
  esac
}

local_login() {
  local user pw body resp code token
  read -r -p "  Local catalog user name: " user || user=""
  if [ -z "$user" ]; then
    info "Cancelled."
    return 1
  fi
  read -r -s -p "  Password (input hidden): " pw || pw=""
  echo
  body="$(mktemp)"
  resp="$(mktemp)"
  (umask 077 && printf '{"username":"%s","password":"%s","fingerprint":"%s","rememberMe":false}' \
    "$(json_escape "$user")" "$(json_escape "$pw")" "$(new_uuid)" > "$body")
  pw=""
  LOCAL_AUTH=""
  code="$(local_call POST /v1/authentication/request "$resp" -H 'Content-Type: application/json' --data-binary "@$body")"
  rm -f -- "$body"
  token="$(json_field access_token "$resp")"
  rm -f -- "$resp"
  case "$code" in
    200)
      if [ -z "$token" ]; then
        err "The login answer contains no token."
        return 1
      fi
      LOCAL_AUTH="Authorization: Bearer $token"
      ok "Logged in to the local catalog."
      ;;
    401) err "Wrong user name or password (the account is locked after 5 failed logins)."; return 1 ;;
    403) err "Too many failed logins - the local catalog blocks this address for a while."; return 1 ;;
    000) err "The local catalog is not reachable at $(local_url) - is the stack running (option 6)?"; return 1 ;;
    *) err "Login failed (HTTP $code)."; return 1 ;;
  esac
}

# Sets LOCAL_AUTH from the stored local key, or asks for a key or a login.
local_auth_obtain() {
  local mode="${1:-interactive}" key choice
  LOCAL_AUTH=""
  key=""
  if [ -s "$LOCAL_KEY_FILE" ]; then
    key="$(tr -d ' \r\n\t' < "$LOCAL_KEY_FILE")"
  fi
  if [ -n "$key" ]; then
    LOCAL_AUTH="X-Api-Key: $key"
    local_auth_check
    if [ "$LOCAL_STATE" = "valid" ]; then
      return 0
    fi
    report_local_state
    if [ "$LOCAL_STATE" != "invalid" ] || [ "$mode" != "interactive" ]; then
      return 1
    fi
    LOCAL_AUTH=""
  fi
  if [ "$mode" != "interactive" ]; then
    err "No local catalog API key stored - add one with menu option 18."
    return 1
  fi
  echo "  Access to the local catalog ($(local_url)):"
  echo "   1) API key of the local catalog (web interface: API keys; role Synchronizer or Admin)"
  echo "   2) Log in with a local administrator (the password is not stored)"
  echo "   0) Cancel"
  read -r -p "  Select [1]: " choice || choice="0"
  case "${choice:-1}" in
    1)
      read -r -s -p "  Local API key (input hidden): " key || key=""
      echo
      key="$(api_key_normalize "$key")"
      if [ -z "$key" ] || [[ "$key" == *[\"\\]* ]]; then
        info "Cancelled."
        return 1
      fi
      LOCAL_AUTH="X-Api-Key: $key"
      local_auth_check
      report_local_state
      if [ "$LOCAL_STATE" != "valid" ]; then
        LOCAL_AUTH=""
        return 1
      fi
      if confirm "Save the local key in $LOCAL_KEY_FILE (readable only by $(id -un))?" y; then
        (umask 077 && printf '%s\n' "$key" > "$LOCAL_KEY_FILE")
        chmod 600 "$LOCAL_KEY_FILE"
        ok "Local API key saved."
      fi
      ;;
    2)
      local_login || return 1
      local_auth_check
      ;;
    *)
      info "Cancelled."
      return 1
      ;;
  esac
}

# Follows a local operation until it ends.
watch_operation() {
  local opid="$1" out code status progress message path="/v1/operation/$1" waited=0
  out="$(mktemp)"
  info "Import running (operation $opid) - the progress is checked every 5 seconds."
  while [ "$waited" -lt 14400 ]; do
    code="$(local_call GET "$path" "$out")"
    if [ "$code" = "403" ] && [ "$path" = "/v1/operation/$opid" ]; then
      path="/v1/synchronizationHistory/progress/$opid"
      continue
    fi
    status="$(json_field status "$out")"
    progress="$(json_field progress "$out")"
    message="$(json_field message "$out")"
    if [[ "$progress" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      job_progress "$progress" "Import ${status:-running}${message:+: $message}"
    else
      job_progress "" "Import ${status:-running}${message:+: $message}"
    fi
    case "$status" in
      finished|Finished)
        echo
        rm -f -- "$out"
        ok "Import finished."
        return 0
        ;;
      failed|Failed|cancelled|Cancelled|rejected|Rejected)
        echo
        rm -f -- "$out"
        err "Import $status${message:+: $message}"
        return 1
        ;;
    esac
    sleep 5
    waited=$((waited + 5))
  done
  echo
  rm -f -- "$out"
  warn "Still running after 4 hours - check the Catalog web interface."
  return 1
}

# catalog_fixed_upload_limit VERSION -> true for Catalog 25.x and older: 10 GB per upload, not configurable
catalog_fixed_upload_limit() {
  [[ "$1" =~ ^([0-9]+)\. ]] && [ "${BASH_REMATCH[1]}" -le 25 ]
}

# Bytes the local catalog accepts in one upload: Catalog 25.x has a fixed limit of 10 GB, newer
# versions take Synchronization__MaxUploadFileSize (SYNC_MAX_UPLOAD in .env, 8GB when it is missing).
upload_limit() {
  local version value num unit
  version=""
  if command -v docker >/dev/null 2>&1 && detect_compose 2>/dev/null; then
    version="$(running_tag catalog-web 2>/dev/null)" || version=""
  fi
  if ! [[ "$version" =~ ^[0-9]+\. ]]; then
    version="$CATALOG_VERSION"
  fi
  if catalog_fixed_upload_limit "$version"; then
    printf '%s' 10737418239
    return 0
  fi
  value="$(env_value SYNC_MAX_UPLOAD 2>/dev/null)" || value=""
  value="${value:-8GB}"
  if [[ "$value" =~ ^([0-9]+)(GB|MB|KB)?$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
      GB) printf '%s' $((num * 1024 * 1024 * 1024)) ;;
      MB) printf '%s' $((num * 1024 * 1024)) ;;
      KB) printf '%s' $((num * 1024)) ;;
      *) printf '%s' "$num" ;;
    esac
  else
    printf '%s' $((8 * 1024 * 1024 * 1024))
  fi
}

# upload_fits FILE SIZE -> fails with an explanation when the file is larger than the upload limit
upload_fits() {
  local limit
  limit="$(upload_limit)"
  if [ "$2" -le "$limit" ]; then
    return 0
  fi
  err "$(basename -- "$1") is $(human_size "$2"), the local catalog accepts at most $(human_size "$limit") per upload."
  if [ "$limit" = 10737418239 ]; then
    echo "  Catalog 25.x has a fixed limit of 10 GB. On a server with internet access option 20 lets the"
    echo "  Catalog fetch the data itself; otherwise upgrade to 26.x (option 21) and import again."
  else
    echo "  Raise SYNC_MAX_UPLOAD in the settings (option 1), then apply it with option 2 and 6."
  fi
  return 1
}

# import_chain CHAINFILE -> uploads the files of a downloaded chain, in order, each after the previous one finished
import_chain() {
  local chainfile="$1" mode="${2:-interactive}" type date size file
  local -a files=()
  if [ -z "$chainfile" ] || [ ! -f "$chainfile" ]; then
    err "No downloaded chain${chainfile:+ at $chainfile} - download one with option 17 ('Full + all changes up to today')."
    return 1
  fi
  while IFS=$'\t' read -r type date size _; do
    file="$WORK_DIR/snapshots/$date-$type.tar.gz"
    if [ ! -f "$file" ]; then
      err "$(basename -- "$file") of the chain is missing - download it again with option 17."
      return 1
    fi
    upload_fits "$file" "$(stat -c %s -- "$file")" || return 1
    files+=("$file")
  done < "$chainfile"
  if [ "${#files[@]}" -eq 0 ]; then
    err "$chainfile lists no snapshot."
    return 1
  fi
  local_auth_obtain "$mode" || return 1
  if [ "${#files[@]}" -gt 1 ] && [[ "$LOCAL_AUTH" == "Authorization: Bearer "* ]]; then
    warn "A login stays valid for about one hour - for a long chain store a local API key (option 18)."
  fi
  if [ "$mode" = "interactive" ] && [ -n "$SCRIPT_PATH" ]; then
    run_job "Snapshot import (${#files[@]} files up to $(tail -n 1 "$chainfile" | cut -f2))" "$LOCAL_AUTH" -- import_chain_run "${files[@]}"
  else
    import_chain_run "${files[@]}"
  fi
}

# Worker: import_chain_run FILE... - one upload after the other; stops at the first failure
import_chain_run() {
  local file n=0
  for file in "$@"; do
    n=$((n + 1))
    echo
    info "[$n/$#] $(basename -- "$file")"
    job_step "[$n/$#] Importing $(basename -- "$file")"
    if ! import_upload "$file"; then
      err "Import stopped at $(basename -- "$file") - the files after it were not imported."
      return 1
    fi
  done
  ok "All $# snapshots imported."
}

# import_snapshot FILE [interactive|cli]
import_snapshot() {
  local file="$1" mode="${2:-interactive}" size
  if [ ! -f "$file" ]; then
    err "File not found: $file"
    return 1
  fi
  if [ "$(head -c 2 -- "$file" | od -An -tx1 | tr -d ' \n')" != "1f8b" ]; then
    err "$file is not a .tar.gz snapshot."
    return 1
  fi
  size="$(stat -c %s -- "$file")"
  upload_fits "$file" "$size" || return 1
  if [[ "$(basename -- "$file")" == *-daily.tar.gz ]] && [ "$mode" = "interactive" ]; then
    warn "A daily snapshot only applies on top of a catalog that has the previous day's data."
    if ! confirm "Import $(basename -- "$file") anyway?" y; then
      info "Cancelled."
      return 0
    fi
  fi
  local_auth_obtain "$mode" || return 1
  if [ "$mode" = "interactive" ] && [ -n "$SCRIPT_PATH" ]; then
    run_job "Snapshot import ($(basename -- "$file"))" "$LOCAL_AUTH" -- import_upload "$file"
  else
    import_upload "$file"
  fi
}

# Worker: import_upload FILE (credentials from the job secret or LOCAL_AUTH)
import_upload() {
  local file="$1" resp code opid size pid codefile auth
  auth="$(job_secret_take)"
  auth="${auth:-$LOCAL_AUTH}"
  size="$(stat -c %s -- "$file")"
  info "Uploading $(basename -- "$file") ($(human_size "$size")) to $(local_url)"
  resp="$(mktemp)"
  codefile="$(mktemp)"
  curl -sS -K - -H 'Accept: application/json' --connect-timeout 5 -F "file=@$file;type=application/gzip" \
    -o "$resp" -w '%{http_code}' "$(local_url)/v1/synchronization/snapshot" <<< "header = \"$auth\"" > "$codefile" &
  pid=$!
  job_watch_bytes "$pid" "rchar:$pid" "$size" "Uploading"
  wait "$pid" || true
  code="$(cat -- "$codefile")"
  opid="$(json_field operationId "$resp")"
  rm -f -- "$resp" "$codefile"
  LOCAL_AUTH="$auth"
  case "$code" in
    202)
      if [ -z "$opid" ]; then
        ok "Upload accepted - follow the import in the Catalog web interface."
        return 0
      fi
      watch_operation "$opid"
      ;;
    200) err "The catalog received no file." ; return 1 ;;
    401|403) err "The local catalog refused the upload (HTTP $code) - the key or user needs the Synchronizer or Admin role."; return 1 ;;
    413) err "The file is larger than the upload limit - raise Synchronization__MaxUploadFileSize for catalog-web."; return 1 ;;
    415) err "The catalog does not accept this file type."; return 1 ;;
    000) err "The local catalog is not reachable at $(local_url) - is the stack running (option 6)?"; return 1 ;;
    *) err "Upload failed (HTTP $code)."; return 1 ;;
  esac
}

import_snapshot_menu() {
  local files=() chains=() f i choice n total size names line
  while IFS= read -r f; do
    chains+=("$f")
  done < <(ls -1t -- "$WORK_DIR"/snapshots/chain-*.tsv 2>/dev/null)
  while IFS= read -r f; do
    files+=("$f")
  done < <(ls -1t -- "$WORK_DIR"/snapshots/*.tar.gz 2>/dev/null)
  if [ "${#files[@]}" -eq 0 ]; then
    warn "No snapshot in $WORK_DIR/snapshots - download one with option 17."
    return 0
  fi
  echo
  ui_box "$(ui_width)" "Import into the local catalog $UI_SEP $(local_url)" "Snapshots in $WORK_DIR/snapshots, newest first. A chain is imported file by file, in order."
  i=0
  for f in "${chains[@]}"; do
    i=$((i + 1))
    n=0
    total=0
    names=""
    while IFS= read -r line; do
      IFS=$'\t' read -r _ _ size _ <<< "$line"
      n=$((n + 1))
      total=$((total + size))
      if [ "$n" -eq 1 ]; then
        names="$(snapshot_name "$line")"
      fi
    done < "$f"
    if [ "$n" -gt 2 ]; then
      names="$names $UI_RARR $((n - 2)) more $UI_RARR $(snapshot_name "$(tail -n 1 "$f")")"
    elif [ "$n" -eq 2 ]; then
      names="$names $UI_RARR $(snapshot_name "$(tail -n 1 "$f")")"
    fi
    printf '   %s %s  %s  %s\n' "$C_BLD$i$C_RST" "$(menu_icon run)" "$(ui_pad "Chain up to $(tail -n 1 "$f" | cut -f2)" 34)" "$names $UI_SEP $n files, $(human_size "$total")"
  done
  for f in "${files[@]}"; do
    i=$((i + 1))
    printf '   %s %s  %s  %s\n' "$C_BLD$i$C_RST" "$(menu_icon run)" "$(ui_pad "$(basename -- "$f")" 34)" "$(human_size "$(stat -c %s -- "$f")")"
  done
  printf '   %s    %s\n' "${C_BLD}0$C_RST" "${C_DIM}cancel$C_RST"
  echo
  ui_ask choice "Select [1]:" || choice="0"
  choice="${choice:-1}"
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$i" ]; then
    info "Cancelled."
  elif [ "$choice" -le "${#chains[@]}" ]; then
    import_chain "${chains[choice - 1]}"
  else
    import_snapshot "${files[choice - 1 - ${#chains[@]}]}"
  fi
}

# Online servers: the local catalog gets the online catalog URL and key and synchronizes itself
# (daily by AUTOSYNC_CRON afterwards).
local_self_sync() {
  local key cur body out code
  key="$(api_key_stored)"
  if [ -z "$key" ]; then
    echo "  The local catalog needs your API key for $CATALOG_CLOUD_URL."
    prompt_api_key || return 0
    key="$NEW_KEY"
    if confirm "Save the key for the next time (in $API_KEY_FILE, readable only by $(id -un))?" y; then
      api_key_save "$key"
      ok "API key saved."
    fi
  else
    info "Testing the stored API key $(api_key_mask "$key")"
    api_key_check "$key"
    report_key_state
    if [ "$KEY_STATE" != "valid" ]; then
      return 1
    fi
  fi
  if [ -n "$MANIFEST_FILE" ]; then
    rm -f -- "$MANIFEST_FILE"
  fi
  local_auth_obtain || return 1
  if [ "$LOCAL_ADMIN" != "yes" ]; then
    err "Changing the synchronization settings needs a local administrator."
    return 1
  fi

  cur="$(mktemp)"
  body="$(mktemp)"
  out="$(mktemp)"
  code="$(local_call GET /v1/databaseconfiguration/synchronization "$cur")"
  if [ "$code" != "200" ]; then
    rm -f -- "$cur" "$body" "$out"
    err "Could not read the synchronization settings (HTTP $code)."
    return 1
  fi
  chmod 600 "$body"
  if command -v jq >/dev/null 2>&1; then
    jq --arg u "$CATALOG_CLOUD_URL" --rawfile k <(printf '%s' "$key") \
      '(if type == "object" then . else {} end) + {parentInstanceUrl: $u, parentInstanceKey: $k}' "$cur" > "$body"
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$key" | python3 -c '
import json, sys
cur = json.load(open(sys.argv[1]))
cur = cur if isinstance(cur, dict) else {}
cur["parentInstanceUrl"] = sys.argv[2]
cur["parentInstanceKey"] = sys.stdin.read()
print(json.dumps(cur))
' "$cur" "$CATALOG_CLOUD_URL" > "$body"
  else
    warn "jq or python3 not found - other synchronization settings (e.g. the proxy) may be reset."
    printf '{"parentInstanceUrl":"%s","parentInstanceKey":"%s"}' "$(json_escape "$CATALOG_CLOUD_URL")" "$(json_escape "$key")" > "$body"
  fi
  rm -f -- "$cur"
  code="$(local_call POST /v1/databaseconfiguration/synchronization "$out" -H 'Content-Type: application/json' --data-binary "@$body")"
  rm -f -- "$body"
  case "$code" in
    200|201|204) ok "The local catalog now synchronizes from $CATALOG_CLOUD_URL (automatically: AUTOSYNC_CRON \"$(setting AUTOSYNC_CRON)\")." ;;
    *) rm -f -- "$out"; err "Saving the synchronization settings failed (HTTP $code)."; return 1 ;;
  esac

  if ! confirm "Start a synchronization now?" y; then
    rm -f -- "$out"
    return 0
  fi
  rm -f -- "$out"
  if [ -n "$SCRIPT_PATH" ]; then
    run_job "Synchronization from the online catalog" "$LOCAL_AUTH" -- self_sync_run
  else
    self_sync_run
  fi
}

# Worker: starts the synchronization of the local catalog and follows it.
self_sync_run() {
  local tmp out code opid auth
  auth="$(job_secret_take)"
  LOCAL_AUTH="${auth:-$LOCAL_AUTH}"
  tmp="$(mktemp)"
  out="$(mktemp)"
  printf -- '--rvcboundary--\r\n' > "$tmp"
  code="$(local_call POST /v1/synchronization/synchronize "$out" -H 'Content-Type: multipart/form-data; boundary=rvcboundary' --data-binary "@$tmp")"
  rm -f -- "$tmp"
  case "$code" in
    200|202)
      opid="$(json_field operationId "$out")"
      rm -f -- "$out"
      if [ -n "$opid" ]; then
        watch_operation "$opid"
      else
        ok "Synchronization started - follow it in the Catalog web interface."
      fi
      ;;
    304) rm -f -- "$out"; ok "The local catalog is already up to date." ;;
    503) rm -f -- "$out"; warn "A synchronization is already running." ;;
    403) rm -f -- "$out"; err "The local catalog refused the synchronization (HTTP 403) - the online key may lack the Synchronizer role."; return 1 ;;
    *) rm -f -- "$out"; err "Starting the synchronization failed (HTTP $code)."; return 1 ;;
  esac
}

###############################################################################
# Guided upgrade
###############################################################################

# Image tag of a running service (empty when it does not run).
running_tag() {
  local id image
  id="$(compose ps -q "$1" 2>/dev/null | head -n 1)" || id=""
  if [ -z "$id" ]; then
    return 0
  fi
  image="$(docker inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)" || image=""
  printf '%s' "${image##*:}"
}

mongo_running_version() {
  compose exec -T mongo mongod --version 2>/dev/null | sed -n 's/^db version v//p' | head -n 1 || true
}

# Waits until every service runs (and is healthy where it has a healthcheck) and Catalog Web answers.
stack_health() {
  local timeout="${1:-$HEALTH_TIMEOUT}" waited=0 svc id state health restarts bad code warned
  local -a services=()
  while IFS= read -r svc; do
    if [ -n "$svc" ]; then
      services+=("$svc")
    fi
  done < <(compose config --services 2>/dev/null)
  info "Health check of ${#services[@]} services (up to $((timeout / 60)) minutes)"
  while true; do
    bad=""
    warned=""
    for svc in "${services[@]}"; do
      id="$(compose ps -q "$svc" 2>/dev/null | head -n 1)" || id=""
      if [ -z "$id" ]; then
        bad="$bad $svc(missing)"
        continue
      fi
      read -r state health restarts <<< "$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}' "$id" 2>/dev/null)" || true
      if [ "${state:-}" != "running" ] || { [ "${health:-none}" != "none" ] && [ "$health" != "healthy" ]; }; then
        bad="$bad $svc(${state:-?}/${health:-?})"
      elif [ "${restarts:-0}" != "0" ]; then
        warned="$warned $svc(${restarts}x)"
      fi
    done
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$(local_url)/" || true)"
    if [ -z "$bad" ] && [ "$code" = "200" ]; then
      if [ -t 1 ]; then
        echo
      fi
      ok "All ${#services[@]} services run and Catalog Web answers on $(local_url)."
      if [ -n "$warned" ]; then
        warn "Restarted while starting:$warned - check their logs (option 10) if this keeps growing."
      fi
      return 0
    fi
    if [ "$waited" -ge "$timeout" ]; then
      if [ -t 1 ]; then
        echo
      fi
      err "Not healthy after $((timeout / 60)) minutes:${bad} Catalog Web: HTTP $code"
      return 1
    fi
    if [ -n "$JOB_DIR" ]; then
      job_progress "$((timeout > 0 ? waited * 100 / timeout : 0))" "Health check ${waited}s: waiting for${bad:- -} web=$code"
    elif [ -t 1 ]; then
      printf '\r       %4ss  waiting for:%s web=%s          ' "$waited" "${bad:- -}" "$code"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

# Writes a compressed mongodump of all databases to backups/; the password stays inside the container.
mongo_backup() {
  local dir file
  dir="$WORK_DIR/backups"
  mkdir -p -- "$dir"
  file="$dir/mongo-$(date +%Y%m%d-%H%M%S).archive.gz"
  info "MongoDB backup -> $file"
  job_step "MongoDB backup"
  BACKUP_PARTIAL="$file"
  if (umask 077 && compose exec -T mongo sh -c '
      umask 077
      printf "password: \"%s\"\n" "$MONGO_INITDB_ROOT_PASSWORD" > /tmp/.rvc-dump.yml
      mongodump --quiet --archive --gzip --config=/tmp/.rvc-dump.yml \
        --username "$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase admin
      rc=$?
      rm -f /tmp/.rvc-dump.yml
      exit $rc' > "$file") && [ -s "$file" ]; then
    chmod 600 "$file"
    BACKUP_PARTIAL=""
    ok "Backup written ($(human_size "$(stat -c %s -- "$file")"))."
    LAST_BACKUP="$file"
  else
    BACKUP_PARTIAL=""
    rm -f -- "$file"
    err "The MongoDB backup failed."
    return 1
  fi
}

# Series of a version for patch updates: MongoDB, OpenSearch and RabbitMQ X.Y, Nginx Proxy Manager X.
version_series() {
  local key="$1" core
  core="$(version_core "$2")"
  case "$key" in
    npm) printf '%s' "${core%%.*}" ;;
    minio) printf 'RELEASE' ;;
    *) printf '%s' "$(cut -d. -f1-2 <<< "$core")" ;;
  esac
}

# Same-series updates of the infrastructure components (MongoDB 8.0.4 -> 8.0.32 and so on).
offer_patch_updates() {
  local key first tag current series newest v count=0 i choice tok mongo_running
  local -a keys=() froms=() tos=() picked=() toks=() specs=()
  mongo_running="$(mongo_running_version)"
  for key in "${UPD_KEYS[@]}"; do
    component_info "$key"
    first="${C_SETTINGS%% *}"
    tag="${!first}"
    if [ "$key" = "mongo" ] && [ -n "$mongo_running" ]; then
      current="$mongo_running"
    elif [[ "$tag" =~ $(kind_regex "$C_KIND") ]]; then
      current="$tag"
    else
      current="${UPD_RESOLVED[$key]-}"
    fi
    if [ -z "$current" ] || [ -z "${UPD_VERSIONS[$key]-}" ]; then
      continue
    fi
    series="$(version_series "$key" "$current")"
    newest=""
    while IFS= read -r v; do
      if [ "$(version_series "$key" "$v")" = "$series" ]; then
        newest="$v"
        break
      fi
    done <<< "${UPD_VERSIONS[$key]}"
    if [ -n "$newest" ] && kind_newer "$C_KIND" "$newest" "$current"; then
      keys+=("$key")
      froms+=("$current")
      tos+=("$newest")
      picked+=(1)
    fi
  done
  if [ "$mongo_running" != "" ] && [ "${mongo_running%%.*}" -lt 8 ] 2>/dev/null; then
    info "MongoDB ${mongo_running%%.*}.x runs here. MongoDB 8.0 is a major upgrade (Updates, option 8)$(if kernel_blocks_mongo8; then printf ' and does not start on this kernel'; fi)."
  fi
  if [ "${#keys[@]}" -eq 0 ]; then
    ok "MongoDB, OpenSearch, RabbitMQ, MinIO and Nginx Proxy Manager have the newest patch versions of their series."
    return 0
  fi
  while true; do
    echo
    ui_box "$(ui_width)" "Patch updates" "Same release series: bug and security fixes, no data migration"
    for i in "${!keys[@]}"; do
      component_info "${keys[i]}"
      printf '   %s %s  %s %s -> %s\n' "$(if [ "${picked[i]}" = 1 ]; then printf '%s' "$C_GRN$UI_ON$C_RST"; else printf '%s' "$C_DIM$UI_OFF$C_RST"; fi)" "$C_BLD$((i + 1))$C_RST" "$(ui_pad "$C_LABEL" 26)" "$(version_core "${froms[i]}")" "$C_GRN$(version_core "${tos[i]}")$C_RST"
    done
    echo
    ui_keys "1-${#keys[@]}|toggle" "Enter|apply the selected ones" "0|skip"
    ui_ask choice "Toggle, or Enter to apply:" || choice="0"
    case "$choice" in
      "") break ;;
      0) info "No patch updates applied."; return 0 ;;
      *)
        read -r -a toks <<< "$choice"
        for tok in "${toks[@]}"; do
          if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#keys[@]}" ]; then
            picked[tok - 1]=$((1 - picked[tok - 1]))
          fi
        done
        ;;
    esac
  done
  for i in "${!keys[@]}"; do
    if [ "${picked[i]}" = 1 ]; then
      component_info "${keys[i]}"
      for first in $C_SETTINGS; do
        specs+=("$first|${!first}|${tos[i]}")
      done
      count=$((count + 1))
    fi
  done
  if [ "$count" -eq 0 ]; then
    info "No patch updates applied."
    return 0
  fi
  sibling_guard || return 1
  run_job "Patch updates ($count component(s))" -- patch_apply "${specs[@]}"
}

PATCH_CHANGES=()
PATCH_STAGE=""

# Worker: patch_apply NAME|OLD|NEW... - a cancel or an error before the services run goes back
patch_apply() {
  local spec name old new
  require_docker || return 1
  PATCH_CHANGES=("$@")
  JOB_CLEANUP="patch_cleanup"
  PATCH_STAGE="pull"
  for spec in "$@"; do
    IFS='|' read -r name old new <<< "$spec"
    set_setting "$name" "$new"
    printf -v "$name" '%s' "$new"
  done
  do_generate keep no-next
  job_step "Pulling the new images"
  info "Pulling the new images"
  compose pull
  PATCH_STAGE="switch"
  job_step "Recreating the changed services"
  info "Recreating the changed services"
  compose up -d --remove-orphans
  PATCH_STAGE=""
  stack_health
}

patch_cleanup() {
  local spec name old new
  if [ -z "$PATCH_STAGE" ]; then
    return 0
  fi
  warn "Going back to the previous versions."
  for spec in "${PATCH_CHANGES[@]}"; do
    IFS='|' read -r name old new <<< "$spec"
    set_setting "$name" "$old"
    printf -v "$name" '%s' "$old"
  done
  do_generate keep no-next
  if [ "$PATCH_STAGE" = "switch" ]; then
    compose up -d --remove-orphans || true
  fi
  PATCH_STAGE=""
}

UPGRADE_FAILED_FILE="$WORK_DIR/.upgrade-failed"
UPG_STAGE=""
UPG_OLD=""
BACKUP_PARTIAL=""

# Asks about going back after an upgrade that did not become healthy. Returns 1 when it went back.
upgrade_offer_rollback() {
  local old target backup
  if [ ! -f "$UPGRADE_FAILED_FILE" ]; then
    return 0
  fi
  IFS='|' read -r old target backup < "$UPGRADE_FAILED_FILE" || true
  warn "The upgrade to $target did not become healthy."
  if confirm "Go back to $old?" n; then
    run_job "Go back to Catalog $old" -- upgrade_rollback "$old" "$target" "$backup" || true
    reload_settings
    return 1
  fi
  echo "  Option 21 offers going back later."
}

do_upgrade() {
  local installed target backup="no" rc
  require_files || return 1
  require_docker || return 1
  sibling_guard || return 1
  upgrade_offer_rollback || return 0
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is needed (apt-get install curl)."
    return 1
  fi
  collect_updates
  installed="$(running_tag catalog-web)"
  if [ -z "$installed" ]; then
    installed="$(env_value CATALOG_IMAGE)"
    installed="${installed##*:}"
  fi
  target="${HUB_STABLE:-${HUB_VERSIONS%%$'\n'*}}"
  if [ -z "$target" ]; then
    err "The available Catalog versions could not be read from Docker Hub."
    return 1
  fi
  echo
  echo " Installed Catalog: ${installed:-unknown}"
  echo " Newest Catalog:    $(version_with_tag "$target")"

  if [ "$installed" = "$target" ] || { is_version "$installed" && ! version_gt "$target" "$installed"; }; then
    ok "The Catalog is up to date."
  else
    cat <<EOF

 Upgrade plan
   1. MongoDB backup (recommended; the new version may migrate the database)
   2. Pull the images of $target while the old version still runs
   3. docker compose down (data volumes are kept)
   4. CATALOG_VERSION $installed -> $target, regenerate the files (passwords are kept)
   5. docker compose up -d
   6. Health check of all services and Catalog Web
 It runs as a background job: closing the SSH session does not stop it, and a cancel
 before step 3 changes nothing while a cancel after it goes back to $installed.
EOF
    if ! confirm "Upgrade the Catalog to $target now? (the Catalog is offline during steps 3 to 6)" n; then
      info "Cancelled - nothing was changed."
      return 0
    fi
    if confirm "Create the MongoDB backup first?" y; then
      backup="yes"
    fi
    rc=0
    run_job "Upgrade to Catalog $target" -- upgrade_run "$target" "$installed" "$backup" || rc=$?
    reload_settings
    case "$rc" in
      0) ;;
      3)
        echo "  Option 21 offers the patch updates of MongoDB, OpenSearch and RabbitMQ when the job is done."
        return 0
        ;;
      *)
        upgrade_offer_rollback || true
        return 1
        ;;
    esac
  fi
  offer_patch_updates
}

upgrade_revert_settings() {
  set_setting CATALOG_VERSION "$UPG_OLD"
  CATALOG_VERSION="$UPG_OLD"
  do_generate keep no-next
}

upgrade_cleanup() {
  case "$UPG_STAGE" in
    backup)
      if [ -n "$BACKUP_PARTIAL" ]; then
        rm -f -- "$BACKUP_PARTIAL"
        echo "Incomplete backup removed: $BACKUP_PARTIAL"
      fi
      warn "Stopped before the upgrade - nothing was changed."
      ;;
    pull)
      upgrade_revert_settings
      warn "Stopped before the switch - Catalog $UPG_OLD keeps running."
      ;;
    switch)
      warn "Stopped during the switch - going back to Catalog $UPG_OLD."
      upgrade_revert_settings
      compose up -d --remove-orphans || true
      if [ -n "$LAST_BACKUP" ]; then
        echo "  If the new version already migrated the database, restore $LAST_BACKUP (see option 21)."
      fi
      ;;
  esac
  UPG_STAGE=""
}

# Worker: upgrade_run TARGET INSTALLED BACKUP(yes|no)
upgrade_run() {
  local target="$1" installed="$2" backup="$3"
  require_docker || return 1
  UPG_OLD="$CATALOG_VERSION"
  JOB_CLEANUP="upgrade_cleanup"
  rm -f -- "$UPGRADE_FAILED_FILE"
  LAST_BACKUP=""
  if [ "$backup" = "yes" ]; then
    UPG_STAGE="backup"
    if ! mongo_backup; then
      UPG_STAGE=""
      err "Upgrade stopped - nothing was changed. Start it again without the backup to upgrade anyway."
      return 1
    fi
  fi
  UPG_STAGE="pull"
  set_setting CATALOG_VERSION "$target"
  CATALOG_VERSION="$target"
  do_generate keep no-next
  job_step "Pulling the images of $target"
  info "Pulling the images of $target"
  if ! compose pull catalog-web worker-recognition-1 worker-recognition-2 worker-other worker-search; then
    err "Pulling the images failed - the running version was not touched."
    upgrade_revert_settings
    UPG_STAGE=""
    return 1
  fi
  UPG_STAGE="switch"
  job_step "docker compose down"
  info "Stopping the stack (docker compose down)"
  compose down --remove-orphans
  job_step "Starting $target"
  info "Starting $target (docker compose up -d)"
  compose up -d --remove-orphans
  if stack_health && [ "$(running_tag catalog-web)" = "$target" ]; then
    UPG_STAGE=""
    ok "Catalog upgraded: $installed -> $target."
    return 0
  fi
  UPG_STAGE=""
  err "The upgrade to $target is not healthy."
  compose ps || true
  echo "  Last log lines of catalog-web:"
  compose logs --tail=30 catalog-web 2>/dev/null | sed 's/^/    /' || true
  printf '%s|%s|%s\n' "$UPG_OLD" "$target" "$LAST_BACKUP" > "$UPGRADE_FAILED_FILE"
  return 1
}

# Worker: upgrade_rollback OLD TARGET BACKUP
upgrade_rollback() {
  local old="$1" target="$2" backup="$3"
  require_docker || return 1
  rm -f -- "$UPGRADE_FAILED_FILE"
  UPG_OLD="$old"
  upgrade_revert_settings
  job_step "Starting $old"
  compose up -d --remove-orphans
  stack_health || true
  if [ -n "$backup" ]; then
    warn "If $target already migrated the database, restore the backup:"
    echo "      docker compose exec -T mongo sh -c 'mongorestore --drop --archive --gzip -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin' < $backup"
  fi
}

###############################################################################
# Installer update
###############################################################################

# Installers from before the rename to rn1-technology-catalog-installer.sh carry this INSTALLER_URL.
LEGACY_INSTALLER_URL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/catalog.sh"
CURRENT_INSTALLER_URL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh"

# Downloads the newest installer and carries the current settings over to it.
update_installer() {
  local mode="${1:-interactive}" tmp line name value backup new_names url="$INSTALLER_URL"
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "Cannot update ${SCRIPT_PATH:-the installer} (not a writable file)."
    return 1
  fi
  if [ "$url" = "$LEGACY_INSTALLER_URL" ]; then
    url="$CURRENT_INSTALLER_URL"
  fi
  tmp="$(mktemp)"
  info "Downloading the newest installer from $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --connect-timeout 10 --max-time 120 -o "$tmp" "$url" || : > "$tmp"
  else
    wget -q -T 120 -O "$tmp" "$url" || : > "$tmp"
  fi
  if ! head -n 1 "$tmp" | grep -q '^#!/usr/bin/env bash' || ! settings_section "$tmp" >/dev/null || ! bash -n "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    err "The download failed or is not a valid installer."
    return 1
  fi
  new_names="$(settings_pairs "$tmp" | cut -d'|' -f1)"
  while IFS='|' read -r name value; do
    if [ "$name" = "INSTALLER_URL" ] && [ "$value" = "$LEGACY_INSTALLER_URL" ]; then
      continue
    fi
    if grep -qx -- "$name" <<< "$new_names"; then
      set_setting "$name" "$value" "$tmp"
    fi
  done < <(settings_pairs "$SCRIPT_PATH")
  if [ "$(cksum < "$tmp")" = "$(cksum < "$SCRIPT_PATH")" ]; then
    rm -f -- "$tmp"
    ok "The installer is up to date."
    return 0
  fi
  if [ "$INSTALLER_URL" = "$LEGACY_INSTALLER_URL" ] && [ "$(grep -v '^INSTALLER_URL=' "$tmp" | cksum)" = "$(grep -v '^INSTALLER_URL=' "$SCRIPT_PATH" | cksum)" ]; then
    rm -f -- "$tmp"
    set_setting INSTALLER_URL "$CURRENT_INSTALLER_URL"
    ok "The installer is up to date. Its update address is now $CURRENT_INSTALLER_URL."
    return 0
  fi
  if ! bash "$tmp" check-settings >/dev/null; then
    rm -f -- "$tmp"
    err "The new installer does not accept the current settings - not updated."
    return 1
  fi
  echo "  Settings that are new in this version keep their defaults; all others keep your values."
  if [ "$mode" = "interactive" ] && ! confirm "Replace $SCRIPT_NAME with the new version?" y; then
    rm -f -- "$tmp"
    info "Cancelled."
    return 0
  fi
  backup="$(script_backup)"
  # Write the content back instead of moving the file, so owner and mode stay.
  cat -- "$tmp" > "$SCRIPT_PATH"
  rm -f -- "$tmp"
  ok "Installer updated (previous version: $backup)."
  if [ "$mode" = "interactive" ]; then
    export RVC_NOTICE="Installer updated - your settings were kept."
    exec bash "$SCRIPT_PATH" menu
  fi
}

###############################################################################
# Take over an existing installation
###############################################################################

project_name_of() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

# Existing Catalog installations, one per line: project|folder|compose file|env file|image|status
find_installations() {
  local project dir cfg envf image status f d seen=" "
  if command -v docker >/dev/null 2>&1; then
    while IFS='|' read -r project dir cfg envf image status; do
      if [ -z "$dir" ] || { [ "$dir" = "$WORK_DIR" ] || [ "$dir" -ef "$WORK_DIR" ]; } || [[ "$seen" == *" $dir "* ]]; then
        continue
      fi
      seen="$seen$dir "
      cfg="${cfg%%,*}"
      printf '%s|%s|%s|%s|%s|%s\n' "$project" "$dir" "${cfg:-$dir/docker-compose.yml}" "${envf:-$dir/.env}" "$image" "$status"
    done < <(docker ps -a --filter "label=com.docker.compose.service=catalog-web" \
      --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Label "com.docker.compose.project.config_files"}}|{{.Label "com.docker.compose.project.environment_file"}}|{{.Image}}|{{.Status}}' 2>/dev/null || true)
  fi
  while IFS= read -r f; do
    d="$(dirname -- "$f")"
    if { [ "$d" = "$WORK_DIR" ] || [ "$d" -ef "$WORK_DIR" ]; } || [[ "$seen" == *" $d "* ]] || ! grep -q 'rayventory-catalog' "$f" 2>/dev/null; then
      continue
    fi
    seen="$seen$d "
    printf '%s|%s|%s|%s|%s|%s\n' "$(project_name_of "$(basename -- "$d")")" "$d" "$f" "$d/.env" "" "not running"
  done < <(find /root /home /opt /srv -maxdepth 3 \( -name docker-compose.yml -o -name docker-compose.yaml -o -name compose.yml -o -name compose.yaml \) 2>/dev/null || true)
}

# A value of an env file as docker compose reads it: the text inside single or double quotes, or
# the text before an inline " #" comment.
env_unquote() {
  local v="$1" rest
  case "$v" in
    \"*)
      rest="${v:1}"
      printf '%s' "${rest%%\"*}"
      ;;
    \'*)
      rest="${v:1}"
      printf '%s' "${rest%%\'*}"
      ;;
    *)
      v="${v%%[[:space:]]#*}"
      v="${v%"${v##*[![:space:]]}"}"
      printf '%s' "$v"
      ;;
  esac
}

# Value of KEY in an env file (any file, not only ours).
env_file_value() {
  sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -n 1 | tr -d '\r'
}

# Settings of FILE that have another value in this script: NAME|OURS|THEIRS
settings_diff() {
  local name value
  local -A mine=()
  while IFS='|' read -r name value; do
    mine["$name"]="$value"
  done < <(settings_pairs "$SCRIPT_PATH")
  while IFS='|' read -r name value; do
    if [ "$name" = "INSTALLER_URL" ] || [ "$name" = "CHECK_FOR_UPDATES" ] || [ -z "${mine[$name]+set}" ]; then
      continue
    fi
    if [ "${mine[$name]}" != "$value" ]; then
      printf '%s|%s|%s\n' "$name" "${mine[$name]}" "$value"
    fi
  done < <(settings_pairs "$1")
}

# FILE is an installer script (an older catalog.sh, the original generator or a copy).
is_installer_file() {
  [ -f "$1" ] && [ -r "$1" ] && head -n 1 "$1" | grep -q '^#!/usr/bin/env bash' && settings_section "$1" >/dev/null
}

# Installer files in this folder other than this script.
other_installers() {
  local f self
  if [ -z "$SCRIPT_PATH" ]; then
    return 0
  fi
  self="$(readlink -f -- "$SCRIPT_PATH" 2>/dev/null)" || self="$SCRIPT_PATH"
  for f in "$WORK_DIR"/*.sh; do
    if [ "$(readlink -f -- "$f" 2>/dev/null)" != "$self" ] && is_installer_file "$f"; then
      printf '%s\n' "$f"
    fi
  done
}

# The files an installer generates (its ENV_FILE or COMPOSE_FILE) are in this folder.
installer_generated() {
  local ef cf
  ef="$(settings_pairs "$1" | sed -n 's/^ENV_FILE|//p' | tail -n 1)"
  cf="$(settings_pairs "$1" | sed -n 's/^COMPOSE_FILE|//p' | tail -n 1)"
  ef="${ef:-.env}"
  cf="${cf:-docker-compose.yml}"
  case "$ef" in /*) ;; *) ef="$WORK_DIR/$ef" ;; esac
  case "$cf" in /*) ;; *) cf="$WORK_DIR/$cf" ;; esac
  [ -f "$ef" ] || [ -f "$cf" ]
}

# Other installers in this folder whose settings differ from ours (CHECK_FOR_UPDATES and
# INSTALLER_URL do not count).
sibling_installers() {
  local f
  while IFS= read -r f; do
    if [ -n "$(settings_diff "$f")" ]; then
      printf '%s\n' "$f"
    fi
  done < <(other_installers)
}

# Generating with our settings would change files of an installation in this folder: ours differ
# from the settings, only one of them exists, or OTHER_INSTALLER generated its own files here.
generate_would_change() {
  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
    settings_stale
  elif [ -f "$ENV_FILE" ] || [ -f "$COMPOSE_FILE" ]; then
    return 0
  else
    [ -n "${1:-}" ] && installer_generated "$1"
  fi
}

# The other installer to warn about: it has other settings, and generating with ours would change
# the installation here. Empty when there is nothing to warn about.
conflicting_sibling() {
  local -a sibs=()
  mapfile -t sibs < <(sibling_installers)
  if [ "${#sibs[@]}" -gt 0 ] && generate_would_change "${sibs[0]}"; then
    printf '%s' "${sibs[0]}"
  fi
}

sibling_advice() {
  printf '%s' "If it manages this installation, take its settings over (option 23, or './$SCRIPT_NAME adopt ./$(basename -- "$1")'); if it is no longer used, rename or remove it."
}

# Stops a step that would generate the files while another installer here has other settings.
# Background jobs were checked when they were started.
sibling_guard() {
  local sib
  if [ -n "$JOB_DIR" ]; then
    return 0
  fi
  sib="$(conflicting_sibling)"
  if [ -n "$sib" ]; then
    err "$(basename -- "$sib") in this folder has other settings than $SCRIPT_NAME, and generating would change the installation."
    echo "  $(sibling_advice "$sib")"
    return 1
  fi
}

# Folder of the first installation find_installations reports (safe with pipefail).
first_installation_dir() {
  local -a found=()
  mapfile -t found < <(find_installations 2>/dev/null)
  if [ "${#found[@]}" -gt 0 ]; then
    printf '%s' "$(cut -d'|' -f2 <<< "${found[0]}")"
  fi
}

# takeover_settings [interactive|cli] FILE -> copies the settings of another installer in this folder
takeover_settings() {
  local mode="$1" src="$2" spec name ours theirs backup n=0 old
  local -a diffs=()
  mapfile -t diffs < <(settings_diff "$src")
  if [ "${#diffs[@]}" -eq 0 ]; then
    ok "$(basename -- "$src") has the same settings as $SCRIPT_NAME."
    return 0
  fi
  echo
  echo " $(basename -- "$src") in this folder has other settings than $SCRIPT_NAME:"
  for spec in "${diffs[@]}"; do
    IFS='|' read -r name ours theirs <<< "$spec"
    printf '   %-30s %s -> %s\n' "$name" "${ours:-(empty)}" "${theirs:-(empty)}"
  done
  echo " Taking them over writes these values into $SCRIPT_NAME. $ENV_FILE, $COMPOSE_FILE and the containers stay as they are."
  if [ -n "$(job_running_ids)" ]; then
    err "Jobs are running (J) - take the settings over when they are done."
    return 1
  fi
  if [ "$mode" = "interactive" ] && ! confirm "Take over the settings of $(basename -- "$src")?" y; then
    info "Cancelled."
    return 0
  fi
  backup="$(script_backup)"
  for spec in "${diffs[@]}"; do
    IFS='|' read -r name ours theirs <<< "$spec"
    if ! set_setting "$name" "$theirs"; then
      cat -- "$backup" > "$SCRIPT_PATH"
      err "Nothing was changed in $SCRIPT_NAME."
      return 1
    fi
    n=$((n + 1))
  done
  if ! bash -n "$SCRIPT_PATH" || ! bash "$SCRIPT_PATH" check-settings; then
    cat -- "$backup" > "$SCRIPT_PATH"
    err "The settings of $(basename -- "$src") do not fit - nothing was changed in $SCRIPT_NAME."
    return 1
  fi
  ok "Took over $n setting(s) from $(basename -- "$src") (previous $SCRIPT_NAME: $backup)."
  old="$src.replaced-$(date +%Y%m%d-%H%M%S)"
  if [ "$mode" != "interactive" ] || confirm "Rename $(basename -- "$src") to $(basename -- "$old"), so that only $SCRIPT_NAME manages this folder?" y; then
    mv -- "$src" "$old"
    ok "Renamed to $(basename -- "$old")."
  fi
  if [ "$mode" = "interactive" ]; then
    export RVC_NOTICE="Settings of $(basename -- "$src") taken over."
    exec bash "$SCRIPT_PATH" menu
  fi
}

# adopt_installation [interactive|cli] [FOLDER]
adopt_installation() {
  local mode="${1:-interactive}" wanted="${2:-}" line choice project dir cfg envf image status i version key value imported=0 skipped="" backup tmp_env tmp_compose
  local this_folder="false"
  local -a cands=() sibs=()
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "Cannot change ${SCRIPT_PATH:-the installer} (not a writable file)."
    return 1
  fi
  if [ -n "$wanted" ] && [ -f "$wanted" ]; then
    if [ "$(dirname -- "$wanted")" -ef "$WORK_DIR" ] && ! [ "$wanted" -ef "$SCRIPT_PATH" ] && is_installer_file "$wanted"; then
      takeover_settings "$mode" "$wanted"
      return
    fi
    err "$wanted is not another installer in $WORK_DIR."
    return 1
  fi
  if [ -n "$wanted" ] && [ -d "$wanted" ] && [ "$wanted" -ef "$WORK_DIR" ]; then
    this_folder="true"
    wanted=""
  fi
  if [ -z "$wanted" ]; then
    mapfile -t sibs < <(sibling_installers)
    if [ "${#sibs[@]}" -gt 0 ] && [ "$mode" != "interactive" ]; then
      err "Installers with other settings in this folder: $(for i in "${sibs[@]}"; do printf '%s ' "$(basename -- "$i")"; done)"
      echo "  Name the one that manages this installation, for example: ./$SCRIPT_NAME adopt ./$(basename -- "${sibs[0]}")"
      return 1
    elif [ "${#sibs[@]}" -eq 1 ]; then
      takeover_settings "$mode" "${sibs[0]}"
      return
    elif [ "${#sibs[@]}" -gt 1 ]; then
      echo " Installers with other settings in this folder:"
      for i in "${!sibs[@]}"; do
        printf '   %d) %s\n' "$((i + 1))" "$(basename -- "${sibs[i]}")"
      done
      echo "   0) Cancel"
      read -r -p " Select [1]: " choice || choice="0"
      choice="${choice:-1}"
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#sibs[@]}" ]; then
        takeover_settings "$mode" "${sibs[choice - 1]}"
      else
        info "Cancelled."
      fi
      return
    elif [ "$this_folder" = "true" ]; then
      info "$WORK_DIR is the folder of $SCRIPT_NAME - there is nothing to take over here."
      return 0
    fi
  fi
  while IFS= read -r line; do
    if [ -n "$wanted" ]; then
      IFS='|' read -r project dir cfg envf image status <<< "$line"
      if [ "$dir" != "${wanted%/}" ]; then
        continue
      fi
    fi
    cands+=("$line")
  done < <(find_installations)
  if [ "${#cands[@]}" -eq 0 ] && [ -n "$wanted" ] && [ -d "$wanted" ]; then
    wanted="$(cd -- "$wanted" && pwd -P)"
    for cfg in "$wanted/docker-compose.yml" "$wanted/docker-compose.yaml" "$wanted/compose.yml" "$wanted/compose.yaml"; do
      if [ -f "$cfg" ]; then
        cands+=("$(project_name_of "$(basename -- "$wanted")")|$wanted|$cfg|$wanted/.env||not running")
        break
      fi
    done
  fi
  if [ "${#cands[@]}" -eq 0 ]; then
    info "No other Catalog installation found on this host."
    return 0
  fi

  echo
  echo " Existing Catalog installations:"
  for i in "${!cands[@]}"; do
    IFS='|' read -r project dir cfg envf image status <<< "${cands[i]}"
    version="${image##*:}"
    if [ -z "$image" ]; then
      version="$(env_file_value CATALOG_IMAGE "$envf")"
      version="${version##*:}"
    fi
    printf '   %d) %-40s project %-22s Catalog %-15s %s\n' "$((i + 1))" "$dir" "$project" "${version:-?}" "$status"
  done
  if [ "${#cands[@]}" -eq 1 ]; then
    choice=1
  elif [ "$mode" = "interactive" ]; then
    echo "   0) Cancel"
    read -r -p " Select [1]: " choice || choice="0"
    choice="${choice:-1}"
  else
    err "More than one installation found - give the folder: $SCRIPT_NAME adopt FOLDER"
    return 1
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#cands[@]}" ]; then
    info "Cancelled."
    return 0
  fi
  IFS='|' read -r project dir cfg envf image status <<< "${cands[choice - 1]}"
  if [ ! -r "$cfg" ] || [ ! -r "$envf" ]; then
    err "$cfg or $envf is missing or not readable."
    return 1
  fi

  echo
  echo " Found in $dir:"
  printf '   %-22s %s\n' "Compose file" "$cfg" "Env file" "$envf" "Compose project" "$project" \
    "Catalog version" "$(env_file_value CATALOG_IMAGE "$envf" | sed 's/.*://')" \
    "Catalog Web port" "$(env_file_value CATALOG_WEB_PORT "$envf")" \
    "Nginx Proxy Manager" "$(env_file_value INSTALL_NGINX_PROXY_MANAGER "$envf")" \
    "MongoDB tag" "$(env_file_value MONGO_TAG "$envf")"
  for key in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS; do
    if [ -n "$(env_file_value "$key" "$envf")" ]; then
      printf '   %-22s %s\n' "$key" "found (not shown)"
    else
      printf '   %-22s %s\n' "$key" "missing"
    fi
  done
  echo
  echo " Taking it over copies its .env and docker-compose.yml to $WORK_DIR and writes its values into"
  echo " the settings of $SCRIPT_NAME. The running containers and their data are not touched."
  if [ "$mode" = "interactive" ] && ! confirm "Take over this installation?" y; then
    info "Cancelled."
    return 0
  fi

  backup="$(script_backup)"
  backup_file "$ENV_FILE"
  backup_file "$COMPOSE_FILE"
  (umask 077 && cp -- "$envf" "$ENV_FILE")
  chmod 600 "$ENV_FILE"
  cp -- "$cfg" "$COMPOSE_FILE"

  while IFS= read -r line; do
    line="${line%$'\r'}"
    if ! [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="$(env_unquote "${BASH_REMATCH[2]}")"
    case "$key" in
      MONGO_INITDB_ROOT_PASSWORD|MINIO_ROOT_PASSWORD|RABBITMQ_DEFAULT_PASS|ENV_FILE|COMPOSE_FILE) continue ;;
      CATALOG_IMAGE)
        set_setting CATALOG_IMAGE_REPO "${value%:*}"
        set_setting CATALOG_VERSION "${value##*:}"
        imported=$((imported + 2))
        continue
        ;;
      CATALOG_WORKER_IMAGE)
        set_setting CATALOG_WORKER_IMAGE_REPO "${value%:*}"
        imported=$((imported + 1))
        continue
        ;;
    esac
    if [[ "$value" == *[\"\\\$\`]* ]]; then
      skipped="$skipped $key"
    elif has_setting "$SCRIPT_PATH" "$key"; then
      set_setting "$key" "$value"
      imported=$((imported + 1))
    fi
  done < "$envf"
  if [ "$project" != "$(project_name_of "$(basename -- "$WORK_DIR")")" ]; then
    set_setting COMPOSE_PROJECT_NAME "$project"
    if ! grep -q '^COMPOSE_PROJECT_NAME=' "$ENV_FILE"; then
      printf '\nCOMPOSE_PROJECT_NAME=%s\n' "$project" >> "$ENV_FILE"
    fi
  fi
  if ! bash -n "$SCRIPT_PATH" || ! bash "$SCRIPT_PATH" check-settings; then
    cat -- "$backup" > "$SCRIPT_PATH"
    err "The values of $envf do not fit the settings - nothing was changed in $SCRIPT_NAME."
    return 1
  fi
  ok "Imported $imported settings from $envf; passwords kept in $ENV_FILE."
  if [ -n "$skipped" ]; then
    warn "Not imported (special characters):$skipped"
  fi
  if [ -n "$(sed -n 's/^COMPOSE_PROJECT_NAME="\(.*\)"$/\1/p' "$SCRIPT_PATH")" ]; then
    ok "Compose project \"$project\" is used, so the same containers and volumes stay in use."
  fi

  tmp_env="$(mktemp -d)"
  cp -- "$SCRIPT_PATH" "$tmp_env/rn1-technology-catalog-installer.sh"
  cp -p -- "$ENV_FILE" "$tmp_env/.env"
  (cd -- "$tmp_env" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1) || true
  tmp_compose="$tmp_env/$(basename -- "$COMPOSE_FILE")"
  if [ -f "$tmp_compose" ] && [ "$(cat "$tmp_compose")" = "$(cat "$COMPOSE_FILE")" ]; then
    ok "Its docker-compose.yml is the same as the one this installer generates."
  elif [ -f "$tmp_compose" ]; then
    warn "Its docker-compose.yml differs from the one this installer generates:"
    diff <(grep -E '^[[:space:]]+image:' "$COMPOSE_FILE") <(grep -E '^[[:space:]]+image:' "$tmp_compose") | sed -n 's/^[<>]/   &/p' || true
    echo "   ($(diff "$COMPOSE_FILE" "$tmp_compose" | grep -c '^[<>]' || true) changed lines in total.) Nothing changes until you run option 2 (generate) and 6 (start)."
  fi
  rm -rf -- "$tmp_env"
  echo "  From now on manage the stack from $WORK_DIR. The files in $dir are left as they are."
  if [ "$mode" = "interactive" ]; then
    export RVC_NOTICE="Installation in $dir taken over."
    exec bash "$SCRIPT_PATH" menu
  fi
}

###############################################################################
# User interface
###############################################################################

UI_UTF="false"
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UI_UTF="true" ;;
esac
UI_LINES=0
UI_JOB_SEL=""
UI_HOLD_START=""
UI_HOLD_LAST=""
UI_HOLD_MS=2000
UI_PANEL_W=80
UI_RUNNING_IDS=""
UI_BOX_ROW=0
UI_BOX_COL=0
UI_BOX_HOLD=-1

if [ "$UI_UTF" = "true" ]; then
  UI_TL="╭"; UI_TR="╮"; UI_BL="╰"; UI_BR="╯"; UI_H="─"; UI_V="│"
  UI_FULL="█"; UI_EMPTY="░"; UI_OK="✔"; UI_NO="✖"; UI_DOT="●"; UI_UP="▲"; UI_SEP="·"; UI_ARROW="›"
  UI_HOLD_ON="▰"; UI_HOLD_OFF="▱"
  UI_STAR="★"; UI_MAJOR="⇧"; UI_RARR="→"; UI_HEART="♥"; UI_ON="■"; UI_OFF="□"
  UI_EDIT="✎"; UI_RUN="▶"; UI_VIEW="◉"; UI_DEL="✖"
else
  UI_TL="+"; UI_TR="+"; UI_BL="+"; UI_BR="+"; UI_H="-"; UI_V="|"
  UI_FULL="#"; UI_EMPTY="-"; UI_OK="ok"; UI_NO="x"; UI_DOT="*"; UI_UP="^"; UI_SEP="-"; UI_ARROW=">"
  UI_HOLD_ON="#"; UI_HOLD_OFF="-"
  UI_STAR="*"; UI_MAJOR="^^"; UI_RARR="->"; UI_HEART="<3"; UI_ON="[x]"; UI_OFF="[ ]"
  UI_EDIT="e"; UI_RUN=">"; UI_VIEW="i"; UI_DEL="!"
fi
C_DIM=""
C_CYN=""
C_MAG=""
C_HRT=""
if [ -n "$C_RST" ]; then
  C_DIM=$'\033[2m'
  C_CYN=$'\033[1;36m'
  C_MAG=$'\033[1;35m'
  C_HRT=$'\033[31m'
fi

# Width of sub-screens: the terminal, at most 118 columns.
ui_width() {
  local c
  c="$(ui_cols)"
  if [ "$c" -gt 118 ]; then
    c=118
  fi
  if [ "$c" -lt 60 ]; then
    c=60
  fi
  printf '%s' "$c"
}

# ui_screen TITLE [LINE...] -> clears the terminal (when it is one) and prints the framed header
ui_screen() {
  local title="$1"
  shift
  clear_screen
  ui_box "$(ui_width)" "RAYNET ONE TECHNOLOGY CATALOG $UI_SEP $title" "$@"
  echo
}

# ui_keys "KEY|what it does"... -> one dim hint line with highlighted keys
ui_keys() {
  local spec out=""
  for spec in "$@"; do
    out="$out$C_RST$C_BLD${spec%%|*}$C_RST$C_DIM ${spec#*|}   "
  done
  printf '  %s%s\n' "$C_DIM" "${out%   }$C_RST"
}

# ui_ask VAR PROMPT -> read with the arrow prompt; fails at end of input
ui_ask() {
  local __var="$1" __answer=""
  if ! read -r -p "  $C_CYN$UI_ARROW$C_RST $2 " __answer; then
    printf -v "$__var" '%s' ""
    return 1
  fi
  printf -v "$__var" '%s' "$__answer"
}

# Status text of row_status as a badge: symbol, colour and text.
ui_badge() {
  local text="$1" color="$2" sym="$UI_NO"
  case "$text" in
    "up to date"*) sym="$UI_OK" ;;
    "update available"*) sym="$UI_UP" ;;
    "major update"*) sym="$UI_MAJOR"; color="$C_MAG" ;;
  esac
  printf '%s%s %s%s' "$color" "$sym" "$text" "$C_RST"
}

# "26.3.4789.148 ★ stable" for the version behind the stable tag
ui_version() {
  if [ -n "$HUB_STABLE" ] && [ "$1" = "$HUB_STABLE" ]; then
    printf '%s %s%s stable%s' "$1" "$C_YLW" "$UI_STAR" "$C_RST"
  else
    printf '%s' "$1"
  fi
}

# "2 → 2.19.6" for a floating tag and the version it points to
ui_current() {
  local tag="$1" resolved="$2"
  if [ -n "$resolved" ] && [ "$resolved" != "$tag" ]; then
    printf '%s %s%s%s %s' "$tag" "$C_DIM" "$UI_RARR" "$C_RST" "$(version_core "$resolved")"
  else
    printf '%s' "$tag"
  fi
}

# Pauses after an action in a sub-screen, so its messages can be read before the screen is redrawn.
ui_pause_tty() {
  if [ -t 0 ] && [ -t 1 ]; then
    echo
    read -r -s -n 1 -p "  ${C_DIM}Press any key to continue$C_RST" _ || true
    echo
  fi
}

ui_fancy() {
  [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ "${RVC_UI:-}" != "plain" ]
}

ui_cols() {
  local c
  c="$(tput cols 2>/dev/null)" || c=""
  printf '%s' "${c:-${COLUMNS:-80}}"
}

ui_rows() {
  local r
  r="$(tput lines 2>/dev/null)" || r=""
  printf '%s' "${r:-${LINES:-24}}"
}

ui_repeat() {
  local s="" i
  for ((i = 0; i < $2; i++)); do
    s="$s$1"
  done
  printf '%s' "$s"
}

# Visible length of a string (ANSI color codes do not count).
ui_len() {
  local s
  s="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')"
  printf '%s' "${#s}"
}

# ui_pad TEXT WIDTH -> TEXT cut or padded to exactly WIDTH visible characters
ui_pad() {
  local text="$1" width="$2" len
  len="$(ui_len "$text")"
  if [ "$len" -gt "$width" ]; then
    text="$(printf '%s' "$text" | sed 's/\x1b\[[0-9;]*m//g')"
    printf '%s' "${text:0:$((width - 1))}~"
  else
    printf '%s%s' "$text" "$(ui_repeat ' ' $((width - len)))"
  fi
}

ui_bar() {
  local pct="${1:-0}" width="$2" fill
  pct="${pct%%.*}"
  if ! [[ "$pct" =~ ^[0-9]+$ ]]; then
    pct=0
  fi
  if [ "$pct" -gt 100 ]; then
    pct=100
  fi
  fill=$((pct * width / 100))
  printf '%s%s%s%s' "$C_GRN" "$(ui_repeat "$UI_FULL" "$fill")" "$C_DIM$(ui_repeat "$UI_EMPTY" $((width - fill)))" "$C_RST"
}

# ui_box WIDTH TITLE LINE... -> a rounded box, sets UI_LINES
ui_box() {
  local width="$1" title="$2" line inner
  shift 2
  inner=$((width - 2))
  printf '%s%s %s %s%s\n' "$C_DIM$UI_TL$UI_H$C_RST" "" "$C_BLD$title$C_RST" "$C_DIM$(ui_repeat "$UI_H" $((inner - $(ui_len "$title") - 3)))" "$UI_TR$C_RST"
  for line in "$@"; do
    printf '%s %s %s\n' "$C_DIM$UI_V$C_RST" "$(ui_pad "$line" $((inner - 2)))" "$C_DIM$UI_V$C_RST"
  done
  printf '%s\n' "$C_DIM$UI_BL$(ui_repeat "$UI_H" "$inner")$UI_BR$C_RST"
  UI_LINES=$(($# + 2))
}

# ui_box_line WIDTH TEXT -> one inner line of a ui_box
ui_box_line() {
  printf '%s %s %s' "$C_DIM$UI_V$C_RST" "$(ui_pad "$2" $(($1 - 4)))" "$C_DIM$UI_V$C_RST"
}

ui_noecho() {
  stty -echo 2>/dev/null || true
}

ui_echo() {
  stty echo 2>/dev/null || true
}

ui_now_ms() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then
    t="${EPOCHREALTIME/[.,]/}"
    printf '%s' "$((10#$t / 1000))"
  else
    date +%s%3N
  fi
}

# Hold-to-cancel: call with every key; returns 0 when X was held long enough.
# UI_HOLD_PCT tells how far the hold is (0-100).
UI_HOLD_PCT=0
ui_hold_key() {
  local key="$1" now
  now="$(ui_now_ms)"
  if [ "$key" = "x" ] || [ "$key" = "X" ]; then
    if [ -z "$UI_HOLD_START" ] || [ $((now - UI_HOLD_LAST)) -gt 900 ]; then
      UI_HOLD_START="$now"
    fi
    UI_HOLD_LAST="$now"
  elif [ -n "$UI_HOLD_LAST" ] && [ $((now - UI_HOLD_LAST)) -gt 900 ]; then
    UI_HOLD_START=""
    UI_HOLD_LAST=""
  fi
  if [ -z "$UI_HOLD_START" ]; then
    UI_HOLD_PCT=0
    return 1
  fi
  UI_HOLD_PCT=$(( (now - UI_HOLD_START) * 100 / UI_HOLD_MS ))
  if [ "$UI_HOLD_PCT" -ge 100 ]; then
    UI_HOLD_START=""
    UI_HOLD_LAST=""
    UI_HOLD_PCT=0
    return 0
  fi
  return 1
}

ui_hold_line() {
  local n=$((UI_HOLD_PCT * 12 / 100))
  if [ "$UI_HOLD_PCT" -gt 0 ]; then
    printf '%sCancelling %s%s%s keep holding X%s' "$C_RED" "$(ui_repeat "$UI_HOLD_ON" "$n")" "$C_DIM$(ui_repeat "$UI_HOLD_OFF" $((12 - n)))$C_RST$C_RED" "" "$C_RST"
  else
    printf '%sq back to the menu (the job continues) %s hold X for 2 s to cancel%s' "$C_DIM" "$UI_SEP" "$C_RST"
  fi
}

# The live panel of one job.
ui_job_panel() {
  local id="$1" state="$2" pct="$3" text="$4" width last badge
  width="$(ui_cols)"
  if [ "$width" -gt 100 ]; then
    width=100
  fi
  UI_PANEL_W="$width"
  last="$(grep -v '^[[:space:]]*$' "$JOBS_DIR/$id/log" 2>/dev/null | tail -n 1 | sed 's/\x1b\[[0-9;]*m//g; s/\r.*//; s/^==> //')" || last=""
  case "$state" in
    running) badge="$C_CYN$UI_DOT running$C_RST" ;;
    done) badge="$C_GRN$UI_OK done$C_RST" ;;
    cancelled) badge="$C_YLW$UI_NO cancelled$C_RST" ;;
    *) badge="$C_RED$UI_NO $state$C_RST" ;;
  esac
  ui_box "$width" "Job #$id $UI_SEP $(cat -- "$JOBS_DIR/$id/title")" \
    "$badge   $(if [ -n "$pct" ]; then printf '%s %5s%%' "$(ui_bar "$pct" $((width - 30)))" "$pct"; else printf '%s' "${text:-working}"; fi)" \
    "$(if [ -n "$pct" ]; then printf '%s' "$text"; else printf '%s' ""; fi)" \
    "$C_DIM$UI_ARROW ${last:-...}$C_RST" \
    "$(ui_hold_line)"
}

# Bottom-right "Current processes" box of the menu (at most 9 lines high).
ui_processes_box() {
  local width="$1" id pct text detail state title i first=0 count
  local -a ids=() lines=()
  if [ -n "$UI_RUNNING_IDS" ]; then
    mapfile -t ids <<< "$UI_RUNNING_IDS"
  fi
  count=${#ids[@]}
  if [ "$count" -eq 0 ]; then
    lines=("${C_DIM}No running processes${C_RST}")
    id="$(job_unseen_id)"
    if [ -n "$id" ]; then
      title="$(cat -- "$JOBS_DIR/$id/title")"
      state="$(job_state "$id")"
      lines+=("")
      case "$state" in
        done) lines+=("$C_GRN$UI_OK #$id $title$C_RST" "  ${C_DIM}finished $UI_SEP J shows the result$C_RST") ;;
        *) lines+=("$C_RED$UI_NO #$id $title$C_RST" "  ${C_DIM}$state $UI_SEP J shows the log$C_RST") ;;
      esac
    else
      lines+=("" "${C_DIM}Long tasks run here and keep running$C_RST" "${C_DIM}when you leave or the SSH session ends$C_RST")
    fi
  else
    for i in "${!ids[@]}"; do
      if [ "${ids[i]}" = "$UI_JOB_SEL" ] && [ "$i" -ge 2 ]; then
        first=$((i - 1))
      fi
    done
    for ((i = first; i < count && i < first + 2; i++)); do
      id="${ids[i]}"
      IFS='|' read -r pct text detail < "$JOBS_DIR/$id/progress" 2>/dev/null || { pct=""; text=""; detail=""; }
      title="$(cat -- "$JOBS_DIR/$id/title")"
      if [ "$id" = "$UI_JOB_SEL" ]; then
        lines+=("$C_BLD$UI_ARROW #$id $title$C_RST")
      else
        lines+=("  #$id $title")
      fi
      if [ -n "$pct" ]; then
        lines+=("  $(ui_bar "$pct" $((width - 14))) $(printf '%5s%%' "$pct")")
        if [ "$count" -eq 1 ]; then
          lines+=("  $C_DIM${detail:-$text}$C_RST")
        fi
      else
        lines+=("  $C_DIM${text:-working}$C_RST")
      fi
    done
    if [ "$count" -gt 2 ]; then
      lines+=("  $C_DIM+ $((count - 2)) more $UI_SEP Tab shows them$C_RST")
    fi
    if [ "$UI_HOLD_PCT" -gt 0 ]; then
      lines+=("$(ui_hold_line)")
    elif [ -n "$UI_JOB_SEL" ] && [ -f "$JOBS_DIR/$UI_JOB_SEL/cancel" ]; then
      lines+=("${C_YLW}Cleaning up $UI_SEP hold X again to force$C_RST")
    else
      lines+=("${C_DIM}J follow $UI_SEP Tab select $UI_SEP hold X cancel$C_RST")
    fi
  fi
  ui_box "$width" "Current processes" "${lines[@]}"
}

###############################################################################
# Background jobs
###############################################################################

JOB_DIR=""
JOB_CANCELLED="false"
JOB_CLEANUP=""

# Progress of the running job: PERCENT (empty when unknown), a status text and an optional
# detail (size, speed, remaining time).
job_progress() {
  if [ -n "$JOB_DIR" ] && [ -d "$JOB_DIR" ]; then
    printf '%s|%s|%s\n' "$1" "$2" "${3:-}" > "$JOB_DIR/progress.tmp" && mv -f -- "$JOB_DIR/progress.tmp" "$JOB_DIR/progress"
  elif [ -t 1 ]; then
    printf '\r       %s%s%s    ' "$(if [ -n "$1" ]; then printf '%5s%%  ' "$1"; fi)" "$2" "${3:+ $UI_SEP $3}"
  fi
}

# A status text for the "Current processes" box (only inside a job).
job_step() {
  if [ -n "$JOB_DIR" ]; then
    job_progress "" "$1"
  fi
}

# A secret for a job travels in a file that only the owner can read, never on a command line.
job_secret_take() {
  local value=""
  if [ -n "$JOB_DIR" ] && [ -f "$JOB_DIR/secret" ]; then
    value="$(cat -- "$JOB_DIR/secret")"
    rm -f -- "$JOB_DIR/secret"
  fi
  printf '%s' "$value"
}

fmt_duration() {
  local s="${1:-0}"
  if [ "$s" -ge 3600 ]; then
    printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# Watches a growing amount of bytes (a file size, or "rchar:PID" for bytes read by a process)
# until PID ends and reports percent, size, speed and remaining time.
# job_watch_bytes PID SOURCE TOTAL LABEL
job_watch_bytes() {
  local pid="$1" src="$2" total="$3" label="$4" cur last=0 t0 t1 rate=0 eta pct
  t0="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    cur="$(job_bytes "$src")" || cur=0
    cur="${cur:-0}"
    t1="$(date +%s)"
    if [ "$t1" -gt "$t0" ]; then
      rate=$(( cur / (t1 - t0) ))
    fi
    pct=""
    eta=""
    if [ "${total:-0}" -gt 0 ]; then
      pct="$(awk -v c="$cur" -v t="$total" 'BEGIN { p = c * 100 / t; if (p > 100) p = 100; printf "%.1f", p }')"
      if [ "$rate" -gt 0 ] && [ "$cur" -lt "$total" ]; then
        eta=" $UI_SEP ETA $(fmt_duration $(( (total - cur) / rate )))"
      fi
    fi
    job_progress "$pct" "$label" "$(human_size "$cur")$(if [ "${total:-0}" -gt 0 ]; then printf ' / %s' "$(human_size "$total")"; fi) $UI_SEP $(human_size "$rate")/s$eta"
    last="$cur"
    sleep 1
  done
}

# Bytes so far: a file size, "rchar:PID" (bytes read by PID) or "proc:PID:NAME" (bytes read by
# PID or by its child process NAME, e.g. scp under sshpass).
job_bytes() {
  local src="$1" pid comm
  case "$src" in
    rchar:*)
      pid="${src#rchar:}"
      ;;
    proc:*)
      pid="${src#proc:}"
      comm="${pid#*:}"
      pid="${pid%%:*}"
      if [ "$(cat -- "/proc/$pid/comm" 2>/dev/null)" != "$comm" ]; then
        pid="$(awk -v pp="$pid" -v c="$comm" 'FNR == 1 { name = "" } /^Name:/ { name = $2 } /^PPid:/ && $2 == pp && name == c { split(FILENAME, a, "/"); print a[3]; exit }' /proc/[0-9]*/status 2>/dev/null)" || pid=""
      fi
      ;;
    *)
      stat -c %s -- "$src" 2>/dev/null || echo 0
      return 0
      ;;
  esac
  awk '/^rchar:/ { print $2 }' "/proc/${pid:-0}/io" 2>/dev/null || echo 0
}

# Jobs of one class do not run at the same time (two of them changing the stack would collide).
job_class() {
  case "$1" in
    do_up|do_down|do_restart|do_pull|do_reset|upgrade_run|upgrade_rollback|patch_apply) printf 'stack' ;;
    snapshot_fetch|snapshot_plan_fetch) printf 'snapshot' ;;
    import_upload|import_chain_run|self_sync_run) printf 'import' ;;
  esac
}

# job_busy TITLE [SECRET] -- FUNCTION ... -> number of a running job of the same class
job_busy() {
  local class id
  shift
  if [ "$1" != "--" ]; then
    shift
  fi
  shift
  class="$(job_class "$1")"
  if [ -z "$class" ]; then
    return 0
  fi
  while IFS= read -r id; do
    if [ -n "$id" ] && [ "$(cat -- "$JOBS_DIR/$id/class" 2>/dev/null)" = "$class" ]; then
      printf '%s' "$id"
      return 0
    fi
  done < <(job_running_ids)
}

# Keeps the newest 25 finished jobs.
job_prune() {
  local id
  local -a done_ids=()
  while IFS= read -r id; do
    if [ -n "$id" ] && [ "$(job_state "$id")" != "running" ]; then
      done_ids+=("$id")
    fi
  done < <(job_ids)
  while [ "${#done_ids[@]}" -gt 25 ]; do
    rm -rf -- "${JOBS_DIR:?}/${done_ids[0]}"
    done_ids=("${done_ids[@]:1}")
  done
}

# job_start TITLE [SECRET] -- FUNCTION [ARGS...]: runs FUNCTION in its own session, detached
# from the terminal, so it survives a closed SSH session. Prints the job number.
job_start() {
  local title="$1" secret="" id dir
  shift
  if [ "$1" != "--" ]; then
    secret="$1"
    shift
  fi
  shift
  mkdir -p -- "$JOBS_DIR"
  chmod 700 "$JOBS_DIR"
  job_prune
  id=$(( $(cat -- "$JOBS_DIR/seq" 2>/dev/null || echo 0) + 1 ))
  while ! mkdir -- "$JOBS_DIR/$id" 2>/dev/null; do
    id=$((id + 1))
  done
  echo "$id" > "$JOBS_DIR/seq"
  dir="$JOBS_DIR/$id"
  printf '%s\n' "$title" > "$dir/title"
  date '+%Y-%m-%d %H:%M:%S' > "$dir/started"
  echo "running" > "$dir/state"
  echo "|starting" > "$dir/progress"
  job_class "$1" > "$dir/class"
  if [ -n "$secret" ]; then
    (umask 077 && printf '%s' "$secret" > "$dir/secret")
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$SCRIPT_PATH" __job "$id" "$@" > "$dir/log" 2>&1 < /dev/null &
  else
    nohup bash "$SCRIPT_PATH" __job "$id" "$@" > "$dir/log" 2>&1 < /dev/null &
  fi
  echo "$!" > "$dir/pid"
  printf '%s' "$id"
}

# Entry point of a job process: main -> __job ID FUNCTION ARGS...
job_run() {
  local id="$1"
  shift
  JOB_DIR="$JOBS_DIR/$id"
  INTERACTIVE="false"
  echo "$$" > "$JOB_DIR/pid"
  trap 'job_finish' EXIT
  trap 'job_on_signal' TERM INT HUP
  "$@"
}

job_on_signal() {
  trap '' TERM INT HUP
  JOB_CANCELLED="true"
  job_progress "" "cancelling"
  echo
  echo "Cancel requested."
  kill -TERM -- "-$$" 2>/dev/null || true
  kill -TERM $(jobs -p) 2>/dev/null || true
  exit 130
}

# EXIT trap of a job: a cancelled or failed job runs its JOB_CLEANUP first.
job_finish() {
  local rc=$? state
  trap '' TERM INT HUP
  if [ "$rc" -ne 0 ] && [ -n "$JOB_CLEANUP" ]; then
    job_progress "" "cleaning up"
    $JOB_CLEANUP || true
  fi
  if [ "$JOB_CANCELLED" = "true" ]; then
    state="cancelled"
  elif [ "$rc" -eq 0 ]; then
    state="done"
  else
    state="failed"
  fi
  rm -f -- "$JOB_DIR/secret"
  echo "$rc" > "$JOB_DIR/exit"
  date '+%Y-%m-%d %H:%M:%S' > "$JOB_DIR/ended"
  if [ "$state" = "done" ]; then
    job_progress "100" "finished"
  fi
  echo "$state" > "$JOB_DIR/state"
}

job_state() {
  local dir="$JOBS_DIR/$1" state pid
  state="$(cat -- "$dir/state" 2>/dev/null)" || state="unknown"
  if [ "$state" = "running" ]; then
    pid="$(cat -- "$dir/pid" 2>/dev/null)" || pid=""
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      sleep 0.3
      state="$(cat -- "$dir/state" 2>/dev/null)" || state="unknown"
      pid="$(cat -- "$dir/pid" 2>/dev/null)" || pid=""
      if [ "$state" = "running" ] && { [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; }; then
        state="stopped"
      fi
    fi
  fi
  printf '%s' "$state"
}

# job_cancel ID [wait|nowait]: the job cleans up first (partial files, previous state);
# a second cancel stops it at once.
job_cancel() {
  local id="$1" mode="${2:-wait}" dir="$JOBS_DIR/$1" pid i
  pid="$(cat -- "$dir/pid" 2>/dev/null)" || pid=""
  if [ "$(job_state "$id")" != "running" ] || [ -z "$pid" ]; then
    warn "Job #$id is not running."
    return 1
  fi
  if [ -f "$dir/cancel" ]; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    echo "cancelled" > "$dir/state"
    warn "Job #$id stopped at once (without cleaning up)."
    return 0
  fi
  touch "$dir/cancel"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  if [ "$mode" = "nowait" ]; then
    return 0
  fi
  info "Cancelling job #$id - it removes partial files and restores the previous state first."
  for i in $(seq 1 1200); do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "Job #$id is still cleaning up - cancel it again to stop it at once."
    return 1
  fi
  ok "Job #$id cancelled."
}

job_ids() {
  local d
  for d in "$JOBS_DIR"/*/; do
    if [ -f "$d/title" ]; then
      d="${d%/}"
      printf '%s\n' "${d##*/}"
    fi
  done | sort -n
}

job_running_ids() {
  local id
  while IFS= read -r id; do
    if [ -n "$id" ] && [ "$(job_state "$id")" = "running" ]; then
      printf '%s\n' "$id"
    fi
  done < <(job_ids)
}

job_summary() {
  local id="$1" pct text detail
  IFS='|' read -r pct text detail < "$JOBS_DIR/$id/progress" 2>/dev/null || { pct=""; text=""; detail=""; }
  printf '%s%s%s' "$(if [ -n "$pct" ]; then printf '%s%%  ' "$pct"; fi)" "$text" "${detail:+ $UI_SEP $detail}"
}

# Live view of a job. q: back to the menu (the job continues), hold X: cancel.
job_follow() {
  local id="$1" dir="$JOBS_DIR/$1" state pct text detail key shown=0 n lines=0 last_draw=0 now
  UI_HOLD_START=""
  UI_HOLD_PCT=0
  if [ ! -d "$dir" ]; then
    err "Job #$id not found."
    return 1
  fi
  if ! ui_fancy; then
    while true; do
      state="$(job_state "$id")"
      n="$(wc -l < "$dir/log" 2>/dev/null)" || n=0
      if [ "$n" -gt "$shown" ]; then
        sed -n "$((shown + 1)),${n}p" "$dir/log"
        shown="$n"
      fi
      if [ "$state" != "running" ]; then
        n="$(wc -l < "$dir/log" 2>/dev/null)" || n=0
        if [ "$n" -gt "$shown" ]; then
          sed -n "$((shown + 1)),${n}p" "$dir/log"
        fi
        break
      fi
      sleep 1
    done
    job_report "$id"
    [ "$(job_state "$id")" = "done" ]
    return
  fi
  tput civis 2>/dev/null || true
  ui_noecho
  while true; do
    state="$(job_state "$id")"
    now="$(ui_now_ms)"
    if [ "$state" != "running" ] || { [ "$UI_HOLD_PCT" -eq 0 ] && [ $((now - last_draw)) -ge 500 ]; }; then
      IFS='|' read -r pct text detail < "$dir/progress" 2>/dev/null || { pct=""; text=""; detail=""; }
      if [ "$lines" -gt 0 ]; then
        printf '\033[%dA\033[J' "$lines"
      fi
      ui_job_panel "$id" "$state" "$pct" "$text${detail:+ $UI_SEP $detail}"
      lines="$UI_LINES"
      last_draw="$now"
    elif [ "$UI_HOLD_PCT" -gt 0 ] && [ "$lines" -gt 0 ]; then
      printf '\033[2A\r%s\033[2B\r' "$(ui_box_line "$UI_PANEL_W" "$(ui_hold_line)")"
      last_draw=0
    fi
    if [ "$state" != "running" ]; then
      break
    fi
    key=""
    read -rsn1 -t 0.1 key || true
    if ui_hold_key "$key"; then
      job_cancel "$id" nowait >/dev/null 2>&1 || true
      continue
    fi
    case "$key" in
      q|Q)
        tput cnorm 2>/dev/null || true
        ui_echo
        echo
        info "Job #$id keeps running in the background - the menu shows it under Current processes."
        return 3
        ;;
    esac
  done
  tput cnorm 2>/dev/null || true
  ui_echo
  job_report "$id"
  [ "$(job_state "$id")" = "done" ]
}

job_report() {
  local id="$1" dir="$JOBS_DIR/$1" state
  state="$(job_state "$id")"
  echo
  case "$state" in
    done) ok "Job #$id finished: $(cat -- "$dir/title")" ;;
    cancelled) warn "Job #$id was cancelled: $(cat -- "$dir/title")" ;;
    *)
      err "Job #$id $state: $(cat -- "$dir/title")"
      if ui_fancy; then
        echo "  Last lines of its log:"
        tail -n 15 "$dir/log" | sed 's/^/    /'
      fi
      ;;
  esac
  touch "$dir/seen"
}

job_state_color() {
  case "$1" in
    running) printf '%s' "$C_CYN" ;;
    done) printf '%s' "$C_GRN" ;;
    cancelled) printf '%s' "$C_YLW" ;;
    *) printf '%s' "$C_RED" ;;
  esac
}

jobs_list() {
  local id state
  if [ -z "$(job_ids)" ]; then
    echo "   No jobs yet."
    return 0
  fi
  printf '   %s\n' "$C_DIM$(printf '%-5s %-10s %-19s %s' "#" "STATE" "STARTED" "TASK")$C_RST"
  while IFS= read -r id; do
    state="$(job_state "$id")"
    printf '   %-5s %s %-19s %s  %s\n' "$id" "$(job_state_color "$state")$(printf '%-10s' "$state")$C_RST" "$(cat -- "$JOBS_DIR/$id/started")" "$(cat -- "$JOBS_DIR/$id/title")" "$(if [ "$state" = "running" ]; then job_summary "$id"; fi)"
    if [ "$state" != "running" ]; then
      touch "$JOBS_DIR/$id/seen"
    fi
  done < <(job_ids | tail -n 15)
}

# Newest finished job nobody has looked at yet.
job_unseen_id() {
  local id last=""
  while IFS= read -r id; do
    if [ -n "$id" ] && [ ! -f "$JOBS_DIR/$id/seen" ] && [ "$(job_state "$id")" != "running" ]; then
      last="$id"
    fi
  done < <(job_ids)
  printf '%s' "$last"
}

jobs_menu() {
  local choice id
  while true; do
    echo
    ui_box "$(ui_width)" "Jobs" "Long tasks run as jobs: they keep running when you leave the menu or the SSH session ends."
    jobs_list
    echo
    ui_keys "f N|follow" "c N|cancel" "l N|log" "d|delete finished jobs" "0|back"
    ui_ask choice "Command:" || choice="0"
    id="${choice#* }"
    case "$choice" in
      f\ *|F\ *) job_follow "$id" || true ;;
      c\ *|C\ *) if confirm "Cancel job #$id ($(cat -- "$JOBS_DIR/$id/title" 2>/dev/null))?" n; then job_cancel "$id" || true; fi ;;
      l\ *|L\ *) if [ -f "$JOBS_DIR/$id/log" ]; then page cat -- "$JOBS_DIR/$id/log"; fi ;;
      d|D)
        while IFS= read -r id; do
          if [ "$(job_state "$id")" != "running" ]; then
            rm -rf -- "${JOBS_DIR:?}/$id"
          fi
        done < <(job_ids)
        ok "Finished jobs deleted."
        ;;
      0|"") return 0 ;;
      *) warn "Unknown entry: $choice" ;;
    esac
  done
}

jobs_cli() {
  local action="${1:-list}" id="${2:-}"
  case "$action" in
    list) jobs_list ;;
    follow) job_follow "$id" ;;
    cancel) job_cancel "$id" ;;
    log) cat -- "$JOBS_DIR/$id/log" ;;
    *) err "Usage: $SCRIPT_NAME jobs [list | follow N | cancel N | log N]"; return 2 ;;
  esac
}

# Runs FUNCTION as a job and follows it: run_job TITLE [SECRET] -- FUNCTION ARGS...
run_job() {
  local id busy
  if [ -z "$SCRIPT_PATH" ]; then
    shift
    if [ "$1" != "--" ]; then
      shift
    fi
    shift
    "$@"
    return
  fi
  busy="$(job_busy "$@")"
  if [ -n "$busy" ]; then
    err "Job #$busy ($(cat -- "$JOBS_DIR/$busy/title")) is still running - follow or cancel it first (J)."
    return 1
  fi
  id="$(job_start "$@")"
  info "Started as job #$id - it keeps running when you leave this view or the SSH session ends."
  job_follow "$id"
}

###############################################################################
# Time zone
###############################################################################

# The Catalog runs AUTOSYNC_CRON and VULNERABILITIES_CACHING_CRON in the local time of its
# containers (TimeZoneInfo.Local), and that is TZ.
TZ_KEEP_FILE="$WORK_DIR/.timezone-kept"

tz_valid() {
  if ! [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]]; then
    return 1
  fi
  if [ -d /usr/share/zoneinfo ]; then
    [ -f "/usr/share/zoneinfo/$1" ]
  fi
}

# Time zone of this server (empty when it cannot be read).
host_timezone() {
  local tz=""
  if command -v timedatectl >/dev/null 2>&1; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null)" || tz=""
  fi
  if [ -z "$tz" ] && [ -L /etc/localtime ]; then
    tz="$(readlink /etc/localtime 2>/dev/null)" || tz=""
    case "$tz" in
      */zoneinfo/*)
        tz="${tz#*/zoneinfo/}"
        tz="${tz#posix/}"
        tz="${tz#right/}"
        ;;
      *) tz="" ;;
    esac
  fi
  if [ -z "$tz" ] && [ -r /etc/timezone ]; then
    tz="$(head -n 1 /etc/timezone | tr -d ' \r')"
  fi
  tz="${tz#posix/}"
  tz="${tz#right/}"
  if [[ "$tz" =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]]; then
    printf '%s' "$tz"
  fi
}

# Zone name without posix/ or right/; UTC for its other names and for an empty TZ (the containers
# then run in UTC).
tz_canonical() {
  local z="${1#posix/}"
  z="${z#right/}"
  case "$z" in
    ""|UTC|UCT|Universal|Zulu|GMT|GMT0|GMT+0|GMT-0|Greenwich|Etc/UTC|Etc/UCT|Etc/Universal|Etc/Zulu|Etc/GMT|Etc/GMT0|Etc/GMT+0|Etc/GMT-0|Etc/Greenwich) printf 'UTC' ;;
    *) printf '%s' "$z" ;;
  esac
}

# A zone this server can calculate with (date silently treats unknown names as UTC).
tz_known() {
  local z
  z="$(tz_canonical "$1")"
  [ "$z" = "UTC" ] || { tz_valid "$z" && [ -f "/usr/share/zoneinfo/$z" ]; }
}

# The same zone: the same name, both UTC, or names of the same zone data (links such as
# Europe/Bratislava and Europe/Prague).
tz_same() {
  local a b
  a="$(tz_canonical "$1")"
  b="$(tz_canonical "$2")"
  [ "$a" = "$b" ] || { [ -f "/usr/share/zoneinfo/$a" ] && [ -f "/usr/share/zoneinfo/$b" ] && cmp -s "/usr/share/zoneinfo/$a" "/usr/share/zoneinfo/$b"; }
}

# tz_offset_min TZ EPOCH -> UTC offset in minutes
tz_offset_min() {
  local z
  z="$(TZ="$1" date -d "@$2" +%z 2>/dev/null)" || return 1
  if ! [[ "$z" =~ ^[+-][0-9]{4}$ ]]; then
    return 1
  fi
  if [ "${z:0:1}" = "-" ]; then
    printf '%s' "$(( -(10#${z:1:2} * 60 + 10#${z:3:2}) ))"
  else
    printf '%s' "$(( 10#${z:1:2} * 60 + 10#${z:3:2} ))"
  fi
}

# cron_values FIELD MIN MAX -> the numbers of a cron field, one per line
cron_values() {
  local field="$1" min="$2" max="$3" part range step a b v
  local -a parts=()
  IFS=',' read -r -a parts <<< "$field"
  if [ "${#parts[@]}" -eq 0 ]; then
    return 1
  fi
  for part in "${parts[@]}"; do
    step=1
    range="$part"
    if [[ "$part" == */* ]]; then
      step="${part#*/}"
      range="${part%%/*}"
    fi
    if ! [[ "$step" =~ ^[0-9]+$ ]] || [ "$((10#$step))" -eq 0 ]; then
      return 1
    fi
    step=$((10#$step))
    case "$range" in
      "*"|"?") a="$min"; b="$max" ;;
      *-*) a="${range%%-*}"; b="${range#*-}" ;;
      *)
        a="$range"
        b="$range"
        if [[ "$part" == */* ]]; then
          b="$max"
        fi
        ;;
    esac
    if ! [[ "$a" =~ ^[0-9]+$ ]] || ! [[ "$b" =~ ^[0-9]+$ ]]; then
      return 1
    fi
    a=$((10#$a))
    b=$((10#$b))
    if [ "$a" -lt "$min" ] || [ "$b" -gt "$max" ] || [ "$a" -gt "$b" ]; then
      return 1
    fi
    for ((v = a; v <= b; v += step)); do
      printf '%s\n' "$v"
    done
  done
}

cron_range() {
  if [ "$1" -eq "$2" ]; then
    printf '%s' "$1"
  elif [ "$2" -eq $(($1 + 1)) ]; then
    printf '%s,%s' "$1" "$2"
  else
    printf '%s-%s' "$1" "$2"
  fi
}

# cron_list NUMBER... -> sorted, without duplicates, consecutive numbers as ranges ("2-6", "6,14,22")
cron_list() {
  local out="" v start="" prev=""
  local -a vals=()
  mapfile -t vals < <(printf '%s\n' "$@" | sort -n -u)
  for v in "${vals[@]}"; do
    if [ -z "$start" ]; then
      start="$v"
    elif [ "$v" -ne $((prev + 1)) ]; then
      out="$out,$(cron_range "$start" "$prev")"
      start="$v"
    fi
    prev="$v"
  done
  out="$out,$(cron_range "$start" "$prev")"
  printf '%s' "${out#,}"
}

cron_wild() {
  [ "$1" = "*" ] || [ "$1" = "?" ]
}

# cron_convert EXPR FROM_TZ TO_TZ [DATE] -> the expression that runs in TO_TZ at the same moments
# as EXPR in FROM_TZ, with the UTC offsets of DATE (default: today). Fails when one cron
# expression cannot express that (for example a day of the month that moves to the next day).
cron_convert() {
  local expr="$1" from="$2" to="$3" day="${4:-}" m h dom mon dow extra epoch off_from off_to delta
  local list hh mm t sd shift="" mixed="false" newm="" newh newdow v d
  local -a hours=() days=()
  if [ "$expr" = "-" ]; then
    printf '%s' "-"
    return 0
  fi
  read -r m h dom mon dow extra <<< "$expr"
  if [ -z "$dow" ] || [ -n "$extra" ] || ! tz_known "$from" || ! tz_known "$to"; then
    return 1
  fi
  from="$(tz_canonical "$from")"
  to="$(tz_canonical "$to")"
  day="${day:-$(date +%F)}"
  epoch="$(TZ="$from" date -d "$day 12:00" +%s 2>/dev/null)" || return 1
  off_from="$(tz_offset_min "$from" "$epoch")" || return 1
  off_to="$(tz_offset_min "$to" "$epoch")" || return 1
  delta=$((off_to - off_from))
  if [ "$delta" -eq 0 ]; then
    printf '%s' "$expr"
    return 0
  fi
  mm=0
  if [ $((delta % 60)) -ne 0 ]; then
    if ! [[ "$m" =~ ^[0-9]+$ ]] || [ "$((10#$m))" -gt 59 ]; then
      return 1
    fi
    mm=$((10#$m))
  fi
  list="$(cron_values "$h" 0 23)" || return 1
  for hh in $list; do
    t=$((hh * 60 + mm + delta))
    if [ "$t" -ge 0 ]; then
      sd=$((t / 1440))
    else
      sd=$((-((1439 - t) / 1440)))
    fi
    t=$((t - sd * 1440))
    newm=$((t % 60))
    hours+=("$((t / 60))")
    if [ -z "$shift" ]; then
      shift="$sd"
    elif [ "$shift" != "$sd" ]; then
      mixed="true"
    fi
  done
  if [ $((delta % 60)) -eq 0 ]; then
    newm="$m"
  fi
  if [ "$h" = "*" ]; then
    newh="*"
  else
    newh="$(cron_list "${hours[@]}")"
  fi
  newdow="$dow"
  if ! cron_wild "$dom" || ! cron_wild "$mon" || ! cron_wild "$dow"; then
    if [ "$mixed" = "true" ]; then
      return 1
    fi
    if [ "$shift" != "0" ]; then
      if ! cron_wild "$dom" || ! cron_wild "$mon"; then
        return 1
      fi
      d="${dow^^}"
      d="${d//SUN/0}"; d="${d//MON/1}"; d="${d//TUE/2}"; d="${d//WED/3}"
      d="${d//THU/4}"; d="${d//FRI/5}"; d="${d//SAT/6}"
      list="$(cron_values "$d" 0 7)" || return 1
      for v in $list; do
        days+=("$((((v % 7 + shift) % 7 + 7) % 7))")
      done
      newdow="$(cron_list "${days[@]}")"
    fi
  fi
  printf '%s %s %s %s %s' "$newm" "$newh" "$dom" "$mon" "$newdow"
}

# "07:30" for a cron expression with one fixed time, otherwise the expression itself.
cron_time_text() {
  local m h rest
  read -r m h rest <<< "$1"
  if [[ "$m" =~ ^[0-9]+$ ]] && [[ "$h" =~ ^[0-9]+$ ]]; then
    printf '%02d:%02d' "$((10#$h))" "$((10#$m))"
  else
    printf '"%s"' "$1"
  fi
}

# When the two zones do not change their clocks on the same dates, tells which times in the old
# zone the converted time stands for during the year (sampled on the 1st and 15th of each month).
tz_season_note() {
  local from="$1" to="$2" m h rest y mon dd epoch t times=""
  read -r m h rest <<< "$3"
  if ! [[ "$m" =~ ^[0-9]+$ ]] || ! [[ "$h" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  y="$(date +%Y)"
  for mon in 01 02 03 04 05 06 07 08 09 10 11 12; do
    for dd in 01 15; do
      epoch="$(TZ="$to" date -d "$y-$mon-$dd $((10#$h)):$((10#$m))" +%s 2>/dev/null)" || return 0
      t="$(TZ="$from" date -d "@$epoch" +%H:%M 2>/dev/null)" || return 0
      if [[ " $times " != *" $t "* ]]; then
        times="$times $t"
      fi
    done
  done
  times="${times# }"
  if [ "$times" != "${times%% *}" ]; then
    echo "    $from and $to change their clocks on different dates, so $(cron_time_text "$3") $to is ${times// / or } $from depending on the date."
  fi
}

cron_label() {
  case "$1" in
    AUTOSYNC_CRON) printf 'daily synchronization' ;;
    VULNERABILITIES_CACHING_CRON) printf 'vulnerability caching' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Offers TZ = time zone of this server and converts the cron settings, so that the jobs keep
# running at the same moments. "force" asks again after an earlier "no".
tz_offer_alignment() {
  local force="${1:-}" host from name value newval spec question copy answer backup sib default="y" hint="[Y/n]"
  local -a changes=()
  TZ_CHANGED="false"
  reload_settings
  host="$(host_timezone)"
  if [ -z "$host" ]; then
    if [ "$force" = "force" ]; then
      warn "The time zone of this server could not be read (timedatectl, /etc/localtime, /etc/timezone)."
    fi
    return 0
  fi
  if tz_same "$host" "$TZ"; then
    if [ "$force" = "force" ]; then
      ok "TZ (${TZ:-empty, UTC}) is the time zone of this server."
    fi
    return 0
  fi
  if [ "$force" != "force" ] && [ -f "$TZ_KEEP_FILE" ] && [ "$(cat -- "$TZ_KEEP_FILE")" = "$TZ|$host" ]; then
    return 0
  fi
  sib="$(conflicting_sibling)"
  if [ -n "$sib" ]; then
    if [ "$force" = "force" ]; then
      warn "$(basename -- "$sib") in this folder has other settings than $SCRIPT_NAME - settle that first. $(sibling_advice "$sib")"
    fi
    return 0
  fi
  from="${TZ:-UTC}"
  echo
  warn "This server runs in the time zone $host, the Catalog is set to $from (TZ)."
  if ! tz_known "$from" || ! tz_known "$host"; then
    if [ -f /usr/share/zoneinfo/Europe/Berlin ]; then
      warn "    $(tz_missing_names "$from" "$host") is not a time zone this server knows (a misspelling, or a legacy name from tzdata-legacy), so"
    else
      warn "    This server has no time zone data for $(tz_missing_names "$from" "$host") (packages tzdata, tzdata-legacy), so"
    fi
    warn "    the job times cannot be converted. TZ stays $from; change TZ and AUTOSYNC_CRON together in option 1 if needed."
    return 0
  fi
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    warn "    ${SCRIPT_PATH:-This installer} cannot be changed (not a writable file) - TZ stays $from."
    return 0
  fi
  question="Change TZ to $host"
  for name in AUTOSYNC_CRON VULNERABILITIES_CACHING_CRON; do
    value="${!name}"
    if [ "$value" = "-" ]; then
      continue
    fi
    if newval="$(cron_convert "$value" "$from" "$host")"; then
      echo "    The $(cron_label "$name") ($name \"$value\") runs at $(cron_time_text "$value") $from, that is $(cron_time_text "$newval") $host."
      tz_season_note "$from" "$host" "$newval"
      if [ "$newval" != "$value" ]; then
        changes+=("$name|$newval")
        question="$question and $name to \"$newval\""
      fi
    else
      warn "    $name \"$value\" cannot be converted automatically - check it after the change (option 1)."
    fi
  done
  # An existing installation changes only on an explicit yes.
  if [ -f "$ENV_FILE" ]; then
    default="n"
    hint="[y/N]"
  fi
  if ! read -r -p "$question? $hint " answer; then
    echo
    info "No answer - nothing was changed."
    return 0
  fi
  case "${answer:-$default}" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *)
      printf '%s|%s\n' "$TZ" "$host" > "$TZ_KEEP_FILE"
      info "TZ stays $from. This is not asked again for $host ('./$SCRIPT_NAME timezone' asks again)."
      return 0
      ;;
  esac
  copy="$(mktemp)"
  if ! cp -- "$SCRIPT_PATH" "$copy" || ! set_setting TZ "$host" "$copy"; then
    rm -f -- "$copy"
    err "Nothing was changed."
    return 1
  fi
  for spec in ${changes[@]+"${changes[@]}"}; do
    if ! set_setting "${spec%%|*}" "${spec#*|}" "$copy"; then
      rm -f -- "$copy"
      err "Nothing was changed."
      return 1
    fi
  done
  if ! backup="$(script_backup)"; then
    rm -f -- "$copy"
    err "Cannot write next to $SCRIPT_PATH - nothing was changed."
    return 1
  fi
  if ! cat -- "$copy" > "$SCRIPT_PATH"; then
    rm -f -- "$copy"
    cat -- "$backup" > "$SCRIPT_PATH" 2>/dev/null || true
    err "Cannot write $SCRIPT_PATH. If it is damaged, the previous version is $backup."
    return 1
  fi
  rm -f -- "$copy" "$backup"
  TZ="$host"
  for spec in ${changes[@]+"${changes[@]}"}; do
    printf -v "${spec%%|*}" '%s' "${spec#*|}"
  done
  rm -f -- "$TZ_KEEP_FILE"
  TZ_CHANGED="true"
  ok "TZ is now $host$(if [ "${#changes[@]}" -gt 0 ]; then printf ' - the jobs keep their times'; fi)."
}

# A TZ this server has no data for, while it has zone data: most likely a misspelled name, and the
# containers would quietly run in UTC.
tz_name_warning() {
  if [ -n "$TZ" ] && ! tz_known "$TZ" && [ -f /usr/share/zoneinfo/Europe/Berlin ]; then
    warn "TZ \"$TZ\" is not a time zone this server knows - check the spelling (option 1); with an unknown name the containers run in UTC."
  fi
}

tz_missing_names() {
  local z out=""
  for z in "$@"; do
    if ! tz_known "$z"; then
      out="$out${out:+ and }$z"
    fi
  done
  printf '%s' "$out"
}

tz_menu_note() {
  local host
  host="$(host_timezone)"
  if [ -z "$host" ] || tz_same "$host" "$TZ" || ! tz_known "$host" || ! tz_known "$TZ" || [ ! -w "$SCRIPT_PATH" ] || [ -n "$(conflicting_sibling)" ]; then
    return 0
  fi
  if [ -f "$TZ_KEEP_FILE" ] && [ "$(cat -- "$TZ_KEEP_FILE")" = "$TZ|$host" ]; then
    return 0
  fi
  printf 'The server runs in %s, the Catalog in %s (TZ) - option 2 offers to align it' "$host" "${TZ:-UTC}"
}

timezone_cli() {
  INTERACTIVE="true"
  tz_offer_alignment force
  if [ "$TZ_CHANGED" = "true" ] && [ -f "$ENV_FILE" ]; then
    echo "  Apply it with option 2 and 6, or: ./$SCRIPT_NAME generate && ./$SCRIPT_NAME up"
  fi
}

###############################################################################
# Generate .env and docker-compose.yml
###############################################################################

check_settings() {
  local problems=0 name value seen=" "
  case "$INSTALL_NGINX_PROXY_MANAGER" in
    true|false) ;;
    *)
      err "INSTALL_NGINX_PROXY_MANAGER must be \"true\" or \"false\" (is \"$INSTALL_NGINX_PROXY_MANAGER\")."
      problems=$((problems + 1))
      ;;
  esac
  for name in $(port_settings); do
    value="${!name}"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
      err "$name must be a port number between 1 and 65535 (is \"$value\")."
      problems=$((problems + 1))
    elif [[ "$seen" == *" $value "* ]]; then
      err "$name: host port $value is used by more than one setting."
      problems=$((problems + 1))
    fi
    seen="${seen}${value} "
  done
  if [ -n "$COMPOSE_PROJECT_NAME" ] && ! [[ "$COMPOSE_PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    err "COMPOSE_PROJECT_NAME may only contain lower-case letters, digits, - and _ (is \"$COMPOSE_PROJECT_NAME\")."
    problems=$((problems + 1))
  fi
  if [ -z "$CATALOG_VERSION" ]; then
    err "CATALOG_VERSION must not be empty."
    problems=$((problems + 1))
  fi
  if ! [[ "${SYNC_MAX_UPLOAD:-}" =~ ^[0-9]+(GB|MB|KB)?$ ]]; then
    err "SYNC_MAX_UPLOAD must be a size like 32GB, 8000MB or a number of bytes (is \"${SYNC_MAX_UPLOAD:-}\")."
    problems=$((problems + 1))
  fi
  [ "$problems" -eq 0 ]
}

write_env_file() {
  : > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  cat > "$ENV_FILE" <<EOF
# General
TZ=${TZ}
BASEURL=${BASEURL}

# Enable / Disable optional services
INSTALL_NGINX_PROXY_MANAGER=${INSTALL_NGINX_PROXY_MANAGER}

# Image Tags
NGINX_PROXY_MANAGER_TAG=${NGINX_PROXY_MANAGER_TAG}
OPENSEARCH_TAG=${OPENSEARCH_TAG}
OPENSEARCH_DASHBOARDS_TAG=${OPENSEARCH_DASHBOARDS_TAG}
MONGO_TAG=${MONGO_TAG}
MINIO_TAG=${MINIO_TAG}
RABBITMQ_TAG=${RABBITMQ_TAG}
CATALOG_IMAGE=${CATALOG_IMAGE_REPO}:${CATALOG_VERSION}
CATALOG_WORKER_IMAGE=${CATALOG_WORKER_IMAGE_REPO}:${CATALOG_VERSION}

# Mongo
MONGO_INITDB_ROOT_USERNAME=${MONGO_INITDB_ROOT_USERNAME}
MONGO_INITDB_ROOT_PASSWORD=${MONGO_INITDB_ROOT_PASSWORD}
MONGO_INITDB_DATABASE=${MONGO_INITDB_DATABASE}
MONGO_AUTH_DATABASE=${MONGO_AUTH_DATABASE}
MONGO_PORT_HOST=${MONGO_PORT_HOST}

# MinIO
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
MINIO_API_PORT_HOST=${MINIO_API_PORT_HOST}
MINIO_CONSOLE_PORT_HOST=${MINIO_CONSOLE_PORT_HOST}
MINIO_PORT_CONTAINER=${MINIO_PORT_CONTAINER}

# RabbitMQ
RABBITMQ_DEFAULT_USER=${RABBITMQ_DEFAULT_USER}
RABBITMQ_DEFAULT_PASS=${RABBITMQ_DEFAULT_PASS}
RABBITMQ_AMQP_PORT=${RABBITMQ_AMQP_PORT}
RABBITMQ_UI_PORT=${RABBITMQ_UI_PORT}

# Catalog / App
CATALOG_WEB_PORT=${CATALOG_WEB_PORT}
CATALOG_LICENSE_PATH=${CATALOG_LICENSE_PATH}

# OpenSearch
OPENSEARCH_HEAP=${OPENSEARCH_HEAP}
OPENSEARCH_URL=${OPENSEARCH_URL}
OPENSEARCH_DASHBOARDS_PORT=${OPENSEARCH_DASHBOARDS_PORT}

# Nginx Proxy Manager
NPM_HTTP_PORT=${NPM_HTTP_PORT}
NPM_HTTPS_PORT=${NPM_HTTPS_PORT}
NPM_ADMIN_PORT=${NPM_ADMIN_PORT}
X_FRAME_OPTIONS=${X_FRAME_OPTIONS}
DISABLE_IPV6=${DISABLE_IPV6}

# Shared app config
QUEUE_PREFIX=${QUEUE_PREFIX}
FILESTORAGE_BUCKET=${FILESTORAGE_BUCKET}
FILESTORAGE_LOCATION=${FILESTORAGE_LOCATION}
AUTOSYNC_CRON=${AUTOSYNC_CRON}
EOF
  if ! catalog_fixed_upload_limit "$CATALOG_VERSION"; then
    printf 'SYNC_MAX_UPLOAD=%s\n' "$SYNC_MAX_UPLOAD" >> "$ENV_FILE"
  fi
  cat >> "$ENV_FILE" <<EOF
VULNERABILITIES_CACHING_CRON=${VULNERABILITIES_CACHING_CRON}
ASPNETCORE_URLS=${ASPNETCORE_URLS}
ASPNETCORE_HTTP_PORTS=${ASPNETCORE_HTTP_PORTS}
LOG_LEVEL_DEFAULT=${LOG_LEVEL_DEFAULT}
EOF
  if [ -n "$COMPOSE_PROJECT_NAME" ]; then
    printf '\nCOMPOSE_PROJECT_NAME=%s\n' "$COMPOSE_PROJECT_NAME" >> "$ENV_FILE"
  fi
}

write_compose_file() {
  {
    echo "services:"

    if [ "${INSTALL_NGINX_PROXY_MANAGER}" = "true" ]; then
      cat <<'EOF'
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:${NGINX_PROXY_MANAGER_TAG}
    hostname: nginx-proxy-manager
    restart: always
    environment:
      X_FRAME_OPTIONS: "${X_FRAME_OPTIONS}"
      DISABLE_IPV6: "${DISABLE_IPV6}"
    volumes:
      - npm_data:/data
      - npm_letsencrypt:/etc/letsencrypt
    ports:
      - "${NPM_HTTP_PORT}:80"
      - "${NPM_ADMIN_PORT}:81"
      - "${NPM_HTTPS_PORT}:443"

EOF
    fi

    cat <<'EOF'
  opensearch:
    image: opensearchproject/opensearch:${OPENSEARCH_TAG}
    container_name: opensearch
    environment:
      cluster.name: opensearch
      node.name: opensearch
      discovery.type: single-node
      bootstrap.memory_lock: "true"
      OPENSEARCH_JAVA_OPTS: "${OPENSEARCH_HEAP}"
      DISABLE_INSTALL_DEMO_CONFIG: "true"
      DISABLE_SECURITY_PLUGIN: "true"
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - opensearch_data:/usr/share/opensearch/data

  opensearch-dashboards:
    image: opensearchproject/opensearch-dashboards:${OPENSEARCH_DASHBOARDS_TAG}
    container_name: opensearch-dashboards
    ports:
      - "${OPENSEARCH_DASHBOARDS_PORT}:5601"
    expose:
      - "5601"
    depends_on:
      - opensearch
    environment:
      OPENSEARCH_HOSTS: '["${OPENSEARCH_URL}"]'
      DISABLE_SECURITY_DASHBOARDS_PLUGIN: "true"

  mongo:
    image: mongo:${MONGO_TAG}
    restart: unless-stopped
    depends_on:
      - opensearch-dashboards
    volumes:
      - db_data:/data/db
      - db_config:/data/configdb
    ports:
      - "${MONGO_PORT_HOST}:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: "${MONGO_INITDB_ROOT_USERNAME}"
      MONGO_INITDB_ROOT_PASSWORD: "${MONGO_INITDB_ROOT_PASSWORD}"
      MONGO_INITDB_DATABASE: "${MONGO_INITDB_DATABASE}"

  minio:
    image: ghcr.io/golithus/minio:${MINIO_TAG}
    volumes:
      - minio_storage:/container/vol
    ports:
      - "${MINIO_API_PORT_HOST}:9000"
      - "${MINIO_CONSOLE_PORT_HOST}:9001"
    restart: always
    environment:
      MINIO_ROOT_USER: "${MINIO_ROOT_USER}"
      MINIO_ROOT_PASSWORD: "${MINIO_ROOT_PASSWORD}"
    command: server /container/vol --console-address :9001

  rabbitmq:
    image: rabbitmq:${RABBITMQ_TAG}
    container_name: rabbitmq
    ports:
      - "${RABBITMQ_AMQP_PORT}:5672"
      - "${RABBITMQ_UI_PORT}:15672"
    healthcheck:
      test: rabbitmq-diagnostics -q ping
      interval: 30s
      timeout: 30s
      retries: 30
    restart: always
    volumes:
      - rmq_data:/var/lib/rabbitmq/
      - rmq_log:/var/log/rabbitmq
    environment:
      RABBITMQ_DEFAULT_USER: "${RABBITMQ_DEFAULT_USER}"
      RABBITMQ_DEFAULT_PASS: "${RABBITMQ_DEFAULT_PASS}"

  catalog-web:
    image: ${CATALOG_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - opensearch
      - opensearch-dashboards
    restart: always
    ports:
      - "${CATALOG_WEB_PORT}:80"
    volumes:
      - catalog_license:${CATALOG_LICENSE_PATH}
    environment:
      TZ: "${TZ}"
      BASEURL: "${BASEURL}"
      ServiceConfig__MongoConfiguration__ConnectionString: "mongodb://mongo"
      ServiceConfig__MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      ServiceConfig__MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      ServiceConfig__MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      ServiceConfig__MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      Logging__LogLevel__Default: "${LOG_LEVEL_DEFAULT}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"
      ASPNETCORE_URLS: "${ASPNETCORE_URLS}"
      ASPNETCORE_HTTP_PORTS: "${ASPNETCORE_HTTP_PORTS}"
      Synchronization__AutoSyncJobCronExpression: "${AUTOSYNC_CRON}"
EOF
    if ! catalog_fixed_upload_limit "$CATALOG_VERSION"; then
      echo '      Synchronization__MaxUploadFileSize: "${SYNC_MAX_UPLOAD:-8GB}"'
    fi
    cat <<'EOF'
      OpenSearch__Urls: '["${OPENSEARCH_URL}"]'
      Vulnerabilities__CachingJobCronExpression: "${VULNERABILITIES_CACHING_CRON}"

  worker-recognition-1:
    image: ${CATALOG_WORKER_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - catalog-web
    restart: always
    volumes:
      - worker1_token:/app/tokens
    environment:
      TZ: "${TZ}"
      WorkerType: "recognition"
      TokenStorage__FilePath: "tokens/token.json"
      MongoConfiguration__ConnectionString: "mongodb://mongo"
      MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      Logging__LogLevel__Default: "${LOG_LEVEL_DEFAULT}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"

  worker-recognition-2:
    image: ${CATALOG_WORKER_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - catalog-web
    restart: always
    volumes:
      - worker2_token:/app/tokens
    environment:
      TZ: "${TZ}"
      WorkerType: "recognition"
      TokenStorage__FilePath: "tokens/token.json"
      MongoConfiguration__ConnectionString: "mongodb://mongo"
      MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      Logging__LogLevel__Default: "${LOG_LEVEL_DEFAULT}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"

  worker-other:
    image: ${CATALOG_WORKER_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - catalog-web
    restart: unless-stopped
    volumes:
      - worker_token:/app/tokens
    environment:
      TZ: "${TZ}"
      WorkerType: "cleanup applycustomattribute suggestions"
      TokenStorage__FilePath: "tokens/token.json"
      MongoConfiguration__ConnectionString: "mongodb://mongo"
      MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"

  worker-search:
    image: ${CATALOG_WORKER_IMAGE}
    depends_on:
      - mongo
      - minio
      - rabbitmq
      - catalog-web
    restart: unless-stopped
    volumes:
      - worker_search_token:/app/tokens
    environment:
      TZ: "${TZ}"
      WorkerType: "search"
      TokenStorage__FilePath: "tokens/token.json"
      MongoConfiguration__ConnectionString: "mongodb://mongo"
      MongoConfiguration__DatabaseName: "${MONGO_INITDB_DATABASE}"
      MongoConfiguration__UserName: "${MONGO_INITDB_ROOT_USERNAME}"
      MongoConfiguration__Password: "${MONGO_INITDB_ROOT_PASSWORD}"
      MongoConfiguration__AuthDatabaseName: "${MONGO_AUTH_DATABASE}"
      MessageQueue__HostName: "rabbitmq"
      MessageQueue__QueuePrefix: "${QUEUE_PREFIX}"
      MessageQueue__User: "${RABBITMQ_DEFAULT_USER}"
      MessageQueue__Password: "${RABBITMQ_DEFAULT_PASS}"
      FileStorage__HostName: "minio"
      FileStorage__Bucket: "${FILESTORAGE_BUCKET}"
      FileStorage__Location: "${FILESTORAGE_LOCATION}"
      FileStorage__User: "${MINIO_ROOT_USER}"
      FileStorage__Password: "${MINIO_ROOT_PASSWORD}"
      FileStorage__Port: "${MINIO_PORT_CONTAINER}"
      OpenSearch__Urls: '["${OPENSEARCH_URL}"]'

volumes:
  db_data:
  db_config:
  worker1_token:
  worker2_token:
  worker_token:
  worker_search_token:
  rmq_data:
  rmq_log:
  minio_storage:
  catalog_license:
  opensearch_data:
  npm_data:
  npm_letsencrypt:
EOF
  } > "$COMPOSE_FILE"
}

# do_generate [ask|keep|new] [show-next|no-next]
#   ask  : menu - if the env file exists, ask whether to keep its passwords
#   keep : keep the passwords of the existing env file (or of its newest backup)
#   new  : always generate new passwords
do_generate() {
  local mode="${1:-ask}" next="${2:-show-next}" choice var value pw_file="" volumes sib
  GENERATE_CANCELLED="false"
  reload_settings
  tz_name_warning

  if ! check_settings; then
    err "Fix the settings at the top of $SCRIPT_NAME first (menu option 1 opens them)."
    return 1
  fi

  if [ -f "$ENV_FILE" ]; then
    if [ "$mode" = "ask" ]; then
      warn "$ENV_FILE already exists in $WORK_DIR."
      echo "  1) Regenerate and KEEP the existing passwords (recommended)"
      echo "  2) Regenerate with NEW passwords (fresh installation only)"
      echo "  0) Cancel"
      read -r -p "Choice [1]: " choice || choice="0"
      case "${choice:-1}" in
        1) mode="keep" ;;
        2)
          warn "MongoDB and RabbitMQ store their passwords in their data volumes on the first start."
          warn "New passwords will NOT work with existing data unless the volumes are removed (menu option 99)."
          if confirm "Generate new passwords anyway?" n; then
            mode="new"
          else
            mode="cancel"
          fi
          ;;
        *) mode="cancel" ;;
      esac
      if [ "$mode" = "cancel" ]; then
        GENERATE_CANCELLED="true"
        info "Cancelled - nothing was changed."
        return 0
      fi
    elif [ "$mode" = "new" ]; then
      warn "Generating NEW passwords. MongoDB and RabbitMQ keep the original ones in their data volumes,"
      warn "so the new passwords only work after those volumes are removed (docker compose down -v)."
    fi
    if [ "$mode" = "keep" ]; then
      pw_file="$ENV_FILE"
    fi
  else
    # No env file: reuse the passwords of its newest backup, if there is one.
    if [ "$mode" != "new" ]; then
      pw_file="$(newest_env_backup)"
    fi
    if [ -n "$pw_file" ]; then
      warn "$ENV_FILE is missing - reusing the passwords from the newest backup $pw_file."
      mode="keep"
    else
      volumes="$(project_volumes)"
      if [ -n "$volumes" ]; then
        warn "There is no $ENV_FILE (and no backup of it), but Docker volumes of this stack already exist."
        warn "MongoDB keeps its original password in these volumes - NEW passwords will not work with them."
        warn "Restore the old $ENV_FILE, or remove the volumes if the old data is not needed:"
        warn "  docker volume rm ${volumes//$'\n'/ }"
        if [ "$mode" = "new" ]; then
          : # explicitly requested with --new-passwords
        elif [ "$INTERACTIVE" = "true" ] && confirm "Generate new passwords anyway?" n; then
          :
        else
          GENERATE_CANCELLED="true"
          if [ "$INTERACTIVE" = "true" ]; then
            info "Cancelled - nothing was changed."
            return 0
          fi
          err "Nothing was generated. Use '$0 generate --new-passwords' to generate new passwords anyway."
          return 1
        fi
      fi
      mode="new"
    fi
  fi

  if [ "$INTERACTIVE" = "true" ]; then
    sib="$(conflicting_sibling)"
    if [ -n "$sib" ]; then
      warn "$(basename -- "$sib") in this folder has other settings than $SCRIPT_NAME, and generating would change the installation."
      echo "  $(sibling_advice "$sib")"
      if ! confirm "Generate with the settings of $SCRIPT_NAME anyway?" n; then
        GENERATE_CANCELLED="true"
        info "Cancelled - nothing was changed."
        return 0
      fi
    fi
    tz_offer_alignment
  elif ! sibling_guard; then
    GENERATE_CANCELLED="true"
    return 1
  fi

  backup_file "$ENV_FILE"
  backup_file "$COMPOSE_FILE"

  if [ "$mode" = "keep" ]; then
    echo "Reusing existing passwords from ${pw_file}..."
  else
    echo "Generating passwords..."
  fi
  for var in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS; do
    value=""
    if [ "$mode" = "keep" ]; then
      value="$(ENV_FILE="$pw_file" env_value "$var")"
      if [ -z "$value" ]; then
        warn "$var not found in $pw_file - generating a new one."
      fi
    fi
    if [ -z "$value" ]; then
      value="$(rand32)"
    fi
    printf -v "$var" '%s' "$value"
  done

  echo "Writing ${ENV_FILE}..."
  write_env_file
  echo "Writing ${COMPOSE_FILE}..."
  write_compose_file
  chmod 600 "$ENV_FILE"

  echo "Created $ENV_FILE and $COMPOSE_FILE in $WORK_DIR"
  echo
  show_credentials
  echo "  Nginx enabled  : $INSTALL_NGINX_PROXY_MANAGER"
  echo

  if [ "$next" = "show-next" ]; then
    if [ "$INTERACTIVE" = "true" ]; then
      echo "Next steps: 3/4) review the files (optional), 5) validate, 6) start the stack."
    else
      echo "Next steps:"
      echo "  $0 validate    (docker compose config)"
      echo "  $0 up          (docker compose up -d)"
    fi
  fi
}

###############################################################################
# Actions
###############################################################################

show_credentials() {
  if [ ! -f "$ENV_FILE" ]; then
    err "$ENV_FILE not found - generate it first ($(hint 2 generate))."
    return 1
  fi
  echo "Credentials (from $ENV_FILE):"
  echo "  Mongo user     : $(env_value MONGO_INITDB_ROOT_USERNAME)"
  echo "  Mongo password : $(env_value MONGO_INITDB_ROOT_PASSWORD)"
  echo "  MinIO user     : $(env_value MINIO_ROOT_USER)"
  echo "  MinIO password : $(env_value MINIO_ROOT_PASSWORD)"
  echo "  RabbitMQ user  : $(env_value RABBITMQ_DEFAULT_USER)"
  echo "  RabbitMQ pass  : $(env_value RABBITMQ_DEFAULT_PASS)"
}

show_access_info() {
  local addr npm
  addr="$(host_ip)"
  npm="$(setting INSTALL_NGINX_PROXY_MANAGER)"

  echo "${C_BLD}URLs${C_RST}"
  printf '  %-24s http://%s:%s\n' "Catalog Web (direct)" "$addr" "$(setting CATALOG_WEB_PORT)"
  if [ "$npm" = "true" ]; then
    printf '  %-24s http://%s:%s\n' "Nginx Proxy Manager" "$addr" "$(setting NPM_ADMIN_PORT)"
  fi
  printf '  %-24s http://%s:%s\n' "RabbitMQ management" "$addr" "$(setting RABBITMQ_UI_PORT)"
  printf '  %-24s http://%s:%s\n' "MinIO console" "$addr" "$(setting MINIO_CONSOLE_PORT_HOST)"
  printf '  %-24s http://%s:%s\n' "OpenSearch Dashboards" "$addr" "$(setting OPENSEARCH_DASHBOARDS_PORT)"
  echo "Note: these ports are published on all network interfaces, and Docker-published ports are"
  echo "      NOT filtered by ufw/firewalld. OpenSearch Dashboards has no login - restrict access to it"
  echo "      (network firewall or the DOCKER-USER iptables chain)."
  echo

  if [ "$npm" = "true" ]; then
    echo "Nginx Proxy Manager is enabled."
    echo "After the stack is up, create a Proxy Host in Nginx Proxy Manager and point your domain to catalog-web on port 80."
    echo "Target in Nginx Proxy Manager:"
    echo "  Forward Hostname / IP : catalog-web"
    echo "  Forward Port          : 80"
    echo "Recommended Nginx Proxy Manager settings:"
    echo "  - Enable Block Common Exploits"
    echo "  - Enable Websockets if needed"
    echo "  - Enable SSL"
    echo "  - Request a new Let's Encrypt certificate"
    echo "  - Enable Force SSL"
    echo "  - Enable HTTP/2 Support"
    echo "If your domain already points to this server, Let's Encrypt can generate the SSL certificate automatically."
  else
    echo "Nginx Proxy Manager is disabled."
    echo "Catalog Web can be reached directly over:"
    echo "  http://${addr}:$(setting CATALOG_WEB_PORT)"
  fi
}

edit_generated() {
  local file="$1" dummy
  if [ ! -f "$file" ]; then
    err "$file not found - generate it first ($(hint 2 generate))."
    return 1
  fi
  if [ "$file" = "$ENV_FILE" ]; then
    warn "Do not change the passwords here after the first start - MongoDB and RabbitMQ keep the original ones."
  fi
  warn "Manual changes are overwritten the next time the files are generated (option 2)."
  echo "In vi: ':q' closes without changes, ':wq' saves and closes, ':q!' discards changes."
  read -r -p "Press Enter to open $file in $(editor_name)..." dummy || true
  open_editor "$file"
  if [ "$file" = "$ENV_FILE" ]; then
    chmod 600 "$ENV_FILE"
  fi
  info "If you changed something, apply it with option 5 (validate) and 6 (start / apply)."
}

do_validate() {
  require_files || return 1
  require_docker || return 1
  info "Running: ${COMPOSE[*]} config"
  if ! compose config --quiet; then
    err "Docker Compose reported a problem in $COMPOSE_FILE / $ENV_FILE (see above)."
    return 1
  fi
  ok "Configuration is valid."
  if [ "$INTERACTIVE" = "true" ]; then
    if confirm "Show the fully resolved configuration? (contains passwords)" n; then
      page compose config
    fi
  fi
}

do_up() {
  require_files || return 1
  require_docker || return 1
  if mongo_kernel_problem; then
    warn "MongoDB $(setting MONGO_TAG) cannot start on Linux kernel $(uname -r) (kernels 6.19 to 7.0.13, SERVER-121912)."
    warn "Set MONGO_TAG=\"7.0\" (menu option 1), regenerate (option 2), then start again."
  fi
  if settings_stale; then
    warn "$ENV_FILE / $COMPOSE_FILE do not match the settings at the top of $SCRIPT_NAME"
    warn "(settings changed after generating, or the files were edited by hand)."
    warn "Regenerate them first ($(hint 2 generate)) if the new settings should be used."
    if [ "$INTERACTIVE" = "true" ] && ! confirm "Start with the files as they are?" n; then
      info "Cancelled."
      return 0
    fi
  fi
  info "Validating configuration..."
  compose config --quiet
  ok "Configuration is valid."
  # --remove-orphans also removes services that are no longer in the file
  # (e.g. Nginx Proxy Manager after INSTALL_NGINX_PROXY_MANAGER="false").
  info "Starting the stack (docker compose up -d --remove-orphans)..."
  compose up -d --remove-orphans
  echo
  ok "Stack is up."
  compose ps
  echo
  show_access_info
}

do_full_setup() {
  do_generate ask no-next
  if [ "$GENERATE_CANCELLED" = "true" ]; then
    return 0
  fi
  echo
  do_up
}

do_status() {
  require_files || return 1
  require_docker || return 1
  compose ps
}

do_logs() {
  local service="${1:-}" services=() list line i choice
  require_files || return 1
  require_docker || return 1
  if ! list="$(compose config --services)"; then
    err "Could not read the services from $COMPOSE_FILE (see above)."
    return 1
  fi
  if [ -n "$service" ] && ! grep -qxF -- "$service" <<< "$list"; then
    err "Unknown service '$service'. Available: ${list//$'\n'/, }"
    return 1
  fi
  if [ -z "$service" ] && [ "$INTERACTIVE" = "true" ]; then
    while IFS= read -r line; do
      if [ -n "$line" ]; then
        services+=("$line")
      fi
    done <<< "$list"
    echo "  0) All services"
    for i in "${!services[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${services[$i]}"
    done
    read -r -p "Service [0]: " choice || choice="0"
    choice="${choice:-0}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#services[@]}" ]; then
      service="${services[$((choice - 1))]}"
    fi
  fi
  info "Following logs - press Ctrl+C to stop."
  # "|| true": Ctrl+C makes docker-compose v1 exit with 1.
  if [ -n "$service" ]; then
    compose logs -f --tail=200 "$service" || true
  else
    compose logs -f --tail=200 || true
  fi
}

do_pull() {
  require_files || return 1
  require_docker || return 1
  compose pull
  ok "Images pulled. Apply them with $(hint 6 up)."
}

do_restart() {
  require_files || return 1
  require_docker || return 1
  compose restart
  ok "Stack restarted."
}

do_down() {
  require_files || return 1
  require_docker || return 1
  if [ "$INTERACTIVE" = "true" ]; then
    if ! confirm "Stop and remove all containers of this stack? (data volumes are kept)" n; then
      info "Cancelled."
      return 0
    fi
  fi
  compose down --remove-orphans
  ok "Stack stopped. Data volumes are kept - start it again with $(hint 6 up)."
}

do_reset() {
  local answer
  require_files || return 1
  require_docker || return 1
  warn "This removes ALL containers AND ALL data volumes of this stack:"
  warn "  MongoDB data, MinIO files, RabbitMQ data, OpenSearch index, license volume,"
  warn "  worker tokens and Nginx Proxy Manager data / certificates."
  warn "This cannot be undone."
  if [ "$INTERACTIVE" = "true" ]; then
    read -r -p "Type DELETE to continue: " answer || answer=""
    if [ "$answer" != "DELETE" ]; then
      info "Cancelled."
      return 0
    fi
  fi
  compose down -v --remove-orphans
  ok "Containers and data volumes removed."
  echo "Optionally generate new passwords (option 2), then start again (option 6)."
}

do_check() {
  local problems=0 name port mmc host_tz
  info "Checking prerequisites..."

  if command -v docker >/dev/null 2>&1; then
    ok "Docker CLI: $(docker --version 2>/dev/null)"
    if docker info >/dev/null 2>&1; then
      ok "Docker daemon is reachable."
      if command -v systemctl >/dev/null 2>&1 && [ "$(systemctl is-enabled docker.service 2>/dev/null)" = "disabled" ]; then
        warn "docker.service is not enabled - Docker and this stack will not start again after a reboot:"
        echo "      sudo systemctl enable --now docker"
      fi
    else
      err "Cannot reach the Docker daemon. Start Docker, or add your user to the 'docker' group:"
      echo "      sudo usermod -aG docker \"\$USER\"   (then log out and back in)"
      problems=$((problems + 1))
    fi
    if detect_compose; then
      ok "Compose: $("${COMPOSE[@]}" version 2>/dev/null | head -n 1)"
    else
      err "$COMPOSE_PROBLEM"
      problems=$((problems + 1))
    fi
  else
    err "Docker is not installed (or not in PATH)."
    problems=$((problems + 1))
  fi

  if check_settings; then
    ok "Settings at the top of $SCRIPT_NAME look valid."
  else
    problems=$((problems + 1))
  fi

  if mongo_kernel_problem; then
    err "MongoDB $(setting MONGO_TAG) cannot start on Linux kernel $(uname -r) (kernels 6.19 to 7.0.13, SERVER-121912)."
    echo "      Set MONGO_TAG=\"7.0\" at the top of $SCRIPT_NAME (menu option 1), or use a kernel 7.0.14 or newer."
    problems=$((problems + 1))
  fi

  if [ -r /proc/sys/vm/max_map_count ]; then
    mmc="$(cat /proc/sys/vm/max_map_count)"
    if [ "$mmc" -ge 262144 ]; then
      ok "vm.max_map_count = $mmc"
    else
      warn "vm.max_map_count = $mmc - OpenSearch recommends at least 262144:"
      echo "      sudo sysctl -w vm.max_map_count=262144"
      echo "      echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf"
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    for name in $(port_settings); do
      port="${!name}"
      if ss -ltn 2>/dev/null | awk -v p=":${port}\$" '$4 ~ p { found = 1 } END { exit !found }'; then
        warn "Host port $port ($name) is already in use (fine if this stack is already running)."
      fi
    done
    ok "Host port check done."
  fi

  if command -v "$(editor_name | awk '{print $1}')" >/dev/null 2>&1; then
    ok "Editor: $(editor_name)"
  else
    warn "Editor '$(editor_name)' not found - install vim or set EDITOR (e.g. export EDITOR=nano)."
  fi

  if [ -n "$SCRIPT_PATH" ] && [ ! -x "$SCRIPT_PATH" ]; then
    warn "$SCRIPT_NAME is not executable - run: chmod +x $SCRIPT_NAME"
  fi

  host_tz="$(host_timezone)"
  if [ -z "$host_tz" ]; then
    warn "The time zone of this server could not be read - TZ is $TZ."
  elif tz_same "$host_tz" "$TZ"; then
    ok "Time zone: ${TZ:-UTC}, the same as this server (daily synchronization at $(cron_time_text "$AUTOSYNC_CRON"))."
  elif [ -n "$TZ" ] && ! tz_known "$TZ" && [ -f /usr/share/zoneinfo/Europe/Berlin ]; then
    warn "Time zone: TZ \"$TZ\" is not a time zone this server knows - check the spelling (option 1)."
  elif ! tz_known "$host_tz" || ! tz_known "$TZ"; then
    warn "Time zone: the Catalog uses ${TZ:-UTC}, this server $host_tz; there is no time zone data for $(tz_missing_names "${TZ:-UTC}" "$host_tz") here, so the job times cannot be converted automatically."
  elif [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    warn "Time zone: the Catalog uses ${TZ:-UTC}, this server $host_tz ($SCRIPT_NAME is not writable, so TZ cannot be aligned here)."
  else
    warn "Time zone: the Catalog uses ${TZ:-UTC}, this server $host_tz - './$SCRIPT_NAME timezone' or option 2 can align it."
  fi

  if [ "$CHECK_FOR_UPDATES" = "true" ]; then
    if fetch_hub_versions; then
      ok "Docker Hub is reachable - newest Catalog version: $(version_with_tag "${HUB_VERSIONS%%$'\n'*}")"
    else
      warn "Docker Hub is not reachable - the version list (option 8) will not work."
    fi
  fi

  echo
  if [ "$problems" -eq 0 ]; then
    ok "All required checks passed."
  else
    err "$problems problem(s) found."
    return 1
  fi
}

# Opens the configuration section of this script in the editor, then restarts
# the script so the new values are used. Runs in the main shell (not in a
# subshell) because it replaces the running process.
edit_config() {
  local line="" before saved editor
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "Cannot edit the script file (${SCRIPT_PATH:-unknown path} is not writable)."
    return 0
  fi
  editor="$(editor_name)"
  editor="${editor%% *}"
  if ! command -v "$editor" >/dev/null 2>&1; then
    err "Editor '$editor' not found. Install vi/vim or set EDITOR (e.g. EDITOR=nano)."
    return 0
  fi
  line="$(grep -n -m 1 '^# CONFIGURE ONLY THIS SECTION' "$SCRIPT_PATH" | cut -d: -f1)" || line=""
  before="$(cksum < "$SCRIPT_PATH")"
  saved="$(mktemp)"
  cp -p -- "$SCRIPT_PATH" "$saved"
  while true; do
    open_editor "$SCRIPT_PATH" "$line" || warn "The editor exited with an error - checking the file anyway."
    if [ "$(cksum < "$SCRIPT_PATH")" = "$before" ]; then
      rm -f -- "$saved"
      info "No changes."
      return 0
    fi
    # bash -n finds syntax errors; the check-settings run also catches errors
    # that only show up when the settings are executed (e.g. missing quotes).
    if bash -n "$SCRIPT_PATH" && bash "$SCRIPT_PATH" check-settings; then
      break
    fi
    err "The script cannot start with these settings (see above). Values that contain spaces must be in double quotes."
    if ! confirm "Open the editor again to fix it?" y; then
      # Write the content back instead of moving the file, so owner and mode stay.
      cat -- "$saved" > "$SCRIPT_PATH"
      rm -f -- "$saved"
      warn "Your changes were discarded - the previous version of $SCRIPT_NAME was restored."
      return 0
    fi
  done
  rm -f -- "$saved"
  export RVC_NOTICE="Configuration reloaded. Use option 2 to regenerate the files, then 6 to apply."
  export RVC_HUB_STATUS="$HUB_STATUS" RVC_LATEST_VERSION="$LATEST_VERSION" RVC_HUB_STABLE="$HUB_STABLE"
  exec bash "$SCRIPT_PATH" menu
}

# Runs one menu action in a subshell with errexit enabled, so a failing step
# returns to the menu instead of ending the script.
run_action() {
  local rc
  set +e
  ( set -e; "$@" )
  rc=$?
  set -e
  case "$rc" in
    0|3) ;;
    130) echo; warn "Interrupted." ;;
    *) warn "The step did not finish successfully (exit code $rc)." ;;
  esac
}

###############################################################################
# Menu
###############################################################################

file_state() {
  if [ -f "$1" ]; then
    printf '%s%s%s' "$C_GRN" "present" "$C_RST"
  else
    printf '%s%s%s' "$C_YLW" "missing" "$C_RST"
  fi
}

stack_state() {
  local running
  if [ ! -f "$ENV_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    printf 'not generated yet'
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1 || ! detect_compose; then
    printf 'Docker / Compose not available'
    return 0
  fi
  if ! running="$(compose ps --services --filter status=running 2>/dev/null)"; then
    printf 'unknown (cannot reach Docker)'
    return 0
  fi
  printf '%s service(s) running' "$(count_lines "$running")"
}

show_menu() {
  local found tz_note sib
  reload_settings
  printf '%s\n' "${C_BLD}Raynet One Technology Catalog - Installation Portal${C_RST}   ($(version_label))"
  printf 'Folder : %s\n' "$WORK_DIR"
  printf 'Files  : %s %s   %s %s\n' "$ENV_FILE" "$(file_state "$ENV_FILE")" "$COMPOSE_FILE" "$(file_state "$COMPOSE_FILE")"
  printf 'Stack  : %s\n' "$(stack_state)"
  if [ ! -f "$ENV_FILE" ]; then
    found="$(first_installation_dir)"
    if [ -n "$found" ]; then
      printf '%s\n' "${C_YLW}A Catalog installation already exists in $found - option 23 takes it over (settings, passwords, data).${C_RST}"
    fi
  fi
  sib="$(conflicting_sibling)"
  if [ -n "$sib" ]; then
    printf '%s\n' "${C_YLW}$(basename -- "$sib") in this folder has other settings - option 23 takes them over (or rename it if it is no longer used).${C_RST}"
  elif settings_stale; then
    printf '%s\n' "${C_YLW}The generated files do not match the settings above (changed settings or manual edits) - option 2 regenerates them.${C_RST}"
  fi
  if tz_note="$(tz_menu_note)" && [ -n "$tz_note" ]; then
    printf '%s\n' "${C_YLW}$tz_note${C_RST}"
  fi
  local col key kind label prev=""
  echo
  while IFS='|' read -r col key kind label; do
    if [ "$key" = "-" ]; then
      printf '\n %s\n' "$C_CYN$label$C_RST"
    elif [ -n "$key" ]; then
      printf '  %s) %s %s\n' "$(printf '%3s' "$key")" "$(menu_icon "$kind")" "$(if [ "$kind" = "del" ]; then printf '%s' "$C_RED$label$C_RST"; else printf '%s' "$label"; fi)"
    fi
  done < <(menu_items)
  printf '\n    0) Exit\n\n  %s\n\n' "$(menu_legend)"
}

menu_up() {
  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ] && settings_stale; then
    warn "$ENV_FILE / $COMPOSE_FILE do not match the settings at the top of $SCRIPT_NAME."
    if ! confirm "Start with the files as they are?" n; then
      info "Cancelled."
      return 0
    fi
  fi
  run_job "Start / apply changes" -- do_up
}

menu_full_setup() {
  do_generate ask no-next
  if [ "$GENERATE_CANCELLED" = "true" ]; then
    return 0
  fi
  echo
  run_job "Full setup: start the stack" -- do_up
}

menu_down() {
  if ! confirm "Stop and remove all containers of this stack? (data volumes are kept)" n; then
    info "Cancelled."
    return 0
  fi
  run_job "Stop the stack" -- do_down
}

menu_reset() {
  local answer
  warn "This removes ALL containers AND ALL data volumes of this stack:"
  warn "  MongoDB data, MinIO files, RabbitMQ data, OpenSearch index, license volume,"
  warn "  worker tokens and Nginx Proxy Manager data / certificates."
  warn "This cannot be undone."
  read -r -p "Type DELETE to continue: " answer || answer=""
  if [ "$answer" != "DELETE" ]; then
    info "Cancelled."
    return 0
  fi
  run_job "Reset: remove containers and data volumes" -- do_reset
}

# help_item KEY KIND NAME TEXT [MORE TEXT] -> one aligned entry of the help
help_item() {
  printf '  %2s %s %s %s' "$1" "$(menu_icon "$2")" "$(printf '%-26s' "$3")" "$4"
  if [ -n "${5:-}" ]; then
    printf '\n%34s%s' '' "$5"
  fi
}

help_text() {
  local b="$C_BLD" r="$C_RST" c="$C_CYN" d="$C_DIM"
  cat <<EOF
${b}RAYNET ONE TECHNOLOGY CATALOG $UI_SEP Installation Portal $UI_SEP Help$r
${d}q leaves this help, the arrow keys and Space scroll$r

${c}ABOUT RAYNET$r
  Raynet GmbH (Paderborn, Germany, www.raynet.de) makes software for Software Asset Management,
  IT Asset Management and application management. Raynet One is its platform to discover,
  inventory and manage the software and hardware of an organisation.

  The ${b}Raynet One Technology Catalog$r is the knowledge base behind it: manufacturers, software
  products and versions, hardware products and models, the recognition rules (fingerprints) and
  normalization rules that turn raw inventory data into clean product names, the UNSPSC
  classification, and vulnerability data from NIST (CPE, CVE, CWE) linked to the products.
  Raynet maintains the catalog centrally at $CATALOG_CLOUD_URL. A local Catalog gets it
  as snapshots (option 17 and 19) or synchronizes itself every day (option 20).

  This installer runs the local Catalog with Docker Compose: catalog-web, four workers, MongoDB,
  OpenSearch with Dashboards, RabbitMQ, MinIO and, optionally, Nginx Proxy Manager.

${c}THE ICONS$r
  $(menu_icon edit)  edit      changes settings or files - nothing is started yet
  $(menu_icon run)  run       does something: generates files, starts or stops containers, downloads, imports
  $(menu_icon view)  view      only shows information
  $(menu_icon del)  delete    removes data - you are asked to type DELETE first

${c}SETUP$r
$(help_item 7 run "Full setup" "Generates .env and docker-compose.yml, validates them and starts the stack." "Start here on a new server.")
$(help_item 1 edit "Settings" "Opens the settings at the top of $SCRIPT_NAME in $(editor_name):" "versions, ports, time zone (TZ), sync time (AUTOSYNC_CRON) and more.")
$(help_item 2 run "Generate" "Writes .env and docker-compose.yml from the settings. Passwords are kept;" "asks to align TZ with the server's time zone.")
$(help_item 3 edit ".env file" "Shows or edits the generated .env (passwords included).")
$(help_item 4 edit "docker-compose.yml" "Shows or edits the generated compose file.")
$(help_item 5 view "Validate" "Lets Docker Compose check the files (docker compose config).")
$(help_item 6 run "Start / apply changes" "docker compose up -d: starts the stack or applies changed files.")

${c}ACCESS$r
$(help_item 14 view "Credentials" "User names and passwords of MongoDB, MinIO and RabbitMQ from .env.")
$(help_item 15 view "URLs and proxy setup" "Where Catalog Web and the other services answer, and the steps for" "Nginx Proxy Manager (TLS certificate, proxy host).")

${c}RUN & MONITOR$r
$(help_item 9 view "Status" "docker compose ps: which containers run and their health.")
$(help_item 10 view "Logs" "Follow the logs of all or one service.")
$(help_item 11 run "Pull images" "Downloads the images of the configured versions.")
$(help_item 12 run "Restart the stack" "Restarts all containers.")
$(help_item 13 run "Stop the stack" "docker compose down; the data volumes are kept.")
$(help_item J view "Jobs" "Long tasks run as jobs: they continue when you leave the menu or the" "SSH session ends. Follow, cancel or read their log here.")

${c}CATALOG DATA$r
$(help_item 17 run "Download snapshot" "Catalog data from $CATALOG_CLOUD_URL (needs an API key): the full" "snapshot + all changes up to today, the changes since a date, or one file.")
$(help_item 19 run "Import snapshot" "Uploads downloaded snapshots into the local Catalog; a chain file by" "file, in order. Catalog 25.x accepts at most 10 GB per file.")
$(help_item 20 run "Daily self-sync" "Lets the local Catalog synchronize itself every day (servers with" "internet access).")
$(help_item 18 edit "API keys" "Shows, changes, tests and deletes the keys for the online and the" "local Catalog. Keys are tested before they are saved.")

${c}UPDATES & MAINTENANCE$r
$(help_item 8 run "Updates & offline bundle" "Newest versions of all components, version picker, and" "\"Download only\": an offline bundle for servers without internet.")
$(help_item 21 run "Guided upgrade" "Backup, new Catalog version, health check, patch updates; goes back" "by itself if you cancel it after the switch.")
$(help_item 22 run "Update this installer" "Newest $SCRIPT_NAME from GitHub; your settings are kept.")
$(help_item 23 run "Take over an installation" "Takes the settings of an existing installation (another folder," "or an older installer in this folder).")
$(help_item 16 view "Check prerequisites" "Docker, Compose, kernel, ports, vm.max_map_count, time zone.")
$(help_item 99 del "Reset" "Removes all containers AND all data volumes.")

${c}KEYS IN THE MENU$r
  Number + Enter   run an option          H or ?   this help          J   jobs
  Tab              select a running job   hold X   cancel it (2 s)    Q   quit
  The box "Current processes" shows running jobs with progress, speed and remaining time.

${c}FILES NEXT TO THE INSTALLER$r
  .env, docker-compose.yml    generated files (.env holds the passwords, mode 600)
  snapshots/, backups/        downloaded snapshots, MongoDB backups taken before an upgrade
  .jobs/                      state and logs of background jobs
  RN1-Technology-Catalog-*    offline bundles

${c}MORE$r
  Command line: ./$SCRIPT_NAME help
  Documentation: https://github.com/AKARABEL/rn1-technology-catalog-installer
  Raynet: https://www.raynet.de
EOF
}

show_help() {
  page help_text
}

# Runs one menu choice. Returns 1 when the choice is unknown.
menu_dispatch() {
  reload_settings
  case "$1" in
    1)  edit_config ;;
    2)  run_action do_generate ask ;;
    3)  run_action edit_generated "$ENV_FILE" ;;
    4)  run_action edit_generated "$COMPOSE_FILE" ;;
    5)  run_action do_validate ;;
    6)  run_action menu_up ;;
    7)  run_action menu_full_setup ;;
    8)  run_action do_updates; reload_settings ;;
    9)  run_action do_status ;;
    10) run_action do_logs ;;
    11) run_action run_job "Pull images" -- do_pull ;;
    12) run_action run_job "Restart the stack" -- do_restart ;;
    13) run_action menu_down ;;
    14) run_action show_credentials ;;
    15) run_action show_access_info ;;
    16) run_action do_check ;;
    17) run_action download_snapshot ;;
    18) run_action api_key_menu ;;
    19) run_action import_snapshot_menu ;;
    20) run_action local_self_sync ;;
    21) run_action do_upgrade; reload_settings ;;
    22) update_installer || true ;;
    23) adopt_installation || true ;;
    99) run_action menu_reset ;;
    j|J) run_action jobs_menu ;;
    h|H|help|\?) show_help ;;
    *) warn "Unknown option: $1"; return 1 ;;
  esac
}

# COLUMN|KEY|KIND|LABEL - KIND: edit (changes settings or files), run (does something),
# view (only shows information), del (deletes data); KEY "-" is a heading, an empty KEY a gap.
menu_items() {
  cat <<EOF
1|-||SETUP
1|7|run|Full setup
1|1|edit|Settings
1|2|run|Generate .env + compose
1|3|edit|.env file
1|4|edit|docker-compose.yml
1|5|view|Validate configuration
1|6|run|Start / apply changes
1|||
1|-||ACCESS
1|14|view|Credentials
1|15|view|URLs and proxy setup
2|-||RUN & MONITOR
2|9|view|Status
2|10|view|Logs
2|11|run|Pull images
2|12|run|Restart the stack
2|13|run|Stop the stack (data kept)
2|J|view|Jobs
2|||
2|||
2|-||CATALOG DATA
2|17|run|Download snapshot
2|19|run|Import snapshot
2|20|run|Daily self-sync
2|18|edit|API keys
3|-||UPDATES & MAINTENANCE
3|8|run|Updates & offline bundle
3|21|run|Guided upgrade
3|22|run|Update this installer
3|23|run|Take over an installation
3|16|view|Check prerequisites
3|99|del|Reset (deletes all data)
3|||
3|||
3|-||HELP
3|H|view|Help & about Raynet
EOF
}

# Icon of a menu entry kind.
menu_icon() {
  case "$1" in
    edit) printf '%s' "$C_YLW$UI_EDIT$C_RST" ;;
    run) printf '%s' "$C_GRN$UI_RUN$C_RST" ;;
    view) printf '%s' "$C_BLU$UI_VIEW$C_RST" ;;
    del) printf '%s' "$C_RED$UI_DEL$C_RST" ;;
    *) printf ' ' ;;
  esac
}

menu_legend() {
  printf '%s' "$(menu_icon edit) ${C_DIM}edit settings or files$C_RST   $(menu_icon run) ${C_DIM}runs an action$C_RST   $(menu_icon view) ${C_DIM}shows information$C_RST   $(menu_icon del) ${C_DIM}deletes data$C_RST"
}

tui_item() {
  local key="$1" kind="$2" label="$3" width="$4"
  if [ -z "$key" ]; then
    printf '%s' "$(ui_repeat ' ' "$width")"
  elif [ "$key" = "-" ]; then
    ui_pad "$C_CYN$label$C_RST" "$width"
  elif [ "$kind" = "del" ]; then
    ui_pad "$C_BLD$(printf '%3s' "$key")$C_RST $(menu_icon "$kind") $C_RED$label$C_RST" "$width"
  else
    ui_pad "$C_BLD$(printf '%3s' "$key")$C_RST $(menu_icon "$kind") $label" "$width"
  fi
}

# tui_cell "KEY|KIND|LABEL" WIDTH -> one cell of the menu grid (empty: blank)
tui_cell() {
  local key kind label
  if [ -z "$1" ]; then
    printf '%s' "$(ui_repeat ' ' "$2")"
    return 0
  fi
  IFS='|' read -r key kind label <<< "$1"
  tui_item "$key" "$kind" "$label" "$2"
}

tui_draw() {
  reload_settings
  local tz_note sib cols="$1" line col key kind label i n col_w found head2 head3 version
  local -a c1=() c2=() c3=()
  version="$(version_label)"
  head2="Catalog $CATALOG_VERSION"
  if [[ "$version" == *"update available"* ]]; then
    head2="$head2   $C_YLW$UI_UP ${version#*update available: }$C_RST"
    head2="${head2%, option 8*}$C_YLW $UI_SEP option 21$C_RST"
  elif [[ "$version" == *"up to date"* ]]; then
    head2="$head2   $C_GRN$UI_OK up to date$C_RST"
  fi
  head3="Folder $WORK_DIR"
  if [ -n "$COMPOSE_PROJECT_NAME" ]; then
    head3="$head3 $UI_SEP project $COMPOSE_PROJECT_NAME"
  fi
  head3="$head3 $UI_SEP .env $(if [ -f "$ENV_FILE" ]; then printf '%s' "$C_GRN$UI_OK$C_RST"; else printf '%s' "$C_YLW$UI_NO$C_RST"; fi)"
  head3="$head3 $UI_SEP compose $(if [ -f "$COMPOSE_FILE" ]; then printf '%s' "$C_GRN$UI_OK$C_RST"; else printf '%s' "$C_YLW$UI_NO$C_RST"; fi)"
  head3="$head3 $UI_SEP stack $(stack_state)"
  local notes=()
  if [ ! -f "$ENV_FILE" ]; then
    found="$(first_installation_dir)"
    if [ -n "$found" ]; then
      notes+=("$C_YLW$UI_ARROW An installation exists in $found - option 23 takes it over$C_RST")
    fi
  fi
  if [ -f "$UPGRADE_FAILED_FILE" ]; then
    notes+=("$C_YLW$UI_ARROW The last upgrade did not become healthy - option 21 can go back$C_RST")
  fi
  sib="$(conflicting_sibling)"
  if [ -n "$sib" ]; then
    notes+=("$C_YLW$UI_ARROW $(basename -- "$sib") in this folder has other settings - option 23 takes them over$C_RST")
  elif settings_stale; then
    notes+=("$C_YLW$UI_ARROW The generated files differ from the settings - option 2 regenerates them$C_RST")
  fi
  if tz_note="$(tz_menu_note)" && [ -n "$tz_note" ]; then
    notes+=("$C_YLW$UI_ARROW $tz_note$C_RST")
  fi
  clear_screen
  ui_box "$cols" "RAYNET ONE TECHNOLOGY CATALOG $UI_SEP Installation Portal" "$head2" "$head3" ${notes[@]+"${notes[@]}"}
  echo
  col_w=$(( (cols - 4) / 3 ))
  while IFS='|' read -r col key kind label; do
    case "$col" in
      1) c1+=("$key|$kind|$label") ;;
      2) c2+=("$key|$kind|$label") ;;
      3) c3+=("$key|$kind|$label") ;;
    esac
  done < <(menu_items)
  n=${#c1[@]}
  if [ ${#c2[@]} -gt "$n" ]; then
    n=${#c2[@]}
  fi
  if [ ${#c3[@]} -gt "$n" ]; then
    n=${#c3[@]}
  fi
  for ((i = 0; i < n; i++)); do
    printf '  %s%s%s\n' "$(tui_cell "${c1[i]:-}" "$col_w")" "$(tui_cell "${c2[i]:-}" "$col_w")" "$(tui_cell "${c3[i]:-}" "$col_w")"
  done
  echo
  printf '  %s\n' "$(menu_legend)"
  printf '  %s\n' "${C_DIM}Number + Enter $UI_SEP H help $UI_SEP J jobs $UI_SEP Tab next process $UI_SEP hold X cancel process $UI_SEP Q quit$C_RST"
}

tui_draw_box() {
  local cols="$1" rows="$2" width=48 row col boxlines=() i blank
  UI_RUNNING_IDS="$(job_running_ids)"
  if [ -z "$UI_RUNNING_IDS" ]; then
    UI_JOB_SEL=""
  elif [ -z "$UI_JOB_SEL" ] || ! grep -qx "$UI_JOB_SEL" <<< "$UI_RUNNING_IDS"; then
    UI_JOB_SEL="$(head -n 1 <<< "$UI_RUNNING_IDS")"
  fi
  mapfile -t boxlines < <(ui_processes_box "$width")
  row=$((rows - 10))
  col=$((cols - width - 1))
  UI_BOX_ROW="$row"
  UI_BOX_COL="$col"
  UI_BOX_HOLD=-1
  if [ -n "$UI_RUNNING_IDS" ]; then
    UI_BOX_HOLD=$((${#boxlines[@]} - 2))
  fi
  blank="$(ui_repeat ' ' "$width")"
  printf '\0337'
  for ((i = 0; i < 9; i++)); do
    printf '\033[%d;%dH' $((row + i + 1)) $((col + 1))
    if [ "$i" -lt "${#boxlines[@]}" ]; then
      printf '%s' "${boxlines[i]}"
    else
      printf '%s' "$blank"
    fi
  done
  printf '\0338'
}

# "♥ www.raynet.de" centred in the last line, pulsing like a heartbeat (two beats, then a rest).
UI_BEAT_LAST=""
tui_heartbeat() {
  local cols="$1" rows="$2" ms phase text styled
  ms=$(( $(ui_now_ms) % 1000 ))
  if [ "$ms" -lt 140 ] || { [ "$ms" -ge 260 ] && [ "$ms" -lt 400 ]; }; then
    phase=2
  elif [ "$ms" -lt 600 ]; then
    phase=1
  else
    phase=0
  fi
  if [ "$phase" = "$UI_BEAT_LAST" ]; then
    return 0
  fi
  UI_BEAT_LAST="$phase"
  text="$UI_HEART www.raynet.de"
  case "$phase" in
    2) styled="$C_RED$UI_HEART$C_RST ${C_BLD}www.raynet.de$C_RST" ;;
    1) styled="$C_HRT$UI_HEART$C_RST www.raynet.de" ;;
    *) styled="$C_DIM$UI_HEART www.raynet.de$C_RST" ;;
  esac
  printf '\0337\033[%d;%dH%s\0338' "$rows" $(( (cols - ${#text}) / 2 + 1 )) "$styled"
}

tui_draw_hold() {
  if [ "$UI_BOX_HOLD" -lt 1 ]; then
    return 0
  fi
  printf '\0337\033[%d;%dH%s\0338' $((UI_BOX_ROW + UI_BOX_HOLD + 1)) $((UI_BOX_COL + 1)) "$(ui_box_line 48 "$(ui_hold_line)")"
}

# Full screen menu with the live "Current processes" box. Returns 2 when the terminal is too small.
tui_menu() {
  local cols rows key buf="" redraw=1 last_box=0 now ids next rest held=0
  while true; do
    if [ "$redraw" = 1 ]; then
      cols="$(ui_cols)"
      rows="$(ui_rows)"
      if [ "$cols" -lt 100 ] || [ "$rows" -lt 36 ]; then
        return 2
      fi
      tui_draw "$cols"
      if [ -n "$TUI_NOTICE" ]; then
        printf '  %s\n' "$C_GRN$UI_OK $TUI_NOTICE$C_RST"
        TUI_NOTICE=""
      fi
      redraw=0
      last_box=0
      UI_BEAT_LAST=""
    fi
    now="$(ui_now_ms)"
    if [ "$UI_HOLD_PCT" -gt 0 ]; then
      tui_draw_hold
      held=1
    elif [ $((now - last_box)) -ge 1000 ] || [ "$held" = 1 ]; then
      tui_draw_box "$cols" "$rows"
      last_box="$now"
      held=0
    fi
    printf '\033[%d;3H%s Select: %s\033[K' $((rows - 1)) "$C_CYN$UI_ARROW$C_RST" "$buf"
    tui_heartbeat "$cols" "$rows"
    key=""
    if ! read -rsn1 -t 0.1 key; then
      ui_hold_key "" || true
      continue
    fi
    if [ -n "$UI_JOB_SEL" ] && ui_hold_key "$key"; then
      job_cancel "$UI_JOB_SEL" nowait >/dev/null 2>&1 || true
      TUI_NOTICE="Cancelling process #$UI_JOB_SEL - it cleans up and then stops."
      redraw=1
      continue
    fi
    if [ "$UI_HOLD_PCT" -gt 0 ]; then
      continue
    fi
    case "$key" in
      [0-9]) buf="$buf$key" ;;
      $'\x7f'|$'\x08') buf="${buf%?}" ;;
      $'\t')
        ids="$(job_running_ids)"
        next="$(awk -v s="$UI_JOB_SEL" 'found { print; exit } $0 == s { found = 1 }' <<< "$ids")"
        UI_JOB_SEL="${next:-$(head -n 1 <<< "$ids")}"
        last_box=0
        ;;
      $'\033') read -rsn5 -t 0.01 rest || true ;;
      j|J) tui_run J; redraw=1 ;;
      h|H|\?) tui_run H; redraw=1 ;;
      q|Q)
        tput cup $((rows - 1)) 0
        echo
        if [ -n "$(job_running_ids)" ]; then
          info "Running processes continue in the background; start $SCRIPT_NAME again to see them."
        fi
        exit 0
        ;;
      "")
        if [ -n "$buf" ]; then
          if [ "$buf" = "0" ]; then
            tput cup $((rows - 1)) 0
            echo
            exit 0
          fi
          tui_run "$buf"
          buf=""
          redraw=1
        fi
        ;;
    esac
  done
}

tui_run() {
  clear_screen
  tput cnorm 2>/dev/null || true
  ui_echo
  menu_dispatch "$1" || true
  ui_echo
  if [ "$1" != "H" ] || ! command -v less >/dev/null 2>&1; then
    echo
    pause
  fi
  ui_noecho
}

menu() {
  local choice notice="${RVC_NOTICE:-}"
  INTERACTIVE="true"
  TUI_NOTICE="$notice"
  unset RVC_NOTICE
  trap 'printf "\n"' INT

  if [ -n "${RVC_HUB_STATUS:-}" ]; then
    HUB_STATUS="$RVC_HUB_STATUS"
    LATEST_VERSION="${RVC_LATEST_VERSION:-}"
    HUB_STABLE="${RVC_HUB_STABLE:-}"
    unset RVC_HUB_STATUS RVC_LATEST_VERSION RVC_HUB_STABLE
  else
    if [ "$CHECK_FOR_UPDATES" = "true" ]; then
      info "Checking Docker Hub for new Catalog versions..."
    fi
    check_latest_version
  fi

  if ui_fancy; then
    trap 'tput cnorm 2>/dev/null || true; stty echo 2>/dev/null || true' EXIT
    ui_noecho
    tui_menu || true
    ui_echo
  fi

  while true; do
    clear_screen
    show_menu
    if [ -n "$notice" ]; then
      ok "$notice"
      echo
      notice=""
    fi
    if [ -n "$SCRIPT_PATH" ] && [ -n "$(job_running_ids)" ]; then
      echo " Running processes (J shows, follows and cancels them):"
      while IFS= read -r choice; do
        printf '   #%s %s  %s\n' "$choice" "$(cat -- "$JOBS_DIR/$choice/title")" "$(job_summary "$choice")"
      done < <(job_running_ids)
      echo
    fi
    if ! read -r -p "Select an option: " choice; then
      echo
      exit 0
    fi
    echo
    case "$choice" in
      0|q|Q|exit|quit) exit 0 ;;
      "") continue ;;
    esac
    menu_dispatch "$choice" || true
    echo
    pause
  done
}

usage() {
  cat <<EOF
Usage: ./$SCRIPT_NAME [command]

Without a command, an interactive menu is shown.

Commands:
  menu                        Interactive menu (default)
  generate [--new-passwords]  Write $ENV_FILE and $COMPOSE_FILE.
                              Existing passwords are kept unless --new-passwords is given.
  validate                    Check the configuration (docker compose config)
  up                          Validate and start / update the stack (docker compose up -d)
  setup                       generate + validate + up
  status                      Show container status (docker compose ps)
  logs [service]              Follow the logs of all services or of one service
  pull                        Pull the images
  restart                     Restart all containers
  down                        Stop and remove the containers (data volumes are kept)
  credentials                 Show the generated credentials
  info                        Show URLs and Nginx Proxy Manager instructions
  check                       Check prerequisites (Docker, Compose, ports, vm.max_map_count, Docker Hub)
  timezone                    Use the time zone of this server for TZ (the job times are converted)
  updates                     Show available updates for all components
  upgrade                     Guided upgrade (asks first, then runs as a background job)
  self-update                 Update this installer from GitHub, keeping the settings
  adopt [FOLDER]              Take over an existing installation (its .env, docker-compose.yml and data)
  jobs [follow N|cancel N|log N]  Background tasks: list, follow, cancel (cleans up first), log
  download                    Download all images into a new offline bundle folder (+ .tar.gz)
  snapshot [daily|full]       Download the newest daily or full catalog snapshot (needs a stored API key)
  snapshot chain              Download the full snapshot and all changes up to today, in order
  snapshot since YYYY-MM-DD   Download only the changes after that date
  import FILE                 Import a snapshot file into the local catalog (needs a stored local key)
  import-chain [CHAINFILE]    Import a downloaded chain file by file (default: the newest chain)
  versions                    Show the newest Catalog versions on Docker Hub
  set-version VERSION|stable  Select the Catalog version (used by catalog-web and all workers)
  help                        Show this help
EOF
}

main() {
  local cmd="${1:-}"
  if [ "$#" -gt 0 ]; then
    shift
  fi
  cd -- "$WORK_DIR"

  case "$cmd" in
    "")
      if [ -t 0 ] && [ -t 1 ]; then
        menu
      else
        warn "No terminal detected - running 'generate' (existing passwords are kept). See './$SCRIPT_NAME help'."
        do_generate keep
      fi
      ;;
    menu) menu ;;
    generate)
      case "${1:-}" in
        "") do_generate keep ;;
        --new-passwords) do_generate new ;;
        *)
          err "Unknown option for generate: $1"
          usage
          return 2
          ;;
      esac
      ;;
    validate|config) do_validate ;;
    up|start) do_up ;;
    setup|install) do_generate keep no-next; echo; do_up ;;
    status|ps) do_status ;;
    logs) do_logs "${1:-}" ;;
    pull) do_pull ;;
    restart) do_restart ;;
    down|stop) do_down ;;
    credentials|creds) show_credentials ;;
    info|urls) show_access_info ;;
    check) do_check ;;
    timezone|tz) timezone_cli ;;
    __cron_convert) cron_convert "$@"; echo ;;
    updates) show_updates_cli ;;
    upgrade) INTERACTIVE="true"; do_upgrade ;;
    self-update) update_installer cli ;;
    adopt) adopt_installation cli "${1:-}" ;;
    jobs) jobs_cli "$@" ;;
    __job) job_run "$@" ;;
    download) download_bundle all ;;
    snapshot)
      case "${1:-daily}" in
        since) download_snapshot "since:${2:-}" cli ;;
        *) download_snapshot "${1:-daily}" cli ;;
      esac
      ;;
    import-chain) import_chain "${1:-$(ls -1t -- "$WORK_DIR"/snapshots/chain-*.tsv 2>/dev/null | head -n 1)}" cli ;;
    import) import_snapshot "${1:-}" cli ;;
    versions) list_versions ;;
    set-version) set_version_cli "${1:-}" ;;
    check-settings) check_settings ;;  # used by menu option 1 after editing
    help|-h|--help) usage ;;
    *)
      err "Unknown command: $cmd"
      usage
      return 2
      ;;
  esac
}

# Keep "main" and "exit" on one line: the menu can edit this file while it is
# running, and bash must not read any further from the changed file.
main "$@"; exit $?
