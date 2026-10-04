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
HEALTH_TIMEOUT="600"
INSTALLER_URL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/catalog.sh"

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
LAST_BACKUP=""
INTERACTIVE="false"
GENERATE_CANCELLED="false"
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

# Value of NAME="..." in the settings section of this script file.
script_setting() {
  if [ -z "$SCRIPT_PATH" ]; then
    return 0
  fi
  sed -n "s/^$1=\"\(.*\)\"\$/\1/p" "$SCRIPT_PATH" | head -n 1
}

# set_setting NAME VALUE [FILE] -> writes NAME="VALUE" into the settings section of this script (or of FILE).
set_setting() {
  local name="$1" value="$2" file="${3:-$SCRIPT_PATH}" tmp
  if [ -z "$file" ] || [ ! -w "$file" ]; then
    err "Cannot change ${file:-$SCRIPT_NAME} (not writable)."
    return 1
  fi
  tmp="$(mktemp)"
  if ! awk -v n="$name" -v v="$value" '
      !done && index($0, n "=\"") == 1 { print n "=\"" v "\""; done = 1; next }
      { print }
      END { exit !done }' "$file" > "$tmp"; then
    rm -f -- "$tmp"
    err "$name not found in $file."
    return 1
  fi
  # Write the content back instead of moving the file, so owner and mode stay.
  cat -- "$tmp" > "$file"
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
    echo "Selected in $SCRIPT_NAME: $(version_with_tag "$CATALOG_VERSION")"
    print_versions numbered
    echo "  0) Cancel"
    read -r -p "Select a version [0]: " choice || choice="0"
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
  local i=1 key first tag resolved versions newest current cat_resolved
  echo
  printf '%s\n\n' "${C_BLD}Raynet One Technology Catalog - Installation Portal - Updates${C_RST}   (checked $UPD_CHECKED - Docker Hub and GHCR)"
  printf '  %-2s %-24s %-34s %-30s %s\n' "#" "Component" "Current" "Newest" "Status"

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
    newest="$(version_with_tag "${HUB_VERSIONS%%$'\n'*}")"
  else
    row_status catalog "" ""
    newest="-"
  fi
  printf '  %-2s %-24s %-34s %-30s %s\n' "$i" "Catalog + 4 workers" "$(current_label "$CATALOG_VERSION" "${cat_resolved:-$CATALOG_VERSION}")" "$newest" "$ST_COLOR$ST_TEXT$C_RST"

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
    current="$(current_label "$tag" "$resolved")"
    printf '  %-2s %-24s %-34s %-30s %s\n' "$i" "$C_LABEL" "$current" "$newest" "$ST_COLOR$ST_TEXT$C_RST"
  done
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
    echo " $C_LABEL   current: $(current_label "$tag" "$resolved")"
    i=0
    while IFS= read -r v; do
      i=$((i + 1))
      marker=""
      if [ "$v" = "$resolved" ]; then
        marker="  (current)"
      elif [ "$C_KIND" != "minio" ] && [[ "$cur_major" =~ ^[0-9]+$ ]] && [ "$(version_major "$v")" -gt "$cur_major" ]; then
        marker="  ${C_YLW}(major update)${C_RST}"
      fi
      if [ "$key" = "mongo" ] && [ "$(version_major "$v")" -ge 8 ] && kernel_blocks_mongo8; then
        marker="$marker  ${C_RED}(may fail on this kernel)${C_RST}"
      fi
      printf '   %d) %s%s\n' "$i" "$(version_core "$v")" "$marker"
    done <<< "$list"
    echo "   0) Cancel"
    read -r -p " Select a version [0]: " choice || choice="0"
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
  for name in CATALOG_VERSION OPENSEARCH_TAG OPENSEARCH_DASHBOARDS_TAG MONGO_TAG RABBITMQ_TAG MINIO_TAG NGINX_PROXY_MANAGER_TAG; do
    value="$(script_setting "$name")" || value=""
    if [ -n "$value" ]; then
      printf -v "$name" '%s' "$value"
    fi
  done
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
    echo "  1-6) Pick a version    p) Pin floating tags to exact versions    r) Check again"
    echo "  s) Apply (generate + start)    d) Download only (offline bundle)    0) Back"
    read -r -p "Select: " choice || choice="0"
    case "$choice" in
      1) run_action select_version no-apply; reload_settings ;;
      [2-6]) run_action pick_component "${UPD_KEYS[$((choice - 2))]}"; reload_settings ;;
      p|P) run_action pin_floating_tags; reload_settings ;;
      r|R) collect_updates ;;
      s|S) run_action apply_updates ;;
      d|D) run_action download_bundle; reload_settings ;;
      0|"") return 0 ;;
      *) warn "Unknown option: $choice" ;;
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

# save_image ENGINE REF FILE EXPECTED_BYTES
save_image() {
  local engine="$1" ref="$2" out="$3" total="$4" pid cur
  if [ "$engine" = "podman" ]; then
    podman save --format docker-archive -o "$out" "$ref" &
  else
    docker save -o "$out" "$ref" &
  fi
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; exit 130' INT TERM
  while kill -0 "$pid" 2>/dev/null; do
    if [ -t 1 ]; then
      cur="$(stat -c %s -- "$out" 2>/dev/null)" || cur=0
      progress_bar save "${cur:-0}" "$total"
    fi
    sleep 1
  done
  trap - INT TERM
  if ! wait "$pid"; then
    echo
    err "Saving $ref failed."
    return 1
  fi
  cur="$(stat -c %s -- "$out")"
  progress_bar save "$cur" "$cur"
  echo
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
    if ! confirm "Create the archive anyway?" n; then
      return 0
    fi
  fi
  if command -v pigz >/dev/null 2>&1; then
    compressor="pigz -1"
  fi
  info "Creating $archive"
  tar -C "$base" -cf - -- "$name" | $compressor > "$archive" &
  pid=$!
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f -- "$archive"; exit 130' INT TERM
  while kill -0 "$pid" 2>/dev/null; do
    if [ -t 1 ] && [ -r "/proc/$pid/io" ]; then
      rchar="$(awk '/^rchar:/ { print $2 }' "/proc/$pid/io" 2>/dev/null)" || rchar=0
      progress_bar pack "${rchar:-0}" "$total"
    fi
    sleep 1
  done
  trap - INT TERM
  if ! wait "$pid"; then
    echo
    rm -f -- "$archive"
    err "Creating $archive failed."
    return 1
  fi
  progress_bar pack "$total" "$total"
  echo
  (cd -- "$base" && sha256sum -- "$name.tar.gz" > "$name.tar.gz.sha256")
  ok "Archive: $archive ($(human_size "$(stat -c %s -- "$archive")")), checksum in $name.tar.gz.sha256"
}

# scp_bundle PATH... -> asks for the target and copies the paths with scp
scp_bundle() {
  local host scp_host port user target rt auth key pw ctl f rc=0 verify name kh kf known="$HOME/.ssh/known_hosts"
  local -a ssh_opts=() pass=() recursive=()
  echo
  read -r -p "  Host (IP or DNS)  : " host || host=""
  if [ -z "$host" ]; then
    info "Cancelled."
    return 0
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
  ssh_opts=(-o "Port=$port" -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known")
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
      return 0
    fi
    mkdir -p -- "$HOME/.ssh"
    chmod 700 -- "$HOME/.ssh"
    cat -- "$kf" >> "$known"
    rm -f -- "$kf"
  fi
  if [ "${auth:-2}" = "1" ]; then
    read -r -p "  Key file [default]: " key || key=""
    if [ -n "$key" ]; then
      ssh_opts+=(-i "$key")
    fi
  else
    ssh_opts+=(-o PubkeyAuthentication=no)
    if command -v sshpass >/dev/null 2>&1; then
      read -r -s -p "  Password          : " pw || pw=""
      echo
      export SSHPASS="$pw"
      pw=""
      pass=(sshpass -e)
    else
      info "sshpass is not installed - ssh asks for the password itself (once)."
    fi
  fi
  if [ "${#pass[@]}" -eq 0 ]; then
    ctl="$(mktemp -d)"
    ssh_opts+=(-o ControlMaster=auto -o "ControlPath=$ctl/%C" -o ControlPersist=300)
  fi

  info "Connecting to $user@$host:$port"
  if ! ${pass[@]+"${pass[@]}"} ssh "${ssh_opts[@]}" "$user@$host" "mkdir -p -- '$rt'"; then
    err "Could not connect to $host or create $target there."
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    for f in "$@"; do
      recursive=()
      if [ -d "$f" ]; then
        recursive=(-r)
      fi
      info "Copying $(basename -- "$f")"
      if ! ${pass[@]+"${pass[@]}"} scp "${ssh_opts[@]}" ${recursive[@]+"${recursive[@]}"} -- "$f" "$user@$scp_host:$rt/"; then
        err "Copying $f failed."
        rc=1
        break
      fi
    done
  fi
  if [ "$rc" -eq 0 ]; then
    name="$(basename -- "$1")"
    if [ -d "$1" ]; then
      verify="cd -- '$rt/$name' && sha256sum -c --quiet SHA256SUMS"
    else
      verify="cd -- '$rt' && sha256sum -c --quiet -- '$name.sha256'"
    fi
    info "Verifying the copy on $host"
    if ${pass[@]+"${pass[@]}"} ssh "${ssh_opts[@]}" "$user@$host" "$verify"; then
      ok "Copied to $user@$host:$target - checksums match."
      if [ -d "$1" ]; then
        echo "  On $host: cd $target/$name && ./import-images.sh"
      else
        echo "  On $host: cd $target && tar -xzf $name && cd ${name%.tar.gz} && ./import-images.sh"
      fi
    else
      err "Checksum verification on $host failed - copy again."
      rc=1
    fi
  fi

  unset SSHPASS
  if [ -n "${ctl:-}" ]; then
    ssh "${ssh_opts[@]}" -O exit "$user@$host" >/dev/null 2>&1 || true
    rm -rf -- "$ctl"
  fi
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
  local mode="${1:-interactive}" engine ref pref choice tok base name dir file id size free_kb count=0 n=0 i floating=0 installer archive
  local -a images=() picked=() toks=()
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
      echo " Download only - offline bundle   (engine: $engine, platform: linux/amd64)"
      for i in "${!images[@]}"; do
        if [ "${picked[i]}" = "1" ]; then
          printf '   [x] %d  %s\n' "$((i + 1))" "${images[i]}"
        else
          printf '   [ ] %d  %s\n' "$((i + 1))" "${images[i]}"
        fi
      done
      echo " Toggle with numbers (e.g. 1 3), a = all, n = none, Enter = start, 0 = cancel"
      read -r -p " > " choice || choice="0"
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
  mkdir -p -- "$dir/images"
  BUNDLE_PARTIAL="$dir"
  trap 'if [ -n "${BUNDLE_PARTIAL:-}" ]; then rm -rf -- "$BUNDLE_PARTIAL"; echo; warn "Incomplete bundle removed: $BUNDLE_PARTIAL"; fi' EXIT
  : > "$dir/images.txt"
  free_kb="$(df -Pk -- "$base" | awk 'NR == 2 { print $4 }')" || free_kb=0
  info "Bundle folder: $dir (free space: $(human_size "$((free_kb * 1024))"))"

  for i in "${!images[@]}"; do
    if [ "${picked[i]}" != "1" ]; then
      continue
    fi
    n=$((n + 1))
    ref="${images[i]}"
    echo
    info "[$n/$count] $ref"
    pref="$(qualify_ref "$ref")"
    "$engine" pull --platform linux/amd64 "$pref"
    id="$("$engine" image inspect --format '{{.Id}}' "$pref")"
    id="${id#sha256:}"
    size="$("$engine" image inspect --format '{{.Size}}' "$pref")"
    free_kb="$(df -Pk -- "$dir" | awk 'NR == 2 { print $4 }')" || free_kb=0
    if [ "$size" -gt $((free_kb * 1024)) ]; then
      err "Not enough free space in $base for $ref ($(human_size "$size") needed)."
      return 1
    fi
    file="images/$(printf '%s' "$ref" | tr '/:' '__').tar"
    save_image "$engine" "$pref" "$dir/$file" "$size"
    printf '%s|%s|%s\n' "$ref" "$file" "$id" >> "$dir/images.txt"
  done

  installer=""
  if [ -n "$SCRIPT_PATH" ]; then
    installer="$(basename -- "$SCRIPT_PATH")"
    cp -- "$SCRIPT_PATH" "$dir/$installer"
    set_setting CHECK_FOR_UPDATES false "$dir/$installer"
    chmod +x "$dir/$installer"
  fi
  write_import_script "$dir/import-images.sh" "${installer:-catalog.sh}"
  (cd -- "$dir" && sha256sum -- images/*.tar images.txt import-images.sh ${installer:+"$installer"} > SHA256SUMS)
  BUNDLE_PARTIAL=""
  trap - EXIT
  echo
  ok "Bundle ready: $dir ($(du -sh -- "$dir" | cut -f1))"
  echo "  images/ ($count image(s)), images.txt, SHA256SUMS, import-images.sh${installer:+, $installer}"
  echo "  No $ENV_FILE / $COMPOSE_FILE inside - the target machine generates its own (with new passwords)."

  archive=""
  if [ "$mode" = "all" ] || confirm "Create $name.tar.gz?" y; then
    make_archive "$dir"
    if [ -f "$base/$name.tar.gz" ]; then
      archive="$base/$name.tar.gz"
    fi
  fi
  if [ "$mode" = "interactive" ] && confirm "Copy the bundle to another machine with scp?" n; then
    if [ -n "$archive" ]; then
      scp_bundle "$archive" "$archive.sha256"
    else
      scp_bundle "$dir"
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
      lkey="$(tr -d ' 
	' < "$LOCAL_KEY_FILE")"
    fi
    echo
    echo " API keys"
    printf '   Online catalog (%s): %s
' "$CATALOG_CLOUD_URL" "$(if [ -n "$key" ]; then api_key_mask "$key"; else printf 'none'; fi)"
    printf '   Local catalog  (%s): %s
' "$(local_url)" "$(if [ -n "$lkey" ]; then api_key_mask "$lkey"; else printf 'none'; fi)"
    echo "   1) Show the online key          5) Show the local key"
    echo "   2) Add / change the online key  6) Add / change the local key"
    echo "   3) Test the online key          7) Test the local key"
    echo "   4) Delete the online key        8) Delete the local key"
    echo "   0) Back"
    echo " New keys are tested before they are saved."
    read -r -p " Select: " choice || choice="0"
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

# Manifest -> one line per snapshot: type, date, size, checksum, path, based-on date (tab separated).
manifest_rows() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '([.latestFullSnapshot | select(.) | ["full", .date, (.sizeBytes | tostring), (.checksum // ""), .downloadPath, ""]]
      + [.dailyDeltas[]? | ["daily", .date, (.sizeBytes | tostring), (.checksum // ""), .downloadPath, (.basedOnDate // "")]])[] | @tsv'
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
for r in rows:
    print("\t".join(r))
' | tr -d '\r'
  else
    err "Reading the snapshot list needs jq or python3 (apt-get install jq)."
    return 1
  fi
}

# download_snapshot [daily|full] [interactive|cli]
download_snapshot() {
  local kind="${1:-}" mode="${2:-interactive}" key rows daily full row choice
  local type date size checksum path based dir dest code actual free_kb
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
    echo
    echo " Snapshots on $CATALOG_CLOUD_URL"
    if [ -n "$daily" ]; then
      IFS=$'\t' read -r type date size checksum path based <<< "$daily"
      printf '   1) Latest daily snapshot   %s   %10s   (applies on top of %s)\n' "$date" "$(human_size "$size")" "${based:-the previous state}"
    else
      echo "   1) Latest daily snapshot   - none available"
    fi
    if [ -n "$full" ]; then
      IFS=$'\t' read -r type date size checksum path based <<< "$full"
      printf '   2) Latest full snapshot    %s   %10s   (for a new installation)\n' "$date" "$(human_size "$size")"
    else
      echo "   2) Latest full snapshot    - none available"
    fi
    echo "   0) Cancel"
    read -r -p " Select [1]: " choice || choice="0"
    case "${choice:-1}" in
      1) kind="daily" ;;
      2) kind="full" ;;
      *) info "Cancelled."; return 0 ;;
    esac
  fi
  case "${kind:-daily}" in
    daily) row="$daily" ;;
    full) row="$full" ;;
    *) err "Unknown snapshot type: $kind (daily or full)"; return 2 ;;
  esac
  if [ -z "$row" ]; then
    err "No ${kind:-daily} snapshot is available."
    return 1
  fi
  IFS=$'\t' read -r type date size checksum path based <<< "$row"
  if [[ "$path" == *..* ]] || ! [[ "$path" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    err "Unexpected snapshot path in the manifest: $path"
    return 1
  fi

  dir="$WORK_DIR/snapshots"
  mkdir -p -- "$dir"
  dest="$dir/$date-$type.tar.gz"
  if [ -f "$dest" ] && [ -n "$checksum" ] && [ "$(sha256sum -- "$dest" | cut -d' ' -f1)" = "${checksum#sha256:}" ]; then
    ok "Already downloaded: $dest"
    return 0
  fi
  free_kb="$(df -Pk -- "$dir" | awk 'NR == 2 { print $4 }')" || free_kb=0
  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt $((free_kb * 1024)) ]; then
    err "Not enough free space in $dir: $(human_size "$size") needed, $(human_size "$((free_kb * 1024))") free."
    return 1
  fi

  info "Downloading the $type snapshot of $date ($(human_size "$size"))"
  trap 'rm -f -- "$dest.part"; exit 130' INT TERM
  code="$(cloud_get "$key" "/v3/synchronization/snapshot/$path" "$dest.part" download)"
  trap - INT TERM
  if [ "$code" != "200" ]; then
    rm -f -- "$dest.part"
    case "$code" in
      401|403) err "Download refused (HTTP $code) - check the API key (menu option 18)." ;;
      000) err "Download failed: $CATALOG_CLOUD_URL is not reachable." ;;
      *) err "Download failed (HTTP $code)." ;;
    esac
    return 1
  fi
  if [ -n "$checksum" ]; then
    actual="$(sha256sum -- "$dest.part" | cut -d' ' -f1)"
    if [ "$actual" != "${checksum#sha256:}" ]; then
      rm -f -- "$dest.part"
      err "Checksum mismatch - the download is broken, try again."
      return 1
    fi
  else
    warn "The manifest has no checksum for this snapshot - not verified."
  fi
  if [ "$(head -c 2 -- "$dest.part" | od -An -tx1 | tr -d ' \n')" != "1f8b" ]; then
    rm -f -- "$dest.part"
    err "The download is not a .tar.gz archive."
    return 1
  fi
  mv -f -- "$dest.part" "$dest"
  ok "Snapshot saved: $dest ($(human_size "$(stat -c %s -- "$dest")"), sha256 verified)"
  if [ "$type" = "daily" ]; then
    echo "  A daily snapshot applies on top of a catalog at ${based:-the previous day}; a new installation needs the full snapshot."
  fi
  if [ "$mode" = "interactive" ]; then
    if confirm "Import it into the local catalog now?" n; then
      import_snapshot "$dest"
    else
      echo "  Import it later with option 19."
    fi
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
    if [[ "$progress" =~ ^[0-9]+$ ]] && [ -t 1 ]; then
      progress_bar import "$progress" 100
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

# import_snapshot FILE [interactive|cli]
import_snapshot() {
  local file="$1" mode="${2:-interactive}" resp code opid size
  local -a progress=(-sS)
  if [ ! -f "$file" ]; then
    err "File not found: $file"
    return 1
  fi
  if [ "$(head -c 2 -- "$file" | od -An -tx1 | tr -d ' \n')" != "1f8b" ]; then
    err "$file is not a .tar.gz snapshot."
    return 1
  fi
  size="$(stat -c %s -- "$file")"
  if [ "$size" -gt $((8 * 1024 * 1024 * 1024)) ]; then
    warn "The file is larger than 8 GB, the default upload limit of the catalog (Synchronization__MaxUploadFileSize)."
  fi
  if [[ "$(basename -- "$file")" == *-daily.tar.gz ]] && [ "$mode" = "interactive" ]; then
    warn "A daily snapshot only applies on top of a catalog that has the previous day's data."
    if ! confirm "Import $(basename -- "$file") anyway?" y; then
      info "Cancelled."
      return 0
    fi
  fi
  local_auth_obtain "$mode" || return 1

  info "Uploading $(basename -- "$file") ($(human_size "$size")) to $(local_url)"
  if [ -t 2 ]; then
    progress=(--progress-bar)
  fi
  resp="$(mktemp)"
  code="$(printf 'header = "%s"\n' "$LOCAL_AUTH" | curl "${progress[@]}" -K - -H 'Accept: application/json' \
    --connect-timeout 5 -F "file=@$file;type=application/gzip" -o "$resp" -w '%{http_code}' \
    "$(local_url)/v1/synchronization/snapshot" || true)"
  opid="$(json_field operationId "$resp")"
  rm -f -- "$resp"
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
  local files=() f i choice
  while IFS= read -r f; do
    files+=("$f")
  done < <(ls -1t -- "$WORK_DIR"/snapshots/*.tar.gz 2>/dev/null)
  if [ "${#files[@]}" -eq 0 ]; then
    warn "No snapshot in $WORK_DIR/snapshots - download one with option 17."
    return 0
  fi
  echo " Snapshots in $WORK_DIR/snapshots (newest first):"
  for i in "${!files[@]}"; do
    printf '   %d) %s  %s\n' "$((i + 1))" "$(basename -- "${files[i]}")" "$(human_size "$(stat -c %s -- "${files[i]}")")"
  done
  echo "   0) Cancel"
  read -r -p " Select [1]: " choice || choice="0"
  choice="${choice:-1}"
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
    import_snapshot "${files[choice - 1]}"
  else
    info "Cancelled."
  fi
}

# Online servers: the local catalog gets the online catalog URL and key and synchronizes itself
# (daily by AUTOSYNC_CRON afterwards).
local_self_sync() {
  local key cur body out code tmp opid
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
  tmp="$(mktemp)"
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
    if [ -t 1 ]; then
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
  if (umask 077 && compose exec -T mongo sh -c '
      umask 077
      printf "password: \"%s\"\n" "$MONGO_INITDB_ROOT_PASSWORD" > /tmp/.rvc-dump.yml
      mongodump --quiet --archive --gzip --config=/tmp/.rvc-dump.yml \
        --username "$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase admin
      rc=$?
      rm -f /tmp/.rvc-dump.yml
      exit $rc' > "$file") && [ -s "$file" ]; then
    chmod 600 "$file"
    ok "Backup written ($(human_size "$(stat -c %s -- "$file")"))."
    LAST_BACKUP="$file"
  else
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
  local -a keys=() froms=() tos=() picked=() toks=()
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
    echo " Patch updates in the same series (bug and security fixes, no data migration):"
    for i in "${!keys[@]}"; do
      component_info "${keys[i]}"
      printf '   [%s] %d  %-24s %s -> %s\n' "$(if [ "${picked[i]}" = 1 ]; then printf x; else printf ' '; fi)" "$((i + 1))" "$C_LABEL" "$(version_core "${froms[i]}")" "$(version_core "${tos[i]}")"
    done
    echo " Toggle with numbers, Enter = apply the selected ones, 0 = skip"
    read -r -p " > " choice || choice="0"
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
        set_setting "$first" "${tos[i]}"
        printf -v "$first" '%s' "${tos[i]}"
      done
      count=$((count + 1))
    fi
  done
  if [ "$count" -eq 0 ]; then
    info "No patch updates applied."
    return 0
  fi
  do_generate keep no-next
  info "Pulling the new images"
  compose pull
  info "Recreating the changed services"
  compose up -d --remove-orphans
  stack_health
}

do_upgrade() {
  local installed target old_version answer
  require_files || return 1
  require_docker || return 1
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
EOF
    if ! confirm "Upgrade the Catalog to $target now? (the Catalog is offline during steps 3 to 6)" n; then
      info "Cancelled - nothing was changed."
      return 0
    fi
    LAST_BACKUP=""
    if confirm "Create the MongoDB backup first?" y; then
      if ! mongo_backup && ! confirm "Continue without a backup?" n; then
        info "Cancelled - nothing was changed."
        return 0
      fi
    fi
    old_version="$CATALOG_VERSION"
    set_setting CATALOG_VERSION "$target"
    CATALOG_VERSION="$target"
    do_generate keep no-next
    info "Pulling the images of $target"
    if ! compose pull catalog-web worker-recognition-1 worker-recognition-2 worker-other worker-search; then
      err "Pulling the images failed - the running version was not touched."
      set_setting CATALOG_VERSION "$old_version"
      CATALOG_VERSION="$old_version"
      do_generate keep no-next
      return 1
    fi
    info "Stopping the stack (docker compose down)"
    compose down --remove-orphans
    info "Starting $target (docker compose up -d)"
    compose up -d --remove-orphans
    if stack_health && [ "$(running_tag catalog-web)" = "$target" ]; then
      ok "Catalog upgraded: $installed -> $target."
    else
      err "The upgrade to $target is not healthy."
      compose ps || true
      echo "  Last log lines of catalog-web:"
      compose logs --tail=30 catalog-web 2>/dev/null | sed 's/^/    /' || true
      if confirm "Go back to $old_version?" n; then
        set_setting CATALOG_VERSION "$old_version"
        CATALOG_VERSION="$old_version"
        do_generate keep no-next
        compose up -d --remove-orphans
        stack_health || true
        if [ -n "$LAST_BACKUP" ]; then
          warn "If $target already migrated the database, restore the backup:"
          echo "      docker compose exec -T mongo sh -c 'mongorestore --drop --archive --gzip -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin' < $LAST_BACKUP"
        fi
      fi
      return 1
    fi
  fi
  offer_patch_updates
}

###############################################################################
# Installer update
###############################################################################

# Downloads the newest installer and carries the current settings over to it.
update_installer() {
  local mode="${1:-interactive}" tmp line name value backup
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "Cannot update ${SCRIPT_PATH:-the installer} (not a writable file)."
    return 1
  fi
  tmp="$(mktemp)"
  info "Downloading the newest installer from $INSTALLER_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --connect-timeout 10 --max-time 120 -o "$tmp" "$INSTALLER_URL" || : > "$tmp"
  else
    wget -q -T 120 -O "$tmp" "$INSTALLER_URL" || : > "$tmp"
  fi
  if ! head -n 1 "$tmp" | grep -q '^#!/usr/bin/env bash' || ! grep -q '^# CONFIGURE ONLY THIS SECTION' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    err "The download failed or is not a valid installer."
    return 1
  fi
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=\"(.*)\"$ ]]; then
      name="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if grep -q "^$name=\"" "$tmp"; then
        set_setting "$name" "$value" "$tmp"
      fi
    fi
  done < <(sed -n '/^# CONFIGURE ONLY THIS SECTION/,/^# DO NOT CHANGE ANYTHING BELOW/p' "$SCRIPT_PATH")
  if [ "$(cksum < "$tmp")" = "$(cksum < "$SCRIPT_PATH")" ]; then
    rm -f -- "$tmp"
    ok "The installer is up to date."
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
  backup="$SCRIPT_PATH.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$SCRIPT_PATH" "$backup"
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
      if [ -z "$dir" ] || [ "$dir" = "$WORK_DIR" ] || [[ "$seen" == *" $dir "* ]]; then
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
    if [ "$d" = "$WORK_DIR" ] || [[ "$seen" == *" $d "* ]] || ! grep -q 'rayventory-catalog' "$f" 2>/dev/null; then
      continue
    fi
    seen="$seen$d "
    printf '%s|%s|%s|%s|%s|%s\n' "$(project_name_of "$(basename -- "$d")")" "$d" "$f" "$d/.env" "" "not running"
  done < <(find /root /home /opt /srv -maxdepth 3 \( -name docker-compose.yml -o -name docker-compose.yaml -o -name compose.yml -o -name compose.yaml \) 2>/dev/null || true)
}

# Value of KEY in an env file (any file, not only ours).
env_file_value() {
  sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -n 1 | tr -d '\r'
}

# adopt_installation [interactive|cli] [FOLDER]
adopt_installation() {
  local mode="${1:-interactive}" wanted="${2:-}" line choice project dir cfg envf image status i version key value imported=0 skipped="" backup tmp_env tmp_compose
  local -a cands=()
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "Cannot change ${SCRIPT_PATH:-the installer} (not a writable file)."
    return 1
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

  backup="$SCRIPT_PATH.bak-$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$SCRIPT_PATH" "$backup"
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
    value="${BASH_REMATCH[2]}"
    value="${value#\"}"
    value="${value%\"}"
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
    elif grep -q "^$key=\"" "$SCRIPT_PATH"; then
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
  cp -- "$SCRIPT_PATH" "$tmp_env/catalog.sh"
  cp -p -- "$ENV_FILE" "$tmp_env/.env"
  (cd -- "$tmp_env" && bash catalog.sh generate </dev/null >/dev/null 2>&1) || true
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
VULNERABILITIES_CACHING_CRON=${VULNERABILITIES_CACHING_CRON}
ASPNETCORE_URLS=${ASPNETCORE_URLS}
ASPNETCORE_HTTP_PORTS=${ASPNETCORE_HTTP_PORTS}
LOG_LEVEL_DEFAULT=${LOG_LEVEL_DEFAULT}
EOF
  if [ -n "$COMPOSE_PROJECT_NAME" ]; then
    printf '
COMPOSE_PROJECT_NAME=%s
' "$COMPOSE_PROJECT_NAME" >> "$ENV_FILE"
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
  local mode="${1:-ask}" next="${2:-show-next}" choice var value pw_file="" volumes
  GENERATE_CANCELLED="false"

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
  read -r -p "Type DELETE to continue: " answer || answer=""
  if [ "$answer" != "DELETE" ]; then
    info "Cancelled."
    return 0
  fi
  compose down -v --remove-orphans
  ok "Containers and data volumes removed."
  echo "Optionally generate new passwords (option 2), then start again (option 6)."
}

do_check() {
  local problems=0 name port mmc
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
    0) ;;
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
  local found
  printf '%s\n' "${C_BLD}Raynet One Technology Catalog - Installation Portal${C_RST}   ($(version_label))"
  printf 'Folder : %s\n' "$WORK_DIR"
  printf 'Files  : %s %s   %s %s\n' "$ENV_FILE" "$(file_state "$ENV_FILE")" "$COMPOSE_FILE" "$(file_state "$COMPOSE_FILE")"
  printf 'Stack  : %s\n' "$(stack_state)"
  if [ ! -f "$ENV_FILE" ]; then
    found="$(find_installations 2>/dev/null | head -n 1 | cut -d'|' -f2)" || found=""
    if [ -n "$found" ]; then
      printf '%s\n' "${C_YLW}A Catalog installation already exists in $found - option 23 takes it over (settings, passwords, data).${C_RST}"
    fi
  fi
  if settings_stale; then
    printf '%s\n' "${C_YLW}The generated files do not match the settings above (changed settings or manual edits) - option 2 regenerates them.${C_RST}"
  fi
  cat <<EOF

 Setup
   1) Edit configuration (opens this script in $(editor_name))
   2) Generate .env and docker-compose.yml
   3) Review / edit .env
   4) Review / edit docker-compose.yml
   5) Validate configuration (docker compose config)
   6) Start the stack / apply changes (docker compose up -d)
   7) Full setup: generate + validate + start
   8) Updates and offline download (all components)

 Operations
   9) Status (docker compose ps)
  10) Logs
  11) Pull images
  12) Restart the stack
  13) Stop the stack (docker compose down, data is kept)
  14) Show credentials
  15) Show URLs and Nginx Proxy Manager instructions
  16) Check prerequisites

 Catalog data
  17) Download the daily catalog snapshot (rayventorycatalog.raynet.de)
  18) API keys: show, change, test, delete
  19) Import a downloaded snapshot into the local catalog
  20) Let the local catalog synchronize itself daily (online servers)

 Upgrade
  21) Guided upgrade: Catalog to the newest version, health check, patch updates
  22) Update this installer from GitHub (your settings are kept)
  23) Take over an existing installation on this host (reads its .env and docker-compose.yml)

  99) Reset: remove containers AND all data volumes
   0) Exit

EOF
}

menu() {
  local choice notice="${RVC_NOTICE:-}"
  INTERACTIVE="true"
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

  while true; do
    clear_screen
    show_menu
    if [ -n "$notice" ]; then
      ok "$notice"
      echo
      notice=""
    fi
    if ! read -r -p "Select an option: " choice; then
      echo
      exit 0
    fi
    echo
    case "$choice" in
      1)  edit_config ;;
      2)  run_action do_generate ask ;;
      3)  run_action edit_generated "$ENV_FILE" ;;
      4)  run_action edit_generated "$COMPOSE_FILE" ;;
      5)  run_action do_validate ;;
      6)  run_action do_up ;;
      7)  run_action do_full_setup ;;
      8)  run_action do_updates; reload_settings ;;
      9)  run_action do_status ;;
      10) run_action do_logs ;;
      11) run_action do_pull ;;
      12) run_action do_restart ;;
      13) run_action do_down ;;
      14) run_action show_credentials ;;
      15) run_action show_access_info ;;
      16) run_action do_check ;;
      17) run_action download_snapshot ;;
      18) run_action api_key_menu ;;
      19) run_action import_snapshot_menu ;;
      20) run_action local_self_sync ;;
      21) run_action do_upgrade ;;
      22) update_installer || true ;;
      23) adopt_installation || true ;;
      99) run_action do_reset ;;
      0|q|Q|exit|quit) exit 0 ;;
      "") continue ;;
      *)  warn "Unknown option: $choice" ;;
    esac
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
  updates                     Show available updates for all components
  upgrade                     Guided upgrade (asks before every step)
  self-update                 Update this installer from GitHub, keeping the settings
  adopt [FOLDER]              Take over an existing installation (its .env, docker-compose.yml and data)
  download                    Download all images into a new offline bundle folder (+ .tar.gz)
  snapshot [daily|full]       Download the newest catalog snapshot (needs a stored API key)
  import FILE                 Import a snapshot file into the local catalog (needs a stored local key)
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
    updates) show_updates_cli ;;
    upgrade) INTERACTIVE="true"; do_upgrade ;;
    self-update) update_installer cli ;;
    adopt) adopt_installation cli "${1:-}" ;;
    download) download_bundle all ;;
    snapshot) download_snapshot "${1:-daily}" cli ;;
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
