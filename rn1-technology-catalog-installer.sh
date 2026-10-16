#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi
set -euo pipefail

# macOS: Homebrew, a current bash and the GNU tools come first - checked one by one, installed only
# after a yes. This part runs in the bash 3.2 of macOS.
rn1_mac_yes() {
  local answer=""
  printf '%s [Y/n] ' "$1"
  if ! read -r answer; then
    echo
    return 1
  fi
  if [ ! -t 0 ]; then
    echo
  fi
  case "$answer" in
    ""|[Yy]|[Yy][Ee][Ss]) return 0 ;;
  esac
  return 1
}

rn1_mac_brew() {
  local d
  for d in ${RN1_BREW_DIRS-/opt/homebrew/bin /usr/local/bin}; do
    if [ -x "$d/brew" ]; then
      printf '%s' "$d/brew"
      return 0
    fi
  done
  command -v brew 2>/dev/null
}

# The proxy of the settings (option 26) with its login, for the downloads of Homebrew, which passes on only
# the lower-case variables; a proxy the shell already has stays
rn1_mac_proxy() {
  local p l=""
  if [ -n "${https_proxy:-}" ] || [ ! -r "$0" ]; then
    return 0
  fi
  p="$(sed -n 's/^INTERNET_PROXY="\([^"]*\)"$/\1/p' "$0")"
  p="${p%%$'\n'*}"
  if [ -z "$p" ]; then
    return 0
  fi
  # the login only when .proxy_login belongs to this proxy (its line proxy=, when it has one)
  if [ -r "$(dirname "$0")/.proxy_login" ]; then
    l="$(tr -d ' \r\t' < "$(dirname "$0")/.proxy_login" | awk -v p="$p" '/^proxy=/ { s = 1; ok = (substr($0, 7) == p); next } $0 != "" && l == "" { l = $0 } END { if (!s || ok) print l }')"
  fi
  if [ -n "$l" ]; then
    p="${p%%://*}://$l@${p#*://}"
  fi
  export http_proxy="$p" https_proxy="$p" RN1_PROXY_SET="yes"
}

rn1_mac_bootstrap() {
  local brew prefix t hb missing="" url="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
  if [ "$(id -u)" = "0" ]; then
    echo "ERROR On macOS run $0 as your normal user, not as root: Homebrew and the Podman machine belong to the user." >&2
    exit 1
  fi
  rn1_mac_proxy
  brew="$(rn1_mac_brew)" || brew=""
  if [ -z "$brew" ]; then
    echo "==> Homebrew is not installed. The installer needs it: macOS has bash 3.2, and the installer"
    echo "    needs a current bash and the GNU tools (coreutils, gnu-sed, grep, findutils) from Homebrew."
    echo "    It is installed with the official script of https://brew.sh (it asks for your password):"
    echo "      /bin/bash -c \"\$(curl -fsSL $url)\""
    if [ ! -t 0 ]; then
      echo "Homebrew's installer needs a terminal (your password, RETURN): run the command above, then start $0 again." >&2
      exit 1
    fi
    if ! rn1_mac_yes "Install Homebrew now?"; then
      echo "Nothing was installed. Install Homebrew from https://brew.sh, then start $0 again." >&2
      exit 1
    fi
    if ! hb="$(curl -fsSL "$url")" || [ -z "$hb" ]; then
      echo "ERROR The Homebrew install script could not be downloaded: $url (network, proxy?)" >&2
      exit 1
    fi
    if ! /bin/bash -c "$hb"; then
      echo "ERROR Homebrew could not be installed (see above)." >&2
      exit 1
    fi
    brew="$(rn1_mac_brew)" || brew=""
    if [ -z "$brew" ]; then
      echo "ERROR Homebrew was installed, but its brew command is not found." >&2
      exit 1
    fi
    echo " OK Homebrew is installed. For new terminals, run the commands Homebrew showed under \"Next steps\"."
  fi
  prefix="$("$brew" --prefix)"
  PATH="$prefix/bin:$prefix/sbin:$PATH"
  export PATH
  for t in bash coreutils gnu-sed grep findutils; do
    if [ ! -d "$prefix/opt/$t" ]; then
      missing="$missing $t"
    fi
  done
  if [ -n "$missing" ]; then
    echo "==> Homebrew installs what the installer needs here:$missing"
    echo "      brew install$missing"
    if ! rn1_mac_yes "Install them now?"; then
      echo "Nothing was installed. The installer needs them: brew install$missing" >&2
      exit 1
    fi
    # shellcheck disable=SC2086
    if ! "$brew" install $missing; then
      echo "ERROR brew install$missing failed (see above)." >&2
      exit 1
    fi
  fi
  export RN1_MAC_BOOTSTRAPPED=1
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    export RN1_BASH_REEXEC=1
    exec "$prefix/opt/bash/bin/bash" "$0" ${1+"$@"}
  fi
}

if [ -z "${RN1_MAC_BOOTSTRAPPED:-}" ] && [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
  rn1_mac_bootstrap ${1+"$@"}
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$b" ] && [ "${RN1_BASH_REEXEC:-}" != "1" ]; then
      export RN1_BASH_REEXEC=1
      exec "$b" "$0" ${1+"$@"}
    fi
  done
  echo "ERROR bash 4.2 or newer is needed (this is bash $BASH_VERSION). On macOS: brew install bash coreutils gnu-sed grep findutils" >&2
  exit 1
fi

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

# Container engine: podman, docker or colima (macOS); empty: the one that holds this installation
CONTAINER_ENGINE=""
# Domain and HTTPS (option 24); an empty domain uses the address of the server
CATALOG_DOMAIN=""
NPM_ADMIN_EMAIL=""

# Internet access (option 26): the proxy, e.g. http://proxy.example.com:8080 (its login is not kept here),
# the internal names reached without it, the root certificate of a network that inspects HTTPS, the PAC file
INTERNET_PROXY=""
INTERNET_NO_PROXY=""
INTERNET_PROXY_CA_FILE=""
INTERNET_PROXY_PAC=""

# Image Tags
NGINX_PROXY_MANAGER_TAG="2"
OPENSEARCH_TAG="2"
OPENSEARCH_DASHBOARDS_TAG="2"
MONGO_TAG="8.0"
MINIO_TAG="RELEASE.2025-10-15T17-29-55Z"
RABBITMQ_TAG="3.13-management-alpine"

CATALOG_VERSION="26.3.4789.148"
CATALOG_IMAGE_REPO="raynetgmbh/rayventory-catalog"
CATALOG_WORKER_IMAGE_REPO="raynetgmbh/rayventory-catalog-worker"
CHECK_FOR_UPDATES="true"

# Mongo
MONGO_INITDB_ROOT_USERNAME="raymaster_rc"
MONGO_INITDB_DATABASE="raymaster_rc"
MONGO_AUTH_DATABASE="admin"
MONGO_PORT_HOST="27017"
# Cache of MongoDB in GB, e.g. 4 or 2.5; empty: automatic, (memory of the engine - 10 GB) / 2
MONGO_CACHE_GB=""

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
# Host name of catalog-web, which the license is bound to; empty: as in .env, else the one a licensed catalog-web
# has, else the short name of this server
CATALOG_HOSTNAME=""
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

# The settings section above as published, by its cksum ("CRC BYTES" of the lines from '# CONFIGURE ONLY THIS
# SECTION' to '# DO NOT CHANGE ANYTHING BELOW', each with its newline - settings_sum). While the line below
# has it and the section still has it, the settings are the defaults of a new download (settings_pristine),
# which takes the values of an installation in its folder over by itself. That state is one way: the first
# time a start finds the section changed, a check finds nothing to take over, or the installer writes a
# setting into this file (settings_unpublish), the value goes - SETTINGS_PUBLISHED_SUM="" - and a section
# that was put back to the defaults by hand is no new download again. A self-update brings the value of the new
# version only into a file that is still a new download and stays one. After a change of the section the
# maintainer sets the new value (tests/check_settings_hash.sh fails until then):
# sed -i "s/^SETTINGS_PUBLISHED_SUM=.*/SETTINGS_PUBLISHED_SUM=\"$(bash rn1-technology-catalog-installer.sh __settings_hash)\"/" rn1-technology-catalog-installer.sh && cp rn1-technology-catalog-installer.sh catalog.sh
SETTINGS_PUBLISHED_SUM="1427209992 2773"

OS_KIND="$(uname -s 2>/dev/null || echo Linux)"
# macOS: the script uses GNU date, sed, stat, readlink ... (brew install coreutils gnu-sed grep findutils);
# a gnubin folder already on the PATH keeps its place
mac_gnu_path() {
  local p t
  for p in /usr/local /opt/homebrew $(brew --prefix 2>/dev/null); do
    for t in findutils grep gnu-sed coreutils; do
      if [ -d "$p/opt/$t/libexec/gnubin" ] && [[ ":$PATH:" != *":$p/opt/$t/libexec/gnubin:"* ]]; then
        PATH="$p/opt/$t/libexec/gnubin:$PATH"
      fi
    done
  done
  export PATH
}
if [ "$OS_KIND" = "Darwin" ]; then
  mac_gnu_path
fi

SCRIPT_NAME="$(basename -- "$0")"
# the folder the installer was called from (main changes to the folder of the installer)
CALL_DIR="$PWD"
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
TZ_STOPPED="false"
COMPOSE=()
COMPOSE_PROBLEM=""
# The container engine, set once at startup by resolve_engine: ENGINE is the command (podman or docker),
# ENGINE_KIND what runs the containers (podman, docker or colima), ENGINE_NAME its name in the texts
ENGINE="podman"
ENGINE_KIND="podman"
ENGINE_NAME="Podman"
ENGINE_GUARD_NOTED=""
# DOCKER_HOST and DOCKER_CONTEXT as the environment gave them: Podman drops them, Docker needs them back
ENV_DOCKER_HOST="${DOCKER_HOST-}"
ENV_DOCKER_HOST_SET="${DOCKER_HOST+1}"
ENV_DOCKER_CONTEXT="${DOCKER_CONTEXT-}"
ENV_DOCKER_CONTEXT_SET="${DOCKER_CONTEXT+1}"
PODMAN_MIN="4.9.0"
if [ -n "${RN1_COMPOSE_PROVIDER:-}" ]; then
  COMPOSE_PROVIDER="$RN1_COMPOSE_PROVIDER"
elif [ "$OS_KIND" = "Darwin" ]; then
  COMPOSE_PROVIDER="$HOME/.docker/cli-plugins/docker-compose"
else
  COMPOSE_PROVIDER="/usr/local/lib/docker/cli-plugins/docker-compose"
fi
SUDO=()
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

# confirm "Question" [y|n]  -> returns 0 for yes. CONFIRM_LAST: what was typed (the guided tasks stop at 0).
CONFIRM_LAST=""
confirm() {
  local prompt="$1" default="${2:-n}" hint answer
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  CONFIRM_LAST=""
  if ! read -r -p "$prompt $hint " answer; then
    return 1
  fi
  CONFIRM_LAST="$answer"
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

# Value of KEY in the generated env file (empty if missing). A .env saved with Windows line endings (CRLF) reads
# like one without: Docker Compose does not take the carriage return into the value either.
env_value() {
  local key="$1"
  if [ -f "$ENV_FILE" ]; then
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r'
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
  if ! cp -p -- "$SCRIPT_PATH" "$target"; then
    rm -f -- "$target"
    return 1
  fi
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
  if [ "$OS_KIND" = "Darwin" ]; then
    addr="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)" || addr=""
    printf '%s' "${addr:-localhost}"
    return 0
  fi
  addr="$(hostname -I 2>/dev/null | awk '{print $1}')" || addr=""
  if [ -z "$addr" ]; then
    addr="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')" || addr=""
  fi
  printf '%s' "${addr:-<server-ip>}"
}

# True when NAME is another service of the stack: as the host name of catalog-web, that name would point
# to catalog-web itself inside it
hostname_taken() {
  case " nginx-proxy-manager opensearch opensearch-dashboards mongo minio rabbitmq worker-recognition-1 worker-recognition-2 worker-other worker-search " in
    *" ${1,,} "*) return 0 ;;
  esac
  return 1
}

# True when NAME can be the host name of catalog-web: letters, digits and -, 1 to 63 characters, no dots,
# not localhost (every machine's name for itself)
hostname_valid() {
  local re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  [[ "$1" =~ $re ]] && ! hostname_taken "$1" && [ "${1,,}" != "localhost" ]
}

# The short name of this server in lower case, without the domain (macOS: its local host name), as a
# host name for catalog-web; the name of a service of the stack gets "catalog-" in front, a server
# without a name of its own (localhost) gives catalog-web
server_hostname() {
  local h=""
  if [ "$OS_KIND" = "Darwin" ]; then
    h="$(scutil --get LocalHostName 2>/dev/null)" || h=""
    if [ -z "$h" ]; then
      h="$(hostname -s 2>/dev/null)" || h=""
    fi
  fi
  if [ -z "$h" ]; then
    h="$(uname -n 2>/dev/null)" || h=""
  fi
  h="${h%%.*}"
  h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | cut -c1-63 | sed 's/^-*//; s/-*$//')"
  if [ -z "$h" ] || [ "$h" = "localhost" ]; then
    h="catalog-web"
  elif hostname_taken "$h"; then
    h="catalog-$h"
  fi
  printf '%s' "$h"
}

# The host name of catalog-web in the env file FILE (default: the generated one), without quotes
env_hostname() {
  env_unquote "$(env_file_value CATALOG_HOSTNAME "${1:-$ENV_FILE}")"
}

# The host name catalog-web gets: CATALOG_HOSTNAME, else the one the env file FILE has (the license stays
# bound to it when the server is renamed), else the short name of this server
catalog_hostname() {
  local h="$CATALOG_HOSTNAME"
  if [ -z "$h" ] && [ -n "${1:-}" ] && [ -f "$1" ]; then
    h="$(env_hostname "$1")"
    if ! hostname_valid "$h"; then
      h=""
    fi
  fi
  if [ -z "$h" ]; then
    h="$(server_hostname)"
  fi
  printf '%s' "$h"
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
# Container engine (Podman, Docker or Colima) / Compose
###############################################################################

# pkg_hint PACKAGE... -> the command that installs them on this machine ("sudo dnf install jq")
pkg_hint() {
  local pm
  if [ "$OS_KIND" = "Darwin" ]; then
    echo "brew install $*"
    return 0
  fi
  for pm in apt-get dnf yum zypper apk; do
    if command -v "$pm" >/dev/null 2>&1; then
      case "$pm" in
        apk) echo "sudo apk add $*" ;;
        *) echo "sudo $pm install $*" ;;
      esac
      return 0
    fi
  done
  echo "install $*"
}

# os_release FIELD -> a field of /etc/os-release (ID, ID_LIKE ...), without quotes
os_release() {
  local v=""
  if [ -r /etc/os-release ]; then
    v="$(sed -n "s/^$1=//p" /etc/os-release)"
  fi
  v="${v%%$'\n'*}"
  v="${v//\"/}"
  printf '%s' "${v//\'/}"
}

# The package with ssh, scp and ssh-keygen
ssh_package() {
  if command -v apt-get >/dev/null 2>&1 || command -v apk >/dev/null 2>&1; then
    echo "openssh-client"
  else
    echo "openssh-clients"
  fi
}

# The version of the engine's command (podman version 5.7.0 -> 5.7.0, Docker version 29.9.0, build x -> 29.9.0)
engine_version() {
  local v
  v="$("$ENGINE" --version 2>/dev/null)" || v=""
  v="${v%%,*}"
  v="${v##* }"
  printf '%s' "${v%%[!0-9.]*}"
}

# True when the docker command is Podman's emulation (podman-docker), which is not Docker
docker_is_podman() {
  local v
  v="$(docker --version 2>/dev/null)" || v=""
  case "$v" in
    *[Pp]odman*) return 0 ;;
  esac
  return 1
}

# True when docker is the snap of Docker (offered by the Ubuntu Server installer): not docker.service,
# and its confinement keeps it out of folders outside /home
docker_is_snap() {
  local p
  if [ "$OS_KIND" = "Darwin" ]; then
    return 1
  fi
  p="$(command -v docker 2>/dev/null)" || return 1
  case "$p" in
    /snap/*) return 0 ;;
  esac
  p="$(readlink -f -- "$p" 2>/dev/null)" || return 1
  [ "${p##*/}" = "snap" ]
}

docker_snap_problem() {
  printf '%s' "Docker is installed as a snap, which the Catalog cannot use (no docker.service, no access to folders outside /home). Remove it - 'snap remove docker' deletes its containers, volumes and images - then './$SCRIPT_NAME install-docker' installs Docker from Docker's repository."
}

# compose_v2 TEXT -> true when TEXT (docker compose version) is Docker Compose 2 or newer: v2.40.3, or
# without the v in the builds of the distributions (2.40.3+ds1-0ubuntu1~24.04.1)
compose_v2() {
  local v="${1%%$'\n'*}"
  case "$v" in
    "Docker Compose version "*) ;;
    *) return 1 ;;
  esac
  v="${v#Docker Compose version }"
  v="${v#v}"
  v="${v%%.*}"
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 2 ]
}

# True when the command of the engine is there (a docker that is Podman's emulation does not count)
engine_cli() {
  command -v "$ENGINE" >/dev/null 2>&1 && { [ "$ENGINE" = "podman" ] || ! docker_is_podman; }
}

# "false" when the engine runs rootful (what the Catalog needs), "true" when rootless, empty when it
# does not answer
engine_rootless() {
  local s
  if [ "$ENGINE" = "docker" ]; then
    s="$(docker info --format '{{range .SecurityOptions}}{{.}} {{end}}' 2>/dev/null)" || return 0
    case "$s" in
      *name=rootless*) printf 'true' ;;
      *) printf 'false' ;;
    esac
    return 0
  fi
  podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true
}

# True when the engine's API answers: Podman's systemd socket (podman.socket) or its machine on macOS,
# the Docker daemon (Docker Desktop, the Colima VM)
engine_socket_ok() {
  local state m
  if [ "$ENGINE" = "docker" ]; then
    docker info >/dev/null 2>&1
  elif [ "$OS_KIND" = "Darwin" ]; then
    m="$(mac_machine)"
    state=""
    if [ -n "$m" ]; then
      state="$(podman machine inspect --format '{{.State}}' "$m" 2>/dev/null)" || state=""
    fi
    [ "${state%%$'\n'*}" = "running" ]
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet podman.socket
  else
    [ -S /run/podman/podman.sock ]
  fi
}

# The Podman machine the stack uses (macOS): the running one, else podman-machine-default, else the first
mac_machine() {
  local name running first="" def=""
  while IFS='|' read -r name running; do
    name="${name%\*}"
    if [ -z "$name" ]; then
      continue
    fi
    if [ "$running" = "true" ]; then
      printf '%s' "$name"
      return 0
    fi
    if [ -z "$first" ]; then
      first="$name"
    fi
    if [ "$name" = "podman-machine-default" ]; then
      def="$name"
    fi
  done < <(podman machine list --format '{{.Name}}|{{.Running}}' 2>/dev/null)
  printf '%s' "${def:-$first}"
}

# The kernel the containers run on: this machine's, or on macOS the one of the Linux VM (the Podman
# machine, Docker Desktop, Colima)
engine_kernel() {
  if [ "$OS_KIND" != "Darwin" ]; then
    uname -r 2>/dev/null || true
  elif [ "$ENGINE" = "docker" ]; then
    docker info --format '{{.KernelVersion}}' 2>/dev/null || true
  else
    podman info --format '{{.Host.Kernel}}' 2>/dev/null || true
  fi
}

# amd64 or arm64 (an Apple Silicon Mac counts as arm64 even when the shell runs under Rosetta)
engine_arch() {
  local m
  if [ "$OS_KIND" = "Darwin" ]; then
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then
      printf 'arm64'
    else
      printf 'amd64'
    fi
    return 0
  fi
  m="$(uname -m 2>/dev/null)" || m=""
  case "$m" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) printf '%s' "$m" ;;
  esac
}

# short_ref docker.io/library/mongo:8 -> mongo:8 (the inverse of qualify_ref)
short_ref() {
  local r="${1#docker.io/library/}"
  printf '%s' "${r#docker.io/}"
}

# use_sudo -> SUDO=() as root and on macOS (Homebrew, the Linux VM and ~/.docker belong to the user),
# SUDO=(sudo) otherwise; 1 when there is no sudo
use_sudo() {
  if [ "$OS_KIND" = "Darwin" ] || [ "$(id -u)" -eq 0 ]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    return 1
  fi
}

# engine_use podman|docker|colima -> ENGINE, ENGINE_KIND and ENGINE_NAME for that kind. "podman compose"
# runs Docker Compose against Podman's API socket: a DOCKER_HOST from the environment would make it talk
# to something else. Docker gets both back as the environment gave them (rootless Docker, the contexts of
# Colima and Docker Desktop); on macOS without them, the docker command is pinned to the VM of the kind.
engine_use() {
  case "$1" in
    docker|colima)
      ENGINE="docker"
      ENGINE_KIND="docker"
      ENGINE_NAME="Docker"
      if [ "$1" = "colima" ] && [ "$OS_KIND" = "Darwin" ]; then
        ENGINE_KIND="colima"
        ENGINE_NAME="Colima"
      fi
      if [ -n "$ENV_DOCKER_HOST_SET" ]; then
        export DOCKER_HOST="$ENV_DOCKER_HOST"
      else
        unset DOCKER_HOST
      fi
      if [ -n "$ENV_DOCKER_CONTEXT_SET" ]; then
        export DOCKER_CONTEXT="$ENV_DOCKER_CONTEXT"
      else
        unset DOCKER_CONTEXT
      fi
      if [ "$OS_KIND" = "Darwin" ]; then
        mac_docker_path
        mac_docker_pin
      fi
      ;;
    *)
      ENGINE="podman"
      ENGINE_KIND="podman"
      ENGINE_NAME="Podman"
      unset DOCKER_HOST DOCKER_CONTEXT
      export PODMAN_COMPOSE_WARNING_LOGS=false
      ;;
  esac
  COMPOSE=()
  COMPOSE_PROBLEM=""
}

# docker_orig ARG... -> docker with DOCKER_HOST and DOCKER_CONTEXT as the environment gave them
docker_orig() {
  (
    if [ -n "$ENV_DOCKER_HOST_SET" ]; then
      export DOCKER_HOST="$ENV_DOCKER_HOST"
    else
      unset DOCKER_HOST
    fi
    if [ -n "$ENV_DOCKER_CONTEXT_SET" ]; then
      export DOCKER_CONTEXT="$ENV_DOCKER_CONTEXT"
    else
      unset DOCKER_CONTEXT
    fi
    docker "$@"
  )
}

# The engines that can hold containers and volumes here: on macOS Docker Desktop and Colima are two
# Linux VMs, each with its own
engine_kinds() {
  if [ "$OS_KIND" = "Darwin" ]; then
    printf 'podman docker colima'
  else
    printf 'podman docker'
  fi
}

# kind_name podman|docker|colima -> its name in the texts
kind_name() {
  case "$1" in
    podman) printf 'Podman' ;;
    colima) printf 'Colima' ;;
    *)
      if [ "$OS_KIND" = "Darwin" ]; then
        printf 'Docker Desktop'
      else
        printf 'Docker'
      fi
      ;;
  esac
}

# kinds_text "KIND..." -> their names: Docker Desktop and Colima
kinds_text() {
  local k out=""
  for k in $1; do
    out="${out:+$out and }$(kind_name "$k")"
  done
  printf '%s' "$out"
}

# engine_has_data podman|docker|colima [containers] -> true when that engine holds containers or volumes
# of this project (containers: only containers count). A docker that is Podman's emulation holds nothing
# of its own. On macOS Docker Desktop and Colima are asked through their own Docker context.
engine_has_data() {
  local filter ctx
  local -a cmd=(podman)
  filter="label=com.docker.compose.project=$(stack_project)"
  if [ "$1" != "podman" ]; then
    cmd=(docker_orig)
    if [ "$OS_KIND" = "Darwin" ]; then
      mac_docker_path
    fi
    if ! command -v docker >/dev/null 2>&1 || docker_is_podman; then
      return 1
    fi
    if [ "$OS_KIND" = "Darwin" ]; then
      ctx="$(mac_docker_context "$1")"
      if [ -z "$ctx" ]; then
        return 1
      fi
      cmd+=(--context "$ctx")
    fi
  elif ! command -v podman >/dev/null 2>&1; then
    return 1
  fi
  [ -n "$("${cmd[@]}" ps -aq --filter "$filter" 2>/dev/null)" ] \
    || { [ "${2:-}" != "containers" ] && [ -n "$("${cmd[@]}" volume ls -q --filter "$filter" 2>/dev/null)" ]; }
}

# The engine a CONTAINER_ENGINE that is empty stands for: the one that alone holds this project's
# containers or volumes (when more than one does, engine_guard asks for the choice); else Podman when it
# is installed, else a Docker that answers, else Podman. Docker on macOS is Colima when the current Docker
# context is Colima's.
engine_detect() {
  local k kind=""
  if [ "$OS_KIND" = "Darwin" ]; then
    mac_docker_path
  fi
  if ! engine_has_data podman; then
    for k in $(engine_kinds); do
      if [ "$k" != "podman" ] && engine_has_data "$k"; then
        kind="$k"
        break
      fi
    done
  fi
  if [ -z "$kind" ]; then
    kind="podman"
    if ! command -v podman >/dev/null 2>&1 && command -v docker >/dev/null 2>&1 && ! docker_is_podman && docker_orig info >/dev/null 2>&1; then
      kind="docker"
      if [ "$OS_KIND" = "Darwin" ] && [ "$(mac_docker_kind)" = "colima" ]; then
        kind="colima"
      fi
    fi
  fi
  printf '%s' "$kind"
}

# resolve_engine -> ENGINE, ENGINE_KIND and ENGINE_NAME from CONTAINER_ENGINE (engine_detect when it is empty)
resolve_engine() {
  local kind="$CONTAINER_ENGINE"
  if [ -z "$kind" ]; then
    kind="$(engine_detect)"
  fi
  engine_use "$kind"
}

# True when CONTAINER_ENGINE names an engine this machine can have (empty included)
engine_setting_ok() {
  case "$CONTAINER_ENGINE" in
    ""|podman|docker) return 0 ;;
    colima) [ "$OS_KIND" = "Darwin" ] ;;
    *) return 1 ;;
  esac
}

# The other engines (podman, docker, colima) that hold containers or volumes of this project; empty when none
other_engine_data() {
  local k out=""
  for k in $(engine_kinds); do
    if [ "$k" != "$ENGINE_KIND" ] && engine_has_data "$k"; then
      out="$out $k"
    fi
  done
  printf '%s' "${out# }"
}

# engine_guard -> fails, with the reason, when another engine holds this project's containers or volumes
# and this one does not: one engine per server - starting here would leave that data behind. When this
# one holds them too, it goes on with a note (once); with CONTAINER_ENGINE empty it asks for the choice.
engine_guard() {
  local other first name
  other="$(other_engine_data)"
  if [ -z "$other" ]; then
    return 0
  fi
  first="${other%% *}"
  name="$(kind_name "$ENGINE_KIND")"
  if engine_has_data "$ENGINE_KIND"; then
    if [ -z "$CONTAINER_ENGINE" ]; then
      err "The containers or data volumes of project \"$(stack_project)\" are in $name and in $(kinds_text "$other"):"
      echo "  choose the one to go on with: CONTAINER_ENGINE=\"$ENGINE_KIND\" or \"$first\" (option 1). The other one can"
      echo "  then be removed: R with CONTAINER_ENGINE set to it."
      return 1
    fi
    if [ -z "$ENGINE_GUARD_NOTED" ]; then
      ENGINE_GUARD_NOTED="yes"
      warn "The containers or data volumes of project \"$(stack_project)\" are also in $(kinds_text "$other"); this folder uses $name."
      echo "  To remove them: R with CONTAINER_ENGINE=\"$first\" (option 1), then CONTAINER_ENGINE=\"$ENGINE_KIND\" again."
    fi
    return 0
  fi
  err "The containers or data volumes of project \"$(stack_project)\" are in $(kinds_text "$other"), but this folder uses $name:"
  echo "  $name would start an empty Catalog and leave that data behind (one engine per server)."
  echo "  Use CONTAINER_ENGINE=\"$first\" (option 1) to go on with it, or remove that installation first"
  echo "  (R with CONTAINER_ENGINE=\"$first\"), then start again."
  return 1
}

# engine_switch_problem KIND -> why CONTAINER_ENGINE cannot become KIND in this folder (empty when it can):
# KIND holds none of this project's containers or volumes, and another engine does
engine_switch_problem() {
  local want="$1" k
  if [ -z "$want" ]; then
    return 0
  fi
  if [ "$want" = "colima" ] && [ "$OS_KIND" != "Darwin" ]; then
    want="docker"
  fi
  if engine_has_data "$want"; then
    return 0
  fi
  for k in $(engine_kinds); do
    if [ "$k" != "$want" ] && engine_has_data "$k"; then
      printf 'The containers or data volumes of project "%s" are in %s - one engine per server: keep "%s", or remove that installation first (R).' \
        "$(stack_project)" "$(kind_name "$k")" "$k"
      return 0
    fi
  done
}

# The command that sets up the engine of this folder
engine_install_cmd() {
  case "$ENGINE_KIND" in
    podman) printf 'install-podman' ;;
    docker) printf 'install-docker' ;;
    *) printf 'install-engine' ;;
  esac
}

# What to do when the engine does not answer
engine_down_hint() {
  case "$ENGINE_KIND" in
    podman)
      if [ "$OS_KIND" = "Darwin" ]; then
        printf 'start the Podman machine: podman machine start %s' "$(mac_machine)"
      else
        printf 'run %s as root, with podman.socket active' "$SCRIPT_NAME"
      fi
      ;;
    colima) printf 'start Colima: colima start' ;;
    *)
      if [ "$OS_KIND" = "Darwin" ]; then
        printf 'start Docker Desktop: open -a Docker'
      else
        printf 'start the daemon (systemctl enable --now docker) and run as root or as a member of the docker group'
      fi
      ;;
  esac
}

# True when the engine is ready for the stack (quiet; for the menu): installed, rootful, compose there
engine_ready() {
  engine_cli && [ "$(engine_rootless)" = "false" ] && detect_compose >/dev/null 2>&1 \
    && { [ "$ENGINE_KIND" != "colima" ] || colima status >/dev/null 2>&1; }
}

# True when the Docker Compose at COMPOSE_PROVIDER is the installer's own (it keeps it at the newest
# release): always with Podman; with Docker when it is a file there, not a link of Docker Desktop
compose_own() {
  [ "$ENGINE" = "podman" ] || { [ -x "$COMPOSE_PROVIDER" ] && [ ! -L "$COMPOSE_PROVIDER" ]; }
}

detect_compose() {
  local v
  if [ "${#COMPOSE[@]}" -gt 0 ]; then
    return 0
  fi
  if [ "$ENGINE" = "docker" ]; then
    if ! command -v docker >/dev/null 2>&1; then
      COMPOSE_PROBLEM="$ENGINE_NAME is not installed - './$SCRIPT_NAME $(engine_install_cmd)' installs it (option 16 shows how)."
      return 1
    fi
    if docker_is_podman; then
      COMPOSE_PROBLEM="'docker' on this machine is Podman (podman-docker), not Docker - './$SCRIPT_NAME $(engine_install_cmd)' installs Docker, or use CONTAINER_ENGINE=\"podman\"."
      return 1
    fi
    if docker_is_snap; then
      COMPOSE_PROBLEM="$(docker_snap_problem)"
      return 1
    fi
    v="$(docker compose version 2>/dev/null)" || v=""
    if ! compose_v2 "$v"; then
      COMPOSE_PROBLEM="Docker Compose ('docker compose') is missing or too old - './$SCRIPT_NAME $(engine_install_cmd)' installs the newest one."
      return 1
    fi
    COMPOSE=(docker compose)
    return 0
  fi
  if ! command -v podman >/dev/null 2>&1; then
    COMPOSE_PROBLEM="Podman is not installed - './$SCRIPT_NAME install-podman' installs it (option 16 shows the commands)."
    return 1
  fi
  v="$(engine_version)"
  if [ -z "$v" ] || version_gt "$PODMAN_MIN" "$v"; then
    COMPOSE_PROBLEM="Podman ${v:-(unknown version)} is too old: $PODMAN_MIN or newer is needed ('podman compose' came with 4.7; Debian 12 has 4.3 - use Debian 13)."
    return 1
  fi
  if [ ! -x "$COMPOSE_PROVIDER" ]; then
    COMPOSE_PROBLEM="Docker Compose, the engine behind 'podman compose', is missing ($COMPOSE_PROVIDER) - './$SCRIPT_NAME install-podman' installs the newest one."
    return 1
  fi
  v="$("$COMPOSE_PROVIDER" version 2>/dev/null)" || v=""
  case "${v%%$'\n'*}" in
    "Docker Compose version v"*) ;;
    *)
      COMPOSE_PROBLEM="$COMPOSE_PROVIDER is not Docker Compose - './$SCRIPT_NAME install-podman' installs it."
      return 1
      ;;
  esac
  export PODMAN_COMPOSE_PROVIDER="$COMPOSE_PROVIDER"
  COMPOSE=(podman compose)
}

require_engine() {
  if ! engine_setting_ok; then
    err "CONTAINER_ENGINE must be \"podman\", \"docker\"$(if [ "$OS_KIND" = "Darwin" ]; then printf ', "colima"'; fi) or empty (is \"$CONTAINER_ENGINE\") - option 1 changes it."
    return 1
  fi
  if [ "$ENGINE" = "docker" ]; then
    require_docker
    return
  fi
  if ! command -v podman >/dev/null 2>&1; then
    err "Podman is not installed - './$SCRIPT_NAME install-podman' installs it (option 16 shows the commands)."
    return 1
  fi
  if [ "$OS_KIND" != "Darwin" ] && [ "$(engine_arch)" != "amd64" ]; then
    err "The Catalog images exist only for amd64 (x86_64); this machine is $(uname -m 2>/dev/null)."
    return 1
  fi
  if [ "$OS_KIND" = "Darwin" ] && ! engine_socket_ok; then
    err "The Podman machine is not running - start it: podman machine start $(mac_machine)"
    return 1
  fi
  if ! podman info >/dev/null 2>&1; then
    err "Podman does not answer (podman info failed)."
    return 1
  fi
  if [ "$(engine_rootless)" != "false" ]; then
    if [ "$OS_KIND" = "Darwin" ]; then
      err "The Podman machine is rootless; the Catalog needs it rootful: podman machine stop && podman machine set --rootful && podman machine start"
    else
      err "Run $SCRIPT_NAME as root (sudo): the Catalog runs with rootful Podman."
    fi
    return 1
  fi
  if [ "$OS_KIND" != "Darwin" ] && ! engine_socket_ok; then
    err "The Podman API socket is not active - start it: systemctl enable --now podman.socket"
    return 1
  fi
  if ! detect_compose; then
    err "$COMPOSE_PROBLEM"
    return 1
  fi
}

# require_engine for Docker (Docker Engine, Docker Desktop, Colima)
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "$ENGINE_NAME is not installed - './$SCRIPT_NAME $(engine_install_cmd)' installs it (option 16 shows how)."
    return 1
  fi
  if docker_is_podman; then
    err "'docker' on this machine is Podman (podman-docker), not Docker - './$SCRIPT_NAME $(engine_install_cmd)' installs Docker, or use CONTAINER_ENGINE=\"podman\"."
    return 1
  fi
  if docker_is_snap; then
    err "$(docker_snap_problem)"
    return 1
  fi
  if [ "$OS_KIND" != "Darwin" ] && [ "$(engine_arch)" != "amd64" ]; then
    err "The Catalog images exist only for amd64 (x86_64); this machine is $(uname -m 2>/dev/null)."
    return 1
  fi
  if [ "$ENGINE_KIND" = "colima" ]; then
    if ! command -v colima >/dev/null 2>&1; then
      err "Colima is not installed - './$SCRIPT_NAME install-engine' installs it (option 16 shows how)."
      return 1
    fi
    if ! colima status >/dev/null 2>&1; then
      err "Colima does not run - $(engine_down_hint)."
      return 1
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    err "$ENGINE_NAME does not answer (docker info failed) - $(engine_down_hint)."
    return 1
  fi
  if [ "$(engine_rootless)" != "false" ]; then
    err "Docker runs rootless here; the Catalog needs the rootful Docker daemon (ports 80 and 443 of Nginx Proxy Manager, the memory lock of OpenSearch)."
    return 1
  fi
  if ! detect_compose; then
    err "$COMPOSE_PROBLEM"
    return 1
  fi
}

###############################################################################
# Install the engine (Podman, Docker, Colima) and the newest Docker Compose
###############################################################################

# podman_install_plan -> the commands (as root, one per line) that install Podman on this Linux.
# 2 (the reason on stderr) when Podman cannot run the Catalog here.
podman_install_plan() {
  local id like ver pkgs="podman netavark aardvark-dns"
  id="$(os_release ID)"
  like=" $(os_release ID_LIKE) "
  ver="$(os_release VERSION_ID)"
  if [ "$(engine_arch)" != "amd64" ]; then
    echo "The Catalog images exist only for amd64 (x86_64); this machine is $(uname -m 2>/dev/null)." >&2
    return 2
  fi
  if ! command -v curl >/dev/null 2>&1; then
    pkgs="$pkgs curl"
  fi
  case "$id $like" in
    ubuntu*|*" ubuntu "*)
      if [ "$id" = "ubuntu" ] && [ -n "$ver" ] && version_gt "24.04" "$ver"; then
        echo "Ubuntu $ver has no Podman 4.9 or newer - use Ubuntu 24.04 or newer." >&2
        return 2
      fi
      echo "apt-get update"
      echo "DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs"
      ;;
    debian*|*" debian "*)
      if [ "$id" = "debian" ] && [[ "$ver" =~ ^[0-9]+$ ]] && [ "$ver" -lt 13 ]; then
        echo "Debian $ver has Podman 4.3, without 'podman compose' - use Debian 13 or newer." >&2
        return 2
      fi
      echo "apt-get update"
      echo "DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs"
      ;;
    *)
      if command -v dnf >/dev/null 2>&1; then
        echo "dnf install -y $pkgs"
      elif command -v yum >/dev/null 2>&1; then
        echo "The Podman of this Linux (RHEL/CentOS 7) is too old - use version 8 or newer." >&2
        return 2
      elif command -v zypper >/dev/null 2>&1; then
        echo "zypper -n install ${pkgs/ netavark aardvark-dns/}"
      else
        echo "This Linux is not covered - install Podman $PODMAN_MIN or newer with its package manager." >&2
        return 2
      fi
      ;;
  esac
}

# The systemd units the stack needs: the API socket for "podman compose", and the restart of the
# containers after a reboot
podman_service_plan() {
  echo "systemctl enable --now podman.socket"
  echo "systemctl enable podman-restart.service"
  # Podman before 5.3 ignores PODMAN_COMPOSE_WARNING_LOGS: its notice on every podman compose goes off here
  echo "mkdir -p /etc/containers/containers.conf.d && printf '[engine]\\ncompose_warning_logs = false\\n' > /etc/containers/containers.conf.d/50-rn1-compose.conf"
}

# installed_packages PACKAGE... -> those of the packages that are installed (dpkg or rpm)
installed_packages() {
  local p st out=""
  for p in "$@"; do
    if command -v dpkg-query >/dev/null 2>&1; then
      st="$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" || st=""
      if [ "$st" = "install ok installed" ]; then
        out="$out $p"
      fi
    elif command -v rpm >/dev/null 2>&1 && rpm -q "$p" >/dev/null 2>&1; then
      out="$out $p"
    fi
  done
  printf '%s' "${out# }"
}

# docker_install_plan -> the commands (as root, one per line) that install the newest Docker Engine with
# its Compose plugin from Docker's repository (download.docker.com), as docs.docker.com describes it for
# this Linux; openSUSE and SLES get the Docker of their own packages. Packages that conflict are removed
# first. 2 (the reason on stderr) when Docker cannot run the Catalog here.
docker_install_plan() {
  local id like ver major repo="" codename="" arch old
  local pkgs="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  local uncovered="This Linux is not covered - install Docker Engine with its Compose plugin as https://docs.docker.com/engine/install/ describes it."
  id="$(os_release ID)"
  like=" $(os_release ID_LIKE) "
  ver="$(os_release VERSION_ID)"
  major="${ver%%.*}"
  if [ "$(engine_arch)" != "amd64" ]; then
    echo "The Catalog images exist only for amd64 (x86_64); this machine is $(uname -m 2>/dev/null)." >&2
    return 2
  fi
  case "$id $like" in
    ubuntu*|*" ubuntu "*)
      repo="ubuntu"
      codename="$(os_release UBUNTU_CODENAME)"
      codename="${codename:-$(os_release VERSION_CODENAME)}"
      if [ "$id" = "ubuntu" ] && [ -n "$ver" ] && version_gt "22.04" "$ver"; then
        echo "Ubuntu $ver has no packages in Docker's repository any more - use Ubuntu 22.04 or newer." >&2
        return 2
      fi
      ;;
    debian*|*" debian "*)
      repo="debian"
      codename="$(os_release VERSION_CODENAME)"
      ;;
  esac
  if [ -n "$repo" ]; then
    if [ -z "$codename" ] || ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
      echo "$uncovered" >&2
      return 2
    fi
    # a derivative (Linux Mint, Kali ...) needs a release that Docker's repository has
    if [ "$id" != "$repo" ] && ! http_get "https://download.docker.com/linux/$repo/dists/$codename/Release" >/dev/null 2>&1; then
      echo "Docker's repository has no packages for $(os_release PRETTY_NAME) ($repo $codename)." >&2
      return 2
    fi
    arch="$(dpkg --print-architecture)"
    old="$(installed_packages docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)"
    echo "apt-get update"
    echo "DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl"
    if [ -n "$old" ]; then
      echo "DEBIAN_FRONTEND=noninteractive apt-get remove -y $old"
    fi
    echo "install -m 0755 -d /etc/apt/keyrings"
    echo "curl -fsSL https://download.docker.com/linux/$repo/gpg -o /etc/apt/keyrings/docker.asc"
    echo "chmod a+r /etc/apt/keyrings/docker.asc"
    echo "printf '%s\\n' 'Types: deb' 'URIs: https://download.docker.com/linux/$repo' 'Suites: $codename' 'Components: stable' 'Architectures: $arch' 'Signed-By: /etc/apt/keyrings/docker.asc' > /etc/apt/sources.list.d/docker.sources"
    echo "apt-get update"
    echo "DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs"
    return 0
  fi
  case "$id" in
    amzn) ;;
    fedora) repo="fedora" ;;
    rhel) repo="rhel" ;;
    centos|rocky|almalinux|ol) repo="centos" ;;
    *)
      case "$like" in
        *" rhel "*|*" centos "*) repo="centos" ;;
        *" fedora "*) repo="fedora" ;;
      esac
      ;;
  esac
  if [ -n "$repo" ] && [ "$repo" != "fedora" ]; then
    if ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt 8 ]; then
      echo "$(os_release PRETTY_NAME) is too old for Docker's packages - use version 8 or newer." >&2
      return 2
    fi
    # Docker's centos/8 repository stopped at an old Docker: version 8 of every RHEL rebuild takes rhel/8
    if [ "$major" -eq 8 ]; then
      repo="rhel"
    fi
  fi
  if [ -n "$repo" ]; then
    if ! command -v dnf >/dev/null 2>&1; then
      echo "$uncovered" >&2
      return 2
    fi
    old="docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman-docker"
    # as Docker's pages list them: only the one for RHEL takes out Podman and runc, Fedora's the SELinux
    # packages of the old Docker
    case "$repo" in
      rhel) old="$old podman runc" ;;
      fedora) old="$old docker-selinux docker-engine-selinux" ;;
    esac
    # shellcheck disable=SC2086
    old="$(installed_packages $old)"
    if [ -n "$old" ]; then
      echo "dnf remove -y $old"
    fi
    if ! command -v curl >/dev/null 2>&1; then
      echo "dnf install -y curl"
    fi
    echo "curl -fsSL https://download.docker.com/linux/$repo/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo"
    echo "dnf install -y $pkgs"
    return 0
  fi
  if [[ " $id $like " == *suse* || "$id" == sles* ]] && command -v zypper >/dev/null 2>&1; then
    echo "zypper -n install docker"
    return 0
  fi
  echo "$uncovered" >&2
  return 2
}

# The systemd unit of Docker: the daemon now and after every reboot (it restarts the containers itself)
docker_service_plan() {
  echo "systemctl enable --now docker"
}

# run_plan "STEP" ... -> runs each step as root (sudo when needed), stops at the first failure. With a proxy
# in this run each step reads it first (proxy_run_begin); the step shown stays as it is.
run_plan() {
  local step n=0 rc=0 traps="" stopped=""
  if [[ "$*" == *zypper* ]]; then
    net_zypper_note
  fi
  proxy_run_begin || return 1
  if proxy_run_active; then
    traps="$(trap -p INT TERM HUP)"
    trap 'stopped="yes"' INT TERM HUP
  fi
  for step in "$@"; do
    n=$((n + 1))
    info "Step $n of $#: $step"
    if ! ${SUDO[@]+"${SUDO[@]}"} sh -c "$(proxy_run_step "$step")"; then
      rc=1
      if [ -n "$stopped" ]; then
        rc=130
      else
        err "Step $n failed (see above)."
      fi
      break
    fi
    if [ -n "$stopped" ]; then
      rc=130
      break
    fi
  done
  if proxy_run_active; then
    proxy_run_end
    trap - INT TERM HUP
    eval "$traps"
  fi
  return "$rc"
}

# The tag of the newest Docker Compose release (v5.6.0), from the redirect of GitHub's latest-release page
compose_latest_tag() {
  local head
  head="$(curl -fsSI --max-time 20 https://github.com/docker/compose/releases/latest 2>/dev/null)" || head=""
  head="$(printf '%s\n' "$head" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/releases/tag/##p')"
  printf '%s' "${head%%$'\n'*}"
}

# compose_try FILE -> true when the Docker Compose FILE works with the engine here
compose_try() {
  if [ "$ENGINE" = "docker" ]; then
    "$1" ls -q >/dev/null 2>&1
  else
    PODMAN_COMPOSE_PROVIDER="$1" podman compose ls -q >/dev/null 2>&1
  fi
}

# install_compose_provider ask|yes -> keeps Docker Compose (the engine behind "podman compose", or the
# Compose plugin of Docker) at the newest release: downloads it from GitHub, checks the checksum and that
# it works with the engine here. A newest release that does not work here is not installed: the previous
# one stays.
install_compose_provider() {
  local mode="$1" tag have os arch url tmp exp got v rc
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is needed to download Docker Compose ($(pkg_hint curl))."
    return 1
  fi
  tag="$(compose_latest_tag)"
  have=""
  if [ -x "$COMPOSE_PROVIDER" ]; then
    have="$("$COMPOSE_PROVIDER" version --short 2>/dev/null)" || have=""
    have="${have#v}"
  fi
  if [ -z "$tag" ]; then
    if [ -n "$have" ]; then
      warn "GitHub cannot be reached - Docker Compose $have stays."
      return 0
    fi
    err "GitHub cannot be reached, and Docker Compose (the engine behind '$ENGINE compose') is missing."
    echo "  On a server without internet, use an offline bundle: it carries Docker Compose."
    return 1
  fi
  if [ "$have" = "${tag#v}" ]; then
    ok "Docker Compose ${tag#v} (the newest) runs '$ENGINE compose'."
    return 0
  fi
  info "Docker Compose ${tag#v} is the newest release${have:+ (installed: $have)}; '$ENGINE compose' runs it."
  if [ "$mode" = "ask" ] && ! confirm "Install Docker Compose ${tag#v} from github.com/docker/compose?" y; then
    info "Docker Compose was not changed."
    [ -n "$have" ]
    return
  fi
  case "$OS_KIND" in
    Darwin) os="darwin" ;;
    *) os="linux" ;;
  esac
  case "$(engine_arch)" in
    arm64) arch="aarch64" ;;
    *) arch="x86_64" ;;
  esac
  url="https://github.com/docker/compose/releases/download/$tag/docker-compose-$os-$arch"
  # the download lands next to its target: a /tmp mounted noexec could not run the checks below
  if ! ${SUDO[@]+"${SUDO[@]}"} mkdir -p "${COMPOSE_PROVIDER%/*}" \
    || ! tmp="$(${SUDO[@]+"${SUDO[@]}"} mktemp "${COMPOSE_PROVIDER%/*}/.docker-compose.XXXXXX")"; then
    err "Cannot write to ${COMPOSE_PROVIDER%/*}."
    return 1
  fi
  if ! proxy_sudo curl -fsSL --proto '=https' --max-time 600 -o "$tmp" "$url"; then
    ${SUDO[@]+"${SUDO[@]}"} rm -f -- "$tmp"
    err "The download failed: $url"
    net_offer_check "The download of Docker Compose"
    return 1
  fi
  exp="$(curl -fsSL --proto '=https' --max-time 30 "$url.sha256" 2>/dev/null)" || exp=""
  exp="${exp%% *}"
  got="$(sha256sum "$tmp" 2>/dev/null)" || got="$(shasum -a 256 "$tmp" 2>/dev/null)" || got=""
  got="${got%% *}"
  if [ -z "$exp" ] || [ "$exp" != "$got" ]; then
    ${SUDO[@]+"${SUDO[@]}"} rm -f -- "$tmp"
    err "The checksum of $url does not match - nothing was installed."
    return 1
  fi
  ${SUDO[@]+"${SUDO[@]}"} chmod 755 "$tmp"
  rc=0
  v="$("$tmp" version 2>/dev/null)" || rc=$?
  case "${v%%$'\n'*}" in
    "Docker Compose version v"*) ;;
    *)
      ${SUDO[@]+"${SUDO[@]}"} rm -f -- "$tmp"
      if [ "$rc" -eq 126 ]; then
        err "Programs cannot run from ${COMPOSE_PROVIDER%/*} (mounted noexec?) - nothing was installed."
      else
        err "The download is not Docker Compose - nothing was installed."
      fi
      return 1
      ;;
  esac
  # try it against the engine first: a release that needs a newer API is not installed
  if engine_socket_ok && [ "$(engine_rootless)" = "false" ] && ! compose_try "$tmp"; then
    ${SUDO[@]+"${SUDO[@]}"} rm -f -- "$tmp"
    if [ -n "$have" ]; then
      warn "Docker Compose ${tag#v} does not work with $ENGINE_NAME $(engine_version) here - Docker Compose $have stays."
      return 0
    fi
    err "Docker Compose ${tag#v} does not work with $ENGINE_NAME $(engine_version) here."
    return 1
  fi
  if [ -n "$have" ]; then
    ${SUDO[@]+"${SUDO[@]}"} cp -p -- "$COMPOSE_PROVIDER" "$COMPOSE_PROVIDER.previous" 2>/dev/null || true
  fi
  if ! ${SUDO[@]+"${SUDO[@]}"} mv -f -- "$tmp" "$COMPOSE_PROVIDER"; then
    ${SUDO[@]+"${SUDO[@]}"} rm -f -- "$tmp"
    err "Cannot write $COMPOSE_PROVIDER."
    return 1
  fi
  COMPOSE=()
  ok "Docker Compose ${tag#v} installed ($COMPOSE_PROVIDER); '$ENGINE compose' runs it."
}

# install_podman_linux ask|yes -> Podman with its socket and restart service on this Linux
install_podman_linux() {
  local mode="$1" plan="" v="" rc=0 proxy="no" was="no"
  local -a steps=()
  if [ "$(engine_arch)" != "amd64" ]; then
    err "The Catalog images exist only for amd64 (x86_64); this machine is $(uname -m 2>/dev/null)."
    return 1
  fi
  if [ ! -d "${RN1_SYSTEMD_DIR:-/run/systemd/system}" ]; then
    err "This Linux does not run systemd, which rootful Podman needs here (API socket, restart after a reboot)."
    return 1
  fi
  if command -v podman >/dev/null 2>&1; then
    v="$(engine_version)"
    if [ -z "$v" ] || version_gt "$PODMAN_MIN" "$v"; then
      err "Podman ${v:-(unknown version)} is too old: $PODMAN_MIN or newer is needed. Update it with the package manager."
      return 1
    fi
  else
    plan="$(podman_install_plan)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      err "Podman cannot be installed here by the installer."
      return 1
    fi
    mapfile -t steps <<< "$plan"
  fi
  if net_engine_plan podman >/dev/null; then
    proxy="yes"
    steps+=("systemctl daemon-reload")
  fi
  mapfile -t -O "${#steps[@]}" steps < <(podman_service_plan)
  echo
  info "Podman $(if [ -n "$plan" ]; then printf 'will be installed from the packages of %s, then its' "$(os_release PRETTY_NAME)"; else printf '%s is installed; its' "$(engine_version)"; fi) API socket and restart service will be enabled:"
  printf '      %s\n' "${steps[@]}"
  if [ "$proxy" = "yes" ]; then
    net_engine_plan podman || true
  fi
  if [ "$mode" = "ask" ] && ! confirm "Run these commands${SUDO[*]:+ with sudo}?" y; then
    info "Podman was not set up."
    return 1
  fi
  if [ "$proxy" = "yes" ]; then
    if systemctl is-active --quiet podman.service 2>/dev/null; then
      was="yes"
    fi
    net_engine_write "$mode" podman || return 1
  fi
  run_plan "${steps[@]}" || return 1
  # a Podman service that was not running starts with the proxy files already
  if [ "$was" = "no" ]; then
    NET_ENGINE_CHANGED="${NET_ENGINE_CHANGED// podman/}"
  fi
  net_engine_restart "$mode" podman || true
  COMPOSE=()
  ok "Podman $(engine_version) is ready (rootful, API socket on, containers restart after a reboot)."
}

# install_docker_linux ask|yes -> Docker Engine with its service on this Linux (from Docker's repository;
# openSUSE and SLES: their packages). A Docker that is there already only gets its service enabled.
install_docker_linux() {
  local mode="$1" plan="" rc=0 from proxy="no" was="no"
  local -a steps=()
  if [ "$(engine_arch)" != "amd64" ]; then
    err "The Catalog images exist only for amd64 (x86_64); this machine is $(uname -m 2>/dev/null)."
    return 1
  fi
  if [ ! -d "${RN1_SYSTEMD_DIR:-/run/systemd/system}" ]; then
    err "This Linux does not run systemd, which Docker needs here (its daemon, the restart after a reboot)."
    return 1
  fi
  if docker_is_snap; then
    err "$(docker_snap_problem)"
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1 || docker_is_podman; then
    plan="$(docker_install_plan)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      err "Docker cannot be installed here by the installer."
      return 1
    fi
    mapfile -t steps <<< "$plan"
  fi
  if net_engine_plan docker >/dev/null; then
    proxy="yes"
    steps+=("systemctl daemon-reload")
  fi
  mapfile -t -O "${#steps[@]}" steps < <(docker_service_plan)
  from="the packages of $(os_release PRETTY_NAME)"
  if [[ "$plan" == *download.docker.com* ]]; then
    from="Docker's repository (download.docker.com) for $(os_release PRETTY_NAME)"
  fi
  echo
  info "Docker $(if [ -n "$plan" ]; then printf 'will be installed from %s, then its' "$from"; else printf '%s is installed; its' "$(engine_version)"; fi) service will be enabled:"
  printf '      %s\n' "${steps[@]}"
  if [[ "$plan" == *" remove -y "* ]]; then
    echo "  The remove step takes out the packages that conflict with Docker's (named in it)."
  fi
  if [ "$proxy" = "yes" ]; then
    net_engine_plan docker || true
  fi
  if [ "$mode" = "ask" ] && ! confirm "Run these commands${SUDO[*]:+ with sudo}?" y; then
    info "Docker was not set up."
    return 1
  fi
  if [ "$proxy" = "yes" ]; then
    if systemctl is-active --quiet docker 2>/dev/null; then
      was="yes"
    fi
    net_engine_write "$mode" docker || return 1
  fi
  run_plan "${steps[@]}" || return 1
  # a Docker that was not running started with the proxy files already
  if [ "$was" = "no" ]; then
    NET_ENGINE_CHANGED="${NET_ENGINE_CHANGED// docker/}"
  fi
  net_engine_restart "$mode" docker || true
  COMPOSE=()
  ok "Docker $(engine_version) is ready (daemon on, the containers restart after a reboot)."
}

# The LaunchAgent that starts the Podman machine when the user logs in (macOS)
MAC_AGENT="$HOME/Library/LaunchAgents/de.raynet.rn1-podman-machine.plist"
# Docker Desktop's settings (Rosetta ...)
MAC_DD_SETTINGS="$HOME/Library/Group Containers/group.com.docker/settings-store.json"

# The settings of the Colima VM (its type, the provision scripts): colima.yaml of the default profile, in
# the folder Colima takes - COLIMA_HOME, ~/.colima, $XDG_CONFIG_HOME/colima, ~/.config/colima
mac_colima_yaml() {
  local dir="$HOME/.colima"
  if [ -n "${COLIMA_HOME:-}" ] && [ -d "$COLIMA_HOME" ]; then
    dir="$COLIMA_HOME"
  elif [ ! -d "$HOME/.colima" ]; then
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
      dir="$XDG_CONFIG_HOME/colima"
    elif [ -d "$HOME/.config/colima" ]; then
      dir="$HOME/.config/colima"
    fi
  fi
  printf '%s/default/colima.yaml' "$dir"
}

# The type of a Podman machine (applehv, libkrun, ...)
mac_vmtype() {
  local name type
  while IFS='|' read -r name type; do
    if [ "${name%\*}" = "$1" ]; then
      printf '%s' "$type"
      return 0
    fi
  done < <(podman machine list --format '{{.Name}}|{{.VMType}}' 2>/dev/null)
}

# True when Rosetta runs amd64 programs in the Podman machine NAME
mac_rosetta_on() {
  local s
  s="$(podman machine ssh "$1" cat /proc/sys/fs/binfmt_misc/rosetta 2>/dev/null)" || s=""
  [ "${s%%$'\n'*}" = "enabled" ]
}

# mac_agent NAME -> the LaunchAgent that starts the Podman machine NAME at login. launchd stops what a
# job leaves behind unless AbandonProcessGroup is set - the machine would stop right after its start.
mac_agent() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>de.raynet.rn1-podman-machine</string>
  <key>ProgramArguments</key><array><string>$(command -v podman)</string><string>machine</string><string>start</string><string>$1</string></array>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>$(net_plist_env)
</dict>
</plist>
EOF
}

# mac_vm_size -> "CPUS MEMORY-MB" of the Linux VM for the Catalog: up to 6 CPUs; MEM_RECOMMENDED_GB of memory
# when the Mac keeps 8 GB for itself, else all but 8 GB (at least 8 GB). macOS gives the VM memory only as it
# uses it.
mac_vm_size() {
  local ram cpus mem
  ram="$(sysctl -n hw.memsize 2>/dev/null)" || ram=0
  cpus="$(sysctl -n hw.ncpu 2>/dev/null)" || cpus=4
  if [ "$cpus" -gt 6 ]; then
    cpus=6
  fi
  mem=$(((ram / 1073741824 - 8) * 1024))
  if [ "$mem" -ge $((MEM_RECOMMENDED_GB * 1024)) ]; then
    mem=$((MEM_RECOMMENDED_GB * 1024))
  else
    if [ "$mem" -lt 8192 ]; then
      mem=8192
    fi
    if [ "$ram" -lt $((16 * 1024 * 1024 * 1024)) ]; then
      warn "This Mac has less than 16 GB of memory; the Catalog needs about 8 GB in its Linux VM."
    fi
    warn "The Linux VM gets $((mem / 1024)) GB of memory; at least $MEM_RECOMMENDED_GB GB is recommended"
    echo "  (a Mac with $((MEM_RECOMMENDED_GB + 8)) GB or more)." >&2
  fi
  printf '%s %s' "$cpus" "$mem"
}

# mac_brew_tools ask|yes [COMMAND...] -> Homebrew with the GNU tools the script uses and the formulas of
# the COMMANDs (podman, colima, docker): what is missing is installed after asking
mac_brew_tools() {
  local mode="$1" t
  local -a missing=()
  shift
  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew is needed: install it from https://brew.sh, then start $SCRIPT_NAME again."
    return 1
  fi
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  for t in coreutils gnu-sed grep findutils; do
    if [ ! -d "$(brew --prefix 2>/dev/null)/opt/$t" ]; then
      missing+=("$t")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    info "Homebrew will install: ${missing[*]}"
    echo "      brew install ${missing[*]}"
    if [ "$mode" = "ask" ] && ! confirm "Run it now?" y; then
      info "Nothing was installed."
      return 1
    fi
    brew install "${missing[@]}" || return 1
    # the GNU tools count from now on, not only from the next start
    mac_gnu_path
  fi
}

# mac_prepare ask|yes -> Homebrew packages, a rootful Podman machine with enough memory and Rosetta,
# vm.max_map_count and the restart service in it, and the LaunchAgent
mac_prepare() {
  local mode="$1" t mem cpus name rootful state type osver
  if [ "$(engine_arch)" != "arm64" ]; then
    err "Intel Macs are not supported: Podman runs only on Apple Silicon (M1 or newer)."
    echo "  Docker Desktop or Colima runs the Catalog on an Intel Mac: CONTAINER_ENGINE=\"docker\" or \"colima\"."
    return 1
  fi
  if [ "$(id -u)" -eq 0 ]; then
    err "On macOS run $SCRIPT_NAME as your normal user, not as root: the Podman machine belongs to the user."
    return 1
  fi
  # Rosetta runs the amd64 Catalog images; with the Linux kernel of current Podman machines it works
  # only from macOS 26
  osver="$(sw_vers -productVersion 2>/dev/null)" || osver=""
  if [[ "${osver%%.*}" =~ ^[0-9]+$ ]] && [ "${osver%%.*}" -lt 26 ]; then
    err "macOS $osver is too old for the Catalog: macOS 26 (Tahoe) or newer is needed."
    echo "  The Catalog images are amd64; Rosetta runs them in the Podman machine, and with its Linux kernel"
    echo "  Rosetta works only from macOS 26."
    return 1
  fi
  mac_brew_tools "$mode" podman || return 1
  # the Catalog images are amd64: Apple's hypervisor with Rosetta runs them
  t="$HOME/.config/containers/containers.conf.d/50-rn1-machine.conf"
  if [ ! -f "$t" ]; then
    mkdir -p "${t%/*}"
    printf '%s\n' '[machine]' 'provider = "applehv"' 'rosetta = true' > "$t"
  fi
  name="$(mac_machine)"
  if [ -z "$name" ]; then
    read -r cpus mem <<< "$(mac_vm_size)"
    info "A Podman machine (Linux VM) will be created: rootful, $cpus CPUs, $((mem / 1024)) GB memory, 100 GB disk."
    echo "      podman machine init --rootful --cpus $cpus --memory $mem --disk-size 100 --now"
    if [ "$mode" = "ask" ] && ! confirm "Create it now?" y; then
      info "No Podman machine was created."
      return 1
    fi
    podman machine init --rootful --cpus "$cpus" --memory "$mem" --disk-size 100 --now || return 1
    name="$(mac_machine)"
    name="${name:-podman-machine-default}"
  else
    type="$(mac_vmtype "$name")"
    if [ -n "$type" ] && [ "$type" != "applehv" ]; then
      err "The Podman machine $name runs with $type, which cannot use Rosetta for the amd64 Catalog images."
      echo "  The Catalog needs a machine with Apple's hypervisor. Removing $name deletes its containers and data:"
      echo "      podman machine rm $name, then start $SCRIPT_NAME again."
      return 1
    fi
    rootful="$(podman machine inspect --format '{{.Rootful}}' "$name" 2>/dev/null)" || rootful=""
    state="$(podman machine inspect --format '{{.State}}' "$name" 2>/dev/null)" || state=""
    if [ "${rootful%%$'\n'*}" != "true" ]; then
      info "The Podman machine $name runs rootless; the Catalog needs it rootful."
      if [ "$mode" = "ask" ] && ! confirm "Switch it to rootful (it restarts)?" y; then
        return 1
      fi
      podman machine stop "$name" >/dev/null 2>&1 || true
      podman machine set --rootful "$name" || return 1
      state="stopped"
    fi
    if [ "${state%%$'\n'*}" != "running" ]; then
      podman machine start "$name" || return 1
    fi
    mem="$(podman machine inspect --format '{{.Resources.Memory}}' "$name" 2>/dev/null)" || mem=0
    if [[ "${mem%%$'\n'*}" =~ ^[0-9]+$ ]] && [ "${mem%%$'\n'*}" -lt 8192 ]; then
      warn "The Podman machine has ${mem%%$'\n'*} MB of memory; the Catalog needs 8192 MB."
      echo "  $MEM_RECOMMENDED_GB GB is recommended; the machine gets more memory while it is stopped:"
      mem_vm_cmds podman "$name"
    fi
  fi
  if ! mac_rosetta_on "$name"; then
    info "Rosetta is not active in the Podman machine $name; turning it on restarts the machine."
    if [ "$mode" = "ask" ] && ! confirm "Restart the Podman machine now?" y; then
      return 1
    fi
    # Podman 5.6 to 5.8 also wants this file in the machine
    podman machine ssh "$name" sudo touch /etc/containers/enable-rosetta >/dev/null 2>&1 || true
    podman machine stop "$name" >/dev/null 2>&1 || true
    podman machine start "$name" || return 1
    if ! mac_rosetta_on "$name"; then
      err "Rosetta does not run in the Podman machine $name, and the Catalog images (amd64) need it."
      echo "  Update Podman (brew upgrade podman), or create a new machine (its containers and data are lost):"
      echo "      podman machine rm $name, then start $SCRIPT_NAME again."
      return 1
    fi
  fi
  podman machine ssh "$name" sudo systemctl enable podman-restart.service >/dev/null 2>&1 || true
  t="$(podman machine ssh "$name" sysctl -n vm.max_map_count 2>/dev/null)" || t=0
  t="${t//[^0-9]/}"
  if [ "${t:-0}" -lt 262144 ]; then
    podman machine ssh "$name" "sudo sh -c 'echo vm.max_map_count=262144 > /etc/sysctl.d/99-opensearch.conf && sysctl --system'" >/dev/null 2>&1 || true
  fi
  if [ ! -f "$MAC_AGENT" ]; then
    info "The Podman machine does not start by itself after a restart of the Mac. A LaunchAgent can start it"
    echo "  when you log in; the Catalog then comes back by itself ($MAC_AGENT)."
    if [ "$mode" = "yes" ] || confirm "Add the LaunchAgent?" y; then
      mkdir -p "${MAC_AGENT%/*}"
      mac_agent "$name" | net_private_write "$MAC_AGENT"
      launchctl load -w "$MAC_AGENT" >/dev/null 2>&1 || true
      ok "LaunchAgent added: the Podman machine starts when you log in."
    fi
  elif [ "$(mac_agent "$name")" != "$(cat "$MAC_AGENT" 2>/dev/null)" ]; then
    # an older LaunchAgent, or one for another machine or Podman: brought up to date
    launchctl unload "$MAC_AGENT" >/dev/null 2>&1 || true
    mac_agent "$name" | net_private_write "$MAC_AGENT"
    launchctl load -w "$MAC_AGENT" >/dev/null 2>&1 || true
    ok "LaunchAgent updated: it starts the Podman machine $name when you log in."
  fi
  COMPOSE=()
}

# Docker on macOS: colima when the current Docker context (or DOCKER_HOST) is Colima's, else docker
mac_docker_kind() {
  local ctx
  ctx="$(docker_orig context show 2>/dev/null)" || ctx=""
  case "$ctx ${ENV_DOCKER_HOST}" in
    *colima*) printf 'colima' ;;
    *) printf 'docker' ;;
  esac
}

# mac_docker_context docker|colima -> the Docker context of that VM: colima, or desktop-linux (Docker
# Desktop). Without desktop-linux the current context (another Docker that answers), default when that is
# Colima's. Empty for Colima without its context (no Colima VM yet).
mac_docker_context() {
  local cur
  if [ "$1" = "colima" ]; then
    if docker_orig context inspect colima >/dev/null 2>&1; then
      printf 'colima'
    fi
    return 0
  fi
  if docker_orig context inspect desktop-linux >/dev/null 2>&1; then
    printf 'desktop-linux'
    return 0
  fi
  cur="$(docker_orig context show 2>/dev/null)" || cur=""
  case "$cur" in
    ""|colima|colima-*) printf 'default' ;;
    *) printf '%s' "$cur" ;;
  esac
}

# mac_docker_pin -> DOCKER_CONTEXT for the VM of ENGINE_KIND (Docker Desktop and Colima each hold their own
# containers and volumes), unless the environment set DOCKER_HOST or DOCKER_CONTEXT
mac_docker_pin() {
  local ctx
  if [ "$ENGINE" != "docker" ] || [ -n "$ENV_DOCKER_HOST_SET$ENV_DOCKER_CONTEXT_SET" ] || ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  ctx="$(mac_docker_context "$ENGINE_KIND")"
  if [ -n "$ctx" ]; then
    export DOCKER_CONTEXT="$ctx"
  else
    unset DOCKER_CONTEXT
  fi
}

# The docker command of Docker Desktop on the PATH when it is not there yet (~/.docker/bin, the app)
mac_docker_path() {
  local d
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  for d in "$HOME/.docker/bin" /Applications/Docker.app/Contents/Resources/bin "$HOME/Applications/Docker.app/Contents/Resources/bin"; do
    if [ -x "$d/docker" ]; then
      PATH="$PATH:$d"
      export PATH
      return 0
    fi
  done
  return 0
}

# The folder of Docker Desktop (Docker.app); fails when it is not installed
mac_docker_app() {
  local a
  for a in /Applications/Docker.app "$HOME/Applications/Docker.app"; do
    if [ -d "$a" ]; then
      printf '%s' "$a"
      return 0
    fi
  done
  return 1
}

mac_docker_license() {
  echo "  Docker Desktop is free only for companies with fewer than 250 employees AND less than 10 million"
  echo "  USD annual revenue, for personal use, education and non-commercial open source projects; everyone"
  echo "  else needs a paid Docker subscription. Colima (CONTAINER_ENGINE=\"colima\") is free."
}

# mac_wait_docker -> waits until Docker answers (docker info), at most RN1_DOCKER_WAIT seconds (300).
# Docker Desktop creates its context (desktop-linux) at its first start.
mac_wait_docker() {
  local start="$SECONDS" limit="${RN1_DOCKER_WAIT:-300}"
  until mac_docker_path && mac_docker_pin && docker info >/dev/null 2>&1; do
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      return 1
    fi
    sleep 3
  done
}

# True when the settings of Docker Desktop show Rosetta off (the amd64 Catalog images then run in QEMU)
mac_docker_rosetta_off() {
  grep -Eiq '"UseVirtualizationFrameworkRosetta"[[:space:]]*:[[:space:]]*false' "$MAC_DD_SETTINGS" 2>/dev/null
}

# True when Rosetta cannot run the amd64 Catalog images in the Linux VM of Docker Desktop or Colima: it
# fails with Linux 6.13 and newer before macOS 26
mac_kernel_problem() {
  local k osver
  if [ "$(engine_arch)" != "arm64" ]; then
    return 1
  fi
  osver="$(sw_vers -productVersion 2>/dev/null)" || osver=""
  if ! [[ "${osver%%.*}" =~ ^[0-9]+$ ]] || [ "${osver%%.*}" -ge 26 ]; then
    return 1
  fi
  k="$(engine_kernel)"
  [[ "$k" =~ ^[0-9]+\.[0-9]+ ]] && ! version_gt "6.13" "${BASH_REMATCH[0]}"
}

mac_kernel_error() {
  err "macOS $(sw_vers -productVersion 2>/dev/null) with Linux $(engine_kernel) in the $ENGINE_NAME VM: Rosetta, which runs the amd64"
  echo "  Catalog images, fails with Linux 6.13 and newer before macOS 26 - update macOS to 26 (Tahoe)."
}

# mac_docker_desktop ask|yes -> a Docker that answers (Docker Desktop, or any other that does): Docker
# Desktop is installed with Homebrew when it is missing (only after its license note and a question - also
# with yes; without a terminal it is not installed), started, and waited for
mac_docker_desktop() {
  local mode="$1"
  if [ "$(id -u)" -eq 0 ]; then
    err "On macOS run $SCRIPT_NAME as your normal user, not as root: Docker Desktop belongs to the user."
    return 1
  fi
  mac_brew_tools "$mode" || return 1
  mac_docker_pin
  if ! docker info >/dev/null 2>&1; then
    if ! mac_docker_app >/dev/null; then
      info "Docker Desktop is not installed; Homebrew can install it:"
      echo "      brew install --cask docker-desktop"
      mac_docker_license
      if [ "$mode" = "yes" ] && [ ! -t 0 ]; then
        err "Docker Desktop is not installed without a question (its license): install it with the command above,"
        echo "  or start $SCRIPT_NAME in a terminal, then start it again."
        return 1
      fi
      if ! confirm "Install Docker Desktop now (its license above applies)?" n; then
        info "Docker Desktop was not installed."
        return 1
      fi
      brew install --cask docker-desktop || return 1
      mac_docker_path
    fi
    info "Starting Docker Desktop (open -a Docker). At its first start, accept its agreement."
    if [ "$(engine_arch)" = "arm64" ]; then
      echo "  Then turn on Settings > General > \"Use Rosetta for x86_64/amd64 emulation\" (the Catalog images are amd64)."
    fi
    open -a Docker >/dev/null 2>&1 || true
    while ! mac_wait_docker; do
      if [ "$mode" = "yes" ] || ! confirm "Docker Desktop does not answer yet. Wait again?" y; then
        err "Docker Desktop does not answer (docker info) - start it, accept its agreement, then start $SCRIPT_NAME again."
        return 1
      fi
    done
    mac_docker_path
  fi
  ok "Docker answers: $(docker --version 2>/dev/null)"
  if [ "$(engine_arch)" = "arm64" ] && mac_docker_rosetta_off; then
    warn "Rosetta is off in Docker Desktop, and the Catalog images are amd64 (slow and unreliable without it):"
    echo "  turn on Settings > General > \"Use Rosetta for x86_64/amd64 emulation\", then Apply & restart."
  fi
  if mac_kernel_problem; then
    mac_kernel_error
    return 1
  fi
  COMPOSE=()
}

# True when Rosetta runs amd64 programs in the Colima VM
mac_colima_rosetta_on() {
  local s
  s="$(colima ssh -- cat /proc/sys/fs/binfmt_misc/rosetta 2>/dev/null)" || s=""
  [ "${s%%$'\n'*}" = "enabled" ]
}

# Keeps vm.max_map_count in the Colima VM after a restart: a provision script in colima.yaml, which
# Colima runs at every start
mac_colima_provision() {
  local tmp yaml
  yaml="$(mac_colima_yaml)"
  if [ ! -f "$yaml" ] || grep -q 'vm.max_map_count' "$yaml"; then
    return 0
  fi
  tmp="$(mktemp)" || return 0
  awk -v s="sysctl -w vm.max_map_count=262144" '
    !done && /^provision:[[:space:]]*\[\][[:space:]]*$/ { print "provision:"; print "  - mode: system"; print "    script: " s; done = 1; next }
    !done && /^provision:[[:space:]]*$/ {
      print
      ind = "  "
      if ((getline nxt) > 0) {
        if (nxt ~ /^ *- /) { ind = nxt; sub(/-.*/, "", ind) }
        print ind "- mode: system"; print ind "  script: " s; print nxt
      } else {
        print ind "- mode: system"; print ind "  script: " s
      }
      done = 1; next
    }
    { print }
    END { if (!done) { print "provision:"; print "  - mode: system"; print "    script: " s } }' "$yaml" > "$tmp" \
    && cat -- "$tmp" > "$yaml"
  rm -f -- "$tmp"
}

# mac_colima ask|yes -> Colima from Homebrew (a Linux VM with Docker): a VM with Apple's virtualization and
# Rosetta, vm.max_map_count in it, and its start at login (brew services)
mac_colima() {
  local mode="$1" osver t cpus mem yaml
  local -a args=()
  if [ "$(id -u)" -eq 0 ]; then
    err "On macOS run $SCRIPT_NAME as your normal user, not as root: Colima belongs to the user."
    return 1
  fi
  osver="$(sw_vers -productVersion 2>/dev/null)" || osver=""
  if [[ "${osver%%.*}" =~ ^[0-9]+$ ]] && [ "${osver%%.*}" -lt 13 ]; then
    err "macOS $osver is too old for Colima: macOS 13 or newer is needed (Apple's virtualization)."
    return 1
  fi
  mac_brew_tools "$mode" colima docker || return 1
  yaml="$(mac_colima_yaml)"
  if ! colima status >/dev/null 2>&1; then
    if [ -f "$yaml" ]; then
      t="$(sed -n 's/^vmType:[[:space:]]*//p' "$yaml")"
      t="${t%%$'\n'*}"
      if [ "$(engine_arch)" = "arm64" ] && [ -n "$t" ] && [ "$t" != "vz" ]; then
        err "The Colima VM runs with $t, which cannot use Rosetta for the amd64 Catalog images."
        echo "  The Catalog needs a VM with Apple's virtualization. Removing it deletes its containers and data:"
        echo "      colima delete, then start $SCRIPT_NAME again."
        return 1
      fi
      info "Starting the Colima VM: colima start"
      colima start || return 1
    else
      read -r cpus mem <<< "$(mac_vm_size)"
      args=(--vm-type=vz)
      if [ "$(engine_arch)" = "arm64" ]; then
        args+=(--vz-rosetta)
      fi
      args+=(--cpu "$cpus" --memory "$((mem / 1024))" --disk 100)
      info "A Colima VM (Linux with Docker) will be created: $cpus CPUs, $((mem / 1024)) GB memory, 100 GB disk."
      echo "      colima start ${args[*]}"
      if [ "$mode" = "ask" ] && ! confirm "Create it now?" y; then
        info "No Colima VM was created."
        return 1
      fi
      colima start "${args[@]}" || return 1
    fi
  fi
  # the context colima exists from the first start on: the docker command talks to this VM
  mac_docker_pin
  if [ "$(engine_arch)" = "arm64" ] && ! mac_colima_rosetta_on; then
    err "Rosetta does not run in the Colima VM, and the Catalog images (amd64) need it."
    echo "  Update Colima (brew upgrade colima), or create a new VM with Rosetta (its containers and data are lost):"
    echo "      colima delete, then start $SCRIPT_NAME again."
    return 1
  fi
  if mac_kernel_problem; then
    mac_kernel_error
    return 1
  fi
  t="$(colima ssh -- sysctl -n vm.max_map_count 2>/dev/null)" || t=0
  t="${t//[^0-9]/}"
  if [ "${t:-0}" -lt 262144 ]; then
    colima ssh -- sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
  fi
  mac_colima_provision
  net_colima_apply "$mode" y
  if [ "$(brew services list 2>/dev/null | awk '$1 == "colima" { print $2 }')" != "started" ]; then
    info "Colima does not start by itself after a restart of the Mac. Homebrew can start it when you log in"
    echo "  (brew services start colima); the Catalog then comes back by itself."
    if [ "$mode" = "yes" ] || confirm "Start Colima at login?" y; then
      if brew services start colima >/dev/null 2>&1; then
        ok "Colima starts when you log in."
      else
        warn "brew services start colima failed - after a restart of the Mac, start it yourself: colima start"
      fi
    fi
  fi
  COMPOSE=()
}

# engine_offer -> in a terminal: when the engine is not ready, says why and offers to set it up
engine_offer() {
  if [ ! -t 0 ] || engine_ready; then
    return 0
  fi
  if [ "$ENGINE" = "podman" ] && [ "$OS_KIND" != "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
    warn "Prerequisites are not met: run $SCRIPT_NAME as root (sudo) - the Catalog uses rootful Podman."
    echo
    return 0
  fi
  detect_compose >/dev/null 2>&1 || true
  warn "Prerequisites are not met: ${COMPOSE_PROBLEM:-$ENGINE_NAME is not ready for the Catalog}"
  engine_setup ask || true
  echo
}

# engine_setup ask|yes -> everything the stack needs with the engine of this folder: the engine, its
# services or Linux VM, and Docker Compose. An empty CONTAINER_ENGINE is set to it afterwards.
engine_setup() {
  local mode="${1:-ask}"
  engine_guard || return 1
  # the sites the setup downloads from: only those that cannot be reached are named
  if ! net_engine_check && [ "$mode" = "ask" ] && ! confirm "Set up $ENGINE_NAME anyway?" n; then
    return 1
  fi
  case "$ENGINE_KIND" in
    podman) podman_setup "$mode" || return 1 ;;
    *) docker_setup "$mode" || return 1 ;;
  esac
  if [ -z "$CONTAINER_ENGINE" ] && [ -n "$SCRIPT_PATH" ] && [ -w "$SCRIPT_PATH" ] && set_setting CONTAINER_ENGINE "$ENGINE_KIND"; then
    CONTAINER_ENGINE="$ENGINE_KIND"
    ok "CONTAINER_ENGINE = \"$ENGINE_KIND\": this folder uses $ENGINE_NAME from now on."
  fi
}

# podman_setup ask|yes -> Podman, its services or machine, and Docker Compose
podman_setup() {
  local mode="${1:-ask}"
  if ! use_sudo; then
    err "Setting up Podman needs root: run $SCRIPT_NAME as root, or install sudo."
    return 1
  fi
  if [ "$OS_KIND" = "Darwin" ]; then
    mac_prepare "$mode" || return 1
  else
    install_podman_linux "$mode" || return 1
  fi
  install_compose_provider "$mode" || return 1
  require_engine
}

# True when Docker comes from the packages of this Linux (openSUSE, SLES): their Docker Compose is old,
# the installer keeps the newest one as Docker's plugin
docker_from_distro() {
  [ "$OS_KIND" != "Darwin" ] && [[ " $(os_release ID) $(os_release ID_LIKE) " == *suse* || "$(os_release ID)" == sles* ]]
}

# docker_setup ask|yes -> Docker Engine and its service (Linux), Docker Desktop or Colima (macOS), and
# the newest Docker Compose from GitHub when Docker has none, an old one of its distribution, or the
# installer's own
docker_setup() {
  local mode="${1:-ask}"
  if ! use_sudo; then
    err "Setting up Docker needs root: run $SCRIPT_NAME as root, or install sudo."
    return 1
  fi
  case "$OS_KIND:$ENGINE_KIND" in
    Darwin:colima) mac_colima "$mode" || return 1 ;;
    Darwin:*) mac_docker_desktop "$mode" || return 1 ;;
    *) install_docker_linux "$mode" || return 1 ;;
  esac
  if [ "$OS_KIND" = "Darwin" ]; then
    mac_docker_pin
  fi
  if compose_own || docker_from_distro || ! detect_compose >/dev/null 2>&1; then
    install_compose_provider "$mode" || return 1
  fi
  require_engine
}

# engine_cli_setup KIND -> the commands install-podman and install-docker: set up KIND when the folder
# uses it or has not chosen yet
engine_cli_setup() {
  if [ -n "$CONTAINER_ENGINE" ] && [ "$CONTAINER_ENGINE" != "$1" ]; then
    err "This folder uses CONTAINER_ENGINE=\"$CONTAINER_ENGINE\" - './$SCRIPT_NAME install-engine' sets that up (option 1 changes it)."
    return 1
  fi
  engine_use "$1"
  engine_setup yes
}

# engine_not_here KIND -> why KIND cannot run the Catalog on this machine (empty when it can)
engine_not_here() {
  local osver major v
  osver="$(sw_vers -productVersion 2>/dev/null)" || osver=""
  major="${osver%%.*}"
  case "$OS_KIND:$1" in
    Darwin:podman)
      if [ "$(engine_arch)" != "arm64" ]; then
        echo "Intel Macs are not supported: Podman runs only on Apple Silicon (M1 or newer)."
      elif [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -lt 26 ]; then
        echo "macOS $osver is too old for Podman: Rosetta in the Podman machine needs macOS 26 (Tahoe) or newer."
      fi
      ;;
    Darwin:docker)
      if ! mac_docker_app >/dev/null && ! ( engine_use docker; docker info >/dev/null 2>&1 ) && [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -lt 14 ]; then
        echo "macOS $osver is too old for Docker Desktop: macOS 14 or newer is needed."
      fi
      ;;
    Darwin:colima)
      if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -lt 13 ]; then
        echo "macOS $osver is too old for Colima: macOS 13 or newer is needed (Apple's virtualization)."
      fi
      ;;
    *:colima) echo "Colima runs only on macOS." ;;
    *:podman)
      if command -v podman >/dev/null 2>&1; then
        v="$(engine_use podman; engine_version)"
        if [ -z "$v" ] || version_gt "$PODMAN_MIN" "$v"; then
          echo "Podman ${v:-(unknown version)} is too old: $PODMAN_MIN or newer is needed."
        fi
      elif [ ! -d "${RN1_SYSTEMD_DIR:-/run/systemd/system}" ]; then
        echo "This Linux does not run systemd, which rootful Podman needs here."
      else
        podman_install_plan 2>&1 >/dev/null || true
      fi
      ;;
    *:docker)
      if [ "$(engine_arch)" != "amd64" ]; then
        echo "The Catalog images exist only for amd64 (x86_64); this machine is $(uname -m 2>/dev/null)."
      elif docker_is_snap; then
        docker_snap_problem
        echo
      elif ! command -v docker >/dev/null 2>&1 || docker_is_podman; then
        if [ ! -d "${RN1_SYSTEMD_DIR:-/run/systemd/system}" ]; then
          echo "This Linux does not run systemd, which Docker needs here."
        else
          docker_install_plan 2>&1 >/dev/null || true
        fi
      fi
      ;;
  esac
}

# engine_choices -> the engines of this machine, one per line: KIND|LABEL|STATE|REASON. STATE is data
# (it holds the containers or volumes of this folder's project), ready, installed (setup does the rest)
# or missing (setup installs it). REASON says why KIND cannot be chosen here; empty when it can. When
# engines hold data, only they can be chosen.
engine_choices() {
  local kind label state reason holders="" k
  for k in $(engine_kinds); do
    if engine_has_data "$k"; then
      holders="$holders $k"
    fi
  done
  holders="${holders# }"
  for kind in $(engine_kinds); do
    case "$OS_KIND:$kind" in
      *:podman) label="Podman" ;;
      Darwin:docker) label="Docker Desktop" ;;
      *:docker) label="Docker Engine" ;;
      *) label="Colima" ;;
    esac
    reason="$(engine_not_here "$kind")"
    reason="${reason%%$'\n'*}"
    if [[ " $holders " == *" $kind "* ]]; then
      state="data"
    elif ( engine_use "$kind"; engine_ready ); then
      state="ready"
    elif [ "$kind" = "podman" ] && command -v podman >/dev/null 2>&1; then
      state="installed"
    elif [ "$kind" = "colima" ] && command -v colima >/dev/null 2>&1; then
      state="installed"
    elif [ "$OS_KIND:$kind" = "Darwin:docker" ] && mac_docker_app >/dev/null; then
      state="installed"
    elif [ "$OS_KIND:$kind" != "Darwin:docker" ] && [ "$kind" = "docker" ] && command -v docker >/dev/null 2>&1 && ! docker_is_podman; then
      state="installed"
    else
      state="missing"
    fi
    if [ "$state" != "data" ] && [ -n "$holders" ]; then
      reason="The containers or data volumes of this installation are in $(kinds_text "$holders") - one engine per server."
    fi
    printf '%s|%s|%s|%s\n' "$kind" "$label" "$state" "$reason"
  done
}

# engine_choose KIND -> CONTAINER_ENGINE=KIND in the settings of this script, used from now on; fails,
# with the reason, when KIND cannot be used on this machine
engine_choose() {
  local want="$1" kind label state reason found="no"
  while IFS='|' read -r kind label state reason; do
    if [ "$kind" = "$want" ]; then
      found="yes"
      break
    fi
  done <<< "$(engine_choices)"
  if [ "$found" = "no" ]; then
    err "Unknown container engine \"$want\" - choose one of: $(if [ "$OS_KIND" = "Darwin" ]; then echo "podman, docker, colima"; else echo "podman, docker"; fi)."
    return 1
  fi
  if [ -n "$reason" ]; then
    err "$label cannot be used here: $reason"
    return 1
  fi
  if [ "$CONTAINER_ENGINE" != "$want" ]; then
    set_setting CONTAINER_ENGINE "$want" || return 1
    CONTAINER_ENGINE="$want"
  fi
  engine_use "$want"
  ok "CONTAINER_ENGINE = \"$want\" ($label)"
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

# Volumes that already belong to this Compose project (empty if none, or if the engine cannot be reached).
project_volumes() {
  if ! engine_cli; then
    return 0
  fi
  "$ENGINE" volume ls -q --filter "label=com.docker.compose.project=$(stack_project)" 2>/dev/null || true
}

# False when the engine is installed but does not answer (the Podman machine, Colima, Docker Desktop or
# the daemon not started); true when it answers or is not installed (it holds no container then)
engine_answers() {
  ! engine_cli || "$ENGINE" volume ls -q --filter "label=com.docker.compose.project=$(stack_project)" >/dev/null 2>&1
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
    for var in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS NPM_ADMIN_PASSWORD; do
      printf -v "$var" '%s' "$(env_value "$var")"
    done
    CATALOG_HOSTNAME="$(catalog_hostname "$ENV_FILE")"
    MONGO_WT_CACHE_GB="$(mongo_cache_written)"
    ENV_FILE="$tmp_env"
    COMPOSE_FILE="$tmp_compose"
    write_env_file
    write_compose_file
  )
  # a .env without the cache of MongoDB gets it at the start (mongo_cache_refresh)
  if ! grep -q '^MONGO_WT_CACHE_GB=' "$ENV_FILE"; then
    sed -i '/^MONGO_WT_CACHE_GB=/d' "$tmp_env"
  fi
  if [ "$(cat "$tmp_env")" != "$(cat "$ENV_FILE")" ] || [ "$(cat "$tmp_compose")" != "$(cat "$COMPOSE_FILE")" ]; then
    rc=0
  fi
  rm -f "$tmp_env" "$tmp_compose"
  return "$rc"
}

# True when an installer older than the fixed host name of catalog-web wrote .env (no CATALOG_HOSTNAME): the
# files differ from what this one writes (settings_stale), whatever the settings are
files_older() {
  [ -f "$ENV_FILE" ] && ! grep -q '^CATALOG_HOSTNAME=' "$ENV_FILE"
}

###############################################################################
# Memory
###############################################################################

# The cache of MongoDB in .env (MONGO_WT_CACHE_GB): MONGO_CACHE_GB, else automatic from the memory of the engine
MONGO_WT_CACHE_GB=""
# "yes" while an import runs again after an out-of-memory stop: the memory was asked about already
MEM_ASKED=""
ERREXIT_RC=0
# Seconds the engine has to answer again after a restart of its VM (brew services starts Colima in the background)
MEM_ENGINE_WAIT=180

# Memory the containers can use, in MB: the engine's (on macOS its Linux VM), else MemTotal of this server on
# Linux; empty when unknown
engine_mem_mb() {
  local b=""
  if engine_cli; then
    if [ "$ENGINE" = "docker" ]; then
      b="$(docker info --format '{{.MemTotal}}' 2>/dev/null)" || b=""
    else
      b="$(podman info --format '{{.Host.MemTotal}}' 2>/dev/null)" || b=""
    fi
    b="${b%%$'\n'*}"
  fi
  if [[ "$b" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$((b / 1048576))"
  elif [ "$OS_KIND" != "Darwin" ]; then
    b="$(awk '$1 == "MemTotal:" { print $2; exit }' /proc/meminfo 2>/dev/null)" || b=""
    if [[ "$b" =~ ^[1-9][0-9]*$ ]]; then
      printf '%s' "$((b / 1024))"
    fi
  fi
}

# mem_gb MB -> whole GB, as the VM or the server was given them (a VM of 14 GB shows 13928 MB: its kernel keeps some)
mem_gb() {
  printf '%s' "$((($1 + 1023) / 1024))"
}

# mem_low MB -> true below MEM_RECOMMENDED_GB; 92 % of it counts as enough (the kernel keeps some)
mem_low() {
  [ $(($1 * 100)) -lt $((MEM_RECOMMENDED_GB * 1024 * 92)) ]
}

# mongo_cache_valid VALUE -> true for a cache size of MongoDB: GB with up to two decimals, at least 0.25
mongo_cache_valid() {
  local f
  if ! [[ "$1" =~ ^(0|[1-9][0-9]{0,3})(\.([0-9]{1,2}))?$ ]]; then
    return 1
  fi
  f="${BASH_REMATCH[3]}00"
  [ $((BASH_REMATCH[1] * 100 + 10#${f:0:2})) -ge 25 ]
}

# mongo_cache_gb [MB] -> the cache of MongoDB in GB: MONGO_CACHE_GB, else (memory of the engine - 10 GB) / 2, at
# least 1 - about 10 GB stay for catalog-web, the workers, OpenSearch, RabbitMQ and MinIO (14 GB: 2, 24 GB: 7,
# 32 GB: 11). Empty when it is automatic and the memory is unknown.
mongo_cache_gb() {
  local mb h
  if [ -n "${MONGO_CACHE_GB:-}" ]; then
    printf '%s' "$MONGO_CACHE_GB"
    return 0
  fi
  if [ $# -gt 0 ]; then
    mb="$1"
  else
    mb="$(engine_mem_mb)"
  fi
  if [ -z "$mb" ]; then
    return 0
  fi
  h=$(($(mem_gb "$mb") - 10))
  if [ "$h" -lt 2 ]; then
    printf '1'
  elif [ $((h % 2)) -eq 0 ]; then
    printf '%s' "$((h / 2))"
  else
    printf '%s.5' "$((h / 2))"
  fi
}

# The cache of MongoDB that .env has for the current settings, without asking the engine: MONGO_CACHE_GB, else
# the automatic value in .env (it is written again at every start)
mongo_cache_written() {
  if [ -n "${MONGO_CACHE_GB:-}" ]; then
    printf '%s' "$MONGO_CACHE_GB"
  else
    env_value MONGO_WT_CACHE_GB
  fi
}

# Before a start: the cache of MongoDB in .env for the memory the engine has now (a VM that got more memory gives
# MongoDB more). Compose creates only mongo again when it changed.
mongo_cache_refresh() {
  local want have
  if [ ! -f "$ENV_FILE" ] || ! grep -q 'wiredTigerCacheSizeGB' "$COMPOSE_FILE" 2>/dev/null; then
    return 0
  fi
  want="$(mongo_cache_gb)"
  have="$(env_value MONGO_WT_CACHE_GB)"
  if [ -z "$want" ] || ! mongo_cache_valid "$want" || { [ "$want" = "$have" ] && grep -q '^MONGO_WT_CACHE_GB=' "$ENV_FILE"; }; then
    return 0
  fi
  if grep -q '^MONGO_WT_CACHE_GB=' "$ENV_FILE"; then
    sed -i "s/^MONGO_WT_CACHE_GB=.*/MONGO_WT_CACHE_GB=$want/" "$ENV_FILE"
  elif grep -q '^MONGO_PORT_HOST=' "$ENV_FILE"; then
    sed -i "/^MONGO_PORT_HOST=/a MONGO_WT_CACHE_GB=$want" "$ENV_FILE"
  else
    printf '\nMONGO_WT_CACHE_GB=%s\n' "$want" >> "$ENV_FILE"
  fi
  info "MongoDB gets a cache of $want GB${have:+ (was $have GB)}$(if [ -z "${MONGO_CACHE_GB:-}" ]; then printf ' for the memory of %s' "$ENGINE_NAME"; fi)."
}

# A note when the files of this installation do not limit the cache of MongoDB yet (an older installer wrote them)
mongo_cache_note() {
  if [ -f "$COMPOSE_FILE" ] && ! grep -q 'wiredTigerCacheSizeGB' "$COMPOSE_FILE"; then
    echo "  $COMPOSE_FILE does not limit the cache of MongoDB yet, which takes"
    echo "  about half of the memory: $(hint 2 generate) writes the files again."
  fi
}

# CPUs of the Colima VM (its colima.yaml), else those a new VM gets
mac_colima_cpus() {
  local c
  c="$(sed -n 's/^cpu:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$(mac_colima_yaml)" 2>/dev/null | head -n 1)" || c=""
  if [ -z "$c" ]; then
    read -r c _ <<< "$(mac_vm_size 2>/dev/null)"
  fi
  printf '%s' "$c"
}

# True when brew services has Colima: its colima start -f starts the VM at login. While the VM runs, a new
# colima start -f ends at once and launchd starts it again, so a colima stop does not last.
mac_colima_service() {
  local s
  s="$(brew services list 2>/dev/null | awk '$1 == "colima" { print $2 }')" || s=""
  [ -n "$s" ] && [ "$s" != "none" ]
}

# mem_vm_cmds podman|colima [MACHINE] -> the commands that give the Linux VM on macOS MEM_RECOMMENDED_GB GB: the
# Podman machine while it is stopped; Colima through colima.yaml when brew services starts it
mem_vm_cmds() {
  if [ "$1" = "colima" ]; then
    if mac_colima_service; then
      echo "      brew services stop colima; colima stop"
      echo "      memory: $MEM_RECOMMENDED_GB in $(mac_colima_yaml)"
      echo "      brew services start colima"
    else
      echo "      colima stop && colima start --cpu $(mac_colima_cpus) --memory $MEM_RECOMMENDED_GB"
    fi
  else
    echo "      podman machine stop ${2:-}"
    echo "      podman machine set --memory $((MEM_RECOMMENDED_GB * 1024)) ${2:-}"
    echo "      podman machine start ${2:-}"
  fi
}

# How the containers get more memory: the Linux VM on macOS (macOS gives it memory only as it uses it), the
# server itself on Linux
mem_hint() {
  case "$OS_KIND:$ENGINE_KIND" in
    Darwin:podman)
      echo "  More memory for the Podman machine (macOS gives it only what it uses):"
      mem_vm_cmds podman "$(mac_machine)"
      ;;
    Darwin:colima)
      echo "  More memory for the Colima VM (macOS gives it only what it uses):"
      mem_vm_cmds colima
      ;;
    Darwin:*) echo "  Docker Desktop: Settings > Resources > Memory - $MEM_RECOMMENDED_GB GB, then Apply & restart." ;;
    *)
      echo "  The memory of this server has to be raised by whoever runs it"
      echo "  (VM settings or hardware); MONGO_CACHE_GB (option 1) lowers MongoDB's part."
      ;;
  esac
}

# mem_oom_stops [SINCE] -> the containers of this stack the kernel stopped for lack of memory. Podman keeps
# OOMKilled when the restart policy starts the container again (only a new container clears it): SERVICE|RESTARTS,
# a new stop shows as more restarts. Docker clears it at that start: the SERVICE of each oom event since SINCE
# (seconds; else the last 24 hours - the daemon keeps only its last 256 events).
mem_oom_stops() {
  local ids
  if ! engine_cli; then
    return 0
  fi
  ids="$("$ENGINE" ps -aq --filter "label=com.docker.compose.project=$(stack_project)" 2>/dev/null)" || ids=""
  if [ -z "$ids" ]; then
    return 0
  fi
  if [ "$ENGINE" = "docker" ]; then
    docker events --since "${1:-24h}" --until "$(date +%s)" --filter type=container --filter event=oom \
      --filter "label=com.docker.compose.project=$(stack_project)" \
      --format '{{index .Actor.Attributes "com.docker.compose.service"}}' 2>/dev/null || true
  else
    # shellcheck disable=SC2086
    "$ENGINE" container inspect --format '{{.State.OOMKilled}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.RestartCount}}' $ids 2>/dev/null | sed -n 's/^true|//p' || true
  fi
}

# Before an import: what mem_oom_report counts from - with Podman the stops so far, with Docker the time (@SECONDS)
mem_oom_marks() {
  if [ "$ENGINE" = "docker" ]; then
    printf '@%s\n' "$(date +%s)"
  else
    mem_oom_stops
  fi
}

# mem_oom_report [MARKS] -> names the containers of this stack the kernel stopped for lack of memory - only those
# since MARKS (mem_oom_marks of before) - and how the engine gets more; fails when there is none
mem_oom_report() {
  local marks="${1:-}" since="" line svc found="" mb
  if [[ "$marks" == @* ]]; then
    since="${marks#@}"
  fi
  while IFS= read -r line; do
    if [ -n "$line" ] && ! grep -qxF -- "$line" <<< "$marks" && [[ " $found " != *" ${line%%|*} "* ]]; then
      found="$found ${line%%|*}"
    fi
  done <<< "$(mem_oom_stops "$since")"
  if [ -z "$found" ]; then
    return 1
  fi
  for svc in $found; do
    case "$svc" in
      mongo) svc="MongoDB" ;;
      opensearch) svc="OpenSearch" ;;
      rabbitmq) svc="RabbitMQ" ;;
      minio) svc="MinIO" ;;
    esac
    warn "$svc was stopped by the kernel: out of memory."
  done
  mb="$(engine_mem_mb)"
  if [ -n "$mb" ] && ! mem_low "$mb"; then
    echo "  The engine has $(mem_gb "$mb") GB of memory."
    echo "  MONGO_CACHE_GB (option 1) lowers the part MongoDB takes."
  else
    if [ -n "$mb" ]; then
      echo "  The engine has $(mem_gb "$mb") GB of memory; at least $MEM_RECOMMENDED_GB GB is recommended."
    else
      echo "  At least $MEM_RECOMMENDED_GB GB of memory is recommended."
    fi
    mem_hint
  fi
  mongo_cache_note
}

# Waits until the engine answers again after a restart of its VM (at most MEM_ENGINE_WAIT seconds)
mem_wait_engine() {
  local start="$SECONDS"
  until "$ENGINE" info >/dev/null 2>&1; do
    if [ $((SECONDS - start)) -ge "$MEM_ENGINE_WAIT" ]; then
      return 1
    fi
    sleep 2
  done
}

# After a start of the Podman machine: waits (at most 2 minutes) while its podman-restart.service still starts the
# containers of before - Compose would otherwise create mongo again in the middle of it
mac_restart_wait() {
  local start="$SECONDS" s
  while true; do
    s="$(podman machine ssh "$1" systemctl is-active podman-restart.service 2>/dev/null)" || true
    if [ "${s//[^a-z]/}" != "activating" ] || [ $((SECONDS - start)) -ge 120 ]; then
      return 0
    fi
    sleep 2
  done
}

# mem_raise wizard|confirm -> on macOS, after PODMAN REBOOT or COLIMA REBOOT is typed: MEM_RECOMMENDED_GB GB for
# the Podman machine or the Colima VM, when the Mac keeps 8 GB for itself (the VM is stopped and started again; a
# running Catalog is started again and waited for); with Docker Desktop where it is set. 0: raised, 1: not
# raised (Enter or any other answer), 2: stopped (0 or the end of input in the wizard), 3: the VM or the Catalog
# does not run cleanly again (yet). Ctrl+C while the Podman machine starts: exit 130 (the menu says Interrupted).
mem_raise() {
  local how="$1" ram what word stop="" answer ans=0 rc=0 m="" running="" mb yaml log traps cut="" started="yes"
  if [ "$OS_KIND" != "Darwin" ]; then
    return 1
  fi
  if [ "$ENGINE_KIND" = "docker" ]; then
    mem_hint
    return 1
  fi
  ram="$(sysctl -n hw.memsize 2>/dev/null)" || ram=""
  ram="${ram//[^0-9]/}"
  if [ "${ram:-0}" -lt $(((MEM_RECOMMENDED_GB + 8) * 1073741824)) ]; then
    echo "  This Mac has $((${ram:-0} / 1073741824)) GB: not enough to give the containers $MEM_RECOMMENDED_GB GB"
    echo "  and keep 8 GB for macOS."
    return 1
  fi
  what="Podman machine"
  if [ "$ENGINE_KIND" = "colima" ]; then
    what="Colima VM"
  fi
  if [ -n "$(job_running_ids)" ]; then
    echo "  A job is running (J): the $what gets more memory with a restart,"
    echo "  when the job is done."
    return 1
  fi
  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ] && detect_compose >/dev/null 2>&1 && [ -n "$(compose ps -q catalog-web 2>/dev/null)" ]; then
    running="yes"
  fi
  # the restart stops every container: only the typed word starts it, not a y out of habit
  word="PODMAN REBOOT"
  if [ "$ENGINE_KIND" = "colima" ]; then
    word="COLIMA REBOOT"
  fi
  if [ "$how" = "wizard" ]; then
    stop=", 0 stops"
  fi
  echo "  The $what can get $MEM_RECOMMENDED_GB GB; macOS gives it memory only as it uses it."
  warn "For that the $what is STOPPED and STARTED again (about a minute):"
  echo "  every container in it stops${running:+; the Catalog is started again afterwards}."
  if ! read -r -p "Type $word to restart it with $MEM_RECOMMENDED_GB GB (Enter: no$stop): " answer; then
    echo
    if [ "$how" = "wizard" ]; then
      return 2
    fi
    answer=""
  fi
  if [ "$answer" != "$word" ]; then
    if [ "$how" = "wizard" ] && [ "$answer" = "0" ]; then
      return 2
    fi
    if [ -n "$answer" ]; then
      info "Not $word: the $what keeps its memory."
    else
      info "The $what keeps its memory."
    fi
    return 1
  fi
  info "The $what restarts with $MEM_RECOMMENDED_GB GB:"
  if [ "$ENGINE_KIND" = "colima" ]; then
    mem_vm_cmds colima
    if mac_colima_service; then
      # the colima start -f of brew services would start the VM again with its old memory: the memory goes into
      # colima.yaml, and brew services starts the VM with it
      brew services stop colima >/dev/null 2>&1 || true
      if colima status >/dev/null 2>&1 && ! colima stop; then
        err "Colima did not stop - its memory stays as it is."
        brew services start colima >/dev/null 2>&1 || true
        return 1
      fi
      yaml="$(mac_colima_yaml)"
      if grep -q '^memory:' "$yaml" 2>/dev/null; then
        sed -i "s/^memory:.*/memory: $MEM_RECOMMENDED_GB/" "$yaml"
      else
        printf 'memory: %s\n' "$MEM_RECOMMENDED_GB" >> "$yaml"
      fi
      info "The Colima VM starts again (about a minute)..."
      if ! brew services start colima >/dev/null; then
        err "Colima did not start again - start it: brew services start colima"
        return 3
      fi
    else
      m="$(mac_colima_cpus)"
      if ! colima stop; then
        err "Colima did not stop - its memory stays as it is."
        return 1
      fi
      if ! colima start --cpu "$m" --memory "$MEM_RECOMMENDED_GB"; then
        err "Colima did not start again with $MEM_RECOMMENDED_GB GB (see above) - start it: colima start"
        return 3
      fi
    fi
    mac_docker_pin
  else
    m="$(mac_machine)"
    log="$(mktemp)" || return 1
    mem_vm_cmds podman "$m"
    if ! podman machine stop "$m"; then
      rm -f -- "$log"
      err "The Podman machine did not stop - its memory stays as it is."
      return 1
    fi
    podman machine set --memory "$((MEM_RECOMMENDED_GB * 1024))" "$m" || ans=1
    # its own output (the helper for the Docker API socket, DOCKER_HOST) only when it fails; into a file, not a
    # pipe, which a helper it leaves running could hold open. Ctrl+C: the file goes, how to start it is shown.
    info "The Podman machine starts again (about a minute)..."
    traps="$(trap -p INT TERM)"
    trap 'cut="yes"' INT TERM
    podman machine start "$m" > "$log" 2>&1 || started="no"
    trap - INT TERM
    eval "$traps"
    if [ -n "$cut" ]; then
      rm -f -- "$log"
      echo
      warn "Stopped while the Podman machine started - if it does not run, start it:"
      echo "      podman machine start $m"
      exit 130
    fi
    if [ "$started" = "no" ]; then
      cat -- "$log"
      rm -f -- "$log"
      err "The Podman machine did not start again - start it:"
      echo "      podman machine start $m"
      return 3
    fi
    rm -f -- "$log"
    ok "The Podman machine runs again."
  fi
  if ! mem_wait_engine; then
    err "$ENGINE_NAME does not answer after the restart:"
    echo "  $(engine_down_hint)."
    return 3
  fi
  if [ "$ENGINE_KIND" = "podman" ]; then
    mac_restart_wait "$m"
  fi
  if [ "$ans" -ne 0 ]; then
    err "The memory of the Podman machine could not be changed (see above)."
  else
    mb="$(engine_mem_mb)"
    if [ -n "$mb" ] && mem_low "$mb"; then
      warn "The $what still has $(mem_gb "$mb") GB of memory."
    elif [ -n "$mb" ]; then
      ok "The $what has $(mem_gb "$mb") GB of memory now."
    fi
  fi
  if [ -n "$running" ]; then
    run_job "Start the Catalog again" -- install_start || rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "The Catalog does not run cleanly again yet."
      if [ "$rc" -eq 3 ]; then
        echo "  Its start goes on in the background (J)."
      fi
      return 3
    fi
  fi
  [ "$ans" -eq 0 ]
}

# mem_ask wizard|confirm [import|said] -> below MEM_RECOMMENDED_GB: says so (before an import also when the files
# do not limit the cache of MongoDB yet; "said": the check just printed it), offers more memory for the Linux VM
# on macOS, then asks whether to go on with less. 0: go on, 1: no, 2: stopped (0 or the end of input in the
# wizard). Outside the menu without a terminal only the warning, then on.
mem_ask() {
  local how="$1" mb rc=0
  if [ "$MEM_ASKED" = "yes" ]; then
    return 0
  fi
  mb="$(engine_mem_mb)"
  if [ -z "$mb" ] || ! mem_low "$mb"; then
    return 0
  fi
  if [ "${2:-}" != "said" ]; then
    warn "This engine has $(mem_gb "$mb") GB of memory; at least $MEM_RECOMMENDED_GB GB is recommended."
  fi
  if [ "${2:-}" = "import" ]; then
    mongo_cache_note
  fi
  if [ "$INTERACTIVE" != "true" ] && [ ! -t 0 ]; then
    return 0
  fi
  mem_raise "$how" || rc=$?
  case "$rc" in
    0)
      mb="$(engine_mem_mb)"
      if [ -z "$mb" ] || ! mem_low "$mb"; then
        return 0
      fi
      ;;
    2) return 2 ;;
    3) return 1 ;;
  esac
  if [ "$how" = "wizard" ]; then
    rc=0
    wiz_yes_no "Continue with $(mem_gb "$mb") GB anyway?" n || rc=$?
    return "$rc"
  fi
  confirm "Continue with $(mem_gb "$mb") GB anyway?" n
}

# mem_import_again RC JOB MARKS file|chain|daily -> after an import that failed (RC; JOB yes: it ran as a job,
# whose log names the reason) because the kernel stopped a container for lack of memory (since MARKS, see
# mem_oom_marks): the reason, more memory for the VM on macOS, then whether to import the file or the chain
# again - a daily snapshot builds on the data before, it is not offered again. True when it should run again.
mem_import_again() {
  local rc="$1" job="$2" marks="$3" what="$4" mb ans=0
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
    return 1
  fi
  if [ "$job" = "yes" ]; then
    mem_oom_report "$marks" >/dev/null 2>&1 || return 1
  else
    mem_oom_report "$marks" || return 1
  fi
  if [ "$INTERACTIVE" != "true" ] && [ ! -t 0 ]; then
    return 1
  fi
  echo
  mb="$(engine_mem_mb)"
  # Docker Desktop: mem_oom_report named where its memory is set
  if [ -n "$mb" ] && mem_low "$mb" && [ "$ENGINE_KIND" != "docker" ]; then
    mem_raise confirm || ans=$?
    if [ "$ans" -eq 3 ]; then
      return 1
    fi
  fi
  case "$what" in
    daily)
      echo "  A daily snapshot builds on the day before: import again from a full snapshot"
      echo "  on (option 19, a chain from option 17)."
      return 1
      ;;
    chain) what="the chain" ;;
    *) what="the same file" ;;
  esac
  echo "  A snapshot import replaces the data, so the half import does no harm."
  confirm "Import $what again?" y
}

# errexit_rc FUNCTION ARGS... -> ERREXIT_RC: the exit code of FUNCTION, which runs in a subshell with errexit as
# here (called left of || or in an if, a function runs without errexit)
errexit_rc() {
  ERREXIT_RC=0
  case "$-" in
    *e*)
      set +e
      ( set -e; "$@" )
      ERREXIT_RC=$?
      set -e
      ;;
    *) "$@" || ERREXIT_RC=$? ;;
  esac
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

# True when the configured MongoDB (8 or newer) needs GLIBC_TUNABLES=glibc.pthread.rseq=1 on this
# kernel. The kernels 6.19 to 7.0.13 broke the rseq behaviour that TCMalloc's per-CPU caches rely on,
# and the released mongod refuses to start there while those caches are on (SERVER-121912). Ubuntu's
# 7.0.0-NN always counts as 7.0.0, even with the kernel fix. When glibc registers rseq, TCMalloc uses
# per-thread caches instead: the broken path is not used and mongod starts (some performance cost).
# mongo_rseq_workaround [MONGO_TAG] (default: the one in use)
mongo_rseq_workaround() {
  local tag="${1-$(setting MONGO_TAG)}"
  tag="${tag//[\"\']/}"
  if [[ "$tag" =~ ^([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -lt 8 ]; then
    return 1
  fi
  kernel_blocks_mongo8
}

# True when MongoDB would not start with the generated files: they lack the workaround it needs here
# (generated before this version, or on another machine)
mongo_kernel_problem() {
  mongo_rseq_workaround && [ -f "$COMPOSE_FILE" ] && ! grep -q '^      GLIBC_TUNABLES: ' "$COMPOSE_FILE"
}

# True when the files still have the MongoDB workaround although this kernel does not need it any more
# (generated on an older kernel): they work, but MongoDB runs without its per-CPU caches
mongo_workaround_unneeded() {
  ! mongo_rseq_workaround && [ -f "$COMPOSE_FILE" ] && grep -q '^      GLIBC_TUNABLES: ' "$COMPOSE_FILE"
}

# The upstream kernel version of an Ubuntu kernel (Ubuntu 7.0.0-38.38-generic 7.0.14 -> 7.0.14)
kernel_upstream_version() {
  local sig=""
  if [ -r /proc/version_signature ]; then
    sig="$(cat /proc/version_signature 2>/dev/null)" || sig=""
  fi
  printf '%s' "${sig##* }"
}

kernel_blocks_mongo8() {
  local release major minor patch
  release="$(engine_kernel)"
  [ -n "$release" ] || return 1
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

# Where nothing is installed: the Catalog version a start would install - the one .env names (option 6 starts
# the files as they are), the setting while there is no .env
next_catalog() {
  local v=""
  if [ -f "$ENV_FILE" ]; then
    v="$(env_value CATALOG_IMAGE)"
    v="${v##*:}"
  fi
  printf '%s' "${v:-$CATALOG_VERSION}"
}

# Where nothing is installed: the version a start would install - "X would be installed (the newest)", or the
# newer one Docker Hub has; when the files name another version than the settings, both
install_next_text() {
  local next text
  next="$(next_catalog)"
  text="$next would be installed"
  if [ "$next" != "$CATALOG_VERSION" ]; then
    printf '%s (the files; option 2 writes %s)' "$text" "$CATALOG_VERSION"
    return 0
  fi
  case "$HUB_STATUS" in
    ok)
      if [ "$LATEST_VERSION" = "$CATALOG_VERSION" ]; then
        text="$text (the newest)"
      elif ! is_version "$CATALOG_VERSION"; then
        text="$text, newest on Docker Hub: $(version_with_tag "$LATEST_VERSION")"
      elif version_gt "$LATEST_VERSION" "$CATALOG_VERSION"; then
        text="$text, ${C_YLW}newer: $(version_with_tag "$LATEST_VERSION"), option 8${C_RST}"
      fi
      ;;
    failed)
      text="$text, newest version unknown (Docker Hub not reachable)"
      ;;
  esac
  printf '%s' "$text"
}

# version_label KIND -> "Catalog X - up to date": the installed Catalog. Without one (KIND, see install_kind:
# files or none) the version a start would install: "Catalog not installed - X would be installed (the newest)".
# When the engine cannot tell the version (or the files are incomplete): "Catalog X (the settings)", no status.
version_label() {
  local cur label kind="${1:-}"
  if nothing_installed "$kind"; then
    printf 'Catalog %snot installed%s - %s' "$C_YLW" "$C_RST" "$(install_next_text)"
    return 0
  fi
  cur="$(installed_catalog)"
  if [ -z "$cur" ]; then
    printf 'Catalog %s (the settings)' "$CATALOG_VERSION"
    return 0
  fi
  label="Catalog $cur"
  case "$HUB_STATUS" in
    ok)
      if [ "$LATEST_VERSION" = "$cur" ]; then
        label="$label - ${C_GRN}up to date${C_RST}"
      elif ! is_version "$cur"; then
        label="$label - newest on Docker Hub: $(version_with_tag "$LATEST_VERSION")"
      elif version_gt "$LATEST_VERSION" "$cur"; then
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

# settings_sum FILE -> "CRC BYTES": cksum of the settings section of FILE, the lines settings_section prints
# (from '# CONFIGURE ONLY THIS SECTION' to '# DO NOT CHANGE ANYTHING BELOW', each with its newline). Fails
# when the section is damaged.
settings_sum() {
  local sec sum crc bytes
  sec="$(settings_section "$1")" || return 1
  sum="$(printf '%s\n' "$sec" | cksum)" || return 1
  read -r crc bytes <<< "$sum"
  printf '%s %s' "$crc" "$bytes"
}

# settings_published FILE -> the SETTINGS_PUBLISHED_SUM value FILE holds ("CRC BYTES"; empty: none, or gone)
settings_published() {
  awk -F'"' '/^SETTINGS_PUBLISHED_SUM="[0-9]+ [0-9]+"$/ { print $2; exit }' "$1" 2>/dev/null || true
}

# settings_pristine [FILE] -> true when the settings of FILE (default: this installer) are as published: the
# SETTINGS_PUBLISHED_SUM it holds (read from the file, which the installer changes while it runs) is the cksum
# of its settings section. A new download is; any change of a setting, by the installer or by hand, ends it -
# for good: settings_unpublish. An installer without the constant (an older version) never is.
settings_pristine() {
  local file="${1:-$SCRIPT_PATH}" want have
  if [ -z "$file" ] || [ ! -r "$file" ]; then
    return 1
  fi
  want="$(settings_published "$file")"
  [ -n "$want" ] && have="$(settings_sum "$file")" && [ "$have" = "$want" ]
}

# settings_set_sum FILE VALUE -> the SETTINGS_PUBLISHED_SUM line of FILE with VALUE (empty: gone). Nothing
# when FILE has no such line. The content is written back, so owner and mode stay.
settings_set_sum() {
  local file="$1" value="$2" tmp
  if ! grep -q '^SETTINGS_PUBLISHED_SUM="' "$file" 2>/dev/null; then
    return 0
  fi
  tmp="$(mktemp)" || return 1
  if ! SUM_VALUE="$value" awk '/^SETTINGS_PUBLISHED_SUM="/ { print "SETTINGS_PUBLISHED_SUM=\"" ENVIRON["SUM_VALUE"] "\""; next } { print }' "$file" > "$tmp" \
    || ! cat -- "$tmp" > "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
}

# settings_unpublish [FILE] -> the settings of FILE (default: this installer) are no new download's any more:
# its SETTINGS_PUBLISHED_SUM is blank, in the file and in this run. The installer calls it whenever it writes
# a setting into the file (set_setting), when a start finds the section changed or has nothing to take over,
# and after the editor. Values put back to the published ones later - by the installer or by hand - make no
# new download again, and the installation's values are never taken over against a choice.
settings_unpublish() {
  local file="${1:-$SCRIPT_PATH}"
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    return 0
  fi
  if [ "$file" = "$SCRIPT_PATH" ]; then
    SETTINGS_PUBLISHED_SUM=""
  fi
  if [ -n "$(settings_published "$file")" ] && [ -w "$file" ]; then
    settings_set_sum "$file" "" || true
  fi
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
      !insec && /^SETTINGS_PUBLISHED_SUM="/ { print "SETTINGS_PUBLISHED_SUM=\"\""; next }
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
  # a setting written by the installer is no published default any more (the awk pass blanked the sum)
  if [ "$file" = "$SCRIPT_PATH" ]; then
    SETTINGS_PUBLISHED_SUM=""
  fi
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
  local mode="${1:-}" choice selected="" generated count installed
  info "Reading the available versions from Docker Hub..."
  if ! fetch_hub_versions; then
    err "Could not read the versions from Docker Hub (no internet access, a proxy is needed, or the images are not on Docker Hub)."
    echo "CATALOG_VERSION can still be changed by hand with option 1; $(hint 26 network-check) checks the internet access."
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

  installed="$(installed_catalog)"
  if [ "$selected" = "$CATALOG_VERSION" ]; then
    info "$selected is already selected."
  elif is_version "$installed" && version_gt "$installed" "$selected"; then
    err "$selected is OLDER than the installed $installed, which migrated the database - not selected (option 21 goes back after a failed upgrade)."
    return 0
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
    if is_version "$installed" && version_gt "$selected" "$installed"; then
      warn "Catalog $installed is installed: applying $selected here comes without the MongoDB backup, health check and rollback of U and option 21."
    fi
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
  local wanted="${1:-}" installed
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
  installed="$(installed_catalog)"
  if is_version "$installed" && version_gt "$installed" "$wanted"; then
    err "$wanted is OLDER than the installed $installed, which migrated the database - not selected."
    return 1
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
  if is_version "$installed" && version_gt "$wanted" "$installed"; then
    echo "Catalog $installed is installed: both ask first, as they come without a MongoDB backup - '$0 upgrade' upgrades it with one, a health check and rollback."
  fi
}

###############################################################################
# Updates and offline bundle
###############################################################################

MANIFEST_TYPES="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json"
UPD_KEYS=(opensearch mongo rabbitmq minio npm)
# Release series Raynet runs with the Catalog (8.0 = 8.0.x, 2 = 2.x.y, empty = any); raised when Raynet moves its own servers, installations get it with the installer update.
declare -A SERIES_ALLOWED=([mongo]="8.0" [opensearch]="2" [rabbitmq]="3" [npm]="2" [minio]="")
# The moving tag inside each series, for when the registry cannot be read (empty: the tag stays)
declare -A SERIES_TAG=([mongo]="8.0" [opensearch]="2" [rabbitmq]="3.13-management-alpine" [npm]="2" [minio]="")
# Memory the containers should have: a full snapshot import loads MongoDB, the Catalog and OpenSearch at the same time
MEM_RECOMMENDED_GB=24
declare -A UPD_VERSIONS=() UPD_RESOLVED=()
UPD_MONGO_HERE=""
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

# in_series KEY VERSION -> true when VERSION (or a tag like 3.13-management-alpine) lies inside the
# allowed series of KEY; without a series every version does
in_series() {
  local s="${SERIES_ALLOWED[$1]-}" core
  if [ -z "$s" ]; then
    return 0
  fi
  core="$(version_core "$2")"
  [ "$core" = "$s" ] || [[ "$core" == "$s".* ]]
}

# The versions of KEY in the registry that lie inside its allowed series, newest first.
series_versions() {
  local v
  while IFS= read -r v; do
    if [ -n "$v" ] && in_series "$1" "$v"; then
      printf '%s\n' "$v"
    fi
  done <<< "${UPD_VERSIONS[$1]-}"
}

# The version recommended for KEY: the newest inside its allowed series (empty: registry not reachable).
recommended_version() {
  local v
  while IFS= read -r v; do
    if [ -n "$v" ] && in_series "$1" "$v"; then
      printf '%s' "$v"
      return 0
    fi
  done <<< "${UPD_VERSIONS[$1]-}"
}

# upd_current KEY TAG -> the exact version behind TAG (after component_info KEY): TAG itself when it
# is exact; for MongoDB the version that runs here (a moving tag such as "8" can point further in the
# registry than the binary that runs); else the version the registry resolves TAG to (empty: unknown)
upd_current() {
  if [[ "$2" =~ $(kind_regex "$C_KIND") ]]; then
    printf '%s' "$2"
  elif [ "$1" = "mongo" ] && [ -n "$UPD_MONGO_HERE" ]; then
    printf '%s' "$UPD_MONGO_HERE"
  else
    printf '%s' "${UPD_RESOLVED[$1]-}"
  fi
}

# The Catalog version recommended: always the newest one on Docker Hub.
recommended_catalog() {
  printf '%s' "${HUB_VERSIONS%%$'\n'*}"
}

series_name() {
  case "$1" in
    mongo) printf 'MongoDB' ;;
    opensearch) printf 'OpenSearch' ;;
    rabbitmq) printf 'RabbitMQ' ;;
    minio) printf 'MinIO' ;;
    npm) printf 'Nginx Proxy Manager' ;;
  esac
}

# The series of the newest version of KEY when the registry has one newer than the allowed series
# ("4" for RabbitMQ 4.3.6 next to the series 3), empty otherwise.
newer_series() {
  local s="${SERIES_ALLOWED[$1]-}" newest rec dots
  newest="${UPD_VERSIONS[$1]-}"
  newest="${newest%%$'\n'*}"
  if [ -z "$s" ] || [ -z "$newest" ] || in_series "$1" "$newest"; then
    return 0
  fi
  rec="$(recommended_version "$1")"
  if [ -n "$rec" ] && ! version_gt "$(version_core "$newest")" "$(version_core "$rec")"; then
    return 0
  fi
  dots="${s//[!.]/}"
  version_core "$newest" | cut -d. -f"1-$((${#dots} + 1))"
}

# newer_series_note KEY... -> "MongoDB 9.0 and RabbitMQ 4 exist - not released for the Catalog yet"
# (empty when no newer series exists)
newer_series_note() {
  local key s list="" n=0
  for key in "$@"; do
    s="$(newer_series "$key")"
    if [ -n "$s" ]; then
      list="$list, $(series_name "$key") $s"
      n=$((n + 1))
    fi
  done
  list="${list#, }"
  case "$n" in
    0) ;;
    1) printf '%s exists - not released for the Catalog yet' "$list" ;;
    *) printf '%s and %s exist - not released for the Catalog yet' "${list%, *}" "${list##*, }" ;;
  esac
}

# rabbitmq_flags_hint FROM TO -> RabbitMQ wants all feature flags enabled before every step
rabbitmq_flags_hint() {
  printf 'Before RabbitMQ %s -> %s enable all feature flags (with the stack running): %s exec rabbitmq rabbitmqctl enable_feature_flag all' "$1" "$2" "$ENGINE"
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

# Checks all components in parallel; results come back through files. Ctrl+C stops the checks and
# returns 130 (nothing is changed); the traps of the caller (the menu's Ctrl+C) come back afterwards.
collect_updates() {
  local key tmp traps stopped=""
  info "Checking Docker Hub and GHCR for new versions..."
  tmp="$(mktemp -d)" || return 1
  traps="$(trap -p INT TERM)"
  trap 'stopped="yes"; kill $(jobs -p) 2>/dev/null || true' INT TERM
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
  until wait; do
    :
  done
  trap - INT TERM
  eval "$traps"
  if [ -n "$stopped" ]; then
    rm -rf -- "$tmp"
    return 130
  fi
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
  UPD_MONGO_HERE=""
  if ! is_exact_tag "$MONGO_TAG" && remove_compose_ok; then
    UPD_MONGO_HERE="$(mongo_running_version)"
  fi
  UPD_CHECKED="$(date +%H:%M)"
}

# Sets ST_TEXT and ST_COLOR for a row: the current version against the recommended one, the newest
# inside the allowed series of KEY (the Catalog has none).
# row_status KIND RESOLVED VERSIONS [KEY]
row_status() {
  local kind="$1" resolved="$2" versions="$3" key="${4:-catalog}" newest="" v
  ST_COLOR="$C_RED"
  if [ -z "$versions" ]; then
    ST_TEXT="unknown (registry not reachable)"
    return 0
  fi
  while IFS= read -r v; do
    if [ -n "$v" ] && in_series "$key" "$v"; then
      newest="$v"
      break
    fi
  done <<< "$versions"
  if [ -z "$newest" ]; then
    ST_TEXT="no version of the series ${SERIES_ALLOWED[$key]-} found"
    return 0
  fi
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
  if ! in_series "$key" "$resolved" && kind_newer "$kind" "$resolved" "$newest"; then
    ST_TEXT="outside the series ${SERIES_ALLOWED[$key]-}"
  elif ! kind_newer "$kind" "$newest" "$resolved"; then
    ST_TEXT="up to date"
    ST_COLOR="$C_GRN"
  elif [ "$kind" = "catalog" ] || [ "$kind" = "minio" ]; then
    ST_TEXT="update available"
  elif [ "$(version_major "$resolved")" = "$(version_major "$newest")" ]; then
    ST_TEXT="update available: $(version_core "$newest")"
  else
    ST_TEXT="major update"
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
  local i=1 key first tag resolved versions newest cat_resolved w_cur=34 w_new=31 head note
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
    newest="$(ui_version "$(recommended_catalog)")"
  else
    row_status catalog "" ""
    newest="-"
  fi
  # nothing installed in this folder (option 99, R, a new folder): the setting is the newest, nothing is up to date
  if nothing_installed "$(install_kind)"; then
    case "$ST_TEXT" in
      "up to date") ST_TEXT="the newest - not installed" ;;
      "update available") ST_TEXT="newer available - not installed" ;;
    esac
  fi
  rows+=("$(ui_pad "$C_BLD$i$C_RST" 4)$(ui_pad "Catalog + 4 workers" 26)$(ui_pad "$(ui_current "$CATALOG_VERSION" "${cat_resolved:-$CATALOG_VERSION}")" "$w_cur")$(ui_pad "$newest" "$w_new")$(ui_badge "$ST_TEXT" "$ST_COLOR")")

  for key in "${UPD_KEYS[@]}"; do
    i=$((i + 1))
    component_info "$key"
    first="${C_SETTINGS%% *}"
    tag="${!first}"
    versions="${UPD_VERSIONS[$key]-}"
    resolved="$(upd_current "$key" "$tag")"
    row_status "$C_KIND" "$resolved" "$versions" "$key"
    newest="$(version_core "$(recommended_version "$key")")"
    if [ "$key" = "npm" ] && [ "$INSTALL_NGINX_PROXY_MANAGER" != "true" ]; then
      ST_TEXT="$ST_TEXT (disabled)"
    fi
    rows+=("$(ui_pad "$C_BLD$i$C_RST" 4)$(ui_pad "$C_LABEL" 26)$(ui_pad "$(ui_current "$tag" "$resolved")" "$w_cur")$(ui_pad "${newest:--}" "$w_new")$(ui_badge "$ST_TEXT" "$ST_COLOR")")
  done

  head="Checked $UPD_CHECKED $UI_SEP Docker Hub and GHCR $UI_SEP linux/amd64"
  if [ -f "$ENV_FILE" ]; then
    head="$head $UI_SEP $ENV_FILE has Catalog $(env_value CATALOG_IMAGE | sed 's/.*://')"
  fi
  ui_screen "Updates" "$head"
  printf '  %s\n' "$C_DIM$(ui_pad "#" 4)$(ui_pad "COMPONENT" 26)$(ui_pad "CURRENT" "$w_cur")$(ui_pad "RECOMMENDED" "$w_new")STATUS$C_RST"
  printf '  %s\n' "${rows[@]}"
  echo
  printf '  %s\n' "${C_DIM}Recommended: the newest Catalog $UI_SEP the others: the newest of the series Raynet runs$C_RST"
  note="$(newer_series_note mongo opensearch rabbitmq minio npm)"
  if [ -n "$note" ]; then
    printf '  %s\n' "$C_DIM$note$C_RST"
  fi
}

# Up to 4 versions of a list inside one allowed series, newest first: the newest of every release
# line (X.Y) from the current one on, then the next newest ones.
# pick_list VERSIONS CURRENT
pick_list() {
  awk -F. -v cur="$(version_core "${2:-}")" '
    BEGIN { split(cur, c, "."); num = (c[1] ~ /^[0-9]+$/) }
    { v[NR] = $0; line = $1 "." $2 }
    $1 ~ /^[0-9]+$/ && !(line in seen) && n < 4 {
      seen[line] = 1
      if (!num || $1 + 0 > c[1] + 0 || ($1 + 0 == c[1] + 0 && $2 + 0 >= c[2] + 0)) { pick[NR] = 1; n++ }
    }
    END {
      for (i = 1; i <= NR && n < 4; i++) if (!pick[i]) { pick[i] = 1; n++ }
      for (i = 1; i <= NR; i++) if (pick[i]) print v[i]
    }' <<< "$1"
}

# list_tag LIST CHOICE -> the entry of LIST that is CHOICE, or whose version is CHOICE (3.13.7 for
# 3.13.7-management-alpine); empty when there is none
list_tag() {
  local v
  while IFS= read -r v; do
    if [ -n "$v" ] && { [ "$v" = "$2" ] || [ "$(version_core "$v")" = "$2" ]; }; then
      printf '%s' "$v"
      return 0
    fi
  done <<< "$1"
}

# Option 8, rows 2-6: another version of a component, only inside its allowed series.
pick_component() {
  local key="$1" first tag resolved versions list choice selected="" count i=0 v marker cur_major sel_major setting last_series series rec note
  local -a box=()
  component_info "$key"
  first="${C_SETTINGS%% *}"
  tag="${!first}"
  series="${SERIES_ALLOWED[$key]-}"
  if [ -z "${UPD_VERSIONS[$key]-}" ]; then
    err "No versions known for $C_LABEL (registry not reachable) - try r) Check again."
    return 1
  fi
  versions="$(series_versions "$key")"
  if [ -z "$versions" ]; then
    err "The registry has no version of $C_LABEL in the series $series."
    return 1
  fi
  resolved="$(upd_current "$key" "$tag")"
  cur_major="$(version_major "${resolved:-$tag}")"
  rec="${versions%%$'\n'*}"
  list="$(pick_list "$versions" "${resolved:-$tag}")"
  count="$(count_lines "$list")"
  note="$(newer_series_note "$key")"
  box=("Current: $C_BLD$(ui_current "$tag" "$resolved")$C_RST   $C_DIM$UI_SEP images: $C_IMAGES$C_RST")
  if [ -n "$series" ]; then
    box+=("${C_DIM}Series $series: the versions Raynet runs with the Catalog$C_RST")
    if ! in_series "$key" "${resolved:-$tag}"; then
      box+=("$C_YLW$(version_core "${resolved:-$tag}") is outside the series$C_RST")
    fi
  fi

  while [ -z "$selected" ]; do
    echo
    ui_box "$(ui_width)" "$C_LABEL" "${box[@]}"
    i=0
    while IFS= read -r v; do
      i=$((i + 1))
      marker=""
      if [ "$v" = "$resolved" ]; then
        marker="  $C_GRN$UI_DOT current$C_RST"
      elif [ "$v" = "$rec" ]; then
        marker="  $C_GRN$UI_OK recommended$C_RST"
      fi
      if [ "$v" != "$resolved" ] && [ "$C_KIND" != "minio" ] && [[ "$cur_major" =~ ^[0-9]+$ ]] && [ "$(version_major "$v")" -gt "$cur_major" ]; then
        marker="$marker  $C_MAG$UI_MAJOR major update$C_RST"
      fi
      if [ "$key" = "mongo" ] && [ "$(version_major "$v")" -ge 8 ] && kernel_blocks_mongo8; then
        marker="$marker  ${C_DIM}with the kernel workaround$C_RST"
      fi
      printf '   %s  %s%s\n' "$C_BLD$i$C_RST" "$(ui_pad "$(version_core "$v")" 30)" "$marker"
    done <<< "$list"
    if [ -n "$note" ]; then
      printf '      %s\n' "$C_DIM$note$C_RST"
    fi
    printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}cancel$C_RST"
    echo
    ui_ask choice "Select a version [0]:" || choice="0"
    choice="${choice:-0}"
    if [ "$choice" = "0" ]; then
      info "Cancelled - nothing was changed."
      return 0
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      selected="$(sed -n "${choice}p" <<< "$list")"
    else
      v="$(list_tag "$versions" "$choice")"
      if [ -n "$v" ]; then
        selected="$v"
      elif [ -n "$(list_tag "${UPD_VERSIONS[$key]}" "$choice")" ]; then
        warn "$choice is outside the series $series Raynet runs with the Catalog - it is not offered."
      else
        warn "Invalid choice: $choice"
      fi
    fi
  done

  if [ "$selected" = "$tag" ]; then
    info "$(version_core "$selected") is already selected."
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
        last_series="$(grep -E "^$cur_major\." <<< "${UPD_VERSIONS[$key]}" | head -n 1 | cut -d. -f1-2)" || last_series=""
        case "$(cut -d. -f1-2 <<< "$resolved")" in
          "$cur_major.0"|"$last_series"|"") ;;
          *) warn "MongoDB $sel_major.0 can only be reached from $cur_major.0 or $last_series - upgrade to $(grep -F "$last_series." <<< "${UPD_VERSIONS[$key]}" | head -n 1) first." ;;
        esac
        ;;
      rabbitmq) warn "$(rabbitmq_flags_hint "$cur_major.x" "$sel_major.x")" ;;
      *) warn "$C_LABEL $cur_major.x -> $sel_major.x is a major upgrade - check its release notes." ;;
    esac
    if ! confirm "Select $(version_core "$selected")?" n; then
      info "Cancelled - nothing was changed."
      return 0
    fi
  elif [ "$key" = "rabbitmq" ] && [ -n "$resolved" ] && [ "$resolved" != "$selected" ]; then
    warn "$(rabbitmq_flags_hint "$(version_core "$resolved")" "$(version_core "$selected")")"
  fi
  if [ "$key" = "mongo" ] && [[ "$sel_major" =~ ^[0-9]+$ ]] && [ "$sel_major" -ge 8 ] && kernel_blocks_mongo8; then
    info "MongoDB $sel_major on this kernel ($(engine_kernel)) starts with GLIBC_TUNABLES=glibc.pthread.rseq=1 (SERVER-121912);"
    info "the generated files get it by themselves."
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
    if is_exact_tag "$tag"; then
      continue
    fi
    resolved="$(upd_current "$key" "$tag")"
    if [ -z "$resolved" ]; then
      warn "$C_LABEL: the version behind \"$tag\" is unknown - not pinned."
    elif ! grep -qxF -- "$resolved" <<< "${UPD_VERSIONS[$key]-}"; then
      warn "$C_LABEL: $resolved is not available for all images ($C_IMAGES) - not pinned."
    elif ! in_series "$key" "$resolved"; then
      warn "$C_LABEL: \"$tag\" points to $(version_core "$resolved"), outside the series ${SERIES_ALLOWED[$key]} Raynet runs - not pinned; pick a version of the series instead."
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

# Reads the settings of this script again (a job or a take-over of the installation's values in a
# subshell may have changed any of them); the engine is chosen once at the start.
reload_settings() {
  local name value
  if [ -z "$SCRIPT_PATH" ]; then
    return 0
  fi
  while IFS='|' read -r name value; do
    case "$name" in
      CONTAINER_ENGINE) ;;
      *) printf -v "$name" '%s' "$value" ;;
    esac
  done < <(settings_pairs "$SCRIPT_PATH")
  proxy_load
}

do_updates() {
  local choice before
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is needed to check for updates ($(pkg_hint curl))."
    return 1
  fi
  collect_updates || return $?
  while true; do
    show_updates
    echo
    ui_keys "1-6|pick a version" "p|pin floating tags" "r|check again" "s|apply (generate + start)" "d|offline bundle" "0|back"
    ui_ask choice "Select:" || choice="0"
    case "$choice" in
      1)
        before="$CATALOG_VERSION"
        run_action select_version no-apply
        reload_settings
        # a Catalog picked here is the user's choice: s applies it without asking again (upgrade_guard)
        if [ "$CATALOG_VERSION" != "$before" ]; then
          RVC_RAISE_OK="$CATALOG_VERSION"
        fi
        ui_pause_tty
        ;;
      [2-6]) run_action pick_component "${UPD_KEYS[$((choice - 2))]}"; reload_settings; ui_pause_tty ;;
      p|P) run_action pin_floating_tags; reload_settings; ui_pause_tty ;;
      r|R) collect_updates || return $? ;;
      s|S) run_action apply_updates; reload_settings; ui_pause_tty ;;
      d|D) run_action download_bundle; reload_settings; ui_pause_tty ;;
      0|"") return 0 ;;
      *) warn "Unknown option: $choice"; ui_pause_tty ;;
    esac
  done
}

show_updates_cli() {
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is needed to check for updates ($(pkg_hint curl))."
    return 1
  fi
  collect_updates || return $?
  show_updates
}

# set_settings_atomic [--keep-backup] NAME|VALUE... -> writes the settings into this script all at once
# (into a copy first, then over the script): either all of them change or none. A setting a job writes
# meanwhile is kept (the copy is made again). --keep-backup keeps the backup of the script (SETTINGS_BACKUP).
SETTINGS_BACKUP=""
set_settings_atomic() {
  local spec copy backup keep="no" sum tries=0
  SETTINGS_BACKUP=""
  if [ "${1:-}" = "--keep-backup" ]; then
    keep="yes"
    shift
  fi
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "${SCRIPT_PATH:-This installer} cannot be changed (not a writable file) - nothing was changed."
    return 1
  fi
  while true; do
    copy="$(mktemp)" || return 1
    sum="$(cksum < "$SCRIPT_PATH")"
    if ! cp -- "$SCRIPT_PATH" "$copy"; then
      rm -f -- "$copy"
      err "Nothing was changed."
      return 1
    fi
    for spec in "$@"; do
      if ! set_setting "${spec%%|*}" "${spec#*|}" "$copy"; then
        rm -f -- "$copy"
        err "Nothing was changed."
        return 1
      fi
    done
    if [ "$(cksum < "$SCRIPT_PATH")" = "$sum" ]; then
      break
    fi
    rm -f -- "$copy"
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      err "$SCRIPT_NAME keeps changing (a running job?) - nothing was changed, try again later."
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
  rm -f -- "$copy"
  if [ "$keep" = "yes" ]; then
    SETTINGS_BACKUP="$backup"
  else
    rm -f -- "$backup"
  fi
  for spec in "$@"; do
    printf -v "${spec%%|*}" '%s' "${spec#*|}"
  done
}

VERSION_PICKED=""

# One row of the versions screen: another version for KEY (the Catalog: any of its versions; the
# others: only inside their series). Sets VERSION_PICKED; returns 1 for back, 2 at the end of input.
# choose_versions_row KEY CURRENT SELECTED INSTALLED(yes|no)
choose_versions_row() {
  local key="$1" resolved="$2" selected="$3" installed="$4" versions list rec count i v marker choice label kind series="" note=""
  VERSION_PICKED=""
  if [ "$key" = "catalog" ]; then
    label="Catalog"
    kind="catalog"
    versions="$HUB_VERSIONS"
    list="$(sed -n '1,4p' <<< "$versions")"
    rec="$(recommended_catalog)"
  else
    component_info "$key"
    label="$C_LABEL"
    kind="$C_KIND"
    series="${SERIES_ALLOWED[$key]-}"
    versions="$(series_versions "$key")"
    list="$(pick_list "$versions" "$resolved")"
    rec="${versions%%$'\n'*}"
    note="$(newer_series_note "$key")"
  fi
  if [ -z "$versions" ]; then
    warn "No versions known for $label (registry not reachable)."
    return 1
  fi
  count="$(count_lines "$list")"
  while true; do
    echo
    if [ -n "$series" ]; then
      printf '  %s   %s\n' "$C_BLD$label$C_RST" "${C_DIM}series $series: the versions Raynet runs with the Catalog$C_RST"
    else
      printf '  %s\n' "$C_BLD$label$C_RST"
    fi
    i=0
    while IFS= read -r v; do
      i=$((i + 1))
      marker=""
      if [ "$key" = "catalog" ] && [ -n "$HUB_STABLE" ] && [ "$v" = "$HUB_STABLE" ]; then
        marker="  $C_YLW$UI_STAR stable$C_RST"
      fi
      if [ "$v" = "$rec" ]; then
        marker="$marker  $C_GRN$UI_OK recommended$C_RST"
      fi
      if [ "$v" = "$selected" ]; then
        marker="$marker  $C_CYN$UI_DOT selected$C_RST"
      fi
      if [ "$installed" = "yes" ] && [ "$v" = "$resolved" ]; then
        marker="$marker  ${C_DIM}installed$C_RST"
      fi
      printf '   %s  %s%s\n' "$C_BLD$i$C_RST" "$(ui_pad "$(version_core "$v")" 30)" "$marker"
    done <<< "$list"
    if [ -n "$note" ]; then
      printf '      %s\n' "$C_DIM$note$C_RST"
    fi
    printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}back$C_RST"
    echo
    ui_ask choice "Select a version, or type one [0]:" || return 2
    choice="${choice:-0}"
    if [ "$choice" = "0" ]; then
      return 1
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
      VERSION_PICKED="$(sed -n "${choice}p" <<< "$list")"
    else
      VERSION_PICKED="$(list_tag "$versions" "$choice")"
      if [ -z "$VERSION_PICKED" ]; then
        if [ "$key" != "catalog" ] && [ -n "$(list_tag "${UPD_VERSIONS[$key]-}" "$choice")" ]; then
          warn "$choice is outside the series $series Raynet runs with the Catalog - it is not offered."
        else
          warn "Invalid choice: $choice"
        fi
        continue
      fi
    fi
    if [ "$key" = "catalog" ] && [ "$installed" = "yes" ] && [ "$VERSION_PICKED" != "$selected" ] \
      && { [ -z "$resolved" ] || kind_newer catalog "$VERSION_PICKED" "$resolved"; }; then
      warn "U or option 21 upgrades the Catalog of an installation (MongoDB backup, health check, rollback) - not this screen."
      continue
    fi
    if [ "$installed" = "yes" ] && [ -n "$resolved" ] && kind_newer "$kind" "$resolved" "$VERSION_PICKED"; then
      warn "$(version_core "$VERSION_PICKED") is OLDER than the installed $(version_core "$resolved") - downgrades can fail with existing data."
    fi
    return 0
  done
}

# The versions step of the install wizard: one row per component with its current value and the
# recommended version (the Catalog: the newest; the others: the newest of their allowed series).
# Enter takes the table, a row number picks another version of that row; then the exact tags are
# written all at once. In a folder that is installed already, the Catalog and versions outside the
# series are kept (U and option 8 change them). Returns 1 when cancelled or at the end of input:
# nothing was changed then.
choose_versions() {
  local -a keys=(catalog mongo opensearch rabbitmq minio) cur=() res=() sel=() marks=() recs=() specs=()
  local key i choice first tag resolved rec installed="no" hub_down="no" reg_down="" note spec label curtext seltext mark rc row
  local w_cur=0 w_sel=30
  if [ "$INSTALL_NGINX_PROXY_MANAGER" = "true" ]; then
    keys+=(npm)
  fi
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "The installer must be a writable file (it keeps the versions)."
    return 1
  fi
  # the files that option 99 or R left hold no installation: the versions of a new one
  if ! nothing_installed "$(install_kind)"; then
    installed="yes"
  fi
  if ! collect_updates; then
    echo
    info "Cancelled - nothing was changed."
    return 1
  fi
  for i in "${!keys[@]}"; do
    key="${keys[i]}"
    if [ "$key" = "catalog" ]; then
      cur[i]="$CATALOG_VERSION"
      res[i]=""
      tag="$(installed_catalog)"
      if [ "$installed" = "yes" ] && is_version "$tag"; then
        res[i]="$tag"
      elif is_version "$CATALOG_VERSION"; then
        res[i]="$CATALOG_VERSION"
      fi
      rec="$(recommended_catalog)"
      recs[i]="$rec"
      if [ -z "$rec" ]; then
        hub_down="yes"
        sel[i]="$CATALOG_VERSION"
        marks[i]="kept"
      elif [ "$installed" = "yes" ] && [ "$rec" != "$CATALOG_VERSION" ]; then
        sel[i]="$CATALOG_VERSION"
        marks[i]="kept"
        info "The Catalog stays $CATALOG_VERSION in this installation - U upgrades it with backup and rollback."
      else
        sel[i]="$rec"
        marks[i]="recommended"
      fi
      continue
    fi
    component_info "$key"
    first="${C_SETTINGS%% *}"
    tag="${!first}"
    resolved="$(upd_current "$key" "$tag")"
    cur[i]="$tag"
    res[i]="$resolved"
    rec="$(recommended_version "$key")"
    recs[i]="$rec"
    if [ -z "$rec" ]; then
      # without the registry: an exact version inside the series stays, other tags become the moving
      # tag of the series (in an installation a tag outside the series stays)
      reg_down="$reg_down, $(series_name "$key")"
      sel[i]="$tag"
      marks[i]="kept"
      if [ -n "${SERIES_TAG[$key]-}" ] && [ "$tag" != "${SERIES_TAG[$key]}" ]; then
        if { in_series "$key" "$tag" && ! [[ "$tag" =~ $(kind_regex "$C_KIND") ]]; } || { ! in_series "$key" "$tag" && [ "$installed" = "no" ]; }; then
          sel[i]="${SERIES_TAG[$key]}"
          marks[i]="series tag"
        fi
      fi
    elif [ "$installed" = "yes" ] && ! in_series "$key" "${resolved:-$tag}"; then
      sel[i]="$tag"
      marks[i]="kept"
      if [ -n "$resolved" ] && kind_newer "$C_KIND" "$resolved" "$rec"; then
        warn "$C_LABEL $(version_core "$resolved") is outside the series ${SERIES_ALLOWED[$key]} Raynet runs with the Catalog - kept: it is never downgraded automatically."
      else
        warn "$C_LABEL $(version_core "${resolved:-$tag}") is outside the series ${SERIES_ALLOWED[$key]} Raynet runs with the Catalog - kept here; option 8 changes it."
      fi
    else
      sel[i]="$rec"
      marks[i]="recommended"
      if [ "$installed" = "yes" ] && [ "$key" = "rabbitmq" ] && [ -n "$resolved" ] && [ "$resolved" != "$rec" ]; then
        warn "$(rabbitmq_flags_hint "$(version_core "$resolved")" "$(version_core "$rec")")"
      fi
    fi
  done
  if [ "$hub_down" = "yes" ]; then
    warn "Docker Hub could not be read (no internet access, or a proxy is needed - $(hint 26 network-check) checks it): the Catalog stays $CATALOG_VERSION."
  fi
  if [ -n "$reg_down" ]; then
    reg_down="${reg_down#, }"
    if [[ "$reg_down" == *", "* ]]; then
      reg_down="${reg_down%, *} and ${reg_down##*, }"
    fi
    warn "The versions of $reg_down could not be read:"
    warn "    an exact version inside the series stays, other tags become the moving tag of the series."
  fi
  if [ "$(ui_width)" -ge 112 ]; then
    w_cur=35
    w_sel=35
  elif [ "$(ui_width)" -ge 100 ]; then
    w_cur=29
    w_sel=29
  fi
  note="$(newer_series_note "${keys[@]:1}")"

  while true; do
    echo
    ui_box "$(ui_width)" "Versions" \
      "Recommended: the newest Catalog, and for the other components the newest" \
      "version of the series Raynet runs with the Catalog."
    if [ "$w_cur" -gt 0 ]; then
      printf '  %s\n' "$C_DIM$(ui_pad "#" 3)$(ui_pad "COMPONENT" 24)$(ui_pad "CURRENT" "$w_cur")SELECTED$C_RST"
    else
      printf '  %s\n' "$C_DIM$(ui_pad "#" 3)$(ui_pad "COMPONENT" 24)SELECTED$C_RST"
    fi
    for i in "${!keys[@]}"; do
      key="${keys[i]}"
      if [ "$key" = "catalog" ]; then
        label="Catalog + 4 workers"
        curtext="${cur[i]}"
        seltext="$(ui_version "${sel[i]}")"
      else
        component_info "$key"
        label="$C_LABEL"
        curtext="$(ui_current "$(version_core "${cur[i]}")" "$(version_core "${res[i]}")")"
        seltext="$(version_core "${sel[i]}")"
      fi
      case "${marks[i]}" in
        recommended) mark="$C_GRN$UI_OK recommended$C_RST" ;;
        kept) mark="${C_DIM}kept$C_RST" ;;
        "series tag") mark="$C_YLW${UI_DOT} series tag$C_RST" ;;
        *) mark="$C_CYN$UI_DOT your choice$C_RST" ;;
      esac
      row="$(ui_pad "$C_BLD$((i + 1))$C_RST" 3)$(ui_pad "$label" 24)"
      if [ "$w_cur" -gt 0 ]; then
        row="$row$(ui_pad "$curtext" $((w_cur - 1))) "
      fi
      printf '  %s\n' "$row$(ui_pad "$seltext" $((w_sel - 1))) $mark"
      # narrow terminals: the current value of an installation on a line of its own
      if [ "$w_cur" -eq 0 ] && [ "$installed" = "yes" ] && [ "${cur[i]}" != "${sel[i]}" ]; then
        printf '  %s\n' "$(ui_pad "" 27)${C_DIM}now ${curtext//$C_RST/$C_RST$C_DIM}$C_RST"
      fi
    done
    if [ -n "$note" ] && [ "${#note}" -gt $(($(ui_width) - 4)) ]; then
      printf '  %s\n' "$C_DIM${note%% - *}$C_RST" "$C_DIM- ${note#* - }$C_RST"
    elif [ -n "$note" ]; then
      printf '  %s\n' "$C_DIM$note$C_RST"
    fi
    echo
    ui_keys "Enter|use the selected versions" "1-${#keys[@]}|another version for that row" "0|cancel"
    if ! ui_ask choice "Enter, or a row:"; then
      echo
      info "No answer - nothing was changed."
      return 1
    fi
    case "$choice" in
      "") break ;;
      0)
        info "Cancelled - nothing was changed."
        return 1
        ;;
    esac
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#keys[@]}" ]; then
      warn "Invalid choice: $choice"
      continue
    fi
    i=$((choice - 1))
    rc=0
    choose_versions_row "${keys[i]}" "${res[i]}" "${sel[i]}" "$installed" || rc=$?
    case "$rc" in
      0)
        sel[i]="$VERSION_PICKED"
        if [ "$VERSION_PICKED" = "${recs[i]}" ]; then
          marks[i]="recommended"
        elif [ "$VERSION_PICKED" = "${cur[i]}" ]; then
          marks[i]="kept"
        else
          marks[i]="chosen"
        fi
        ;;
      2)
        echo
        info "No answer - nothing was changed."
        return 1
        ;;
    esac
  done

  for i in "${!keys[@]}"; do
    key="${keys[i]}"
    if [ "$key" = "catalog" ]; then
      if [ "${sel[i]}" != "$CATALOG_VERSION" ]; then
        specs+=("CATALOG_VERSION|${sel[i]}")
      fi
      continue
    fi
    component_info "$key"
    for first in $C_SETTINGS; do
      if [ "${!first}" != "${sel[i]}" ]; then
        specs+=("$first|${sel[i]}")
      fi
    done
  done
  if [ "${#specs[@]}" -eq 0 ]; then
    ok "The versions stay as they are."
    return 0
  fi
  if ! set_settings_atomic "${specs[@]}"; then
    return 1
  fi
  for spec in "${specs[@]}"; do
    ok "${spec%%|*} = \"${spec#*|}\""
  done
}

# Offline bundle

container_engine() {
  if engine_cli && "$ENGINE" info >/dev/null 2>&1; then
    printf '%s' "$ENGINE"
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

# save_image ENGINE REF FILE EXPECTED_BYTES [LABEL] - Podman writes a docker-archive; Docker saves the
# amd64 image only, where it can choose (the containerd image store keeps more than one platform)
save_image() {
  local engine="$1" ref="$2" out="$3" total="$4" label="${5:-Saving}" pid cur help
  local -a cmd=(podman save --format docker-archive)
  if [ "$engine" = "docker" ]; then
    cmd=(docker save)
    help="$(docker save --help 2>&1)" || help=""
    if [[ "$help" == *--platform* ]]; then
      cmd+=(--platform linux/amd64)
    fi
  fi
  "${cmd[@]}" -o "$out" "$ref" &
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

# the engine of the installer next to this script (CONTAINER_ENGINE), else the one installed here
is_podman_shim() {
  case "$(docker --version 2>/dev/null)" in
    *[Pp]odman*) return 0 ;;
  esac
  return 1
}
engine="$(sed -n 's/^CONTAINER_ENGINE="\([a-z]*\)"$/\1/p' ./@INSTALLER@ 2>/dev/null)" || engine=""
engine="${engine%%$'\n'*}"
case "$engine" in
  podman|docker) ;;
  colima) engine="docker" ;;
  *)
    if command -v podman >/dev/null 2>&1; then
      engine="podman"
    elif command -v docker >/dev/null 2>&1 && ! is_podman_shim; then
      engine="docker"
    else
      echo "ERROR Neither Podman nor Docker is installed on this machine - the installer sets one up (install-engine)." >&2
      exit 1
    fi
    ;;
esac
if [ "$engine" = "podman" ] && ! command -v podman >/dev/null 2>&1; then
  echo "ERROR Podman is not installed on this machine - the installer sets it up (install-podman)." >&2
  exit 1
fi
if [ "$engine" = "docker" ] && { ! command -v docker >/dev/null 2>&1 || is_podman_shim; }; then
  echo "ERROR Docker is not installed on this machine - the installer sets it up (install-docker)." >&2
  exit 1
fi
if [ "$engine" = "podman" ] && [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" -ne 0 ]; then
  echo "ERROR Run it as root (sudo ./import-images.sh): the Catalog runs in the Podman of root, which does not see images loaded by $(id -un)." >&2
  exit 1
fi
echo "==> Container engine: $engine"

# Docker Hub names as the engine stores them (podman tag with a short name would create localhost/...)
qualify() {
  local first="${1%%/*}"
  if [[ "$1" == */* ]] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = "localhost" ]; }; then
    printf '%s' "$1"
  elif [[ "$1" == */* ]]; then
    printf 'docker.io/%s' "$1"
  else
    printf 'docker.io/library/%s' "$1"
  fi
}

if command -v sha256sum >/dev/null 2>&1; then
  echo "==> Verifying the image files (SHA256SUMS)"
  if ! awk '$2 ~ /^[*]?(images|compose)(\/|\.txt$)/' SHA256SUMS | sha256sum -c --quiet -; then
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
  qref="$(qualify "$ref")"
  if ! "$engine" load -i "$file" >/dev/null; then
    echo "ERROR Loading $file failed" >&2
    failed=$((failed + 1))
    continue
  fi
  if ! "$engine" image inspect "$qref" >/dev/null 2>&1; then
    "$engine" tag "$id" "$qref" >/dev/null 2>&1 || true
  fi
  if "$engine" image inspect "$qref" >/dev/null 2>&1; then
    echo " OK $ref"
    loaded=$((loaded + 1))
  else
    echo "ERROR $ref could not be tagged" >&2
    failed=$((failed + 1))
  fi
done < images.txt

echo
echo "$loaded image(s) loaded, $failed failed."
# Podman: the API socket "podman compose" needs, and the restart of the containers after a reboot;
# Docker: its daemon (it restarts the containers itself)
if [ "$(uname -s)" = "Linux" ] && command -v systemctl >/dev/null 2>&1 && [ -d "${RN1_SYSTEMD_DIR:-/run/systemd/system}" ]; then
  if [ "$engine" = "podman" ]; then
    systemctl enable --now podman.socket >/dev/null 2>&1 || echo "WARNING podman.socket could not be started: systemctl enable --now podman.socket" >&2
    systemctl enable podman-restart.service >/dev/null 2>&1 || true
  elif [ "$(id -u)" -eq 0 ]; then
    systemctl enable --now docker >/dev/null 2>&1 || echo "WARNING Docker could not be started: systemctl enable --now docker" >&2
  fi
fi
# compose_works FILE -> true when the Docker Compose FILE works with the engine here
compose_works() {
  if [ "$engine" = "docker" ]; then
    "$1" ls -q >/dev/null 2>&1
  else
    PODMAN_COMPOSE_PROVIDER="$1" PODMAN_COMPOSE_WARNING_LOGS=false podman compose ls -q >/dev/null 2>&1
  fi
}
# Docker Compose from the bundle, when this server has none or another one: the engine behind "podman
# compose", or the Compose plugin of a Docker that has none - the installed one stays when the bundled
# one does not work with this engine
if [ -f compose/docker-compose-linux-x86_64 ] && [ "$(id -u)" -eq 0 ]; then
  target="${RN1_COMPOSE_TARGET:-/usr/local/lib/docker/cli-plugins/docker-compose}"
  wanted="yes"
  if [ "$engine" = "docker" ] && [ ! -f "$target" ]; then
    # Docker's own Compose 2 or newer (v2.40.3, or 2.40.3+ds1-... in the packages of the distributions)
    v="$(docker compose version 2>/dev/null | head -n 1)" || v=""
    v="${v#Docker Compose version }"
    v="${v#v}"
    if [[ "${v%%.*}" =~ ^[0-9]+$ ]] && [ "${v%%.*}" -ge 2 ]; then
      wanted="no"
    fi
  fi
  if [ "$wanted" = "yes" ] && { [ ! -x "$target" ] || ! cmp -s compose/docker-compose-linux-x86_64 "$target"; }; then
    if [ -x "$target" ] && ! compose_works "$PWD/compose/docker-compose-linux-x86_64"; then
      echo "WARNING The Docker Compose of the bundle does not work with this $(if [ "$engine" = "podman" ]; then echo Podman; else echo Docker; fi) - the installed one stays." >&2
    else
      mkdir -p "${target%/*}"
      if [ -x "$target" ]; then
        cp -p "$target" "$target.previous"
      fi
      install -m 755 compose/docker-compose-linux-x86_64 "$target"
      echo " OK Docker Compose installed: $target"
    fi
  fi
fi
if [ "$failed" -gt 0 ]; then
  exit 1
fi
echo "Next: ./@INSTALLER@  (menu option 7: generate + validate + start)"
IMPORT_EOF
  sed -i "s/@INSTALLER@/$installer/" "$file"
  chmod +x "$file"
}

# bundle_compose DIR -> DIR/compose/docker-compose-linux-x86_64: the newest Docker Compose for the
# offline server (the engine behind "podman compose", or Docker's Compose plugin); import-images.sh
# installs it there
bundle_compose() {
  local dir="$1" tag url exp got
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl is missing - the bundle has no Docker Compose ($(pkg_hint curl))."
    return 1
  fi
  tag="$(compose_latest_tag)"
  if [ -z "$tag" ]; then
    warn "GitHub cannot be reached - the bundle has no Docker Compose (the offline server needs one)."
    return 1
  fi
  url="https://github.com/docker/compose/releases/download/$tag/docker-compose-linux-x86_64"
  mkdir -p -- "$dir/compose"
  job_step "Downloading Docker Compose ${tag#v}"
  info "Docker Compose ${tag#v} for the offline server"
  if ! curl -fsSL --proto '=https' --max-time 600 -o "$dir/compose/docker-compose-linux-x86_64" "$url"; then
    rm -rf -- "$dir/compose"
    warn "Docker Compose could not be downloaded - the bundle has none."
    return 1
  fi
  exp="$(curl -fsSL --proto '=https' --max-time 30 "$url.sha256" 2>/dev/null)" || exp=""
  got="$(sha256sum -- "$dir/compose/docker-compose-linux-x86_64")"
  if [ -z "$exp" ] || [ "${exp%% *}" != "${got%% *}" ]; then
    rm -rf -- "$dir/compose"
    warn "The checksum of Docker Compose does not match - the bundle has none."
    return 1
  fi
  chmod 755 "$dir/compose/docker-compose-linux-x86_64"
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
  local host scp_host port user target rt auth key pw kh kf known="$HOME/.ssh/known_hosts" tool
  for tool in ssh scp ssh-keygen ssh-keyscan; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      err "Copying needs the SSH client, $tool is missing: $(pkg_hint "$(ssh_package)")"
      return 1
    fi
  done
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
      local import="./import-images.sh"
      if [ "$SCP_USER" != "root" ]; then
        import="sudo ./import-images.sh"
      fi
      if [ -d "$1" ]; then
        echo "  On $SCP_HOST: cd $SCP_TARGET/$name && $import"
      else
        echo "  On $SCP_HOST: cd $SCP_TARGET && tar -xzf $name && cd ${name%.tar.gz} && $import"
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
    err "Downloading needs $ENGINE_NAME on this machine ('./$SCRIPT_NAME $(engine_install_cmd)' sets it up)."
    return 1
  fi
  while IFS= read -r ref; do
    images+=("$ref")
  done < <(stack_images)
  for ref in ${images[@]+"${images[@]}"}; do
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
          for tok in ${toks[@]+"${toks[@]}"}; do
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
  local engine="$1" dir="$2" archive_wanted="$3" scp_wanted="$4" base name ref pref id size free_kb file n=0 count installer archive="" secret old
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
    old=""
    if [ "$OS_KIND" = "Darwin" ]; then
      old="$("$engine" image inspect --format '{{.ID}}' "$pref" 2>/dev/null)" || old=""
    fi
    job_step "[$n/$count] Pulling $ref"
    if [ -n "$JOB_DIR" ]; then
      "$engine" pull -q --platform linux/amd64 "$pref"
    else
      "$engine" pull --platform linux/amd64 "$pref"
    fi
    id="$("$engine" image inspect --format '{{.ID}}' "$pref")"
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
    # the amd64 pull moved the tag of an image the local stack uses: it goes back to that image
    if [ -n "$old" ] && [ "${old#sha256:}" != "$id" ]; then
      "$engine" tag "$old" "$pref" >/dev/null 2>&1 || true
    fi
  done

  installer=""
  if [ -n "$SCRIPT_PATH" ]; then
    installer="$(basename -- "$SCRIPT_PATH")"
    cp -- "$SCRIPT_PATH" "$dir/$installer"
    chmod u+w "$dir/$installer"
    set_setting CHECK_FOR_UPDATES false "$dir/$installer"
    # the engine of this machine is not the one of the target: there the installer finds it
    set_setting CONTAINER_ENGINE "" "$dir/$installer"
    # the proxy, its internal names, PAC file and company certificate belong to the network of this machine
    set_setting INTERNET_PROXY "" "$dir/$installer"
    set_setting INTERNET_NO_PROXY "" "$dir/$installer"
    set_setting INTERNET_PROXY_PAC "" "$dir/$installer"
    set_setting INTERNET_PROXY_CA_FILE "" "$dir/$installer"
    chmod +x "$dir/$installer"
  fi
  write_import_script "$dir/import-images.sh" "${installer:-rn1-technology-catalog-installer.sh}"
  bundle_compose "$dir" || true
  job_step "Writing SHA256SUMS"
  (cd -- "$dir" && sha256sum -- images/*.tar images.txt import-images.sh ${installer:+"$installer"} $(ls compose/* 2>/dev/null) > SHA256SUMS)
  BUNDLE_PARTIAL=""
  if [ -z "$JOB_DIR" ]; then
    trap - EXIT
  fi
  echo
  ok "Bundle ready: $dir ($(du -sh -- "$dir" | cut -f1))"
  echo "  images/ ($count image(s)), images.txt, SHA256SUMS, import-images.sh${installer:+, $installer}$([ -d "$dir/compose" ] && printf ', compose/ (Docker Compose)')"
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
    err "Reading the snapshot list needs jq or python3 ($(pkg_hint jq))."
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
    err "curl is needed ($(pkg_hint curl))."
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
          if confirm "Import the $count files into the local catalog now, one after the other?" "${SNAP_IMPORT_DEFAULT:-n}"; then
            import_chain "$chainfile"
          else
            echo "  Import them later with option 19 (it offers the whole chain)."
          fi
        else
          IFS=$'\t' read -r type date _ <<< "$plan"
          if confirm "Import $dir/$date-$type.tar.gz into the local catalog now?" "${SNAP_IMPORT_DEFAULT:-n}"; then
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
  for line in ${lines[@]+"${lines[@]}"}; do
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
LOCAL_REFRESH=""
LOCAL_AUTH_AT=0
LOCAL_AUTH_TTL=1800
LOCAL_STATE=""
LOCAL_ADMIN="no"
LOCAL_CODE=""
LOCAL_USER=""

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

# json_text NAME FILE -> the whole text of NAME (json_field ends at a comma), escaped quotes undone
json_text() {
  local s re
  re='"'"$1"'" *: *"(([^"\\]|\\.)*)"'
  s="$(tr -d '\r\n' < "$2")"
  if [[ "$s" =~ $re ]]; then
    s="${BASH_REMATCH[1]//\\\"/\"}"
    printf '%s' "${s//\\\\/\\}"
  fi
}

# Checks LOCAL_AUTH: LOCAL_STATE valid / invalid / unlicensed / unreachable / error, LOCAL_ADMIN yes / no.
# A new catalog has no synchronization settings yet and answers 204 (no content) - for an administrator
# too. Without a valid license the Catalog answers 520 to everything that needs one.
local_auth_check() {
  local out code
  out="$(mktemp)"
  code="$(local_call GET /v1/databaseconfiguration/synchronization "$out")"
  rm -f -- "$out"
  LOCAL_ADMIN="no"
  LOCAL_CODE="$code"
  case "$code" in
    200|204) LOCAL_STATE="valid"; LOCAL_ADMIN="yes" ;;
    403) LOCAL_STATE="valid" ;;
    401) LOCAL_STATE="invalid" ;;
    520) LOCAL_STATE="unlicensed" ;;
    000) LOCAL_STATE="unreachable" ;;
    *) LOCAL_STATE="error" ;;
  esac
}

# Where the Catalog is activated: option 25 in the menu and in a job (its log is read in the menu), else
# the command
license_how() {
  if [ "$INTERACTIVE" != "true" ] && [ -z "$JOB_DIR" ]; then
    printf "'%s license'" "$0"
  else
    printf 'option 25'
  fi
}

# The answer to HTTP 520 of the local catalog
report_unlicensed() {
  err "The Catalog is not activated yet (no valid license) - $(license_how) activates it."
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
    unlicensed) report_unlicensed ;;
    unreachable) err "The local catalog is not reachable at $(local_url) - is the stack running (option 6)?" ;;
    *) err "Unexpected answer from the local catalog (HTTP ${LOCAL_CODE:-?})." ;;
  esac
}

# local_login [DEFAULT-USER] -> LOCAL_AUTH with the token of a login and LOCAL_REFRESH with its refresh
# token (with a default user, 0 cancels). 1: failed, 2: cancelled
local_login() {
  local def="${1:-}" user="" pw body resp code token refresh ttl
  if read -r -p "  Local catalog user name${def:+ [$def]}: " user; then
    user="${user:-$def}"
  else
    user=""
  fi
  if [ -z "$user" ] || { [ -n "$def" ] && [ "$user" = "0" ]; }; then
    info "Cancelled."
    return 2
  fi
  LOCAL_USER="$user"
  read -r -s -p "  Password (input hidden): " pw || pw=""
  echo
  body="$(mktemp)"
  resp="$(mktemp)"
  # Ctrl+C removes the file with the password too
  trap "rm -f -- $(printf '%q ' "$body" "$resp"); exit 130" INT TERM
  (umask 077 && printf '{"username":"%s","password":"%s","fingerprint":"%s","rememberMe":false}' \
    "$(json_escape "$user")" "$(json_escape "$pw")" "$(new_uuid)" > "$body")
  pw=""
  LOCAL_AUTH=""
  LOCAL_REFRESH=""
  code="$(local_call POST /v1/authentication/request "$resp" -H 'Content-Type: application/json' --data-binary "@$body")"
  rm -f -- "$body"
  token="$(json_field access_token "$resp")"
  refresh="$(json_field refresh_token "$resp")"
  ttl="$(json_field expires_in "$resp")"
  rm -f -- "$resp"
  trap - INT TERM
  case "$code" in
    200)
      if [ -z "$token" ]; then
        err "The login answer contains no token."
        return 1
      fi
      LOCAL_AUTH="Authorization: Bearer $token"
      LOCAL_REFRESH="$refresh"
      LOCAL_AUTH_AT="$SECONDS"
      if [[ "$ttl" =~ ^[1-9][0-9]*$ ]]; then
        LOCAL_AUTH_TTL="$ttl"
      fi
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
  LOCAL_REFRESH=""
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
  echo "  An API key does not expire - the better choice for long imports."
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
      if [ "$LOCAL_STATE" = "unlicensed" ]; then
        report_local_state
        return 1
      fi
      ;;
    *)
      info "Cancelled."
      return 1
      ;;
  esac
}

# local_refresh -> renews a login with its refresh token: a new access token (LOCAL_AUTH) and its lifetime;
# the Catalog gives a new refresh token only in the last 30 minutes of its 12 hours (see local_auth_renew).
# The tokens stay in memory: curl gets the refresh token through its stdin config and prints the answer.
local_refresh() {
  local body resp code re token="" refresh="" ttl=""
  if [ -z "$LOCAL_REFRESH" ] || [[ "$LOCAL_AUTH" != "Authorization: Bearer "* ]]; then
    return 1
  fi
  body="{\"refreshToken\":\"$(json_escape "$LOCAL_REFRESH")\"}"
  body="${body//\\/\\\\}"
  resp="$(printf 'data-binary = "%s"\n' "${body//\"/\\\"}" | curl -sS -K - -X POST -H 'Accept: application/json' \
    -H 'Content-Type: application/json' --connect-timeout 5 --max-time 60 -w '%{http_code}' "$(local_url)/v1/authentication/refresh" 2>/dev/null)" || true
  code="${resp: -3}"
  re='"access_token" *: *"([^"]+)"'
  if [[ "$resp" =~ $re ]]; then
    token="${BASH_REMATCH[1]}"
  fi
  re='"refresh_token" *: *"([^"]+)"'
  if [[ "$resp" =~ $re ]]; then
    refresh="${BASH_REMATCH[1]}"
  fi
  re='"expires_in" *: *([1-9][0-9]*)'
  if [[ "$resp" =~ $re ]]; then
    ttl="${BASH_REMATCH[1]}"
  fi
  if [ "$code" != "200" ] || [ -z "$token" ]; then
    return 1
  fi
  LOCAL_AUTH="Authorization: Bearer $token"
  LOCAL_REFRESH="${refresh:-$LOCAL_REFRESH}"
  LOCAL_AUTH_AT="$SECONDS"
  LOCAL_AUTH_TTL="${ttl:-$LOCAL_AUTH_TTL}"
}

# local_auth_renew -> renews a login after five sixths of the lifetime of its access token (30 minutes): a
# renewal in each such span reaches the last 30 minutes of the refresh token too, where the Catalog gives a
# new one, so the login lasts as long as the follow-up. A failed renewal is tried again a minute later.
local_auth_renew() {
  local due=$((LOCAL_AUTH_TTL * 5 / 6))
  if [ -n "$LOCAL_REFRESH" ] && [ $((SECONDS - LOCAL_AUTH_AT)) -ge "$due" ]; then
    local_refresh || LOCAL_AUTH_AT=$((SECONDS - due + 60))
  fi
}

# local_call_kept METHOD PATH OUTFILE [curl args...] -> LOCAL_CODE of local_call; a login the Catalog no
# longer accepts (HTTP 401) is renewed once and the call repeated
local_call_kept() {
  LOCAL_CODE="$(local_call "$@")"
  if [ "$LOCAL_CODE" = "401" ] && local_refresh; then
    LOCAL_CODE="$(local_call "$@")"
  fi
}

# The credentials a job gets through its secret: LOCAL_AUTH and, for a login, its refresh token and the
# lifetime of its access token
local_auth_secret() {
  printf '%s' "$LOCAL_AUTH"
  if [[ "$LOCAL_AUTH" == "Authorization: Bearer "* ]] && [ -n "$LOCAL_REFRESH" ]; then
    printf '\n%s\n%s' "$LOCAL_REFRESH" "$LOCAL_AUTH_TTL"
  fi
}

# Worker: LOCAL_AUTH, LOCAL_REFRESH and LOCAL_AUTH_TTL from the job secret (outside a job they stay as they are)
local_auth_take() {
  local secret ttl
  secret="$(job_secret_take)"
  if [ -n "$secret" ]; then
    LOCAL_AUTH="${secret%%$'\n'*}"
    LOCAL_REFRESH=""
    LOCAL_AUTH_AT="$SECONDS"
    if [[ "$secret" == *$'\n'* ]]; then
      secret="${secret#*$'\n'}"
      LOCAL_REFRESH="${secret%%$'\n'*}"
      ttl="${secret#*$'\n'}"
      if [[ "$ttl" =~ ^[1-9][0-9]*$ ]]; then
        LOCAL_AUTH_TTL="$ttl"
      fi
    fi
  fi
}

FOLLOW_CID=""
FOLLOW_SINCE=""
FOLLOW_SEEN=""
FOLLOW_KEEP=0
FOLLOW_TIME=""
FOLLOW_STEP=""
FOLLOW_FAILED=""
FOLLOW_CANCEL=""
FOLLOW_STARTED=""

# Before a line of a follow-up: a terminal outside a job has the progress in its last line
follow_clear() {
  if [ -z "$JOB_DIR" ] && [ -t 1 ]; then
    printf '\r\033[K'
  fi
}

# Container of catalog-web (empty where the engine cannot be asked)
catalog_web_id() {
  if engine_cli && detect_compose 2>/dev/null; then
    compose ps -q catalog-web 2>/dev/null | head -n 1 || true
  fi
}

# follow_mark -> where the log of catalog-web stands before an import or a synchronization is started: the
# follow-up shows what comes after it (FOLLOW_CID empty where the engine cannot be asked)
follow_mark() {
  FOLLOW_CID="$(catalog_web_id)"
  FOLLOW_SINCE=""
  FOLLOW_SEEN=""
  FOLLOW_KEEP=0
  FOLLOW_TIME=""
  if [ -n "$FOLLOW_CID" ]; then
    catalog_log_steps "" mark || true
  fi
}

# catalog_log_steps OPID [mark] -> prints the new lines of the log of catalog-web about a running import or
# synchronization as "HH:MM:SS message": the steps of its snapshot services and of its operation, errors, a
# full disk, and the text of an exception with the line it belongs to (never its stack); true when there
# was one (FOLLOW_STEP: the last). Where the next look starts comes from the time stamps of the engine
# (FOLLOW_SINCE), not from the clock of this host, which may differ (the virtual machine on macOS);
# FOLLOW_SEEN keeps the lines of that last second from being shown twice; FOLLOW_KEEP and FOLLOW_TIME carry
# the line a following line without a time belongs to. It notes what the log says about the operation:
# FOLLOW_STARTED, FOLLOW_FAILED (the reason) and FOLLOW_CANCEL (26.x cancels a synchronization while
# another one runs; that line names no operation). With "mark" it only notes where the log stands; a log
# that cannot be read then is not read during this follow-up.
catalog_log_steps() {
  local opid="$1" mark="${2:-}" out line new=1 since="" seen="" tail=5000
  local -a args=(logs --timestamps)
  if [ -n "$FOLLOW_SINCE" ]; then
    args+=(--since "$FOLLOW_SINCE")
  fi
  if [ -n "$mark" ]; then
    tail=100
  fi
  # --tail spares the engine reading a long log from its start
  if ! out="$("$ENGINE" "${args[@]}" --tail "$tail" "$FOLLOW_CID" 2>&1 \
    | FL_OPID="$opid" FL_MARK="$mark" FL_SEEN="$FOLLOW_SEEN" FL_KEEP="$FOLLOW_KEEP" FL_TIME="$FOLLOW_TIME" FL_NOW="$(date +%H:%M:%S)" awk '
      BEGIN {
        opid = ENVIRON["FL_OPID"]; mark = ENVIRON["FL_MARK"]; keep = ENVIRON["FL_KEEP"] + 0; tm = ENVIRON["FL_TIME"]
        n = split(ENVIRON["FL_SEEN"], a, "\n")
        for (i = 1; i <= n; i++) seen[a[i]] = 1
        fail = "Operation [" opid "] failed: "
      }
      # a line of the container: the time stamp of the engine, then the line of log4net
      /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][^ ]* / {
        sub(/\r$/, "")
        st = substr($0, 1, index($0, " ") - 1)
        u = substr($0, length(st) + 2)
        sub(/^[ \t]+/, "", u)
        last = st
        ev = ""
        timed = (u ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)
        if (timed) {
          # date time level logger.method : message
          tm = substr(u, 12, 8)
          r = substr(u, 20)
          sub(/^[,.0-9]*[ \t]+/, "", r)
          lv = r
          sub(/[ \t].*/, "", lv)
          r = substr(r, length(lv) + 1)
          sub(/^[ \t]+/, "", r)
          i = index(r, " : ")
          lg = (i > 0) ? substr(r, 1, i - 1) : ""
          msg = (i > 0) ? substr(r, i + 3) : r
          keep = (lg ~ /DatabaseSnapshotDataTransferService|SnapshotServiceBase|\.SynchronizationService\./ || lv == "ERROR" || lv == "FATAL" || index(msg, "No space left on device") > 0)
          if (lg ~ /LegacyOperationBridge/) {
            keep = (opid != "" && index(msg, opid) > 0)
            if (index(msg, "was cancelled, because synchronization is currently being processed") > 0) {
              keep = 1
              ev = "C"
            }
            if (keep && index(msg, "Starting the synchronization operation") == 1) ev = "B"
            if (keep && index(msg, fail) == 1) {
              f = substr(msg, length(fail) + 1)
              sub(/\.$/, "", f)
              ev = "F " f
            }
          }
          # the answer to an expired login
          if (index(msg, "Authorization failed") > 0 || index(msg, "Failed to validate the token") > 0) keep = 0
          if (lv != "INFO" && lv != "DEBUG") msg = lv " " msg
          if (msg ~ /^Extracted archive to \//) msg = "Extracted archive"
          show = keep
        } else {
          # a line of an exception: shown with the line it belongs to (a full disk always), its stack never
          if (u == "" || u ~ /^at / || u ~ /^--- End of / || u ~ /SecurityToken[A-Za-z]*Exception|IDX10223/) next
          msg = u
          show = (keep || index(u, "No space left on device") > 0)
        }
        if (show || !timed) {
          k++
          cand[k] = $0
          cst[k] = st
        }
        if (($0 in seen) || mark) next
        if (ev != "") print ev
        if (show) print "L " (tm != "" ? tm : ENVIRON["FL_NOW"]) " " msg
      }
      END {
        if (last != "") {
          print "S " last
          for (i = 1; i <= k; i++) if (substr(cst[i], 1, 19) == substr(last, 1, 19)) print "E " cand[i]
        }
        print "K " keep
        print "T " tm
      }' | sed -E "/^L /s#([ '\"(])/([^/ ]+/)+([^/ '\"]+)#\\1.../\\3#g")"; then
    if [ -n "$mark" ]; then
      FOLLOW_CID=""
    fi
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      "L "*)
        follow_clear
        printf '%s\n' "${line#L }"
        FOLLOW_STEP="${line:11}"
        new=0
        ;;
      "S "*) since="${line#S }" ;;
      "E "*) seen="$seen${line#E }"$'\n' ;;
      "K "*) FOLLOW_KEEP="${line#K }" ;;
      "T "*) FOLLOW_TIME="${line#T }" ;;
      "F "*) FOLLOW_FAILED="${line#F }" ;;
      C) FOLLOW_CANCEL="yes" ;;
      B) FOLLOW_STARTED="yes" ;;
    esac
  done <<< "$out"
  if [ -n "$since" ]; then
    FOLLOW_SINCE="$since"
    FOLLOW_SEEN="$seen"
  fi
  return "$new"
}

# import_step PERCENT -> what a snapshot import does at this progress of its synchronization history (the
# Catalog sets it before each step)
import_step() {
  local p="$1" step="" entry
  local -a steps=("2 importing AppCompat" "6 importing the CPE dictionary" "10 importing CVE" "14 importing CWE"
    "18 importing UNSPSC" "22 importing vulnerability metadata" "26 importing manufacturers"
    "30 importing license classification metadata" "34 importing function metadata" "36 caching metadata"
    "38 importing relationships" "40 importing products" "42 importing hardware products" "46 importing versions"
    "50 importing hardware models" "54 importing fingerprints" "58 importing hardware fingerprints"
    "62 importing license classifications" "66 importing functions" "70 importing storage files"
    "74 importing normalization rules" "78 importing hardware normalization rules" "82 importing product numbers"
    "84 importing product URL patterns" "87 importing ECCN" "89 importing fingerprint vulnerabilities"
    "92 importing fingerprint CPE strings" "96 importing cached vulnerabilities" "99 finishing")
  # Catalog 25.x imports the products at 38 (26.x the relationships first)
  if [[ "$CATALOG_VERSION" =~ ^([0-9]+)\. ]] && [ "${BASH_REMATCH[1]}" -le 25 ]; then
    steps[10]="38 importing products"
  fi
  for entry in "${steps[@]}"; do
    if [ "$p" -lt "${entry%% *}" ]; then
      break
    fi
    step="${entry#* }"
  done
  printf '%s' "$step"
}

# follow_get PATH OUTFILE WHAT -> LOCAL_CODE of a GET of a follow-up (without curl's messages: the progress
# line says when the Catalog does not answer); fails, with the reason said, when the follow-up cannot go
# on: the login expired and could not be renewed (4), no license (1)
follow_get() {
  local_call_kept GET "$1" "$2" 2>/dev/null
  case "$LOCAL_CODE" in
    401)
      follow_clear
      job_step "Stopped following - it goes on in the Catalog"
      if [[ "$LOCAL_AUTH" == "Authorization: Bearer "* ]]; then
        warn "The login has expired; the $3 goes on in the Catalog - its progress: option 10 (logs) or the web interface"
      else
        warn "The Catalog no longer accepts the API key; the $3 goes on in the Catalog - its progress: option 10 (logs) or the web interface"
      fi
      job_unfollowed
      return 4
      ;;
    520)
      follow_clear
      report_unlicensed
      return 1
      ;;
  esac
}

# The end of a follow-up: the lines the Catalog logged since the last look
follow_end() {
  if [ -n "$FOLLOW_CID" ]; then
    catalog_log_steps "$1" || true
  fi
  follow_clear
}

# follow_index OUTFILE ADMIN -> after an import the Catalog rebuilds its search index in an operation of its
# own (an administrator can read it)
follow_index() {
  local status=""
  if [ "$2" = "yes" ]; then
    local_call_kept GET "/v1/operation/recent?type=index&maxItems=1" "$1" 2>/dev/null
    if [ "$LOCAL_CODE" = "200" ]; then
      status="$(json_field status "$1")"
      case "${status,,}" in
        pending|accepted|started) status="${status,,}" ;;
        *) status="" ;;
      esac
    fi
  fi
  info "The Catalog now rebuilds its search index in a separate operation${status:+ ($status)} - searches can be incomplete until it ends."
}

# Follows a local operation (a snapshot import or a synchronization) until it ends: the progress of its
# synchronization history (what the web interface shows), the status of the operation (only Admin and
# SiteAdmin may read it) and the steps the Catalog logs after follow_mark.
# watch_operation OPID LABEL -> 0 finished, 1 failed, 4 not followed to the end (the operation goes on in
# the Catalog or its end is not known: the login expired, nothing changed for a day, probably cancelled)
watch_operation() {
  local out rc=0
  out="$(mktemp)"
  watch_loop "$out" "$1" "$2" || rc=$?
  rm -f -- "$out"
  return "$rc"
}

# watch_loop OUTFILE OPID LABEL (see watch_operation)
watch_loop() {
  local out="$1" opid="$2" label="$3" what pct="" p status="" message="" step prepare doing gone="no"
  local hist="yes" op="yes" polls=0 t0="$SECONDS" quiet="$SECONDS" said="no" older="no" others=0 cancels=0
  what="${label,,}"
  if [ "$label" = "Import" ]; then
    prepare="the Catalog copies the snapshot and unpacks it"
    doing="copying and unpacking the snapshot"
  else
    prepare="the Catalog downloads the data and unpacks it"
    doing="downloading and unpacking the data"
  fi
  # Catalog 25.x lets a second synchronization wait, 26.x cancels it
  if [[ "$CATALOG_VERSION" =~ ^([0-9]+)\. ]] && [ "${BASH_REMATCH[1]}" -le 25 ]; then
    older="yes"
  fi
  FOLLOW_STEP=""
  FOLLOW_FAILED=""
  FOLLOW_CANCEL=""
  FOLLOW_STARTED=""
  info "$label running (operation $opid) - the progress is checked every 5 seconds."
  while true; do
    polls=$((polls + 1))
    local_auth_renew
    if [ "$hist" = "yes" ]; then
      follow_get "/v1/synchronizationHistory/progress/$opid" "$out" "$what" || return $?
      gone="no"
      case "$LOCAL_CODE" in
        200)
          p="$(tr -dc '0-9' < "$out")"
          if [ -n "$p" ] && [ "$p" != "$pct" ]; then
            pct="$p"
            quiet="$SECONDS"
          fi
          ;;
        403) hist="no" ;;
        000) gone="yes" ;;
      esac
    fi
    if [ "$op" = "yes" ]; then
      follow_get "/v1/operation/$opid" "$out" "$what" || return $?
      case "$LOCAL_CODE" in
        200)
          p="$(json_field status "$out")"
          if [ "${p,,}" != "$status" ]; then
            status="${p,,}"
            quiet="$SECONDS"
          fi
          message="$(json_text message "$out")"
          ;;
        403) op="no" ;;
        000) gone="yes" ;;
      esac
    fi
    if [ "$hist" = "no" ] && [ "$op" = "no" ]; then
      follow_clear
      ok "$label started - this login may not read its progress: follow it in the Catalog web interface."
      return 0
    fi
    if [ -n "$FOLLOW_CID" ] && catalog_log_steps "$opid"; then
      quiet="$SECONDS"
    fi
    case "$status" in
      finished)
        follow_end "$opid"
        ok "$label finished."
        follow_index "$out" "$op"
        return 0
        ;;
      failed|rejected)
        follow_end "$opid"
        err "$label $status${message:+: $message}"
        return 1
        ;;
      cancelled)
        follow_end "$opid"
        err "$label cancelled${message:+: $message}"
        echo "  The Catalog cancels it while another synchronization runs - start it again when that one has ended."
        return 1
        ;;
    esac
    # without the right to read the operation: its synchronization history tells the end and the result
    if [ "$op" = "no" ] && [ "$pct" = "100" ]; then
      follow_get /v1/synchronizationHistory/lastSynchronizationHistory "$out" "$what" || return $?
      if [ "$LOCAL_CODE" != "200" ] || [ "$(json_field operationId "$out")" != "$opid" ]; then
        follow_end "$opid"
        ok "$label finished (100%)."
        follow_index "$out" "$op"
        return 0
      fi
      message="$(json_text summaryDetails "$out")"
      case "$(json_field synchronizationStatus "$out")" in
        3)
          follow_end "$opid"
          ok "$label finished.${message:+ $message}"
          follow_index "$out" "$op"
          return 0
          ;;
        4)
          follow_end "$opid"
          err "$label failed${message:+: $message}"
          return 1
          ;;
      esac
    fi
    # ... and the Catalog's log a failure before the history has a record (a full disk while it copies the snapshot)
    if [ "$op" = "no" ] && [ -n "$FOLLOW_FAILED" ]; then
      follow_end "$opid"
      err "$label failed: $FOLLOW_FAILED"
      return 1
    fi
    # 26.x cancels it while another synchronization runs: it never starts and gets no history record. The log
    # says so (naming no operation); without the log the newest history record is another one that runs -
    # which a Catalog stopped during a synchronization also leaves behind, so that is only a guess.
    if [ "$op" = "no" ] && [ "${pct:-0}" = "0" ] && [ "$older" = "no" ] && [ -z "$FOLLOW_STARTED" ]; then
      if [ -n "$FOLLOW_CANCEL" ]; then
        cancels=$((cancels + 1))
        if [ "$cancels" -ge 2 ]; then
          follow_end "$opid"
          err "$label cancelled: another synchronization runs in the Catalog (its log says so)."
          echo "  Start it again when that one has ended (the web interface shows it)."
          return 1
        fi
      elif [ $((polls % 3)) -eq 2 ]; then
        follow_get /v1/synchronizationHistory/lastSynchronizationHistory "$out" "$what" || return $?
        p="$(json_field operationId "$out")"
        if [ "$LOCAL_CODE" = "200" ] && [ "$(json_field synchronizationStatus "$out")" = "2" ] && [ -n "$p" ] && [ "$p" != "$opid" ]; then
          others=$((others + 1))
        else
          others=0
        fi
        if [ "$others" -ge 2 ]; then
          follow_end "$opid"
          warn "Another synchronization runs in the Catalog - this $what was probably cancelled: check the web interface."
          job_unfollowed
          return 4
        fi
      fi
    fi
    # a full snapshot can unpack for many hours without a sign: only a whole day without one ends the follow
    if [ $((SECONDS - quiet)) -ge 86400 ]; then
      follow_clear
      warn "Nothing has changed for 24 hours - not followed any further: check the Catalog web interface."
      job_unfollowed
      return 4
    fi
    if [ "$gone" = "yes" ]; then
      job_progress "" "Catalog Web does not answer at $(local_url)" "$(fmt_duration $((SECONDS - t0)))"
    elif [ "$status" = "pending" ] || [ "$status" = "accepted" ]; then
      job_progress "" "$label waiting for the Catalog to start it ($status)" "$(fmt_duration $((SECONDS - t0)))"
    elif [ "$hist" = "no" ]; then
      job_progress "" "$label ${status:-running}${message:+: $message}" "$(fmt_duration $((SECONDS - t0)))"
    elif [ "${pct:-0}" -eq 0 ] || { [ "$label" != "Import" ] && [ "$pct" -lt 50 ]; }; then
      if [ "$said" = "no" ]; then
        follow_clear
        info "Preparing: $prepare (it reports no progress for this; a full snapshot can take a long time)."
        said="yes"
      fi
      job_progress "" "Preparing: $doing" "$(fmt_duration $((SECONDS - t0)))"
    else
      p="$pct"
      if [ "$label" != "Import" ]; then
        # a synchronization reports the import of what it downloaded as 50 to 100
        p=$(((pct - 50) * 2))
      fi
      step="$(import_step "$p")"
      step="${step:-${FOLLOW_STEP//|//}}"
      job_progress "$pct" "$label $pct% $UI_SEP ${step:-running} $UI_SEP $(fmt_duration $((SECONDS - t0)))"
    fi
    sleep 5
  done
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
  if engine_cli && detect_compose 2>/dev/null; then
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
  local chainfile="$1" mode="${2:-interactive}" type date size file rc job="no" marks
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
  if ! mem_ask confirm import; then
    info "Cancelled."
    return 0
  fi
  local_auth_obtain "$mode" || return 1
  if [ "${#files[@]}" -gt 1 ] && [[ "$LOCAL_AUTH" == "Authorization: Bearer "* ]]; then
    info "The login is renewed while the chain is imported; a local API key (option 18) does not expire."
  fi
  rc=0
  marks="$(mem_oom_marks)"
  if [ "$mode" = "interactive" ] && [ -n "$SCRIPT_PATH" ]; then
    job="yes"
    run_job "Snapshot import (${#files[@]} files up to $(tail -n 1 "$chainfile" | cut -f2))" "$(local_auth_secret)" -- import_chain_run "${files[@]}" || rc=$?
  else
    errexit_rc import_chain_run "${files[@]}"
    rc="$ERREXIT_RC"
  fi
  if mem_import_again "$rc" "$job" "$marks" chain; then
    MEM_ASKED="yes" import_chain "$chainfile" "$mode"
    return
  fi
  return "$rc"
}

# Worker: import_chain_run FILE... - one upload after the other; stops at the first failure (4: an import
# not followed to its end, it goes on in the Catalog)
import_chain_run() {
  local file n=0 rc
  local_auth_take
  for file in "$@"; do
    n=$((n + 1))
    echo
    info "[$n/$#] $(basename -- "$file")"
    job_step "[$n/$#] Importing $(basename -- "$file")"
    # the import before may have taken longer than the access token of a login lasts
    if [ "$n" -gt 1 ] && [ -n "$LOCAL_REFRESH" ] && ! local_refresh; then
      err "The login has expired - $(basename -- "$file") and the files after it were not imported."
      return 1
    fi
    rc=0
    import_upload "$file" || rc=$?
    if [ "$rc" -eq 4 ]; then
      if [ "$n" -lt "$#" ]; then
        warn "The files after $(basename -- "$file") were not imported."
      fi
      return 4
    elif [ "$rc" -ne 0 ]; then
      err "Import stopped at $(basename -- "$file") - the files after it were not imported."
      return 1
    fi
  done
  ok "All $# snapshots imported."
}

# import_snapshot FILE [interactive|cli]
import_snapshot() {
  local file="$1" mode="${2:-interactive}" size rc job="no" marks
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
  if ! mem_ask confirm import; then
    info "Cancelled."
    return 0
  fi
  local_auth_obtain "$mode" || return 1
  rc=0
  marks="$(mem_oom_marks)"
  if [ "$mode" = "interactive" ] && [ -n "$SCRIPT_PATH" ]; then
    job="yes"
    run_job "Snapshot import ($(basename -- "$file"))" "$(local_auth_secret)" -- import_upload "$file" || rc=$?
  else
    errexit_rc import_upload "$file"
    rc="$ERREXIT_RC"
  fi
  if mem_import_again "$rc" "$job" "$marks" "$(if [[ "$(basename -- "$file")" == *-daily.tar.gz ]]; then printf daily; else printf file; fi)"; then
    MEM_ASKED="yes" import_snapshot "$file" "$mode"
    return
  fi
  return "$rc"
}

# Worker: import_upload FILE (credentials from the job secret or LOCAL_AUTH)
import_upload() {
  local file="$1" resp code opid size pid codefile base
  local_auth_take
  size="$(stat -c %s -- "$file")"
  info "Uploading $(basename -- "$file") ($(human_size "$size")) to $(local_url)"
  resp="$(mktemp)"
  codefile="$(mktemp)"
  base="$(minio_volume_bytes)" || base=""
  follow_mark
  # the credentials through a pipe: a here-string of bash 4.2 to 5.0 is a temporary file
  printf 'header = "%s"\n' "$LOCAL_AUTH" | curl -sS -K - -H 'Accept: application/json' --connect-timeout 5 \
    -F "file=@$file;type=application/gzip" -o "$resp" -w '%{http_code}' "$(local_url)/v1/synchronization/snapshot" > "$codefile" &
  pid=$!
  if [ -r /proc/self/io ]; then
    job_watch_bytes "$pid" "rchar:$pid" "$size" "Uploading" until-total
    if kill -0 "$pid" 2>/dev/null; then
      import_wait_store "$pid" "$size" "$base"
    fi
  else
    # the bytes sent cannot be seen here: one step for the upload and the storing in the Catalog
    job_watch_bytes "$pid" "rchar:$pid" "$size" "Uploading and storing in the Catalog (MinIO)"
  fi
  wait "$pid" || true
  code="$(cat -- "$codefile")"
  opid="$(json_field operationId "$resp")"
  rm -f -- "$resp" "$codefile"
  case "$code" in
    202)
      if [ -z "$opid" ]; then
        ok "Upload accepted - follow the import in the Catalog web interface."
        return 0
      fi
      # its own return: bash 4.2 leaves a function that errexit stops with 1, not with its code
      watch_operation "$opid" Import || return $?
      ;;
    200) err "The catalog received no file." ; return 1 ;;
    401|403) err "The local catalog refused the upload (HTTP $code) - the key or user needs the Synchronizer or Admin role."; return 1 ;;
    520) report_unlicensed; return 1 ;;
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
  ui_box "$(ui_width)" "Import into the local catalog $UI_SEP $(local_url)" "Snapshots in $WORK_DIR/snapshots, newest first. A chain is imported file by file: full import, then delta."
  i=0
  for f in ${chains[@]+"${chains[@]}"}; do
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

# catalog_settings_fill -> System Settings (Synchronization + Updates, Proxy server, Logging) of the local
# catalog, with LOCAL_AUTH of an administrator: Parent feed = CATALOG_CLOUD_URL always, conflicts resolved
# automatically (Always take incoming) in place of Resolve manually, Log level Info in place of the Debug a
# new Catalog starts with, and in empty fields only the stored API key (left empty without one) and the
# proxy of INTERNET_PROXY with its saved login (the Catalog shows its proxy password masked). One setting
# per POST, as the web interface saves them: a setting the Catalog has goes back as it came, with the new
# value. The Catalog builds its proxy from server and port into a Uri: the server keeps its scheme.
catalog_settings_fill() {
  local key p scheme host port l user="" pass="" pairs=() i name value was cur re out body code done_names=() failed=0
  key="$(api_key_stored)"
  # NAME VALUE WAS: written when the field is empty or has WAS (*: whatever it has)
  pairs=(ParentInstanceUrl "${CATALOG_CLOUD_URL%/}" "*" ConflictsResolvingBehavior "Always take incoming" "Resolve manually" LoggingLevel Info Debug)
  if [ -n "$key" ]; then
    pairs+=(ParentInstanceKey "$key" "")
  fi
  if [ -n "$INTERNET_PROXY" ]; then
    p="$INTERNET_PROXY"
    scheme="http"
    case "$p" in
      *://*) scheme="${p%%://*}"; p="${p#*://}" ;;
    esac
    p="${p##*@}"
    p="${p%%/*}"
    host="$p"
    port=""
    if [[ "$p" =~ ^(.*[^:]):([0-9]+)$ ]]; then
      host="${BASH_REMATCH[1]}"
      port="${BASH_REMATCH[2]}"
    fi
    if [ -z "$port" ]; then
      case "$scheme" in
        https) port="443" ;;
        *) port="80" ;;
      esac
    fi
    pairs+=(SynchronizationProxyServer "$scheme://$host" "" SynchronizationProxyServerPort "$port" "")
    l="$(proxy_login)"
    if [ -n "$l" ]; then
      user="$(net_decode "${l%%:*}")"
      pass="$(net_decode "${l#*:}")"
      pairs+=(SynchronizationProxyServerUsername "$user" "" SynchronizationProxyServerPassword "$pass" "")
    fi
  fi
  out="$(mktemp)"
  body="$(mktemp)"
  chmod 600 "$body"
  for ((i = 0; i < ${#pairs[@]}; i += 3)); do
    name="${pairs[i]}"
    value="${pairs[i + 1]}"
    was="${pairs[i + 2]}"
    code="$(local_call GET "/v1/databaseconfiguration/$name" "$out")"
    cur=""
    case "$code" in
      200) cur="$(tr -d '\r\n' < "$out")" ;;
      204|404) ;;
      520) rm -f -- "$out" "$body"; report_unlicensed; return 1 ;;
      *) failed=$((failed + 1)); continue ;;
    esac
    re='"value" *: *"(([^"\\]|\\.)*)"'
    if [[ "$cur" =~ $re ]]; then
      if [ "${BASH_REMATCH[1]}" = "$(json_escape "$value")" ]; then
        continue
      fi
      if [ -n "${BASH_REMATCH[1]}" ] && [ "${BASH_REMATCH[1]}" != "$was" ] && [ "$was" != "*" ]; then
        continue
      fi
      # split by hand: in a ${x/a/b} of bash 5.2 an & of the value would stand for the match
      printf '%s"value":"%s"%s' "${cur%%"${BASH_REMATCH[0]}"*}" "$(json_escape "$value")" "${cur#*"${BASH_REMATCH[0]}"}" > "$body"
    else
      printf '{"property":"%s","value":"%s"}' "$name" "$(json_escape "$value")" > "$body"
    fi
    code="$(local_call POST /v1/databaseconfiguration "$out" -H 'Content-Type: application/json' --data-binary "@$body")"
    case "$code" in
      200|201|204) done_names+=("$name") ;;
      *) failed=$((failed + 1)) ;;
    esac
  done
  rm -f -- "$out" "$body"
  if [ "${#done_names[@]}" -gt 0 ]; then
    ok "System Settings filled: ${done_names[*]}."
  elif [ "$failed" -eq 0 ]; then
    ok "System Settings already set - nothing to change."
  fi
  if [ -z "$key" ]; then
    info "No API key for $CATALOG_CLOUD_URL stored yet: the API Key field stays empty (option 20 sets it)."
  fi
  if [ "$failed" -gt 0 ]; then
    warn "$failed field(s) of System Settings could not be written - the web interface sets them by hand."
    return 1
  fi
}

# Option 27: System Settings of a Catalog activated before (the activation fills them only once): an
# administrator logs in, catalog_settings_fill does the rest
catalog_settings_menu() {
  license_status
  case "$LICENSE_STATE" in
    valid) ;;
    invalid) report_unlicensed; return 1 ;;
    *) report_license_state; return 1 ;;
  esac
  local_auth_obtain || return 1
  if [ "$LOCAL_ADMIN" != "yes" ]; then
    if [ "$LOCAL_STATE" = "valid" ]; then
      err "Changing System Settings needs a local administrator (for example admin or root)."
    else
      report_local_state
    fi
    return 1
  fi
  catalog_settings_fill
}

# Online servers: the local catalog gets the online catalog URL and key and synchronizes itself
# (daily by AUTOSYNC_CRON afterwards).
local_self_sync() {
  local key cur body out code
  # without a license the Catalog refuses everything: no need to ask for the online key first
  license_status
  if [ "$LICENSE_STATE" = "invalid" ]; then
    report_unlicensed
    return 1
  fi
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
    if [ "$LOCAL_STATE" = "valid" ] && [[ "$LOCAL_AUTH" == "Authorization: Bearer "* ]]; then
      err "The local catalog refused to change the synchronization settings (HTTP ${LOCAL_CODE:-403})."
      echo "  The user needs the Admin role (for example admin or root)."
    elif [ "$LOCAL_STATE" = "valid" ]; then
      err "Changing the synchronization settings needs a local administrator."
    else
      report_local_state
    fi
    return 1
  fi

  cur="$(mktemp)"
  body="$(mktemp)"
  out="$(mktemp)"
  code="$(local_call GET /v1/databaseconfiguration/synchronization "$cur")"
  if [ "$code" != "200" ] && [ "$code" != "204" ]; then
    rm -f -- "$cur" "$body" "$out"
    if [ "$code" = "520" ]; then
      report_unlicensed
    else
      err "Could not read the synchronization settings (HTTP $code)."
    fi
    return 1
  fi
  chmod 600 "$body"
  # only the online catalog and its key, as the web interface sends them: the other settings stay as the
  # Catalog keeps them - sent back, the masked password of its synchronization proxy would replace the real
  # one (and a proxy without its port fails)
  printf '{"parentInstanceUrl":"%s","parentInstanceKey":"%s"}' "$(json_escape "$CATALOG_CLOUD_URL")" "$(json_escape "$key")" > "$body"
  rm -f -- "$cur"
  code="$(local_call POST /v1/databaseconfiguration/synchronization "$out" -H 'Content-Type: application/json' --data-binary "@$body")"
  rm -f -- "$body"
  case "$code" in
    200|201|204)
      ok "The local catalog now synchronizes from $CATALOG_CLOUD_URL (automatically: AUTOSYNC_CRON \"$(setting AUTOSYNC_CRON)\")."
      wiz_mark sync
      # the proxy fields, which the synchronization settings above leave as they are
      catalog_settings_fill || true
      ;;
    520) rm -f -- "$out"; report_unlicensed; return 1 ;;
    *) rm -f -- "$out"; err "Saving the synchronization settings failed (HTTP $code)."; return 1 ;;
  esac

  if ! confirm "Start a synchronization now?" y; then
    rm -f -- "$out"
    return 0
  fi
  rm -f -- "$out"
  if [ -n "$SCRIPT_PATH" ]; then
    run_job "Synchronization from the online catalog" "$(local_auth_secret)" -- self_sync_run
  else
    self_sync_run
  fi
}

# Worker: starts the synchronization of the local catalog and follows it.
self_sync_run() {
  local tmp out code opid
  local_auth_take
  tmp="$(mktemp)"
  out="$(mktemp)"
  printf -- '--rvcboundary--\r\n' > "$tmp"
  follow_mark
  code="$(local_call POST /v1/synchronization/synchronize "$out" -H 'Content-Type: multipart/form-data; boundary=rvcboundary' --data-binary "@$tmp")"
  rm -f -- "$tmp"
  case "$code" in
    200|202)
      opid="$(json_field operationId "$out")"
      rm -f -- "$out"
      if [ -n "$opid" ]; then
        watch_operation "$opid" Synchronization || return $?
      else
        ok "Synchronization started - follow it in the Catalog web interface."
      fi
      ;;
    304) rm -f -- "$out"; ok "The local catalog is already up to date." ;;
    503) rm -f -- "$out"; warn "A synchronization is already running." ;;
    403) rm -f -- "$out"; err "The local catalog refused the synchronization (HTTP 403) - the online key may lack the Synchronizer role."; return 1 ;;
    520) rm -f -- "$out"; report_unlicensed; return 1 ;;
    *) rm -f -- "$out"; err "Starting the synchronization failed (HTTP $code)."; return 1 ;;
  esac
}

###############################################################################
# License of the local catalog (option 25)
###############################################################################

LICENSE_STATE=""
LICENSE_CODE=""
LICENSE_STATUS=""
LICENSE_ADMIN="no"
LICENSE_HOST=""
LICENSE_MSG=""
LICENSE_MSG_KIND=""
LICENSE_FILE=""

# license_status [CURL ARGS...] -> LICENSE_STATE valid / invalid / unreachable / error (GET
# /v1/license/isValid, no login); --max-time N waits less than local_call (no answer in time: unreachable)
license_status() {
  local out body
  out="$(mktemp)"
  LICENSE_CODE="$(local_call GET /v1/license/isValid "$out" "$@" 2>/dev/null)"
  body="$(tr -d ' \r\n\t' < "$out")"
  rm -f -- "$out"
  case "$LICENSE_CODE:$body" in
    200:true) LICENSE_STATE="valid" ;;
    200:false) LICENSE_STATE="invalid" ;;
    000:*) LICENSE_STATE="unreachable" ;;
    *) LICENSE_STATE="error" ;;
  esac
}

report_license_state() {
  case "$LICENSE_STATE" in
    valid) ok "The Catalog is activated (valid license)." ;;
    invalid) warn "The Catalog is not activated yet (no valid license)." ;;
    unreachable) err "Catalog Web does not answer at $(local_url) - is the stack running (option 6)?" ;;
    *) err "Unexpected answer of Catalog Web to the license check (HTTP ${LICENSE_CODE:-?})." ;;
  esac
}

# After a restart of the stack (upgrade, patch update): a license the new start does not accept is named
license_recheck() {
  license_status
  if [ "$LICENSE_STATE" = "invalid" ]; then
    warn "The Catalog has no valid license after the restart - $(license_how) shows why."
    echo "  A license for an older Catalog version or another host name of catalog-web"
    echo "  stops working at an upgrade."
  fi
}

# Before a job that writes the files of an older installer again: catalog-web gets its fixed host name. A
# licensed Catalog keeps the one it has (do_generate decides); a CATALOG_HOSTNAME of the settings that
# differs from it needs a license for the new name.
license_host_note() {
  local running
  if [ ! -f "$ENV_FILE" ] || [ -n "$(env_hostname)" ]; then
    return 0
  fi
  if [ -z "$CATALOG_HOSTNAME" ]; then
    info "catalog-web gets a fixed host name now (CATALOG_HOSTNAME): a licensed"
    echo "  Catalog keeps the one it has, so its license stays valid."
    return 0
  fi
  running="$(running_hostname)"
  if [ "$running" = "$CATALOG_HOSTNAME" ]; then
    return 0
  fi
  warn "catalog-web gets the fixed host name $CATALOG_HOSTNAME now (CATALOG_HOSTNAME)."
  echo "  The Catalog binds its license to its host name: afterwards it needs a license"
  echo "  for the new name ($(hint 25 license) shows its hardware ID)."
}

# The Catalog version of this installation (a license names the newest one it is for)
license_catalog_version() {
  local v
  v="$(env_value CATALOG_IMAGE)"
  v="${v##*:}"
  printf '%s' "${v:-$CATALOG_VERSION}"
}

# license_message FILE -> LICENSE_MSG, the text of an error answer: a JSON string (LICENSE_MSG_KIND text),
# or the title of a problem object of the Catalog's own checks of the request (problem)
license_message() {
  local m
  m="$(tr -d '\r\n' < "$1" 2>/dev/null)" || m=""
  LICENSE_MSG_KIND="text"
  case "$m" in
    \"*) m="$(printf '%s' "$m" | sed 's/^"//; s/"$//; s/\\"/"/g; s/\\\\/\\/g')" ;;
    \{*) m="$(json_field title "$1")"; LICENSE_MSG_KIND="problem" ;;
  esac
  LICENSE_MSG="${m:0:300}"
}

# license_version FILE -> the newest Catalog version the license is for ("26.3"; a string or an object)
license_version() {
  local v
  v="$(json_field version "$1")"
  if [ "$v" = "{" ]; then
    v="$(json_field major "$1").$(json_field minor "$1")"
  fi
  if [ "$v" = "." ]; then
    v=""
  fi
  printf '%s' "$v"
}

# The hardware ID of a license comes from the host name of catalog-web
license_host_hint() {
  local host="${LICENSE_HOST:-$(env_hostname)}"
  if [ -n "$host" ]; then
    echo "  The Catalog takes it from the host name of catalog-web: $host"
    echo "  A license made for another name works with that name in CATALOG_HOSTNAME"
    if [ "$INTERACTIVE" = "true" ]; then
      echo "  (option 1, then 2 and 6). The order number gets a license for this name."
    else
      echo "  (at the top of $SCRIPT_NAME, then '$0 generate' and '$0 up')."
      echo "  The order number gets a license for this name."
    fi
  else
    echo "  The Catalog takes it from the host name of catalog-web, which changes with"
    echo "  every new container in the files of older installers: $(hint 2 generate)"
    echo "  writes them with a fixed one (CATALOG_HOSTNAME), $(hint 6 up) applies them."
  fi
}

license_text_hint() {
  echo "  Use the file or the text exactly as Raynet sent it - the text from its first"
  echo "  line (LICENSE STARTS HERE) to its last line (LICENSE ENDS HERE)."
}

license_net_hint() {
  echo "  catalog-web needs HTTPS (port 443) to licenses.raynet.de, through a proxy"
  echo "  where the network has one. Without it: the license file or the e-mail text."
  echo "  The internet access of this server is checked by $(hint 26 network-check)."
}

license_not_admin() {
  err "${LOCAL_USER:-The user} is not a site administrator: only the role SiteAdmin activates."
  echo "  root is one; admin is not enough."
}

# license_explain STATUS -> what a license status of the Catalog means, and what helps
license_explain() {
  case "$1" in
    Ok|NotPresent|"") ;;
    InvalidHardwareId)
      warn "The license is for another server: the hardware ID does not match."
      license_host_hint
      ;;
    Expired) warn "The license has expired - Raynet makes a new one." ;;
    AnotherProduct) warn "The license is for another Raynet product, not the Technology Catalog." ;;
    OldVersion)
      warn "The license is for an older Catalog - this one is $(license_catalog_version)."
      echo "  Ask Raynet for a license for this version, or go back to the licensed version."
      ;;
    *) warn "License status: $1" ;;
  esac
}

# license_why WAY MESSAGE [KIND] -> why the Catalog refused an activation (WAY: order, file or mail; KIND
# problem: its own checks of the request refused it), and what helps
license_why() {
  local way="$1" m="$2" other="the license file or the e-mail text"
  if [ "${3:-}" = "problem" ]; then
    err "The Catalog refused the request: ${m:-no reason given}"
    return 0
  fi
  case "$m" in
    license.messages.invalid-hardware-id)
      err "This license is for another server: the hardware ID does not match."
      license_host_hint
      ;;
    license.messages.license-expired) err "This license has expired - Raynet makes a new one." ;;
    license.messages.another-product) err "This license is for another Raynet product, not the Technology Catalog." ;;
    license.messages.wrong-version)
      err "This license is for an older Catalog - this one is $(license_catalog_version)."
      echo "  Ask Raynet for a license for this version."
      ;;
    "Unable to connect to activation server (server error"*)
      err "Raynet's license server failed${m#Unable to connect to activation server}"
      echo "  Try again later - or use $other."
      ;;
    license.messages.check-connection|"Unable to connect to activation server"*|"Could not connect to the activation server"*)
      err "Catalog Web could not reach Raynet's license server (licenses.raynet.de)."
      license_net_hint
      ;;
    "The license could not be activated.")
      # the request for the license got no answer (the login before it did)
      err "Raynet's license server (licenses.raynet.de) did not answer."
      license_net_hint
      ;;
    "The license could not be activated"*)
      err "Raynet's license server failed${m#The license could not be activated}"
      echo "  Try again later - or use $other."
      ;;
    license.messages.invalid-license)
      err "Raynet's license server refused the request."
      echo "  Check the order number and the other fields."
      echo "  Another way: $other."
      ;;
    license.messages.unknown-issue)
      err "The Catalog could not activate the license (it gives no reason)."
      echo "  The log of catalog-web: $(hint 10 "logs catalog-web")."
      ;;
    *"Unknown order number"*)
      if [ "$way" = "order" ]; then
        err "Raynet's license server has no license for this order number."
        echo "  Check the order number on the order confirmation of Raynet."
      else
        err "This is not a license the Catalog can read."
        license_text_hint
      fi
      ;;
    "The license is malformed."*)
      err "The license is damaged or incomplete:${m#The license is malformed.}"
      license_text_hint
      ;;
    *Base-64*|*base64*|*Base64*)
      err "The license text is damaged: it is not the text as Raynet sent it."
      license_text_hint
      ;;
    "This license is not valid"*)
      err "The Catalog does not accept this license:"
      echo "  $m"
      ;;
    "File must be uploaded.") err "The Catalog received no file." ;;
    "") err "The activation failed (HTTP 400, no reason given)." ;;
    *)
      if [ "$way" = "order" ]; then
        err "Raynet's license server: $m"
      else
        err "The Catalog refused the license: $m"
      fi
      ;;
  esac
}

# license_show FILE -> the license in an answer of the Catalog (GET /v1/license, or an activation)
license_show() {
  local status edition version expires hid host text
  status="$(json_field status "$1")"
  edition="$(json_field edition "$1")"
  version="$(license_version "$1")"
  expires="$(json_field expirationDate "$1")"
  hid="$(json_field yourHardwareId "$1")"
  host="${LICENSE_HOST:-$(env_hostname)}"
  case "$status" in
    Ok) text="$C_GRN${UI_OK}$C_RST valid" ;;
    NotPresent) text="none yet" ;;
    *) text="$C_YLW${UI_NO}$C_RST not valid ($status)" ;;
  esac
  printf '  %-13s %s\n' "License" "$text"
  if [ -n "$edition" ]; then
    printf '  %-13s %s\n' "Edition" "$edition"
  fi
  if [ -n "$version" ]; then
    printf '  %-13s %s\n' "For" "Catalog up to $version"
  fi
  if [ "$status" != "NotPresent" ]; then
    printf '  %-13s %s\n' "Expires" "$(if [ -n "$expires" ] && [ "$expires" != "null" ]; then printf '%s' "${expires:0:10}"; else printf 'no expiration date'; fi)"
  fi
  if [ -n "$hid" ]; then
    printf '  %-13s %s\n' "Hardware ID" "$hid${host:+ (host name $host)}"
    if [ "$status" != "Ok" ]; then
      echo "  Raynet makes a license file or e-mail text for this hardware ID."
    fi
  fi
  license_explain "$status"
}

# license_details [show] -> GET /v1/license with LOCAL_AUTH: LICENSE_STATUS, LICENSE_ADMIN (yes: the
# answer has the hardware ID, which the Catalog gives only to site administrators; unknown: the Catalog
# could not read its license); show prints it
license_details() {
  local out code
  out="$(mktemp)"
  code="$(local_call GET /v1/license "$out")"
  LICENSE_STATUS=""
  LICENSE_ADMIN="no"
  case "$code" in
    200) ;;
    401) rm -f -- "$out"; err "The Catalog did not accept the login (HTTP 401) - log in again."; return 1 ;;
    000) rm -f -- "$out"; err "Catalog Web does not answer at $(local_url)."; return 1 ;;
    *)
      # a damaged license can make the Catalog fail here: the activation replaces it
      rm -f -- "$out"
      warn "The license could not be read (HTTP $code) - an activation replaces it."
      LICENSE_ADMIN="unknown"
      return 0
      ;;
  esac
  LICENSE_STATUS="$(json_field status "$out")"
  if [ -n "$(json_field yourHardwareId "$out")" ]; then
    LICENSE_ADMIN="yes"
  fi
  if [ "${1:-}" = "show" ]; then
    license_show "$out"
  fi
  rm -f -- "$out"
}

# license_login [show] -> LOCAL_AUTH of a site administrator, who alone may activate; show prints the
# license. 1: failed, 2: cancelled
license_login() {
  local rc=0
  echo "  Activation needs a site administrator (role SiteAdmin: root, not admin)."
  echo "  A new Catalog has the user root with the password root."
  local_login root || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  if ! license_details "${1:-}"; then
    LOCAL_AUTH=""
    return 1
  fi
  if [ "$LICENSE_ADMIN" = "no" ]; then
    license_not_admin
    LOCAL_AUTH=""
    return 1
  fi
}

# Temporary files of an activation (the order data, the license, the answer): Ctrl+C (or TERM) removes them
# before it stops. license_tmp_guard FILE... adds files, license_tmp_done removes them all.
LICENSE_TMP=()
license_tmp_guard() {
  LICENSE_TMP+=("$@")
  trap 'rm -rf -- ${LICENSE_TMP[@]+"${LICENSE_TMP[@]}"}; exit 130' INT TERM
}

license_tmp_done() {
  rm -rf -- ${LICENSE_TMP[@]+"${LICENSE_TMP[@]}"}
  LICENSE_TMP=()
  trap - INT TERM
}

# license_send WAY [curl args...] -> sends a license to Catalog Web (WAY: order, file or mail) and says
# what came of it; 0 when the Catalog took it
license_send() {
  local way="$1" out code
  shift
  out="$(mktemp)"
  license_tmp_guard "$out"
  code="$(local_call POST "/v1/license/activate/$way" "$out" "$@")"
  case "$code" in
    200)
      echo
      ok "The Catalog took the license:"
      license_show "$out"
      rm -f -- "$out"
      license_status
      if [ "$LICENSE_STATE" = "valid" ]; then
        ok "Catalog Web confirms it: the license is valid."
        return 0
      fi
      warn "Catalog Web does not confirm the license (license check: $LICENSE_STATE)."
      echo "  $(license_how) shows it."
      return 1
      ;;
    400)
      license_message "$out"
      license_why "$way" "$LICENSE_MSG" "$LICENSE_MSG_KIND"
      # the Catalog answers so too when it took the license but could not save it
      if [ "$LICENSE_MSG" = "license.messages.unknown-issue" ]; then
        license_status
        if [ "$LICENSE_STATE" = "valid" ]; then
          warn "The Catalog took the license, but could not save it in its volume"
          echo "  catalog_license: the license is lost at the next restart of catalog-web."
        fi
      fi
      ;;
    401) err "The Catalog did not accept the login any more (HTTP 401) - log in again."; LOCAL_AUTH="" ;;
    403) license_not_admin; LOCAL_AUTH="" ;;
    000)
      license_status
      case "$LICENSE_STATE" in
        valid)
          ok "Catalog Web confirms it: the license is valid."
          rm -f -- "$out"
          return 0
          ;;
        unreachable) err "Catalog Web does not answer at $(local_url) any more." ;;
        *)
          if [ "$way" = "order" ]; then
            err "Catalog Web got no license from Raynet's license server in time."
            license_net_hint
          else
            err "Catalog Web did not answer the activation in time."
          fi
          ;;
      esac
      ;;
    *) err "The activation failed (HTTP $code)." ;;
  esac
  rm -f -- "$out"
  return 1
}

# Activation by order number: Catalog Web fetches the license from Raynet's license server.
# 0 activated, 1 failed, 2 cancelled
license_order() {
  local order="" user="" company="" email="" def="" body rc
  echo "  Catalog Web fetches the license from Raynet's license server"
  echo "  (licenses.raynet.de): it needs internet access. The order number, your name,"
  echo "  company and e-mail address go to Raynet."
  ui_ask order "Order number:" || order=""
  if [ -n "$order" ] && [ "$order" != "0" ]; then
    ui_ask user "User name (your name, for Raynet):" || user=""
  fi
  if [ -n "$user" ] && [ "$user" != "0" ]; then
    ui_ask company "Company name:" || company=""
  fi
  if [ -n "$company" ] && [ "$company" != "0" ]; then
    if email_valid "$NPM_ADMIN_EMAIL"; then
      def="$NPM_ADMIN_EMAIL"
    fi
    while ui_ask email "E-mail address${def:+ [$def]}:"; do
      email="${email:-$def}"
      if [ -z "$email" ] || [ "$email" = "0" ] || email_valid "$email"; then
        break
      fi
      err "Give an e-mail address, e.g. it@example.com."
      email=""
    done
  fi
  if [ -z "$email" ] || [ "$email" = "0" ]; then
    info "Cancelled."
    return 2
  fi
  body="$(mktemp)"
  # Ctrl+C (the call can take minutes) removes the order data too
  license_tmp_guard "$body"
  (umask 077 && printf '{"orderNumber":"%s","userName":"%s","companyName":"%s","email":"%s"}' \
    "$(json_escape "$order")" "$(json_escape "$user")" "$(json_escape "$company")" "$(json_escape "$email")" > "$body")
  order=""
  info "Catalog Web asks Raynet's license server - this can take a few minutes..."
  rc=0
  license_send order -H 'Content-Type: application/json' --data-binary "@$body" --max-time 450 || rc=$?
  license_tmp_done
  return "$rc"
}

# license_file_check PATH -> LICENSE_FILE: PATH without quotes around it and with ~/ expanded; fails (and
# says why) when it is no readable, non-empty file
license_file_check() {
  local path="$1"
  case "$path" in
    \"*\"|\'*\') path="${path:1:${#path}-2}" ;;
  esac
  case "$path" in
    "~/"*) path="$HOME/${path#\~/}" ;;
  esac
  LICENSE_FILE="$path"
  if [ ! -f "$path" ]; then
    err "No license file at $path."
    return 1
  fi
  if [ ! -r "$path" ]; then
    err "$path cannot be read - run the installer as its owner, or copy it here."
    return 1
  fi
  if [ ! -s "$path" ]; then
    err "$path is empty."
    return 1
  fi
}

# license_file [PATH] -> activation by the license file of Raynet (.rswl), uploaded as it is.
# 0 activated, 1 failed, 2 cancelled
license_file() {
  local path="${1:-}" dir rc
  if [ -z "$path" ]; then
    ui_ask path "Path of the license file (.rswl):" || path=""
    if [ -z "$path" ] || [ "$path" = "0" ]; then
      info "Cancelled."
      return 2
    fi
  fi
  license_file_check "$path" || return 1
  path="$LICENSE_FILE"
  # a copy with a plain name: curl -F takes ; and , in a file name for options
  dir="$(mktemp -d)"
  license_tmp_guard "$dir"
  if ! (umask 077 && cp -- "$path" "$dir/license.rswl"); then
    license_tmp_done
    err "$path could not be copied to $dir (disk full?)."
    return 1
  fi
  info "Uploading $(basename -- "$path") to $(local_url)"
  rc=0
  license_send file -F "file=@$dir/license.rswl" || rc=$?
  license_tmp_done
  return "$rc"
}

# Activation by e-mail: the license text of Raynet's e-mail, pasted - from its line LICENSE STARTS HERE
# (text before it, a greeting, is dropped) to its line LICENSE ENDS HERE, two empty lines or the end of the
# input; a text without these lines ends at an empty line. Quotes of an e-mail client (> ) and indentation
# are dropped, the line breaks kept; in a terminal, what the paste brought after the text is dropped too.
# 0 activated, 1 failed, 2 cancelled
license_text() {
  local file line t n=0 rc started="no" empty=0 skipped=0 eof="no"
  echo "  Paste the license text of Raynet's e-mail, from its line LICENSE STARTS HERE"
  echo "  to its line LICENSE ENDS HERE (0 cancels):"
  file="$(mktemp)"
  license_tmp_guard "$file"
  chmod 600 "$file"
  while [ "$eof" = "no" ]; do
    line=""
    IFS= read -r line || eof="yes"
    line="${line#"${line%%[![:space:]>]*}"}"
    t="${line//[[:space:]]/}"
    if [ -z "$t" ]; then
      empty=$((empty + 1))
      if [ "$n" -gt 0 ] && { [ "$started" = "no" ] || [ "$empty" -ge 2 ]; }; then
        break
      fi
      continue
    fi
    empty=0
    if [ "$n" -eq 0 ] && [ "$t" = "0" ]; then
      license_tmp_done
      info "Cancelled."
      return 2
    fi
    if [[ "$line" == *"LICENSE STARTS HERE"* ]]; then
      : > "$file"
      n=0
      started="yes"
    elif [ "$started" = "no" ] && [ "$n" -eq 0 ] && { [ "${#t}" -lt 16 ] || ! [[ "$t" =~ ^[A-Za-z0-9+/=]+$ ]]; }; then
      # text before the license (a greeting) is not part of it
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s\n' "$line" >> "$file"
    n=$((n + 1))
    if [[ "$line" == *"LICENSE ENDS HERE"* ]]; then
      break
    fi
  done
  if [ "$eof" = "no" ] && [ -t 0 ]; then
    while IFS= read -r -t 0.3 _; do
      :
    done
  fi
  if [ "$n" -eq 0 ]; then
    license_tmp_done
    if [ "$skipped" -gt 0 ]; then
      err "No license text found: its line LICENSE STARTS HERE is missing."
      license_text_hint
      return 1
    fi
    info "Cancelled."
    return 2
  fi
  info "Sending the license text ($n lines) to $(local_url)"
  rc=0
  license_send mail -H 'Content-Type: text/plain' --data-binary "@$file" || rc=$?
  license_tmp_done
  return "$rc"
}

# Host name of the running catalog-web container as the Catalog sees it, up to the first dot (empty when
# it does not run or the engine does not answer)
running_hostname() {
  local id host=""
  if ! engine_cli || ! detect_compose >/dev/null 2>&1; then
    return 0
  fi
  id="$(compose ps -q catalog-web 2>/dev/null | head -n 1)" || id=""
  if [ -n "$id" ]; then
    host="$("$ENGINE" container inspect --format '{{.Config.Hostname}}' "$id" 2>/dev/null)" || host=""
  fi
  printf '%s' "${host%%.*}"
}

# Host name of the catalog-web container of this Compose project, running or stopped, as the Catalog sees
# it: up to the first dot (empty when there is none or the engine does not answer); the files are not
# needed
web_container_hostname() {
  local ids host=""
  if ! engine_cli; then
    return 0
  fi
  ids="$("$ENGINE" ps -aq --filter "label=com.docker.compose.project=$(stack_project)" --filter "label=com.docker.compose.service=catalog-web" 2>/dev/null)" || ids=""
  if [ -n "$ids" ]; then
    host="$("$ENGINE" container inspect --format '{{.Config.Hostname}}' "${ids%%$'\n'*}" 2>/dev/null)" || host=""
  fi
  printf '%s' "${host%%.*}"
}

# The host name catalog-web keeps when the files get their fixed one for the first time: the one its
# container has now (in the files of older installers its container ID), when the Catalog holds a valid
# license bound to it or does not answer (stopped, starting: it may hold one). Empty without data volumes
# (VOLUMES, the volumes of the project), without a container, or when Catalog Web answers that it has no
# valid license (nothing to lose). Fails, with that name, when it cannot be a fixed host name: the license
# the Catalog may hold is lost then. license_kept_hostname VOLUMES
license_kept_hostname() {
  local host
  if [ -z "$1" ]; then
    return 0
  fi
  host="$(web_container_hostname)"
  if [ -z "$host" ]; then
    return 0
  fi
  # not long: a Catalog Web that hangs counts as one that does not answer
  license_status --max-time 15
  if [ "$LICENSE_STATE" = "invalid" ]; then
    return 0
  fi
  printf '%s' "$host"
  hostname_valid "$host"
}

# The license is bound to the host name catalog-web runs with. Writing the files keeps it when they have
# no fixed one yet (an older installer: a licensed Catalog keeps its name); a fixed one that differs
# (CATALOG_HOSTNAME of the files, or of the settings) ends a license activated now when the files are
# applied. Sets LICENSE_HOST; fails when the activation should wait. license_host_check [menu|wizard]
license_host_check() {
  local mode="${1:-menu}" fixed next running
  LICENSE_HOST=""
  if [ ! -f "$ENV_FILE" ]; then
    return 0
  fi
  fixed="$(env_hostname)"
  next="${CATALOG_HOSTNAME:-$fixed}"
  running="$(running_hostname)"
  LICENSE_HOST="${running:-$fixed}"
  if [ -z "$next" ] || [ -z "$running" ] || [ "$running" = "$next" ]; then
    return 0
  fi
  warn "catalog-web still runs with the host name $running."
  echo "  A license activated now stops working when the files with the fixed host name"
  echo "  $next (CATALOG_HOSTNAME) are applied."
  if [ "$mode" = "wizard" ]; then
    echo "  The repair of I (choice 1) writes and applies them - activate then."
  elif [ "$next" != "$fixed" ]; then
    echo "  $(hint 2 generate) writes them, $(hint 6 up) applies them - activate then."
  else
    echo "  $(hint 6 up) applies them - activate then."
  fi
  confirm "Activate anyway?" n
}

# license_activate [menu|wizard] -> shows the license and activates one: by order number, license file or
# the text of Raynet's e-mail. 1: failed. Wizard: 0 when the Catalog has a valid license at the end, 2 later.
license_activate() {
  local mode="${1:-menu}" choice rc fails=0 later="cancel"
  LOCAL_AUTH=""
  license_status
  case "$LICENSE_STATE" in
    unreachable|error)
      report_license_state
      return 1
      ;;
  esac
  if [ "$mode" = "wizard" ]; then
    if [ "$LICENSE_STATE" = "valid" ]; then
      report_license_state
      return 0
    fi
    later="later $UI_SEP option 25 activates it"
    echo "  The Catalog needs a license from Raynet: without one it takes no data."
    if ! license_host_check wizard; then
      info "Later: option 25 activates the Catalog."
      return 2
    fi
  else
    echo
    report_license_state
    if ! license_host_check; then
      info "Cancelled."
      return 0
    fi
    rc=0
    license_login show || rc=$?
    case "$rc" in
      0) ;;
      2) return 0 ;;
      *) return 1 ;;
    esac
    if [ "$LICENSE_STATE" = "valid" ] && ! confirm "Activate again?" n; then
      return 0
    fi
  fi
  while true; do
    echo
    printf '   %s %s  %s\n' "${C_BLD}1$C_RST" "$(menu_icon run)" "By order number $C_DIM(Catalog Web fetches it from Raynet: internet)$C_RST"
    printf '   %s %s  %s\n' "${C_BLD}2$C_RST" "$(menu_icon run)" "By license file $C_DIM(the .rswl file of Raynet)$C_RST"
    printf '   %s %s  %s\n' "${C_BLD}3$C_RST" "$(menu_icon run)" "By e-mail $C_DIM(paste the license text of Raynet's e-mail)$C_RST"
    printf '   %s    %s\n' "${C_BLD}0$C_RST" "$C_DIM$later$C_RST"
    echo
    ui_ask choice "Select [0]:" || choice="0"
    choice="${choice:-0}"
    case "$choice" in
      1|2|3) ;;
      0)
        if [ "$mode" = "wizard" ]; then
          info "Later: option 25 activates the Catalog."
          return 2
        fi
        info "Cancelled."
        return 0
        ;;
      *) warn "Unknown choice: $choice"; continue ;;
    esac
    echo
    rc=0
    if [ -z "$LOCAL_AUTH" ]; then
      license_login show || rc=$?
      if [ "$rc" -eq 0 ]; then
        echo
      fi
    fi
    if [ "$rc" -eq 0 ]; then
      case "$choice" in
        1) license_order || rc=$? ;;
        2) license_file || rc=$? ;;
        3) license_text || rc=$? ;;
      esac
    fi
    case "$rc" in
      0)
        # activated: the login of the activation fills System Settings at once, before any import
        catalog_settings_fill || true
        return 0
        ;;
      2) ;;
      *) fails=$((fails + 1)) ;;
    esac
    if [ "$fails" -ge 3 ]; then
      warn "Stopped after $fails failed attempts - $(license_how) tries again."
      return 1
    fi
    if [ "$rc" -ne 2 ]; then
      echo "  Another way below, or 0."
    fi
  done
}

# license [status|file PATH|order|text] on the command line; without an argument as option 25
license_cli() {
  local path="${2:-}"
  case "${1:-}" in
    "") license_activate menu ;;
    status)
      license_status
      report_license_state
      [ "$LICENSE_STATE" = "valid" ]
      ;;
    file|order|text)
      # a wrong path is named before the login
      if [ "$1" = "file" ]; then
        if [ -z "$path" ]; then
          err "Give the license file: $0 license file PATH"
          return 2
        fi
        if [[ "$path" != /* ]] && [ -e "$CALL_DIR/$path" ]; then
          path="$CALL_DIR/$path"
        fi
        license_file_check "$path" || return 1
        path="$LICENSE_FILE"
      fi
      license_status
      case "$LICENSE_STATE" in
        unreachable|error) report_license_state; return 1 ;;
      esac
      report_license_state
      license_host_check || return 1
      license_login || return 1
      case "$1" in
        file) license_file "$path" ;;
        order) license_order ;;
        text) license_text ;;
      esac
      ;;
    *)
      err "Unknown option for license: $1 (status, file PATH, order or text)"
      return 2
      ;;
  esac
}

# Step of the install task: the license, which the data needs. A valid one is named in the data step.
install_license() {
  local n="$1" rc=0
  shift
  license_status
  if [ "$LICENSE_STATE" = "valid" ]; then
    return 0
  fi
  wiz_head "Install" "$n" "$@"
  wiz_run license_activate wizard || rc=$?
  # the outcome (a failure too) stays on the screen until a key; later goes on at once
  if [ "$rc" -ne 2 ]; then
    ui_pause_tty
  fi
}

###############################################################################
# Guided upgrade
###############################################################################

# Image tag of a running service (empty when it does not run); running_tag SERVICE all: also of its
# stopped container
running_tag() {
  local id image all=""
  if [ "${2:-}" = "all" ]; then
    all="-a"
  fi
  id="$(compose ps ${all:+"$all"} -q "$1" 2>/dev/null | head -n 1)" || id=""
  if [ -z "$id" ]; then
    return 0
  fi
  image="$("$ENGINE" container inspect --format '{{.Config.Image}}' "$id" 2>/dev/null)" || image=""
  printf '%s' "${image##*:}"
}

mongo_running_version() {
  local id
  id="$(compose ps -q mongo 2>/dev/null | head -n 1)" || id=""
  if [ -n "$id" ]; then
    "$ENGINE" exec "$id" mongod --version 2>/dev/null | sed -n 's/^db version v//p' | head -n 1 || true
  fi
}

###############################################################################
# The installation in this folder against the settings
###############################################################################

# The Catalog version of catalog-web here: of its container, running or stopped (empty when there is
# none - its image is what shows the installed version); the menu asks once per draw.
running_catalog() {
  if [ $((SECONDS - MENU_HERE_AT)) -le 2 ]; then
    printf '%s' "$MENU_CATALOG"
  elif [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ] && engine_cli && detect_compose >/dev/null 2>&1; then
    running_tag catalog-web all 2>/dev/null || true
  fi
}

# True when .env belongs to data of this stack: its data volumes exist, or the engine cannot tell. After
# a reset (option 99) or R with the data, .env names nothing that is installed.
install_data() {
  local vols
  if [ ! -f "$ENV_FILE" ]; then
    return 1
  fi
  if [ $((SECONDS - MENU_HERE_AT)) -le 2 ]; then
    [ "$MENU_DATA" = "yes" ]
    return
  fi
  if ! engine_cli || ! vols="$("$ENGINE" volume ls -q --filter "label=com.docker.compose.project=$(stack_project)" 2>/dev/null)"; then
    return 0
  fi
  [ -n "$vols" ]
}

# The installed Catalog version: the one of catalog-web's container, else the one .env names while the
# data of the stack exists (empty: neither). CATALOG_VERSION is what the next generate writes, not what
# is installed.
installed_catalog() {
  local v
  v="$(running_catalog)"
  if [ -z "$v" ] && install_data; then
    v="$(env_value CATALOG_IMAGE)"
    v="${v##*:}"
  fi
  printf '%s' "$v"
}

# tag_below A B -> true when the series of the version tag A lies below the one of B, compared as far
# as both go up to the minor version: 8.0 and 8.0.30 are not below 8.0.32 (a patch may go back within
# its series), 7.0 and 2.17.0 (against 2.19.5) are
tag_below() {
  local a="${1%%-*}" b="${2%%-*}" da db n
  if ! [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ ]] || ! [[ "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    return 1
  fi
  da="${a//[!.]/}"
  db="${b//[!.]/}"
  n=$((${#da} < ${#db} ? ${#da} + 1 : ${#db} + 1))
  if [ "$n" -gt 2 ]; then
    n=2
  fi
  version_gt "$(cut -d. -f1-"$n" <<< "$b")" "$(cut -d. -f1-"$n" <<< "$a")"
}

# The env file the installation runs with: .env, or - when the container of catalog-web has another version
# than .env names - the newest backup of .env that names that one (empty when there is none)
install_env() {
  local run v f i
  local -a baks=()
  run="$(running_catalog)"
  v="$(env_value CATALOG_IMAGE)"
  if [ -f "$ENV_FILE" ] && { [ -z "$run" ] || [ "${v##*:}" = "$run" ]; }; then
    printf '%s' "$ENV_FILE"
    return 0
  fi
  if [ -z "$run" ]; then
    return 0
  fi
  for f in "$ENV_FILE".bak-*; do
    if [ -f "$f" ]; then
      baks+=("$f")
    fi
  done
  # the names carry the time: the newest first
  for ((i = ${#baks[@]} - 1; i >= 0; i--)); do
    v="$(env_unquote "$(env_file_value CATALOG_IMAGE "${baks[i]}")")"
    if [ "${v##*:}" = "$run" ]; then
      printf '%s' "${baks[i]}"
      return 0
    fi
  done
}

# What the menu says when the settings would lower the installation in this folder (the Catalog, MongoDB,
# OpenSearch, RabbitMQ or Nginx Proxy Manager), or its files name an older Catalog than the installed one
# (empty: nothing). Option 23 takes the installation's values over.
install_note() {
  local run files inst src spec name tag
  if [ ! -f "$ENV_FILE" ]; then
    return 0
  fi
  run="$(running_catalog)"
  files="$(env_value CATALOG_IMAGE)"
  files="${files##*:}"
  inst="$run"
  if [ -z "$inst" ]; then
    if ! install_data; then
      return 0
    fi
    inst="$files"
  fi
  if is_version "$inst" && is_version "$CATALOG_VERSION" && version_gt "$inst" "$CATALOG_VERSION"; then
    printf 'The settings say Catalog %s, %s is installed' "$CATALOG_VERSION" "$inst"
  elif is_version "$run" && is_version "$files" && version_gt "$run" "$files"; then
    printf 'The files say Catalog %s, %s is installed' "$files" "$run"
  else
    src="$(install_env)"
    if [ -z "$src" ]; then
      return 0
    fi
    for spec in MONGO_TAG:mongo OPENSEARCH_TAG:opensearch RABBITMQ_TAG:rabbitmq NGINX_PROXY_MANAGER_TAG:npm; do
      name="${spec%%:*}"
      tag="$(env_unquote "$(env_file_value "$name" "$src")")"
      if tag_below "${!name}" "$tag"; then
        printf 'The settings say %s %s, %s is installed' "$(series_name "${spec#*:}")" "$(version_core "${!name}")" "$(version_core "$tag")"
        return 0
      fi
    done
  fi
}

# catalog_raise settings|files -> "NEWER INSTALLED" when CATALOG_VERSION (settings) or the env file (files)
# names a newer Catalog than the installed one (the files: than the one of its container); empty otherwise
catalog_raise() {
  local catalog inst
  if [ "$1" = "files" ]; then
    catalog="$(env_value CATALOG_IMAGE)"
    catalog="${catalog##*:}"
    inst="$(running_catalog)"
  else
    catalog="$CATALOG_VERSION"
    inst="$(installed_catalog)"
  fi
  if is_version "$catalog" && is_version "$inst" && version_gt "$catalog" "$inst"; then
    printf '%s %s' "$catalog" "$inst"
  fi
}

# What the menu says when the settings (or the files) name a newer Catalog than the installed one - a new
# download of the installer has the newest stable Catalog as its default (empty: nothing). Only U and
# option 21 upgrade with a MongoDB backup, a health check and the way back; option 23 keeps the installed one.
raise_note() {
  local v what="files"
  # the files first: option 6 would start them
  v="$(catalog_raise files)"
  if [ -z "$v" ]; then
    what="settings"
    v="$(catalog_raise settings)"
  fi
  if [ -z "$v" ]; then
    return 0
  fi
  if [ "$INTERACTIVE" = "true" ]; then
    printf 'The %s say Catalog %s, %s is installed - U or option 21 upgrades it (MongoDB backup, health check, rollback), option 23 keeps %s' "$what" "${v% *}" "${v#* }" "${v#* }"
  else
    printf "The %s say Catalog %s, %s is installed - '%s upgrade' upgrades it (MongoDB backup, health check, rollback), '%s adopt .' keeps %s" "$what" "${v% *}" "${v#* }" "$0" "$0" "${v#* }"
  fi
}

# Raising the installed Catalog is the upgrade's (U, option 21, 'upgrade'): a MongoDB backup first, then a
# health check and the way back - the new version migrates the database, which cannot go back. A step that
# would write (settings) or start (files) a newer Catalog than the installed one says so and asks first; no
# answer, or no: nothing is written or started. A job asks nothing: the step that started it asked, and
# settings it was not allowed are refused. RVC_RAISE_OK: the Catalog that may be written and started (the
# upgrade's target, a version picked in option 8, or one confirmed here - exported for the jobs started
# afterwards). upgrade_guard settings|files
upgrade_guard() {
  local v catalog inst
  v="$(catalog_raise "$1")"
  if [ -z "$v" ]; then
    return 0
  fi
  catalog="${v% *}"
  inst="${v#* }"
  if [ "$catalog" = "${RVC_RAISE_OK:-}" ] || { [ "$1" = "files" ] && [ -n "$JOB_DIR" ]; }; then
    return 0
  fi
  warn "Catalog $catalog would replace the installed $inst without a MongoDB backup, health check or rollback - it migrates the database, which cannot go back."
  if [ "$1" = "files" ]; then
    echo "  $ENV_FILE names Catalog $catalog, the catalog-web container has $inst."
  else
    echo "  The settings of $SCRIPT_NAME say Catalog $catalog (a new download of the installer has the newest one)."
  fi
  if [ "$INTERACTIVE" = "true" ]; then
    echo "  U or option 21 upgrades it with them; option 23 keeps Catalog $inst."
  else
    echo "  '$0 upgrade' upgrades it with them; '$0 adopt .' keeps Catalog $inst."
  fi
  if [ -z "$JOB_DIR" ] && confirm "Upgrade to Catalog $catalog without a backup anyway?" n; then
    export RVC_RAISE_OK="$catalog"
    return 0
  fi
  if [ "$1" = "files" ]; then
    echo "  Nothing was started."
  else
    echo "  Nothing was written."
  fi
  return 1
}

# install_differs NAME SETTING VALUE -> true when the setting NAME (SETTING) would change the VALUE the
# installation has. An empty CATALOG_HOSTNAME is automatic: the next generate keeps the host name .env has,
# so a valid one there is no difference (only a backup with another name than .env is - the license is
# bound to it); MONGO_WT_CACHE_GB of .env is derived (MONGO_CACHE_GB, else the memory), never a setting.
install_differs() {
  case "$1" in
    CATALOG_HOSTNAME)
      if [ -z "$2" ]; then
        hostname_valid "$3" && [ "$(env_hostname)" != "$3" ]
        return
      fi
      ;;
    MONGO_CACHE_GB|MONGO_WT_CACHE_GB) return 1 ;;
  esac
  [ "$2" != "$3" ]
}

# The values of the installation in this folder (its env file, see install_env) that the settings would
# change, the versions aside (a newer Catalog is raise_note's, older versions install_note's): "The settings
# differ from the installation in CATALOG_WEB_PORT, TZ" (empty: none). A new download of the installer
# with the installed Catalog version has them, or settings changed after the files were written.
install_diff_note() {
  local src name value names="" n=0
  if [ -z "$(running_catalog)" ] && ! install_data; then
    return 0
  fi
  src="$(install_env)"
  if [ -z "$src" ]; then
    return 0
  fi
  while IFS='|' read -r name value; do
    case "$name" in
      ""|CATALOG_VERSION|*_TAG) continue ;;
    esac
    if install_differs "$name" "${!name-}" "$value"; then
      n=$((n + 1))
      if [ "$n" -le 3 ]; then
        names="$names${names:+, }$name"
      fi
    fi
  done <<< "$(env_settings "$src")"
  if [ -n "$COMPOSE_PROJECT_NAME" ] && ! grep -q '^COMPOSE_PROJECT_NAME=' "$src"; then
    n=$((n + 1))
    if [ "$n" -le 3 ]; then
      names="$names${names:+, }COMPOSE_PROJECT_NAME"
    fi
  fi
  if [ "$n" -gt 3 ]; then
    names="$names and $((n - 3)) more"
  fi
  if [ "$n" -gt 0 ]; then
    printf 'The settings differ from the installation in %s' "$names"
  fi
}

# NAME|VALUE for every setting an env file holds (the passwords stay in the env file; CATALOG_IMAGE gives
# CATALOG_IMAGE_REPO and CATALOG_VERSION). ENV_SKIPPED: the keys whose values a setting cannot hold.
ENV_SKIPPED=""
env_settings() {
  local line key value names
  ENV_SKIPPED=""
  names="$(settings_pairs "$SCRIPT_PATH" | cut -d'|' -f1)"
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
        printf '%s|%s\n' CATALOG_IMAGE_REPO "${value%:*}" CATALOG_VERSION "${value##*:}"
        continue
        ;;
      CATALOG_WORKER_IMAGE)
        printf '%s|%s\n' CATALOG_WORKER_IMAGE_REPO "${value%:*}"
        continue
        ;;
    esac
    if [[ "$value" == *[\"\\\$\`]* ]]; then
      ENV_SKIPPED="$ENV_SKIPPED $key"
    elif grep -qx -- "$key" <<< "$names"; then
      printf '%s|%s\n' "$key" "$value"
    fi
  done < "$1"
}

# install_values ENV-FILE -> NAME|VALUE of the installation in this folder (a later line wins): the
# values of its env file (COMPOSE_PROJECT_NAME empty when the file has none), then the Catalog and the
# component tags of its containers
install_values() {
  local src="$1" name tag
  if [ -n "$src" ]; then
    env_settings "$src"
    if ! grep -q '^COMPOSE_PROJECT_NAME=' "$src"; then
      printf 'COMPOSE_PROJECT_NAME|\n'
    fi
  fi
  tag="$(running_catalog)"
  if [ -n "$tag" ]; then
    printf 'CATALOG_VERSION|%s\n' "$tag"
  fi
  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ] && engine_cli && detect_compose >/dev/null 2>&1; then
    for name in MONGO_TAG OPENSEARCH_TAG OPENSEARCH_DASHBOARDS_TAG RABBITMQ_TAG MINIO_TAG NGINX_PROXY_MANAGER_TAG; do
      tag="$(running_tag "$(setting_service "$name")" all)"
      if [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        printf '%s|%s\n' "$name" "$tag"
      fi
    done
  fi
}

# The values of the installation in this folder that the settings would change: INSTALL_DIFFS
# (NAME|OURS|THEIRS) and INSTALL_SPECS (NAME|THEIRS, for set_settings_atomic), from INSTALL_SRC, the env
# file of the installation (install_env; empty: only the versions of the containers are known)
INSTALL_SRC=""
INSTALL_DIFFS=()
INSTALL_SPECS=()
# NAME|VALUE|REASON of the values the automatic take-over names and leaves alone (install_diffs auto): a value
# its setting does not accept, a value that cannot be taken over safely
INSTALL_NOT=()
install_diffs() {
  local auto="${1:-}" name ours value problem
  local -A theirs=()
  INSTALL_DIFFS=()
  INSTALL_SPECS=()
  INSTALL_NOT=()
  INSTALL_SRC="$(install_env)"
  while IFS='|' read -r name value; do
    if [ -n "$name" ]; then
      theirs["$name"]="$value"
    fi
  done <<< "$(install_values "$INSTALL_SRC")"
  # the env file of an older installer has no host name: catalog-web runs with its container ID, to which a
  # license may be bound - the name of the current .env (not the installation's) would end it
  if [ "$INSTALL_SRC" != "$ENV_FILE" ] && [ -z "${theirs[CATALOG_HOSTNAME]+set}" ]; then
    value="$(license_kept_hostname "$(project_volumes)")" || value=""
    if [ -n "$value" ]; then
      theirs[CATALOG_HOSTNAME]="$value"
    fi
  fi
  while IFS='|' read -r name ours; do
    if [ -n "$name" ] && [ -n "${theirs[$name]+set}" ] && install_differs "$name" "$ours" "${theirs[$name]}"; then
      # the automatic take-over writes only what its setting accepts, and names the rest
      if [ -n "$auto" ] && ! problem="$(settings_check "$name" "${theirs[$name]}" "$ours")"; then
        INSTALL_NOT+=("$name|${theirs[$name]}|$problem")
        continue
      fi
      INSTALL_DIFFS+=("$name|$ours|${theirs[$name]}")
      INSTALL_SPECS+=("$name|${theirs[$name]}")
    fi
  done <<< "$(settings_pairs "$SCRIPT_PATH")"
  if [ -n "$auto" ]; then
    install_extras
  fi
}

# install_extra NAME OURS VALUE -> the value joins the take-over (INSTALL_DIFFS and INSTALL_SPECS)
install_extra() {
  INSTALL_DIFFS+=("$1|$2|$3")
  INSTALL_SPECS+=("$1|$3")
}

# install_no_proxy ENV-FILE -> the internal names of INTERNET_NO_PROXY, read back from the NO_PROXY of the
# containers in ENV-FILE (RN1_NO_PROXY, see net_no_proxy_containers): without what the installer adds by itself
# (localhost, the services of the stack, this server, its host name, the domain, the private ranges), and each
# name once that stands there as name and .name
install_no_proxy() {
  local list fixed item out="" rest
  local -a items=()
  list="$(env_unquote "$(env_file_value RN1_NO_PROXY "$1")")"
  fixed=",localhost,127.0.0.1,::1,mongo,minio,rabbitmq,opensearch,opensearch-dashboards,catalog-web,nginx-proxy-manager,worker-recognition-1,worker-recognition-2,worker-other,worker-search,host.docker.internal,host.containers.internal,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,"
  for item in $(net_server_names) "$(env_unquote "$(env_file_value CATALOG_HOSTNAME "$1")")" "$(env_unquote "$(env_file_value CATALOG_DOMAIN "$1")")" "$(net_host_addr)" "$(net_cloud_internal)"; do
    if [ -n "$item" ]; then
      fixed="$fixed${item,,},"
    fi
  done
  IFS=',' read -r -a items <<< "$list"
  rest=","
  for item in ${items[@]+"${items[@]}"}; do
    item="${item//[[:space:]]/}"
    if [ -n "$item" ] && [[ "$fixed" != *",${item,,},"* ]] && [[ "$rest" != *",$item,"* ]]; then
      rest="$rest$item,"
    fi
  done
  IFS=',' read -r -a items <<< "${rest#,}"
  for item in ${items[@]+"${items[@]}"}; do
    case "$item" in
      "") ;;
      .*) if [[ "$rest" != *",${item#.},"* ]]; then out="$out,$item"; fi ;;
      *) out="$out,$item" ;;
    esac
  done
  printf '%s' "${out#,}"
}

# What the automatic take-over takes over besides the settings .env names itself (INSTALL_SRC): the internet
# proxy (.env holds it as RN1_HTTPS_PROXY and RN1_NO_PROXY, which are no setting names, so the next generate
# would write none of it), the company certificate, and the cache of MongoDB (MONGO_WT_CACHE_GB, derived from
# MONGO_CACHE_GB or the memory: taken as MONGO_CACHE_GB when it is not the automatic value). The proxy the way
# net_adopt takes it from another folder: its address without the login, which stays in .proxy_login (INSTALL_LOGIN,
# written after the take-over only when that file is missing) and never goes into the script. Whatever cannot be
# taken over safely is named (INSTALL_NOT).
INSTALL_LOGIN=""
install_extras() {
  local src="$INSTALL_SRC" v p no cache auto_cache problem
  INSTALL_LOGIN=""
  if [ -z "$src" ]; then
    return 0
  fi
  if [ -z "$INTERNET_PROXY" ]; then
    v="$(env_unquote "$(env_file_value RN1_HTTPS_PROXY "$src")")"
    if [ -n "$v" ]; then
      if net_parse "$v" && [ -n "$NP_PORT" ]; then
        INSTALL_LOGIN="$NP_LOGIN"
        case "$NP_HOST" in
          host.docker.internal|host.containers.internal) NP_HOST="127.0.0.1" ;;
        esac
        p="$NP_SCHEME://$NP_HOST:$NP_PORT"
        if problem="$(settings_check INTERNET_PROXY "$p" "")"; then
          install_extra INTERNET_PROXY "" "$p"
          no="$(install_no_proxy "$src")"
          if [ -n "$no" ] && [ -z "$INTERNET_NO_PROXY" ]; then
            if problem="$(settings_check INTERNET_NO_PROXY "$no" "")"; then
              install_extra INTERNET_NO_PROXY "" "$no"
            else
              INSTALL_NOT+=("INTERNET_NO_PROXY|$no|$problem")
            fi
          fi
        else
          INSTALL_LOGIN=""
          INSTALL_NOT+=("INTERNET_PROXY|$(net_mask "$v")|$problem")
        fi
      else
        INSTALL_NOT+=("INTERNET_PROXY|$(net_mask "$v")|not a proxy address with a port (scheme://host:port)")
      fi
    fi
  fi
  # the company certificate: the installation mounts the bundle that is made of it
  if [ -z "$INTERNET_PROXY_CA_FILE" ] && grep -q "$(basename -- "$PROXY_CA_BUNDLE"):$NET_CA_MOUNT" "$COMPOSE_FILE" 2>/dev/null; then
    if problem="$(settings_check INTERNET_PROXY_CA_FILE "$PROXY_CA_COPY" "")"; then
      install_extra INTERNET_PROXY_CA_FILE "" "$PROXY_CA_COPY"
    else
      INSTALL_NOT+=("INTERNET_PROXY_CA_FILE|$PROXY_CA_COPY|$problem")
    fi
  fi
  # the cache of MongoDB: install_differs leaves it out for option 23 (an automatic value is no setting); here
  # only one that is not the automatic one - which option 1 would have set as MONGO_CACHE_GB - is taken over
  cache="$(env_unquote "$(env_file_value MONGO_WT_CACHE_GB "$src")")"
  if [ -n "$cache" ] && [ -z "${MONGO_CACHE_GB:-}" ] && mongo_cache_valid "$cache"; then
    auto_cache="$(mongo_cache_gb)"
    if [ -z "$auto_cache" ]; then
      INSTALL_NOT+=("MONGO_CACHE_GB|$cache|the memory of $ENGINE_NAME is unknown, so it is not known whether this is the automatic cache")
    elif [ "$cache" != "$auto_cache" ]; then
      install_extra MONGO_CACHE_GB "" "$cache"
    fi
  fi
}

# What the automatic take-over names and leaves alone (INSTALL_NOT), one line each
install_not_lines() {
  local spec name value reason
  for spec in ${INSTALL_NOT[@]+"${INSTALL_NOT[@]}"}; do
    IFS='|' read -r name value reason <<< "$spec"
    warn "Not taken over: $name \"$value\" - $reason"
  done
}

# The table of the values install_takeover takes over (INSTALL_DIFFS): setting, its value, the installation's
# value, where they come from, and what is left alone. The automatic take-over (auto) shows it after it worked.
# install_table "" | auto RUN FILES
install_table() {
  local auto="$1" run="$2" files="$3" spec name ours value src="$INSTALL_SRC"
  echo
  if [ -n "$auto" ]; then
    echo " This installer is a new download with its default settings; the installation"
    echo " here has other values - taken over:"
    printf '   %-30s %s\n' "" "default -> installation"
  else
    echo " The installation in this folder has other values than the settings of $SCRIPT_NAME:"
    printf '   %-30s %s\n' "" "$SCRIPT_NAME -> installation"
  fi
  for spec in "${INSTALL_DIFFS[@]}"; do
    IFS='|' read -r name ours value <<< "$spec"
    printf '   %-30s %s -> %s\n' "$name" "${ours:-(empty)}" "${value:-(empty)}"
  done
  if [ -n "$run" ] && [ -n "$src" ]; then
    echo " The versions are those of the containers, the other values come from $src."
  fi
  if [ -z "$src" ]; then
    warn "No $ENV_FILE and no backup of it names the installed Catalog $run: only the versions are known - check the other settings (option 1)."
  elif [ "$src" != "$ENV_FILE" ]; then
    echo " ($ENV_FILE names Catalog $files; $src is the newest backup that names the installed $run.)"
  fi
  if [ -n "$src" ]; then
    env_settings "$src" > /dev/null
  fi
  if [ -n "$ENV_SKIPPED" ]; then
    warn "Not taken over (special characters):$ENV_SKIPPED"
  fi
  install_not_lines
}

# Takes the values of the installation in this folder over into the settings (after a new download of
# the installer, for example): the table first, then all at once, with a backup of the installer. .env,
# docker-compose.yml and the containers stay; when the files name an older Catalog than the one that
# is installed, it then offers to put back their backups that belong to it. auto: a new download at its
# start (auto_takeover, which has run install_diffs) - nothing asked before the values are written, nothing
# said when none differs. install_takeover [interactive|cli] [auto]
install_takeover() {
  local mode="${1:-interactive}" auto="${2:-}" src run files stamp cbak check="" checked=""
  local -a diffs=() specs=()
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "Cannot change ${SCRIPT_PATH:-the installer} (not a writable file)."
    return 1
  fi
  if [ -z "$auto" ]; then
    install_diffs
  fi
  src="$INSTALL_SRC"
  if [ "${#INSTALL_DIFFS[@]}" -gt 0 ]; then
    diffs=("${INSTALL_DIFFS[@]}")
    specs=("${INSTALL_SPECS[@]}")
  elif [ -n "$auto" ]; then
    return 0
  fi
  run="$(running_catalog)"
  files="$(env_value CATALOG_IMAGE)"
  files="${files##*:}"
  if [ "${#diffs[@]}" -gt 0 ]; then
    if [ -z "$auto" ]; then
      install_table "" "$run" "$files"
      echo " Taking them over writes these values into $SCRIPT_NAME (its previous version is kept). $ENV_FILE, $COMPOSE_FILE and the containers stay as they are."
    fi
    if [ -n "$(job_running_ids)" ]; then
      err "Jobs are running (J) - take the values over when they are done."
      return 1
    fi
    if [ -z "$auto" ] && [ "$mode" != "cli" ] && ! confirm "Take over the installation's values?" y; then
      info "Cancelled - nothing was changed."
      return 0
    fi
    if ! set_settings_atomic --keep-backup "${specs[@]}"; then
      return 1
    fi
    if [ -n "$auto" ]; then
      # said only when it worked; the errors of the check come with the failure
      if check="$("$BASH" -n "$SCRIPT_PATH" 2>&1 && "$BASH" "$SCRIPT_PATH" check-settings 2>&1)"; then
        checked="yes"
      fi
    elif "$BASH" -n "$SCRIPT_PATH" && "$BASH" "$SCRIPT_PATH" check-settings; then
      checked="yes"
    fi
    if [ "$checked" != "yes" ]; then
      cat -- "$SETTINGS_BACKUP" > "$SCRIPT_PATH"
      rm -f -- "$SETTINGS_BACKUP"
      SETTINGS_BACKUP=""
      reload_settings
      if [ -n "$auto" ]; then
        # one try: a take-over that does not work is not repeated at every start - the notes and option 23 stay
        settings_unpublish
        echo
        echo " This installer is a new download with its default settings; the installation"
        echo " here has other values, but they do not fit the settings - nothing was taken over:"
        printf '%s\n' "$check" | sed 's/^/    /'
        echo " Option 23 lists the values, option 1 changes the settings."
      else
        err "The values of the installation do not fit the settings - nothing was changed in $SCRIPT_NAME."
      fi
      return 1
    fi
    if [ -n "$auto" ]; then
      install_table auto "$run" "$files"
      ok "Taken over: ${#specs[@]} value(s) - $ENV_FILE, $COMPOSE_FILE and the containers stay."
      echo "    Previous version: $(basename -- "$SETTINGS_BACKUP")"
      # the login of the proxy is in .env (and in .proxy_login while that exists): never in the script
      if [ -n "$INSTALL_LOGIN" ] && [ -n "$INTERNET_PROXY" ]; then
        if [ ! -e "$PROXY_LOGIN_FILE" ] && proxy_login_save "$INSTALL_LOGIN"; then
          echo "    Its proxy login is kept in $(basename -- "$PROXY_LOGIN_FILE") (mode 600), not in the settings."
        elif [ -z "$(proxy_login)" ]; then
          warn "Not taken over: the login of the proxy - $(basename -- "$PROXY_LOGIN_FILE") names another proxy; option 26 asks for it."
        fi
      fi
    else
      ok "Took over ${#specs[@]} value(s) of the installation (previous $SCRIPT_NAME: $SETTINGS_BACKUP)."
    fi
  fi
  if [ -n "$src" ] && [ "$src" != "$ENV_FILE" ]; then
    stamp="${src#"$ENV_FILE".bak-}"
    cbak="$COMPOSE_FILE.bak-$stamp"
    if [ ! -f "$cbak" ]; then
      cbak=""
    fi
    echo
    echo " $ENV_FILE and $COMPOSE_FILE name Catalog $files, but $run is installed: $src${cbak:+ and $cbak} belong to it."
    if [ "$mode" = "cli" ]; then
      echo "  Menu option 23 puts them back, or '$0 generate' writes them from the settings, which now fit the installation."
    elif confirm "Put $src${cbak:+ and $cbak} back? (the current files are kept as backups)" y; then
      backup_file "$ENV_FILE"
      if [ -n "$cbak" ]; then
        backup_file "$COMPOSE_FILE"
      fi
      if (umask 077 && cp -- "$src" "$ENV_FILE") && chmod 600 "$ENV_FILE" && { [ -z "$cbak" ] || cp -- "$cbak" "$COMPOSE_FILE"; }; then
        ok "$ENV_FILE${cbak:+ and $COMPOSE_FILE} name the installed Catalog $run again."
      else
        err "Cannot write $ENV_FILE${cbak:+ or $COMPOSE_FILE} - their previous versions are the newest backups."
        return 1
      fi
    else
      info "The files stay as they are - option 6 would start Catalog $files: put them back first (option 23)."
    fi
  elif [ "${#diffs[@]}" -eq 0 ]; then
    if [ -z "$src" ] && [ -n "$run" ]; then
      warn "$ENV_FILE names Catalog $files, but $run is installed, and no backup of $ENV_FILE names $run - option 2 writes the files from the settings ($CATALOG_VERSION)."
    else
      info "$WORK_DIR is the folder of $SCRIPT_NAME, and its settings match the installation - there is nothing to take over here."
    fi
  fi
}

# True when .env or the compose file here are a Catalog's (CATALOG_IMAGE in .env, the Catalog image in the compose
# file - as find_installations reads them), not another application's
catalog_files() {
  grep -q '^CATALOG_IMAGE=' "$ENV_FILE" 2>/dev/null || grep -q 'rayventory-catalog' "$COMPOSE_FILE" 2>/dev/null
}

# True when the engine and Compose answer about this stack (the volumes of its project, catalog-web's container
# by exit status): the installed versions are those of the containers, and an engine that does not answer shows
# none - running_catalog and install_data take that for 'no container' and 'perhaps data'. auto_takeover needs it.
auto_engine_answers() {
  engine_cli || return 1
  "$ENGINE" volume ls -q --filter "label=com.docker.compose.project=$(stack_project)" >/dev/null 2>&1 || return 1
  if [ -f "$COMPOSE_FILE" ]; then
    detect_compose >/dev/null 2>&1 && compose ps -a -q catalog-web >/dev/null 2>&1
  fi
}

# "yes" when auto_takeover said something in this run: the menu does not offer the same take-over (and the
# putting back of the backups it asks about) a second time at its start
AUTO_TAKEOVER_SAID=""

# A new download of the installer takes the values of the installation in its folder over by itself, at its
# start and before anything else: its settings are the published defaults (settings_pristine), which nobody
# chose. The installation: the containers of the stack or its data volumes, with the .env of a Catalog (the
# files alone, which option 99 or R leave, are none); its values are those option 23 takes over (install_diffs:
# the versions of the containers, the rest from .env or the backup of .env that names the installed Catalog).
# Settings changed on purpose - by hand, by the installer, or carried over by a self-update with other values
# than the new defaults - are never taken over, only named (option 23 takes them over): the state of a new
# download is one way (settings_unpublish). Another installer in this folder manages the installation unless
# its settings are as published too: only an installer that is pristine and alone here, or whose siblings are
# all pristine, takes over - the first of them to start; the others then name it as an installer with other
# settings. Nothing is said when no value differs. Returns 0 when it said something.
# auto_takeover interactive|cli
auto_takeover() {
  local mode="$1" sib
  if [ -z "$SCRIPT_PATH" ]; then
    return 1
  fi
  # one way: a section that is not as published any more (a hand edit, an editor) is never a new download's again
  if ! settings_pristine; then
    settings_unpublish
    return 1
  fi
  # the files of a Catalog: not another application's .env and compose file in this folder
  if [ ! -f "$ENV_FILE" ] || ! catalog_files; then
    return 1
  fi
  while IFS= read -r sib; do
    if [ -n "$sib" ] && ! settings_pristine "$sib"; then
      return 1
    fi
  done <<< "$(other_installers)"
  # an engine that does not answer shows no containers: nothing is taken over (the notes as before, and the next
  # start tries again) - the installation would be read from .env alone
  if ! auto_engine_answers; then
    return 1
  fi
  # an installation is containers of the stack or its data volumes; the files option 99 (or R) left are none, and
  # a new download then starts a new installation with its own defaults
  if [ -z "$(project_volumes)" ] && ! stack_containers_any; then
    return 1
  fi
  install_diffs auto
  # .env names another Catalog than the one that runs and no backup of it names the installed one: only the
  # versions of the containers would be known, and the generate that follows would write the defaults over every
  # other value of .env (without the take-over it says 'Nothing was written'). Nothing is taken over: the note
  # and option 23 as before, and the check is not repeated.
  if [ -z "$INSTALL_SRC" ]; then
    settings_unpublish
    return 1
  fi
  if [ "${#INSTALL_DIFFS[@]}" -eq 0 ]; then
    # nothing to take over, now or at any later start: the installation has the defaults of this download, or
    # its values are named
    settings_unpublish
    if [ "${#INSTALL_NOT[@]}" -eq 0 ]; then
      return 1
    fi
    echo
    echo " This installer is a new download with its default settings; the installation"
    echo " here has other values, but none of them could be taken over:"
    install_not_lines
    AUTO_TAKEOVER_SAID="yes"
    return 0
  fi
  if [ ! -w "$SCRIPT_PATH" ]; then
    echo
    echo " This installer is a new download with its default settings; the installation"
    echo " here has other values, but the file is not writable: nothing was taken over."
    AUTO_TAKEOVER_SAID="yes"
    return 0
  fi
  if [ -n "$(job_running_ids)" ]; then
    echo
    echo " This installer is a new download with its default settings; the installation"
    echo " here has other values - taken over at the next start, when no job runs (J)."
    AUTO_TAKEOVER_SAID="yes"
    return 0
  fi
  AUTO_TAKEOVER_SAID="yes"
  install_takeover "$mode" auto || true
  reload_settings
  return 0
}

# The step that writes these versions (settings: into the files) or starts them (files) would lower
# the installation: catalog-web below the installed Catalog (the files: below the one of its container),
# or MongoDB below the series that runs (or that its stopped container has). Prints what would happen
# (empty: nothing). downgrade_problem CATALOG MONGO-TAG settings|files
downgrade_problem() {
  local catalog="$1" mongo="$2" inst run="" what="running"
  if [ "$3" = "files" ]; then
    inst="$(running_catalog)"
  else
    inst="$(installed_catalog)"
  fi
  if is_version "$catalog" && is_version "$inst" && version_gt "$inst" "$catalog"; then
    printf 'Catalog %s would replace the installed %s; the database was migrated by %s.\n' "$catalog" "$inst" "$(cut -d. -f1-2 <<< "$inst")"
  fi
  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ] && engine_cli && detect_compose >/dev/null 2>&1; then
    run="$(mongo_running_version)"
    if [ -z "$run" ]; then
      run="$(running_tag mongo all)"
      what="installed"
    fi
  fi
  if [ -n "$run" ] && tag_below "$mongo" "$run"; then
    printf 'MongoDB %s would replace the %s %s; its data cannot go back to an older MongoDB.\n' "$mongo" "$what" "$run"
  fi
}

# Stops a step that would lower the installation (downgrade_problem); only the go-back of an upgrade
# (GUARD_ALLOW_CATALOG) or of patch updates (GUARD_ALLOW_MONGO) may, to the version it came from. The
# menu offers the take-over of the installation's values. downgrade_guard settings|files [stop]
# (stop: before the containers go whose images show the installed versions)
GUARD_ALLOW_CATALOG=""
GUARD_ALLOW_MONGO=""
downgrade_guard() {
  local problem line catalog mongo
  if [ "$1" = "files" ]; then
    catalog="$(env_value CATALOG_IMAGE)"
    catalog="${catalog##*:}"
    mongo="$(env_value MONGO_TAG)"
  else
    catalog="$CATALOG_VERSION"
    mongo="$MONGO_TAG"
  fi
  if [ -n "$GUARD_ALLOW_CATALOG" ] && [ "$catalog" = "$GUARD_ALLOW_CATALOG" ]; then
    catalog=""
  fi
  if [ -n "$GUARD_ALLOW_MONGO" ] && [ "$mongo" = "$GUARD_ALLOW_MONGO" ]; then
    mongo=""
  fi
  problem="$(downgrade_problem "$catalog" "$mongo" "$1")"
  if [ -z "$problem" ]; then
    return 0
  fi
  while IFS= read -r line; do
    err "$line"
  done <<< "$problem"
  if [ "${2:-}" = "stop" ]; then
    echo "  $ENV_FILE and $COMPOSE_FILE name older versions than the installation - nothing was stopped: its containers show the installed versions, and a later start would start these files."
  elif [ "$1" = "files" ]; then
    echo "  $ENV_FILE and $COMPOSE_FILE name older versions than the installation - nothing was started."
  else
    echo "  The settings of $SCRIPT_NAME are older than the installation (a new download of the installer has its defaults) - nothing was written."
  fi
  if [ "$INTERACTIVE" = "true" ] && [ -z "$JOB_DIR" ]; then
    if confirm "Take over the installation's values now?" y; then
      install_takeover interactive || true
    fi
  elif [ "$1" = "files" ] && [ -z "$(downgrade_problem "$CATALOG_VERSION" "$MONGO_TAG" settings)" ]; then
    echo "  The settings fit the installation: write the files from them first ($(hint 2 generate)), or put back the backups of $ENV_FILE and $COMPOSE_FILE that name the installed versions (menu option 23)."
  else
    echo "  Take the installation's values over first: menu option 23, or '$0 adopt .'."
  fi
  return 1
}

# health_pct READY SERVICES HTTP-CODE WEB-SECONDS -> how far the start is. The services fill the first
# half (they run within seconds or a minute); the second half is Catalog Web, which starts last and
# takes longest: it grows with the seconds since all services were ready, slower and slower, and only
# an answer of Catalog Web makes it 100.
health_pct() {
  local ready="$1" n="$2" secs="${4:-0}"
  if [ "$ready" -lt "$n" ]; then
    printf '%s' "$((ready * 50 / n))"
  elif [ "$3" = "200" ]; then
    printf '100'
  else
    printf '%s' "$((50 + 49 * secs / (secs + 90)))"
  fi
}

# The state of Catalog Web for the progress line: "OK", "HTTP 500" or "no answer yet"
health_web_text() {
  case "$1" in
    200) printf 'OK' ;;
    ""|000) printf 'no answer yet' ;;
    *) printf 'HTTP %s' "$1" ;;
  esac
}

# Waits until every service runs (and is healthy where it has a healthcheck) and Catalog Web answers.
# The timeout is wall-clock time: each round also spends time in the engine and curl.
stack_health() {
  local timeout="${1:-$HEALTH_TIMEOUT}" start="$SECONDS" waited=0 shown=0 svc id state health restarts bad code warned i
  local ready line web_since="" web_secs=0
  local -a services=() ids=() seen=()
  while IFS= read -r svc; do
    if [ -n "$svc" ]; then
      services+=("$svc")
      ids+=("")
      seen+=("")
    fi
  done < <(compose config --services 2>/dev/null)
  info "Health check of ${#services[@]} services (up to $((timeout / 60)) minutes)"
  while true; do
    bad=""
    warned=""
    ready=0
    for ((i = 0; i < ${#services[@]}; i++)); do
      svc="${services[$i]}"
      # the container of a service keeps its ID while it restarts: look it up once
      if [ -z "${ids[$i]}" ]; then
        ids[$i]="$(compose ps -q "$svc" 2>/dev/null | head -n 1)" || ids[$i]=""
      fi
      id="${ids[$i]}"
      if [ -z "$id" ]; then
        bad="$bad $svc(missing)"
        continue
      fi
      IFS='|' read -r state health restarts <<< "$("$ENGINE" container inspect --format '{{.State.Status}}|{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}|{{.RestartCount}}' "$id" 2>/dev/null)" || true
      if [ -z "${state:-}" ]; then
        ids[$i]=""
      fi
      if [ "${state:-}" != "running" ] || { [ "${health:-none}" != "none" ] && [ "$health" != "healthy" ]; }; then
        bad="$bad $svc(${state:-?}/${health:-?})"
      elif [ -n "${seen[$i]}" ] && [ "${restarts:-0}" != "${seen[$i]}" ]; then
        bad="$bad $svc(restarting, ${restarts}x)"
      else
        ready=$((ready + 1))
        if [ "${restarts:-0}" != "0" ]; then
          warned="$warned $svc(${restarts}x)"
        fi
      fi
      seen[$i]="${restarts:-0}"
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
    # the waiting list first: the panel and an 80-column terminal cut the end of a long line
    if [ -n "$bad" ]; then
      web_since=""
      web_secs=0
      line="waiting for:$bad $UI_SEP $ready/${#services[@]} services ready $UI_SEP Catalog Web: $(health_web_text "$code")"
    else
      web_since="${web_since:-$SECONDS}"
      web_secs=$((SECONDS - web_since))
      line="all ${#services[@]} services ready $UI_SEP Catalog Web starting, $(fmt_duration "$web_secs") ($(health_web_text "$code"))"
    fi
    if [ -n "$JOB_DIR" ]; then
      job_progress "$(health_pct "$ready" "${#services[@]}" "$code" "$web_secs")" "Health check ${waited}s: $line"
    elif [ -t 1 ]; then
      printf '\r\033[K%s' "$(ui_pad "$(printf '       %4ss  %s' "$waited" "$line")" $(($(ui_cols) - 1)))"
    elif [ $((waited / 60)) -gt "$shown" ]; then
      shown=$((waited / 60))
      echo "  ${waited}s: $line"
    fi
    sleep 5
    waited=$((SECONDS - start))
  done
}

# Writes a compressed mongodump of all databases to backups/; the password stays inside the container.
mongo_backup() {
  local dir file id
  dir="$WORK_DIR/backups"
  mkdir -p -- "$dir"
  file="$dir/mongo-$(date +%Y%m%d-%H%M%S).archive.gz"
  info "MongoDB backup -> $file"
  job_step "MongoDB backup"
  BACKUP_PARTIAL="$file"
  id="$(compose ps -q mongo 2>/dev/null | head -n 1)" || id=""
  if [ -n "$id" ] && (umask 077 && "$ENGINE" exec "$id" sh -c '
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

# Updates of the infrastructure components inside their allowed series: patch and minor steps
# (MongoDB 8.0.4 -> 8.0.32, OpenSearch 2.17 -> 2.19, RabbitMQ 3.12 -> 3.13). A version outside the
# series is only named, never changed here.
offer_patch_updates() {
  local key first tag current rec count=0 i choice tok mongo_running
  local -a keys=() froms=() tos=() picked=() toks=() specs=()
  mongo_running="$(mongo_running_version)"
  for key in "${UPD_KEYS[@]}"; do
    if [ "$key" = "npm" ] && [ "$INSTALL_NGINX_PROXY_MANAGER" != "true" ]; then
      continue
    fi
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
    rec="$(recommended_version "$key")"
    if [ -z "$current" ] || [ -z "$rec" ]; then
      continue
    fi
    if ! in_series "$key" "$current"; then
      if kind_newer "$C_KIND" "$current" "$rec"; then
        warn "$C_LABEL $(version_core "$current") runs here, outside the series ${SERIES_ALLOWED[$key]} Raynet runs with the Catalog - it is kept (never downgraded automatically)."
      else
        info "$C_LABEL $(version_core "$current") runs here. $(version_core "$rec") of the series ${SERIES_ALLOWED[$key]} is an upgrade for option 8 (Updates)."
      fi
      continue
    fi
    if kind_newer "$C_KIND" "$rec" "$current"; then
      keys+=("$key")
      froms+=("$current")
      tos+=("$rec")
      picked+=(1)
      if ! is_exact_tag "$tag" && ! in_series "$key" "$tag"; then
        warn "$C_LABEL uses the moving tag \"$tag\", which can leave the series ${SERIES_ALLOWED[$key]} with a later pull - the update below pins $(version_core "$rec")."
      fi
    elif ! is_exact_tag "$tag" && ! in_series "$key" "$tag"; then
      warn "$C_LABEL uses the moving tag \"$tag\", which can leave the series ${SERIES_ALLOWED[$key]} with a later pull - option 8 sets a version of the series."
    fi
  done
  if [ "${#keys[@]}" -eq 0 ]; then
    ok "No updates of MongoDB, OpenSearch, RabbitMQ, MinIO or Nginx Proxy Manager inside their series."
    return 0
  fi
  license_host_note
  while true; do
    echo
    ui_box "$(ui_width)" "Patch updates" "Inside the series Raynet runs: fixes and minor steps, no major versions"
    for i in "${!keys[@]}"; do
      component_info "${keys[i]}"
      printf '   %s %s  %s %s -> %s\n' "$(if [ "${picked[i]}" = 1 ]; then printf '%s' "$C_GRN$UI_ON$C_RST"; else printf '%s' "$C_DIM$UI_OFF$C_RST"; fi)" "$C_BLD$((i + 1))$C_RST" "$(ui_pad "$C_LABEL" 26)" "$(version_core "${froms[i]}")" "$C_GRN$(version_core "${tos[i]}")$C_RST"
      if [ "${keys[i]}" = "rabbitmq" ]; then
        printf '         %s\n' "$C_YLW$(rabbitmq_flags_hint "$(version_core "${froms[i]}")" "$(version_core "${tos[i]}")")$C_RST"
      fi
    done
    echo
    ui_keys "1-${#keys[@]}|toggle" "Enter|apply the selected ones" "0|skip"
    ui_ask choice "Toggle, or Enter to apply:" || choice="0"
    case "$choice" in
      "") break ;;
      0) info "No patch updates applied."; return 0 ;;
      *)
        read -r -a toks <<< "$choice"
        for tok in ${toks[@]+"${toks[@]}"}; do
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
  # the patch updates write all settings
  downgrade_guard settings || return 1
  upgrade_guard settings || return 1
  run_job "Patch updates ($count component(s))" -- patch_apply "${specs[@]}"
}

PATCH_CHANGES=()
PATCH_STAGE=""

setting_service() {
  case "$1" in
    OPENSEARCH_TAG) printf 'opensearch' ;;
    OPENSEARCH_DASHBOARDS_TAG) printf 'opensearch-dashboards' ;;
    MONGO_TAG) printf 'mongo' ;;
    RABBITMQ_TAG) printf 'rabbitmq' ;;
    MINIO_TAG) printf 'minio' ;;
    NGINX_PROXY_MANAGER_TAG) printf 'nginx-proxy-manager' ;;
  esac
}

# Worker: patch_apply NAME|OLD|NEW... - a cancel or an error before the services run goes back. Only
# the changed services are pulled: the moving tag of another one (MongoDB "8") must not move with it.
patch_apply() {
  local spec name old new svc
  local -a services=()
  require_engine || return 1
  engine_guard || return 1
  PATCH_CHANGES=("$@")
  JOB_CLEANUP="patch_cleanup"
  PATCH_STAGE="pull"
  for spec in "$@"; do
    IFS='|' read -r name old new <<< "$spec"
    set_setting "$name" "$new"
    printf -v "$name" '%s' "$new"
    svc="$(setting_service "$name")"
    if [ -n "$svc" ]; then
      services+=("$svc")
    fi
  done
  do_generate keep no-next
  job_step "Pulling the new images"
  info "Pulling the new images"
  compose pull ${services[@]+"${services[@]}"}
  PATCH_STAGE="switch"
  job_step "Recreating the changed services"
  info "Recreating the changed services"
  compose up -d --remove-orphans
  PATCH_STAGE=""
  if ! stack_health; then
    return 1
  fi
  license_recheck
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
    if [ "$name" = "MONGO_TAG" ]; then
      GUARD_ALLOW_MONGO="$old"
    fi
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
  require_engine || return 1
  engine_guard || return 1
  # option 99, or R that kept the files: no Catalog to upgrade
  if [ "$(install_kind)" = "files" ]; then
    info "Nothing is installed in this folder yet: only $ENV_FILE and $COMPOSE_FILE, no containers and no data."
    echo "  There is nothing to upgrade - option 8 picks the versions, I or option 6 installs the Catalog."
    # (the mark of a failed upgrade from before the data went: nothing to go back to)
    rm -f -- "$UPGRADE_FAILED_FILE"
    return 0
  fi
  sibling_guard || return 1
  upgrade_offer_rollback || return 0
  if ! command -v curl >/dev/null 2>&1; then
    err "curl is needed ($(pkg_hint curl))."
    return 1
  fi
  collect_updates || return $?
  installed="$(installed_catalog)"
  if [ -z "$installed" ]; then
    installed="$(env_value CATALOG_IMAGE)"
    installed="${installed##*:}"
  fi
  target="$(recommended_catalog)"
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
    # the upgrade writes all settings: older ones than the installation (a new download) are taken over first
    downgrade_guard settings || return 1
    cat <<EOF

 Upgrade plan
   1. MongoDB backup (recommended; the new version may migrate the database)
   2. Pull the images of $target while the old version still runs
   3. $ENGINE compose down (data volumes are kept)
   4. CATALOG_VERSION $installed -> $target, regenerate the files (passwords are kept)
   5. $ENGINE compose up -d
   6. Health check of all services and Catalog Web
 It runs as a background job: closing the SSH session does not stop it, and a cancel
 before step 3 changes nothing while a cancel after it goes back to $installed.
EOF
    license_host_note
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
  GUARD_ALLOW_CATALOG="$UPG_OLD"
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
  require_engine || return 1
  # a go-back returns to what was installed, not to what the settings said
  UPG_OLD="${installed:-$CATALOG_VERSION}"
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
  # the upgrade itself raises the installed Catalog (upgrade_guard)
  RVC_RAISE_OK="$target"
  do_generate keep no-next
  job_step "Pulling the images of $target"
  info "Pulling the images of $target"
  if ! compose pull catalog-web worker-recognition-1 worker-recognition-2 worker-other worker-search; then
    err "Pulling the images failed - the running version was not touched."
    net_offer_check "Pulling the images"
    upgrade_revert_settings
    UPG_STAGE=""
    return 1
  fi
  UPG_STAGE="switch"
  job_step "$ENGINE compose down"
  info "Stopping the stack ($ENGINE compose down)"
  compose down --remove-orphans
  job_step "Starting $target"
  info "Starting $target ($ENGINE compose up -d)"
  compose up -d --remove-orphans
  if stack_health && [ "$(running_tag catalog-web)" = "$target" ]; then
    UPG_STAGE=""
    ok "Catalog upgraded: $installed -> $target."
    license_recheck
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
  require_engine || return 1
  engine_guard || return 1
  rm -f -- "$UPGRADE_FAILED_FILE"
  UPG_OLD="$old"
  upgrade_revert_settings
  job_step "Starting $old"
  compose up -d --remove-orphans
  stack_health || true
  if [ -n "$backup" ]; then
    warn "If $target already migrated the database, restore the backup:"
    echo "      $ENGINE exec -i \"\$($ENGINE compose ps -q mongo)\" sh -c 'mongorestore --drop --archive --gzip -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin' < $backup"
  fi
}

###############################################################################
# Installer update
###############################################################################

# Installers from before the rename to rn1-technology-catalog-installer.sh carry this INSTALLER_URL.
LEGACY_INSTALLER_URL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/catalog.sh"
CURRENT_INSTALLER_URL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh"
# "yes" once update_installer has replaced this file with a newer version
INSTALLER_UPDATED="no"

INSTALL_SH_URL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/install.sh"

# The one-line install for a folder without an installer (install.sh downloads the installer into the current
# folder and starts it; it keeps one that is there): with curl, or with wget where curl is missing
install_line() {
  if ! command -v curl >/dev/null 2>&1 && command -v wget >/dev/null 2>&1; then
    echo "wget -nv -O- $INSTALL_SH_URL | bash"
  else
    echo "curl -fsSL $INSTALL_SH_URL | bash"
  fi
}

# cksum of FILE without its SETTINGS_PUBLISHED_SUM line, which says nothing about what the installer does
body_cksum() {
  grep -v '^SETTINGS_PUBLISHED_SUM=' "$1" | cksum
}

# Downloads the newest installer and carries the current settings over to it. The new version brings its own
# SETTINGS_PUBLISHED_SUM only when this file is still a new download (its settings as published) and the
# carried settings are the published ones of the new version too: that file is a new download of the new
# version. In every other file the line stays blank - a one-way state (settings_unpublish) - and a file that
# only differs in that line is up to date.
update_installer() {
  local mode="${1:-interactive}" tmp line name value backup new_names pairs sum url="$INSTALLER_URL" was_new="no" new_sum
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "Cannot update ${SCRIPT_PATH:-the installer} (not a writable file)."
    return 1
  fi
  if [ -n "$(job_running_ids)" ]; then
    err "Jobs are running (J) - update the installer when they are done (a job may still change the settings it carries over)."
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
  if ! head -n 1 "$tmp" | grep -q '^#!/usr/bin/env bash' || ! settings_section "$tmp" >/dev/null || ! "$BASH" -n "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    err "The download failed or is not a valid installer."
    net_offer_check "The download of the installer"
    return 1
  fi
  new_names="$(settings_pairs "$tmp" | cut -d'|' -f1)"
  new_sum="$(settings_published "$tmp")"
  if settings_pristine; then
    was_new="yes"
  fi
  sum="$(cksum < "$SCRIPT_PATH")"
  if ! pairs="$(settings_pairs "$SCRIPT_PATH")" || [ -z "$pairs" ]; then
    rm -f -- "$tmp"
    err "Cannot read the settings of $SCRIPT_NAME - not updated."
    return 1
  fi
  while IFS='|' read -r name value; do
    if [ "$name" = "INSTALLER_URL" ] && [ "$value" = "$LEGACY_INSTALLER_URL" ]; then
      continue
    fi
    if grep -qx -- "$name" <<< "$new_names" && ! set_setting "$name" "$value" "$tmp"; then
      rm -f -- "$tmp"
      err "Cannot carry the setting $name over (disk full?) - not updated."
      return 1
    fi
  done <<< "$pairs"
  # (set_setting blanked the line of the new version in tmp)
  if [ "$was_new" = "yes" ] && [ -n "$new_sum" ] && [ "$(settings_sum "$tmp")" = "$new_sum" ]; then
    settings_set_sum "$tmp" "$new_sum" || true
  fi
  if [ "$(body_cksum "$tmp")" = "$(body_cksum "$SCRIPT_PATH")" ]; then
    rm -f -- "$tmp"
    ok "The installer is up to date."
    return 0
  fi
  if [ "$INSTALLER_URL" = "$LEGACY_INSTALLER_URL" ] && [ "$(grep -v -e '^INSTALLER_URL=' -e '^SETTINGS_PUBLISHED_SUM=' "$tmp" | cksum)" = "$(grep -v -e '^INSTALLER_URL=' -e '^SETTINGS_PUBLISHED_SUM=' "$SCRIPT_PATH" | cksum)" ]; then
    rm -f -- "$tmp"
    set_setting INSTALLER_URL "$CURRENT_INSTALLER_URL" || return 1
    ok "The installer is up to date. Its update address is now $CURRENT_INSTALLER_URL."
    return 0
  fi
  if ! "$BASH" "$tmp" check-settings >/dev/null; then
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
  if [ "$(cksum < "$SCRIPT_PATH")" != "$sum" ]; then
    rm -f -- "$tmp"
    err "$SCRIPT_NAME was changed meanwhile (a job?) - not updated, run the update again."
    return 1
  fi
  if ! backup="$(script_backup)"; then
    rm -f -- "$tmp"
    err "Cannot write a backup next to $SCRIPT_PATH - nothing was changed."
    return 1
  fi
  # Write the content back instead of moving the file, so owner and mode stay.
  if ! cat -- "$tmp" > "$SCRIPT_PATH"; then
    cat -- "$backup" > "$SCRIPT_PATH" 2>/dev/null || true
    rm -f -- "$tmp"
    err "Cannot write $SCRIPT_PATH - it was restored from $backup."
    return 1
  fi
  rm -f -- "$tmp"
  INSTALLER_UPDATED="yes"
  ok "Installer updated (previous version: $backup)."
  if [ "$mode" = "interactive" ]; then
    export RVC_NOTICE="Installer updated - your settings were kept."
    exec "$BASH" "$SCRIPT_PATH" menu ${WIZ_RESUME:+"$WIZ_RESUME"}
  fi
}

###############################################################################
# Take over an existing installation
###############################################################################

project_name_of() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

# catalog_web_containers TEMPLATE -> the catalog-web containers of all projects, formatted
catalog_web_containers() {
  local ids
  ids="$("$ENGINE" ps -aq --filter "label=com.docker.compose.service=catalog-web" 2>/dev/null)" || ids=""
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    "$ENGINE" container inspect --format "$1" $ids 2>/dev/null || true
  fi
}

# Existing Catalog installations, one per line: project|folder|compose file|env file|image|status
# (the containers of the engine this folder uses, and compose files in the usual places)
find_installations() {
  local project dir cfg envf image status f d seen=" "
  if engine_cli; then
    while IFS='|' read -r project dir cfg envf image status; do
      if [ -z "$dir" ] || { [ "$dir" = "$WORK_DIR" ] || [ "$dir" -ef "$WORK_DIR" ]; } || [[ "$seen" == *" $dir "* ]]; then
        continue
      fi
      seen="$seen$dir "
      cfg="${cfg%%,*}"
      printf '%s|%s|%s|%s|%s|%s\n' "$project" "$dir" "${cfg:-$dir/docker-compose.yml}" "${envf:-$dir/.env}" "$image" "$status"
    done < <(catalog_web_containers '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{index .Config.Labels "com.docker.compose.project.environment_file"}}|{{.Config.Image}}|{{.State.Status}}')
  fi
  while IFS= read -r f; do
    d="$(dirname -- "$f")"
    if { [ "$d" = "$WORK_DIR" ] || [ "$d" -ef "$WORK_DIR" ]; } || [[ "$seen" == *" $d "* ]] || ! grep -q 'rayventory-catalog' "$f" 2>/dev/null; then
      continue
    fi
    seen="$seen$d "
    printf '%s|%s|%s|%s|%s|%s\n' "$(project_name_of "$(basename -- "$d")")" "$d" "$f" "$d/.env" "" "not running"
  done < <(find_compose_files)
}

# Compose files where installations usually live. macOS: the home folder, without the folders that
# would make macOS ask for permission (Desktop, Documents, Downloads, ...)
find_compose_files() {
  local -a roots=(/root /home /opt /srv)
  if [ "$OS_KIND" = "Darwin" ]; then
    roots=("$HOME")
  fi
  find "${roots[@]}" -maxdepth 3 \( -path "$HOME/Desktop" -o -path "$HOME/Documents" -o -path "$HOME/Downloads" \
    -o -path "$HOME/Library" -o -path "$HOME/Pictures" -o -path "$HOME/Movies" -o -path "$HOME/Music" \) -prune \
    -o \( -name docker-compose.yml -o -name docker-compose.yaml -o -name compose.yml -o -name compose.yaml \) -print 2>/dev/null || true
}

# A value of an env file as Docker Compose reads it: the text inside single or double quotes, or
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

# sibling_fits FILE... -> true when one of these installers names the installed Catalog
sibling_fits() {
  local f inst
  inst="$(installed_catalog)"
  for f in "$@"; do
    if [ -n "$inst" ] && [ "$(settings_pairs "$f" | sed -n 's/^CATALOG_VERSION|//p' | tail -n 1)" = "$inst" ]; then
      return 0
    fi
  done
  return 1
}

# takeover_settings [interactive|cli] FILE -> copies the settings of another installer in this folder
takeover_settings() {
  local mode="$1" src="$2" spec name ours theirs backup n=0 old inst lower=""
  local -a diffs=()
  mapfile -t diffs < <(settings_diff "$src")
  if [ "${#diffs[@]}" -eq 0 ]; then
    ok "$(basename -- "$src") has the same settings as $SCRIPT_NAME."
    return 0
  fi
  inst="$(installed_catalog)"
  echo
  echo " $(basename -- "$src") in this folder has other settings than $SCRIPT_NAME:"
  for spec in "${diffs[@]}"; do
    IFS='|' read -r name ours theirs <<< "$spec"
    printf '   %-30s %s -> %s\n' "$name" "${ours:-(empty)}" "${theirs:-(empty)}"
    if [ "$name" = "CATALOG_VERSION" ] && is_version "$inst" && is_version "$theirs" && version_gt "$inst" "$theirs"; then
      lower="$theirs"
    fi
  done
  if [ -n "$lower" ]; then
    err "$(basename -- "$src") names Catalog $lower, but $inst is installed - its settings would lower the installation."
    echo "  If it is no longer used, rename or remove it."
    return 1
  fi
  echo " Taking them over writes these values into $SCRIPT_NAME. $ENV_FILE, $COMPOSE_FILE and the containers stay as they are."
  if [ -n "$(job_running_ids)" ]; then
    err "Jobs are running (J) - take the settings over when they are done."
    return 1
  fi
  if [ "$mode" = "interactive" ] && ! confirm "Take over the settings of $(basename -- "$src")?" y; then
    info "Cancelled."
    return 0
  fi
  if ! backup="$(script_backup)"; then
    err "Cannot write a backup next to $SCRIPT_PATH - nothing was changed."
    return 1
  fi
  for spec in "${diffs[@]}"; do
    IFS='|' read -r name ours theirs <<< "$spec"
    if ! set_setting "$name" "$theirs"; then
      cat -- "$backup" > "$SCRIPT_PATH"
      err "Nothing was changed in $SCRIPT_NAME."
      return 1
    fi
    n=$((n + 1))
  done
  if ! "$BASH" -n "$SCRIPT_PATH" || ! "$BASH" "$SCRIPT_PATH" check-settings; then
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
    exec "$BASH" "$SCRIPT_PATH" menu
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
    # settings that would lower the installation here: its own values, unless another installer here has them
    if [ -n "$(install_note)" ] && ! sibling_fits ${sibs[@]+"${sibs[@]}"}; then
      install_takeover "$mode"
      return
    fi
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
    elif [ "$this_folder" = "true" ] || [ -n "$(raise_note)" ] || [ -n "$(install_diff_note)" ]; then
      # the installation here has other values than the settings (or an older Catalog); else installations in
      # other folders
      install_takeover "$mode"
      return
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

  if ! backup="$(script_backup)"; then
    err "Cannot write a backup next to $SCRIPT_PATH - nothing was changed."
    return 1
  fi
  backup_file "$ENV_FILE"
  backup_file "$COMPOSE_FILE"
  (umask 077 && cp -- "$envf" "$ENV_FILE")
  chmod 600 "$ENV_FILE"
  cp -- "$cfg" "$COMPOSE_FILE"

  while IFS='|' read -r key value; do
    if [ -n "$key" ]; then
      set_setting "$key" "$value"
      imported=$((imported + 1))
    fi
  done <<< "$(env_settings "$envf")"
  env_settings "$envf" > /dev/null
  skipped="$ENV_SKIPPED"
  if [ "$project" != "$(project_name_of "$(basename -- "$WORK_DIR")")" ]; then
    set_setting COMPOSE_PROJECT_NAME "$project"
    if ! grep -q '^COMPOSE_PROJECT_NAME=' "$ENV_FILE"; then
      printf '\nCOMPOSE_PROJECT_NAME=%s\n' "$project" >> "$ENV_FILE"
    fi
  fi
  if ! "$BASH" -n "$SCRIPT_PATH" || ! "$BASH" "$SCRIPT_PATH" check-settings; then
    cat -- "$backup" > "$SCRIPT_PATH"
    err "The values of $envf do not fit the settings - nothing was changed in $SCRIPT_NAME."
    return 1
  fi
  ok "Imported $imported settings from $envf; passwords kept in $ENV_FILE."
  net_adopt "$dir" "$envf"
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
    exec "$BASH" "$SCRIPT_PATH" menu
  fi
}

###############################################################################
# User interface
###############################################################################

UI_UTF="false"
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*)
    # only when the locale is installed: bash then counts the three bytes of a line character as one
    UI_PROBE="$(printf '\342\224\200')"
    if [ "${#UI_PROBE}" -eq 1 ]; then
      UI_UTF="true"
    fi
    ;;
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

# The logo above the menu (4 rows): the mark and TECHNOLOGY up to column 48, CATALOG after it
UI_LOGO_SPLIT=48
if [ "$UI_UTF" = "true" ]; then
  UI_LOGO=(
    ' ___     ___  _  _           _      _   __'
    '|  / \    |  |  /  | | |\ | / \ |  / \ /   \ /  ▄▀▀ ▄▀▄ ▀█▀ ▄▀▄ █   ▄▀▄ ▄▀▀'
    '| <   >   |  |- |  |-| | \| | | |  | | | _  |   █   █▄█  █  █▄█ █   █ █ █ ▄'
    '|  \ /    |  |_ \_ | | |  | \_/ |_ \_/ \_|  |   ▀▄▄ █ █  █  █ █ █▄▄ ▀▄▀ ▀▄█'
  )
else
  UI_LOGO=(
    ' ___     ___  _  _           _      _   __      ###  #  ###  #  #   ### ###'
    '|  / \    |  |  /  | | |\ | / \ |  / \ /   \ /  #   # #  #  # # #   # # #'
    '| <   >   |  |- |  |-| | \| | | |  | | | _  |   #   ###  #  ### #   # # # #'
    '|  \ /    |  |_ \_ | | |  | \_/ |_ \_/ \_|  |   ### # #  #  # # ### ### ###'
  )
fi

# ui_logo COLS -> the logo centred as one block (one left margin from the widest row), CATALOG in bold
ui_logo() {
  local cols="$1" line w=0 pad rest
  for line in "${UI_LOGO[@]}"; do
    if [ "${#line}" -gt "$w" ]; then
      w="${#line}"
    fi
  done
  pad=$(( (cols - w) / 2 ))
  if [ "$pad" -lt 0 ]; then
    pad=0
  fi
  for line in "${UI_LOGO[@]}"; do
    rest="${line:$UI_LOGO_SPLIT}"
    printf '%*s%s%s\n' "$pad" '' "${line:0:$UI_LOGO_SPLIT}" "${rest:+$C_BLD$rest$C_RST}"
  done
}

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
    "up to date"*|"the newest"*) sym="$UI_OK" ;;
    "update available"*|"newer available"*) sym="$UI_UP" ;;
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

# True when this process may read from the terminal: stdin and stdout are one, and it runs in the
# terminal's foreground (under "timeout" or "&" a read would stop it)
ui_foreground() {
  local stat state ppid pgrp session tty tpgid rest
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    return 1
  fi
  if ! { read -r stat < "/proc/$$/stat"; } 2>/dev/null; then
    return 0
  fi
  read -r state ppid pgrp session tty tpgid rest <<< "${stat##*) }"
  if [[ "$pgrp" =~ ^[0-9]+$ ]] && [[ "$tpgid" =~ ^-?[0-9]+$ ]] && [ "$pgrp" != "$tpgid" ]; then
    return 1
  fi
  return 0
}

ui_fancy() {
  [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ "${RVC_UI:-}" != "plain" ]
}

ui_cols() {
  local c s
  s="$(stty size 2>/dev/null)" || s=""
  c="${s##* }"
  if ! [[ "$c" =~ ^[1-9][0-9]*$ ]]; then
    c="$(tput cols 2>/dev/null)" || c=""
  fi
  printf '%s' "${c:-${COLUMNS:-80}}"
}

ui_rows() {
  local r s
  s="$(stty size 2>/dev/null)" || s=""
  r="${s%% *}"
  if ! [[ "$r" =~ ^[1-9][0-9]*$ ]]; then
    r="$(tput lines 2>/dev/null)" || r=""
  fi
  printf '%s' "${r:-${LINES:-24}}"
}

ui_repeat() {
  local s="" i
  for ((i = 0; i < $2; i++)); do
    s="$s$1"
  done
  printf '%s' "$s"
}

# Visible length of a string (ANSI color codes do not count). The codes are removed in bash, without a
# process: a job view pads many lines each time it is drawn.
ui_len() {
  local s="$1" re=$'\e''\[[0-9;]*m'
  while [[ "$s" =~ $re ]]; do
    s="${s/"${BASH_REMATCH[0]}"/}"
  done
  printf '%s' "${#s}"
}

# ui_lines TEXT COLUMNS -> the rows TEXT takes in a terminal of COLUMNS (a longer line wraps)
ui_lines() {
  local n
  n="$(ui_len "$1")"
  if [ "$n" -le "$2" ]; then
    printf '1'
  else
    printf '%s' $(((n + $2 - 1) / $2))
  fi
}

# ui_pad TEXT WIDTH -> TEXT cut or padded to exactly WIDTH visible characters
ui_pad() {
  local text="$1" width="$2" plain="$1" re=$'\e''\[[0-9;]*m'
  while [[ "$plain" =~ $re ]]; do
    plain="${plain/"${BASH_REMATCH[0]}"/}"
  done
  if [ "${#plain}" -gt "$width" ]; then
    printf '%s' "${plain:0:$((width - 1))}~"
  else
    printf '%s%*s' "$text" $((width - ${#plain})) ''
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

# The live panel of one job: its progress and the last lines of its log, wrapped at the width of the panel,
# as many as the terminal has room for. A job that has ended shows every line from its first step on (a
# line that starts with a time, e.g. of an import), however long: nothing draws over it any more.
# ui_job_panel ID STATE PCT TEXT [WIDTH] (default: the width of the terminal)
ui_job_panel() {
  local id="$1" state="$2" pct="$3" text="$4" width="${5:-}" badge n w i j first line cut word room
  local -a lines=() part=() rev=() shown=()
  # the whole width of the terminal: long log lines (compose ps, paths) wrap less
  if [ -z "$width" ]; then
    width="$(ui_cols)"
  fi
  UI_PANEL_W="$width"
  # the rest of the panel takes 5 lines, the cursor one below it
  n=$(($(ui_rows) - 6))
  if [ "$n" -lt 1 ]; then
    n=1
  fi
  w=$((width - 6))
  if [ "$w" -lt 10 ]; then
    w=10
  fi
  mapfile -t lines < <(tail -n 200 -- "$JOBS_DIR/$id/log" 2>/dev/null | grep -v '^[[:space:]]*$' | sed 's/\x1b\[[0-9;]*m//g; s/\r.*//; s/^==> //')
  if [ "${#lines[@]}" -eq 0 ]; then
    lines=("...")
  fi
  first=${#lines[@]}
  if [ "$state" != "running" ]; then
    for i in "${!lines[@]}"; do
      if [[ "${lines[i]}" =~ ^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\  ]]; then
        first="$i"
        break
      fi
    done
  fi
  # from the newest line back; a line that does not fit any more keeps its start
  for ((i = ${#lines[@]} - 1; i >= 0 && (${#rev[@]} < n || i >= first); i--)); do
    line="${lines[i]}"
    part=()
    while [ "${#line}" -gt "$w" ]; do
      # at the last space, unless that leaves less than half a line
      cut="${line:0:$w}"
      word="${cut% *}"
      if [ "${#word}" -ge $((w / 2)) ]; then
        cut="$word"
      fi
      part+=("$cut")
      line="${line:${#cut}}"
      line="${line# }"
    done
    part+=("$line")
    room=$((n - ${#rev[@]}))
    if [ "$i" -lt "$first" ] && [ "${#part[@]}" -gt "$room" ]; then
      part=("${part[@]:0:$room}")
    fi
    for ((j = ${#part[@]} - 1; j >= 0; j--)); do
      if [ "$i" -eq $((${#lines[@]} - 1)) ] && [ "$j" -eq 0 ]; then
        rev+=("$C_DIM$UI_ARROW ${part[j]}$C_RST")
      else
        rev+=("$C_DIM  ${part[j]}$C_RST")
      fi
    done
  done
  for ((i = ${#rev[@]} - 1; i >= 0; i--)); do
    shown+=("${rev[i]}")
  done
  case "$state" in
    running) badge="$C_CYN$UI_DOT running$C_RST" ;;
    done) badge="$C_GRN$UI_OK done$C_RST" ;;
    cancelled) badge="$C_YLW$UI_NO cancelled$C_RST" ;;
    unfollowed) badge="$C_YLW$UI_NO result unknown$C_RST" ;;
    *) badge="$C_RED$UI_NO $state$C_RST" ;;
  esac
  ui_box "$width" "Job #$id $UI_SEP $(cat -- "$JOBS_DIR/$id/title")" \
    "$badge   $(if [ -n "$pct" ]; then printf '%s %5s%%' "$(ui_bar "$pct" $((width - 30)))" "$pct"; else printf '%s' "${text:-working}"; fi)" \
    "$(if [ -n "$pct" ]; then printf '%s' "$text"; else printf '%s' ""; fi)" \
    "${shown[@]}" \
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
        unfollowed) lines+=("$C_YLW$UI_NO #$id $title$C_RST" "  ${C_DIM}result unknown $UI_SEP J shows the log$C_RST") ;;
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

# The job stops following a task that goes on elsewhere (an import in the Catalog): it ends without a result.
job_unfollowed() {
  if [ -n "$JOB_DIR" ] && [ -d "$JOB_DIR" ]; then
    : > "$JOB_DIR/unfollowed"
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
# until PID ends - with "until-total", until TOTAL is reached - and reports percent, size, speed and
# remaining time.
# job_watch_bytes PID SOURCE TOTAL LABEL [until-total]
job_watch_bytes() {
  local pid="$1" src="$2" total="$3" label="$4" until="${5:-}" cur last=0 t0 t1 rate=0 eta pct
  t0="$(date +%s)"
  while kill -0 "$pid" 2>/dev/null; do
    if ! cur="$(job_bytes "$src")" || [ -z "$cur" ]; then
      job_progress "" "$label" "$(if [ "${total:-0}" -gt 0 ]; then printf '%s %s ' "$(human_size "$total")" "$UI_SEP"; fi)$(fmt_duration $(( $(date +%s) - t0 )))"
      sleep 1
      continue
    fi
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
    if [ "$until" = "until-total" ] && [ "${total:-0}" -gt 0 ] && [ "$cur" -ge "$total" ]; then
      return 0
    fi
    sleep 1
  done
}

# Bytes in the MinIO volume of this stack, read on this server (fails where it cannot be read, e.g. in
# the virtual machine of macOS)
minio_volume_bytes() {
  local mp
  mp="$("$ENGINE" volume inspect --format '{{.Mountpoint}}' "$(stack_project)_minio_storage" 2>/dev/null)" || return 1
  [ -n "$mp" ] && [ -d "$mp" ] && [ -r "$mp" ] || return 1
  du -sb -- "$mp" 2>/dev/null | cut -f1
}

# import_wait_store PID SIZE BASE -> while the upload request still runs after the last byte: the
# Catalog copies the snapshot into its file storage (MinIO) and starts the import only then. Shows how
# much MinIO holds of it (BASE: its size before the upload), else the time it takes.
import_wait_store() {
  local pid="$1" size="$2" base="$3" t0 now cur pct
  t0="$SECONDS"
  info "Upload finished - the Catalog now copies the snapshot into its file storage (MinIO); the import starts when that is done."
  job_step "Storing the snapshot in the Catalog"
  while kill -0 "$pid" 2>/dev/null; do
    local_auth_renew
    now=$((SECONDS - t0))
    cur=""
    if [ -n "$base" ]; then
      cur="$(minio_volume_bytes)" || cur=""
    fi
    if [[ "$cur" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ]; then
      cur=$((cur > base ? cur - base : 0))
      pct="$(awk -v c="$cur" -v t="$size" 'BEGIN { p = c * 100 / t; if (p > 99.9) p = 99.9; printf "%.1f", p }')"
      job_progress "$pct" "Storing in the Catalog (MinIO)" "$(human_size "$cur") / $(human_size "$size") $UI_SEP $(fmt_duration "$now")"
    else
      job_progress "" "Storing in the Catalog (MinIO)" "the import starts when it is stored $UI_SEP $(fmt_duration "$now")"
    fi
    sleep 2
  done
}

# Bytes so far: a file size, "rchar:PID" (bytes read by PID) or "proc:PID:NAME" (bytes read by
# PID or by its child process NAME, e.g. scp under sshpass). Fails where the bytes a process read
# cannot be seen (no /proc/PID/io: macOS, kernels without I/O accounting).
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
  if [ ! -r /proc/self/io ]; then
    return 1
  fi
  awk '/^rchar:/ { print $2 }' "/proc/${pid:-0}/io" 2>/dev/null || echo 0
}

# Jobs of one class do not run at the same time (two of them changing the stack would collide).
job_class() {
  case "$1" in
    do_up|do_down|do_restart|do_pull|do_reset|upgrade_run|upgrade_rollback|patch_apply|install_start|remove_stack|remove_backup) printf 'stack' ;;
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
  done <<< "$(job_running_ids)"
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
  if ! mkdir -p -- "$JOBS_DIR" 2>/dev/null || [ ! -w "$JOBS_DIR" ]; then
    err "Cannot create $JOBS_DIR - is $WORK_DIR writable?"
    return 1
  fi
  chmod 700 "$JOBS_DIR"
  job_prune
  id=$(( $(cat -- "$JOBS_DIR/seq" 2>/dev/null || echo 0) + 1 ))
  while ! mkdir -- "$JOBS_DIR/$id" 2>/dev/null; do
    id=$((id + 1))
    if [ ! -d "$JOBS_DIR/$((id - 1))" ]; then
      err "Cannot create a job folder in $JOBS_DIR."
      return 1
    fi
  done
  echo "$id" > "$JOBS_DIR/seq"
  dir="$JOBS_DIR/$id"
  printf '%s\n' "$title" > "$dir/title"
  date '+%Y-%m-%d %H:%M:%S' > "$dir/started"
  echo "running" > "$dir/state"
  echo "|starting" > "$dir/progress"
  job_class "$1" > "$dir/class"
  if [ "$(cat -- "$dir/class")" = "import" ]; then mem_oom_marks > "$dir/oom-marks"; fi
  if [ -n "$secret" ]; then
    (umask 077 && printf '%s' "$secret" > "$dir/secret")
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$BASH" "$SCRIPT_PATH" __job "$id" "$@" > "$dir/log" 2>&1 < /dev/null &
  elif command -v perl >/dev/null 2>&1; then
    # macOS has no setsid: the job gets its own session (and process group for the cancel) through perl
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$BASH" "$SCRIPT_PATH" __job "$id" "$@" > "$dir/log" 2>&1 < /dev/null &
  else
    nohup "$BASH" "$SCRIPT_PATH" __job "$id" "$@" > "$dir/log" 2>&1 < /dev/null &
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
  # the root-only proxy file of a step that was running (it holds the proxy login)
  proxy_run_end
  if [ "$rc" -ne 0 ] && [ -n "$JOB_CLEANUP" ]; then
    job_progress "" "cleaning up"
    $JOB_CLEANUP || true
  fi
  if [ "$rc" -ne 0 ] && [ "$JOB_CANCELLED" != "true" ] && [ "$(cat -- "$JOB_DIR/class" 2>/dev/null)" = "import" ]; then mem_oom_report "$(cat -- "$JOB_DIR/oom-marks" 2>/dev/null)" || true; fi
  if [ "$JOB_CANCELLED" = "true" ]; then
    state="cancelled"
  elif [ "$rc" -eq 0 ]; then
    state="done"
  elif [ -f "$JOB_DIR/unfollowed" ]; then
    # the job stopped following a task that goes on elsewhere (job_unfollowed)
    state="unfollowed"
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
  local id="$1" dir="$JOBS_DIR/$1" state pct text detail key shown=0 n lines=0 last_draw=0 now cols
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
    job_rc "$id"
    return
  fi
  tput civis 2>/dev/null || true
  ui_noecho
  while true; do
    state="$(job_state "$id")"
    now="$(ui_now_ms)"
    if [ "$state" != "running" ] || { [ "$UI_HOLD_PCT" -eq 0 ] && [ $((now - last_draw)) -ge 500 ]; }; then
      IFS='|' read -r pct text detail < "$dir/progress" 2>/dev/null || { pct=""; text=""; detail=""; }
      cols="$(ui_cols)"
      if [ "$lines" -gt 0 ] && [ "$cols" != "$UI_PANEL_W" ]; then
        # another width: a narrower terminal wraps the lines of the panel again, $lines up is no longer its top
        printf '\033[H\033[2J'
      elif [ "$lines" -gt 0 ]; then
        printf '\033[%dA\033[J' "$lines"
      fi
      ui_job_panel "$id" "$state" "$pct" "$text${detail:+ $UI_SEP $detail}" "$cols"
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
  job_rc "$id"
}

# job_rc ID -> how a followed job ended: 0 done, 3 its task goes on elsewhere (job_unfollowed), 1 otherwise
job_rc() {
  case "$(job_state "$1")" in
    done) return 0 ;;
    unfollowed) return 3 ;;
    *) return 1 ;;
  esac
}

# The result of a job below its log (the live view shows the last lines of the log in its panel)
job_report() {
  local id="$1" dir="$JOBS_DIR/$1" state
  state="$(job_state "$id")"
  echo
  case "$state" in
    done) ok "Job #$id finished: $(cat -- "$dir/title")" ;;
    cancelled) warn "Job #$id was cancelled: $(cat -- "$dir/title")" ;;
    unfollowed) warn "Job #$id ended without a result: $(cat -- "$dir/title") - its last lines say why." ;;
    *) err "Job #$id $state: $(cat -- "$dir/title")" ;;
  esac
  touch "$dir/seen"
}

job_state_color() {
  case "$1" in
    running) printf '%s' "$C_CYN" ;;
    done) printf '%s' "$C_GRN" ;;
    cancelled|unfollowed) printf '%s' "$C_YLW" ;;
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
  id="$(job_start "$@")" || return 1
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
    newh="$(cron_list ${hours[@]+"${hours[@]}"})"
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
      newdow="$(cron_list ${days[@]+"${days[@]}"})"
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

# tz_offer_alignment [force|wizard] -> offers TZ = time zone of this server and converts the cron settings,
# so that the jobs keep running at the same moments. "force" asks again after an earlier "no"; in a guided
# task (wizard) 0 stops it. TZ_STOPPED: stopped, or the input ended (nothing was changed).
tz_offer_alignment() {
  local mode="${1:-}" host from name value newval spec question copy answer backup sib default="y" hint="[Y/n]"
  local -a changes=()
  TZ_CHANGED="false"
  TZ_STOPPED="false"
  reload_settings
  host="$(host_timezone)"
  if [ -z "$host" ]; then
    if [ "$mode" = "force" ]; then
      warn "The time zone of this server could not be read (timedatectl, /etc/localtime, /etc/timezone)."
    fi
    return 0
  fi
  if tz_same "$host" "$TZ"; then
    if [ "$mode" = "force" ]; then
      ok "TZ (${TZ:-empty, UTC}) is the time zone of this server."
    fi
    return 0
  fi
  if [ "$mode" != "force" ] && [ -f "$TZ_KEEP_FILE" ] && [ "$(cat -- "$TZ_KEEP_FILE")" = "$TZ|$host" ]; then
    return 0
  fi
  sib="$(conflicting_sibling)"
  if [ -n "$sib" ]; then
    if [ "$mode" = "force" ]; then
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
    TZ_STOPPED="true"
    return 0
  fi
  if [ "$mode" = "wizard" ] && [ "$answer" = "0" ]; then
    TZ_STOPPED="true"
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
  # the Catalog runs with the TZ of .env: when that is the server's, the setting only differs from the
  # installation (install_diff_note)
  if [ -f "$ENV_FILE" ] && tz_same "$host" "$(env_value TZ)"; then
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
# Domain and Nginx Proxy Manager
###############################################################################

# Nginx Proxy Manager 2.13 and newer has no default user: on its first start it creates the admin from
# INITIAL_ADMIN_EMAIL (this address when NPM_ADMIN_EMAIL is empty) and INITIAL_ADMIN_PASSWORD.
NPM_DEFAULT_EMAIL="admin@example.com"
NPM_MIN_VERSION="2.13.0"
# the domain whose proxy host has a certificate (written by npm_setup_domain)
NPM_CERT_FILE="$WORK_DIR/.domain-certificate"
# the login of the Nginx Proxy Manager admin: the address it was created with or last signed in with,
# "-" when its admin was not created from .env (no file: it is created from .env on its first start)
NPM_LOGIN_FILE="$WORK_DIR/.npm-login"
NPM_TOKEN=""
NPM_LOGIN=""
NPM_VERSION=""
NPM_SETUP=""
NPM_OUTCOME=""
NPM_CERT_ID=""
NPM_CERT_ERROR=""
DOMAIN_CHANGED="false"
DOMAIN_DNS=""
DOMAIN_DNS_NAME=""

# domain_normalize TEXT -> the host name in TEXT in lower case, without scheme, user, port, path and final dot
domain_normalize() {
  local d="$1" port_re='^(.*[^:]):[0-9]*$'
  d="${d//[[:space:]]/}"
  d="${d#*://}"
  d="${d%%[/?#]*}"
  d="${d##*@}"
  if [[ "$d" =~ $port_re ]]; then
    d="${BASH_REMATCH[1]}"
  fi
  d="${d%.}"
  printf '%s' "${d,,}"
}

# domain_valid NAME -> true for a host name in lower case: labels of 1 to 63 letters, digits and hyphens
# (no hyphen at either end), at least one dot, at most 253 characters
domain_valid() {
  local l='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?' re
  re="^(${l}\\.)+${l}\$"
  [ "${#1}" -le 253 ] && [[ "$1" =~ $re ]]
}

ip_address() {
  local v4='^[0-9.]+$' v6='^\[?[0-9A-Fa-f:.]+\]?$'
  [[ "$1" =~ $v4 ]] || { [[ "$1" == *:* ]] && [[ "$1" =~ $v6 ]]; }
}

email_valid() {
  local re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$'
  [[ "$1" =~ $re ]]
}

# True for names Let's Encrypt gives no certificate for (special-use and private suffixes)
domain_private() {
  case "$1" in
    localhost|*.local|*.lan|*.internal|*.localhost|*.test|*.example|*.invalid) return 0 ;;
  esac
  return 1
}

# True when Let's Encrypt takes EMAIL as contact address: not at example.com, example.net or example.org
# (it refuses exactly these three), not at a local name
npm_email_ok() {
  local d="${1##*@}"
  d="${d,,}"
  if ! email_valid "$1" || domain_private "$d"; then
    return 1
  fi
  case "$d" in
    example.com|example.net|example.org) return 1 ;;
  esac
}

# The login Nginx Proxy Manager creates its admin with on its first start (INITIAL_ADMIN_EMAIL of .env)
npm_login_email() {
  local e
  e="$(env_value NPM_ADMIN_EMAIL)"
  printf '%s' "${e:-$NPM_DEFAULT_EMAIL}"
}

# The login of the Nginx Proxy Manager admin as far as the installer knows it: the address it was created
# with or last signed in with (before generating: the one of the settings); empty when its admin was not
# created from .env (or .env has no password)
npm_known_login() {
  local m=""
  if [ ! -f "$ENV_FILE" ]; then
    printf '%s' "${NPM_ADMIN_EMAIL:-$NPM_DEFAULT_EMAIL}"
    return 0
  fi
  if [ -z "$(env_value NPM_ADMIN_PASSWORD)" ]; then
    return 0
  fi
  m="$(cat -- "$NPM_LOGIN_FILE" 2>/dev/null)" || m=""
  case "$m" in
    -) ;;
    "") npm_login_email ;;
    *) printf '%s' "$m" ;;
  esac
}

# npm_login_note ADDRESS|-|start|reset -> the login marker. ADDRESS: signed in with it; -: the admin is not
# the one of .env; start (after compose up): a new Nginx Proxy Manager has created its admin from
# .env; reset (a new NPM password in .env): an existing admin keeps its old password, a new one gets the new
npm_login_note() {
  local vols
  case "$1" in
    start)
      if [ ! -f "$NPM_LOGIN_FILE" ] && [ "$(env_value INSTALL_NGINX_PROXY_MANAGER)" = "true" ] && [ -n "$(env_value NPM_ADMIN_PASSWORD)" ] \
        && grep -qF 'INITIAL_ADMIN_PASSWORD: "${NPM_ADMIN_PASSWORD}"' "$COMPOSE_FILE" 2>/dev/null; then
        printf '%s\n' "$(npm_login_email)" > "$NPM_LOGIN_FILE" 2>/dev/null || true
      fi
      ;;
    reset)
      vols="$(project_volumes)"
      if grep -q '_npm_data$' <<< "$vols"; then
        printf '%s\n' "-" > "$NPM_LOGIN_FILE" 2>/dev/null || true
      else
        rm -f -- "$NPM_LOGIN_FILE"
      fi
      ;;
    *) printf '%s\n' "$1" > "$NPM_LOGIN_FILE" 2>/dev/null || true ;;
  esac
}

# domain_resolve NAME -> the addresses of NAME in DNS (A and AAAA records), one per line
domain_resolve() {
  if [ "$OS_KIND" = "Darwin" ]; then
    dscacheutil -q host -a name "$1" 2>/dev/null | awk '$1 == "ip_address:" || $1 == "ipv6_address:" { print $2 }' | sort -u || true
    return 0
  fi
  # ahostsv6 also lists the IPv4 addresses as ::ffff:a.b.c.d
  {
    getent ahostsv4 "$1" 2>/dev/null || true
    getent ahostsv6 "$1" 2>/dev/null || true
  } | awk '$1 !~ /^::ffff:/ { print $1 }' | sort -u
}

# The addresses of this server, one per line
local_addresses() {
  if [ "$OS_KIND" = "Darwin" ]; then
    ifconfig 2>/dev/null | awk '$1 == "inet" || $1 == "inet6" { sub(/%.*/, "", $2); print $2 }' | sort -u || true
    return 0
  fi
  {
    hostname -I 2>/dev/null || true
    ip -o addr show 2>/dev/null || true
  } | awk '/^[0-9]+: / { sub(/\/.*/, "", $4); print $4; next } { for (i = 1; i <= NF; i++) print $i }' | sort -u
}

# domain_checks NAME -> says whether Let's Encrypt can give NAME a certificate and where its DNS records
# point; never fails. DOMAIN_DNS: ok (an address of this server), other (another address, fine behind
# NAT), missing, loopback (only in /etc/hosts of this server) or unknown.
domain_checks() {
  local d="$1" addrs mine a here="" other="" loop="" v6=""
  DOMAIN_DNS="unknown"
  DOMAIN_DNS_NAME="$d"
  if domain_private "$d"; then
    warn "Let's Encrypt gives no certificates for names ending in .${d##*.}: the Catalog"
    echo "  answers over HTTP there (or with an own certificate in Nginx Proxy Manager)."
  fi
  if [ "$OS_KIND" != "Darwin" ] && ! command -v getent >/dev/null 2>&1; then
    warn "The DNS records of $d cannot be checked here (getent is missing)."
    return 0
  fi
  addrs="$(domain_resolve "$d")"
  if [ -z "$addrs" ]; then
    DOMAIN_DNS="missing"
    warn "$d is not in DNS yet (no A or AAAA record)."
    echo "  Point it to the public address of this server - Let's Encrypt needs that."
    return 0
  fi
  mine="$(local_addresses)"
  while IFS= read -r a; do
    case "$a" in
      "") ;;
      127.*|::1) loop="$loop $a" ;;
      *)
        if grep -qxF -- "$a" <<< "$mine"; then
          here="$here $a"
        else
          other="$other $a"
          if [[ "$a" == *:* ]]; then
            v6="$v6 $a"
          fi
        fi
        ;;
    esac
  done <<< "$addrs"
  if [ -n "$here" ]; then
    DOMAIN_DNS="ok"
    ok "$d points to this server (${here# })."
    if [ -n "$v6" ]; then
      warn "It also has the IPv6 address${v6} (AAAA record), which is not on this server:"
      echo "  Let's Encrypt tries IPv6 first - correct or remove that record."
    fi
  elif [ -n "$other" ]; then
    DOMAIN_DNS="other"
    info "$d points to ${other# } - not an address of this server, which is fine behind NAT"
    echo "  (a public address that forwards ports 80 and 443 here)."
  else
    DOMAIN_DNS="loopback"
    warn "$d points to${loop} only on this server (/etc/hosts):"
    echo "  its public DNS record cannot be checked from here."
  fi
}

# domain_baseurl DOMAIN true|false -> BASEURL of catalog-web: https behind Nginx Proxy Manager (http for a
# name Let's Encrypt gives no certificate), otherwise http on the port of Catalog Web
domain_baseurl() {
  if [ "$2" = "true" ] && domain_private "$1"; then
    printf 'http://%s' "$1"
  elif [ "$2" = "true" ]; then
    printf 'https://%s' "$1"
  elif [ "$CATALOG_WEB_PORT" = "80" ]; then
    printf 'http://%s' "$1"
  else
    printf 'http://%s:%s' "$1" "$CATALOG_WEB_PORT"
  fi
}

# domain_apply DOMAIN true|false EMAIL -> writes CATALOG_DOMAIN, INSTALL_NGINX_PROXY_MANAGER, NPM_ADMIN_EMAIL
# and the BASEURL that follows from them into this script in one go (all or nothing), after checking them
# together (EMAIL in lower case). Without a domain BASEURL stays, unless it came from the old domain.
# DOMAIN_CHANGED: true when a setting changed.
domain_apply() {
  local domain="$1" npm="$2" email="${3,,}" base="$BASEURL" problem dir copy backup spec name out=""
  local -a changes=()
  DOMAIN_CHANGED="false"
  case "$npm" in
    true|false) ;;
    *)
      err "INSTALL_NGINX_PROXY_MANAGER is \"true\" or \"false\" (is \"$npm\") - nothing was changed."
      return 1
      ;;
  esac
  for spec in "CATALOG_DOMAIN|$domain" "NPM_ADMIN_EMAIL|$email"; do
    if [ -n "${spec#*|}" ] && ! problem="$(settings_check "${spec%%|*}" "${spec#*|}" "")"; then
      err "${spec%%|*}: $problem"
      return 1
    fi
  done
  if [ -n "$domain" ]; then
    base="$(domain_baseurl "$domain" "$npm")"
  elif [ -n "$CATALOG_DOMAIN" ]; then
    case "$BASEURL" in
      "https://$CATALOG_DOMAIN"|"http://$CATALOG_DOMAIN"|"http://$CATALOG_DOMAIN:"*) base="http://catalog-web" ;;
    esac
  fi
  for spec in "CATALOG_DOMAIN|$domain" "INSTALL_NGINX_PROXY_MANAGER|$npm" "NPM_ADMIN_EMAIL|$email" "BASEURL|$base"; do
    name="${spec%%|*}"
    if [ "${!name}" != "${spec#*|}" ]; then
      changes+=("$spec")
    fi
  done
  if [ "${#changes[@]}" -eq 0 ]; then
    return 0
  fi
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "${SCRIPT_PATH:-This installer} cannot be changed (not a writable file) - nothing was changed."
    return 1
  fi
  if ! dir="$(mktemp -d)" || [ ! -d "$dir" ]; then
    err "Cannot create a temporary folder (TMPDIR) - nothing was changed."
    return 1
  fi
  copy="$dir/$SCRIPT_NAME"
  if ! cp -p -- "$SCRIPT_PATH" "$copy"; then
    rm -rf -- "$dir"
    err "Cannot copy $SCRIPT_NAME - nothing was changed."
    return 1
  fi
  for spec in "${changes[@]}"; do
    if ! set_setting "${spec%%|*}" "${spec#*|}" "$copy"; then
      rm -rf -- "$dir"
      err "Nothing was changed."
      return 1
    fi
  done
  if ! "$BASH" -n "$copy" 2>/dev/null || ! out="$("$BASH" "$copy" check-settings 2>&1)"; then
    rm -rf -- "$dir"
    err "Nothing was changed - the settings do not work together:"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | sed 's/^/    /'
    fi
    return 1
  fi
  if ! backup="$(script_backup)"; then
    rm -rf -- "$dir"
    err "Cannot write next to $SCRIPT_PATH - nothing was changed."
    return 1
  fi
  if ! cat -- "$copy" > "$SCRIPT_PATH"; then
    rm -rf -- "$dir"
    cat -- "$backup" > "$SCRIPT_PATH" 2>/dev/null || true
    err "Cannot write $SCRIPT_PATH. If it is damaged, the previous version is $backup."
    return 1
  fi
  rm -rf -- "$dir"
  rm -f -- "$backup"
  for spec in "${changes[@]}"; do
    printf -v "${spec%%|*}" '%s' "${spec#*|}"
    ok "${spec%%|*} = \"${spec#*|}\""
  done
  if [ -f "$NPM_CERT_FILE" ] && [ "$(cat -- "$NPM_CERT_FILE" 2>/dev/null)" != "$CATALOG_DOMAIN" ]; then
    rm -f -- "$NPM_CERT_FILE"
  fi
  DOMAIN_CHANGED="true"
}

# The API of Nginx Proxy Manager on this server
npm_api() {
  printf 'http://127.0.0.1:%s/api' "$(setting NPM_ADMIN_PORT)"
}

# npm_call METHOD PATH OUTFILE [BODYFILE [SECONDS]] -> HTTP status of the Nginx Proxy Manager API ("000"
# when it does not answer). The token goes to curl through its stdin config.
npm_call() {
  local method="$1" path="$2" out="$3" body="${4:-}" max="${5:-60}" code=""
  local -a data=()
  if [ -n "$body" ]; then
    data=(-H 'Content-Type: application/json' --data-binary "@$body")
  fi
  code="$(if [ -n "$NPM_TOKEN" ]; then
      printf 'header = "Authorization: Bearer %s"\n' "$NPM_TOKEN"
    fi | curl -sS -K - -X "$method" -H 'Accept: application/json' --connect-timeout 5 --max-time "$max" \
      -o "$out" -w '%{http_code}' ${data[@]+"${data[@]}"} "$(npm_api)$path" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# npm_json QUERY FILE [DOMAIN] -> a value of an answer of the Nginx Proxy Manager API (with jq or python3):
#   ready  VERSION|SETUP when its status is OK     token  the token ("2fa" for a two-factor challenge)
#   id     the id                                  error  the error message
#   reason why a certificate failed (the Detail lines of certbot, else the first lines)
#   host DOMAIN  ID|CERTIFICATE_ID|FORWARD_HOST|FORWARD_PORT of the first proxy host of DOMAIN
#   cert DOMAIN  ID|EXPIRES_ON of every Let's Encrypt certificate of DOMAIN
npm_json() {
  local q="$1" f="$2" d="${3:-}"
  if command -v jq >/dev/null 2>&1; then
    case "$q" in
      ready) jq -r 'if type == "object" and .status == "OK" then "\(.version.major // 0).\(.version.minor // 0).\(.version.revision // 0)|\(.setup)" else empty end' "$f" ;;
      token) jq -r 'if type != "object" then empty elif .requires_2fa == true then "2fa" else (.token // empty) end' "$f" ;;
      id) jq -r 'if type == "object" then (.id // empty | tostring) else empty end' "$f" ;;
      error) jq -r 'if type == "object" then (.error.message // empty) else empty end' "$f" ;;
      reason)
        jq -r 'if type == "object" then
            ([.error.message // empty | select(. != "Internal Error")]
              + [(.debug.stack // [])[]? | strings | select(test("^\\s+at ") | not) | select(test("\\S")) | sub("^[A-Za-z]*Error: "; "")])
            | ((map(select(test("Detail:"))) | if length > 0 then . else empty end) // .[0:3])
            | .[] | sub("^\\s+"; "")
          else empty end' "$f"
        ;;
      host)
        jq -r --arg d "$d" 'if type == "array" then
            ([.[] | select((.domain_names // []) | map(ascii_downcase == $d) | any)] | .[0] // empty
              | [.id, (.certificate_id // 0), (.forward_host // ""), (.forward_port // "")] | map(tostring) | join("|"))
          else empty end' "$f"
        ;;
      cert)
        jq -r --arg d "$d" 'if type == "array" then
            (.[] | select(.provider == "letsencrypt" and ((.domain_names // []) | map(ascii_downcase == $d) | any))
              | [.id, (.expires_on // "")] | map(tostring) | join("|"))
          else empty end' "$f"
        ;;
    esac 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, re, sys
q, d = sys.argv[1], sys.argv[3]
try:
    data = json.load(open(sys.argv[2]))
except Exception:
    sys.exit(0)
obj = isinstance(data, dict)
def text(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)
def has(h):
    return d in [str(n).lower() for n in (h.get("domain_names") or [])]
out = []
if q == "ready" and obj and data.get("status") == "OK":
    v = data.get("version") or {}
    out.append("%s.%s.%s|%s" % (v.get("major", 0), v.get("minor", 0), v.get("revision", 0), text(data.get("setup"))))
elif q == "token" and obj:
    out.append("2fa" if data.get("requires_2fa") is True else text(data.get("token")))
elif q == "id" and obj:
    out.append(text(data.get("id")))
elif q == "error" and obj:
    out.append(text((data.get("error") or {}).get("message")))
elif q == "reason" and obj:
    msg = text((data.get("error") or {}).get("message"))
    lines = [msg] if msg and msg != "Internal Error" else []
    for l in (data.get("debug") or {}).get("stack") or []:
        if isinstance(l, str) and l.strip() and not re.match(r"\s+at ", l):
            lines.append(re.sub(r"^[A-Za-z]*Error: ", "", l))
    detail = [l for l in lines if "Detail:" in l]
    out = [l.strip() for l in (detail or lines[:3])]
elif q == "host" and isinstance(data, list):
    for h in data:
        if isinstance(h, dict) and has(h):
            out.append("|".join(text(v) for v in (h.get("id"), h.get("certificate_id") or 0, h.get("forward_host") or "", h.get("forward_port") or "")))
            break
elif q == "cert" and isinstance(data, list):
    for c in data:
        if isinstance(c, dict) and c.get("provider") == "letsencrypt" and has(c):
            out.append("%s|%s" % (text(c.get("id")), text(c.get("expires_on"))))
for l in out:
    if l:
        print(l)
' "$q" "$f" "$d" 2>/dev/null | tr -d '\r' || true
  else
    return 2
  fi
}

# npm_wait_ready [SECONDS] -> waits until Nginx Proxy Manager answers on its API. NPM_VERSION: its version,
# NPM_SETUP: true when it has a user. Fails when it does not run or answer, or is older than 2.13.0.
npm_wait_ready() {
  local timeout="${1:-180}" start="$SECONDS" out code="" ready="" id
  NPM_VERSION=""
  NPM_SETUP=""
  id="$(compose ps -q nginx-proxy-manager 2>/dev/null | head -n 1)" || id=""
  if [ -z "$id" ]; then
    err "Nginx Proxy Manager does not run - start the stack first ($(hint 6 up))."
    return 1
  fi
  out="$(mktemp)"
  while true; do
    code="$(npm_call GET / "$out" "" 10)"
    if [ "$code" = "200" ]; then
      ready="$(npm_json ready "$out")"
    fi
    if [ -n "$ready" ] || [ $((SECONDS - start)) -ge "$timeout" ]; then
      break
    fi
    sleep 3
  done
  rm -f -- "$out"
  if [ -z "$ready" ]; then
    err "Nginx Proxy Manager does not answer on $(npm_api)/ (HTTP $code after ${timeout}s) - see its log ($(hint 10 "logs nginx-proxy-manager"))."
    return 1
  fi
  NPM_VERSION="${ready%%|*}"
  NPM_SETUP="${ready#*|}"
  if version_gt "$NPM_MIN_VERSION" "$NPM_VERSION"; then
    err "Nginx Proxy Manager $NPM_VERSION is too old: the automatic setup needs $NPM_MIN_VERSION or newer (its API changed in 2.13)."
    echo "  Use a newer image (NGINX_PROXY_MANAGER_TAG \"2\" or \"latest\"; $(hint 8 updates) shows the versions), write the files and start"
    echo "  the stack again - or set up the proxy host by hand in Nginx Proxy Manager (http://$(host_ip):$(setting NPM_ADMIN_PORT))."
    return 1
  fi
}

# npm_token -> NPM_TOKEN and NPM_LOGIN: logs in as the admin user of .env (NPM_ADMIN_EMAIL, NPM_ADMIN_PASSWORD),
# trying the login it last had first. A user created while NPM_ADMIN_EMAIL was empty has the address
# admin@example.com. The login marker records the result.
npm_token() {
  local pw id="" tried="" body out code="" t="" known=""
  NPM_TOKEN=""
  NPM_LOGIN=""
  pw="$(env_value NPM_ADMIN_PASSWORD)"
  if [ -z "$pw" ]; then
    err "$ENV_FILE has no NPM_ADMIN_PASSWORD - write the files ($(hint 2 generate)) and apply them ($(hint 6 up)) first."
    return 1
  fi
  known="$(cat -- "$NPM_LOGIN_FILE" 2>/dev/null)" || known=""
  body="$(mktemp)"
  out="$(mktemp)"
  for id in "${known#-}" "$(env_value NPM_ADMIN_EMAIL)" "$NPM_ADMIN_EMAIL" "$NPM_DEFAULT_EMAIL"; do
    id="${id,,}"
    if [ -z "$id" ] || [[ " $tried " == *" $id "* ]]; then
      continue
    fi
    tried="$tried $id"
    (umask 077 && printf '{"identity":"%s","secret":"%s"}' "$(json_escape "$id")" "$(json_escape "$pw")" > "$body")
    code="$(npm_call POST /tokens "$out" "$body")"
    t=""
    if [ "$code" = "200" ]; then
      t="$(npm_json token "$out")"
    fi
    if [ -n "$t" ] || [ "$code" = "000" ]; then
      break
    fi
  done
  rm -f -- "$body" "$out"
  pw=""
  if [ "$t" = "2fa" ]; then
    err "The Nginx Proxy Manager user $id has two-factor authentication - set up the proxy host by hand ($(hint 15 info) shows how)."
    return 1
  fi
  if [ -z "$t" ]; then
    if [ "$code" = "000" ]; then
      err "Nginx Proxy Manager does not answer on $(npm_api)/tokens."
    else
      err "Nginx Proxy Manager refused the login of $ENV_FILE (${tried# }; HTTP $code)."
      echo "  Its admin user was not created by this installer (it was set up on its own page or before the password"
      echo "  was in $ENV_FILE), or its password was changed there. Sign in at http://$(host_ip):$(setting NPM_ADMIN_PORT)"
      echo "  and set up the proxy host by hand ($(hint 15 info) shows how)."
      case "$code" in
        400|401|403) npm_login_note - ;;
      esac
    fi
    return 1
  fi
  NPM_TOKEN="$t"
  NPM_LOGIN="$id"
  npm_login_note "$id"
}

# npm_set_email ADDRESS -> gives the logged-in Nginx Proxy Manager user this address: its login and the
# contact address of Let's Encrypt
npm_set_email() {
  local body out code msg
  body="$(mktemp)"
  out="$(mktemp)"
  printf '{"email":"%s"}' "$(json_escape "$1")" > "$body"
  code="$(npm_call PUT /users/me "$out" "$body")"
  msg="$(npm_json error "$out")"
  rm -f -- "$body" "$out"
  if [ "$code" != "200" ]; then
    warn "The Nginx Proxy Manager login stays $NPM_LOGIN: changing it to $1 failed (HTTP $code${msg:+: $msg})."
    return 1
  fi
  ok "The Nginx Proxy Manager login is now $1 (was $NPM_LOGIN)."
  NPM_LOGIN="$1"
  npm_login_note "$1"
}

# npm_existing_certificate DOMAIN -> the id of a Let's Encrypt certificate of DOMAIN in Nginx Proxy Manager
# that is valid for at least one more day (empty when there is none)
npm_existing_certificate() {
  local out code id exp t now best=""
  out="$(mktemp)"
  code="$(npm_call GET /nginx/certificates "$out")"
  if [ "$code" = "200" ]; then
    now="$(date +%s)"
    while IFS='|' read -r id exp; do
      if [ -z "$id" ]; then
        continue
      fi
      t="$(date -d "$exp" +%s 2>/dev/null)" || t=""
      if [ -z "$t" ] || [ "$t" -gt $((now + 86400)) ]; then
        best="$id"
      fi
    done < <(npm_json cert "$out" "$1")
  fi
  rm -f -- "$out"
  printf '%s' "$best"
}

# npm_request_certificate DOMAIN -> NPM_CERT_ID of a new Let's Encrypt certificate (HTTP challenge on port
# 80), or NPM_CERT_ERROR and the likely cause. One attempt: Let's Encrypt allows 5 failures per hour.
npm_request_certificate() {
  local d="$1" body out code
  NPM_CERT_ID=""
  NPM_CERT_ERROR=""
  body="$(mktemp)"
  out="$(mktemp)"
  printf '{"provider":"letsencrypt","domain_names":["%s"],"meta":{"dns_challenge":false}}' "$(json_escape "$d")" > "$body"
  info "Requesting a Let's Encrypt certificate for $d (Let's Encrypt checks http://$d/; this can take a minute)..."
  code="$(npm_call POST /nginx/certificates "$out" "$body" 600)"
  if [[ "$code" == 20[01] ]]; then
    NPM_CERT_ID="$(npm_json id "$out")"
  fi
  if [ -z "$NPM_CERT_ID" ] || ! [[ "$NPM_CERT_ID" =~ ^[0-9]+$ ]]; then
    NPM_CERT_ID=""
    NPM_CERT_ERROR="$(npm_json reason "$out")"
  fi
  rm -f -- "$body" "$out"
  if [ -n "$NPM_CERT_ID" ]; then
    ok "Let's Encrypt certificate #$NPM_CERT_ID for $d."
    return 0
  fi
  err "Let's Encrypt gave no certificate for $d (HTTP $code)."
  if [ -n "$NPM_CERT_ERROR" ]; then
    printf '%s\n' "$NPM_CERT_ERROR" | sed 's/^/    /'
  fi
  case "$NPM_CERT_ERROR" in
    *NXDOMAIN*|*"DNS problem"*|*"no valid A records"*)
      echo "  DNS: $d has no A/AAAA record yet, or a wrong one - point it to the public address of this server." ;;
    *[Tt]imeout*|*[Cc]onnection\ refused*|*"Fetching http"*)
      echo "  Port 80: Let's Encrypt could not reach http://$d/ - open port 80 in the firewall or security group, or forward it here." ;;
    *[Uu]nauthorized*|*"Invalid response"*|*" 404"*)
      echo "  Another server answered for http://$d/ - $d points elsewhere, or port 80 is forwarded to another machine." ;;
    *"too many"*|*[Rr]ate*[Ll]imit*)
      echo "  Let's Encrypt limits failed attempts (5 per hour) - wait an hour before the next try." ;;
    *[Ee]mail*|*invalidContact*)
      echo "  Let's Encrypt refused the e-mail address $NPM_LOGIN - set a real one ($(hint 24 domain))." ;;
    *)
      echo "  Usual causes: $d does not point to this server yet (DNS), or port 80 is not reachable from the internet." ;;
  esac
  return 1
}

# npm_host_body DOMAIN CERTIFICATE_ID -> the proxy host to Catalog Web; HTTPS forced only with a
# certificate (id 0: none). No size limit and long timeouts for uploads and the hubs of the Catalog.
npm_host_body() {
  local forced="false"
  if [ "$2" != "0" ]; then
    forced="true"
  fi
  printf '{"domain_names":["%s"],"forward_scheme":"http","forward_host":"catalog-web","forward_port":80,"certificate_id":%s,"ssl_forced":%s,"http2_support":true,"block_exploits":true,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":"%s"}' \
    "$(json_escape "$1")" "$2" "$forced" 'client_max_body_size 0;\nproxy_request_buffering off;\nproxy_read_timeout 3600s;\nproxy_send_timeout 3600s;'
}

# npm_probe DOMAIN https|http -> says whether Nginx Proxy Manager answers for DOMAIN (asked on 127.0.0.1,
# so DNS and NAT play no part)
npm_probe() {
  local d="$1" scheme="$2" port url code="" i
  if [ "$scheme" = "https" ]; then
    port="$(setting NPM_HTTPS_PORT)"
  else
    port="$(setting NPM_HTTP_PORT)"
  fi
  url="$scheme://$d"
  if { [ "$scheme" = "https" ] && [ "$port" != "443" ]; } || { [ "$scheme" = "http" ] && [ "$port" != "80" ]; }; then
    url="$url:$port"
  fi
  for i in 1 2 3; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 20 --resolve "$d:$port:127.0.0.1" "$url/" 2>/dev/null)" || true
    if [ "$code" = "200" ]; then
      ok "$url/ answers through Nginx Proxy Manager (checked on this server)."
      return 0
    fi
    if [ "$i" -lt 3 ]; then
      sleep 2
    fi
  done
  warn "$url/ does not answer through Nginx Proxy Manager on this server yet (HTTP ${code:-000}) - check its proxy host (http://$(host_ip):$(setting NPM_ADMIN_PORT))."
}

# npm_outcome DOMAIN https|http [WHY] -> NPM_OUTCOME, the certificate marker and the closing lines
npm_outcome() {
  if [ "$2" = "https" ]; then
    printf '%s\n' "$1" > "$NPM_CERT_FILE" || true
    NPM_OUTCOME="https"
    npm_probe "$1" https
    ok "The Catalog: https://$1 - Nginx Proxy Manager renews the certificate (port 80 must stay open for that)."
  else
    rm -f -- "$NPM_CERT_FILE"
    NPM_OUTCOME="http"
    npm_probe "$1" http
    warn "The Catalog: http://$1 - no certificate yet: ${3:-not requested}."
    if domain_private "$1"; then
      echo "  HTTPS needs an own certificate, added in the admin page of Nginx Proxy Manager."
    else
      echo "  When $1 points to this server and port 80 is open, $(hint 24 domain) requests it (Let's Encrypt allows 5 failed attempts per hour)."
    fi
  fi
}

# npm_setup_domain [ask|yes] -> sets up Nginx Proxy Manager for CATALOG_DOMAIN over its API on this server:
# login with NPM_ADMIN_EMAIL / NPM_ADMIN_PASSWORD of .env, a Let's Encrypt certificate first (ask: after a
# question; one attempt), then the proxy host to catalog-web - with the certificate, or for HTTP only when
# there is none. Running it again reuses the host and the certificate and adds only what is missing; a
# proxy host of the domain to another target is not touched (failed).
# NPM_OUTCOME: https, http (proxy host without certificate) or failed (then it returns 1).
npm_setup_domain() {
  local mode="${1:-yes}" d="${CATALOG_DOMAIN:-}" email host="" hid="0" hcert="0" fhost="" fport="" cert="" why="" out body code msg default
  NPM_OUTCOME="failed"
  if [ "$INSTALL_NGINX_PROXY_MANAGER" != "true" ] || [ -z "$d" ]; then
    NPM_OUTCOME=""
    info "Nothing to set up in Nginx Proxy Manager (it is off, or CATALOG_DOMAIN is empty)."
    return 0
  fi
  require_files || return 1
  require_engine || return 1
  if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    err "Setting up Nginx Proxy Manager needs jq or python3 ($(pkg_hint jq))."
    return 1
  fi
  info "Setting up Nginx Proxy Manager for $d..."
  npm_wait_ready || return 1
  if [ "$NPM_SETUP" = "false" ]; then
    err "Nginx Proxy Manager $NPM_VERSION has no admin user yet: its container started without INITIAL_ADMIN_EMAIL and INITIAL_ADMIN_PASSWORD."
    echo "  Write the files again ($(hint 2 generate)) and apply them ($(hint 6 up)) - it then creates the user of $ENV_FILE."
    return 1
  fi
  npm_token || return 1
  ok "Logged in to Nginx Proxy Manager $NPM_VERSION as $NPM_LOGIN."
  if email_valid "$NPM_ADMIN_EMAIL" && [ "${NPM_ADMIN_EMAIL,,}" != "${NPM_LOGIN,,}" ]; then
    npm_set_email "${NPM_ADMIN_EMAIL,,}" || true
  fi
  email="$NPM_LOGIN"

  out="$(mktemp)"
  code="$(npm_call GET /nginx/proxy-hosts "$out")"
  if [ "$code" = "200" ]; then
    host="$(npm_json host "$out" "$d")"
  fi
  msg="$(npm_json error "$out")"
  rm -f -- "$out"
  if [ "$code" != "200" ]; then
    err "Nginx Proxy Manager did not list its proxy hosts (HTTP $code${msg:+: $msg})."
    return 1
  fi
  if [ -n "$host" ]; then
    IFS='|' read -r hid hcert fhost fport <<< "$host"
    if [ "$fhost" != "catalog-web" ] || [ "$fport" != "80" ]; then
      err "The proxy host of $d (#$hid) in Nginx Proxy Manager forwards to $fhost:$fport, not to catalog-web:80 - it is left as it is."
      echo "  Point it to catalog-web, port 80, or delete it there (http://$(host_ip):$(setting NPM_ADMIN_PORT)); then $(hint 24 domain) sets it up."
      return 1
    fi
    if [ "${hcert:-0}" != "0" ]; then
      ok "The proxy host of $d (#$hid) has a certificate already."
      npm_outcome "$d" https
      return 0
    fi
  fi

  cert="$(npm_existing_certificate "$d")"
  if [ -n "$cert" ]; then
    ok "Nginx Proxy Manager has a Let's Encrypt certificate for $d already (#$cert) - it is used."
  elif domain_private "$d"; then
    why="Let's Encrypt gives no certificates for names ending in .${d##*.}"
  elif ! npm_email_ok "$email"; then
    why="Let's Encrypt needs a real e-mail address, the Nginx Proxy Manager login is $email ($(hint 24 domain) asks for one)"
  else
    if [ "$DOMAIN_DNS_NAME" != "$d" ]; then
      domain_checks "$d"
    fi
    if [ "$(setting NPM_HTTP_PORT)" != "80" ]; then
      warn "Let's Encrypt checks http://$d/ on port 80, and Nginx Proxy Manager uses port $(setting NPM_HTTP_PORT) - port 80 must be forwarded to it."
    fi
    if [ "$mode" = "ask" ]; then
      default="y"
      if [ "$DOMAIN_DNS" = "missing" ]; then
        default="n"
      fi
      if ! confirm "Request a Let's Encrypt certificate for $d now? It must point to this server, with port 80 open from the internet." "$default"; then
        why="not requested"
      fi
    elif [ "$DOMAIN_DNS" = "missing" ]; then
      why="$d is not in DNS yet"
    fi
    if [ -z "$why" ]; then
      if npm_request_certificate "$d"; then
        cert="$NPM_CERT_ID"
      else
        why="Let's Encrypt refused it (see above)"
      fi
    fi
  fi

  body="$(mktemp)"
  out="$(mktemp)"
  if [ "${hid:-0}" = "0" ]; then
    npm_host_body "$d" "${cert:-0}" > "$body"
    code="$(npm_call POST /nginx/proxy-hosts "$out" "$body" 120)"
    hid="$(npm_json id "$out")"
    msg="$(npm_json error "$out")"
    rm -f -- "$body" "$out"
    if [[ "$code" != 20[01] ]] || [ -z "$hid" ]; then
      err "Nginx Proxy Manager did not create the proxy host of $d (HTTP $code${msg:+: $msg})."
      if [ -n "$cert" ]; then
        echo "  The certificate #$cert stays in Nginx Proxy Manager; the next try ($(hint 24 domain)) uses it."
      fi
      return 1
    fi
    if [ -n "$cert" ]; then
      ok "Proxy host #$hid: $d to catalog-web:80, certificate #$cert, HTTPS forced."
    else
      ok "Proxy host #$hid: $d to catalog-web:80, HTTP only."
    fi
  elif [ -n "$cert" ]; then
    printf '{"certificate_id":%s,"ssl_forced":true,"http2_support":true}' "$cert" > "$body"
    code="$(npm_call PUT "/nginx/proxy-hosts/$hid" "$out" "$body" 120)"
    msg="$(npm_json error "$out")"
    rm -f -- "$body" "$out"
    if [ "$code" != "200" ]; then
      err "Nginx Proxy Manager did not add certificate #$cert to the proxy host of $d (HTTP $code${msg:+: $msg})."
      echo "  The certificate stays in Nginx Proxy Manager; the next try ($(hint 24 domain)) uses it."
      return 1
    fi
    ok "Proxy host #$hid of $d: certificate #$cert added, HTTPS forced."
  else
    rm -f -- "$body" "$out"
    ok "The proxy host of $d exists (#$hid, HTTP only)."
  fi
  if [ -n "$cert" ]; then
    npm_outcome "$d" https
  else
    npm_outcome "$d" http "$why"
  fi
}

# Option 24 and 'domain [NAME]': the domain name of the Catalog and HTTPS. Asks for the domain (Enter keeps
# it, - removes it), for Nginx Proxy Manager when it is off, and for the e-mail address when Let's Encrypt
# has none; checks the DNS records and saves the settings. An installation gets new files and a restart
# when they changed (files that differ for another reason only after a question, never without a
# terminal); then Nginx Proxy Manager is set up (proxy host, certificate).
domain_menu() {
  local given="${1:-}" cur="$CATALOG_DOMAIN" d="" npm="$INSTALL_NGINX_PROXY_MANAGER" email="$NPM_ADMIN_EMAIL" input prompt problem="" rc mode="yes"
  local login="" busy="" p yn="y" apply="false"
  echo "${C_BLD}Domain and HTTPS${C_RST}"
  printf '  %-7s %s\n' "Domain" "${cur:-none - the Catalog answers on the address of this server}"
  if [ "$npm" = "true" ]; then
    login="$(npm_known_login)"
    printf '  %-7s %s\n' "Proxy" "Nginx Proxy Manager (HTTPS with Let's Encrypt), login ${login:-as set up in it}"
  else
    printf '  %-7s %s\n' "Proxy" "none - Catalog Web answers on port $CATALOG_WEB_PORT"
  fi
  echo
  if [ -n "$cur" ]; then
    prompt="Domain name (Enter keeps $cur, - removes it): "
  else
    prompt="Domain name, e.g. catalog.example.com (Enter: none, the address of the server is used): "
  fi
  while true; do
    if [ -n "$given" ]; then
      input="$given"
    elif ! read -r -p "$prompt" input; then
      echo
      info "Cancelled - nothing was changed."
      return 0
    fi
    problem=""
    case "$input" in
      "") d="$cur" ;;
      -) d="" ;;
      *)
        d="$(domain_normalize "$input")"
        if [ -z "$d" ]; then
          problem="Give a host name, e.g. catalog.example.com (- removes the domain)."
        fi
        ;;
    esac
    if [ -z "$problem" ] && { [ -z "$d" ] || problem="$(settings_check CATALOG_DOMAIN "$d" "")"; }; then
      break
    fi
    err "$problem"
    if [ -n "$given" ]; then
      return 1
    fi
  done
  if [ -n "$d" ] && [ "$npm" != "true" ]; then
    for p in "$NPM_HTTP_PORT" "$NPM_HTTPS_PORT" "$NPM_ADMIN_PORT"; do
      if wiz_port_used "$p"; then
        busy="$busy, $p"
      fi
    done
    if [ -n "$busy" ]; then
      warn "In use on this server: port ${busy#, } - Nginx Proxy Manager cannot start while another program listens there."
      echo "  Stop that program, or give Nginx Proxy Manager other ports (menu option 1: NPM_HTTP_PORT, NPM_HTTPS_PORT,"
      echo "  NPM_ADMIN_PORT; Let's Encrypt then needs port 80 forwarded to NPM_HTTP_PORT)."
      yn="n"
    fi
    if confirm "Put Nginx Proxy Manager in front, for HTTPS with a Let's Encrypt certificate (ports $NPM_HTTP_PORT, $NPM_HTTPS_PORT and $NPM_ADMIN_PORT)?" "$yn"; then
      npm="true"
    fi
  fi
  if [ -n "$d" ] && [ "$npm" = "true" ] && ! npm_email_ok "$email"; then
    if [ -n "$email" ]; then
      warn "Let's Encrypt does not take $email as contact address."
    fi
    while true; do
      if ! read -r -p "E-mail address for Let's Encrypt and the Nginx Proxy Manager login (Enter: none, no certificate): " input; then
        echo
        input=""
      fi
      input="${input//[[:space:]]/}"
      input="${input,,}"
      if [ -z "$input" ]; then
        warn "Without an e-mail address Let's Encrypt gives no certificate - $d gets HTTP only for now."
        break
      fi
      if ! problem="$(settings_check NPM_ADMIN_EMAIL "$input" "")"; then
        err "$problem"
      elif ! npm_email_ok "$input"; then
        err "Let's Encrypt does not take addresses at ${input##*@} - give a real one."
      else
        email="$input"
        break
      fi
    done
  fi
  if [ -n "$d" ]; then
    echo
    domain_checks "$d"
  fi
  echo
  domain_apply "$d" "$npm" "$email" || return 1
  if [ "$DOMAIN_CHANGED" != "true" ]; then
    info "The settings stay as they are."
  fi
  if [ -n "$cur" ] && [ "$cur" != "$d" ] && [ "$npm" = "true" ]; then
    info "The proxy host of $cur stays in Nginx Proxy Manager - delete it there if it is no longer needed."
  fi
  if [ ! -f "$ENV_FILE" ]; then
    if [ -n "$d" ] && [ "$npm" = "true" ]; then
      info "Nothing is installed here yet: the installation uses these settings, then $(hint 24 domain) sets up Nginx Proxy Manager."
    else
      info "Nothing is installed here yet: the installation uses these settings."
    fi
    return 0
  fi
  if [ "$DOMAIN_CHANGED" = "true" ]; then
    apply="true"
  elif settings_stale; then
    echo
    info "$ENV_FILE and $COMPOSE_FILE do not match the settings (changed settings or manual edits)."
    if { [ "$INTERACTIVE" = "true" ] || [ -t 0 ]; } && confirm "Write them again (passwords kept, backups made) and apply them?" y; then
      apply="true"
    else
      info "The files stay as they are - $(hint 2 generate) writes them again, $(hint 6 up) applies them."
    fi
  fi
  if [ "$apply" = "true" ]; then
    echo
    do_generate keep no-next || return 1
    if [ "$GENERATE_CANCELLED" = "true" ]; then
      return 0
    fi
    echo
    if [ "$INTERACTIVE" = "true" ]; then
      rc=0
      WIZ_QUIET_ACCESS="yes" run_job "Start / apply changes" -- do_up || rc=$?
      if [ "$rc" -eq 3 ]; then
        info "When the job has finished, $(hint 24 domain) sets up Nginx Proxy Manager."
        return 0
      fi
      if [ "$rc" -ne 0 ]; then
        err "The stack did not start (see above) - Nginx Proxy Manager was not set up."
        return 1
      fi
    else
      WIZ_QUIET_ACCESS="yes" do_up
    fi
  fi
  if [ -n "$d" ] && [ "$npm" = "true" ]; then
    echo
    if [ "$INTERACTIVE" = "true" ] || [ -t 0 ]; then
      mode="ask"
    fi
    npm_setup_domain "$mode" || return 1
  elif [ -n "$d" ]; then
    ok "The Catalog answers on $(domain_baseurl "$d" false) once $d points to this server."
  else
    ok "The Catalog answers on http://$(host_ip):$(setting CATALOG_WEB_PORT)."
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
  if ! engine_setting_ok; then
    err "CONTAINER_ENGINE must be \"podman\", \"docker\", \"colima\" (only on macOS) or empty (is \"$CONTAINER_ENGINE\")."
    problems=$((problems + 1))
  fi
  for name in $(port_settings); do
    value="${!name}"
    if ! [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$value" -gt 65535 ]; then
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
  for name in CATALOG_DOMAIN NPM_ADMIN_EMAIL CATALOG_HOSTNAME INTERNET_PROXY INTERNET_NO_PROXY INTERNET_PROXY_CA_FILE INTERNET_PROXY_PAC; do
    if [ -n "${!name:-}" ] && ! value="$(settings_check "$name" "${!name}" "")"; then
      err "$name: $value"
      problems=$((problems + 1))
    fi
  done
  if [ -z "$CATALOG_VERSION" ]; then
    err "CATALOG_VERSION must not be empty."
    problems=$((problems + 1))
  fi
  if ! [[ "${SYNC_MAX_UPLOAD:-}" =~ ^[1-9][0-9]{0,6}(GB|MB|KB)$ ]] && ! [[ "${SYNC_MAX_UPLOAD:-}" =~ ^[1-9][0-9]{0,14}$ ]]; then
    err "SYNC_MAX_UPLOAD must be a size like 32GB, 8000MB or a number of bytes (is \"${SYNC_MAX_UPLOAD:-}\")."
    problems=$((problems + 1))
  fi
  if ! [[ "${HEALTH_TIMEOUT:-}" =~ ^[1-9][0-9]{0,5}$ ]]; then
    err "HEALTH_TIMEOUT must be a number of seconds, e.g. 600 (is \"${HEALTH_TIMEOUT:-}\")."
    problems=$((problems + 1))
  fi
  if [ -n "${MONGO_CACHE_GB:-}" ] && ! mongo_cache_valid "$MONGO_CACHE_GB"; then
    err "MONGO_CACHE_GB must be GB like 4 or 2.5 (at least 0.25) or empty (is \"$MONGO_CACHE_GB\")."
    problems=$((problems + 1))
  fi
  for name in ENV_FILE COMPOSE_FILE; do
    value="${!name}"
    if [ -z "$value" ] || [[ "$value" =~ [[:space:]/] ]] || [ "$value" = "." ] || [ "$value" = ".." ] || [ "$value" = "$SCRIPT_NAME" ]; then
      err "$name must be a plain file name in this folder, not $SCRIPT_NAME (is \"$value\")."
      problems=$((problems + 1))
    fi
  done
  if [ "$ENV_FILE" = "$COMPOSE_FILE" ]; then
    err "ENV_FILE and COMPOSE_FILE must be two different files (both are \"$ENV_FILE\")."
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
CATALOG_DOMAIN=${CATALOG_DOMAIN}

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
MONGO_WT_CACHE_GB=${MONGO_WT_CACHE_GB}

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
CATALOG_HOSTNAME=${CATALOG_HOSTNAME}
CATALOG_LICENSE_PATH=${CATALOG_LICENSE_PATH}

# OpenSearch
OPENSEARCH_HEAP=${OPENSEARCH_HEAP}
OPENSEARCH_URL=${OPENSEARCH_URL}
OPENSEARCH_DASHBOARDS_PORT=${OPENSEARCH_DASHBOARDS_PORT}

# Nginx Proxy Manager
NPM_HTTP_PORT=${NPM_HTTP_PORT}
NPM_HTTPS_PORT=${NPM_HTTPS_PORT}
NPM_ADMIN_PORT=${NPM_ADMIN_PORT}
NPM_ADMIN_EMAIL=${NPM_ADMIN_EMAIL}
NPM_ADMIN_PASSWORD=${NPM_ADMIN_PASSWORD}
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
  if mongo_rseq_workaround "$MONGO_TAG"; then
    printf '\n# MongoDB 8+ on Linux 6.19 to 7.0.x (SERVER-121912): glibc registers rseq, TCMalloc uses per-thread caches\nMONGO_GLIBC_TUNABLES=glibc.pthread.rseq=1\n' >> "$ENV_FILE"
  fi
  if [ -n "$COMPOSE_PROJECT_NAME" ]; then
    printf '\nCOMPOSE_PROJECT_NAME=%s\n' "$COMPOSE_PROJECT_NAME" >> "$ENV_FILE"
  fi
  net_env_block >> "$ENV_FILE"
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
      INITIAL_ADMIN_EMAIL: "${NPM_ADMIN_EMAIL:-admin@example.com}"
      INITIAL_ADMIN_PASSWORD: "${NPM_ADMIN_PASSWORD}"
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
    restart: always
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
    restart: always
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
    command: ["--wiredTigerCacheSizeGB", "${MONGO_WT_CACHE_GB:-1}"]
    restart: always
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
EOF
    if mongo_rseq_workaround "$MONGO_TAG"; then
      echo '      GLIBC_TUNABLES: "${MONGO_GLIBC_TUNABLES:-glibc.pthread.rseq=1}"'
    fi
    cat <<'EOF'

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
      HOME: /root
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
    hostname: ${CATALOG_HOSTNAME}
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
EOF
    # X-Forwarded-Proto of Nginx Proxy Manager counts only from these networks; without the setting only
    # 172.16.0.0/12, and Podman gives compose networks 10.89.x.x
    if [ "${INSTALL_NGINX_PROXY_MANAGER}" = "true" ]; then
      cat <<'EOF'
      ForwardedHeaders__KnownNetworks__0: "10.0.0.0/8"
      ForwardedHeaders__KnownNetworks__1: "172.16.0.0/12"
      ForwardedHeaders__KnownNetworks__2: "192.168.0.0/16"
EOF
    fi
    cat <<'EOF'

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
    restart: always
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
    restart: always
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
  # the Catalog images exist only for amd64: Apple Silicon runs them with Rosetta
  if [ "$OS_KIND" = "Darwin" ] && [ "$(engine_arch)" = "arm64" ]; then
    sed -i 's#^    image: ${CATALOG\(_WORKER\)\{0,1\}_IMAGE}$#&\n    platform: linux/amd64#' "$COMPOSE_FILE"
  fi
  net_compose_edit "$COMPOSE_FILE"
}

# do_generate [ask|keep|new] [show-next|no-next]
#   ask  : menu - if the env file exists, ask whether to keep its passwords
#   keep : keep the passwords of the existing env file (or of its newest backup)
#   new  : always generate new passwords
do_generate() {
  local mode="${1:-ask}" next="${2:-show-next}" choice var value pw_file="" volumes sib npm_new="false" host host_from old_host bad_host named kept lost
  GENERATE_CANCELLED="false"
  reload_settings
  tz_name_warning

  if ! check_settings; then
    err "Fix the settings at the top of $SCRIPT_NAME first (menu option 1 opens them)."
    return 1
  fi
  if ! downgrade_guard settings || ! upgrade_guard settings; then
    GENERATE_CANCELLED="true"
    return 1
  fi

  # the host name of catalog-web in the env file (else in its newest backup). Files without one keep the
  # one of a licensed catalog-web (below), which only the engine can tell: nothing is written without it
  host_from="$ENV_FILE"
  if [ ! -f "$host_from" ]; then
    host_from="$(newest_env_backup)"
  fi
  old_host=""
  if [ -n "$host_from" ] && [ -f "$host_from" ]; then
    old_host="$(env_hostname "$host_from")"
  fi
  if [ -z "$CATALOG_HOSTNAME" ] && [ -n "$host_from" ] && [ -z "$old_host" ] && ! engine_answers; then
    err "$ENGINE_NAME does not answer - $(engine_down_hint)."
    echo "  Nothing was written: catalog-web gets a fixed host name now, and a licensed"
    echo "  Catalog keeps the one its container has, which only $ENGINE_NAME can tell."
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
          warn "MongoDB, RabbitMQ and Nginx Proxy Manager store their passwords in their data volumes on the first start."
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
      warn "Generating NEW passwords. MongoDB, RabbitMQ and Nginx Proxy Manager keep the original ones in their data volumes,"
      warn "so the new passwords only work after those volumes are removed ($ENGINE compose down -v)."
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
        warn "There is no $ENV_FILE (and no backup of it), but $ENGINE_NAME volumes of this stack already exist."
        warn "MongoDB, RabbitMQ and Nginx Proxy Manager keep their original passwords in these volumes - NEW passwords will not work with them."
        warn "Restore the old $ENV_FILE, or remove the volumes if the old data is not needed:"
        warn "  $ENGINE volume rm ${volumes//$'\n'/ }"
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
  for var in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS NPM_ADMIN_PASSWORD; do
    value=""
    if [ "$mode" = "keep" ]; then
      value="$(ENV_FILE="$pw_file" env_value "$var")"
      if [ -z "$value" ]; then
        warn "$var not found in $pw_file - generating a new one."
      fi
    fi
    if [ -z "$value" ]; then
      value="$(rand32)"
      if [ "$var" = "NPM_ADMIN_PASSWORD" ]; then
        npm_new="true"
      fi
    fi
    printf -v "$var" '%s' "$value"
  done
  # the host name of catalog-web stays as it was (the license is bound to it). Files that get one for the
  # first time keep the one a licensed catalog-web has, else they get the name of this server; another
  # one (CATALOG_HOSTNAME) needs a license for the new name.
  host="$(catalog_hostname "$host_from")"
  bad_host=""
  if [ -z "$CATALOG_HOSTNAME" ] && [ -n "$old_host" ] && ! hostname_valid "$old_host"; then
    bad_host="$old_host"
  fi
  named="$CATALOG_HOSTNAME"
  volumes=""
  if [ "$old_host" != "$host" ]; then
    volumes="$(project_volumes)"
  fi
  kept=""
  lost=""
  if [ -z "$named" ] && [ -z "$old_host" ]; then
    if kept="$(license_kept_hostname "$volumes")"; then
      host="${kept:-$host}"
    else
      lost="$kept"
      kept=""
    fi
  fi
  local CATALOG_HOSTNAME="$host"
  # the cache of MongoDB for the memory of the engine; while the engine does not answer, the one of before
  local MONGO_WT_CACHE_GB
  MONGO_WT_CACHE_GB="$(mongo_cache_gb)"
  if [ -z "$MONGO_WT_CACHE_GB" ] && [ -n "$host_from" ] && [ -f "$host_from" ]; then
    MONGO_WT_CACHE_GB="$(sed -n 's/^MONGO_WT_CACHE_GB=//p' "$host_from" | tail -n 1)"
  fi

  echo "Writing ${ENV_FILE}..."
  write_env_file
  echo "Writing ${COMPOSE_FILE}..."
  write_compose_file
  net_ca_bundle_write || true
  if [ "$npm_new" = "true" ]; then
    npm_login_note reset
  fi
  chmod 600 "$ENV_FILE"

  echo "Created $ENV_FILE and $COMPOSE_FILE in $WORK_DIR"
  echo
  show_credentials
  echo "  Nginx enabled  : $INSTALL_NGINX_PROXY_MANAGER"
  echo "  Host name      : $host (catalog-web; the license is bound to it)"
  if [ -n "$MONGO_WT_CACHE_GB" ]; then
    echo "  MongoDB cache  : $MONGO_WT_CACHE_GB GB ($(if [ -n "${MONGO_CACHE_GB:-}" ]; then printf 'MONGO_CACHE_GB'; else printf 'automatic, for the memory of %s' "$ENGINE_NAME"; fi))"
  else
    echo "  MongoDB cache  : set at the start ($ENGINE_NAME does not answer yet)"
  fi
  echo
  if [ -n "$bad_host" ]; then
    warn "CATALOG_HOSTNAME in $host_from is no usable host name: $bad_host"
    echo "  catalog-web gets $host instead (letters, digits and -, no dots)."
  fi
  if [ -n "$kept" ]; then
    ok "catalog-web keeps its host name $host: the Catalog's license"
    echo "  is bound to it (CATALOG_HOSTNAME in $ENV_FILE)."
    echo
  elif [ -z "$lost" ] && [ -z "$old_host" ] && [ -z "$named" ] && [ -n "$volumes" ]; then
    info "catalog-web now has the fixed host name $host (CATALOG_HOSTNAME)."
    echo "  The Catalog binds its license to it and holds no valid license now: none is"
    echo "  lost. After the next start, $(hint 25 license) activates one for this name."
    echo
  elif [ -n "$lost" ] || { [ "$old_host" != "$host" ] && [ -n "$volumes" ] && [ "$host" != "$(web_container_hostname)" ]; }; then
    # a name catalog-web does not have yet (with the one it has, the license stays valid), or one it
    # cannot keep
    if [ -n "$lost" ]; then
      warn "catalog-web gets another host name: $host (before: $lost)."
      echo "  $lost cannot be a fixed host name (letters, digits and -, at most 63"
      echo "  characters, no service name). The Catalog binds its license to its host"
      echo "  name: after the next start it needs a license for $host."
    elif [ -z "$old_host" ]; then
      warn "catalog-web now has the fixed host name $host (CATALOG_HOSTNAME)."
      echo "  The Catalog binds its license to its host name, which changed with every new"
      echo "  container so far: after the next start it needs a license for $host."
    else
      warn "catalog-web gets another host name: $host (before: $old_host)."
      echo "  The Catalog binds its license to its host name: after the next start it"
      echo "  needs a license for $host."
    fi
    echo "  The license activated before does not fit the new name. $(hint 25 license)"
    echo "  shows the hardware ID: the order number fetches a license for it from"
    echo "  Raynet, or Raynet makes a license file or e-mail text for it."
    echo
  fi

  if [ "$next" = "show-next" ]; then
    if [ "$INTERACTIVE" = "true" ]; then
      echo "Next steps: 3/4) review the files (optional), 5) validate, 6) start the stack."
    else
      echo "Next steps:"
      echo "  $0 validate    ($ENGINE compose config)"
      echo "  $0 up          ($ENGINE compose up -d)"
    fi
  fi
}

###############################################################################
# Actions
###############################################################################

show_credentials() {
  local login
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
  if [ "$(env_value INSTALL_NGINX_PROXY_MANAGER)" = "true" ]; then
    login="$(npm_known_login)"
    if [ -n "$login" ]; then
      echo "  NPM login      : $login"
      echo "  NPM password   : $(env_value NPM_ADMIN_PASSWORD)"
    else
      echo "  NPM login      : as set up in Nginx Proxy Manager (its admin was not created from $ENV_FILE)"
    fi
  fi
  if [ -n "$(proxy_login)" ]; then
    echo "  Proxy login    : $(proxy_login_user) (password saved in $(basename -- "$PROXY_LOGIN_FILE"), mode 600)"
  fi
}

show_access_info() {
  local addr npm domain main="" login
  addr="$(host_ip)"
  npm="$(setting INSTALL_NGINX_PROXY_MANAGER)"
  domain="$(setting CATALOG_DOMAIN)"

  echo "${C_BLD}URLs${C_RST}"
  if [ -n "$domain" ]; then
    if [ "$npm" = "true" ]; then
      if [ "$(cat -- "$NPM_CERT_FILE" 2>/dev/null)" = "$domain" ]; then
        main="https://$domain"
      elif domain_private "$domain"; then
        main="http://$domain   (no Let's Encrypt for .${domain##*.} names)"
      else
        main="http://$domain   (no certificate yet - $(hint 24 domain))"
      fi
    elif [ "$(setting CATALOG_WEB_PORT)" = "80" ]; then
      main="http://$domain"
    else
      main="http://$domain:$(setting CATALOG_WEB_PORT)"
    fi
    printf '  %-24s %s\n' "Catalog Web" "$main"
  fi
  printf '  %-24s http://%s:%s\n' "Catalog Web (direct)" "$addr" "$(setting CATALOG_WEB_PORT)"
  if [ "$npm" = "true" ]; then
    login="$(npm_known_login)"
    if [ -n "$login" ]; then
      printf '  %-24s http://%s:%s   login %s, password: %s\n' "Nginx Proxy Manager" "$addr" "$(setting NPM_ADMIN_PORT)" \
        "$login" "$(hint 14 credentials)"
    else
      printf '  %-24s http://%s:%s   login as set up in Nginx Proxy Manager\n' "Nginx Proxy Manager" "$addr" "$(setting NPM_ADMIN_PORT)"
    fi
  fi
  printf '  %-24s http://%s:%s\n' "RabbitMQ management" "$addr" "$(setting RABBITMQ_UI_PORT)"
  printf '  %-24s http://%s:%s\n' "MinIO console" "$addr" "$(setting MINIO_CONSOLE_PORT_HOST)"
  printf '  %-24s http://%s:%s\n' "OpenSearch Dashboards" "$addr" "$(setting OPENSEARCH_DASHBOARDS_PORT)"
  if [ "$ENGINE" = "docker" ]; then
    echo "Note: these ports are published on all network interfaces, and Docker-published"
    echo "      ports are NOT filtered by ufw/firewalld. OpenSearch Dashboards has no login -"
    echo "      restrict access to it (network firewall or the DOCKER-USER iptables chain)."
  else
    echo "Note: these ports are published on all network interfaces, and Podman forwards"
    echo "      them before ufw/firewalld see them. OpenSearch Dashboards has no login -"
    echo "      restrict access to it (network firewall)."
  fi
  echo

  if [ "$npm" = "true" ]; then
    if [ "$main" = "https://$domain" ]; then
      echo "Nginx Proxy Manager forwards $domain to Catalog Web and renews its certificate."
    elif [ -n "$domain" ]; then
      echo "Nginx Proxy Manager forwards $domain to Catalog Web; $(hint 24 domain) sets up the proxy host and the certificate."
    else
      echo "Nginx Proxy Manager is enabled, but no domain is set - $(hint 24 domain) sets the domain, the proxy host and"
      echo "a Let's Encrypt certificate."
    fi
    echo "By hand in Nginx Proxy Manager: a Proxy Host to catalog-web, port 80, with Websockets Support and"
    echo "Block Common Exploits; SSL: a Let's Encrypt certificate, Force SSL, HTTP/2."
  else
    echo "Nginx Proxy Manager is disabled."
    echo "Catalog Web can be reached directly over:"
    echo "  ${main:-http://${addr}:$(setting CATALOG_WEB_PORT)}"
  fi
}

edit_generated() {
  local file="$1" dummy
  if [ ! -f "$file" ]; then
    err "$file not found - generate it first ($(hint 2 generate))."
    return 1
  fi
  if [ "$file" = "$ENV_FILE" ]; then
    warn "Do not change the passwords here after the first start - MongoDB, RabbitMQ and Nginx Proxy Manager keep the original ones."
  fi
  warn "Manual changes are overwritten the next time the files are generated (option 2)."
  echo "In vi: ':q' closes without changes, ':wq' saves and closes, ':q!' discards changes."
  read -r -p "Press Enter to open $file in $(editor_name)..." dummy || true
  open_editor "$file"
  if [ "$file" = "$ENV_FILE" ]; then
    chmod 600 "$ENV_FILE"
  fi
  info "If you changed something, apply it with option 5 (check the files) and 6 (start / apply changes)."
}

do_validate() {
  require_files || return 1
  require_engine || return 1
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
  local note
  require_files || return 1
  require_engine || return 1
  engine_guard || return 1
  downgrade_guard files || return 1
  upgrade_guard files || return 1
  net_ca_bundle_ensure
  if mongo_kernel_problem; then
    warn "MongoDB $(setting MONGO_TAG) refuses to start on kernel $(engine_kernel) without a workaround (SERVER-121912)."
    warn "Regenerate the files ($(hint 2 generate)): MongoDB then starts with GLIBC_TUNABLES=glibc.pthread.rseq=1."
  elif mongo_workaround_unneeded; then
    info "This kernel ($(engine_kernel)) no longer needs the MongoDB workaround that the files have - that is why they differ."
    info "They work as they are; regenerating ($(hint 2 generate)) gives MongoDB its faster per-CPU caches back."
  fi
  if settings_stale; then
    warn "$ENV_FILE / $COMPOSE_FILE do not match the settings at the top of $SCRIPT_NAME"
    note="$(install_note)"
    if [ -n "$note" ]; then
      warn "$note: the settings are older than the installation - take its values over ($(hint 23 "adopt .")), do not regenerate."
    elif note="$(raise_note)" && [ -n "$note" ]; then
      warn "$note."
    elif note="$(install_diff_note)" && [ -n "$note" ]; then
      warn "$note - $(hint 23 "adopt .") takes the installation's values over, $(hint 2 generate) writes the settings."
    else
      warn "(settings changed after generating, or the files were edited by hand)."
      warn "Regenerate them first ($(hint 2 generate)) if the new settings should be used."
    fi
    if [ "$INTERACTIVE" = "true" ] && ! confirm "Start with the files as they are?" n; then
      info "Cancelled."
      return 0
    fi
  fi
  mongo_cache_refresh
  info "Validating configuration..."
  compose config --quiet
  ok "Configuration is valid."
  # --remove-orphans also removes services that are no longer in the file
  # (e.g. Nginx Proxy Manager after INSTALL_NGINX_PROXY_MANAGER="false").
  info "Starting the stack ($ENGINE compose up -d --remove-orphans)..."
  compose up -d --remove-orphans
  npm_login_note start
  echo
  ok "Stack is up."
  compose ps
  if [ "${WIZ_QUIET_ACCESS:-}" != "yes" ]; then
    echo
    show_access_info
  fi
}

do_full_setup() {
  engine_guard || return 1
  do_generate ask no-next
  if [ "$GENERATE_CANCELLED" = "true" ]; then
    return 0
  fi
  echo
  do_up
}

do_status() {
  local inst note here more=""
  require_files || return 1
  require_engine || return 1
  compose ps
  here="$(install_kind)"
  inst="$(installed_catalog)"
  if [ "$here" = "files" ]; then
    echo
    echo "Catalog not installed: no containers and no data volumes, only $ENV_FILE and $COMPOSE_FILE."
    echo "A start makes a new, empty Catalog - $(install_next_text)."
    if [ "$INTERACTIVE" = "true" ]; then
      more=", or step by step with I"
    fi
    echo "Start it with $(hint 6 up)$more."
  elif [ -n "$inst" ]; then
    if [ "$inst" != "$CATALOG_VERSION" ]; then
      more=" (the settings say $CATALOG_VERSION)"
    fi
    if [ "$here" = "stopped" ]; then
      more="$more, stopped - $(hint 6 up) starts it"
    elif [ "$here" = "data" ]; then
      more="$more: its data is kept, no containers - $(hint 6 up) starts it again"
    fi
    echo
    echo "Catalog $inst installed$more"
  fi
  note="$(install_note)"
  if [ -n "$note" ]; then
    warn "$note - $(hint 23 "adopt .") takes the installation's values over."
  elif note="$(raise_note)" && [ -n "$note" ]; then
    warn "$note."
  elif note="$(install_diff_note)" && [ -n "$note" ]; then
    warn "$note - $(hint 23 "adopt .") takes the installation's values over, $(hint 2 generate) writes the settings."
  fi
  mem_oom_report || true
}

do_logs() {
  local service="${1:-}" services=() list line i choice
  require_files || return 1
  require_engine || return 1
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
  require_engine || return 1
  if ! compose pull; then
    net_offer_check "The download of the images"
    return 1
  fi
  ok "Images pulled. Apply them with $(hint 6 up)."
}

do_restart() {
  require_files || return 1
  require_engine || return 1
  compose restart -t 30
  ok "Stack restarted."
}

do_down() {
  require_files || return 1
  require_engine || return 1
  downgrade_guard files stop || return 1
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
  require_engine || return 1
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
  # the proxy hosts, certificates and the admin of Nginx Proxy Manager are gone with its volumes; a failed
  # upgrade has no data left to go back to
  rm -f -- "$NPM_CERT_FILE" "$NPM_LOGIN_FILE" "$UPGRADE_FAILED_FILE"
  ok "Containers and data volumes removed."
  echo "Optionally generate new passwords (option 2), then start again (option 6)."
}

do_check() {
  local problems=0 name port mmc host_tz v where="" mb inst
  info "Checking prerequisites..."
  echo "  Container engine: $ENGINE_NAME$(if [ -z "$CONTAINER_ENGINE" ]; then printf ' (CONTAINER_ENGINE is empty: the one found on this server)'; fi)"

  if [ "$ENGINE" = "docker" ]; then
    if ! command -v docker >/dev/null 2>&1; then
      err "$ENGINE_NAME is not installed. './$SCRIPT_NAME $(engine_install_cmd)' sets it up (I - Install asks first):"
      case "$OS_KIND:$ENGINE_KIND" in
        Darwin:colima) echo "      brew install colima docker, the newest Docker Compose, and a Colima VM with Rosetta" ;;
        Darwin:*)
          echo "      Docker Desktop with Homebrew (brew install --cask docker-desktop)"
          mac_docker_license
          ;;
        *)
          if v="$(docker_install_plan 2>&1)"; then
            printf '      %s\n' $(printf '%s\n' "$v" | tr ' ' '\001') | tr '\001' ' '
            docker_service_plan | sed 's/^/      /'
          else
            echo "      $v"
          fi
          ;;
      esac
      problems=$((problems + 1))
    elif docker_is_podman; then
      err "'docker' on this machine is Podman (podman-docker), not Docker - './$SCRIPT_NAME $(engine_install_cmd)' installs Docker, or use CONTAINER_ENGINE=\"podman\"."
      problems=$((problems + 1))
    elif docker_is_snap; then
      err "$(docker_snap_problem)"
      problems=$((problems + 1))
    else
      ok "Docker $(engine_version)"
      if docker info >/dev/null 2>&1; then
        if [ "$(engine_rootless)" = "true" ]; then
          err "Docker runs rootless here - the Catalog needs the rootful Docker daemon (ports 80 and 443, the memory lock of OpenSearch)."
          problems=$((problems + 1))
        else
          ok "The Docker daemon answers$(if [ "$ENGINE_KIND" = "colima" ]; then printf ' (Colima VM)'; fi) and runs rootful."
        fi
        if [ "$OS_KIND" != "Darwin" ] && command -v systemctl >/dev/null 2>&1 && [ "$(systemctl is-enabled docker.service 2>/dev/null)" != "enabled" ]; then
          warn "docker.service is not enabled - Docker and the stack do not come back after a reboot:"
          echo "      systemctl enable --now docker"
        fi
      else
        err "$ENGINE_NAME does not answer (docker info failed) - $(engine_down_hint)."
        problems=$((problems + 1))
      fi
      if detect_compose; then
        ok "Compose: docker compose with $(docker compose version 2>/dev/null | head -n 1)"
      else
        err "$COMPOSE_PROBLEM"
        problems=$((problems + 1))
      fi
    fi
  elif ! command -v podman >/dev/null 2>&1; then
    err "Podman is not installed. './$SCRIPT_NAME install-podman' sets it up (I - Install asks first):"
    if [ "$OS_KIND" = "Darwin" ]; then
      echo "      brew install podman, a rootful Podman machine, and the newest Docker Compose"
    elif v="$(podman_install_plan 2>&1)"; then
      printf '      %s\n' $(printf '%s\n' "$v" | tr ' ' '\001') | tr '\001' ' '
      podman_service_plan | sed 's/^/      /'
    else
      echo "      $v"
    fi
    problems=$((problems + 1))
  else
    v="$(engine_version)"
    if [ -n "$v" ] && ! version_gt "$PODMAN_MIN" "$v"; then
      ok "Podman $v"
    else
      err "Podman ${v:-(unknown version)} is too old: $PODMAN_MIN or newer is needed ('podman compose' came with 4.7)."
      problems=$((problems + 1))
    fi
    if [ "$OS_KIND" = "Darwin" ] && ! engine_socket_ok; then
      err "The Podman machine is not running: podman machine start $(mac_machine)"
      problems=$((problems + 1))
    else
      case "$(engine_rootless)" in
        false) ok "Podman runs rootful$(if [ "$OS_KIND" = "Darwin" ]; then printf ' (Podman machine)'; fi)." ;;
        true)
          if [ "$OS_KIND" = "Darwin" ]; then
            err "The Podman machine runs rootless: podman machine stop && podman machine set --rootful && podman machine start"
          else
            err "Podman runs rootless here: run $SCRIPT_NAME as root (sudo) - the Catalog needs rootful Podman."
          fi
          problems=$((problems + 1))
          ;;
        *)
          err "Podman does not answer (podman info failed)."
          problems=$((problems + 1))
          ;;
      esac
      if [ "$OS_KIND" != "Darwin" ]; then
        if engine_socket_ok; then
          ok "Podman API socket (podman.socket) is active."
        else
          err "The Podman API socket is not active (podman compose needs it): systemctl enable --now podman.socket"
          problems=$((problems + 1))
        fi
        if command -v systemctl >/dev/null 2>&1 && [ "$(systemctl is-enabled podman-restart.service 2>/dev/null)" != "enabled" ]; then
          warn "podman-restart.service is not enabled - the stack does not come back after a reboot:"
          echo "      systemctl enable podman-restart.service"
        fi
      fi
    fi
    if detect_compose; then
      ok "Compose: podman compose with $("$COMPOSE_PROVIDER" version 2>/dev/null | head -n 1)"
    else
      err "$COMPOSE_PROBLEM"
      problems=$((problems + 1))
    fi
  fi
  # one engine per server: the data of this project in the other engine would be left behind
  if ! engine_guard; then
    problems=$((problems + 1))
  fi

  if check_settings; then
    ok "Settings at the top of $SCRIPT_NAME look valid."
  else
    problems=$((problems + 1))
  fi

  if mongo_kernel_problem; then
    warn "MongoDB $(setting MONGO_TAG) refuses to start on kernel $(engine_kernel) (SERVER-121912): the files lack the workaround."
    echo "      Regenerate them (option 2, or I - repair): MongoDB then starts with GLIBC_TUNABLES=glibc.pthread.rseq=1."
  elif mongo_rseq_workaround; then
    ok "MongoDB $(setting MONGO_TAG) on kernel $(engine_kernel): starts with GLIBC_TUNABLES=glibc.pthread.rseq=1 (SERVER-121912)."
    echo "      TCMalloc then uses per-thread instead of per-CPU caches: some performance cost."
  fi
  local upstream
  upstream="$(kernel_upstream_version)"
  if kernel_blocks_mongo8 && [[ "$upstream" =~ ^7\.0\.[0-9]+$ ]] && version_gt "7.0.14" "$upstream"; then
    warn "This Ubuntu kernel is based on Linux $upstream and lacks the full rseq fix (7.0.14) - update it:"
    echo "      sudo apt update && sudo apt full-upgrade, then reboot (until /proc/version_signature ends in"
    echo "      7.0.14 or newer; for linux-generic that is 7.0.0-31 or newer)"
  fi

  if [ "$OS_KIND" = "Darwin" ] && [ "$ENGINE" = "podman" ]; then
    v="$(sw_vers -productVersion 2>/dev/null)" || v=""
    if [[ "${v%%.*}" =~ ^[0-9]+$ ]] && [ "${v%%.*}" -lt 26 ]; then
      err "macOS $v: the amd64 Catalog images need Rosetta in the Podman machine, which works only from macOS 26."
      problems=$((problems + 1))
    fi
    if engine_socket_ok; then
      if mac_rosetta_on "$(mac_machine)"; then
        ok "Rosetta runs the amd64 Catalog images in the Podman machine."
      else
        err "Rosetta is not active in the Podman machine - './$SCRIPT_NAME install-podman' turns it on."
        problems=$((problems + 1))
      fi
    fi
  elif [ "$OS_KIND" = "Darwin" ] && [ "$(engine_arch)" = "arm64" ] && engine_socket_ok; then
    # Docker Desktop and Colima: Rosetta in their Linux VM, which fails with Linux 6.13 and newer before macOS 26
    if mac_kernel_problem; then
      mac_kernel_error
      problems=$((problems + 1))
    fi
    if [ "$ENGINE_KIND" = "colima" ]; then
      if mac_colima_rosetta_on; then
        ok "Rosetta runs the amd64 Catalog images in the Colima VM."
      else
        err "Rosetta is not active in the Colima VM (colima start --vz-rosetta) - './$SCRIPT_NAME install-engine' checks it."
        problems=$((problems + 1))
      fi
    elif mac_docker_rosetta_off; then
      warn "Rosetta is off in Docker Desktop, and the Catalog images are amd64: turn on Settings > General >"
      echo "      \"Use Rosetta for x86_64/amd64 emulation\", then Apply & restart."
    fi
  fi

  mmc=""
  if [ "$OS_KIND" = "Darwin" ]; then
    if engine_socket_ok; then
      case "$ENGINE_KIND" in
        podman)
          mmc="$(podman machine ssh "$(mac_machine)" sysctl -n vm.max_map_count 2>/dev/null)" || mmc=""
          where=" (Podman machine)"
          ;;
        colima)
          mmc="$(colima ssh -- sysctl -n vm.max_map_count 2>/dev/null)" || mmc=""
          where=" (Colima VM)"
          ;;
      esac
      mmc="${mmc//[^0-9]/}"
    fi
  elif [ -r /proc/sys/vm/max_map_count ]; then
    mmc="$(cat /proc/sys/vm/max_map_count)"
  fi
  if [ -n "$mmc" ]; then
    if [ "$mmc" -ge 262144 ]; then
      ok "vm.max_map_count = $mmc$where"
    elif [ "$ENGINE_KIND" = "colima" ]; then
      warn "vm.max_map_count = $mmc in the Colima VM - OpenSearch recommends at least 262144 ('./$SCRIPT_NAME install-engine' sets it):"
      echo "      colima ssh -- sudo sysctl -w vm.max_map_count=262144"
    elif [ "$OS_KIND" = "Darwin" ]; then
      warn "vm.max_map_count = $mmc in the Podman machine - OpenSearch recommends at least 262144:"
      echo "      podman machine ssh $(mac_machine) \"sudo sh -c 'echo vm.max_map_count=262144 > /etc/sysctl.d/99-opensearch.conf && sysctl --system'\""
    else
      warn "vm.max_map_count = $mmc - OpenSearch recommends at least 262144:"
      echo "      sudo sysctl -w vm.max_map_count=262144"
      echo "      echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-opensearch.conf"
    fi
  fi

  mb="$(engine_mem_mb)"
  if [ -n "$mb" ] && mem_low "$mb"; then
    warn "Memory: $(mem_gb "$mb") GB for the containers - at least $MEM_RECOMMENDED_GB GB is recommended"
    echo "      A full snapshot import loads MongoDB, the Catalog and OpenSearch at once."
  elif [ -n "$mb" ]; then
    ok "Memory: $(mem_gb "$mb") GB for the containers - enough for a full snapshot import"
  fi
  mem_oom_report || true

  if command -v ss >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1; then
    for name in $(port_settings); do
      port="${!name}"
      if wiz_port_used "$port"; then
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
  # the newest Catalog first: the line of what is installed names it, as the menu does
  if [ "$CHECK_FOR_UPDATES" = "true" ]; then
    if fetch_hub_versions; then
      ok "Docker Hub is reachable - newest Catalog version: $(version_with_tag "${HUB_VERSIONS%%$'\n'*}")"
      LATEST_VERSION="${HUB_VERSIONS%%$'\n'*}"
      HUB_STATUS="ok"
    else
      warn "Docker Hub is not reachable - the version list (option 8) will not work."
      HUB_STATUS="failed"
    fi
  fi
  # what is installed in this folder, as the menu says it
  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
    v="$(stack_state)"
    inst="$(installed_catalog)"
    inst="${inst:-$(env_value CATALOG_IMAGE)}"
    inst="${inst##*:}"
    case "$(install_kind "$v")" in
      running) ok "Catalog $inst is installed here: $v." ;;
      stopped) info "Catalog $inst is installed here, stopped - $(hint 6 up) starts it." ;;
      data) info "Catalog $inst is installed here: its data is kept, no containers - $(hint 6 up) starts it again." ;;
      files) info "Catalog not installed here: no containers and no data volumes, only $ENV_FILE and $COMPOSE_FILE - a start makes a new, empty Catalog: $(install_next_text)." ;;
    esac
  fi
  v="$(install_note)"
  if [ -n "$v" ]; then
    warn "$v - $(hint 23 "adopt .") takes the installation's values over (older settings are not written into the files)."
  elif v="$(raise_note)" && [ -n "$v" ]; then
    warn "$v."
  elif v="$(install_diff_note)" && [ -n "$v" ]; then
    warn "$v - $(hint 23 "adopt .") takes the installation's values over, $(hint 2 generate) writes the settings."
  fi
  if net_enabled; then
    net_check_line
  fi

  echo
  if [ "$problems" -eq 0 ]; then
    ok "All required checks passed."
  else
    err "$problems problem(s) found."
    return 1
  fi
}

###############################################################################
# Internet access (option 26): the sites the installation needs, their check, the proxy
###############################################################################

# The proxy the shell gave this run (before proxy_load exports the one of the settings). RN1_PROXY_SET: an
# earlier run of the installer exported the proxy - a job or a restarted menu inherits that one, it is not
# the shell's.
NET_SHELL_PROXY=""
NET_SHELL_NAME=""
NET_SHELL_NO=""
if [ -z "${RN1_PROXY_SET:-}" ]; then
  for NET_SHELL_NAME in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY ""; do
    if [ -n "$NET_SHELL_NAME" ] && [ -n "${!NET_SHELL_NAME:-}" ]; then
      NET_SHELL_PROXY="${!NET_SHELL_NAME}"
      break
    fi
  done
  NET_SHELL_NO="${no_proxy:-${NO_PROXY:-}}"
fi
# The login of the proxy (percent-encoded user:password, mode 600) and the copy of the company's root
# certificate - never in the script, which may be passed on
PROXY_LOGIN_FILE="$WORK_DIR/.proxy_login"
PROXY_CA_COPY="$WORK_DIR/proxy-ca.pem"
# The folders of the system files the check reads (/etc) and of the files of one run (/run)
NET_ETC="${RN1_ETC_DIR:-/etc}"
NET_RUN="${RN1_RUN_DIR:-/run}"
# The last check, for the menu header and option 16: fresh for NET_CACHE_TTL seconds
NET_CACHE="$JOBS_DIR/internet-check"
NET_CACHE_TTL="${RN1_NET_CACHE_TTL:-900}"
# Written when this server has no internet (choice 5 of option 26): the menu start checks nothing
NET_OFFLINE_FILE="$JOBS_DIR/internet-offline"
# Seconds each request of the check may take to connect and in total
NET_CT=8
NET_MT=20
NET_BG_PID=""
# When the menu last started the check in the background (SECONDS), and the process it watches: the check
# stops when that process has ended (the menu quit)
NET_BG_AT=""
NET_WATCH=""
NET_LOADED=""
# The proxy the check goes through, with its login (empty: direct), and how it is named on the screen
NET_VIA=""
NET_VIA_TEXT=""
# The names the check reaches directly while it goes through NET_VIA (comma-separated, as curl takes them)
NET_VIA_NO=""
# The engine the sites are for while an engine is set up (empty: net_engine decides)
NET_ENGINE_KIND=""
NET_TMP=""
NET_TOOL=""
NET_R=""
NET_CODE=""
NET_EFF=""
NET_HOST=""
NET_SCHEMES=""
NET_LOGIN=""
NET_NEW_NO=""
NET_NODNS=""
NET_LIMIT=""
NET_SECS=0
NET_REQ_BAD=0
NET_OPT_BAD=0
NET_TOTAL=0
NET_C_REQ=0
NET_C_OPT=0
NET_C_TOTAL=0
# The rows of the last check (same index everywhere)
NET_KEYS=()
NET_HOSTS=()
NET_PORTS=()
NET_LEVELS=()
NET_WHAT=()
NET_URLS=()
NET_STATUS=()
NET_DETAIL=()
# The files of one run for the steps that run as root (see proxy_run_begin)
NET_RUN_ENV=""
NET_RUN_APT=""
NET_RUN_DNF=""

# True unless the automatic internet checks are off: RN1_NET_CHECK=off (menu start, new installation,
# option 16, engine setup; option 26 and network-check still check)
net_enabled() {
  [ "${RN1_NET_CHECK:-on}" != "off" ]
}

# net_encode TEXT -> TEXT percent-encoded byte by byte, all but A-Za-z0-9._~- : a login in a proxy address
# then needs no quoting anywhere (URLs, env files, .env, YAML)
net_encode() {
  (
    LC_ALL=C
    s="$1"
    out=""
    for ((i = 0; i < ${#s}; i++)); do
      c="${s:i:1}"
      case "$c" in
        [A-Za-z0-9._~-]) out="$out$c" ;;
        *)
          printf -v c '%%%02X' "'$c"
          out="$out$c"
          ;;
      esac
    done
    printf '%s' "$out"
  )
}

# net_decode TEXT -> TEXT with its %XX sequences decoded
net_decode() {
  local s="$1" out="" i=0 c
  while [ "$i" -lt "${#s}" ]; do
    c="${s:i:1}"
    if [ "$c" = "%" ] && [[ "${s:i+1:2}" =~ ^[0-9A-Fa-f][0-9A-Fa-f]$ ]]; then
      printf -v c "\\x${s:i+1:2}"
      i=$((i + 3))
    else
      i=$((i + 1))
    fi
    out="$out$c"
  done
  printf '%s' "$out"
}

# net_sq TEXT -> TEXT in single quotes for sh
net_sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# The login of the proxy as saved: percent-encoded user:password (empty when there is none). The file names
# the proxy it belongs to (a line proxy=ADDRESS): for another INTERNET_PROXY it is no login - a proxy changed
# in option 1 never gets the password of the one before. A file without that line (written by hand) counts.
proxy_login() {
  local l="" line p="" pset="no"
  if [ -r "$PROXY_LOGIN_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line//[[:space:]]/}"
      case "$line" in
        "") ;;
        proxy=*) p="${line#proxy=}"; pset="yes" ;;
        *) if [ -z "$l" ]; then l="$line"; fi ;;
      esac
    done < "$PROXY_LOGIN_FILE"
  fi
  if [ "$pset" = "yes" ] && [ "$p" != "$INTERNET_PROXY" ]; then
    l=""
  fi
  printf '%s' "$l"
}

# The user name of the saved login, as typed (DOMAIN\user)
proxy_login_user() {
  local l
  l="$(proxy_login)"
  if [ -n "$l" ]; then
    net_decode "${l%%:*}"
  fi
}

# proxy_login_save LOGIN -> .proxy_login (percent-encoded user:password) for the proxy of INTERNET_PROXY,
# readable only by its owner
proxy_login_save() {
  if ! (umask 077 && printf 'proxy=%s\n%s\n' "$INTERNET_PROXY" "$1" > "$PROXY_LOGIN_FILE") || ! chmod 600 "$PROXY_LOGIN_FILE"; then
    err "Cannot write $PROXY_LOGIN_FILE."
    return 1
  fi
}

# net_parse ADDRESS -> NP_SCHEME, NP_HOST, NP_PORT and NP_LOGIN (user:password as typed) of a proxy address:
# host:port, IPv4:port or [IPv6]:port, optionally with http://, https://, socks5:// or socks5h:// in front and
# a login; no scheme is http, NP_PORT is empty when the address has none. 1 when ADDRESS is none.
net_parse() {
  local a="$1" re6='^\[([0-9A-Fa-f:.]+)\](:([0-9]+))?$' re='^([A-Za-z0-9._-]+)(:([0-9]+))?$'
  NP_SCHEME="http"
  NP_HOST=""
  NP_PORT=""
  NP_LOGIN=""
  a="${a//[[:space:]]/}"
  if [[ "$a" == *://* ]]; then
    NP_SCHEME="${a%%://*}"
    NP_SCHEME="${NP_SCHEME,,}"
    a="${a#*://}"
  fi
  case "$NP_SCHEME" in
    http|https|socks5|socks5h) ;;
    *) return 1 ;;
  esac
  a="${a%/}"
  if [[ "$a" == *@* ]]; then
    NP_LOGIN="${a%@*}"
    a="${a##*@}"
  fi
  if [[ "$a" =~ $re6 ]]; then
    NP_HOST="[${BASH_REMATCH[1]}]"
    NP_PORT="${BASH_REMATCH[3]}"
  elif [[ "$a" =~ $re ]]; then
    NP_HOST="${BASH_REMATCH[1],,}"
    NP_PORT="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  if [ -n "$NP_PORT" ]; then
    if [ "${#NP_PORT}" -gt 5 ] || [ "$((10#$NP_PORT))" -lt 1 ] || [ "$((10#$NP_PORT))" -gt 65535 ]; then
      return 1
    fi
    NP_PORT="$((10#$NP_PORT))"
  fi
}

# net_with_login URL [LOGIN] -> URL with the login (percent-encoded user:password; default: the saved one)
net_with_login() {
  local url="$1" login="${2-$(proxy_login)}"
  if [ -z "$login" ] || [[ "$url" != *://* ]]; then
    printf '%s' "$url"
  else
    printf '%s://%s@%s' "${url%%://*}" "$login" "${url#*://}"
  fi
}

# net_mask URL -> URL without the password of its login (for the screen)
net_mask() {
  local url="$1" rest user
  if [[ "$url" != *@* ]]; then
    printf '%s' "$url"
    return 0
  fi
  rest="${url#*://}"
  user="${rest%@*}"
  user="${user%%:*}"
  if [[ "$url" == *://* ]]; then
    printf '%s://%s:***@%s' "${url%%://*}" "$user" "${rest##*@}"
  else
    printf '%s:***@%s' "$user" "${rest##*@}"
  fi
}

# INTERNET_NO_PROXY as the tools read it: every name as name and .name (exact and subdomains: .NET takes
# only these two forms), addresses and ranges as they are; comma-separated
net_no_list() {
  local item out=""
  local -a items=()
  IFS=',' read -r -a items <<< "$INTERNET_NO_PROXY"
  for item in ${items[@]+"${items[@]}"}; do
    item="${item//[[:space:]]/}"
    case "$item" in
      "") ;;
      *:*|*/*|[0-9]*.[0-9]*.[0-9]*.[0-9]*) out="$out,$item" ;;
      .*) out="$out,${item#.},$item" ;;
      *) out="$out,$item,.$item" ;;
    esac
  done
  printf '%s' "${out#,}"
}

# The names of this server: its short name and, when it has one, its full name
net_server_names() {
  local h
  h="$(uname -n 2>/dev/null)" || h=""
  h="${h,,}"
  if [ -n "$h" ]; then
    printf '%s\n' "${h%%.*}"
    if [[ "$h" == *.* ]]; then
      printf '%s\n' "$h"
    fi
  fi
}

# The NO_PROXY of this run (and of the programs it starts): this server, its addresses, the domain of the
# Catalog, INTERNET_NO_PROXY, the shell's own list and the private address ranges (only curl 7.86 or newer,
# Go and Node read ranges)
net_no_proxy_session() {
  local out="localhost,127.0.0.1,::1" a
  while IFS= read -r a; do
    case "$a" in
      ""|127.*|::1|fe80:*) ;;
      *) out="$out,$a" ;;
    esac
  done <<< "$(net_server_names; local_addresses 2>/dev/null || true)"
  if [ -n "$CATALOG_DOMAIN" ]; then
    out="$out,$CATALOG_DOMAIN"
  fi
  a="$(net_no_list)"
  if [ -n "$a" ]; then
    out="$out,$a"
  fi
  if [ -n "$NET_SHELL_NO" ]; then
    out="$out,${NET_SHELL_NO// /}"
  fi
  printf '%s,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16' "$out"
}

# proxy_load -> the proxy of INTERNET_PROXY for this run and the programs it starts (curl, wget, git,
# Homebrew, the package managers): http_proxy, https_proxy, no_proxy and their upper-case twins, all with
# the same value and the login of .proxy_login - so the login is in no command line. Without INTERNET_PROXY
# a proxy of the shell stays as it is.
proxy_load() {
  local sig url no
  sig="$INTERNET_PROXY|$INTERNET_NO_PROXY|$CATALOG_DOMAIN|$(proxy_login)"
  if [ "$sig" = "$NET_LOADED" ]; then
    return 0
  fi
  NET_LOADED="$sig"
  if [ -z "$INTERNET_PROXY" ] || ! net_parse "$INTERNET_PROXY" || [ -z "$NP_PORT" ] || [ -n "$NP_LOGIN" ]; then
    if [ -n "${RN1_PROXY_SET:-}" ]; then
      unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY RN1_PROXY_SET
    fi
    return 0
  fi
  url="$(net_with_login "$INTERNET_PROXY")"
  no="$(net_no_proxy_session)"
  export http_proxy="$url" https_proxy="$url" HTTP_PROXY="$url" HTTPS_PROXY="$url"
  export no_proxy="$no" NO_PROXY="$no" RN1_PROXY_SET="yes"
}

# The proxy of this run as the environment has it (empty: none)
net_session_proxy() {
  printf '%s' "${https_proxy:-${HTTPS_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}"
}

# net_root_write FILE TEXT -> FILE with TEXT, readable only by root (sudo when needed): the text goes
# through stdin, so it shows in no process list
net_root_write() {
  if [ "${#SUDO[@]}" -gt 0 ]; then
    "${SUDO[@]}" sh -c 'umask 077 && mkdir -p "${1%/*}" && cat > "$1"' sh "$1" <<< "$2"
  else
    (umask 077 && mkdir -p -- "${1%/*}" && printf '%s\n' "$2" > "$1")
  fi
}

# The proxy a package manager has in its own configuration, which wins over the environment: apt
# (Acquire::http(s)::Proxy) or dnf and yum (proxy= of dnf.conf, yum.conf)
net_apt_proxy() {
  local v
  if ! command -v apt-config >/dev/null 2>&1; then
    return 0
  fi
  # awk reads all of it: an early exit would break the pipe
  v="$(apt-config dump 2>/dev/null | awk 'tolower($1) ~ /^acquire::https?::proxy$/ { gsub(/[";]/, "", $2); if (p == "" && $2 != "" && tolower($2) != "direct" && tolower($2) != "false") p = $2 } END { print p }')" || v=""
  printf '%s' "$v"
}

# The proxy= of the [main] section of dnf.conf (or yum.conf) as FILE|PROXY (empty: none)
net_dnf_conf() {
  local f v
  for f in "$NET_ETC/dnf/dnf.conf" "$NET_ETC/yum.conf"; do
    if [ -r "$f" ]; then
      v="$(awk -F= '/^\[/ { m = ($0 ~ /^\[main\]/) } m && $1 ~ /^[ \t]*proxy[ \t]*$/ { v = $2; gsub(/[ \t]/, "", v); if (p == "" && v != "" && v != "_none_") p = v } END { print p }' "$f")" || v=""
      if [ -n "$v" ]; then
        printf '%s|%s' "$f" "$v"
        return 0
      fi
    fi
  done
}

# proxy_run_begin -> the proxy of this run for the steps that run as root. sudo drops the environment, so
# the values go through stdin into a file only root can read (RUN/rn1-proxy.PID.env), which each step reads
# first. When INTERNET_PROXY is set and apt or dnf have their own proxy configured (it would win), they get
# a copy of their configuration with this proxy (apt-get -c, dnf --config=). Nothing is written without a proxy.
proxy_run_begin() {
  local p h no conf
  NET_RUN_ENV=""
  NET_RUN_APT=""
  NET_RUN_DNF=""
  p="$(net_session_proxy)"
  if [ -z "$p" ]; then
    return 0
  fi
  h="${http_proxy:-${HTTP_PROXY:-$p}}"
  no="${no_proxy:-${NO_PROXY:-}}"
  if [ "${#SUDO[@]}" -gt 0 ]; then
    NET_RUN_ENV="$NET_RUN/rn1-proxy.$$.env"
    if ! net_root_write "$NET_RUN_ENV" "export http_proxy=$(net_sq "$h") https_proxy=$(net_sq "$p") HTTP_PROXY=$(net_sq "$h") HTTPS_PROXY=$(net_sq "$p") no_proxy=$(net_sq "$no") NO_PROXY=$(net_sq "$no")"; then
      err "Cannot write $NET_RUN_ENV (the proxy for the steps as root)."
      proxy_run_end
      return 1
    fi
  fi
  if [ -z "$INTERNET_PROXY" ]; then
    return 0
  fi
  if [ -n "$(net_apt_proxy)" ] && [ "$(net_apt_proxy)" != "$INTERNET_PROXY" ]; then
    NET_RUN_APT="$NET_RUN/rn1-apt.$$.conf"
    if ! net_root_write "$NET_RUN_APT" "Acquire::http::Proxy \"$p\";
Acquire::https::Proxy \"$p\";"; then
      err "Cannot write $NET_RUN_APT (the proxy for apt-get)."
      proxy_run_end
      return 1
    fi
  fi
  conf="$(net_dnf_conf)"
  if [ -n "$conf" ] && [ "${conf#*|}" != "$INTERNET_PROXY" ]; then
    NET_RUN_DNF="$NET_RUN/rn1-dnf.$$.conf"
    if ! net_root_write "$NET_RUN_DNF" "$(awk '/^\[/ { m = ($0 ~ /^\[main\]/) } m && /^[ \t]*proxy(_username|_password|_auth_method)?[ \t]*=/ { next } { print }' "${conf%%|*}")"; then
      err "Cannot write $NET_RUN_DNF (the proxy for dnf)."
      proxy_run_end
      return 1
    fi
  fi
}

# proxy_run_step STEP -> STEP as it runs as root: with the proxy of this run read first, apt-get and dnf
# with their copy of the configuration; STEP itself without a proxy
proxy_run_step() {
  local s="$1"
  if [ -n "$NET_RUN_APT" ]; then
    s="${s//apt-get /apt-get -c $NET_RUN_APT }"
  fi
  if [ -n "$NET_RUN_DNF" ]; then
    s="${s//dnf /dnf --config=$NET_RUN_DNF }"
    s="${s//yum /yum --config=$NET_RUN_DNF }"
  fi
  if [ -n "$NET_RUN_ENV" ]; then
    s=". $NET_RUN_ENV; $s"
  fi
  printf '%s' "$s"
}

# proxy_run_end -> removes the files of proxy_run_begin
proxy_run_end() {
  local f
  local -a files=()
  for f in "$NET_RUN_ENV" "$NET_RUN_APT" "$NET_RUN_DNF"; do
    if [ -n "$f" ]; then
      files+=("$f")
    fi
  done
  NET_RUN_ENV=""
  NET_RUN_APT=""
  NET_RUN_DNF=""
  if [ "${#files[@]}" -gt 0 ]; then
    ${SUDO[@]+"${SUDO[@]}"} rm -f -- "${files[@]}" 2>/dev/null || true
  fi
}

# True when proxy_run_begin wrote files (the steps then run with them)
proxy_run_active() {
  [ -n "$NET_RUN_ENV$NET_RUN_APT$NET_RUN_DNF" ]
}

# proxy_sudo COMMAND [ARG...] -> COMMAND as root (sudo when needed) with the proxy of this run
proxy_sudo() {
  local rc=0 traps stopped=""
  if [ "${#SUDO[@]}" -eq 0 ] || [ -z "$(net_session_proxy)" ]; then
    ${SUDO[@]+"${SUDO[@]}"} "$@"
    return
  fi
  proxy_run_begin || return 1
  # Ctrl+C, a kill or a cancelled job: the root-only file with the login goes first, then the signal
  # does what it would have done (the caller's trap, or the end of the script)
  traps="$(trap -p INT TERM HUP)"
  trap 'stopped="INT"' INT
  trap 'stopped="TERM"' TERM
  trap 'stopped="HUP"' HUP
  "${SUDO[@]}" sh -c '. "$0" && exec "$@"' "$NET_RUN_ENV" "$@" || rc=$?
  proxy_run_end
  trap - INT TERM HUP
  eval "$traps"
  if [ -n "$stopped" ]; then
    kill -s "$stopped" "$BASHPID" 2>/dev/null || true
    return 130
  fi
  return "$rc"
}

# zypper takes its proxy only from /etc/sysconfig/proxy (no setting for one command): what to do when
# INTERNET_PROXY is not set there
net_zypper_note() {
  local f="$NET_ETC/sysconfig/proxy"
  if [ -z "$INTERNET_PROXY" ] || ! command -v zypper >/dev/null 2>&1; then
    return 0
  fi
  if [ -r "$f" ] && grep -q '^PROXY_ENABLED="yes"' "$f" && grep -qF "$INTERNET_PROXY" "$f"; then
    return 0
  fi
  warn "zypper takes its proxy only from $f: set it there (yast proxy), e.g."
  echo "      PROXY_ENABLED=\"yes\""
  echo "      HTTPS_PROXY=\"$INTERNET_PROXY\""
  echo "      HTTP_PROXY=\"$INTERNET_PROXY\""
}

# The engine the sites are for: NET_ENGINE_KIND, CONTAINER_ENGINE, else the one installed here (Podman
# first), else empty - not chosen yet (the first step of the new installation)
net_engine() {
  if [ -n "$NET_ENGINE_KIND" ]; then
    printf '%s' "$NET_ENGINE_KIND"
  elif [ -n "$CONTAINER_ENGINE" ]; then
    printf '%s' "$CONTAINER_ENGINE"
  elif command -v podman >/dev/null 2>&1; then
    printf 'podman'
  elif command -v docker >/dev/null 2>&1 && ! docker_is_podman; then
    printf 'docker'
  fi
}

# net_installed KIND -> true when the engine KIND is installed here
net_installed() {
  case "$1" in
    podman) command -v podman >/dev/null 2>&1 ;;
    colima) command -v colima >/dev/null 2>&1 ;;
    docker) command -v docker >/dev/null 2>&1 && ! docker_is_podman ;;
    *) return 1 ;;
  esac
}

# net_compose_need KIND -> req when the setup of KIND downloads Docker Compose from GitHub, opt when it
# only keeps the installer's own up to date, empty when the engine brings it
net_compose_need() {
  local v
  case "$1" in
    ""|podman|colima)
      if [ -n "$1" ] && [ -x "$COMPOSE_PROVIDER" ]; then
        printf 'opt'
      else
        printf 'req'
      fi
      ;;
    docker)
      if [ "$OS_KIND" = "Darwin" ]; then
        return 0
      fi
      if ! net_installed docker; then
        if docker_from_distro; then
          printf 'req'
        fi
        return 0
      fi
      v="$(docker compose version 2>/dev/null)" || v=""
      if ! compose_v2 "$v"; then
        printf 'req'
      elif [ -x "$COMPOSE_PROVIDER" ] && [ ! -L "$COMPOSE_PROVIDER" ]; then
        printf 'opt'
      fi
      ;;
  esac
}

# The folder of Docker's repository for this Linux (ubuntu, debian, rhel, centos, fedora); empty when Docker
# comes from the packages of the distribution (openSUSE, SLES) or the system is not covered
net_docker_repo() {
  local id like major
  id="$(os_release ID)"
  like=" $(os_release ID_LIKE) "
  major="$(os_release VERSION_ID)"
  major="${major%%.*}"
  case "$id $like" in
    ubuntu*|*" ubuntu "*) printf 'ubuntu'; return 0 ;;
    debian*|*" debian "*) printf 'debian'; return 0 ;;
  esac
  case "$id" in
    fedora) printf 'fedora' ;;
    rhel) printf 'rhel' ;;
    centos|rocky|almalinux|ol|amzn)
      if [ "$major" = "8" ]; then
        printf 'rhel'
      else
        printf 'centos'
      fi
      ;;
    *)
      case "$like" in
        *" rhel "*|*" centos "*) printf 'centos' ;;
        *" fedora "*) printf 'fedora' ;;
      esac
      ;;
  esac
}

# The package repositories of this Linux: KIND|URL|FILE, the URL the check tries. KIND: apt (InRelease of a
# suite), repomd (repodata/repomd.xml), meta (a metalink or a mirror list), any (only that it answers: the
# repository needs a certificate or a token, or has variables the check cannot fill in)
net_repo_urls() {
  local f kind url file rel major arch h
  arch="$(uname -m 2>/dev/null)" || arch="x86_64"
  rel="$(os_release VERSION_ID)"
  major="${rel%%.*}"
  # apt: awk writes the lines itself (the URL of InRelease: dists/SUITE/, or a flat suite that ends in /). No
  # pipe into a while loop with IFS='|' read: in the subshell of a pipe bash 4.2 (CentOS 7) did not split the
  # lines at |, every field landed in the first variable.
  for f in "$NET_ETC/apt/sources.list" "$NET_ETC"/apt/sources.list.d/*.list; do
    if [ -r "$f" ]; then
      awk -v f="${f##*/}" '
        function rel(u, s) { sub(/\/$/, "", u); return s ~ /\/$/ ? u "/" s "InRelease" : u "/dists/" s "/InRelease" }
        $1 == "deb" {
          i = 2
          if ($2 ~ /^\[/) { while (i <= NF && $i !~ /\]$/) i++; i++ }
          if ($i ~ /^https?:\/\// && $(i + 1) != "") print "apt|" rel($i, $(i + 1)) "|" f
        }' "$f"
    fi
  done
  for f in "$NET_ETC"/apt/sources.list.d/*.sources; do
    if [ -r "$f" ]; then
      awk -v f="${f##*/}" '
        function rel(u, s) { sub(/\/$/, "", u); return s ~ /\/$/ ? u "/" s "InRelease" : u "/dists/" s "/InRelease" }
        function flush(  a, b, n, m, U, S) {
          if (en != "no" && types ~ /(^| )deb( |$)/) {
            n = split(uris, U, " "); m = split(suites, S, " ")
            for (a = 1; a <= n; a++) for (b = 1; b <= m; b++) if (U[a] ~ /^https?:\/\//) print "apt|" rel(U[a], S[b]) "|" f
          }
          types = ""; uris = ""; suites = ""; en = ""
        }
        /^[ \t]*$/ { flush(); next }
        { v = $0; sub(/^[^:]*:[ \t]*/, "", v); k = tolower($1) }
        k == "types:" { types = v } k == "uris:" { uris = v } k == "suites:" { suites = v } k == "enabled:" { en = tolower(v) }
        END { flush() }' "$f"
    fi
  done
  while IFS='|' read -r kind url file; do
    if [ -z "$url" ]; then
      continue
    fi
    if [[ " $(os_release ID) $(os_release ID_LIKE) " == *suse* ]]; then
      url="${url//\$releasever_major/$major}"
      url="${url//\$releasever/$rel}"
    else
      url="${url//\$releasever_major/$major}"
      url="${url//\$releasever/$major}"
    fi
    url="${url//\$basearch/$arch}"
    url="${url//\$arch/$arch}"
    url="${url//\$stream/$major-stream}"
    case "$url" in
      http://*|https://*) ;;
      *) continue ;;
    esac
    if [[ "$url" == *\$* ]] || { [ "$kind" = "repomd" ] && [[ "$url" == *\?* ]]; }; then
      kind="any"
    fi
    case "$kind" in
      repomd) url="${url%/}/repodata/repomd.xml" ;;
      any)
        h="${url#*://}"
        url="${url%%://*}://${h%%[/?]*}/"
        ;;
    esac
    printf '%s|%s|%s\n' "$kind" "$url" "$file"
  done <<< "$(
    for f in "$NET_ETC"/yum.repos.d/*.repo "$NET_ETC"/zypp/repos.d/*.repo; do
      if [ -r "$f" ]; then
        awk -v f="${f##*/}" '
          function flush() {
            if (sec != "" && en != "0" && en != "false" && en != "no") {
              if (base != "") print (cert != "" ? "any" : "repomd") "|" base "|" f
              else if (meta != "") print "meta|" meta "|" f
              else if (mirror != "") print "meta|" mirror "|" f
            }
            sec = ""; en = "1"; base = ""; meta = ""; mirror = ""; cert = ""
          }
          /^\[/ { flush(); sec = $0; next }
          { v = $0; sub(/^[^=]*=[ \t]*/, "", v); k = $0; sub(/[ \t]*=.*/, "", k); gsub(/[ \t]/, "", k) }
          k == "enabled" { en = tolower(v) }
          k == "baseurl" { split(v, a, /[ \t,]+/); base = a[1] }
          k == "metalink" { meta = v }
          k == "mirrorlist" { mirror = v }
          k == "sslclientcert" { cert = v }
          END { flush() }' "$f"
      fi
    done
  )"
}

# The package repositories as rows of net_rows, one per host (at most 6)
net_repo_rows() {
  local kind url file host port seen=" " n=0 what
  while IFS='|' read -r kind url file; do
    if [ -z "$url" ]; then
      continue
    fi
    host="${url#*://}"
    host="${host%%[/?]*}"
    port=443
    if [[ "$url" == http://* ]]; then
      port=80
    fi
    if [[ "$host" == *:* ]]; then
      port="${host##*:}"
      host="${host%:*}"
    fi
    if [[ "$seen" == *" $host "* ]]; then
      continue
    fi
    seen="$seen$host "
    n=$((n + 1))
    if [ "$n" -gt 6 ]; then
      break
    fi
    what="packages ($file)"
    printf 'repo%s|%s|%s|req|%s|%s:%s\n' "$n" "$host" "$port" "${what:0:27}" "$kind" "$url"
  done <<< "$(net_repo_urls)"
}

# net_rows -> the sites this installation needs, one per line: KEY|HOST|PORT|LEVEL|WHAT|URL. LEVEL: req (the
# installation stops without it), opt (WHAT does not work without it) or - (not needed here; WHAT says why).
# Built from the settings, the engine, this system and the domain - never a fixed list.
net_rows() {
  local kind installed="no" need repo os="linux" arch="x86_64" h name
  kind="$(net_engine)"
  if [ -n "$kind" ] && net_installed "$kind"; then
    installed="yes"
  fi
  name="$(kind_name "${kind:-podman}")"
  echo "hub|registry-1.docker.io|443|req|images (Docker Hub)|https://registry-1.docker.io/v2/"
  echo "hubauth|auth.docker.io|443|req|image downloads (token)|https://auth.docker.io/token?service=registry.docker.io&scope=repository:$CATALOG_IMAGE_REPO:pull"
  echo "hubcdn|production.cloudfront.docker.com|443|req|image layers (Docker Hub)|"
  echo "ghcr|ghcr.io|443|req|MinIO image|https://ghcr.io/v2/"
  echo "ghcrcdn|pkg-containers.githubusercontent.com|443|req|MinIO image layers|"
  if [ "$OS_KIND" != "Darwin" ]; then
    # the packages of this Linux: only to install the engine
    if [ "$installed" = "yes" ]; then
      h="$(net_repo_rows)"
      h="${h%%$'\n'*}"
      h="$(printf '%s' "$h" | cut -d'|' -f2)"
      echo "repo|${h:-package repositories}|443|-|not needed: $name is there|"
    else
      net_repo_rows
    fi
    repo="$(net_docker_repo)"
    case "$kind" in
      "") echo "dockerrepo|download.docker.com|443|opt|Docker Engine (if chosen)|https://download.docker.com/linux/${repo:-centos}/gpg" ;;
      docker)
        if [ "$installed" = "yes" ]; then
          echo "dockerrepo|download.docker.com|443|-|not needed: Docker is there|"
        elif [ -z "$repo" ]; then
          echo "dockerrepo|download.docker.com|443|-|not needed: distro Docker|"
        else
          echo "dockerrepo|download.docker.com|443|req|Docker Engine packages|https://download.docker.com/linux/$repo/gpg"
        fi
        ;;
      *) echo "dockerrepo|download.docker.com|443|-|not needed: $name|" ;;
    esac
  else
    os="darwin"
  fi
  if [ "$(engine_arch)" = "arm64" ]; then
    arch="aarch64"
  fi
  need="$(net_compose_need "$kind")"
  case "$need" in
    req)
      echo "github|github.com|443|req|Docker Compose|https://github.com/docker/compose/releases/latest"
      echo "ghassets|release-assets.githubusercontent.com|443|req|Docker Compose download|https://github.com/docker/compose/releases/latest/download/docker-compose-$os-$arch.sha256"
      ;;
    opt)
      echo "github|github.com|443|opt|Compose update (optional)|https://github.com/docker/compose/releases/latest"
      echo "ghassets|release-assets.githubusercontent.com|443|opt|Compose download (optional)|https://github.com/docker/compose/releases/latest/download/docker-compose-$os-$arch.sha256"
      ;;
    *) echo "github|github.com|443|-|not needed: has Compose|" ;;
  esac
  if [ "$OS_KIND" = "Darwin" ]; then
    if [ "$installed" = "yes" ]; then
      echo "brew|formulae.brew.sh|443|-|not needed: $name is there|"
    else
      echo "brew|formulae.brew.sh|443|req|Homebrew|https://formulae.brew.sh/api/formula.jws.json"
    fi
    case "$kind:$installed" in
      podman:no) echo "quay|quay.io|443|req|Podman machine image|https://quay.io/v2/" ;;
      :no) echo "quay|quay.io|443|opt|Podman machine (if chosen)|https://quay.io/v2/" ;;
      *) echo "quay|quay.io|443|-|not needed: $name|" ;;
    esac
    case "$kind:$installed" in
      docker:no) echo "desktop|desktop.docker.com|443|req|Docker Desktop|https://desktop.docker.com/mac/main/arm64/appcast.xml" ;;
      :no) echo "desktop|desktop.docker.com|443|opt|Docker Desktop (if chosen)|https://desktop.docker.com/mac/main/arm64/appcast.xml" ;;
      *) echo "desktop|desktop.docker.com|443|-|not needed: $name|" ;;
    esac
  fi
  echo "hubapi|hub.docker.com|443|opt|version list (optional)|https://hub.docker.com/v2/repositories/$CATALOG_IMAGE_REPO/tags?page_size=1"
  h="${INSTALLER_URL#*://}"
  echo "installer|${h%%/*}|443|opt|installer update (optional)|$INSTALLER_URL"
  h="${CATALOG_CLOUD_URL#*://}"
  echo "cloud|${h%%/*}|443|opt|catalog data (optional)|${CATALOG_CLOUD_URL%/}/v1/license/isValid"
  echo "license|licenses.raynet.de|443|opt|license (optional)|https://licenses.raynet.de/Account/Login.aspx"
  if [ "$INSTALL_NGINX_PROXY_MANAGER" != "true" ]; then
    echo "acme|acme-v02.api.letsencrypt.org|443|-|not needed: no NPM|"
    echo "awsip|ip-ranges.amazonaws.com|443|-|not needed: no NPM|"
    echo "cfip|www.cloudflare.com|443|-|not needed: no NPM|"
    return 0
  fi
  if [ -z "$CATALOG_DOMAIN" ]; then
    echo "acme|acme-v02.api.letsencrypt.org|443|-|not needed: no domain|"
  elif domain_private "$CATALOG_DOMAIN"; then
    echo "acme|acme-v02.api.letsencrypt.org|443|-|not needed: .${CATALOG_DOMAIN##*.} name|"
  else
    echo "acme|acme-v02.api.letsencrypt.org|443|req|HTTPS certificate|https://acme-v02.api.letsencrypt.org/directory"
  fi
  echo "awsip|ip-ranges.amazonaws.com|443|opt|NPM IP ranges (optional)|https://ip-ranges.amazonaws.com/ip-ranges.json"
  echo "cfip|www.cloudflare.com|443|opt|NPM IP ranges (optional)|https://www.cloudflare.com/ips-v4"
}

# The curl config of the proxy of the check (on stdin): its address with the login, and the names it reaches
# directly (NET_VIA_NO: those of the settings or of a PAC file - never the ones of the environment)
# An https:// proxy: its certificate is checked whenever the login goes to it (the system's certificates
# and the company's); only a proxy without a login is taken unchecked
net_via_config() {
  printf 'proxy = "%s"\nnoproxy = "%s"\n' "$NET_VIA" "$NET_VIA_NO"
  case "$NET_VIA" in
    https://*@*)
      if [ -n "$INTERNET_PROXY_CA_FILE" ] && [ -r "$PROXY_CA_BUNDLE" ]; then
        printf 'proxy-cacert = "%s"\n' "$PROXY_CA_BUNDLE"
      fi
      ;;
    https://*) printf 'proxy-insecure\n' ;;
  esac
}

# net_curl OUT URL [CURL-OPTION...] -> one request of the check: direct, or through NET_VIA (handed to curl
# in its config on stdin, so the login is on no command line). The certificate is checked against the
# certificates of this system (never -k: with it curl loads none, and every site would look inspected); a
# TLS inspection ends with exit code 60 (or 51) and its verify result. The answer lands in OUT.hdr (the
# proxy's CONNECT answer included) and OUT.body. Prints: EXIT CODE CONNECT VERIFY EFFECTIVE-URL IP
net_curl() {
  local out="$1" url="$2" w="" rc=0 fmt='%{http_code} %{http_connect} %{ssl_verify_result} %{url_effective} %{remote_ip}'
  shift 2
  : > "$out.hdr"
  : > "$out.body"
  if [ -n "$NET_VIA" ]; then
    w="$(net_via_config | curl -sS -K - -o "$out.body" -D "$out.hdr" --connect-timeout "$NET_CT" --max-time "$NET_MT" -w "$fmt" "$@" "$url" 2>"$out.err")" || rc=$?
  else
    w="$(curl -sS --noproxy '*' -o "$out.body" -D "$out.hdr" --connect-timeout "$NET_CT" --max-time "$NET_MT" -w "$fmt" "$@" "$url" 2>"$out.err")" || rc=$?
  fi
  printf '%s %s' "$rc" "${w:-000 000 0 $url}"
}

# The issuer of the certificate a site presents here (the CA of a TLS inspection); the verbose output of
# curl stays in memory (it holds the proxy login)
net_issuer() {
  local v=""
  if [ -n "$NET_VIA" ]; then
    v="$(net_via_config | curl -vks -K - -o /dev/null --connect-timeout "$NET_CT" --max-time "$NET_MT" "$1" 2>&1)" || true
  else
    v="$(curl -vks --noproxy '*' -o /dev/null --connect-timeout "$NET_CT" --max-time "$NET_MT" "$1" 2>&1)" || true
  fi
  v="$(printf '%s\n' "$v" | sed -n 's/^\*  *issuer: *//p')"
  v="${v%%$'\n'*}"
  printf '%s' "${v//|//}"
}

# The login methods a proxy offers in its answer OUT.hdr (Proxy-Authenticate): Basic, NTLM, Negotiate, Digest
net_auth_schemes() {
  tr -d '\r' < "$1" 2>/dev/null | awk 'tolower($1) == "proxy-authenticate:" { s = $2; sub(/,.*/, "", s); if (!seen[s]++) printf "%s%s", (n++ ? " " : ""), s }'
}

# net_sig OUT SIGNATURE -> true when the answer holds SIGNATURE: B:REGEX in the body, H:REGEX in the
# headers (extended, any case); empty: always
net_sig() {
  case "$2" in
    "") return 0 ;;
    B:*) grep -Eqi -- "${2#B:}" "$1.body" 2>/dev/null ;;
    H:*) grep -Eqi -- "${2#H:}" "$1.hdr" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# net_class EXIT CODE CONNECT VERIFY IP OUT EXPECT SIGNATURE HOST URL -> STATUS|DETAIL of one answer.
# STATUS: OK, NO DNS, PROXY DNS, BLOCKED, REFUSED, PROXY LOGIN, DENIED, TLS INSPECTED, CLOCK, TLS RESET,
# WRONG ANSWER or LIMIT (curl's exit code, the proxy's CONNECT answer, the HTTP code, the certificate check,
# then the signature: block pages and captive portals also answer 200)
net_class() {
  local rc="$1" code="$2" conn="$3" ver="$4" ip="$5" out="$6" expect="$7" sig="$8" host="$9" url="${10}" s
  case "$rc" in
    6) echo "NO DNS|the name does not resolve - only a proxy can reach out?"; return 0 ;;
    5) echo "PROXY DNS|the proxy's own name does not resolve"; return 0 ;;
    28)
      if [ -n "$NET_VIA" ]; then
        echo "BLOCKED|no answer in time - the proxy or a firewall drops it"
      else
        echo "BLOCKED|no answer in $NET_CT s - a firewall drops it"
      fi
      return 0
      ;;
    7)
      if [ -n "$NET_VIA" ]; then
        echo "REFUSED|the proxy refuses the connection (wrong port?)"
      else
        echo "REFUSED|connection refused (firewall${ip:+, or DNS points at $ip})"
      fi
      return 0
      ;;
  esac
  if [ "$conn" = "407" ] || [ "$code" = "407" ]; then
    s="$(net_auth_schemes "$out.hdr")"
    echo "PROXY LOGIN|the proxy asks for a login${s:+ ($s)}"
    return 0
  fi
  if [ "$rc" != "0" ] && [ -n "$conn" ] && [ "$conn" != "000" ] && [ "$conn" != "200" ]; then
    echo "DENIED|the proxy or firewall refuses this site (HTTP $conn)"
    return 0
  fi
  case "$ver" in
    0|"") ;;
    9|10)
      echo "CLOCK|check the server clock (date: $(date '+%Y-%m-%d %H:%M'))"
      return 0
      ;;
    *)
      s="$(net_issuer "$url")"
      echo "TLS INSPECTED|certificate from \"${s:-an unknown issuer}\""
      return 0
      ;;
  esac
  case "$rc" in
    0) ;;
    51|60)
      s="$(net_issuer "$url")"
      if [[ "$NET_VIA" == https://*@* ]] && [ -z "$s" ]; then
        echo "TLS INSPECTED|certificate not trusted (of the site, or of the https:// proxy)"
      else
        echo "TLS INSPECTED|certificate from \"${s:-an unknown issuer}\""
      fi
      return 0
      ;;
    35|52|56)
      echo "TLS RESET|TLS was cut - often a filter on the site name"
      return 0
      ;;
    *)
      echo "BLOCKED|no answer (curl error $rc)"
      return 0
      ;;
  esac
  if [ "$code" = "429" ]; then
    echo "LIMIT|Docker Hub pull limit reached"
    return 0
  fi
  if [[ " $expect " == *" $code "* ]] && net_sig "$out" "$sig"; then
    echo "OK|"
    return 0
  fi
  if [ "$code" = "403" ] || grep -qi '^x-squid-error' "$out.hdr" 2>/dev/null; then
    echo "DENIED|the proxy or firewall refuses this site"
    return 0
  fi
  echo "WRONG ANSWER|an answer came (HTTP $code), but not from $host (block or login page?)"
}

# net_get OUT URL EXPECT SIGNATURE [CURL-OPTION...] -> NET_R (STATUS|DETAIL), NET_CODE and NET_EFF (the URL
# the answer came from) of one request: EXPECT the HTTP codes that count as the site's answer, SIGNATURE
# what that answer holds (see net_sig)
net_get() {
  local out="$1" url="$2" expect="$3" sig="$4" rc code conn ver eff ip host
  shift 4
  if [ "$NET_TOOL" = "wget" ]; then
    net_get_wget "$out" "$url" "$expect"
    return 0
  fi
  read -r rc code conn ver eff ip <<< "$(net_curl "$out" "$url" "$@")"
  NET_CODE="${code:-000}"
  NET_EFF="${eff:-$url}"
  host="${NET_EFF#*://}"
  host="${host%%[/:?]*}"
  NET_R="$(net_class "$rc" "$NET_CODE" "${conn:-000}" "${ver:-0}" "${ip:-}" "$out" "$expect" "$sig" "$host" "$url")"
}

# net_get with wget, where curl is missing: fewer classes (reachable, refused by the proxy or the site, login,
# certificate, no answer); the proxy through the environment, as wget reads it
net_get_wget() {
  local out="$1" url="$2" expect="$3" rc=0 v code
  if [ -n "$NET_VIA" ]; then
    v="$(https_proxy="$NET_VIA" http_proxy="$NET_VIA" no_proxy="" wget --spider -S -T "$NET_MT" -t 1 "$url" 2>&1)" || rc=$?
  else
    v="$(wget --no-proxy --spider -S -T "$NET_MT" -t 1 "$url" 2>&1)" || rc=$?
  fi
  code="$(printf '%s\n' "$v" | grep -o 'HTTP/[0-9.]* [0-9][0-9][0-9]' | tail -n 1)" || code=""
  NET_CODE="${code##* }"
  NET_CODE="${NET_CODE:-000}"
  NET_EFF="$url"
  case "$rc" in
    0) NET_R="OK|" ;;
    5) NET_R="TLS INSPECTED|the certificate is not trusted (wget tells no more)" ;;
    4)
      if [[ "$v" == *"unable to resolve"* ]]; then
        NET_R="NO DNS|the name does not resolve"
      else
        NET_R="BLOCKED|no answer"
      fi
      ;;
    8)
      if [[ " $expect " == *" $NET_CODE "* ]]; then
        NET_R="OK|"
      elif [ "$NET_CODE" = "407" ]; then
        NET_R="PROXY LOGIN|the proxy asks for a login"
      elif [ "$NET_CODE" = "403" ]; then
        NET_R="DENIED|the proxy or firewall refuses this site"
      else
        NET_R="WRONG ANSWER|an answer came (HTTP $NET_CODE), but not the expected one"
      fi
      ;;
    *) NET_R="BLOCKED|no answer (wget error $rc)" ;;
  esac
}

# The anonymous pull token in the answer OUT.body
net_token() {
  local t
  t="$(grep -o '"token" *: *"[^"]*"' "$1.body" 2>/dev/null)" || t=""
  t="${t%%$'\n'*}"
  t="${t%\"}"
  printf '%s' "${t##*\"}"
}

# net_probe_layers OUT docker|ghcr -> NET_R and NET_HOST: the host that serves the image layers, learned
# from the redirect of a layer download (Docker Hub's CDN, GitHub's package host), and whether it answers.
# Spends no Docker Hub pull: its manifest only as HEAD (which also tells the pulls left), the layer from
# Docker Hub's tag list.
net_probe_layers() {
  local out="$1" reg repo tag token digest="" loc v body
  if [ "$NET_TOOL" != "curl" ]; then
    NET_R="NOT TESTED|needs curl"
    return 0
  fi
  if [ "$2" = "docker" ]; then
    reg="registry-1.docker.io"
    repo="$CATALOG_IMAGE_REPO"
    tag="$CATALOG_VERSION"
    NET_HOST="production.cloudfront.docker.com"
    net_get "$out.t" "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" "200" 'B:"token"'
  else
    component_info minio
    reg="ghcr.io"
    repo="${C_IMAGES#ghcr.io/}"
    tag="$MINIO_TAG"
    NET_HOST="pkg-containers.githubusercontent.com"
    net_get "$out.t" "https://ghcr.io/token?scope=repository:$repo:pull&service=ghcr.io" "200" 'B:"token"'
  fi
  if [ "${NET_R%%|*}" != "OK" ]; then
    NET_R="NOT TESTED|needs the login of $reg first"
    return 0
  fi
  token="$(net_token "$out.t")"
  if [ "$2" = "docker" ]; then
    net_get "$out.m" "https://$reg/v2/$repo/manifests/$tag" "200" "" -I -H "Authorization: Bearer $token" -H "Accept: $MANIFEST_TYPES"
    if [ "$NET_CODE" = "429" ]; then
      NET_R="LIMIT|Docker Hub pull limit reached"
      return 0
    fi
    v="$(tr -d '\r' < "$out.m.hdr" | awk -F': *' 'tolower($1) == "ratelimit-remaining" { r = $2 } tolower($1) == "ratelimit-limit" { l = $2 } END { sub(/;.*/, "", r); sub(/;.*/, "", l); if (r != "" && l != "") print r " " l }')" || v=""
    if [ -n "$v" ] && [ -n "$NET_TMP" ]; then
      printf '%s\n' "$v" > "$NET_TMP/hub.limit"
    fi
    digest="$(tr -d '\r' < "$out.m.hdr" | awk -F': *' 'tolower($1) == "docker-content-digest" { print $2 }')" || digest=""
    digest="${digest%%$'\n'*}"
    net_get "$out.l" "https://hub.docker.com/v2/repositories/$repo/tags/$tag/images" "200" 'B:"layers"'
    v="$(grep -o '"layers" *: *\[[^]]*' "$out.l.body" 2>/dev/null | grep -o 'sha256:[0-9a-f]\{64\}')" || v=""
    v="${v%%$'\n'*}"
    digest="${v:-$digest}"
  else
    net_get "$out.m" "https://$reg/v2/$repo/manifests/$tag" "200" 'B:"(layers|manifests)"' -H "Authorization: Bearer $token" -H "Accept: $MANIFEST_TYPES"
    body="$(tr -d ' \t\r\n' < "$out.m.body" 2>/dev/null)" || body=""
    if [[ "$body" == *'"manifests"'* ]]; then
      v="$(printf '%s\n' "$body" | sed 's/},{/}\n{/g' | grep '"amd64"' | grep -o '"digest":"sha256:[0-9a-f]*"')" || v=""
      if [ -z "$v" ]; then
        v="$(printf '%s\n' "$body" | grep -o '"digest":"sha256:[0-9a-f]*"')" || v=""
      fi
      v="${v%%$'\n'*}"
      v="${v#\"digest\":\"}"
      v="${v%\"}"
      if [ -n "$v" ]; then
        net_get "$out.m" "https://$reg/v2/$repo/manifests/$v" "200" 'B:"layers"' -H "Authorization: Bearer $token" -H "Accept: $MANIFEST_TYPES"
        body="$(tr -d ' \t\r\n' < "$out.m.body" 2>/dev/null)" || body=""
      fi
    fi
    v="$(printf '%s\n' "$body" | grep -o '"layers":\[[^]]*' | grep -o 'sha256:[0-9a-f]\{64\}')" || v=""
    digest="${v%%$'\n'*}"
  fi
  if [ -z "$digest" ]; then
    NET_R="NOT TESTED|no layer of $repo to try"
    return 0
  fi
  net_get "$out.b" "https://$reg/v2/$repo/blobs/$digest" "301 302 303 307 308" 'H:^location:' -H "Authorization: Bearer $token"
  loc="$(tr -d '\r' < "$out.b.hdr" | sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]: *//p')" || loc=""
  loc="${loc%%$'\n'*}"
  if [ -z "$loc" ]; then
    NET_R="NOT TESTED|$reg named no layer host (HTTP $NET_CODE)"
    return 0
  fi
  NET_HOST="${loc#*://}"
  NET_HOST="${NET_HOST%%[/:?]*}"
  net_get "$out.c" "$loc" "200 206" "" -r 0-0
}

# net_probe INDEX -> tests the site of row INDEX (in the background): STATUS|DETAIL|HOST into
# $NET_TMP/INDEX.res (HOST: the one the answer came from, for the hosts learned from a redirect)
net_probe() {
  local i="$1" key="${NET_KEYS[$1]}" url="${NET_URLS[$1]}" host="${NET_HOSTS[$1]}" out="$NET_TMP/$1" h
  NET_R="BLOCKED|no result"
  case "$key" in
    hub) net_get "$out" "$url" "401" 'H:realm="https://auth\.docker\.io/token"' ;;
    hubauth) net_get "$out" "$url" "200" 'B:"token"' ;;
    hubcdn) net_probe_layers "$out" docker; host="$NET_HOST" ;;
    ghcr) net_get "$out" "$url" "401" 'H:realm="https://ghcr\.io/token"' ;;
    ghcrcdn) net_probe_layers "$out" ghcr; host="$NET_HOST" ;;
    repo*)
      case "${url%%:*}" in
        apt) net_get "$out" "${url#*:}" "200" 'B:BEGIN PGP SIGNED' ;;
        repomd) net_get "$out" "${url#*:}" "200" 'B:<repomd' ;;
        meta) net_get "$out" "${url#*:}" "200" 'B:(<metalink|^https?://)' ;;
        *) net_get "$out" "${url#*:}" "200 301 302 400 401 403 404" "" -I ;;
      esac
      ;;
    dockerrepo) net_get "$out" "$url" "200" 'B:BEGIN PGP PUBLIC KEY BLOCK' ;;
    github) net_get "$out" "$url" "301 302" 'H:^location: .*/releases/tag/' -I ;;
    ghassets)
      if [ "$NET_TOOL" != "curl" ]; then
        NET_R="NOT TESTED|needs curl"
      else
        net_get "$out" "$url" "200 206" "" -L -r 0-0
        h="${NET_EFF#*://}"
        h="${h%%[/:?]*}"
        if [ -n "$h" ] && [ "$h" != "github.com" ]; then
          host="$h"
        fi
      fi
      ;;
    brew) net_get "$out" "$url" "200" "" -I ;;
    quay) net_get "$out" "$url" "401" 'H:realm="https://quay\.io/v2/auth"' ;;
    desktop) net_get "$out" "$url" "200" 'B:<rss' ;;
    hubapi) net_get "$out" "$url" "200" 'B:"results"' ;;
    installer) net_get "$out" "$url" "200 206" 'B:^#!/usr/bin/env bash' -r 0-40 ;;
    cloud) net_get "$out" "$url" "200" 'B:^true' ;;
    license) net_get "$out" "$url" "200" 'H:^x-served-by: *licenses\.raynet\.de' ;;
    acme) net_get "$out" "$url" "200" 'B:"newAccount"' ;;
    awsip) net_get "$out" "$url" "200 206" 'B:"prefixes"' -r 0-1023 ;;
    cfip) net_get "$out" "$url" "200" 'B:^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' ;;
  esac
  NET_R="${NET_R//$'\n'/ }"
  printf '%s|%s\n' "$NET_R" "$host" > "$out.tmp" && mv -f -- "$out.tmp" "$out.res"
}

# net_line STATUS LEVEL HOST WHAT DETAIL -> one row of the check (80 columns; the detail below it)
net_line() {
  local st="$1" level="$2" host="$3" what="$4" detail="$5" color="$C_RED" l
  case "$st" in
    OK) color="$C_GRN" ;;
    -|"NOT TESTED") color="$C_DIM" ;;
    *)
      if [ "$level" != "req" ]; then
        color="$C_YLW"
      fi
      ;;
  esac
  printf '  %s %s %s\n' "$color$(ui_pad "$st" 13)$C_RST" "$(ui_pad "$host" 36)" "$what"
  if [ -n "$detail" ]; then
    while IFS= read -r l; do
      printf '%17s%s\n' "" "$C_DIM$l$C_RST"
    done <<< "$(printf '%s\n' "$detail" | fold -s -w 62 | sed 's/ *$//')"
  fi
}

# net_kill_tree PID -> PID and every process it started (the curl of a stopped check would run on until its
# time is up); the whole tree is collected first, as its processes go to init once their parent ends
net_kill_tree() {
  local -a all=("$1")
  local i=0 c
  while [ "$i" -lt "${#all[@]}" ] && [ "${#all[@]}" -lt 200 ]; do
    while IFS= read -r c; do
      if [ -n "$c" ]; then
        all+=("$c")
      fi
    done <<< "$(pgrep -P "${all[i]}" 2>/dev/null || true)"
    i=$((i + 1))
  done
  kill "${all[@]}" 2>/dev/null || true
}

# net_check [show|quiet|probe] [KEY...] -> checks the sites of net_rows at the same time (one request after
# the other only inside a row), directly or through NET_VIA. show: the table and the verdict; quiet: nothing
# on the screen; probe: only the required sites, nothing shown or cached (the candidates of a PAC file).
# KEY...: only these rows. Fills NET_* and, after a full check of the settings in use, the cache of the
# menu. 0 when every required site answers.
net_check() {
  local mode="${1:-show}" only="${2:-}" key host port level what url i n st det h stopped="" traps=""
  local -a pids=()
  NET_KEYS=()
  NET_HOSTS=()
  NET_PORTS=()
  NET_LEVELS=()
  NET_WHAT=()
  NET_URLS=()
  NET_STATUS=()
  NET_DETAIL=()
  NET_REQ_BAD=0
  NET_OPT_BAD=0
  NET_TOTAL=0
  NET_NODNS=""
  NET_LIMIT=""
  NET_SECS=0
  while IFS='|' read -r key host port level what url; do
    if [ -z "$key" ] || { [ -n "$only" ] && [[ " $only " != *" $key "* ]]; } || { [ "$mode" = "probe" ] && [ "$level" != "req" ]; }; then
      continue
    fi
    NET_KEYS+=("$key")
    NET_HOSTS+=("$host")
    NET_PORTS+=("$port")
    NET_LEVELS+=("$level")
    NET_WHAT+=("$what")
    NET_URLS+=("$url")
    NET_STATUS+=("-")
    NET_DETAIL+=("")
  done <<< "$(net_rows)"
  n="${#NET_KEYS[@]}"
  if command -v curl >/dev/null 2>&1; then
    NET_TOOL="curl"
  elif command -v wget >/dev/null 2>&1; then
    NET_TOOL="wget"
  else
    if [ "$mode" = "show" ]; then
      err "Neither curl nor wget is installed: the sites cannot be checked from here."
      echo "  These are the sites the installation needs:"
      net_hosts_text | sed 's/^/  /'
    fi
    return 1
  fi
  if ! NET_TMP="$(mktemp -d)"; then
    return 1
  fi
  if [ "$mode" != "quiet" ]; then
    traps="$(trap -p INT TERM)"
    trap 'stopped="yes"' INT TERM
  fi
  NET_SECS="$SECONDS"
  if [ "$mode" = "show" ]; then
    printf '  %s\n' "${C_BLD}Internet access$C_RST - ${NET_VIA_TEXT:-direct, no proxy}"
  fi
  # one name first: a server that resolves no internet names reaches out only through a proxy
  if [ -z "$NET_VIA" ] && [ "$n" -gt 0 ] && [ "${NET_KEYS[0]}" = "hub" ]; then
    net_probe 0 || true
    IFS='|' read -r st det h < "$NET_TMP/0.res" || st=""
    if [ "$st" = "NO DNS" ]; then
      NET_NODNS="yes"
    fi
  fi
  for ((i = 0; i < n; i++)); do
    if [ -f "$NET_TMP/$i.res" ]; then
      continue
    fi
    if [ "${NET_LEVELS[i]}" = "-" ]; then
      printf -- '-||%s\n' "${NET_HOSTS[i]}" > "$NET_TMP/$i.res"
    elif [ -n "$NET_NODNS" ]; then
      printf 'NO DNS||%s\n' "${NET_HOSTS[i]}" > "$NET_TMP/$i.res"
    else
      ( set +e; net_probe "$i" ) </dev/null >/dev/null 2>&1 &
      pids[i]=$!
    fi
  done
  for ((i = 0; i < n; i++)); do
    while [ ! -f "$NET_TMP/$i.res" ] && [ -z "$stopped" ]; do
      if [ -n "$NET_WATCH" ] && ! kill -0 "$NET_WATCH" 2>/dev/null; then
        stopped="yes"
        break
      fi
      if [ -n "${pids[i]:-}" ] && ! kill -0 "${pids[i]}" 2>/dev/null; then
        if [ ! -f "$NET_TMP/$i.res" ]; then
          printf 'BLOCKED|no result|%s\n' "${NET_HOSTS[i]}" > "$NET_TMP/$i.res"
        fi
        break
      fi
      sleep 0.1
    done
    if [ -n "$stopped" ]; then
      break
    fi
    IFS='|' read -r st det h < "$NET_TMP/$i.res" || true
    NET_STATUS[i]="${st:--}"
    NET_DETAIL[i]="$det"
    NET_HOSTS[i]="${h:-${NET_HOSTS[i]}}"
    case "${NET_STATUS[i]}" in
      -) ;;
      OK|"NOT TESTED") NET_TOTAL=$((NET_TOTAL + 1)) ;;
      *)
        NET_TOTAL=$((NET_TOTAL + 1))
        if [ "${NET_LEVELS[i]}" = "req" ]; then
          NET_REQ_BAD=$((NET_REQ_BAD + 1))
        else
          NET_OPT_BAD=$((NET_OPT_BAD + 1))
        fi
        ;;
    esac
    if [ "$mode" = "show" ]; then
      net_line "${NET_STATUS[i]}" "${NET_LEVELS[i]}" "${NET_HOSTS[i]}" "${NET_WHAT[i]}" "${NET_DETAIL[i]}"
    fi
  done
  if [ -n "$stopped" ]; then
    for i in ${pids[@]+"${!pids[@]}"}; do
      net_kill_tree "${pids[i]}"
    done
  fi
  NET_LIMIT="$(cat -- "$NET_TMP/hub.limit" 2>/dev/null)" || NET_LIMIT=""
  rm -rf -- "$NET_TMP"
  NET_TMP=""
  NET_SECS=$((SECONDS - NET_SECS))
  if [ "$mode" != "quiet" ]; then
    trap - INT TERM
    eval "$traps"
  fi
  if [ -n "$stopped" ]; then
    echo
    warn "The check was stopped."
    return 130
  fi
  if [ "$mode" != "probe" ] && [ -z "$only" ] && [ "$NET_VIA" = "$(net_via_now)" ]; then
    net_cache_write
  fi
  if [ "$mode" = "show" ]; then
    echo
    net_verdict
  fi
  [ "$NET_REQ_BAD" -eq 0 ] && [ -z "$NET_NODNS" ]
}

# The verdict after the table: what cannot be reached, what that means, the way out
net_verdict() {
  local i what="" hub="no" acme="no"
  for ((i = 0; i < ${#NET_KEYS[@]}; i++)); do
    case "${NET_STATUS[i]}" in
      OK|-|"NOT TESTED") ;;
      *)
        case "${NET_KEYS[i]}" in
          hub|hubauth|hubcdn) hub="yes" ;;
        esac
        if [ "${NET_LEVELS[i]}" != "req" ] && [[ "$what, " != *", ${NET_WHAT[i]% (optional)}, "* ]]; then
          what="$what, ${NET_WHAT[i]% (optional)}"
        fi
        ;;
    esac
    if [ "${NET_KEYS[i]}" = "acme" ] && [ "${NET_LEVELS[i]}" = "req" ]; then
      acme="yes"
    fi
  done
  if [ -n "$NET_NODNS" ]; then
    err "This server cannot resolve internet names: it probably reaches the"
    echo "  internet only through a proxy."
  elif [ "$NET_REQ_BAD" -gt 0 ]; then
    err "$NET_REQ_BAD required site(s) cannot be reached$(if [ -z "$NET_VIA" ]; then printf '. A proxy is probably needed'; fi)."
  fi
  if [ "$hub" = "yes" ]; then
    echo "  Without Docker Hub: a proxy, the offline bundle (option 8 on a computer with"
    echo "  internet), or an internal registry mirror."
  fi
  if [ -n "$what" ] && [ -z "$NET_NODNS" ]; then
    warn "Not reachable, so these do not work here: ${what#, }."
  fi
  if [ "$NET_REQ_BAD" -eq 0 ] && [ -z "$NET_NODNS" ]; then
    ok "Internet access works: $((NET_TOTAL - NET_OPT_BAD)) of $NET_TOTAL sites answer ($NET_SECS s)."
  fi
  if [ -n "$NET_LIMIT" ]; then
    echo "  Docker Hub: ${NET_LIMIT% *} of ${NET_LIMIT#* } pulls left (shared by everyone behind the same address)."
  fi
  if [ "$acme" = "yes" ]; then
    echo "  Let's Encrypt also needs port 80 of this server open from the internet - that"
    echo "  cannot be checked from here."
  fi
}

# The proxy of the settings in use, with its login (empty: direct), as the check takes it
net_via_now() {
  if [ -n "$INTERNET_PROXY" ]; then
    net_with_login "$INTERNET_PROXY"
  else
    printf '%s' "$NET_SHELL_PROXY"
  fi
}

# NET_VIA and NET_VIA_TEXT for the proxy in use: INTERNET_PROXY with the saved login, else the proxy of the
# shell, else none (direct)
net_via_settings() {
  local u
  NET_VIA="$(net_via_now)"
  NET_VIA_TEXT=""
  NET_VIA_NO=""
  if [ -n "$INTERNET_PROXY" ]; then
    u="$(proxy_login_user)"
    NET_VIA_TEXT="through $INTERNET_PROXY${u:+, login $u}"
    NET_VIA_NO="$(net_no_list)"
  elif [ -n "$NET_SHELL_PROXY" ]; then
    NET_VIA_TEXT="through the proxy of your shell ($NET_SHELL_NAME)"
    NET_VIA_NO="${NET_SHELL_NO// /}"
  fi
}

# A checksum of what the sites and their answers depend on: a cached check counts only while it is the same
net_signature() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' "$INTERNET_PROXY" "$INTERNET_NO_PROXY" "$(proxy_login | cksum)" "$CONTAINER_ENGINE" \
    "$CATALOG_DOMAIN" "$INSTALL_NGINX_PROXY_MANAGER" "$CATALOG_VERSION" "$(printf '%s' "$NET_SHELL_PROXY" | cksum)" "$INTERNET_PROXY_CA_FILE" \
    | cksum | cut -d' ' -f1
}

# The result of the last full check, for the menu header and option 16: the time, the signature, then one
# line per site (no login in it)
net_cache_write() {
  local i f
  if ! mkdir -p -- "$JOBS_DIR" 2>/dev/null; then
    return 0
  fi
  chmod 700 "$JOBS_DIR" 2>/dev/null || true
  f="$NET_CACHE.$BASHPID"
  if {
      printf '%s|%s|%s\n' "$(date +%s)" "$(net_signature)" "$NET_SECS"
      for ((i = 0; i < ${#NET_KEYS[@]}; i++)); do
        printf '%s|%s|%s|%s|%s|%s\n' "${NET_KEYS[i]}" "${NET_STATUS[i]}" "${NET_LEVELS[i]}" "${NET_HOSTS[i]}" "${NET_WHAT[i]}" "${NET_DETAIL[i]//|//}"
      done
    } > "$f" 2>/dev/null; then
    mv -f -- "$f" "$NET_CACHE" 2>/dev/null || rm -f -- "$f"
  else
    rm -f -- "$f"
  fi
}

# NET_C_REQ, NET_C_OPT (sites that cannot be reached) and NET_C_TOTAL from the cache; 1 when it is missing,
# older than NET_CACHE_TTL seconds, or the settings changed since
net_cache_read() {
  local t sig rest key st level now
  NET_C_REQ=0
  NET_C_OPT=0
  NET_C_TOTAL=0
  if [ ! -r "$NET_CACHE" ] || ! IFS='|' read -r t sig rest < "$NET_CACHE"; then
    return 1
  fi
  now="$(date +%s)"
  if ! [[ "$t" =~ ^[0-9]+$ ]] || [ $((now - t)) -gt "$NET_CACHE_TTL" ] || [ $((now - t)) -lt -60 ] || [ "$sig" != "$(net_signature)" ]; then
    return 1
  fi
  while IFS='|' read -r key st level rest; do
    case "$st" in
      -|"") ;;
      OK|"NOT TESTED") NET_C_TOTAL=$((NET_C_TOTAL + 1)) ;;
      *)
        NET_C_TOTAL=$((NET_C_TOTAL + 1))
        if [ "$level" = "req" ]; then
          NET_C_REQ=$((NET_C_REQ + 1))
        else
          NET_C_OPT=$((NET_C_OPT + 1))
        fi
        ;;
    esac
  done <<< "$(tail -n +2 "$NET_CACHE")"
}

# The check of the menu start: in the background (the menu never waits for it), its result in the cache;
# a fresh cache is used as it is. Called again while the menu stays open: a new check once the cache is
# older than NET_CACHE_TTL. Not on a server marked offline (choice 5 of option 26). The check is no job of
# the menu (a plain wait elsewhere does not wait for it) and stops when the menu has quit.
net_background_start() {
  if [ -n "$NET_BG_PID" ]; then
    if kill -0 "$NET_BG_PID" 2>/dev/null; then
      return 0
    fi
    NET_BG_PID=""
  fi
  if ! net_enabled || [ -f "$NET_OFFLINE_FILE" ]; then
    return 0
  fi
  if [ -n "$NET_BG_AT" ] && [ $((SECONDS - NET_BG_AT)) -lt "$NET_CACHE_TTL" ]; then
    return 0
  fi
  if net_cache_read; then
    return 0
  fi
  NET_BG_AT="$SECONDS"
  ( set +e; NET_WATCH="$$"; NET_CT=5; NET_MT=10; net_via_settings; net_check quiet ) </dev/null >/dev/null 2>&1 &
  NET_BG_PID=$!
  disown "$NET_BG_PID" 2>/dev/null || true
}

# True (once) when the background check of the menu start has ended: the header is drawn again
net_background_done() {
  if [ -n "$NET_BG_PID" ] && ! kill -0 "$NET_BG_PID" 2>/dev/null; then
    NET_BG_PID=""
    return 0
  fi
  return 1
}

# The internet line of the menu header: empty until a check is known
net_header() {
  if ! net_enabled || [ -f "$NET_OFFLINE_FILE" ] || ! net_cache_read; then
    return 0
  fi
  if [ "$NET_C_REQ" -gt 0 ]; then
    printf 'Internet: %s required site%s blocked - 26 shows them' "$NET_C_REQ" "$(if [ "$NET_C_REQ" -gt 1 ]; then printf s; fi)"
  elif [ "$NET_C_OPT" -gt 0 ]; then
    printf 'Internet %s %s optional site%s blocked' "$UI_OK" "$UI_SEP $NET_C_OPT" "$(if [ "$NET_C_OPT" -gt 1 ]; then printf s; fi)"
  else
    printf 'Internet %s' "$UI_OK"
  fi
}

# The internet line of option 16: the check of the menu start when it is fresh, else a check now
net_check_line() {
  local k
  while IFS= read -r k; do
    if [ -z "$k" ]; then
      continue
    elif [ -z "$INTERNET_PROXY" ]; then
      warn "$(kind_name "$k") does not read the proxy of your shell - option 26 saves it."
    else
      warn "$(kind_name "$k") does not use the internet settings yet - option 26 applies them."
    fi
  done <<< "$(net_engine_stale)"
  if [ -f "$NET_OFFLINE_FILE" ]; then
    info "Internet: not checked - an offline installation (option 26 checks it)."
    return 0
  fi
  if ! net_cache_read; then
    info "Checking the internet access (the sites the installation needs)..."
    net_via_settings
    net_check quiet || true
    if ! net_cache_read; then
      warn "The internet access could not be checked - $(hint 26 network-check) shows why."
      return 0
    fi
  fi
  if [ "$NET_C_REQ" -gt 0 ]; then
    warn "Internet: $NET_C_REQ required site(s) cannot be reached - $(hint 26 network-check) shows them."
  elif [ "$NET_C_OPT" -gt 0 ]; then
    ok "Internet: every required site answers, $NET_C_OPT optional one(s) not."
  else
    ok "Internet: all $NET_C_TOTAL sites the installation needs answer."
  fi
}

# net_engine_check -> before the engine is set up: the sites its setup needs (packages, Docker's repository,
# Docker Compose on GitHub, Homebrew); shows only those that cannot be reached. 1 when a required one cannot.
net_engine_check() {
  local i shown="no"
  if ! net_enabled || ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  NET_ENGINE_KIND="$ENGINE_KIND"
  info "Checking the sites the setup of $ENGINE_NAME downloads from..."
  net_via_settings
  net_check quiet "repo1 repo2 repo3 repo4 repo5 repo6 dockerrepo github ghassets brew quay desktop" || true
  NET_ENGINE_KIND=""
  for ((i = 0; i < ${#NET_KEYS[@]}; i++)); do
    case "${NET_STATUS[i]}" in
      OK|-|"NOT TESTED") ;;
      *)
        if [ "$shown" = "no" ]; then
          echo "  The setup of $ENGINE_NAME downloads from these sites, which cannot be"
          echo "  reached:"
          shown="yes"
        fi
        net_line "${NET_STATUS[i]}" "${NET_LEVELS[i]}" "${NET_HOSTS[i]}" "${NET_WHAT[i]}" "${NET_DETAIL[i]}"
        ;;
    esac
  done
  if [ "$NET_REQ_BAD" -gt 0 ]; then
    warn "The setup will probably fail - $(hint 26 network-check) checks the"
    echo "  internet access and sets a proxy."
    return 1
  fi
}

# The sites of this installation for the network team's firewall request (network-hosts, option 26)
net_hosts_text() {
  local key host port level what url acme="no"
  echo "# Sites the Raynet One Technology Catalog installation needs (outbound; HTTPS"
  echo "# unless the port says otherwise). required: the installation stops without it."
  while IFS='|' read -r key host port level what url; do
    if [ -z "$key" ] || [ "$level" = "-" ]; then
      continue
    fi
    if [ "$key" = "acme" ]; then
      acme="yes"
    fi
    printf '%-40s %-8s %s\n' "$host:$port" "$(if [ "$level" = "req" ]; then printf required; else printf optional; fi)" "${what% (optional)}"
  done <<< "$(net_rows)"
  printf '%-40s %-8s %s\n' "packages.packagestore.com:443" "optional" "package store of the Catalog"
  echo "# Docker Hub serves its layers from production.cloudfront.docker.com (the host"
  echo "# its allow list names); when it moves them to another CDN host, the pulls"
  echo "# follow a redirect there: network-check names the host it finds."
  if [ "$acme" = "yes" ]; then
    echo "# Let's Encrypt also needs inbound TCP port 80 to this server from the internet."
  fi
}

# The proxies set on this server, one per line: WHERE|ADDRESS (the shell, /etc/environment, profile.d,
# dnf, yum, rhsm, apt, SUSE, Docker, Podman, ~/.docker/config.json, macOS)
net_found() {
  local f v h p
  if [ -n "$NET_SHELL_PROXY" ]; then
    printf 'your shell (%s)|%s\n' "$NET_SHELL_NAME" "$NET_SHELL_PROXY"
  fi
  for f in "$NET_ETC/environment" "$NET_ETC"/profile.d/*.sh; do
    if [ -r "$f" ]; then
      v="$(awk 'match($0, /^[ \t]*(export[ \t]+)?(https_proxy|HTTPS_PROXY|http_proxy|HTTP_PROXY|all_proxy|ALL_PROXY)=/) { v = substr($0, RLENGTH + 1); gsub(/["\047]/, "", v); sub(/[ \t;].*/, "", v); if (v != "") { print v; exit } }' "$f")" || v=""
      if [ -n "$v" ]; then
        printf '%s|%s\n' "${f#"$NET_ETC"/}" "$v"
      fi
    fi
  done
  for f in "$NET_ETC/dnf/dnf.conf" "$NET_ETC/yum.conf" "$NET_ETC"/yum.repos.d/*.repo; do
    if [ -r "$f" ]; then
      v="$(awk -F= '$1 ~ /^[ \t]*proxy[ \t]*$/ { v = $2; gsub(/[ \t]/, "", v); if (v != "" && v != "_none_") { print v; exit } }' "$f")" || v=""
      if [ -n "$v" ]; then
        printf '%s|%s\n' "${f#"$NET_ETC"/}" "$v"
      fi
    fi
  done
  f="$NET_ETC/rhsm/rhsm.conf"
  if [ -r "$f" ]; then
    h="$(awk -F= '$1 ~ /^[ \t]*proxy_hostname[ \t]*$/ { v = $2; gsub(/[ \t]/, "", v); print v; exit }' "$f")" || h=""
    p="$(awk -F= '$1 ~ /^[ \t]*proxy_port[ \t]*$/ { v = $2; gsub(/[ \t]/, "", v); print v; exit }' "$f")" || p=""
    if [ -n "$h" ]; then
      printf 'rhsm/rhsm.conf|http://%s%s\n' "$h" "${p:+:$p}"
    fi
  fi
  v="$(net_apt_proxy)"
  if [ -n "$v" ]; then
    printf 'apt (Acquire::Proxy)|%s\n' "$v"
  fi
  f="$NET_ETC/sysconfig/proxy"
  if [ -r "$f" ] && grep -q '^PROXY_ENABLED="yes"' "$f"; then
    v="$(sed -n 's/^HTTPS_PROXY="\(.*\)"$/\1/p' "$f")"
    v="${v:-$(sed -n 's/^HTTP_PROXY="\(.*\)"$/\1/p' "$f")}"
    if [ -n "$v" ]; then
      printf 'sysconfig/proxy|%s\n' "${v%%$'\n'*}"
    fi
  fi
  if command -v systemctl >/dev/null 2>&1 && [ "$OS_KIND" != "Darwin" ]; then
    for h in docker podman; do
      v="$(systemctl show "$h.service" -p Environment 2>/dev/null)" || v=""
      v="$(printf '%s\n' "$v" | tr ' ' '\n' | sed -n 's/^\(Environment=\)\{0,1\}[Hh][Tt][Tt][Pp][Ss]\{0,1\}_[Pp][Rr][Oo][Xx][Yy]=//p')" || v=""
      if [ -n "$v" ]; then
        printf '%s.service|%s\n' "$h" "${v%%$'\n'*}"
      fi
    done
  fi
  f="$NET_ETC/docker/daemon.json"
  if [ -r "$f" ]; then
    v="$(grep -o '"https\{0,1\}-proxy" *: *"[^"]*"' "$f")" || v=""
    v="${v%%$'\n'*}"
    if [ -n "$v" ]; then
      v="${v%\"}"
      printf 'docker/daemon.json|%s\n' "${v##*\"}"
    fi
  fi
  for f in "$NET_ETC/containers/containers.conf" "$NET_ETC"/containers/containers.conf.d/*.conf; do
    if [ -r "$f" ]; then
      v="$(grep -o '[Hh][Tt][Tt][Pp][Ss]\{0,1\}_[Pp][Rr][Oo][Xx][Yy]=[^"]*' "$f")" || v=""
      v="${v%%$'\n'*}"
      if [ -n "$v" ]; then
        printf '%s|%s\n' "${f#"$NET_ETC"/}" "${v#*=}"
      fi
    fi
  done
  f="$HOME/.docker/config.json"
  if [ -r "$f" ]; then
    v="$(grep -o '"https\{0,1\}Proxy" *: *"[^"]*"' "$f")" || v=""
    v="${v%%$'\n'*}"
    if [ -n "$v" ]; then
      v="${v%\"}"
      printf '~/.docker/config.json|%s\n' "${v##*\"}"
    fi
  fi
  if [ "$OS_KIND" = "Darwin" ] && command -v scutil >/dev/null 2>&1; then
    v="$(scutil --proxy 2>/dev/null)" || v=""
    h="$(awk '$1 == "HTTPSProxy" { print $3 }' <<< "$v")"
    p="$(awk '$1 == "HTTPSPort" { print $3 }' <<< "$v")"
    if [ -n "$h" ] && [ "$(awk '$1 == "HTTPSEnable" { print $3 }' <<< "$v")" = "1" ]; then
      printf 'macOS (Network settings)|http://%s%s\n' "$h" "${p:+:$p}"
    fi
    h="$(awk '$1 == "ProxyAutoConfigURLString" { print $3 }' <<< "$v")"
    if [ -n "$h" ]; then
      printf 'macOS (PAC file)|%s\n' "$h"
    fi
  fi
}

# net_found_show LINES -> the proxies of net_found on the screen (passwords masked), with the two places
# whose proxy acts on more than the installer
net_found_show() {
  local where addr
  echo "  Proxies set on this server:"
  while IFS='|' read -r where addr; do
    if [ -n "$where" ]; then
      printf '    %s %s\n' "$(ui_pad "$where" 26)" "$(net_mask "$addr")"
    fi
  done <<< "$1"
  if [[ "$1" == *"~/.docker/config.json|"* ]]; then
    warn "~/.docker/config.json hands its proxy to every container Compose starts:"
    echo "  with INTERNET_PROXY set, the services that need none get an empty one."
  fi
  if [[ "$1" == *"docker/daemon.json|"* ]]; then
    warn "The proxies of docker/daemon.json win over every other setting of the"
    echo "  Docker daemon."
  fi
}

# The address of the first proxy net_found names that is a PAC file or a proxy address
net_found_first() {
  local where addr
  while IFS='|' read -r where addr; do
    if [ -n "$addr" ] && [[ "$where" != *"PAC file"* ]]; then
      printf '%s|%s' "$where" "$addr"
      return 0
    fi
  done <<< "$1"
}

# True when every required site that fails is behind a TLS inspection (the certificate question first)
net_only_tls() {
  local i tls="no"
  for ((i = 0; i < ${#NET_KEYS[@]}; i++)); do
    if [ "${NET_LEVELS[i]}" != "req" ]; then
      continue
    fi
    case "${NET_STATUS[i]}" in
      OK|-|"NOT TESTED") ;;
      "TLS INSPECTED") tls="yes" ;;
      *) return 1 ;;
    esac
  done
  [ "$tls" = "yes" ]
}

# The issuer the TLS inspection of the last check named (empty: none)
net_tls_issuer() {
  local i d
  for ((i = 0; i < ${#NET_KEYS[@]}; i++)); do
    if [ "${NET_STATUS[i]}" = "TLS INSPECTED" ]; then
      d="${NET_DETAIL[i]#*\"}"
      printf '%s' "${d%\"*}"
      return 0
    fi
  done
}

# net_ask [wizard] -> after a check: how this server reaches the internet - a proxy (address, PAC file or
# WPAD), directly (the firewall opens the sites) or not at all (offline bundle). 0: a proxy or the
# certificate was saved; 1: stopped later; 2: 0 at the first question; 3: offline; 4: directly
net_ask() {
  local mode="${1:-}" found first where="" addr="" choice rc
  found="$(net_found)"
  if [ -n "$found" ]; then
    net_found_show "$found"
    echo
  fi
  first="$(net_found_first "$found")"
  if [ -n "$first" ]; then
    where="${first%%|*}"
    addr="${first#*|}"
  fi
  # a TLS inspection only: the company certificate first
  if net_only_tls; then
    if net_ask_ca "$(net_tls_issuer)"; then
      return 0
    fi
    echo
  fi
  while true; do
    echo "  How does this server reach the internet?"
    printf '   %s  %s\n' "${C_BLD}1$C_RST" "Through a proxy server - I know its address"
    printf '   %s  %s\n' "${C_BLD}2$C_RST" "Through a proxy configuration file (PAC)"
    printf '   %s  %s\n' "${C_BLD}3$C_RST" "Find the proxy automatically (WPAD)"
    printf '   %s  %s\n' "${C_BLD}4$C_RST" "Directly - the firewall will allow the sites"
    printf '   %s  %s\n' "${C_BLD}5$C_RST" "Not at all - offline installation"
    printf '   %s  %s\n' "${C_BLD}0$C_RST" "$C_DIM$(if [ "$mode" = "wizard" ]; then printf 'stop'; else printf 'back'; fi)$C_RST"
    echo
    if [ -n "$addr" ]; then
      echo "  Enter takes 1 with $(net_mask "$addr")"
      echo "  (found in $where)."
    fi
    if ! ui_ask choice "Select [1]:"; then
      echo
      return 2
    fi
    case "${choice:-1}" in
      0) return 2 ;;
      1)
        rc=0
        net_ask_proxy "$addr" || rc=$?
        if [ "$rc" -eq 0 ]; then
          return 0
        fi
        ;;
      2)
        if net_ask_pac ""; then
          return 0
        fi
        ;;
      3)
        if net_ask_wpad; then
          return 0
        fi
        ;;
      4)
        echo
        echo "  For the network team - the sites to allow from this server:"
        echo
        net_hosts_text | sed 's/^/  /'
        echo
        info "Directly: the downloads work once the firewall allows these sites."
        rm -f -- "$NET_OFFLINE_FILE"
        # a saved proxy would still be used: it goes after a yes
        if [ -n "$INTERNET_PROXY" ]; then
          echo
          net_remove || true
        fi
        return 4
        ;;
      5)
        echo
        info "Offline installation: on a computer with internet, option 8 (Download only)"
        echo "  builds an offline bundle with all images; copy it here and run its"
        echo "  import-images.sh, then the installer of the bundle."
        echo "  The menu no longer checks the internet at its start (option 26 still does)."
        if mkdir -p -- "$JOBS_DIR" 2>/dev/null; then
          : > "$NET_OFFLINE_FILE" 2>/dev/null || true
        fi
        return 3
        ;;
      *) warn "Invalid choice: $choice" ;;
    esac
    echo
  done
}

# net_proxy_notes SCHEME HOST -> what a SOCKS proxy or a relay on this server means
net_proxy_notes() {
  case "$1" in
    socks5|socks5h)
      warn "A SOCKS proxy: Let's Encrypt in Nginx Proxy Manager and wget cannot use it;"
      echo "  an HTTP proxy is better."
      if [ "$1" = "socks5" ]; then
        echo "  socks5:// resolves the names on this server; socks5h:// lets the proxy do it."
      fi
      ;;
  esac
  case "$2" in
    127.*|localhost|"[::1]")
      info "A relay on this server: the containers reach it as host.docker.internal or"
      echo "  host.containers.internal, so it must listen there too (cntlm Listen, px"
      echo "  --gateway with --allow). Docker: the bridge address (172.17.0.1). Podman:"
      echo "  host.containers.internal is the server's own LAN address - a relay there"
      echo "  that logs in as a domain user is an open proxy for the whole network unless"
      echo "  a firewall lets only the containers in (e.g. 10.88.0.0/16 for Podman)."
      ;;
  esac
}

# net_ntlm_text SCHEMES -> why a proxy that takes only Windows domain logins (or Digest) cannot be used by the
# engine and the package managers, and the two ways out
net_ntlm_text() {
  echo
  if [[ " $1 " == *" Digest "* ]] && [[ " $1 " != *" NTLM "* ]] && [[ " $1 " != *" Negotiate "* ]]; then
    warn "This proxy accepts only Digest logins. Docker, Podman and apt log in"
    echo "  only with Basic, so image pulls and packages cannot pass this proxy."
    echo "  Two ways out:"
  else
    warn "This proxy accepts only Windows domain logins (NTLM or Kerberos). Docker,"
    echo "  Podman and apt can log in only with Basic, so image pulls and packages"
    echo "  cannot pass this proxy. Two ways out:"
  fi
  echo "    a) Ask the network team to let this server through without a login (by its"
  echo "       address: $(host_ip)), or to open the sites ('network-hosts' prints them)."
  echo "    b) Run a local relay that logs in for this server - cntlm (package \"cntlm\")"
  echo "       or px (pip install px-proxy) - and enter the relay's address here as a"
  echo "       normal proxy, e.g. 127.0.0.1:3128."
  echo
}

# net_try URL LOGIN -> one request through the proxy URL: 0 it passes requests on; 1 it cannot be reached
# (said why); 2 it asks for a login (NET_SCHEMES: the methods it offers)
net_try() {
  local tmp host="${1#*://}"
  NET_VIA="$(net_with_login "$1" "$2")"
  NET_VIA_NO=""
  NET_SCHEMES=""
  if ! command -v curl >/dev/null 2>&1; then
    return 0
  fi
  NET_TOOL="curl"
  tmp="$(mktemp -d)" || return 1
  net_get "$tmp/p" "https://registry-1.docker.io/v2/" "401" ""
  NET_SCHEMES="$(net_auth_schemes "$tmp/p.hdr")"
  rm -rf -- "$tmp"
  case "${NET_R%%|*}" in
    "PROXY DNS") err "The name of the proxy does not resolve: ${host%:*}"; return 1 ;;
    REFUSED) err "Nothing listens at $host (wrong port?)."; return 1 ;;
    BLOCKED) err "The proxy does not answer ($host)."; return 1 ;;
    "PROXY LOGIN") return 2 ;;
  esac
  return 0
}

# net_ask_login URL -> NET_LOGIN: user name and password (hidden) for a proxy that takes Basic, tried at
# once; 3 tries. 1: stopped, or wrong three times
net_ask_login() {
  local url="$1" user pass try rc
  echo "  The proxy asks for a login. It is kept in $(basename -- "$PROXY_LOGIN_FILE") next to the"
  echo "  installer (mode 600), never in the script."
  for try in 1 2 3; do
    ui_ask user "User name for the proxy (DOMAIN\\user is fine):" || return 1
    if [ "$user" = "0" ]; then
      return 1
    fi
    if [ -z "$user" ]; then
      warn "Give the user name (0 stops)."
      continue
    fi
    if ! read -r -s -p "  $C_CYN$UI_ARROW$C_RST Password (hidden): " pass; then
      echo
      return 1
    fi
    echo
    NET_LOGIN="$(net_encode "$user"):$(net_encode "$pass")"
    pass=""
    rc=0
    net_try "$url" "$NET_LOGIN" || rc=$?
    case "$rc" in
      0)
        ok "The proxy takes this login."
        return 0
        ;;
      2) err "Wrong user name or password - the proxy asks again." ;;
      *) return 1 ;;
    esac
  done
  NET_LOGIN=""
  err "Stopped after 3 failed logins."
  return 1
}

# The domains of this server (its full name and the search line of resolv.conf), comma-separated: the
# default of the internal names
net_local_domains() {
  local d out=""
  for d in $(net_server_names | sed -n 's/^[^.]*\.//p') $(awk '$1 == "search" || $1 == "domain" { for (i = 2; i <= NF; i++) print $i }' "$NET_ETC/resolv.conf" 2>/dev/null); do
    d="${d%.}"
    d="${d,,}"
    if [[ "$d" == *.* ]] && [[ ",$out," != *",$d,"* ]]; then
      out="$out,$d"
    fi
  done
  printf '%s' "${out#,}"
}

# net_ask_no_proxy [EXTRA] -> NET_NEW_NO: the internal names reached without the proxy (Enter takes
# INTERNET_NO_PROXY, else the domains of this server, plus EXTRA). 1: 0 or the end of input
net_ask_no_proxy() {
  local extra="${1:-}" def input problem me item
  def="$INTERNET_NO_PROXY"
  if [ -z "$def" ]; then
    def="$(net_local_domains)"
  fi
  for item in ${extra//,/ }; do
    if [[ ",$def," != *",$item,"* ]]; then
      def="${def:+$def,}$item"
    fi
  done
  me="$(net_server_names | tr '\n' ' ')$(host_ip)"
  echo
  printf '%s\n' "These are always reached directly: localhost, the services of the Catalog, this server (${me// /, })." | fold -s -w 76 | sed 's/ *$//; s/^/  /'
  echo "  More internal domains or hosts (comma-separated), e.g. corp.example.com;"
  echo "  - for none."
  while true; do
    ui_ask input "Internal names [${def:-none}]:" || return 1
    case "$input" in
      0) return 1 ;;
      "") input="$def" ;;
      -) input="" ;;
    esac
    input="${input//[[:space:]]/}"
    if [ -n "$input" ] && ! problem="$(settings_check INTERNET_NO_PROXY "$input" "")"; then
      err "$problem"
      continue
    fi
    NET_NEW_NO="$input"
    return 0
  done
}

# net_save URL LOGIN PAC NO-PROXY -> the proxy in the settings, its login in .proxy_login (or none), and in
# use from now on
net_save() {
  local name value
  for name in INTERNET_PROXY INTERNET_PROXY_PAC INTERNET_NO_PROXY; do
    case "$name" in
      INTERNET_PROXY) value="$1" ;;
      INTERNET_PROXY_PAC) value="$3" ;;
      *) value="$4" ;;
    esac
    if [ "${!name}" != "$value" ]; then
      set_setting "$name" "$value" || return 1
      printf -v "$name" '%s' "$value"
    fi
  done
  if [ -n "$2" ]; then
    proxy_login_save "$2" || return 1
  else
    rm -f -- "$PROXY_LOGIN_FILE"
  fi
  if [ -n "$1" ]; then
    rm -f -- "$NET_OFFLINE_FILE"
  fi
  proxy_load
}

# net_ask_proxy [DEFAULT] [PAC-SOURCE] [NO-PROXY-EXTRA] -> the questions for a proxy: its address (taken from
# a PAC file when PAC-SOURCE is given), its port, its login when it asks for one (a login typed into the
# address goes to .proxy_login), the check of every site through it (and the company certificate when it
# inspects HTTPS), the internal names; saved after a yes. 0: saved; 1: back
net_ask_proxy_run() {
  local def="${1:-}" pac="${2:-}" extra="${3:-}" input url login port rc ans user
  while true; do
    if [ -n "$pac" ] && [ -n "$def" ]; then
      input="$def"
    else
      pac=""
      ui_ask input "Address of the proxy, e.g. proxy.example.com:8080${def:+ [$(net_mask "$def")]}:" || return 1
      input="${input:-$def}"
      if [ "$input" = "0" ]; then
        return 1
      fi
      if [ -z "$input" ]; then
        continue
      fi
    fi
    if ! net_parse "$input"; then
      err "Give host:port, e.g. proxy.example.com:8080 or http://192.0.2.10:3128"
      echo "  (http, https, socks5 or socks5h)."
      def=""
      pac=""
      continue
    fi
    if [ -z "$NP_PORT" ]; then
      while true; do
        ui_ask port "Port of the proxy (often 8080, 3128 or 80):" || return 1
        if [ "$port" = "0" ]; then
          return 1
        fi
        if [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ]; then
          break
        fi
        err "A port is a number from 1 to 65535."
      done
      NP_PORT="$port"
    fi
    url="$NP_SCHEME://$NP_HOST:$NP_PORT"
    login=""
    if [ -n "$NP_LOGIN" ]; then
      login="$(net_encode "$(net_decode "${NP_LOGIN%%:*}")")"
      if [[ "$NP_LOGIN" == *:* ]]; then
        login="$login:$(net_encode "$(net_decode "${NP_LOGIN#*:}")")"
      fi
      info "The login goes into $(basename -- "$PROXY_LOGIN_FILE") (mode 600), not into the address."
    elif [ "$url" = "$INTERNET_PROXY" ]; then
      login="$(proxy_login)"
    fi
    net_proxy_notes "$NP_SCHEME" "$NP_HOST"
    rc=0
    net_try "$url" "$login" || rc=$?
    if [ "$rc" -eq 1 ]; then
      def=""
      pac=""
      continue
    fi
    if [ "$rc" -eq 2 ]; then
      if [[ " $NET_SCHEMES " == *" Basic "* ]] || [ -z "$NET_SCHEMES" ]; then
        if [ -n "$login" ]; then
          err "The proxy does not take the login given - type it again."
        fi
        net_ask_login "$url" || return 1
        login="$NET_LOGIN"
      else
        net_ntlm_text "$NET_SCHEMES"
        def=""
        pac=""
        continue
      fi
    fi
    # every site through it (the internal names of the settings and of the PAC file directly)
    NET_VIA="$(net_with_login "$url" "$login")"
    NET_VIA_NO="$(INTERNET_NO_PROXY="$INTERNET_NO_PROXY${extra:+,$extra}"; INTERNET_NO_PROXY="${INTERNET_NO_PROXY#,}"; net_no_list)"
    user=""
    if [ -n "$login" ]; then
      user="$(net_decode "${login%%:*}")"
    fi
    NET_VIA_TEXT="through $url${user:+, login $user}"
    echo
    net_check show || true
    if [ -n "$(net_tls_issuer)" ]; then
      net_ask_ca "$(net_tls_issuer)" || true
    fi
    if [ "$NET_REQ_BAD" -gt 0 ] && ! net_only_tls; then
      echo
      ans=0
      wiz_yes_no "Use this proxy anyway? (n: another address)" n || ans=$?
      case "$ans" in
        0) ;;
        1) def=""; pac=""; echo; continue ;;
        *) return 1 ;;
      esac
    fi
    net_ask_no_proxy "$extra" || return 1
    echo
    echo "  Internet proxy $url"
    if [ -n "$user" ]; then
      echo "    login         $user (password saved, mode 600)"
    fi
    if [ -n "$pac" ]; then
      echo "    taken from    $pac"
    fi
    echo "    this run      the downloads of the installer and the package installs (only"
    echo "                  while the installer runs; nothing changes in apt or dnf)"
    net_summary_apply
    echo "    saved         INTERNET_PROXY and INTERNET_NO_PROXY in the settings$(if [ -n "$user" ]; then printf ','; fi)"
    if [ -n "$user" ]; then
      echo "                  the login in $(basename -- "$PROXY_LOGIN_FILE") (mode 600)"
    fi
    ans=0
    wiz_yes_no "Save?" y || ans=$?
    if [ "$ans" -ne 0 ]; then
      info "Nothing was saved."
      return 1
    fi
    net_save "$url" "$login" "$pac" "$NET_NEW_NO" || return 1
    net_cache_write
    ok "Saved: the installer uses this proxy from now on."
    return 0
  done
}

# net_ask_proxy [DEFAULT] [PAC-SOURCE] [NO-PROXY-EXTRA] -> the questions for a proxy (net_ask_proxy_run), then
# the settings applied to the engine and the Catalog - once, a company certificate given on the way too.
# 0: saved; 1: back
net_ask_proxy() {
  local rc=0
  NET_DEFER="yes"
  net_ask_proxy_run "$@" || rc=$?
  NET_DEFER=""
  if [ "$rc" -eq 0 ] || [ -n "$NET_APPLY_PENDING" ]; then
    net_apply
  fi
  return "$rc"
}

# net_pac_fetch SOURCE -> the content of a PAC file: a URL is fetched directly (PAC servers are internal),
# else through a proxy found on this server; a path is read. 1 when it is none (no FindProxyForURL).
net_pac_fetch() {
  local src="$1" c="" first
  case "$src" in
    http://*|https://*)
      c="$(curl -fsS --noproxy '*' --connect-timeout 5 --max-time 10 "$src" 2>/dev/null)" || c=""
      if [ -z "$c" ]; then
        first="$(net_found_first "$(net_found)")"
        if [ -n "$first" ]; then
          c="$(printf 'proxy = "%s"\n' "${first#*|}" | curl -fsS -K - --connect-timeout 5 --max-time 10 "$src" 2>/dev/null)" || c=""
        fi
      fi
      ;;
    *)
      if [ -f "$src" ] && [ -r "$src" ]; then
        c="$(cat -- "$src")"
      fi
      ;;
  esac
  if [[ "$c" != *FindProxyForURL* ]]; then
    return 1
  fi
  printf '%s\n' "$c"
}

# net_pac_candidates PAC-TEXT -> the proxies a PAC file names, in their order, as addresses (PROXY: http://,
# HTTPS: https://, SOCKS: socks5h://), DIRECT as DIRECT
net_pac_candidates() {
  local kind hp
  while read -r kind hp; do
    case "$kind" in
      PROXY) printf 'http://%s\n' "$hp" ;;
      HTTPS) printf 'https://%s\n' "$hp" ;;
      SOCKS|SOCKS5) printf 'socks5h://%s\n' "$hp" ;;
      DIRECT) printf 'DIRECT\n' ;;
    esac
  done <<< "$(printf '%s\n' "$1" | grep -oE '(PROXY|HTTPS|SOCKS5?) ([A-Za-z0-9._-]+|\[[0-9A-Fa-f:.]+\]):[0-9]+|DIRECT')"
}

# net_pac_eval SOURCE PAC-TEXT -> the proxies of the PAC file for the required sites, in their order:
# as pactester or libproxy's proxy tool evaluates it when one is installed (the installer installs neither),
# else as the file names them
net_pac_eval() {
  local src="$1" text="$2" f host p o
  {
    if command -v pactester >/dev/null 2>&1; then
      f="$(mktemp)"
      printf '%s\n' "$text" > "$f"
      for host in $(net_rows | awk -F'|' '$4 == "req" { print $2 }'); do
        pactester -p "$f" -u "https://$host/" 2>/dev/null | awk -F';' 'NR == 1 { sub(/^ */, "", $1); print $1 }' || true
      done | sed 's/^PROXY /http:\/\//; s/^HTTPS /https:\/\//; s/^SOCKS5* /socks5h:\/\//'
      rm -f -- "$f"
    else
      p="$(command -v proxy 2>/dev/null)" || p=""
      o=""
      if [ -n "$p" ] && [[ "$src" == http* ]]; then
        o="$(dpkg -S "$p" 2>/dev/null; rpm -qf "$p" 2>/dev/null)" || true
      fi
      if [[ "$o" == *libproxy* ]]; then
        for host in $(net_rows | awk -F'|' '$4 == "req" { print $2 }'); do
          o="$(printf 'https://%s/\n' "$host" | http_proxy="pac+$src" "$p" "https://$host/" 2>/dev/null)" || o=""
          o="${o%% *}"
          case "$o" in
            direct://*|"") printf 'DIRECT\n' ;;
            *) printf '%s\n' "${o%/}" ;;
          esac
        done
      else
        net_pac_candidates "$text"
      fi
    fi
    printf 'DIRECT\n'
  } | awk 'NF && !seen[$0]++'
}

# net_ask_pac [SOURCE] -> a proxy taken from a PAC file once (curl, Docker, Podman, dnf and wget cannot read
# PAC files): the candidates it names and DIRECT are tried on the required sites; the first candidate that
# reaches them all (with DIRECT: the sites only DIRECT reaches go to INTERNET_NO_PROXY) goes on into
# net_ask_proxy. 1: back, or no single proxy reaches them all
net_ask_pac() {
  local src="${1:-}" text cands c chosen="" extra="" names="" direct=" " dn=0 i req=0 best="" bestn=-1 cnt own k
  if [ -z "$src" ]; then
    ui_ask src "Address or file of the PAC file, e.g. http://pac.example.com/proxy.pac${INTERNET_PROXY_PAC:+ [$INTERNET_PROXY_PAC]}:" || return 1
    src="${src:-$INTERNET_PROXY_PAC}"
    if [ -z "$src" ] || [ "$src" = "0" ]; then
      return 1
    fi
  fi
  if ! text="$(net_pac_fetch "$src")"; then
    err "No PAC file at $src (it must contain FindProxyForURL)."
    return 1
  fi
  cands="$(net_pac_eval "$src" "$text")"
  while IFS= read -r c; do
    if [ -n "$c" ]; then
      names="$names, ${c#*://}"
    fi
  done <<< "$cands"
  echo "  The PAC file names: ${names#, }."
  info "Trying them on the required sites..."
  NET_VIA=""
  NET_VIA_NO=""
  net_check probe || true
  for ((i = 0; i < ${#NET_KEYS[@]}; i++)); do
    req=$((req + 1))
    if [ "${NET_STATUS[i]}" = "OK" ]; then
      direct="$direct${NET_KEYS[i]} "
      dn=$((dn + 1))
    fi
  done
  if [ "$req" -gt 0 ] && [ "$dn" -eq "$req" ]; then
    ok "All $req required sites answer directly - no proxy needed."
    return 1
  fi
  while IFS= read -r c; do
    if [ -z "$c" ] || [ "$c" = "DIRECT" ]; then
      continue
    fi
    NET_VIA="$c"
    net_check probe || true
    extra=""
    cnt=0
    own=0
    for ((i = 0; i < ${#NET_KEYS[@]}; i++)); do
      k="${NET_KEYS[i]}"
      case "${NET_STATUS[i]}" in
        OK|"PROXY LOGIN") cnt=$((cnt + 1)); own=$((own + 1)) ;;
        *)
          if [[ "$direct" == *" $k "* ]]; then
            extra="$extra,${NET_HOSTS[i]}"
            cnt=$((cnt + 1))
          fi
          ;;
      esac
    done
    # a proxy that reaches no site itself is none (a dead one, while DIRECT reaches the rest)
    if [ "$own" -eq 0 ]; then
      continue
    fi
    if [ "$cnt" -gt "$bestn" ]; then
      best="$c"
      bestn="$cnt"
    fi
    if [ "$cnt" -eq "$req" ]; then
      chosen="$c"
      break
    fi
  done <<< "$cands"
  NET_VIA=""
  if [ -z "$chosen" ]; then
    err "No single proxy of the PAC file reaches all $req required sites."
    if [ -n "$best" ]; then
      echo "  The best one, ${best#*://}, reaches $bestn."
    fi
    echo "  Ask the network team for one proxy name for this server (a load-balanced one"
    echo "  if there is one), then choice 1."
    return 1
  fi
  ok "${chosen#*://} reaches all $req required sites - it will be used."
  if [ -n "$extra" ]; then
    echo "  Only reached directly, so they go to the internal names: ${extra#,}"
  fi
  echo "  The PAC file is read only now: its failover between proxies is lost."
  net_ask_proxy "$chosen" "$src" "${extra#,}"
}

# The PAC addresses of WPAD for the domains of this server (search and domain of resolv.conf, the domain of
# its name): http://wpad.DOMAIN/wpad.dat, walking up the domain but never below two labels, and never to a
# public suffix such as co.uk or com.au (whoever registers wpad.co.uk would answer for every company there)
net_wpad_urls() {
  local d seen=" " re='^(co|com|net|org|ac|gov|edu|ne|or|go|gv|nic|ltd|plc|sch|mil)\.[a-z][a-z]$'
  for d in $(awk '$1 == "search" || $1 == "domain" { for (i = 2; i <= NF; i++) print $i }' "$NET_ETC/resolv.conf" 2>/dev/null) $(hostname -d 2>/dev/null); do
    d="${d%.}"
    d="${d,,}"
    while [[ "$d" == *.* ]] && ! [[ "$d" =~ $re ]]; do
      if [[ "$seen" != *" $d "* ]]; then
        seen="$seen$d "
        printf 'http://wpad.%s/wpad.dat\n' "$d"
      fi
      d="${d#*.}"
    done
  done
}

# Choice 3: WPAD - only when chosen (a rogue answer could name any proxy): the PAC file it finds is shown and
# used after a yes. 1: none found, or no
net_ask_wpad() {
  local url found="" ans tried="" c
  info "Looking for the PAC file of your network (WPAD)..."
  while IFS= read -r url; do
    if [ -z "$url" ]; then
      continue
    fi
    tried="$tried ${url#http://}"
    c="$(curl -fsS --noproxy '*' --connect-timeout 3 --max-time 5 "$url" 2>/dev/null)" || c=""
    if [[ "$c" == *FindProxyForURL* ]]; then
      found="$url"
      break
    fi
  done <<< "$(net_wpad_urls)"
  if [ -z "$found" ]; then
    warn "No PAC file found${tried:+ (tried:$tried)}."
    return 1
  fi
  echo "  Found: $found"
  echo "  Make sure it is your company's: on a network, anyone can answer for WPAD."
  ans=0
  wiz_yes_no "Use it?" n || ans=$?
  if [ "$ans" -ne 0 ]; then
    return 1
  fi
  net_ask_pac "$found"
}

# net_ca_pem FILE -> the certificates of FILE in PEM (DER is converted with openssl); fails, with the reason,
# when FILE holds a private key or no certificate
net_ca_pem() {
  local f="$1"
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    err "No readable file: $f"
    return 1
  fi
  if grep -q 'PRIVATE KEY' "$f" 2>/dev/null; then
    err "$f holds a private key - only the certificate is needed (never pass a key on)."
    return 1
  fi
  if grep -q -- '-----BEGIN CERTIFICATE-----' "$f" 2>/dev/null; then
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$f"
    return 0
  fi
  if command -v openssl >/dev/null 2>&1 && openssl x509 -inform der -in "$f" -outform pem 2>/dev/null; then
    return 0
  fi
  err "$f is no certificate in PEM or DER$(if ! command -v openssl >/dev/null 2>&1; then printf ' (DER needs openssl)'; fi)."
  return 1
}

# net_ca_show FILE -> each certificate of FILE: its name, validity and SHA-256 fingerprint, with a warning
# for one that is no CA or has expired. 1 when FILE is none.
net_ca_show() {
  local pem dir c n=0 subj end fp
  pem="$(net_ca_pem "$1")" || return 1
  dir="$(mktemp -d)" || return 1
  printf '%s\n' "$pem" | awk -v d="$dir" '/-----BEGIN CERTIFICATE-----/ { n++ } n { print > (d "/" n ".pem") }'
  for c in "$dir"/*.pem; do
    if [ ! -f "$c" ]; then
      continue
    fi
    n=$((n + 1))
    subj=""
    end=""
    if command -v openssl >/dev/null 2>&1; then
      subj="$(openssl x509 -noout -subject -in "$c" 2>/dev/null | sed 's/^subject= *//')" || subj=""
      end="$(openssl x509 -noout -enddate -in "$c" 2>/dev/null | sed 's/^notAfter=//')" || end=""
      fp="$(openssl x509 -noout -fingerprint -sha256 -in "$c" 2>/dev/null | sed 's/^.*=//')" || fp=""
    else
      fp=""
    fi
    if [ -z "$fp" ]; then
      fp="$(sed '/-----/d' "$c" | base64 -d 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1 | tr 'a-f' 'A-F' | sed 's/../&:/g; s/:$//')" || fp=""
    fi
    echo "  Certificate $n: ${subj:-(name unknown - openssl is missing)}"
    if [ -n "$end" ]; then
      echo "    valid until  $end"
    fi
    echo "    SHA-256      ${fp:0:47}"
    if [ "${#fp}" -gt 48 ]; then
      echo "                 ${fp:48}"
    fi
    if command -v openssl >/dev/null 2>&1; then
      if ! openssl x509 -noout -checkend 0 -in "$c" >/dev/null 2>&1; then
        warn "This certificate has expired."
      fi
      if [[ "$(openssl x509 -noout -text -in "$c" 2>/dev/null)" == *CA:FALSE* ]]; then
        warn "This is no CA certificate (CA:FALSE) - the root certificate is needed."
      fi
    fi
  done
  rm -rf -- "$dir"
  if [ "$n" -eq 0 ]; then
    err "No certificate found in $1."
    return 1
  fi
}

# net_ask_ca [ISSUER] -> the company's root certificate for a network that inspects HTTPS: the file is asked
# for, shown with its SHA-256 fingerprint and kept as proxy-ca.pem (INTERNET_PROXY_CA_FILE) after a yes.
# 1: skipped
net_ask_ca() {
  local issuer="${1:-}" f ans pem
  echo
  if [ -n "$issuer" ]; then
    echo "  Your network inspects HTTPS: the certificates come from"
    echo "  \"$issuer\"."
  else
    echo "  A network that inspects HTTPS signs the sites with its own certificate."
  fi
  echo "  The server, the engine and the Catalog must trust your company's root"
  echo "  certificate. Your IT department has it (a PEM or DER file)."
  while true; do
    ui_ask f "File of that certificate${INTERNET_PROXY_CA_FILE:+ [$INTERNET_PROXY_CA_FILE]}, or 0 to skip:" || return 1
    f="${f:-$INTERNET_PROXY_CA_FILE}"
    if [ -z "$f" ] || [ "$f" = "0" ]; then
      return 1
    fi
    if ! net_ca_show "$f"; then
      continue
    fi
    echo "  Compare the fingerprint with your IT department."
    ans=0
    wiz_yes_no "Is this your company's certificate?" n || ans=$?
    case "$ans" in
      0) break ;;
      1) continue ;;
      *) return 1 ;;
    esac
  done
  pem="$(net_ca_pem "$f")" || return 1
  if ! printf '%s\n' "$pem" > "$PROXY_CA_COPY.tmp" || ! mv -f -- "$PROXY_CA_COPY.tmp" "$PROXY_CA_COPY"; then
    rm -f -- "$PROXY_CA_COPY.tmp"
    err "Cannot write $PROXY_CA_COPY."
    return 1
  fi
  chmod 644 "$PROXY_CA_COPY" 2>/dev/null || true
  if [ "$INTERNET_PROXY_CA_FILE" != "$PROXY_CA_COPY" ]; then
    set_setting INTERNET_PROXY_CA_FILE "$PROXY_CA_COPY" || return 1
    INTERNET_PROXY_CA_FILE="$PROXY_CA_COPY"
  fi
  ok "Kept as $PROXY_CA_COPY (INTERNET_PROXY_CA_FILE)."
  if [ "$OS_KIND" = "Darwin" ]; then
    echo "  On this Mac, add it to the System keychain yourself (Docker Desktop reads it):"
    echo "    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $PROXY_CA_COPY"
  else
    net_ca_trust ask || true
  fi
  if [ -n "$NET_DEFER" ]; then
    NET_APPLY_PENDING="yes"
  else
    net_apply
  fi
}

# Removes the proxy (after a yes): the settings, the login; the company certificate only after its own yes
net_remove() {
  local ans ca="no" trust="no"
  ans=0
  wiz_yes_no "Remove the proxy $INTERNET_PROXY and its login?" n || ans=$?
  if [ "$ans" -ne 0 ]; then
    info "Nothing was changed."
    return 0
  fi
  if [ -n "$INTERNET_PROXY_CA_FILE" ]; then
    ans=0
    wiz_yes_no "Also forget the company certificate ($INTERNET_PROXY_CA_FILE)?" n || ans=$?
    if [ "$ans" -eq 0 ]; then
      ca="yes"
    fi
  fi
  if [ "$ca" = "yes" ] && net_ca_trusted; then
    ans=0
    wiz_yes_no "Also take it out of the trust store of this server?" n || ans=$?
    if [ "$ans" -eq 0 ]; then
      trust="yes"
    fi
  fi
  net_save "" "" "" "" || return 1
  ok "The proxy is removed: the installer goes out directly."
  if [ "$ca" = "yes" ] && set_setting INTERNET_PROXY_CA_FILE ""; then
    INTERNET_PROXY_CA_FILE=""
    rm -f -- "$PROXY_CA_COPY" "$PROXY_CA_BUNDLE"
    ok "The company certificate is forgotten."
    if [ "$trust" = "yes" ]; then
      net_ca_trust remove || true
    fi
  fi
  net_apply
}

# Option 26: the internet settings, the check of every site, then what to change
net_menu() {
  local choice u rc
  echo "${C_BLD}Internet access${C_RST}"
  u="$(proxy_login_user)"
  printf '  %-12s %s\n' "Proxy" "${INTERNET_PROXY:-none - directly${NET_SHELL_PROXY:+ (or the proxy of your shell)}}${u:+, login $u (password saved)}"
  if [ -n "$INTERNET_PROXY_PAC" ]; then
    printf '  %-12s %s\n' "PAC file" "$INTERNET_PROXY_PAC"
  fi
  if [ -n "$INTERNET_NO_PROXY" ]; then
    printf '  %-12s %s\n' "Internal" "$INTERNET_NO_PROXY"
  fi
  if [ -n "$INTERNET_PROXY_CA_FILE" ]; then
    printf '  %-12s %s\n' "Certificate" "$INTERNET_PROXY_CA_FILE"
  fi
  echo
  net_via_settings
  rc=0
  net_check show || rc=$?
  case "$rc" in
    0)
      rm -f -- "$NET_OFFLINE_FILE"
      net_shell_offer ask || true
      ;;
    130) return 0 ;;
    *)
      # nothing saved yet: straight to the questions; else the choices below (remove, certificate...)
      if [ -z "$INTERNET_PROXY$INTERNET_PROXY_CA_FILE" ]; then
        echo
        net_ask || true
        return 0
      fi
      ;;
  esac
  while true; do
    echo
    printf '   %s  %s\n' "${C_BLD}1$C_RST" "Set or change the proxy"
    if [ -n "$INTERNET_PROXY" ]; then
      printf '   %s  %s\n' "${C_BLD}2$C_RST" "Remove the proxy"
    fi
    printf '   %s  %s\n' "${C_BLD}3$C_RST" "Company certificate (for a network that inspects HTTPS)"
    printf '   %s  %s\n' "${C_BLD}4$C_RST" "The sites for the network team (firewall)"
    if [ -n "$INTERNET_PROXY_PAC" ]; then
      printf '   %s  %s\n' "${C_BLD}5$C_RST" "Read the PAC file again"
    fi
    printf '   %s  %s\n' "${C_BLD}6$C_RST" "Apply the settings to the engine and the Catalog again"
    printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}back$C_RST"
    echo
    ui_ask choice "Select [0]:" || return 0
    case "${choice:-0}" in
      0) return 0 ;;
      1) echo; net_ask || true; return 0 ;;
      2) if [ -n "$INTERNET_PROXY" ]; then net_remove; return 0; fi ;;
      3) net_ask_ca "$(net_tls_issuer)" || true; return 0 ;;
      4) echo; net_hosts_text; return 0 ;;
      5) if [ -n "$INTERNET_PROXY_PAC" ]; then echo; net_ask_pac "$INTERNET_PROXY_PAC" || true; return 0; fi ;;
      6) echo; net_apply; return 0 ;;
    esac
    warn "Invalid choice: $choice"
  done
}

# The command network-check: the check of every site, no questions; 0 when every required site answers
net_cli_check() {
  local rc=0
  net_via_settings
  net_check show || rc=$?
  if [ "$rc" -eq 0 ]; then
    net_shell_offer note
  fi
  return "$rc"
}

# True when only the shell has a proxy (no INTERNET_PROXY): the installer's own downloads use it, the engine
# and the containers of the Catalog do not read it
net_shell_only() {
  [ -z "$INTERNET_PROXY" ] && [ -n "$NET_SHELL_PROXY" ]
}

# net_shell_offer ask|note -> after a check through the shell's proxy: the engine and the Catalog do not read
# it; ask: saving it is offered (Enter: yes). 2: 0 at the question
net_shell_offer() {
  local ans=0
  if ! net_shell_only; then
    return 0
  fi
  echo
  warn "Only your shell has this proxy ($NET_SHELL_NAME): Docker, Podman and the"
  echo "  containers of the Catalog do not read it - their pulls and downloads would"
  echo "  go out directly. Saved in the settings (option 26), they get it too."
  if [ "$1" != "ask" ]; then
    return 0
  fi
  wiz_yes_no "Save the proxy of your shell for them?" y || ans=$?
  case "$ans" in
    0) echo; net_ask_proxy "$NET_SHELL_PROXY" || true ;;
    1) ;;
    *) return 2 ;;
  esac
}

# The Internet step of the new installation: the check of the sites; when required ones cannot be reached,
# the questions (net_ask). 0: on to the engine; 1: stopped; 2: stopped at its first question
wiz_internet() {
  local rc=0 ans
  if ! net_enabled; then
    echo "  ${C_DIM}The internet check is off (RN1_NET_CHECK=off).$C_RST"
    return 0
  fi
  echo "  The installation downloads the container images, Docker Compose and the"
  echo "  packages of the engine. First the sites it needs:"
  echo
  net_via_settings
  net_check show || rc=$?
  # Ctrl+C: stopped, no questions on a half-finished table
  if [ "$rc" -eq 130 ]; then
    return 2
  fi
  if [ "$rc" -eq 0 ]; then
    # only optional sites fail: the company certificate when HTTPS is inspected, else a proxy after a yes;
    # a proxy only the shell has is saved for the engine and the Catalog after a yes
    if [ -n "$(net_tls_issuer)" ]; then
      net_ask_ca "$(net_tls_issuer)" || true
    elif net_shell_only; then
      net_shell_offer ask || return 2
    elif [ "$NET_OPT_BAD" -gt 0 ]; then
      echo
      ans=0
      wiz_yes_no "Set an internet proxy now?" n || ans=$?
      case "$ans" in
        0) net_ask wizard || true ;;
        1) ;;
        *) return 2 ;;
      esac
    fi
    ui_pause_tty
    return 0
  fi
  echo
  rc=0
  net_ask wizard || rc=$?
  case "$rc" in
    0|4) ui_pause_tty; return 0 ;;
    2) return 2 ;;
    *) return 1 ;;
  esac
}

# Hooks for the tests: __net encode|decode|parse|rows|found|env|run-plan|sudo|pac|pacask|wpad|header|signature|ask|ca|
# engine|engine-write|apply|agent|colima|cleanup|stale|offer|adopt
net_test_hook() {
  local cmd="${1:-}" p
  shift || true
  case "$cmd" in
    encode) net_encode "$1"; echo ;;
    decode) net_decode "$1"; echo ;;
    parse) if net_parse "$1"; then echo "$NP_SCHEME|$NP_HOST|$NP_PORT|$NP_LOGIN"; else echo "invalid"; return 1; fi ;;
    rows) net_rows ;;
    found) net_found ;;
    env)
      # the proxy of this run without the password, and whether its login is the saved one
      p="${https_proxy:-}"
      printf '%s|%s|%s|%s|login=%s\n' "$(net_mask "$p")" "$(net_mask "${HTTP_PROXY:-}")" "${no_proxy:-}" "${RN1_PROXY_SET:-}" \
        "$(if [ -n "$(proxy_login)" ] && [[ "$p" == *"://$(proxy_login)@"* ]]; then echo saved; else echo none; fi)"
      ;;
    run-plan) use_sudo || return 1; run_plan "$@" || return $? ;;
    sudo) use_sudo || return 1; proxy_sudo "$@" || return $? ;;
    pac) net_pac_candidates "$(cat -- "$1")" ;;
    pacask) net_ask_pac "$1" || return $? ;;
    wpad) net_wpad_urls ;;
    header) net_header; echo ;;
    signature) net_signature; echo ;;
    ask)
      net_via_settings
      if net_check show; then
        return 0
      fi
      echo
      net_ask || return $?
      ;;
    ca) net_ask_ca "${1:-}" || return $? ;;
    engine) engine_use "${1:-podman}"; net_engine_check || return $? ;;
    engine-write) use_sudo || return 1; net_engine_write "$1" "$2" || return $?; net_engine_restart "$1" "$2" || return $? ;;
    apply) net_apply ;;
    agent) mac_agent "$1" ;;
    colima) p=0; net_colima_env "$1" || p=$?; echo "rc=$p" ;;
    cleanup) net_proxy_cleanup || return $? ;;
    stale) net_engine_stale ;;
    offer) net_offer_check "$1" ;;
    adopt) net_adopt "$1" "$2" ;;
    *) err "Unknown: __net $cmd"; return 2 ;;
  esac
}

###############################################################################
# Internet access (option 26): the proxy applied - the engine, the company certificate, the Catalog
###############################################################################

# The first line of every file the installer writes for the proxy outside its folder: only files that
# start with it are changed or removed
NET_MARK="# Written by the Raynet One Technology Catalog installer (option 26 changes or removes it)"
# The proxy of the engine with its login, readable only by root. Host-wide (one engine serves every
# installation folder), so it names the folder it came from.
NET_ENGINE_ENV="$NET_ETC/rn1-technology-catalog/engine-proxy.env"
NET_UNITS="$NET_ETC/systemd/system"
# Podman hands its own proxy to every container it creates unless told not to: only catalog-web and Nginx
# Proxy Manager get one, from the compose file
NET_PODMAN_CONF="$NET_ETC/containers/containers.conf.d/50-rn1-proxy.conf"
# The certificates of the containers while INTERNET_PROXY_CA_FILE is set: those of this system and the
# company's, mounted read-only into catalog-web and Nginx Proxy Manager
PROXY_CA_BUNDLE="$WORK_DIR/proxy-ca-bundle.pem"
NET_CA_MOUNT="/etc/rn1/ca-bundle.pem"
# The engines whose proxy files changed (" docker podman"): they read them at their next start
NET_ENGINE_CHANGED=""
# Set while the questions for a proxy run: a company certificate given on the way is applied with the proxy
NET_DEFER=""
NET_APPLY_PENDING=""
# Set while R removes the installer's proxy files (all of them)
NET_CLEANUP=""

# net_dropin KIND -> the installer's drop-in for the systemd unit of KIND (docker, podman)
net_dropin() {
  printf '%s/%s.service.d/50-rn1-proxy.conf' "$NET_UNITS" "$1"
}

# net_ours FILE -> true when the installer wrote FILE (its first line is NET_MARK)
net_ours() {
  [ -f "$1" ] && [ -r "$1" ] && [ "$(head -n 1 -- "$1" 2>/dev/null)" = "$NET_MARK" ]
}

# net_root_read FILE -> FILE, which only root may read (sudo when needed); nothing when it is missing
net_root_read() {
  if [ -e "$1" ]; then
    ${SUDO[@]+"${SUDO[@]}"} cat -- "$1" 2>/dev/null || true
  fi
}

# net_root_file FILE [MODE TEXT] -> FILE with TEXT and MODE, as root (sudo when needed): the text goes
# through stdin, so it shows in no process list; a new folder gets 755. Without MODE and TEXT: removed.
net_root_file() {
  if [ "$#" -lt 3 ]; then
    ${SUDO[@]+"${SUDO[@]}"} rm -f -- "$1"
    return
  fi
  ${SUDO[@]+"${SUDO[@]}"} sh -c 'umask 022 && mkdir -p "${1%/*}" && umask 077 && cat > "$1.rn1-new" && chmod "$2" "$1.rn1-new" && mv -f "$1.rn1-new" "$1"' sh "$1" "$2" <<< "$3"
}

# The address of this server for NO_PROXY (empty when it is not known)
net_host_addr() {
  local a
  a="$(host_ip)"
  case "$a" in
    ""|"<server-ip>"|localhost) ;;
    *) printf '%s' "$a" ;;
  esac
}

# net_no_join LIST NAME... -> LIST (comma-separated) with each NAME that is not in it yet
net_no_join() {
  local out="$1" n
  shift
  for n in "$@"; do
    if [ -n "$n" ] && [[ ",$out," != *",$n,"* ]]; then
      out="${out:+$out,}$n"
    fi
  done
  printf '%s' "$out"
}

# The NO_PROXY of the engine: localhost, this server, the domain of the Catalog, the internal names (as
# name and .name) and the private address ranges (Go reads ranges)
net_no_proxy_engine() {
  local -a more=()
  IFS=',' read -r -a more <<< "$(net_no_list)"
  # shellcheck disable=SC2046
  net_no_join "localhost,127.0.0.1,::1" $(net_server_names) "$(net_host_addr)" "$CATALOG_DOMAIN" \
    ${more[@]+"${more[@]}"} 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
}

# The host of the online catalog (CATALOG_CLOUD_URL, the parent of the synchronization) when it is internal:
# an address, a name without a dot or with a local ending, or one in the domains of this server (.NET reads
# no address ranges in NO_PROXY, so an internal parent must be named); empty for an internet one
net_cloud_internal() {
  local h d
  h="${CATALOG_CLOUD_URL#*://}"
  h="${h%%/*}"
  h="${h##*@}"
  if [[ "$h" == \[* ]]; then
    h="${h%%]*}]"
  else
    h="${h%%:*}"
  fi
  h="${h,,}"
  case "$h" in
    "") return 0 ;;
    \[*|*[!0-9.]*) ;;
    *) printf '%s' "$h"; return 0 ;;
  esac
  if [[ "$h" == \[* ]] || [[ "$h" != *.* ]] || domain_private "$h"; then
    printf '%s' "$h"
    return 0
  fi
  for d in ${INTERNET_NO_PROXY//,/ } $(net_local_domains | tr ',' ' '); do
    d="${d#.}"
    if [ -n "$d" ] && { [ "$h" = "$d" ] || [[ "$h" == *".$d" ]]; }; then
      printf '%s' "$h"
      return 0
    fi
  done
}

# The NO_PROXY of catalog-web and Nginx Proxy Manager: localhost, the services of the stack, this server as
# the engines name it inside the containers, its names and address, the host name of catalog-web, the
# domain of the Catalog, an internal online catalog, the internal names (as name and .name) and the private
# address ranges
net_no_proxy_containers() {
  local -a more=()
  IFS=',' read -r -a more <<< "$(net_no_list)"
  # shellcheck disable=SC2046
  net_no_join "localhost,127.0.0.1,::1" mongo minio rabbitmq opensearch opensearch-dashboards catalog-web \
    nginx-proxy-manager worker-recognition-1 worker-recognition-2 worker-other worker-search \
    host.docker.internal host.containers.internal $(net_server_names) "$CATALOG_HOSTNAME" "$CATALOG_DOMAIN" \
    "$(net_host_addr)" "$(net_cloud_internal)" ${more[@]+"${more[@]}"} 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
}

# True when INTERNET_PROXY is a relay on this server (127.0.0.1, localhost, [::1]); NP_* of it
net_proxy_local() {
  net_parse "$INTERNET_PROXY" || return 1
  case "$NP_HOST" in
    127.*|localhost|"[::1]") return 0 ;;
  esac
  return 1
}

# INTERNET_PROXY as the containers reach it: a relay on this server by the name the engine gives this server
# inside them (Podman: host.containers.internal, Docker: host.docker.internal)
net_container_proxy() {
  if ! net_proxy_local; then
    printf '%s' "$INTERNET_PROXY"
  elif [ "$ENGINE" = "podman" ]; then
    printf '%s://host.containers.internal:%s' "$NP_SCHEME" "$NP_PORT"
  else
    printf '%s://host.docker.internal:%s' "$NP_SCHEME" "$NP_PORT"
  fi
}

# The proxy part of .env (nothing without INTERNET_PROXY): the proxy of catalog-web and Nginx Proxy Manager
# with its login, for HTTPS only - their internal calls are plain http:// or no HTTP at all, so none of them
# can go to the proxy; for HTTP only when the online catalog is an http:// address
net_env_block() {
  local p http=""
  if [ -z "$INTERNET_PROXY" ]; then
    return 0
  fi
  p="$(net_with_login "$(net_container_proxy)")"
  case "$CATALOG_CLOUD_URL" in
    http://*) http="$p" ;;
  esac
  printf '\n# Internet proxy (option 26): only catalog-web and Nginx Proxy Manager go out through it\n'
  printf "RN1_HTTPS_PROXY='%s'\nRN1_HTTP_PROXY='%s'\nRN1_NO_PROXY='%s'\n" "$p" "$http" "$(net_no_proxy_containers)"
}

# net_compose_edit FILE -> catalog-web and Nginx Proxy Manager of the compose FILE with the proxy of .env
# (every name in both cases: .NET reads the lower-case one first, and an empty HTTP_PROXY and ALL_PROXY
# also beat a proxy of ~/.docker/config.json) and the company certificate read-only; Nginx Proxy Manager
# fetches no address ranges of CDNs at its start (not needed here, and it would wait for them); a relay on
# this server is host.docker.internal for Docker. Every other service gets the same names empty: an engine
# that hands its own proxy to each container (the Podman machine of a Mac, ~/.docker/config.json) would
# send their calls to each other to the proxy. Without INTERNET_PROXY and INTERNET_PROXY_CA_FILE the file
# stays as it is.
net_compose_edit() {
  local f="$1" env="" vol="" hosts="" npm="" none=""
  if [ -z "$INTERNET_PROXY$INTERNET_PROXY_CA_FILE" ] || [ ! -f "$f" ]; then
    return 0
  fi
  if [ -n "$INTERNET_PROXY" ]; then
    # shellcheck disable=SC2016
    env='      HTTPS_PROXY: "${RN1_HTTPS_PROXY}"
      https_proxy: "${RN1_HTTPS_PROXY}"
      HTTP_PROXY: "${RN1_HTTP_PROXY:-}"
      http_proxy: "${RN1_HTTP_PROXY:-}"
      ALL_PROXY: ""
      all_proxy: ""
      NO_PROXY: "${RN1_NO_PROXY}"
      no_proxy: "${RN1_NO_PROXY}"'
    npm='      IP_RANGES_FETCH_ENABLED: "false"'
    none='      HTTPS_PROXY: ""
      https_proxy: ""
      HTTP_PROXY: ""
      http_proxy: ""
      ALL_PROXY: ""
      all_proxy: ""
      NO_PROXY: ""
      no_proxy: ""'
    if net_proxy_local && [ "$ENGINE" != "podman" ]; then
      hosts='    extra_hosts:
      - "host.docker.internal:host-gateway"'
    fi
  fi
  if [ -n "$INTERNET_PROXY_CA_FILE" ]; then
    env="$env${env:+$'\n'}      SSL_CERT_FILE: \"$NET_CA_MOUNT\"
      REQUESTS_CA_BUNDLE: \"$NET_CA_MOUNT\"
      NODE_EXTRA_CA_CERTS: \"$NET_CA_MOUNT\""
    vol="      - ./$(basename -- "$PROXY_CA_BUNDLE"):$NET_CA_MOUNT:ro,z"
  fi
  NET_E="$env" NET_N="$npm" NET_V="$vol" NET_H="$hosts" NET_0="$none" awk '
    /^[^ #]/ { top = $1; svc = "" }
    top == "services:" && /^  [A-Za-z0-9_.-]+:[ \t]*$/ { svc = $1; sub(/:$/, "", svc) }
    svc != "" && svc != "catalog-web" && svc != "nginx-proxy-manager" && $0 == "    environment:" && ENVIRON["NET_0"] != "" {
      print
      print ENVIRON["NET_0"]
      next
    }
    svc != "catalog-web" && svc != "nginx-proxy-manager" { print; next }
    $0 == "    environment:" {
      if (ENVIRON["NET_H"] != "") print ENVIRON["NET_H"]
      print
      print ENVIRON["NET_E"]
      if (svc == "nginx-proxy-manager" && ENVIRON["NET_N"] != "") print ENVIRON["NET_N"]
      next
    }
    $0 == "    volumes:" && ENVIRON["NET_V"] != "" { print; print ENVIRON["NET_V"]; next }
    { print }' "$f" > "$f.rn1-tmp" && cat -- "$f.rn1-tmp" > "$f"
  rm -f -- "$f.rn1-tmp"
}

# The certificates of this system, as OpenSSL reads them (empty when none is found)
net_sys_bundle() {
  local f
  for f in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /etc/ssl/ca-bundle.pem /etc/ssl/cert.pem; do
    if [ -r "$f" ] && [ -s "$f" ]; then
      printf '%s' "$f"
      return 0
    fi
  done
}

# proxy-ca-bundle.pem for the containers while INTERNET_PROXY_CA_FILE is set: the certificates of this
# system and the company's (written in place: a container sees the new one after its restart). 0: changed
net_ca_bundle_write() {
  local sys new
  if [ -z "$INTERNET_PROXY_CA_FILE" ]; then
    return 1
  fi
  sys="$(net_sys_bundle)"
  if ! new="$(net_ca_pem "$INTERNET_PROXY_CA_FILE")"; then
    warn "The certificates for the containers were not written:"
    echo "  $PROXY_CA_BUNDLE"
    return 1
  fi
  if [ -n "$sys" ]; then
    new="$(cat -- "$sys")"$'\n'"$new"
  fi
  if [ -f "$PROXY_CA_BUNDLE" ] && [ "$(cat -- "$PROXY_CA_BUNDLE")" = "$new" ]; then
    return 1
  fi
  if ! printf '%s\n' "$new" > "$PROXY_CA_BUNDLE"; then
    warn "Cannot write $PROXY_CA_BUNDLE."
    return 1
  fi
  chmod 644 "$PROXY_CA_BUNDLE" 2>/dev/null || true
}

# The certificates for the containers before a start, when they are missing (the engine would create a
# folder in their place)
net_ca_bundle_ensure() {
  if [ -n "$INTERNET_PROXY_CA_FILE" ] && [ ! -f "$PROXY_CA_BUNDLE" ]; then
    net_ca_bundle_write || true
  fi
}

# True when catalog-web or Nginx Proxy Manager of this folder runs
net_stack_running() {
  local s
  if ! engine_cli || ! detect_compose >/dev/null 2>&1; then
    return 1
  fi
  s="$(compose ps --services --filter status=running 2>/dev/null)" || return 1
  grep -qx -e catalog-web -e nginx-proxy-manager <<< "$s"
}

# net_catalog_apply -> catalog-web and Nginx Proxy Manager with the internet settings: .env and the compose
# file generated again when they differ from the settings (passwords and host name kept, as option 2 does),
# the certificates for the containers; created again after a yes when the stack runs
net_catalog_apply() {
  local files="no" ca="no" var
  local -a svc=(catalog-web)
  if [ ! -f "$ENV_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    return 0
  fi
  if net_ca_bundle_write; then
    ca="yes"
  fi
  if settings_stale; then
    # other settings not applied yet (versions, ports...) are no part of this: option 2 and the upgrade
    # apply them, with their backup and checks
    if ! net_only_net_stale; then
      warn "Other settings differ from $ENV_FILE and $COMPOSE_FILE as well: they"
      echo "  are applied together - option 2 (or U for a new version) writes the files,"
      echo "  option 6 starts the Catalog with them."
      return 0
    fi
    backup_file "$ENV_FILE"
    backup_file "$COMPOSE_FILE"
    if ! (
      for var in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS NPM_ADMIN_PASSWORD; do
        printf -v "$var" '%s' "$(env_value "$var")"
      done
      CATALOG_HOSTNAME="$(catalog_hostname "$ENV_FILE")"
      # the cache of MongoDB of .env (or, without one, for the memory of the engine, as option 2 writes it)
      MONGO_WT_CACHE_GB="$(mongo_cache_written)"
      if [ -z "$MONGO_WT_CACHE_GB" ]; then
        MONGO_WT_CACHE_GB="$(mongo_cache_gb)"
      fi
      write_env_file
      write_compose_file
    ); then
      err "$ENV_FILE and $COMPOSE_FILE could not be written - option 2 writes them."
      return 1
    fi
    chmod 600 "$ENV_FILE"
    files="yes"
    ok "$ENV_FILE and $COMPOSE_FILE written again from the settings, passwords kept."
  fi
  if [ "$files$ca" = "nono" ]; then
    return 0
  fi
  if ! net_stack_running; then
    info "catalog-web and Nginx Proxy Manager use them from their next start"
    echo "  (option 6)."
    return 0
  fi
  if [ "$INSTALL_NGINX_PROXY_MANAGER" = "true" ]; then
    svc+=(nginx-proxy-manager)
  fi
  if [ "$files" = "yes" ]; then
    info "The containers whose proxy settings changed must be created again (about"
    echo "  a minute without the web interface; the data stays)."
  else
    info "${svc[*]} must be created again to use them (about a minute"
    echo "  without the web interface; the data stays)."
  fi
  if ! confirm "Do it now?" y; then
    info "They use them from their next start (option 6)."
    return 0
  fi
  if [ "$files" = "yes" ]; then
    # only the proxy part differs (net_only_net_stale): compose creates again what changed, nothing else
    compose up -d
  else
    compose up -d --no-deps --force-recreate "${svc[@]}"
  fi
}

# net_strip FILE -> .env or the compose file without what the internet settings add (net_env_block,
# net_compose_edit) and without empty lines
net_strip() {
  awk '
    /^RN1_(HTTPS|HTTP|NO)_PROXY=/ || /^# Internet proxy \(option 26\)/ { next }
    /^      (HTTPS_PROXY|https_proxy|HTTP_PROXY|http_proxy|ALL_PROXY|all_proxy|NO_PROXY|no_proxy|IP_RANGES_FETCH_ENABLED|SSL_CERT_FILE|REQUESTS_CA_BUNDLE|NODE_EXTRA_CA_CERTS): / { next }
    /^      - \.\/proxy-ca-bundle\.pem:/ { next }
    /^    extra_hosts:$/ { held = 1; next }
    held && $0 == "      - \"host.docker.internal:host-gateway\"" { held = 0; next }
    held { print "    extra_hosts:"; held = 0 }
    /^[ \t]*$/ { next }
    { print }' "$1" 2>/dev/null
}

# net_cache_line_match FILE -> FILE (written from the settings) without the cache of MongoDB when .env has
# none yet: a start writes it (mongo_cache_refresh), as settings_stale counts it
net_cache_line_match() {
  if ! grep -q '^MONGO_WT_CACHE_GB=' "$ENV_FILE"; then
    sed -i '/^MONGO_WT_CACHE_GB=/d' "$1"
  fi
}

# True when .env and the compose file differ from the settings only in what the internet settings add
net_only_net_stale() {
  local tmp_env tmp_compose rc=1
  tmp_env="$(mktemp)" || return 1
  tmp_compose="$(mktemp)" || { rm -f -- "$tmp_env"; return 1; }
  if (
    for var in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS NPM_ADMIN_PASSWORD; do
      printf -v "$var" '%s' "$(env_value "$var")"
    done
    CATALOG_HOSTNAME="$(catalog_hostname "$ENV_FILE")"
    MONGO_WT_CACHE_GB="$(mongo_cache_written)"
    ENV_FILE="$tmp_env"
    COMPOSE_FILE="$tmp_compose"
    write_env_file
    write_compose_file
  ) >/dev/null 2>&1 && net_cache_line_match "$tmp_env" && [ "$(net_strip "$tmp_env")" = "$(net_strip "$ENV_FILE")" ] \
    && [ "$(net_strip "$tmp_compose")" = "$(net_strip "$COMPOSE_FILE")" ]; then
    rc=0
  fi
  rm -f -- "$tmp_env" "$tmp_compose"
  return "$rc"
}

# net_engine_env_text [FOLDER...] -> the env file of the engine for INTERNET_PROXY (empty without it): the
# proxy with its login and NO_PROXY in both cases, single-quoted (the login is percent-encoded), and the
# folders whose installations use it (this one, then FOLDER...: one line each)
net_engine_env_text() {
  local p no f folders=""
  if [ -z "$INTERNET_PROXY" ]; then
    return 0
  fi
  p="$(net_with_login "$INTERNET_PROXY")"
  no="$(net_no_proxy_engine)"
  for f in "$WORK_DIR" "$@"; do
    folders="$folders# Folder: $f"$'\n'
  done
  printf "%s\n%sHTTP_PROXY='%s'\nHTTPS_PROXY='%s'\nNO_PROXY='%s'\nhttp_proxy='%s'\nhttps_proxy='%s'\nno_proxy='%s'" \
    "$NET_MARK" "$folders" "$p" "$p" "$no" "$p" "$p" "$no"
}

# net_env_folder TEXT -> the first folder an env file of the engine names (the one that wrote it)
net_env_folder() {
  local l
  while IFS= read -r l; do
    case "$l" in
      "# Folder: "*)
        printf '%s' "${l#\# Folder: }"
        return 0
        ;;
    esac
  done <<< "$1"
}

# net_env_users TEXT -> the other folders an env file of the engine names whose installer still has a proxy
# set (one per line): the engine's proxy files stay while one of them uses them
net_env_users() {
  local l f
  while IFS= read -r l; do
    case "$l" in
      "# Folder: "*)
        f="${l#\# Folder: }"
        if [ "$f" != "$WORK_DIR" ] && [ -d "$f" ] && grep -qs '^INTERNET_PROXY="[^"]' "$f"/*.sh; then
          printf '%s\n' "$f"
        fi
        ;;
    esac
  done <<< "$1"
}

# net_env_body TEXT -> an env file of the engine without the line of its folder: what the engine reads
net_env_body() {
  local l
  while IFS= read -r l; do
    case "$l" in
      "# Folder: "*) ;;
      *) printf '%s\n' "$l" ;;
    esac
  done <<< "$1"
}

# net_env_proxy TEXT -> the proxy an env file of the engine holds, without its password
net_env_proxy() {
  local l
  while IFS= read -r l; do
    case "$l" in
      HTTPS_PROXY=*)
        l="${l#HTTPS_PROXY=}"
        l="${l#\'}"
        net_mask "${l%\'}"
        return 0
        ;;
    esac
  done <<< "$1"
}

# The drop-in of an engine's unit: the values stay in the env file (Environment= lines can be read by
# every user); "-": the engine starts without the file too
net_dropin_text() {
  printf '%s\n[Service]\nEnvironmentFile=-%s' "$NET_MARK" "$NET_ENGINE_ENV"
}

net_podman_conf_text() {
  printf '%s\n# Podman would hand its own proxy to every container it creates: only catalog-web and Nginx\n# Proxy Manager get one, from the compose file\n[containers]\nhttp_proxy = false' "$NET_MARK"
}

# net_engine_foreign KIND -> WHERE|PROXY when KIND has a proxy the installer did not set: Docker's
# daemon.json (it wins over every other setting) or a drop-in of the unit of KIND
net_engine_foreign() {
  local f v
  f="$NET_ETC/docker/daemon.json"
  if [ "$1" = "docker" ] && [ -r "$f" ]; then
    v="$(grep -o '"https\{0,1\}-proxy" *: *"[^"]*"' "$f")" || v=""
    v="${v%%$'\n'*}"
    if [ -n "$v" ]; then
      v="${v%\"}"
      printf 'docker/daemon.json|%s' "${v##*\"}"
      return 0
    fi
  fi
  for f in "$NET_UNITS/$1.service.d"/*.conf; do
    if [ -r "$f" ] && ! net_ours "$f"; then
      v="$(sed -n 's/^[^#]*[Hh][Tt][Tt][Pp][Ss]\{0,1\}_[Pp][Rr][Oo][Xx][Yy]=\([^" ]*\).*/\1/p' "$f")" || v=""
      v="${v%%$'\n'*}"
      if [ -n "$v" ]; then
        printf '%s|%s' "${f#"$NET_ETC"/}" "$v"
        return 0
      fi
    fi
  done
}

# net_engine_write ask|yes KIND -> the proxy of INTERNET_PROXY for the engine KIND (Docker or Podman on a
# Linux with systemd): its env file (mode 600, root) and the drop-in of its unit that points to it - for
# Podman also no proxy handed on to the containers. Without INTERNET_PROXY the installer's files go (not
# while the installer of another folder still uses them). A proxy in daemon.json is left alone (it wins
# anyway); one of another drop-in or of another folder is replaced only after a yes. KIND joins
# NET_ENGINE_CHANGED when something changed.
net_engine_write() {
  local mode="$1" kind="$2" name drop want have other foreign users f
  local -a keep=()
  case "$kind" in
    docker) name="Docker" ;;
    podman) name="Podman" ;;
    *) return 0 ;;
  esac
  if [ "$OS_KIND" = "Darwin" ] || [ ! -d "${RN1_SYSTEMD_DIR:-/run/systemd/system}" ] || { [ "$kind" = "docker" ] && docker_is_snap; }; then
    return 0
  fi
  drop="$(net_dropin "$kind")"
  want="$(net_engine_env_text)"
  if [ -z "$want" ]; then
    # Podman with a proxy of its own (another drop-in) still hands none to the containers (not for R)
    if [ "$kind" = "podman" ] && [ -z "$NET_CLEANUP" ] && ! net_ours "$drop" && [ -n "$(net_engine_foreign podman)" ]; then
      return 0
    fi
    if ! net_ours "$drop" && ! { [ "$kind" = "podman" ] && net_ours "$NET_PODMAN_CONF"; }; then
      return 0
    fi
    have="$(net_root_read "$NET_ENGINE_ENV")"
    users="$(net_env_users "$have")"
    if [ -n "$users" ]; then
      info "$name keeps the proxy the installer in ${users%%$'\n'*} gave it."
      # this folder no longer counts among its users
      if net_env_folders_has "$have" "$WORK_DIR"; then
        net_root_file "$NET_ENGINE_ENV" 600 "$(printf '%s\n' "$have" | awk -v me="# Folder: $WORK_DIR" '$0 != me')" || true
      fi
      return 0
    fi
    if ! net_root_file "$drop" || { [ "$kind" = "podman" ] && net_ours "$NET_PODMAN_CONF" && ! net_root_file "$NET_PODMAN_CONF"; }; then
      err "Cannot remove the proxy of $name ($drop)."
      return 1
    fi
    if [[ "$have" == "$NET_MARK"* ]] && ! net_ours "$(net_dropin docker)" && ! net_ours "$(net_dropin podman)"; then
      net_root_file "$NET_ENGINE_ENV" || true
    fi
    NET_ENGINE_CHANGED="$NET_ENGINE_CHANGED $kind"
    ok "$name has no proxy of the installer any more; removed:"
    echo "  $drop"
    return 0
  fi
  foreign="$(net_engine_foreign "$kind")"
  if [[ "$foreign" == "docker/daemon.json|"* ]]; then
    warn "Docker's proxy is set in $NET_ETC/docker/daemon.json, which wins over"
    echo "  every other setting: the installer leaves it as it is."
    echo "    $(net_mask "${foreign#*|}")"
    return 0
  fi
  have="$(net_root_read "$NET_ENGINE_ENV")"
  users="$(net_env_users "$have")"
  # the same proxy as the installer of another folder: both are recorded (the files stay while one uses them)
  if [ -n "$users" ] && [ "$(net_env_proxy "$have")" = "$(net_env_proxy "$want")" ]; then
    while IFS= read -r f; do
      keep+=("$f")
    done <<< "$users"
    want="$(net_engine_env_text "${keep[@]}")"
  fi
  if [ "$(net_env_body "$have")" = "$(net_env_body "$want")" ] && net_ours "$drop" && { [ "$kind" = "docker" ] || net_ours "$NET_PODMAN_CONF"; }; then
    if ! net_env_folders_has "$have" "$WORK_DIR"; then
      net_root_file "$NET_ENGINE_ENV" 600 "$want" || true
    fi
    return 0
  fi
  if [ -n "$foreign" ] && ! net_ours "$drop"; then
    warn "$name has a proxy of its own: $(net_mask "${foreign#*|}")"
    echo "  ($NET_ETC/${foreign%%|*})."
    echo "  The installer's drop-in would win over it; that file stays as it is."
    if [ "$mode" != "ask" ] || ! confirm "Give $name the proxy $INTERNET_PROXY instead?" n; then
      info "$name keeps its own proxy."
      net_podman_conf_keep "$kind"
      return 0
    fi
  fi
  other="$(net_env_folder "$have")"
  if [ -n "$users" ] && [ "$(net_env_proxy "$have")" != "$(net_env_proxy "$want")" ]; then
    other="${users%%$'\n'*}"
    warn "The installer in $other gave the engine another proxy:"
    echo "  $(net_env_proxy "$have") - one engine serves both folders."
    if [ "$mode" != "ask" ] || ! confirm "Replace it with $INTERNET_PROXY?" n; then
      info "$name keeps that proxy."
      net_podman_conf_keep "$kind"
      return 0
    fi
  fi
  if ! net_root_file "$NET_ENGINE_ENV" 600 "$want" || ! net_root_file "$drop" 644 "$(net_dropin_text)" \
    || { [ "$kind" = "podman" ] && ! net_root_file "$NET_PODMAN_CONF" 644 "$(net_podman_conf_text)"; }; then
    err "Cannot write the proxy of $name ($drop, $NET_ENGINE_ENV)."
    return 1
  fi
  NET_ENGINE_CHANGED="$NET_ENGINE_CHANGED $kind"
  ok "$name gets the proxy: $drop"
  echo "  It reads $NET_ENGINE_ENV (mode 600)."
}

# net_env_folders_has TEXT FOLDER -> true when an env file of the engine names FOLDER
net_env_folders_has() {
  [[ $'\n'"$1"$'\n' == *$'\n'"# Folder: $2"$'\n'* ]]
}

# net_podman_conf_keep KIND -> Podman keeps a proxy that is not the installer's: it still hands it to no
# container (containers.conf.d), so the services of the Catalog call each other directly
net_podman_conf_keep() {
  if [ "$1" != "podman" ] || net_ours "$NET_PODMAN_CONF"; then
    return 0
  fi
  if net_root_file "$NET_PODMAN_CONF" 644 "$(net_podman_conf_text)"; then
    NET_ENGINE_CHANGED="$NET_ENGINE_CHANGED podman"
    ok "Podman hands its proxy to no container: $NET_PODMAN_CONF"
  fi
}

# net_engine_restart ask|yes KIND -> KIND reads its changed proxy files: systemd reloads its units; a running
# Docker restarts after a yes (the Catalog is unreachable for about a minute; without the question it is
# only said); a running Podman service stops (its socket starts it again; the containers keep running)
net_engine_restart() {
  local mode="$1" kind="$2"
  local -a steps=("systemctl daemon-reload")
  if [[ " $NET_ENGINE_CHANGED " != *" $kind "* ]]; then
    return 0
  fi
  NET_ENGINE_CHANGED="${NET_ENGINE_CHANGED// $kind/}"
  case "$kind" in
    docker)
      if systemctl is-active --quiet docker 2>/dev/null; then
        info "Docker reads the change when it restarts: the Catalog is unreachable for"
        echo "  about a minute, then its containers come back by themselves."
        if [ "$mode" = "ask" ] && confirm "Restart Docker now?" n; then
          steps+=("systemctl restart docker")
        else
          info "Docker reads the change at its next restart (systemctl restart docker)."
        fi
      fi
      ;;
    podman)
      if systemctl is-active --quiet podman.service 2>/dev/null; then
        steps+=("systemctl stop podman.service")
      fi
      ;;
  esac
  run_plan "${steps[@]}"
}

# net_engine_plan KIND -> before KIND is set up: true when it gets the installer's proxy files (or loses
# them), with a note for the list of the steps
net_engine_plan() {
  if [ "$OS_KIND" = "Darwin" ]; then
    return 1
  fi
  if [ -n "$INTERNET_PROXY" ]; then
    echo "  $(kind_name "$1") gets the internet proxy before these steps:"
    echo "    $(net_dropin "$1")"
    echo "    reads $NET_ENGINE_ENV (mode 600)"
    return 0
  fi
  net_ours "$(net_dropin "$1")"
}

# The engines whose proxy differs from INTERNET_PROXY as far as it shows without root (one per line: KIND):
# no drop-in of the installer although a proxy is set or the shell has one (and none of their own), or one
# without a proxy
net_engine_stale() {
  local kind
  if [ "$OS_KIND" = "Darwin" ] || [ ! -d "${RN1_SYSTEMD_DIR:-/run/systemd/system}" ]; then
    return 0
  fi
  for kind in docker podman; do
    if ! net_installed "$kind" || { [ "$kind" = "docker" ] && docker_is_snap; }; then
      continue
    fi
    # (a proxy only the shell has counts too: the engine does not read it)
    if [ -n "$INTERNET_PROXY$NET_SHELL_PROXY" ] && ! net_ours "$(net_dropin "$kind")" && [ -z "$(net_engine_foreign "$kind")" ]; then
      printf '%s\n' "$kind"
    elif [ -z "$INTERNET_PROXY" ] && net_ours "$(net_dropin "$kind")"; then
      printf '%s\n' "$kind"
    fi
  done
}

# Where the company certificate goes in the trust store of this Linux: FOLDER|EXTENSION|COMMAND; empty when
# the installer knows none here. RN1_TRUST_DIR: another folder (the tests).
net_trust_target() {
  local os dir ext="pem" cmd
  if [ "$OS_KIND" = "Darwin" ]; then
    return 0
  fi
  os=" $(os_release ID) $(os_release ID_LIKE) "
  case "$os" in
    *suse*|*sles*) dir="/etc/pki/trust/anchors"; cmd="update-ca-certificates" ;;
    *debian*|*ubuntu*) dir="/usr/local/share/ca-certificates"; ext="crt"; cmd="update-ca-certificates" ;;
    *) dir="/etc/pki/ca-trust/source/anchors"; cmd="update-ca-trust extract" ;;
  esac
  if command -v "${cmd%% *}" >/dev/null 2>&1 || [ -x "/usr/sbin/${cmd%% *}" ] || [ -x "/sbin/${cmd%% *}" ]; then
    printf '%s|%s|%s' "${RN1_TRUST_DIR:-$dir}" "$ext" "$cmd"
  fi
}

# The name of this folder's company certificates in the trust store: rn1-proxy-ca-<checksum of the folder>
# (one more installation on this server keeps its own; -N.EXT follows)
net_trust_name() {
  printf 'rn1-proxy-ca-%s' "$(printf '%s' "$WORK_DIR" | cksum | cut -d' ' -f1)"
}

# True when the company certificate of this folder is in the trust store of this server
net_ca_trusted() {
  local t dir ext cmd f
  t="$(net_trust_target)"
  if [ -z "$t" ]; then
    return 1
  fi
  IFS='|' read -r dir ext cmd <<< "$t"
  for f in "$dir/$(net_trust_name)"-*."$ext"; do
    if [ -f "$f" ]; then
      return 0
    fi
  done
  return 1
}

# net_ca_trust ask|remove -> the company certificate (proxy-ca.pem) into the trust store of this Linux after
# a yes, one file per certificate, then the check again (the certificates now trusted); or out of it. The
# engines read it at their next start (NET_ENGINE_CHANGED). 1: not done
net_ca_trust() {
  local mode="$1" t dir ext cmd pem l cert="" n=0 kind
  if [ "$OS_KIND" = "Darwin" ]; then
    return 1
  fi
  t="$(net_trust_target)"
  if [ -z "$t" ]; then
    if [ "$mode" = "ask" ]; then
      warn "No known trust store here (update-ca-trust, update-ca-certificates):"
      echo "  add $PROXY_CA_COPY to the certificates of this system yourself."
    fi
    return 1
  fi
  IFS='|' read -r dir ext cmd <<< "$t"
  if ! use_sudo; then
    warn "The trust store of this server needs root: run as root, or install sudo."
    return 1
  fi
  if [ "$mode" = "remove" ]; then
    if ! net_ca_trusted; then
      return 0
    fi
    ${SUDO[@]+"${SUDO[@]}"} sh -c 'rm -f -- "$1/$3"-*."$2"' sh "$dir" "$ext" "$(net_trust_name)" || return 1
    run_plan "$cmd" || return 1
    ok "The company certificate is out of the trust store of this server."
  else
    pem="$(net_ca_pem "$PROXY_CA_COPY")" || return 1
    echo
    echo "  This server, its engine and its downloads trust the certificate once it is in"
    echo "  the trust store of the system ($cmd):"
    echo "    $dir/$(net_trust_name)-N.$ext"
    if ! confirm "Add it to the trust store of this server?" y; then
      info "Not added: downloads through the inspection fail until it is there."
      return 1
    fi
    ${SUDO[@]+"${SUDO[@]}"} sh -c 'rm -f -- "$1/$3"-*."$2"' sh "$dir" "$ext" "$(net_trust_name)" || return 1
    while IFS= read -r l; do
      l="${l%$'\r'}"
      cert="$cert$l"$'\n'
      if [ "$l" = "-----END CERTIFICATE-----" ]; then
        n=$((n + 1))
        if ! net_root_file "$dir/$(net_trust_name)-$n.$ext" 644 "${cert%$'\n'}"; then
          err "Cannot write $dir/$(net_trust_name)-$n.$ext."
          return 1
        fi
        cert=""
      fi
    done <<< "$pem"
    run_plan "$cmd" || return 1
    ok "The company certificate is in the trust store of this server."
  fi
  for kind in docker podman; do
    if net_installed "$kind"; then
      NET_ENGINE_CHANGED="$NET_ENGINE_CHANGED $kind"
    fi
  done
  if [ "$mode" = "ask" ] && command -v curl >/dev/null 2>&1; then
    echo
    info "The check again, now with the trusted certificate:"
    net_check show || true
  fi
}

# net_private_write FILE -> stdin into FILE, readable only by its owner from the start: written next to it
# with umask 077, then moved into its place (the LaunchAgent holds the proxy login)
net_private_write() {
  if ! (umask 077 && cat > "$1.rn1-new") || ! chmod 600 "$1.rn1-new" || ! mv -f -- "$1.rn1-new" "$1"; then
    rm -f -- "$1.rn1-new"
    warn "Cannot write $1."
    return 1
  fi
}

# The proxy for the LaunchAgent of the Podman machine (nothing without INTERNET_PROXY): Podman writes the
# proxy into the machine at every start from the variables of the process that starts it, and removes it
# when they are missing
net_plist_env() {
  local p no
  if [ -z "$INTERNET_PROXY" ]; then
    return 0
  fi
  p="$(net_with_login "$INTERNET_PROXY")"
  no="$(net_no_proxy_engine)"
  printf '\n  <key>EnvironmentVariables</key><dict>'
  printf '<key>%s</key><string>%s</string>' HTTP_PROXY "$p" HTTPS_PROXY "$p" NO_PROXY "$no" http_proxy "$p" https_proxy "$p" no_proxy "$no"
  printf '</dict>'
}

# net_colima_env FILE -> FILE (colima.yaml) with the proxy in its env: - the variables Colima gives the
# Docker of its VM; started by brew services, Colima has no other place for them - or without them when
# INTERNET_PROXY is empty. 0: changed; 1: as it was; 3: an env: the installer cannot change
net_colima_env() {
  local f="$1" add="" p no tmp rc=0
  if [ ! -f "$f" ]; then
    return 1
  fi
  if [ -n "$INTERNET_PROXY" ]; then
    p="$(net_with_login "$INTERNET_PROXY")"
    no="$(net_no_proxy_engine)"
    add="  HTTP_PROXY: '$p'
  HTTPS_PROXY: '$p'
  NO_PROXY: '$no'
  http_proxy: '$p'
  https_proxy: '$p'
  no_proxy: '$no'"
  fi
  tmp="$(mktemp "$f.XXXXXX")" || return 3
  NET_E="$add" awk '
    BEGIN { add = ENVIRON["NET_E"]; ours = "^[ \t]+(HTTP_PROXY|HTTPS_PROXY|NO_PROXY|http_proxy|https_proxy|no_proxy):" }
    function flush(  out) {
      out = kept
      if (add != "") out = out (out != "" ? "\n" : "") add
      if (out == "") print "env: {}"
      else { print "env:"; print out }
      printf "%s", blanks
      blanks = ""
      done = 1
      inenv = 0
    }
    # empty lines in the block wait: they belong to it only when more of it follows
    inenv && $0 ~ /^[ \t]*$/ { blanks = blanks $0 "\n"; next }
    inenv && $0 ~ /^[ \t]/ {
      if ($0 !~ ours) {
        if (kept != "") kept = kept "\n"
        kept = kept blanks $0
      }
      blanks = ""
      next
    }
    inenv { flush() }
    /^env:[ \t]*\{[ \t]*\}[ \t]*(#.*)?$/ { kept = ""; flush(); next }
    /^env:[ \t]*(#.*)?$/ { inenv = 1; kept = ""; next }
    /^env:/ { bad = 1 }
    { print }
    END {
      if (inenv) flush()
      else if (!done && add != "") { print "env:"; print add }
      if (bad) exit 3
    }' "$f" > "$tmp" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f -- "$tmp"
    return 3
  fi
  if [ "$(cat -- "$tmp")" = "$(cat -- "$f")" ]; then
    rm -f -- "$tmp"
    return 1
  fi
  # the new file is mode 600 from its start (mktemp) and takes the place of the old one: the login is
  # never in a file others can read
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$f"; then
    rm -f -- "$tmp"
    return 3
  fi
}

# net_colima_apply ask|yes DEFAULT -> the proxy in colima.yaml, and Colima restarted to use it: after a yes
# (DEFAULT: the answer of Enter), or without a question when DEFAULT is y and no question is asked
net_colima_apply() {
  local mode="$1" def="$2" yaml rc=0
  yaml="$(mac_colima_yaml)"
  if [ ! -f "$yaml" ]; then
    return 0
  fi
  net_colima_env "$yaml" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *)
      warn "The env: of $yaml is written in a form the installer"
      echo "  does not change: give Colima the proxy there yourself."
      return 0
      ;;
  esac
  if [ -n "$INTERNET_PROXY" ]; then
    ok "Colima gets the proxy: env: in"
    echo "  $yaml (mode 600)"
  else
    ok "Colima has no proxy of the installer any more:"
    echo "  $yaml"
  fi
  if { [ "$mode" = "yes" ] && [ "$def" = "y" ]; } || { [ "$mode" = "ask" ] && confirm "Restart Colima now to use it (the Catalog stops for about a minute)?" "$def"; }; then
    colima restart || warn "colima restart failed - start it again: colima start"
  else
    info "Colima uses it after its next restart (colima restart)."
  fi
}

# The internet settings for the engine of this Mac: the LaunchAgent of the Podman machine and the machine's
# restart after a yes, colima.yaml, or what to set in Docker Desktop
net_mac_apply() {
  local name changed="no"
  case "$(net_engine)" in
    podman)
      if ! command -v podman >/dev/null 2>&1; then
        return 0
      fi
      name="$(mac_machine)"
      if [ -z "$name" ]; then
        return 0
      fi
      if [ ! -f "$MAC_AGENT" ]; then
        changed="yes"
      elif [ "$(mac_agent "$name")" != "$(cat -- "$MAC_AGENT" 2>/dev/null)" ]; then
        launchctl unload "$MAC_AGENT" >/dev/null 2>&1 || true
        mac_agent "$name" | net_private_write "$MAC_AGENT"
        launchctl load -w "$MAC_AGENT" >/dev/null 2>&1 || true
        ok "LaunchAgent updated: the Podman machine gets the proxy at every start."
        changed="yes"
      fi
      if [ "$changed" = "yes" ]; then
        info "The Podman machine $name uses the proxy from its next start."
        if confirm "Restart it now (the Catalog stops for about a minute)?" n; then
          podman machine stop "$name" >/dev/null 2>&1 || true
          podman machine start "$name" || warn "podman machine start $name failed."
        fi
      fi
      ;;
    colima) net_colima_apply ask n ;;
    docker)
      if [ -n "$INTERNET_PROXY" ]; then
        info "Docker Desktop takes its proxy from its own settings: Settings > Resources >"
        echo "  Proxies - System (the proxy of macOS, also a PAC file), or Manual with"
        echo "  $INTERNET_PROXY (and the login)."
      fi
      ;;
  esac
}

# net_apply -> the internet settings applied after they changed: the engines of this server (Linux: their
# drop-ins, a restart after a yes; macOS: the Podman machine, Colima, Docker Desktop described), then
# catalog-web and Nginx Proxy Manager (.env, the compose file, created again after a yes). What cannot be
# done is said.
net_apply() {
  local kind
  NET_APPLY_PENDING=""
  if [ "$OS_KIND" = "Darwin" ]; then
    net_mac_apply || true
  elif use_sudo; then
    for kind in docker podman; do
      if net_installed "$kind"; then
        net_engine_write ask "$kind" || true
        net_engine_restart ask "$kind" || true
      fi
    done
  elif [ -n "$(net_engine_stale)" ]; then
    warn "The engine gets the proxy only as root: run option 26 as root (sudo)."
  fi
  net_catalog_apply || true
}

# The lines of the summary before a proxy is saved: where the engine and the Catalog get it
net_summary_apply() {
  local kind shown="no"
  if [ "$OS_KIND" = "Darwin" ]; then
    case "$(net_engine)" in
      podman) echo "    engine        the Podman machine, from its next start (LaunchAgent)" ;;
      colima) echo "    engine        Colima: env: of colima.yaml (mode 600)" ;;
      docker) echo "    engine        Docker Desktop: in its own settings (shown after saving)" ;;
    esac
    return 0
  fi
  for kind in docker podman; do
    if net_installed "$kind"; then
      printf '    %-13s %s\n' "$(if [ "$shown" = "no" ]; then printf 'engine'; fi)" "$(kind_name "$kind"): $(net_dropin "$kind")"
      shown="yes"
    fi
  done
  if [ "$shown" = "yes" ]; then
    echo "                  -> $NET_ENGINE_ENV (mode 600)"
  else
    echo "    engine        a drop-in of its service when it is set up (mode 600)"
  fi
  echo "    Catalog       catalog-web and Nginx Proxy Manager, through $ENV_FILE (HTTPS"
  echo "                  only); the other services get no proxy"
}

# net_offer_check WHAT -> after WHAT failed (a download): in a terminal the check of the internet access is
# offered, otherwise named
net_offer_check() {
  local ans=0 rc
  if ! net_enabled; then
    return 0
  fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    info "$(hint 26 network-check) checks the internet access (a proxy may be missing)."
    return 0
  fi
  echo
  wiz_yes_no "$1 failed. Check the internet access now?" y || ans=$?
  if [ "$ans" -ne 0 ]; then
    return 0
  fi
  echo
  net_via_settings
  rc=0
  net_check show || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo
    net_ask || true
  fi
}

# net_adopt FOLDER ENV-FILE -> what a taken-over installation had for the internet: its login (.proxy_login,
# mode 600) and company certificate (proxy-ca.pem), and the proxy of its .env as INTERNET_PROXY when none
# is set here
net_adopt() {
  local dir="$1" envf="$2" v
  if [ -f "$dir/.proxy_login" ] && [ ! -e "$PROXY_LOGIN_FILE" ] && (umask 077 && cp -- "$dir/.proxy_login" "$PROXY_LOGIN_FILE"); then
    chmod 600 "$PROXY_LOGIN_FILE"
    ok "Took over its proxy login ($(basename -- "$PROXY_LOGIN_FILE"), mode 600)."
  fi
  v="$(env_unquote "$(env_file_value RN1_HTTPS_PROXY "$envf")")"
  if [ -n "$v" ] && [ -z "$INTERNET_PROXY" ] && net_parse "$v" && [ -n "$NP_PORT" ]; then
    case "$NP_HOST" in
      host.docker.internal|host.containers.internal) NP_HOST="127.0.0.1" ;;
    esac
    if set_setting INTERNET_PROXY "$NP_SCHEME://$NP_HOST:$NP_PORT"; then
      INTERNET_PROXY="$NP_SCHEME://$NP_HOST:$NP_PORT"
      if [ -n "$NP_LOGIN" ] && [ ! -e "$PROXY_LOGIN_FILE" ]; then
        proxy_login_save "$NP_LOGIN" || true
      fi
      ok "Took over its internet proxy: $INTERNET_PROXY"
    fi
  fi
  if [ -f "$dir/proxy-ca.pem" ] && [ -z "$INTERNET_PROXY_CA_FILE" ] && cp -- "$dir/proxy-ca.pem" "$PROXY_CA_COPY" \
    && set_setting INTERNET_PROXY_CA_FILE "$PROXY_CA_COPY"; then
    INTERNET_PROXY_CA_FILE="$PROXY_CA_COPY"
    ok "Took over its company certificate ($(basename -- "$PROXY_CA_COPY"))."
  fi
}

# True when this server has proxy files of the installer: an engine's drop-in, the company certificate in
# the trust store
net_proxy_files() {
  net_ours "$(net_dropin docker)" || net_ours "$(net_dropin podman)" || net_ours "$NET_PODMAN_CONF" || net_ca_trusted
}

# R: the installer's proxy files of the engines and the company certificate in the trust store go (a
# running engine keeps the proxy until its next restart). 1: not everything
net_proxy_cleanup() {
  local kind rc=0
  use_sudo || return 1
  for kind in docker podman; do
    NET_CLEANUP="yes" INTERNET_PROXY="" net_engine_write yes "$kind" || rc=1
    net_engine_restart yes "$kind" || rc=1
  done
  net_ca_trust remove || rc=1
  return "$rc"
}

###############################################################################
# Settings screen (menu option 1)
###############################################################################

# The settings of this script while the screen is open (same index everywhere): group key, group
# title, name, saved value, value on the screen, "1" when that value is not saved yet.
SET_GROUP=()
SET_TITLE=()
SET_NAME=()
SET_SAVED=()
SET_NEW=()
SET_MOD=()
SET_FILTER=""
SET_NOTE=""
SET_CELL=""
SET_NCHANGED=0
SET_CHANGED=""
if [ "$UI_UTF" = "true" ]; then
  SET_LEADER="·"
  SET_MARK="✎"
else
  SET_LEADER="."
  SET_MARK="*"
fi

# GROUP|NAME|VALUE for every setting of FILE, grouped by what the names have in common: names
# ending in _TAG are the image tags ("_TAG"); a first word that two or more settings share makes a
# group ("CATALOG_", "MINIO_" ...); then a last word that two or more share ("_CRON"); the rest is
# "-" (general). Groups keep the order of the settings section, so new settings appear by themselves.
settings_grouped() {
  local pairs
  pairs="$(settings_pairs "$1")" || return 1
  if [ -z "$pairs" ]; then
    return 1
  fi
  awk -F'|' '
    $0 !~ /^[A-Z_][A-Z0-9_]*\|/ { next }
    {
      n++
      name[n] = $1
      val[n] = substr($0, length($1) + 2)
      if ($1 ~ /_TAG$/) { grp[n] = "_TAG"; next }
      if (index($1, "_")) { p = $1; sub(/_.*/, "", p); pre[n] = p; cp[p]++ }
    }
    END {
      for (i = 1; i <= n; i++) {
        if (grp[i] == "" && pre[i] != "" && cp[pre[i]] >= 2) grp[i] = pre[i] "_"
      }
      for (i = 1; i <= n; i++) {
        if (grp[i] == "" && index(name[i], "_")) { s = name[i]; sub(/.*_/, "", s); suf[i] = s; cs[s]++ }
      }
      for (i = 1; i <= n; i++) {
        if (grp[i] == "") grp[i] = (suf[i] != "" && cs[suf[i]] >= 2) ? "_" suf[i] : "-"
        if (!(grp[i] in seen)) { seen[grp[i]] = 1; order[++g] = grp[i] }
      }
      for (j = 1; j <= g; j++) {
        for (i = 1; i <= n; i++) {
          if (grp[i] == order[j]) print grp[i] "|" name[i] "|" val[i]
        }
      }
    }' <<< "$pairs"
}

# Display name of a group key of settings_grouped
settings_group_title() {
  local w
  case "$1" in
    -) printf 'General' ;;
    _TAG) printf 'Image tags' ;;
    _CRON) printf 'Schedules' ;;
    CATALOG_) printf 'Catalog' ;;
    MONGO_) printf 'MongoDB' ;;
    MINIO_) printf 'MinIO' ;;
    RABBITMQ_) printf 'RabbitMQ' ;;
    OPENSEARCH_) printf 'OpenSearch' ;;
    NPM_) printf 'Nginx Proxy Manager' ;;
    ASPNETCORE_) printf 'ASP.NET Core' ;;
    COMPOSE_) printf 'Docker Compose' ;;
    FILESTORAGE_) printf 'File storage' ;;
    INTERNET_) printf 'Internet access' ;;
    *)
      w="${1//_/}"
      printf '%s%s' "${w:0:1}" "$(printf '%s' "${w:1}" | tr '[:upper:]' '[:lower:]')"
      ;;
  esac
}

# "MINIO_*" or "*_TAG" for a group key (empty for the general group)
settings_group_pattern() {
  case "$1" in
    -) ;;
    _*) printf '*%s' "$1" ;;
    *) printf '%s*' "$1" ;;
  esac
}

# One line about a setting for its edit screen (empty when nothing is known about it)
settings_hint() {
  local name="$1" value="$2"
  case "$name" in
    ENV_FILE) printf 'File name of the generated environment file (it holds the passwords)' ;;
    COMPOSE_FILE) printf 'File name of the generated Docker Compose file' ;;
    COMPOSE_PROJECT_NAME) printf 'Compose project name; empty uses the folder name (a-z, 0-9, - and _)' ;;
    TZ) printf 'Time zone of all containers, e.g. Europe/Berlin; the job times (*_CRON) run in it' ;;
    BASEURL) printf 'BASEURL of catalog-web' ;;
    INSTALL_NGINX_PROXY_MANAGER) printf 'true starts Nginx Proxy Manager (reverse proxy with TLS) with the stack' ;;
    CONTAINER_ENGINE) printf 'podman, docker%s; empty: the engine that holds this installation (now %s)' "$(if [ "$OS_KIND" = "Darwin" ]; then printf ' or colima'; fi)" "$ENGINE_KIND" ;;
    CATALOG_DOMAIN) printf 'Host name of the Catalog, e.g. catalog.example.com; empty: the address of the server (option 24)' ;;
    NPM_ADMIN_EMAIL) printf 'Login of Nginx Proxy Manager and the e-mail address for Let'"'"'s Encrypt; the password is generated into %s' "$ENV_FILE" ;;
    INTERNET_PROXY) printf 'Proxy to the internet, e.g. http://proxy.example.com:8080; empty: directly (or the proxy of the shell). Option 26 checks it; its login is in .proxy_login%s' "$(value="$(proxy_login_user)"; if [ -n "$value" ]; then printf ' (%s, password saved)' "$value"; fi)" ;;
    INTERNET_NO_PROXY) printf 'Internal names reached without the proxy, comma-separated, e.g. corp.example.com (this server and the Catalog always are)' ;;
    INTERNET_PROXY_CA_FILE) printf 'Root certificate (PEM) of a network that inspects HTTPS; option 26 asks for it and keeps a copy' ;;
    INTERNET_PROXY_PAC) printf 'The PAC file INTERNET_PROXY was taken from (read once; option 26 reads it again)' ;;
    CATALOG_VERSION) printf 'Version of catalog-web and all workers; option 8 picks one from Docker Hub' ;;
    CATALOG_IMAGE_REPO) printf 'Docker Hub repository of catalog-web' ;;
    CATALOG_WORKER_IMAGE_REPO) printf 'Docker Hub repository of the four workers' ;;
    CHECK_FOR_UPDATES) printf 'true: the menu looks for new Catalog versions on Docker Hub' ;;
    CATALOG_LICENSE_PATH) printf 'Folder of the license volume inside catalog-web' ;;
    CATALOG_HOSTNAME) printf 'Host name of catalog-web, which the license is bound to; empty: as in %s, else the one of a licensed catalog-web, else this server (%s)' "$ENV_FILE" "$(server_hostname)" ;;
    CATALOG_CLOUD_URL) printf 'Online catalog for snapshots (option 17) and the daily self-sync (option 20)' ;;
    SYNC_MAX_UPLOAD) printf 'Largest snapshot upload of Catalog 26.x, e.g. 32GB (25.x: fixed 10 GB)' ;;
    HEALTH_TIMEOUT) printf 'Seconds the guided upgrade waits for a healthy stack' ;;
    INSTALLER_URL) printf 'Where option 22 downloads new versions of this installer' ;;
    OPENSEARCH_HEAP) printf 'Java heap of OpenSearch, e.g. -Xms1g -Xmx1g' ;;
    MONGO_CACHE_GB) printf 'Cache of MongoDB in GB (at least 0.25); empty: automatic, (memory of the engine - 10 GB) / 2%s' "$(value="$(env_value MONGO_WT_CACHE_GB)"; if [ -n "$value" ]; then printf ' - %s has %s' "$ENV_FILE" "$value"; fi)" ;;
    OPENSEARCH_URL) printf 'Address of OpenSearch inside the stack' ;;
    X_FRAME_OPTIONS) printf 'X-Frame-Options header of Nginx Proxy Manager' ;;
    DISABLE_IPV6) printf 'true: Nginx Proxy Manager does not use IPv6' ;;
    QUEUE_PREFIX) printf 'Prefix of the RabbitMQ queues of the Catalog' ;;
    FILESTORAGE_BUCKET) printf 'MinIO bucket of the Catalog files' ;;
    AUTOSYNC_CRON) printf 'Daily synchronization: minute hour day month weekday, in TZ; - turns it off' ;;
    VULNERABILITIES_CACHING_CRON) printf 'Vulnerability caching: minute hour day month weekday, in TZ; - turns it off' ;;
    LOG_LEVEL_DEFAULT) printf 'Trace, Debug, Information, Warning, Error, Critical or None' ;;
    MONGO_INITDB_ROOT_USERNAME|MINIO_ROOT_USER|RABBITMQ_DEFAULT_USER) printf 'User name; the password is generated into %s' "$ENV_FILE" ;;
    *_TAG) printf 'Image tag; option 8 shows newer ones' ;;
    *_CRON) printf 'Cron expression: minute hour day month weekday, in TZ' ;;
    *_PORT_CONTAINER) printf 'Port inside the container (1-65535)' ;;
    *_PORT|*_PORT_HOST) printf 'Port on this server (1-65535)' ;;
    *)
      if [ "$value" = "true" ] || [ "$value" = "false" ]; then
        printf 'true or false'
      fi
      ;;
  esac
}

# settings_empty_ok NAME SAVED -> true when NAME may be empty (it is empty now, or empty has a meaning)
settings_empty_ok() {
  [ -z "$2" ] || [ "$1" = "COMPOSE_PROJECT_NAME" ] || [ "$1" = "CONTAINER_ENGINE" ] || [ "$1" = "CATALOG_DOMAIN" ] || [ "$1" = "NPM_ADMIN_EMAIL" ] || [ "$1" = "CATALOG_HOSTNAME" ] || [ "$1" = "MONGO_CACHE_GB" ] || [[ "$1" == INTERNET_* ]]
}

# settings_check NAME VALUE SAVED -> fails and prints the reason when VALUE does not fit NAME
settings_check() {
  local name="$1" value="$2" saved="$3" f spec idx lo hi what k ports_re='^[1-9][0-9]{0,4}(;[1-9][0-9]{0,4})*$'
  local -a fields=() names=()
  if [[ "$value" == *[[:cntrl:]]* ]]; then
    echo "Control characters are not allowed."
    return 1
  fi
  # the generated .env holds the values without quotes: Docker Compose would read these differently
  if [[ "$value" == *[\"\'\\\$\`]* ]] || [[ "$value" == *" #"* ]]; then
    echo "Not allowed: \" ' \\ \$ \` and \" #\" (the generated $ENV_FILE cannot hold them)."
    return 1
  fi
  if [ -z "$value" ]; then
    if settings_empty_ok "$name" "$saved"; then
      return 0
    fi
    echo "$name must not be empty."
    return 1
  fi
  if { [ "$saved" = "true" ] || [ "$saved" = "false" ]; } && [ "$value" != "true" ] && [ "$value" != "false" ]; then
    echo "$name is true or false."
    return 1
  fi
  if [[ "$name" =~ _PORT(_[A-Z]+)?$ ]]; then
    if ! [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$value" -gt 65535 ]; then
      echo "A port is a number from 1 to 65535."
      return 1
    fi
  fi
  case "$name" in
    *_PORTS)
      if ! [[ "$value" =~ $ports_re ]]; then
        echo "Give one or more ports separated by ;, e.g. 80 or 80;8080."
        return 1
      fi
      ;;
    MINIO_ROOT_USER)
      if [ "${#value}" -lt 3 ]; then
        echo "MinIO needs a user name of at least 3 characters."
        return 1
      fi
      ;;
  esac
  case "$name" in
    *_CRON)
      if [ "$value" = "-" ]; then
        return 0
      fi
      read -r -a fields <<< "$value"
      if [ "${#fields[@]}" -ne 5 ]; then
        echo "Give five fields (minute hour day month weekday), e.g. 30 7 * * *, or - to turn the job off."
        return 1
      fi
      for spec in "0 0 59 minute" "1 0 23 hour" "2 1 31 day" "3 1 12 month" "4 0 7 weekday"; do
        read -r idx lo hi what <<< "$spec"
        f="${fields[idx]}"
        # month and weekday may use names (JAN, MON-FRI): checked as their numbers
        if [ "$idx" -eq 3 ]; then
          names=(JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC)
        else
          names=(SUN MON TUE WED THU FRI SAT)
        fi
        if [ "$idx" -ge 3 ]; then
          f="${f^^}"
          for ((k = 0; k < ${#names[@]}; k++)); do
            f="${f//${names[k]}/$((k + lo))}"
          done
        fi
        if cron_values "$f" "$lo" "$hi" >/dev/null 2>&1; then
          continue
        fi
        echo "The $what field \"${fields[idx]}\" is not valid (allowed: $lo-$hi, *, lists, ranges and steps)."
        return 1
      done
      ;;
    TZ)
      if ! [[ "$value" =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]]; then
        echo "\"$value\" is not a time zone name (e.g. Europe/Berlin, Asia/Singapore, UTC)."
        return 1
      fi
      if [ -f /usr/share/zoneinfo/Europe/Berlin ] && ! tz_known "$value"; then
        echo "\"$value\" is not a time zone this server knows (e.g. Europe/Berlin, Asia/Singapore, UTC)."
        return 1
      fi
      ;;
    SYNC_MAX_UPLOAD)
      if ! [[ "$value" =~ ^[1-9][0-9]{0,6}(GB|MB|KB)$ ]] && ! [[ "$value" =~ ^[1-9][0-9]{0,14}$ ]]; then
        echo "Give a size like 32GB, 8000MB or a number of bytes."
        return 1
      fi
      ;;
    HEALTH_TIMEOUT)
      if ! [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]]; then
        echo "Give the number of seconds, e.g. 600."
        return 1
      fi
      ;;
    MONGO_CACHE_GB)
      if ! mongo_cache_valid "$value"; then
        echo "Give the cache in GB, e.g. 4 or 2.5 (at least 0.25), or \"\" for automatic."
        return 1
      fi
      ;;
    LOG_LEVEL_DEFAULT)
      case "$value" in
        Trace|Debug|Information|Warning|Error|Critical|None) ;;
        *)
          echo "Use Trace, Debug, Information, Warning, Error, Critical or None."
          return 1
          ;;
      esac
      ;;
    COMPOSE_PROJECT_NAME)
      if ! [[ "$value" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Only lower-case letters, digits, - and _ (or \"\" for the folder name)."
        return 1
      fi
      ;;
    CONTAINER_ENGINE)
      if [ "$value" = "colima" ] && [ "$OS_KIND" != "Darwin" ]; then
        echo "Colima runs only on macOS - use podman or docker."
        return 1
      fi
      case "$value" in
        podman|docker|colima) ;;
        *)
          echo "Use podman, docker$(if [ "$OS_KIND" = "Darwin" ]; then printf ', colima'; fi) or \"\" (the engine that holds this installation)."
          return 1
          ;;
      esac
      if [ "$value" != "$saved" ]; then
        f="$(engine_switch_problem "$value")"
        if [ -n "$f" ]; then
          echo "$f"
          return 1
        fi
      fi
      ;;
    ENV_FILE|COMPOSE_FILE)
      if [[ "$value" =~ [[:space:]/] ]] || [ "$value" = "$SCRIPT_NAME" ]; then
        echo "Give a plain file name in this folder (no spaces, no /, not $SCRIPT_NAME)."
        return 1
      fi
      ;;
    CATALOG_DOMAIN)
      if ip_address "$value"; then
        echo "\"$value\" is an IP address - leave it empty to use the IP address."
        return 1
      fi
      if ! domain_valid "$value"; then
        echo "Give a host name in lower case, e.g. catalog.example.com: letters, digits and -, at least one dot (no http://, port or path)."
        return 1
      fi
      ;;
    CATALOG_HOSTNAME)
      if hostname_taken "$value"; then
        echo "\"$value\" is a service of the stack: inside catalog-web it would name catalog-web itself."
        return 1
      fi
      if [ "${value,,}" = "localhost" ]; then
        echo "localhost is every machine's name for itself - give a name of its own, e.g. catalog01."
        return 1
      fi
      if ! hostname_valid "$value"; then
        echo "Give a host name without the domain: letters, digits and -, at most 63 characters, no dots (e.g. catalog01)."
        return 1
      fi
      ;;
    NPM_ADMIN_EMAIL)
      if ! email_valid "$value"; then
        echo "Give an e-mail address, e.g. it@example.com."
        return 1
      fi
      if [ "$value" != "${value,,}" ]; then
        echo "Give the e-mail address in lower case (${value,,}): Nginx Proxy Manager takes logins only in lower case."
        return 1
      fi
      ;;
    INTERNET_PROXY)
      if [[ "$value" != *://* ]] || ! net_parse "$value"; then
        echo "Give scheme://host:port, e.g. http://proxy.example.com:8080 (http, https, socks5 or socks5h; no path)."
        return 1
      fi
      if [ -n "$NP_LOGIN" ]; then
        echo "No login in the address: option 26 keeps it in .proxy_login (mode 600), not in the script."
        return 1
      fi
      if [ -z "$NP_PORT" ]; then
        echo "Give the port too, e.g. http://proxy.example.com:8080."
        return 1
      fi
      ;;
    INTERNET_NO_PROXY)
      if ! [[ "$value" =~ ^[A-Za-z0-9.:/_-]+(,[A-Za-z0-9.:/_-]+)*$ ]]; then
        echo "Give names, addresses or ranges separated by commas, no spaces and no *, e.g. corp.example.com,192.0.2.0/24."
        return 1
      fi
      ;;
    INTERNET_PROXY_CA_FILE)
      if [[ "$value" != /* ]] || [ ! -r "$value" ] || ! grep -q -- '-----BEGIN CERTIFICATE-----' "$value" 2>/dev/null; then
        echo "Give the absolute path of a readable certificate file in PEM (option 26 asks for it and keeps a copy)."
        return 1
      fi
      ;;
    INTERNET_PROXY_PAC)
      if ! [[ "$value" =~ ^https?://[^[:space:]]+$ ]] && [[ "$value" != /* ]]; then
        echo "Give the http:// or https:// address of the PAC file, or its absolute path."
        return 1
      fi
      ;;
    CATALOG_CLOUD_URL|INSTALLER_URL)
      if ! [[ "$value" =~ ^https://[^[:space:]]+$ ]]; then
        echo "Give an https:// address."
        return 1
      fi
      ;;
    *URL)
      if ! [[ "$value" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "Give an http:// or https:// address."
        return 1
      fi
      ;;
    *_PATH)
      if [[ "$value" != /* ]] || [[ "$value" =~ [[:space:]] ]]; then
        echo "Give an absolute path without spaces, e.g. /app/license."
        return 1
      fi
      ;;
    CATALOG_VERSION|*_TAG|*_REPO)
      if [[ "$value" =~ [[:space:]] ]]; then
        echo "$name must not contain spaces."
        return 1
      fi
      ;;
  esac
}

# Fills SET_* with the settings of this script; fails when the settings section cannot be read.
settings_load() {
  local line rest group
  SET_GROUP=()
  SET_TITLE=()
  SET_NAME=()
  SET_SAVED=()
  SET_NEW=()
  SET_MOD=()
  while IFS= read -r line; do
    group="${line%%|*}"
    rest="${line#*|}"
    if [ "${#SET_GROUP[@]}" -eq 0 ] || [ "$group" != "${SET_GROUP[${#SET_GROUP[@]} - 1]}" ]; then
      SET_CELL="$(settings_group_title "$group")"
    fi
    SET_GROUP+=("$group")
    SET_TITLE+=("$SET_CELL")
    SET_NAME+=("${rest%%|*}")
    SET_SAVED+=("${rest#*|}")
    SET_NEW+=("${rest#*|}")
    SET_MOD+=("")
  done < <(settings_grouped "$SCRIPT_PATH")
  [ "${#SET_NAME[@]}" -gt 0 ]
}

# SET_NCHANGED: how many settings are changed on the screen and not saved yet; SET_CHANGED: their names
settings_changed() {
  local i
  SET_NCHANGED=0
  SET_CHANGED=""
  for ((i = 0; i < ${#SET_NAME[@]}; i++)); do
    if [ "${SET_MOD[i]}" = "1" ]; then
      SET_NCHANGED=$((SET_NCHANGED + 1))
      SET_CHANGED="${SET_CHANGED:+$SET_CHANGED, }${SET_NAME[i]}"
    fi
  done
}

# Index of the setting called NAME (any case); fails when there is none.
settings_find() {
  local i want
  want="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  for ((i = 0; i < ${#SET_NAME[@]}; i++)); do
    if [ "${SET_NAME[i]}" = "$want" ]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

# Label of setting INDEX in its group (into SET_CELL): the name without the part the group shares
settings_label() {
  case "${SET_GROUP[$1]}" in
    -) SET_CELL="${SET_NAME[$1]}" ;;
    _*) SET_CELL="${SET_NAME[$1]%"${SET_GROUP[$1]}"}" ;;
    *) SET_CELL="${SET_NAME[$1]#"${SET_GROUP[$1]}"}" ;;
  esac
  if [ -z "$SET_CELL" ]; then
    SET_CELL="${SET_NAME[$1]}"
  fi
}

# settings_cell SPEC WIDTH NUMW -> SET_CELL: a group heading ("H|INDEX"), a setting
# ("I|INDEX|NAMEW": the values of a group line up after NAMEW characters) or a blank ("")
# of exactly WIDTH visible characters. A value that would be cut first gives up the alignment,
# then takes room from a long name; only then is it cut.
settings_cell() {
  local spec="$1" width="$2" numw="$3" i namew title pattern len label value lab val dotsn room cut num mark valc dots pad empty=""
  if [ -z "$spec" ]; then
    printf -v SET_CELL '%*s' "$width" ''
    return 0
  fi
  i="${spec#*|}"
  namew="${i#*|}"
  i="${i%%|*}"
  if [ "${spec%%|*}" = "H" ]; then
    title="${SET_TITLE[i]}"
    pattern="$(settings_group_pattern "${SET_GROUP[i]}")"
    len=$((${#title} + ${pattern:+2 + }${#pattern}))
    if [ "$len" -gt "$width" ]; then
      pattern=""
      title="${title:0:$width}"
      len="${#title}"
    fi
    printf -v pad '%*s' $((width - len)) ''
    SET_CELL="$C_CYN$title$C_RST${pattern:+  $C_DIM$pattern$C_RST}$pad"
    return 0
  fi
  settings_label "$i"
  label="$SET_CELL"
  value="${SET_NEW[i]}"
  if [ -z "$value" ]; then
    value="(empty)"
    empty="$C_DIM"
  fi
  lab="${#label}"
  val="${#value}"
  dotsn=$((namew - lab + 1))
  if [ "$dotsn" -lt 1 ]; then
    dotsn=1
  fi
  room=$((width - numw - lab - dotsn - 4))
  if [ "$val" -gt "$room" ]; then
    dotsn=1
    room=$((width - numw - lab - 5))
  fi
  # a short value (version, time zone, port, true/false) is worth a shorter name; a long one is cut anyway
  cut=0
  if [ "$val" -gt "$room" ] && [ "$val" -le 16 ]; then
    cut=$((val - room))
  elif [ "$val" -gt "$room" ] && [ "$room" -lt 6 ]; then
    cut=$((6 - room))
  fi
  if [ "$cut" -gt $((lab - 6)) ]; then
    cut=$((lab - 6))
  fi
  if [ "$cut" -gt 0 ]; then
    label="${label:0:$((lab - cut - 1))}~"
    lab=$((lab - cut))
    room=$((room + cut))
  fi
  if [ "$room" -lt 1 ]; then
    room=1
  fi
  if [ "$val" -gt "$room" ]; then
    value="${value:0:$((room - 1))}~"
    val="$room"
  fi
  mark=" "
  num="$C_BLD"
  valc="$empty"
  if [ "${SET_MOD[i]}" = "1" ]; then
    mark="$C_YLW$SET_MARK$C_RST"
    num="$C_YLW"
    valc="$C_YLW"
  fi
  printf -v num "%s%${numw}s%s" "$num" "$((i + 1))" "$C_RST"
  printf -v dots '%*s' "$dotsn" ''
  dots="${dots// /$SET_LEADER}"
  printf -v pad '%*s' $((room - val)) ''
  SET_CELL="$mark$num $label $C_DIM$dots$C_RST $valc$value$C_RST$pad"
}

# The editor in short ("vim" for "/usr/bin/vim -p"), for key hints
editor_short() {
  local e
  e="$(editor_name)"
  e="${e%% *}"
  printf '%s' "${e##*/}"
}

# CHECK_FOR_UPDATES and the image repositories of FILE: when they change, the menu checks Docker Hub again
settings_hub_keys() {
  settings_pairs "$1" | awk -F'|' '$1 == "CHECK_FOR_UPDATES" || $1 == "CATALOG_IMAGE_REPO" || $1 == "CATALOG_WORKER_IMAGE_REPO"'
}

# settings_say TEXT -> TEXT wrapped to the screen width, indented by four spaces
settings_say() {
  printf '%s\n' "$1" | fold -s -w $(($(settings_width) - 6)) | sed 's/^/    /'
}

# Width of the settings screens: the terminal, 60 to 160 columns
settings_width() {
  local c
  c="$(ui_cols)"
  if [ "$c" -gt 160 ]; then
    c=160
  fi
  if [ "$c" -lt 60 ]; then
    c=60
  fi
  printf '%s' "$c"
}

# The settings screen: the groups side by side, every setting with its number and value; values
# that are not saved yet are marked.
settings_draw() {
  local width ncol colw cellw numw total="${#SET_NAME[@]}" i b c h r target used shown=0 groups=0 prev=""
  local block="" bhgt=0 nb=0 maxh=0 line namew limit spec header specs filter=""
  local -a bitems=() bh=() bcol=() c1=() c2=() c3=() filterl=()
  width="$(settings_width)"
  if [ "$width" -ge 100 ]; then
    ncol=3
  elif [ "$width" -ge 70 ]; then
    ncol=2
  else
    ncol=1
  fi
  colw=$(((width - 2) / ncol))
  cellw=$((colw - 2))
  numw="${#total}"
  # names up to this length line up their values; longer ones push theirs to the right
  limit=$((cellw * 45 / 100))
  # the patterns on the screen (MINIO_*, *_TAG) work as filters too
  filter="${SET_FILTER//\*/}"
  filter="${filter,,}"

  # one block per group with visible settings: the indexes of its settings
  for ((i = 0; i < total; i++)); do
    if [ "$i" -eq 0 ] || [ "${SET_GROUP[i]}" != "${SET_GROUP[i - 1]}" ]; then
      groups=$((groups + 1))
    fi
    if [ -n "$filter" ] && [[ "${SET_NAME[i],,}" != *"$filter"* ]] && [[ "${SET_NEW[i],,}" != *"$filter"* ]] && [[ "${SET_TITLE[i],,}" != *"$filter"* ]]; then
      continue
    fi
    shown=$((shown + 1))
    if [ -n "$block" ] && [ "${SET_GROUP[i]}" != "$prev" ]; then
      bitems+=("$block")
      bh+=("$bhgt")
      block=""
    fi
    if [ -z "$block" ]; then
      bhgt=1
      prev="${SET_GROUP[i]}"
    fi
    block="${block:+$block }$i"
    bhgt=$((bhgt + 1))
  done
  if [ -n "$block" ]; then
    bitems+=("$block")
    bh+=("$bhgt")
  fi
  nb="${#bh[@]}"

  # the smallest column height that holds all blocks in order, none of them split
  h=0
  for ((b = 0; b < nb; b++)); do
    h=$((h + bh[b] + (b > 0 ? 1 : 0)))
  done
  target=$(((h + ncol - 1) / ncol))
  while true; do
    c=1
    used=0
    for ((b = 0; b < nb; b++)); do
      if [ "$used" -gt 0 ] && [ $((used + 1 + bh[b])) -gt "$target" ]; then
        c=$((c + 1))
        used=0
      fi
      bcol[b]="$c"
      used=$((used + (used > 0 ? 1 : 0) + bh[b]))
    done
    if [ "$c" -le "$ncol" ]; then
      break
    fi
    target=$((target + 1))
  done

  for ((b = 0; b < nb; b++)); do
    namew=0
    for i in ${bitems[b]}; do
      settings_label "$i"
      if [ "${#SET_CELL}" -le "$limit" ] && [ "${#SET_CELL}" -gt "$namew" ]; then
        namew="${#SET_CELL}"
      fi
    done
    specs=""
    if [ "$b" -gt 0 ] && [ "${bcol[b]}" = "${bcol[b - 1]}" ]; then
      specs="-"
    fi
    i="${bitems[b]%% *}"
    specs="${specs:+$specs }H|$i"
    for i in ${bitems[b]}; do
      specs="$specs I|$i|$namew"
    done
    for spec in $specs; do
      if [ "$spec" = "-" ]; then
        spec=""
      fi
      case "${bcol[b]}" in
        1) c1+=("$spec") ;;
        2) c2+=("$spec") ;;
        *) c3+=("$spec") ;;
      esac
    done
  done
  maxh="${#c1[@]}"
  if [ "${#c2[@]}" -gt "$maxh" ]; then
    maxh="${#c2[@]}"
  fi
  if [ "${#c3[@]}" -gt "$maxh" ]; then
    maxh="${#c3[@]}"
  fi

  settings_changed
  if [ "$SET_NCHANGED" -gt 0 ]; then
    header="$C_YLW$SET_MARK $SET_NCHANGED not saved$C_RST ${C_DIM}(S saves, U undoes):$C_RST $SET_CHANGED"
  else
    header="${C_DIM}Changes are checked before they are written; the previous file is kept as a backup.$C_RST"
  fi
  if [ -n "$SET_FILTER" ]; then
    filterl=("Filter \"$SET_FILTER\": $shown of $total settings   ${C_DIM}/ shows all again$C_RST")
  fi
  clear_screen
  ui_box "$width" "RAYNET ONE TECHNOLOGY CATALOG $UI_SEP Settings" \
    "$total settings in $groups groups $UI_SEP from the settings section of $SCRIPT_NAME" \
    "$header" ${filterl[@]+"${filterl[@]}"}
  echo
  if [ "$shown" -eq 0 ]; then
    echo "  ${C_DIM}No setting matches \"$SET_FILTER\".$C_RST"
  fi
  for ((r = 0; r < maxh; r++)); do
    line=""
    for ((c = 1; c <= ncol; c++)); do
      case "$c" in
        1) spec="${c1[r]:-}" ;;
        2) spec="${c2[r]:-}" ;;
        *) spec="${c3[r]:-}" ;;
      esac
      settings_cell "$spec" "$cellw" "$numw"
      line="$line $SET_CELL "
    done
    printf '%s\n' "${line%"${line##*[! ]}"}"
  done
  echo
  # taller than the terminal: the box has scrolled away, so its state is repeated here
  if [ $((maxh + ${#filterl[@]} + 10)) -gt "$(ui_rows)" ]; then
    if [ "$SET_NCHANGED" -gt 0 ]; then
      settings_note "$header"
    fi
    if [ -n "$SET_FILTER" ]; then
      settings_note "${filterl[0]}"
    fi
  fi
  if [ -n "$SET_NOTE" ]; then
    while IFS= read -r line; do
      printf '  %s\n' "$(ui_pad "$line" $((width - 2)))"
    done <<< "$SET_NOTE"
    SET_NOTE=""
  fi
  line="$(ui_keys "number|edit" "/text|filter" "S|save" "U|undo" "E|$(editor_short)" "0|back")"
  if [ "$(ui_len "$line")" -gt "$width" ]; then
    line="$(ui_keys "nr|edit" "/|filter" "S|save" "U|undo" "E|$(editor_short)" "0|back")"
  fi
  printf '%s\n' "$(ui_pad "$line" "$width")"
}

# Adds a line to the note under the settings grid.
settings_note() {
  SET_NOTE="${SET_NOTE:+$SET_NOTE$'\n'}$1"
}

# The job times run in TZ: offers to move them with a new TZ, so they keep their moment.
settings_tz_jobs() {
  local from="$1" to="$2" i value newval k=0 question="" failed="" said="false"
  local -a idx=() vals=()
  for ((i = 0; i < ${#SET_NAME[@]}; i++)); do
    value="${SET_NEW[i]}"
    if [[ "${SET_NAME[i]}" != *_CRON ]] || [ "$value" = "-" ]; then
      continue
    fi
    if newval="$(cron_convert "$value" "$from" "$to")"; then
      settings_say "The $(cron_label "${SET_NAME[i]}") (${SET_NAME[i]} \"$value\") runs at $(cron_time_text "$value") $from, that is $(cron_time_text "$newval") $to."
      settings_say "$(tz_season_note "$from" "$to" "$newval" | sed 's/^ *//')" | sed '/^ *$/d'
      said="true"
      if [ "$newval" != "$value" ]; then
        idx+=("$i")
        vals+=("$newval")
        k=$((k + 1))
        question="${question:+$question and }${SET_NAME[i]} to \"$newval\""
      fi
    else
      failed="${failed:+$failed, }${SET_NAME[i]}"
    fi
  done
  if [ -n "$failed" ]; then
    settings_note "$C_YLW$UI_NO$C_RST $failed could not be moved to $to automatically - check the time."
  fi
  if [ "$k" -eq 0 ]; then
    if [ "$said" = "true" ]; then
      ui_pause_tty
    fi
    return 0
  fi
  if confirm "  Keep the job times: change $question?" y; then
    for ((i = 0; i < k; i++)); do
      SET_NEW[idx[i]]="${vals[i]}"
      if [ "${vals[i]}" = "${SET_SAVED[idx[i]]}" ]; then
        SET_MOD[idx[i]]=""
      else
        SET_MOD[idx[i]]="1"
      fi
    done
  else
    settings_note "${C_DIM}The job times stay as they are and now run in $to time.$C_RST"
  fi
}

HOST_NOW=""
HOST_LICENSE=""

# For the edit screen of CATALOG_HOSTNAME: HOST_NOW, the host name of the catalog-web container (empty:
# none), and HOST_LICENSE, the license of the Catalog (valid, invalid, or unreachable/error: it does not
# answer). Asks Catalog Web, so only there, not when the menu or the settings are drawn.
settings_host_state() {
  HOST_NOW="$(web_container_hostname)"
  HOST_LICENSE="invalid"
  if [ -n "$HOST_NOW" ]; then
    license_status --max-time 15
    HOST_LICENSE="$LICENSE_STATE"
  fi
}

# settings_host_effective VALUE -> the host name catalog-web gets with CATALOG_HOSTNAME=VALUE (as
# do_generate decides it): VALUE, the one of the env file (or of its newest backup), the one a licensed
# catalog-web keeps, else the name of this server. Needs settings_host_state.
settings_host_effective() {
  local from="$ENV_FILE"
  if [ -n "$1" ]; then
    printf '%s' "$1"
    return 0
  fi
  if [ ! -f "$from" ]; then
    from="$(newest_env_backup)"
  fi
  if [ -n "$from" ] && [ -f "$from" ] && [ -n "$(env_hostname "$from")" ]; then
    CATALOG_HOSTNAME="" catalog_hostname "$from"
  elif [ "$HOST_LICENSE" != "invalid" ] && hostname_valid "$HOST_NOW"; then
    printf '%s' "$HOST_NOW"
  else
    server_hostname
  fi
}

# settings_edit INDEX -> asks for a new value of one setting; it stays on the screen until saved
settings_edit() {
  local i="$1" name group saved cur value problem title pattern hint env bool="false" k jobs="" pre prompt eff why
  local -a lines=()
  name="${SET_NAME[i]}"
  group="${SET_GROUP[i]}"
  saved="${SET_SAVED[i]}"
  cur="${SET_NEW[i]}"
  title="${SET_TITLE[i]}"
  pattern="$(settings_group_pattern "$group")"
  if [ "$saved" = "true" ] || [ "$saved" = "false" ]; then
    bool="true"
  fi
  lines+=("Group      $title${pattern:+  $C_DIM$pattern$C_RST}")
  lines+=("Saved      ${saved:-$C_DIM(empty)$C_RST}")
  if [ "${SET_MOD[i]}" = "1" ]; then
    lines+=("On screen  $C_YLW${cur:-(empty)}$C_RST  ${C_DIM}not saved yet$C_RST")
  fi
  if [ "$name" = "CATALOG_HOSTNAME" ]; then
    settings_host_state
  fi
  if [ -f "$ENV_FILE" ] && grep -q "^$name=" "$ENV_FILE"; then
    env="$(env_value "$name")"
    # an empty CATALOG_HOSTNAME keeps the one of the env file
    if [ "$env" = "$saved" ] || { [ "$name" = "CATALOG_HOSTNAME" ] && [ "$(env_unquote "$env")" = "$(settings_host_effective "$saved")" ]; }; then
      lines+=("In $ENV_FILE    ${env:-$C_DIM(empty)$C_RST}")
    else
      lines+=("In $ENV_FILE    $C_YLW${env:-(empty)}$C_RST  ${C_DIM}option 2 regenerates it from the settings$C_RST")
    fi
  fi
  if [ "$name" = "CATALOG_HOSTNAME" ]; then
    eff="$(settings_host_effective "$cur")"
    if [ -z "$HOST_NOW" ]; then
      why="no catalog-web container yet"
    elif [ "$HOST_NOW" != "$eff" ]; then
      why="catalog-web has $HOST_NOW until options 2 and 6"
    elif [ "$HOST_LICENSE" = "valid" ]; then
      why="catalog-web has it; the license is bound to it"
    else
      why="catalog-web has it"
    fi
    lines+=("Effective  $eff  $C_DIM($why)$C_RST")
  fi
  hint="$(settings_hint "$name" "$saved")"
  if [ -n "$hint" ]; then
    lines+=("$C_DIM$hint$C_RST")
  fi
  clear_screen
  ui_box "$(settings_width)" "Setting $UI_SEP $name" "${lines[@]}"
  echo
  if [ -t 0 ]; then
    echo "  ${C_DIM}Change the value and press Enter$(if settings_empty_ok "$name" "$saved"; then printf ' ("" empties it)'; fi). Enter alone keeps it.$C_RST"
  elif [ "$bool" = "true" ]; then
    echo "  ${C_DIM}true or false; Enter keeps ${cur:-it}.$C_RST"
  else
    echo "  ${C_DIM}Enter keeps the value$(if settings_empty_ok "$name" "$saved"; then printf ', "" empties it'; fi).$C_RST"
  fi
  # readline must not count the color codes of the prompt: they go between \001 and \002
  prompt="  "$'\001'"$C_CYN"$'\002'"$UI_ARROW"$'\001'"$C_RST"$'\002'" $name: "
  pre="$cur"
  while true; do
    # On a terminal the value is ready to be changed (after a refused one: the text just typed).
    # The read runs in a subshell with the default Ctrl-C, so Ctrl-C cancels instead of keeping the line.
    if [ -t 0 ]; then
      if ! value="$(trap - INT; read -e -r -i "$pre" -p "$prompt" v && printf '%s' "$v")"; then
        echo
        return 0
      fi
    elif ! ui_ask value "$name:"; then
      return 0
    fi
    if [ -z "$value" ] || [ "$value" = "$cur" ]; then
      return 0
    fi
    if [ "$value" = '""' ]; then
      value=""
    fi
    if [ "$bool" = "true" ]; then
      case "${value,,}" in
        true|t|yes|y|on|1) value="true" ;;
        false|f|no|n|off|0) value="false" ;;
      esac
    fi
    if problem="$(settings_check "$name" "$value" "$saved")"; then
      break
    fi
    err "$problem"
    pre="$value"
  done
  if [ "$value" = "$cur" ]; then
    return 0
  fi
  SET_NEW[i]="$value"
  if [ "$value" = "$saved" ]; then
    SET_MOD[i]=""
    settings_note "$C_GRN$UI_OK$C_RST $name is back at its saved value."
  else
    SET_MOD[i]="1"
    settings_note "$C_YLW$SET_MARK$C_RST $name ${C_DIM}$UI_RARR$C_RST ${value:-(empty)}   ${C_DIM}not saved yet - S saves$C_RST"
  fi
  # a licensed Catalog (or one that does not answer: it may hold a license) loses it with another name
  if [ "$name" = "CATALOG_HOSTNAME" ] && [ -n "$HOST_NOW" ] && [ "$HOST_LICENSE" != "invalid" ]; then
    eff="$(settings_host_effective "$value")"
    if [ "$eff" != "$HOST_NOW" ] && [ "$HOST_LICENSE" = "valid" ]; then
      settings_note "$C_YLW$UI_NO$C_RST The Catalog's license is bound to the host name $HOST_NOW."
      settings_note "  With $eff it must be activated again: option 25, after 2 and 6."
    elif [ "$eff" != "$HOST_NOW" ]; then
      settings_note "$C_YLW$UI_NO$C_RST If the Catalog holds a license, it is bound to the host name $HOST_NOW."
      settings_note "  With $eff it must be activated again: option 25, after 2 and 6."
    fi
  fi
  if [ "$name" = "TZ" ]; then
    if tz_known "${cur:-UTC}" && tz_known "${value:-UTC}"; then
      if ! tz_same "${cur:-UTC}" "${value:-UTC}"; then
        echo
        settings_tz_jobs "${cur:-UTC}" "${value:-UTC}"
      fi
    else
      for ((k = 0; k < ${#SET_NAME[@]}; k++)); do
        if [[ "${SET_NAME[k]}" == *_CRON ]] && [ "${SET_NEW[k]}" != "-" ]; then
          jobs="${jobs:+$jobs, }${SET_NAME[k]}"
        fi
      done
      if [ -n "$jobs" ]; then
        settings_note "$C_YLW$UI_NO$C_RST $jobs not moved: this server has no time zone data to convert them - check the times."
      fi
    fi
  fi
}

# Checks the changed settings together, writes them into this script (after a backup) and
# restarts the menu with them. Fails, with the reason, when they cannot be used.
settings_save() {
  local i n dir copy orig out="" backup="" ids id tries=0 names hub="keep"
  settings_changed
  n="$SET_NCHANGED"
  if [ "$n" -eq 0 ]; then
    settings_note "${C_DIM}Nothing to save.$C_RST"
    return 0
  fi
  ids="$(job_running_ids)"
  if [ -n "$ids" ]; then
    echo
    while IFS= read -r id; do
      warn "Job #$id ($(cat -- "$JOBS_DIR/$id/title" 2>/dev/null)) is running."
    done <<< "$ids"
    if ! confirm "  Save the settings while it runs? It may still use the old values." n; then
      settings_note "${C_DIM}Not saved yet.$C_RST"
      return 0
    fi
  fi
  if ! dir="$(mktemp -d)" || [ ! -d "$dir" ]; then
    err "Cannot create a temporary folder for the check (TMPDIR) - nothing was changed."
    return 1
  fi
  copy="$dir/$SCRIPT_NAME"
  orig="$dir/orig"
  while true; do
    # the changes go into a copy of the current file, so a setting a job wrote meanwhile stays
    if ! cp -p -- "$SCRIPT_PATH" "$orig" || ! cp -p -- "$orig" "$copy"; then
      rm -rf -- "$dir"
      err "Cannot copy $SCRIPT_NAME for the check - nothing was changed."
      return 1
    fi
    for ((i = 0; i < ${#SET_NAME[@]}; i++)); do
      if [ "${SET_MOD[i]}" = "1" ] && ! set_setting "${SET_NAME[i]}" "${SET_NEW[i]}" "$copy"; then
        rm -rf -- "$dir"
        return 1
      fi
    done
    if ! "$BASH" -n "$copy" 2>/dev/null || ! out="$("$BASH" "$copy" check-settings 2>&1)"; then
      rm -rf -- "$dir"
      echo
      err "Not saved - the settings do not work together:"
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed 's/^/    /'
      fi
      return 1
    fi
    if ! backup="$(script_backup)"; then
      rm -rf -- "$dir"
      err "Cannot write a backup next to $SCRIPT_PATH - nothing was changed."
      return 1
    fi
    if [ "$(cksum < "$orig")" = "$(cksum < "$SCRIPT_PATH")" ]; then
      break
    fi
    rm -f -- "$backup"
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      rm -rf -- "$dir"
      err "$SCRIPT_NAME keeps changing (a running job?) - nothing was changed, try again later."
      return 1
    fi
  done
  # Write the content back instead of moving the file, so owner and mode stay.
  if ! cat -- "$copy" > "$SCRIPT_PATH"; then
    cat -- "$backup" > "$SCRIPT_PATH" 2>/dev/null || true
    rm -rf -- "$dir"
    err "Cannot write $SCRIPT_PATH - it was restored from $backup."
    return 1
  fi
  rm -rf -- "$dir"
  names="$SET_CHANGED"
  if [ "$n" -gt 3 ]; then
    names="$(printf '%s' "$SET_CHANGED" | cut -d, -f1-3), +$((n - 3)) more"
  fi
  for ((i = 0; i < ${#SET_NAME[@]}; i++)); do
    if [ "${SET_MOD[i]}" = "1" ]; then
      case "${SET_NAME[i]}" in
        CHECK_FOR_UPDATES|CATALOG_IMAGE_REPO|CATALOG_WORKER_IMAGE_REPO) hub="fresh" ;;
      esac
    fi
  done
  export RVC_NOTICE="$n setting(s) saved ($names; backup $(basename -- "$backup")). Option 2 regenerates the files, then 6 applies them."
  if [ "$hub" = "keep" ]; then
    export RVC_HUB_STATUS="$HUB_STATUS" RVC_LATEST_VERSION="$LATEST_VERSION" RVC_HUB_STABLE="$HUB_STABLE"
  else
    unset RVC_HUB_STATUS RVC_LATEST_VERSION RVC_HUB_STABLE
  fi
  exec "$BASH" "$SCRIPT_PATH" menu
}

# Menu option 1: all settings of this script on one screen, grouped by the part of their names
# they share. Edits stay on the screen until S saves them; E opens the file in the text editor.
settings_editor() {
  local choice n i
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "Cannot change the settings (${SCRIPT_PATH:-the script} is not a writable file)."
    ui_pause_tty
    return 0
  fi
  if ! settings_load; then
    err "The settings section of $SCRIPT_NAME cannot be read - opening the file in the editor."
    edit_config
    ui_pause_tty
    return 0
  fi
  SET_FILTER=""
  SET_NOTE=""
  while true; do
    settings_draw
    if ! ui_ask choice "Select (number or name):"; then
      choice="0"
      echo
    fi
    if [[ "$choice" == *[[:cntrl:]]* ]]; then
      settings_note "$C_YLW$UI_NO$C_RST Type a number, a name or /text."
      continue
    fi
    case "$choice" in
      0|q|Q)
        settings_changed
        n="$SET_NCHANGED"
        if [ "$n" -eq 0 ]; then
          return 0
        fi
        if confirm "  Save the $n changed setting(s) ($SET_CHANGED)?" y; then
          settings_save || ui_pause_tty
        else
          # shown by the menu after it is drawn again
          TUI_NOTICE="Settings not saved - $SCRIPT_NAME is unchanged."
          return 0
        fi
        ;;
      s|S) settings_save || ui_pause_tty ;;
      u|U)
        settings_changed
        n="$SET_NCHANGED"
        for ((i = 0; i < ${#SET_NAME[@]}; i++)); do
          SET_NEW[i]="${SET_SAVED[i]}"
          SET_MOD[i]=""
        done
        settings_note "${C_DIM}$n change(s) undone.$C_RST"
        ;;
      e|E)
        settings_changed
        n="$SET_NCHANGED"
        if [ "$n" -gt 0 ] && ! confirm "  Open the file in $(editor_name)? The $n change(s) on this screen are lost." n; then
          continue
        fi
        edit_config
        ui_pause_tty
        if ! settings_load; then
          err "The settings section of $SCRIPT_NAME cannot be read."
          ui_pause_tty
          return 0
        fi
        ;;
      /*) SET_FILTER="${choice#/}" ;;
      "") ;;
      *)
        if [[ "$choice" =~ ^[0-9]{1,4}$ ]]; then
          if [ "$((10#$choice))" -ge 1 ] && [ "$((10#$choice))" -le "${#SET_NAME[@]}" ]; then
            settings_edit $((10#$choice - 1))
          else
            settings_note "$C_YLW$UI_NO$C_RST There is no setting $choice."
          fi
        elif i="$(settings_find "$choice")"; then
          settings_edit "$i"
        else
          SET_FILTER="$choice"
        fi
        ;;
    esac
  done
}

# True when the CONTAINER_ENGINE of this script, edited by hand, can be used in this folder
editor_engine_ok() {
  local new problem
  new="$(script_setting CONTAINER_ENGINE)"
  if [ "$new" = "$CONTAINER_ENGINE" ]; then
    return 0
  fi
  problem="$(engine_switch_problem "$new")"
  if [ -n "$problem" ]; then
    err "CONTAINER_ENGINE \"$new\": $problem"
    return 1
  fi
}

# Opens the configuration section of this script in the editor, then restarts
# the script so the new values are used. Runs in the main shell (not in a
# subshell) because it replaces the running process.
edit_config() {
  local line="" before saved editor hub
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
  if [ -n "$(job_running_ids)" ]; then
    warn "Jobs are running (J): one may still change a setting, which saving in the editor would overwrite."
    if ! confirm "Open the editor anyway?" n; then
      return 0
    fi
  fi
  line="$(grep -n -m 1 '^# CONFIGURE ONLY THIS SECTION' "$SCRIPT_PATH" | cut -d: -f1)" || line=""
  before="$(cksum < "$SCRIPT_PATH")"
  hub="$(settings_hub_keys "$SCRIPT_PATH")"
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
    # A new CONTAINER_ENGINE must not leave this installation's data in the other engine.
    if "$BASH" -n "$SCRIPT_PATH" && "$BASH" "$SCRIPT_PATH" check-settings && editor_engine_ok; then
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
  # the editor changed the file: whatever it holds now was chosen, also when it equals the published settings
  settings_unpublish
  export RVC_NOTICE="Configuration reloaded. Use option 2 to regenerate the files, then 6 to apply."
  if [ "$(settings_hub_keys "$SCRIPT_PATH")" = "$hub" ]; then
    export RVC_HUB_STATUS="$HUB_STATUS" RVC_LATEST_VERSION="$LATEST_VERSION" RVC_HUB_STABLE="$HUB_STABLE"
  else
    unset RVC_HUB_STATUS RVC_LATEST_VERSION RVC_HUB_STABLE
  fi
  exec "$BASH" "$SCRIPT_PATH" menu
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
  local running n=0
  if [ ! -f "$ENV_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; then
    if engine_cli; then
      n="$(count_lines "$(here_containers 2>/dev/null)")"
    fi
    case "$n" in
      0) printf 'not generated yet' ;;
      1) printf '1 container exists' ;;
      *) printf '%s containers exist' "$n" ;;
    esac
    return 0
  fi
  if ! engine_cli || ! detect_compose; then
    printf '%s / Compose not available' "$ENGINE_NAME"
    return 0
  fi
  if ! running="$(compose ps --services --filter status=running 2>/dev/null)"; then
    printf 'unknown (cannot reach %s)' "$ENGINE_NAME"
    return 0
  fi
  printf '%s service(s) running' "$(count_lines "$running")"
}

# show_menu [LINES] -> the plain menu; LINES: what the caller prints below it (notices, prompt)
show_menu() {
  local found tz_note sib state here inote rnote="" dnote below="${1:-0}" cols height item nh head version line
  local -a notes=() items=() heads=()
  reload_settings
  menu_scan
  state="$MENU_STACK"
  here="$(install_kind "$state")"
  if [ ! -f "$ENV_FILE" ]; then
    found="$(first_installation_dir)"
    if [ -n "$found" ]; then
      notes+=("${C_YLW}A Catalog installation already exists in $found - option 23 takes it over (settings, passwords, data).${C_RST}")
    fi
  fi
  inote="$(install_note)"
  if [ -n "$inote" ]; then
    notes+=("${C_YLW}$inote - option 23 takes the installation's values over.${C_RST}")
  else
    rnote="$(raise_note)"
    if [ -n "$rnote" ]; then
      notes+=("${C_YLW}$rnote.${C_RST}")
    fi
  fi
  sib="$(conflicting_sibling)"
  if [ -n "$sib" ]; then
    notes+=("${C_YLW}$(basename -- "$sib") in this folder has other settings - option 23 takes them over (or rename it if it is no longer used).${C_RST}")
  elif [ -n "$inote$rnote" ]; then
    :
  elif mongo_kernel_problem; then
    notes+=("${C_YLW}MongoDB needs the kernel workaround (SERVER-121912), and the files lack it - option 2 (or I - repair) writes them again.${C_RST}")
  elif mongo_workaround_unneeded; then
    notes+=("${C_YLW}This kernel no longer needs the MongoDB workaround in the files - option 2 writes them again (faster MongoDB).${C_RST}")
  elif settings_stale; then
    dnote="$(install_diff_note)"
    if [ -n "$dnote" ]; then
      notes+=("${C_YLW}$dnote - option 23 takes the installation's values over, option 2 writes the settings.${C_RST}")
    elif files_older; then
      notes+=("${C_YLW}The generated files do not match the settings above (written by an older installer) - option 2 regenerates them.${C_RST}")
    else
      notes+=("${C_YLW}The generated files do not match the settings above (changed settings or manual edits) - option 2 regenerates them.${C_RST}")
    fi
  fi
  if [ -z "$inote" ] && tz_note="$(tz_menu_note)" && [ -n "$tz_note" ]; then
    notes+=("${C_YLW}$tz_note${C_RST}")
  fi
  # the internet check of the menu start, once it is done (a header line)
  nh="$(net_header)"
  mapfile -t items < <(menu_items)
  cols="$(ui_cols)"
  # the title with the state of the Catalog beside it; wider than the terminal, that state gets a line of its
  # own, like Folder and Stack
  version="$(version_label "$here")"
  head="${C_BLD}Raynet One Technology Catalog - Installation Portal${C_RST}   ($version)"
  if [ -t 1 ] && [ "$(ui_len "$head")" -gt "$cols" ]; then
    heads=("${head%%   (*}" "Catalog: ${version#Catalog }")
  else
    heads=("$head")
  fi
  heads+=("Folder : $WORK_DIR" "Files  : $ENV_FILE $(file_state "$ENV_FILE")   $COMPOSE_FILE $(file_state "$COMPOSE_FILE")" "Stack  : $state")
  case "$nh" in
    "") ;;
    "Internet: "*) heads+=("$C_YLW$nh$C_RST") ;;
    *) heads+=("$C_GRN$nh$C_RST") ;;
  esac
  # the logo only in a terminal that has room for it above the whole menu: header (with the internet
  # line) and notes as the terminal wraps them, the cards, every heading (two lines) and option, Exit and
  # the legend, and what the caller prints below
  if [ -t 1 ] && [ "$cols" -ge 80 ]; then
    height=$((2 + 3 + 5 + below))
    for line in "${heads[@]}" ${notes[@]+"${notes[@]}"}; do
      height=$((height + $(ui_lines "$line" "$cols")))
    done
    for item in "${items[@]}"; do
      IFS='|' read -r _ item _ <<< "$item"
      if [ "$item" = "-" ]; then
        height=$((height + 2))
      elif [ -n "$item" ]; then
        height=$((height + 1))
      fi
    done
    if [ "$(ui_rows)" -ge $((height + ${#UI_LOGO[@]} + 1)) ]; then
      ui_logo "$cols"
      echo
    fi
  fi
  printf '%s\n' "${heads[@]}"
  if [ ${#notes[@]} -gt 0 ]; then
    printf '%s\n' "${notes[@]}"
  fi
  local col key kind label desc what title color l1 l2 wide="no" text current=""
  if ! nothing_installed "$here"; then
    current="$(installed_catalog)"
  fi
  if [ "$cols" -ge 70 ]; then
    wide="yes"
  fi
  printf '\n %s\n' "${C_CYN}START HERE$C_RST"
  for key in I U R; do
    IFS='|' read -r title color l1 l2 <<< "$(wiz_card "$key" "$here" "$state" 40 "$current")"
    if [ "$here" = "incomplete" ] && [ "$key" != "R" ]; then
      l1="$l1 $UI_SEP $l2"
    fi
    printf '  %s) %s  %s\n' "$(printf '%3s' "$key")" "$color$(ui_pad "$title" 8)$C_RST" "$l1"
  done
  while IFS='|' read -r col key kind label desc what; do
    if [ "$key" = "-" ]; then
      printf '\n %s\n' "$C_CYN$label$C_RST$C_DIM $UI_SEP $desc$C_RST"
    elif [ -n "$key" ]; then
      text="$label"
      if [ "$kind" = "del" ]; then
        text="$C_RED$label$C_RST"
      fi
      if [ "$wide" = "yes" ]; then
        text="$(ui_pad "$text" 25) $C_DIM$desc$C_RST"
      fi
      printf '  %s) %s %s\n' "$(printf '%3s' "$key")" "$(menu_icon "$kind")" "$text"
    fi
  done < <(printf '%s\n' "${items[@]}")
  printf '\n    0) Exit\n\n  %s\n\n' "$(menu_legend)"
  menu_scan_done
}

menu_up() {
  local note
  downgrade_guard files || return 1
  upgrade_guard files || return 1
  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ] && settings_stale; then
    warn "$ENV_FILE / $COMPOSE_FILE do not match the settings at the top of $SCRIPT_NAME."
    note="$(install_note)"
    if [ -n "$note" ]; then
      warn "$note - option 23 takes the installation's values over."
    elif note="$(raise_note)" && [ -n "$note" ]; then
      warn "$note."
    elif note="$(install_diff_note)" && [ -n "$note" ]; then
      warn "$note - option 23 takes the installation's values over, option 2 writes the settings."
    fi
    if ! confirm "Start with the files as they are?" n; then
      info "Cancelled."
      return 0
    fi
  fi
  run_job "Start / apply changes" -- do_up
}

menu_full_setup() {
  engine_guard || return 1
  # a start that would lower the installation is refused before the memory question, one that would
  # upgrade it without a backup asks first
  downgrade_guard settings || return 1
  upgrade_guard settings || return 1
  if ! mem_ask confirm; then
    info "Cancelled."
    return 0
  fi
  do_generate ask no-next
  if [ "$GENERATE_CANCELLED" = "true" ]; then
    return 0
  fi
  echo
  run_job "Full setup: start the stack" -- do_up
}

menu_down() {
  downgrade_guard files stop || return 1
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

###############################################################################
# Guided tasks of the main menu: I install, U update, R remove
###############################################################################

if [ "$UI_UTF" = "true" ]; then
  WIZ_TODO="○"
else
  WIZ_TODO="-"
fi
# The argument that brings a restarted menu back to step 2 of the update (see update_installer)
WIZ_RESUME=""

# wiz_head TASK STEP STEP-NAME... -> clears the screen and shows the task with all its steps:
# the steps done are ticked, the current one is marked. A narrow terminal shows only the current step.
wiz_head() {
  local task="$1" step="$2" i=0 s line="" width
  shift 2
  local -a names=("$@")
  for s in "$@"; do
    i=$((i + 1))
    if [ "$i" -lt "$step" ]; then
      line="$line$C_GRN$UI_OK $s$C_RST   "
    elif [ "$i" -eq "$step" ]; then
      line="$line$C_CYN$UI_ARROW $s$C_RST   "
    else
      line="$line$C_DIM$WIZ_TODO $s$C_RST   "
    fi
  done
  line="${line%   }"
  width="$(settings_width)"
  if [ "$(ui_len "$line")" -gt $((width - 4)) ]; then
    line="$C_CYN$UI_ARROW ${names[step - 1]}$C_RST"
  fi
  clear_screen
  ui_box "$width" "RAYNET ONE TECHNOLOGY CATALOG $UI_SEP $task $UI_SEP step $step of $#" "$line"
  echo
}

# Runs a step in a subshell, so the variables it changes stay there, and returns its exit code
# (3: a job was left running in the background). The menu runs under "|| true", so errexit does
# not work in here: the steps check their own results.
wiz_run() {
  local rc
  set +e
  ( "$@" )
  rc=$?
  set -e
  return "$rc"
}

# wiz_yes_no QUESTION DEFAULT(y|n) -> 0 yes, 1 no, 2 stop (0, or the end of input)
wiz_yes_no() {
  local hint answer
  if [ "$2" = "y" ]; then
    hint="[Y/n]"
  else
    hint="[y/N]"
  fi
  if ! read -r -p "$1 $hint " answer; then
    echo
    return 2
  fi
  case "${answer:-$2}" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    0) return 2 ;;
    *) return 1 ;;
  esac
}

# The guided task stops here; the menu shows how to go on.
wiz_stop() {
  info "Stopped. $1 starts it again; the steps done so far are kept."
}

# Version of the installed Catalog: catalog-web's container, else .env, else the newest .env backup
wiz_installed_version() {
  local v
  v="$(installed_catalog)"
  if [ -z "$v" ]; then
    v="$(env_value CATALOG_IMAGE)"
  fi
  if [ -z "$v" ] && [ -n "$(newest_env_backup)" ]; then
    v="$(sed -n 's/^CATALOG_IMAGE=//p' "$(newest_env_backup)" | tail -n 1)"
  fi
  printf '%s' "${v##*:}"
}

# The task notes what it set up here (wiz_mark sync); the steps run in subshells
WIZ_MARK=""
wiz_mark() {
  if [ -n "$WIZ_MARK" ]; then
    printf '%s\n' "$1" >> "$WIZ_MARK"
  fi
}

# Number of the newest job (0 when there is none)
wiz_last_job() {
  local id last=0
  for id in "$JOBS_DIR"/[0-9]*; do
    id="${id##*/}"
    if [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -gt "$last" ]; then
      last="$id"
    fi
  done
  printf '%s' "$last"
}

# wiz_job_since ID TITLE-START -> state of the newest job after ID whose title starts so (empty: none)
wiz_job_since() {
  local since="$1" id state=""
  for ((id = since + 1; id <= $(wiz_last_job); id++)); do
    if [[ "$(cat -- "$JOBS_DIR/$id/title" 2>/dev/null)" == "$2"* ]]; then
      state="$(job_state "$id")"
    fi
  done
  printf '%s' "$state"
}

# True when this folder has an installation: its generated files, or containers of this installation
# (volumes alone may belong to another folder with the same name).
# The containers of this installation, listed once per menu draw (menu_scan): the cards and the stack
# line need them, and every listing asks the engine several times. here_containers uses that list during
# the draw and asks the engine again at any other time.
# The stack line (stack_state) is part of the scan too: the draw that follows asks the engine nothing else.
MENU_HERE=""
MENU_HERE_AT=-10
MENU_CATALOG=""
MENU_DATA=""
MENU_STACK=""
MENU_CONTAINERS=""
menu_scan() {
  MENU_HERE=""
  MENU_HERE_AT=-10
  if engine_cli && { [ ! -f "$ENV_FILE" ] || [ ! -f "$COMPOSE_FILE" ]; }; then
    MENU_HERE="$(remove_containers 2>/dev/null)" || MENU_HERE=""
  fi
  MENU_CATALOG="$(running_catalog)"
  # asked only without a container of catalog-web (install_data)
  MENU_DATA="yes"
  if [ -z "$MENU_CATALOG" ] && ! install_data; then
    MENU_DATA="no"
  fi
  MENU_HERE_AT="$SECONDS"
  MENU_STACK="$(stack_state)"
  # the other containers of the stack: asked only where nothing runs and catalog-web has none (install_kind)
  MENU_CONTAINERS="yes"
  if [ -z "$MENU_CATALOG" ] && [ "$MENU_STACK" = "0 service(s) running" ] && ! stack_containers_any; then
    MENU_CONTAINERS="no"
  fi
  # the draw comes now: the cache counts from the end of the scan
  MENU_HERE_AT="$SECONDS"
}
menu_scan_done() {
  MENU_HERE_AT=-10
}
here_containers() {
  if [ $((SECONDS - MENU_HERE_AT)) -le 2 ]; then
    printf '%s' "$MENU_HERE"
  else
    remove_containers
  fi
}

# install_state -> yes (.env and docker-compose.yml are here), incomplete (containers of this folder
# or .env, but not both files) or no
install_state() {
  if [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ]; then
    printf 'yes'
  elif wiz_installed; then
    printf 'incomplete'
  else
    printf 'no'
  fi
}

wiz_installed() {
  if [ -f "$ENV_FILE" ]; then
    return 0
  fi
  engine_cli && [ -n "$(here_containers)" ]
}

# True when a container of the stack exists, running or stopped (the project's label: what compose lists)
stack_containers_any() {
  local ids
  engine_cli && ids="$("$ENGINE" ps -aq --filter "label=com.docker.compose.project=$(stack_project)" 2>/dev/null)" && [ -n "$ids" ]
}

# True when containers of the stack are there - catalog-web's or others, running or stopped; the menu asks
# once per draw (menu_scan)
stack_has_containers() {
  if [ -n "$(running_catalog)" ]; then
    return 0
  fi
  if [ $((SECONDS - MENU_HERE_AT)) -le 2 ]; then
    [ "$MENU_CONTAINERS" = "yes" ]
    return
  fi
  stack_containers_any
}

# install_kind [STACK-STATE] -> what is installed in this folder: running (services of the stack run), stopped
# (containers of the stack are there, none runs), data (no container, the data volumes are kept - option 13),
# files (only .env and docker-compose.yml, no container and no data volume - option 99, or R that kept the
# files), none, incomplete (see install_state) or unknown (the engine does not answer). The menu decides it
# once per draw from what menu_scan knows (with its stack line, STACK-STATE).
install_kind() {
  local state="${1:-}"
  case "$(install_state)" in
    no)
      printf 'none'
      return 0
      ;;
    incomplete)
      printf 'incomplete'
      return 0
      ;;
  esac
  if [ -z "$state" ]; then
    state="$(stack_state)"
  fi
  case "$state" in
    "0 service(s) running")
      if stack_has_containers; then
        printf 'stopped'
      elif install_data; then
        printf 'data'
      else
        printf 'files'
      fi
      ;;
    [0-9]*" service(s) running") printf 'running' ;;
    *) printf 'unknown' ;;
  esac
}

# nothing_installed KIND -> true when no Catalog is installed in this folder: KIND (see install_kind) files or none
nothing_installed() {
  [ "$1" = "files" ] || [ "$1" = "none" ]
}

# Names of the running jobs ("#3 Upgrade to ..."), one per line; empty when none runs.
wiz_running_jobs() {
  local id
  while IFS= read -r id; do
    if [ -n "$id" ]; then
      printf '#%s %s\n' "$id" "$(cat -- "$JOBS_DIR/$id/title" 2>/dev/null)"
    fi
  done < <(job_running_ids)
}

# wiz_wait_job TITLE SINCE -> the next step of a task needs the job it started (the newest job
# after SINCE with that title) to end: shows it again while it runs. 0 when it ended well, 1 when it
# failed or was not started, 3 when it was left again (it goes on in the background).
wiz_wait_job() {
  local title="$1" since="$2" id="" i rc
  for ((i = since + 1; i <= $(wiz_last_job); i++)); do
    if [ "$(cat -- "$JOBS_DIR/$i/title" 2>/dev/null)" = "$title" ]; then
      id="$i"
    fi
  done
  if [ -z "$id" ]; then
    return 1
  fi
  while [ "$(job_state "$id")" = "running" ]; do
    echo
    info "The next step needs job #$id to end first."
    rc=0
    job_follow "$id" || rc=$?
    if [ "$rc" -eq 3 ] && [ "$(job_state "$id")" = "running" ]; then
      return 3
    fi
  done
  [ "$(job_state "$id")" = "done" ]
}

# wiz_set NAME VALUE -> writes a setting into this script and uses it at once
wiz_set() {
  if [ "${!1-}" = "$2" ]; then
    return 0
  fi
  if ! set_setting "$1" "$2"; then
    return 1
  fi
  printf -v "$1" '%s' "$2"
  ok "$1 = \"$2\""
}

# wiz_ask NAME QUESTION [new] -> asks for a new value of a setting (Enter keeps it), checked like on the
# settings screen; a port must not be taken by another setting or, on a new installation (no data volumes
# yet, or "new": the new installation of this folder), by another program. Fails at 0 and at the end of
# input.
wiz_ask() {
  local name="$1" question="$2" new="${3:-}" value problem other ans
  while true; do
    ui_ask value "$question [${!name}]:" || return 1
    if [ "$value" = "0" ]; then
      return 1
    fi
    value="${value:-${!name}}"
    if ! problem="$(settings_check "$name" "$value" "${!name}")"; then
      err "$problem"
      continue
    fi
    if [[ "$name" == *_PORT* ]]; then
      problem=""
      for other in $(port_settings); do
        if [ "$other" != "$name" ] && [ "${!other}" = "$value" ]; then
          problem="Port $value is already set for $other."
        fi
      done
      if [ -n "$problem" ]; then
        err "$problem"
        continue
      fi
      if { [ "$new" = "new" ] || [ -z "$(project_volumes)" ]; } && wiz_port_used "$value"; then
        warn "Port $value is already in use on this server."
        ans=0
        wiz_yes_no "Use it anyway?" n || ans=$?
        case "$ans" in
          0) ;;
          1) continue ;;
          *) return 1 ;;
        esac
      fi
    fi
    wiz_set "$name" "$value"
    return 0
  done
}

# True when something listens on host port $1 (ss on Linux, lsof on macOS; false when neither is there).
wiz_port_used() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p=":$1\$" '$4 ~ p { found = 1 } END { exit !found }'
  elif [ "$OS_KIND" = "Darwin" ] && command -v nc >/dev/null 2>&1; then
    nc -z -G 1 127.0.0.1 "$1" >/dev/null 2>&1
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

# wiz_and A B C -> "A, B and C"
wiz_and() {
  local out="$1"
  shift
  while [ $# -gt 1 ]; do
    out="$out, $1"
    shift
  done
  if [ $# -eq 1 ]; then
    out="$out and $1"
  fi
  printf '%s' "$out"
}

# The marker of a first start that was put off (stopped at the first question of the new installation):
# the menu then opens without it; I still starts it
SETUP_LATER_FILE="$WORK_DIR/.setup-later"

# True when the menu starts with the new installation: nothing is installed in this folder (no .env, no
# compose file, no containers of this project in any engine), no other installation is on this server,
# no job runs, and the first start was not put off (.setup-later). The engine CONTAINER_ENGINE names must
# answer: one that does not (a stopped Docker daemon, Docker Desktop or Colima not started) may hide the
# installation of this folder - the menu then opens, and its engine check starts it.
wiz_first_start() {
  local k
  if [ -f "$SETUP_LATER_FILE" ] || [ -f "$ENV_FILE" ] || [ -f "$COMPOSE_FILE" ]; then
    return 1
  fi
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ] || [ ! -w "$WORK_DIR" ] || [ -n "$(job_running_ids)" ]; then
    return 1
  fi
  if [ -n "$CONTAINER_ENGINE" ] && engine_cli && [ -z "$(engine_rootless)" ]; then
    return 1
  fi
  for k in $(engine_kinds); do
    if engine_has_data "$k" containers; then
      return 1
    fi
  done
  [ -z "$(first_installation_dir)" ]
}

# wiz_engine_row NUMBER LABEL STATE REASON -> one engine of the Engine step; one that cannot be used
# here has no number, only the reason (wrapped to the width of the terminal)
wiz_engine_row() {
  local text line first="yes"
  if [ -n "$4" ]; then
    while IFS= read -r line; do
      if [ "$first" = "yes" ]; then
        printf '   %s  %s %s\n' "${C_DIM}-$C_RST" "$C_DIM$(ui_pad "$2" 16)$C_RST" "$C_DIM$line$C_RST"
        first="no"
      else
        printf '%23s%s\n' "" "$C_DIM$line$C_RST"
      fi
    done < <(printf '%s\n' "$4" | fold -s -w $(($(settings_width) - 24)) | sed 's/ *$//')
    return 0
  fi
  case "$3" in
    data) text="$C_GRN$UI_OK$C_RST holds the data of this folder" ;;
    ready) text="$C_GRN$UI_OK$C_RST ready" ;;
    installed) text="installed - the setup completes it" ;;
    *) text="${C_DIM}not installed - the setup installs it$C_RST" ;;
  esac
  printf '   %s  %s %s\n' "$C_BLD$1$C_RST" "$(ui_pad "$2" 16)" "$text"
}

# wiz_engine_pick CHOICES [FAILED] -> the engine the Engine step takes on Enter, from the lines of
# engine_choices: the one that holds the data of this folder, else CONTAINER_ENGINE, else one that is ready,
# else one that is installed, else the first one the setup installs (on macOS Colima before Docker Desktop,
# whose license comes first). FAILED, an engine whose setup did not work, only when no other one can be used.
wiz_engine_pick() {
  local kind label state reason rank best="" best_rank=9 pass
  for pass in other failed; do
    while IFS='|' read -r kind label state reason; do
      if [ -z "$kind" ] || [ -n "$reason" ] || { [ "$pass" = "other" ] && [ "$kind" = "${2:-}" ]; }; then
        continue
      fi
      case "$state" in
        data) rank=1 ;;
        ready) rank=3 ;;
        installed) rank=4 ;;
        *) rank=5 ;;
      esac
      if [ "$kind" = "$CONTAINER_ENGINE" ] && [ "$rank" -eq 1 ]; then
        rank=0
      elif [ "$kind" = "$CONTAINER_ENGINE" ]; then
        rank=2
      elif [ "$OS_KIND:$kind:$rank" = "Darwin:docker:5" ]; then
        rank=6
      fi
      if [ "$rank" -lt "$best_rank" ]; then
        best="$kind"
        best_rank="$rank"
      fi
    done <<< "$1"
    if [ -n "$best" ]; then
      break
    fi
  done
  printf '%s' "$best"
}

# The Engine step of the new installation: the engines of this machine and the one to use (Enter: see
# wiz_engine_pick), then its setup when it is not ready (after showing the commands and asking).
# 0: ready; 1: stopped; 2: stopped at the first question (the choice of the engine).
wiz_engine() {
  local -a kinds=() labels=() states=() reasons=()
  local choices kind label state reason i def pick choice rc failed="" first="yes" retry
  while true; do
    kinds=()
    labels=()
    states=()
    reasons=()
    choices="$(engine_choices)"
    while IFS='|' read -r kind label state reason; do
      if [ -n "$kind" ]; then
        kinds+=("$kind")
        labels+=("$label")
        states+=("$state")
        reasons+=("$reason")
      fi
    done <<< "$choices"
    if [ "${#kinds[@]}" -eq 0 ]; then
      err "The container engines of this machine could not be listed."
      return 1
    fi
    pick="$(wiz_engine_pick "$choices" "$failed")"
    def=""
    for i in "${!kinds[@]}"; do
      if [ "${kinds[i]}" = "$pick" ]; then
        def="$i"
      fi
    done
    echo "  The container engine runs the containers of the Catalog - one per server:"
    echo
    for i in "${!kinds[@]}"; do
      wiz_engine_row $((i + 1)) "${labels[i]}" "${states[i]}" "${reasons[i]}"
    done
    printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}stop$C_RST"
    echo
    if [ -z "$def" ]; then
      err "None of these engines can run the Catalog here (see the reasons above)."
      return 1
    fi
    if ! ui_ask choice "Select [$((def + 1))]:"; then
      echo
      choice="0"
    fi
    choice="${choice:-$((def + 1))}"
    if [ "$choice" = "0" ]; then
      if [ "$first" = "yes" ]; then
        return 2
      fi
      return 1
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#kinds[@]}" ]; then
      warn "Invalid choice: $choice"
      echo
      continue
    fi
    i=$((choice - 1))
    if [ -n "${reasons[i]}" ]; then
      warn "${labels[i]} cannot be used here: ${reasons[i]}"
      echo
      continue
    fi
    echo
    first="no"
    if ! engine_choose "${kinds[i]}"; then
      echo
      continue
    fi
    if engine_ready; then
      ok "$ENGINE_NAME is ready."
      return 0
    fi
    while true; do
      echo
      retry="yes"
      if [ "$ENGINE" = "podman" ] && [ "$OS_KIND" != "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
        err "Rootful Podman needs root: start $SCRIPT_NAME again with sudo."
        retry="no"
      else
        detect_compose >/dev/null 2>&1 || true
        info "$ENGINE_NAME is not ready yet${COMPOSE_PROBLEM:+: $COMPOSE_PROBLEM}"
        rc=0
        CONFIRM_LAST=""
        engine_setup ask || rc=$?
        if [ "$rc" -eq 0 ] && engine_ready; then
          ok "$ENGINE_NAME is ready."
          ui_pause_tty
          return 0
        fi
        if [ "$CONFIRM_LAST" = "0" ]; then
          return 1
        fi
      fi
      echo
      warn "$ENGINE_NAME is not ready - the Catalog cannot start without it."
      if [ "$retry" = "yes" ]; then
        printf '   %s  %s\n' "${C_BLD}1$C_RST" "Try again"
      fi
      printf '   %s  %s\n' "${C_BLD}2$C_RST" "Choose another engine"
      printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}stop$C_RST"
      echo
      while true; do
        if [ "$retry" = "yes" ]; then
          ui_ask choice "Select [1]:" || return 1
          choice="${choice:-1}"
        else
          ui_ask choice "Select [2]:" || return 1
          choice="${choice:-2}"
        fi
        case "$choice" in
          0|2) break ;;
          1)
            if [ "$retry" = "yes" ]; then
              break
            fi
            ;;
        esac
        warn "Invalid choice: $choice"
      done
      case "$choice" in
        0) return 1 ;;
        2)
          failed="$ENGINE_KIND"
          echo
          break
          ;;
      esac
    done
  done
}

# The Domain step of the new installation: the domain name of the Catalog (Enter keeps the saved one,
# - removes it), checked like on the settings screen, then its DNS records (a name not in DNS can be
# typed again); saved at once. 1: stopped.
wiz_domain() {
  local input d problem ans
  echo "  Domain name of the Catalog (e.g. catalog.example.com) - Enter: none, the"
  echo "  Catalog then runs on http://$(host_ip):$CATALOG_WEB_PORT."
  echo "  The DNS record of the name must point to this server."
  echo
  while true; do
    if [ -n "$CATALOG_DOMAIN" ]; then
      ui_ask input "Domain name [$CATALOG_DOMAIN, - removes it]:" || return 1
    else
      ui_ask input "Domain name [none]:" || return 1
    fi
    case "$input" in
      0) return 1 ;;
      "") d="$CATALOG_DOMAIN" ;;
      -) d="" ;;
      *)
        d="$(domain_normalize "$input")"
        if [ -z "$d" ]; then
          err "Give a host name, e.g. catalog.example.com (- removes the domain)."
          continue
        fi
        ;;
    esac
    if [ -n "$d" ]; then
      if ! problem="$(settings_check CATALOG_DOMAIN "$d" "")"; then
        err "$problem"
        continue
      fi
      echo
      domain_checks "$d"
      if [ "$DOMAIN_DNS" = "missing" ]; then
        ans=0
        wiz_yes_no "Keep $d? (n: type another name)" y || ans=$?
        case "$ans" in
          0) ;;
          1) echo; continue ;;
          *) return 1 ;;
        esac
      fi
    fi
    if domain_apply "$d" "$INSTALL_NGINX_PROXY_MANAGER" "$NPM_ADMIN_EMAIL"; then
      return 0
    fi
  done
}

# Why the domain gets no Let's Encrypt certificate at the start (empty: it gets one): a name Let's Encrypt
# refuses, no e-mail address it takes, or no DNS record yet (domain_checks)
wiz_no_https() {
  if domain_private "$CATALOG_DOMAIN"; then
    printf "no Let's Encrypt for .%s names" "${CATALOG_DOMAIN##*.}"
  elif ! npm_email_ok "$NPM_ADMIN_EMAIL"; then
    printf 'no e-mail address'
  elif [ "$DOMAIN_DNS_NAME" = "$CATALOG_DOMAIN" ] && [ "$DOMAIN_DNS" = "missing" ]; then
    printf 'not in DNS yet'
  fi
}

# The address of the Catalog under its domain with the saved settings (empty without a domain): https with
# Nginx Proxy Manager and a certificate at the start, otherwise http
wiz_domain_url() {
  if [ -z "$CATALOG_DOMAIN" ]; then
    return 0
  fi
  if [ "$INSTALL_NGINX_PROXY_MANAGER" != "true" ] || domain_private "$CATALOG_DOMAIN"; then
    domain_baseurl "$CATALOG_DOMAIN" "$INSTALL_NGINX_PROXY_MANAGER"
  elif [ -z "$(wiz_no_https)" ]; then
    printf 'https://%s' "$CATALOG_DOMAIN"
  else
    printf 'http://%s (HTTPS: option 24)' "$CATALOG_DOMAIN"
  fi
}

# The addresses of the Catalog with the saved settings, in one line: the domain, and Catalog Web on the
# address of this server
wiz_addresses() {
  local direct
  direct="http://$(host_ip):$CATALOG_WEB_PORT"
  if [ -n "$CATALOG_DOMAIN" ]; then
    printf '%s %s %s' "$(wiz_domain_url)" "$UI_SEP" "$direct"
  else
    printf '%s' "$direct"
  fi
}

# The summary of the new installation before the start, one value per row: the engine, the addresses,
# Nginx Proxy Manager and HTTPS, the versions and the folder
wiz_summary() {
  local -a rows=()
  local why
  rows+=("$(ui_pad "Engine" 10) $ENGINE_NAME")
  if [ -n "$CATALOG_DOMAIN" ]; then
    rows+=("$(ui_pad "Address" 10) $(wiz_domain_url)")
    rows+=("$(ui_pad "Direct" 10) http://$(host_ip):$CATALOG_WEB_PORT")
  else
    rows+=("$(ui_pad "Address" 10) http://$(host_ip):$CATALOG_WEB_PORT")
  fi
  if [ "$INSTALL_NGINX_PROXY_MANAGER" = "true" ]; then
    rows+=("$(ui_pad "Proxy" 10) Nginx Proxy Manager $NGINX_PROXY_MANAGER_TAG (admin page: port $NPM_ADMIN_PORT)")
    why="$(wiz_no_https)"
    if [ -z "$CATALOG_DOMAIN" ]; then
      rows+=("$(ui_pad "HTTPS" 10) none - no domain name (option 24 adds one)")
    elif [ -z "$why" ]; then
      rows+=("$(ui_pad "HTTPS" 10) Let's Encrypt certificate at the start ($NPM_ADMIN_EMAIL)")
    elif domain_private "$CATALOG_DOMAIN"; then
      rows+=("$(ui_pad "HTTPS" 10) HTTP only - $why")
    else
      rows+=("$(ui_pad "HTTPS" 10) HTTP for now: $why - option 24 adds HTTPS")
    fi
  else
    rows+=("$(ui_pad "Proxy" 10) none - Catalog Web answers directly")
  fi
  rows+=("$(ui_pad "Versions" 10) Catalog $CATALOG_VERSION $UI_SEP MongoDB $(version_core "$MONGO_TAG") $UI_SEP OpenSearch $(version_core "$OPENSEARCH_TAG")")
  rows+=("$(ui_pad "" 10) RabbitMQ $(version_core "$RABBITMQ_TAG") $UI_SEP MinIO $MINIO_TAG")
  rows+=("$(ui_pad "Folder" 10) $WORK_DIR")
  ui_box "$(settings_width)" "Summary" "${rows[@]}"
}

# The Proxy step of the new installation: Nginx Proxy Manager or not, then with a domain the e-mail address
# for Let's Encrypt and the login of Nginx Proxy Manager, and another port for Catalog Web when its port is
# in use; saved at once. The default is yes with a domain (a saved no counts while the domain is the one
# saved before this run: wiz_proxy DOMAIN-BEFORE), no without one or when its ports are in use. 1: stopped.
wiz_proxy() {
  local d="$CATALOG_DOMAIN" before="${1:-}" p busy="" def="n" ans npm email cur input problem
  if [ -n "$d" ]; then
    domain_checks "$d"
    echo
  fi
  echo "  Nginx Proxy Manager is a reverse proxy in front of the Catalog. It listens on"
  echo "  ports $NPM_HTTP_PORT and $NPM_HTTPS_PORT; its admin page is on port $NPM_ADMIN_PORT."
  if [ -z "$d" ]; then
    echo "  Without a domain name it only forwards http://$(host_ip) to the Catalog:"
    echo "  no HTTPS, and the forwarding is set up by hand in its admin page."
    echo "  Option 24 adds a domain name later."
  elif domain_private "$d"; then
    echo "  With it the Catalog answers on http://$d."
    echo "  Let's Encrypt gives no certificates for .${d##*.} names - HTTPS needs an own"
    echo "  certificate, added in its admin page."
  elif [ "$DOMAIN_DNS" = "missing" ]; then
    echo "  With it the Catalog answers on https://$d with a free"
    echo "  Let's Encrypt certificate once the name points to this server - until then on"
    echo "  http://$d (option 24 requests the certificate later)."
  else
    echo "  With it the Catalog answers on https://$d with a free"
    echo "  Let's Encrypt certificate, set up automatically."
  fi
  if [ -n "$d" ] && { [ "$d" != "$before" ] || [ "$INSTALL_NGINX_PROXY_MANAGER" = "true" ]; }; then
    def="y"
  fi
  for p in "$NPM_HTTP_PORT" "$NPM_HTTPS_PORT" "$NPM_ADMIN_PORT"; do
    if wiz_port_used "$p"; then
      busy="$busy $p"
    fi
  done
  if [ -n "$busy" ]; then
    echo
    if [[ "${busy# }" == *" "* ]]; then
      warn "Ports $(wiz_and $busy) are in use on this server: Nginx Proxy Manager"
    else
      warn "Port ${busy# } is in use on this server: Nginx Proxy Manager"
    fi
    echo "  cannot start while another program listens there."
    def="n"
  fi
  while true; do
    echo
    ans=0
    wiz_yes_no "Install Nginx Proxy Manager?" "$def" || ans=$?
    case "$ans" in
      0) npm="true" ;;
      1) npm="false" ;;
      *) return 1 ;;
    esac
    email="$NPM_ADMIN_EMAIL"
    if [ -n "$d" ] && [ "$npm" = "true" ] && ! domain_private "$d"; then
      cur=""
      if npm_email_ok "$NPM_ADMIN_EMAIL"; then
        cur="$NPM_ADMIN_EMAIL"
      fi
      echo
      echo "  Let's Encrypt needs a real e-mail address for its expiry notices; it is also"
      echo "  the login of Nginx Proxy Manager. Enter: none - no certificate now, option 24"
      echo "  adds HTTPS later."
      while true; do
        ui_ask input "E-mail address [${cur:-none}${cur:+, - none}]:" || return 1
        input="${input//[[:space:]]/}"
        input="${input,,}"
        case "$input" in
          0) return 1 ;;
          "") email="$cur"; break ;;
          -) email=""; break ;;
        esac
        if ! problem="$(settings_check NPM_ADMIN_EMAIL "$input" "")"; then
          err "$problem"
        elif ! npm_email_ok "$input"; then
          err "Let's Encrypt does not take addresses at ${input##*@} - give a real one."
        else
          email="$input"
          break
        fi
      done
      if [ -z "$email" ]; then
        warn "No e-mail address: HTTP only for now - option 24 adds HTTPS later."
      fi
    fi
    echo
    if domain_apply "$d" "$npm" "$email"; then
      break
    fi
  done
  if wiz_port_used "$CATALOG_WEB_PORT"; then
    echo
    warn "Port $CATALOG_WEB_PORT (Catalog Web) is in use on this server - choose another."
    wiz_ask CATALOG_WEB_PORT "Port of Catalog Web on this server" new || return 1
    domain_apply "$CATALOG_DOMAIN" "$INSTALL_NGINX_PROXY_MANAGER" "$NPM_ADMIN_EMAIL" || return 1
  fi
}

# Worker of the install task: start the stack and wait until every service is healthy.
install_start() {
  WIZ_QUIET_ACCESS="yes" do_up
  echo
  stack_health
}

# Step of the install task: writes the files, keeping existing passwords, and checks that they were
# written completely (a full disk does not stop the writes by itself here). Exit code 4: cancelled.
install_generate() {
  do_generate keep no-next || exit 1
  if [ "$GENERATE_CANCELLED" = "true" ]; then
    exit 4
  fi
  if [ ! -s "$ENV_FILE" ] || [ ! -s "$COMPOSE_FILE" ] || settings_stale; then
    err "$ENV_FILE or $COMPOSE_FILE was not written completely (disk full? permissions?)."
    exit 1
  fi
}

# Step of the install task: snapshots, imported right away by default
install_snapshots() {
  SNAP_IMPORT_DEFAULT="y"
  download_snapshot
}

# I: in a folder without an installation the new installation (install_new; first: the menu starts with
# it on the first start here), also on the files that option 99 or R left. In a folder that is installed
# already: repair (check, settings, files, start), continue with the license and the data, update or
# remove. install_wizard [first]
install_wizard() {
  local -a steps=(Check Settings Files Start License Data Done)
  local jobs found choice rc ans step=1 installed="" npm note
  jobs="$(wiz_running_jobs)"
  if [ -n "$jobs" ]; then
    warn "A background job is running - wait for it or follow it with J first:"
    printf '    %s\n' "$jobs"
    return 0
  fi
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "The installer must be a writable file for the installation (it keeps the settings)."
    return 0
  fi
  if [ ! -w "$WORK_DIR" ]; then
    err "$WORK_DIR is not writable - the installation writes its files there (run as its owner, or with sudo)."
    return 0
  fi

  # only .env and docker-compose.yml, no container and no data: nothing to repair, a new installation
  if nothing_installed "$(install_kind)"; then
    found="$(stack_foreign)" || found=""
    if [ -z "$found" ]; then
      found="$(first_installation_dir)"
    fi
    if [ -z "$found" ]; then
      install_new "${1:-}"
      return 0
    fi
    wiz_head "Install" 1 Internet Engine Domain Proxy Versions Install License Data Done
    warn "A Catalog installation already exists on this server: $found"
    echo "  The Catalog runs once per server (its containers have fixed names), so a second one cannot start."
    echo
    printf '   %s  %s\n' "${C_BLD}1$C_RST" "Take it over into this folder (option 23) - keeps its settings, passwords and data"
    printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}cancel (or remove it with R in its own folder first)$C_RST"
    echo
    ui_ask choice "Select [0]:" || choice="0"
    if [ "$choice" = "1" ]; then
      adopt_installation || true
    else
      info "Cancelled."
    fi
    return 0
  fi

  wiz_head "Install" 1 "${steps[@]}"
  installed="$(wiz_installed_version)"
  warn "This folder already has an installation (Catalog ${installed:-$CATALOG_VERSION}, stack: $(stack_state))."
  local repair="Repair: check it, write the files again and start it (passwords, data and version are kept)"
  if [ ! -f "$ENV_FILE" ]; then
    found="$(newest_env_backup)"
    if [ -n "$found" ]; then
      echo "  $ENV_FILE is missing: a repair takes the passwords from its newest backup $found."
      repair="Repair: check it, write the files again with the passwords of that backup, and start it"
    else
      warn "$ENV_FILE is missing and has no backup. It holds the passwords of MongoDB and RabbitMQ:"
      echo "  new passwords would not open the existing data. Put the old $ENV_FILE back first if you have it."
      repair="Repair: check it and write the files again - needs the old $ENV_FILE first (see above)"
    fi
  fi
  echo
  printf '   %s  %s\n' "${C_BLD}1$C_RST" "$repair"
  printf '   %s  %s\n' "${C_BLD}2$C_RST" "Continue with the license and the catalog data (step 5)"
  printf '   %s  %s\n' "${C_BLD}3$C_RST" "Update it instead (U)"
  printf '   %s  %s\n' "${C_BLD}4$C_RST" "Remove it first (R), then install from scratch"
  printf '   %s  %s\n' "${C_BLD}0$C_RST" "${C_DIM}cancel$C_RST"
  echo
  ui_ask choice "Select [0]:" || choice="0"
  case "$choice" in
    1)
      # a repair writes the settings: older ones than the installation (or other values) are offered first
      note="$(install_note)"
      if [ -z "$note" ]; then
        note="$(install_diff_note)"
      fi
      if [ -n "$note" ]; then
        warn "$note."
        install_takeover interactive || true
        ui_pause_tty
      fi
      # the repair keeps the Catalog version of the installation (step 2), not an older MongoDB of the settings:
      # stopped before the check and the memory question
      note="$(downgrade_problem "" "$MONGO_TAG" settings)"
      if [ -n "$note" ]; then
        err "$note"
        echo "  The repair would write it - take the installation's values over first (option 23)."
        return 0
      fi
      wiz_head "Install" 1 "${steps[@]}"
      ;;
    2) step=5 ;;
    3) update_wizard; return 0 ;;
    4) remove_wizard; return 0 ;;
    *) info "Cancelled."; return 0 ;;
  esac

  if [ "$step" -le 1 ]; then
    # 1. Check (the engine first; MongoDB 8 on the kernels 6.19 to 7.0.x needs a workaround, which the files get)
    engine_offer
    if mongo_rseq_workaround "$MONGO_TAG"; then
      info "MongoDB $MONGO_TAG on this kernel ($(engine_kernel)) starts with GLIBC_TUNABLES=glibc.pthread.rseq=1 (SERVER-121912)."
      echo "  The files get it by themselves. TCMalloc then uses per-thread caches: some performance cost."
      echo
    fi
    echo "  $ENGINE_NAME, $ENGINE compose, the kernel of the containers, ports, vm.max_map_count and the time zone:"
    echo
    ans=0
    if wiz_run do_check; then
      wiz_yes_no "Continue with the settings?" y || ans=$?
    else
      echo
      wiz_yes_no "Some checks failed (see above). Continue anyway?" n || ans=$?
    fi
    if [ "$ans" -eq 0 ]; then
      mem_ask wizard said || ans=$?
    fi
    if [ "$ans" -ne 0 ]; then
      wiz_stop "I"
      return 0
    fi

    # 2. Settings (a repair keeps the running version: an upgrade needs the backup and rollback of U)
    wiz_head "Install" 2 "${steps[@]}"
    echo "  The main settings - all others are on the settings screen (option 1)."
    echo
    if is_version "$installed" && [ "$installed" != "$CATALOG_VERSION" ]; then
      warn "CATALOG_VERSION is $CATALOG_VERSION, the installation has $installed - the repair keeps $installed (U upgrades with backup and rollback)."
      wiz_set CATALOG_VERSION "$installed"
    fi
    echo "  Catalog version: $CATALOG_VERSION $C_DIM(kept - U updates it)$C_RST"
    ans=0
    wiz_yes_no "Install Nginx Proxy Manager as reverse proxy with TLS (ports $NPM_HTTP_PORT, $NPM_HTTPS_PORT and $NPM_ADMIN_PORT)?" "$(if [ "$INSTALL_NGINX_PROXY_MANAGER" = "true" ]; then echo y; else echo n; fi)" || ans=$?
    case "$ans" in
      0) npm="true" ;;
      1) npm="false" ;;
      *) wiz_stop "I"; return 0 ;;
    esac
    # with a domain, BASEURL follows Nginx Proxy Manager
    if [ -n "$CATALOG_DOMAIN" ]; then
      if ! domain_apply "$CATALOG_DOMAIN" "$npm" "$NPM_ADMIN_EMAIL"; then
        wiz_stop "I"
        return 0
      fi
    else
      wiz_set INSTALL_NGINX_PROXY_MANAGER "$npm"
    fi
    if ! wiz_ask CATALOG_WEB_PORT "Port of Catalog Web on this server"; then
      wiz_stop "I"
      return 0
    fi
    tz_offer_alignment wizard
    if [ "$TZ_STOPPED" = "true" ]; then
      wiz_stop "I"
      return 0
    fi
    reload_settings
    echo
    ans=0
    wiz_yes_no "Write the files with these settings?" y || ans=$?
    if [ "$ans" -ne 0 ]; then
      wiz_stop "I"
      return 0
    fi

    # 3. Files
    wiz_head "Install" 3 "${steps[@]}"
    rc=0
    wiz_run install_generate || rc=$?
    case "$rc" in
      0) ;;
      4) wiz_stop "I"; return 0 ;;
      *) err "The files could not be written (see above)."; wiz_stop "I"; return 0 ;;
    esac
    echo
    ans=0
    wiz_yes_no "Start the Catalog now? (pulls the images; the first start takes a few minutes)" y || ans=$?
    if [ "$ans" -ne 0 ]; then
      wiz_stop "I"
      return 0
    fi

    # 4. Start
    wiz_head "Install" 4 "${steps[@]}"
    rc=0
    wiz_run run_job "Install: start the Catalog" -- install_start || rc=$?
    case "$rc" in
      0) ;;
      3)
        info "The start goes on in the background (J shows it). When it is done, I continues with the"
        echo "  license and the catalog data (choice 2), or use options 25 and 20."
        return 0
        ;;
      *)
        err "The Catalog did not start cleanly - option 10 shows the logs, option 16 checks the server."
        # the first start downloads the images
        net_offer_check "The start of the Catalog"
        wiz_stop "I"
        return 0
        ;;
    esac
    echo
    ans=0
    wiz_yes_no "Continue with the license and the catalog data?" y || ans=$?
    if [ "$ans" -ne 0 ]; then
      wiz_stop "I"
      return 0
    fi
  fi
  install_license 5 "${steps[@]}"
  install_finish 6 "${steps[@]}"
}

# I in a folder without an installation: the internet access, the engine, the domain name, Nginx Proxy
# Manager and the versions, then the summary, the check, the files and the start (with Nginx Proxy Manager
# for the domain), the license and the catalog data. Every answer is saved at once, so the task starts
# again with them; 0 or the end of input at a question stops it. install_new [first]
install_new() {
  local -a steps=(Internet Engine Domain Proxy Versions Install License Data Done)
  local rc ans out k holders="" before
  wiz_head "Install" 1 "${steps[@]}"
  # data volumes of this project without their passwords (.env, or a backup of it): new passwords
  # would not open them
  if [ ! -f "$ENV_FILE" ] && [ -z "$(newest_env_backup)" ]; then
    for k in $(engine_kinds); do
      if engine_has_data "$k"; then
        holders="$holders $k"
      fi
    done
    if [ -n "$holders" ]; then
      warn "Data volumes of project \"$(stack_project)\" are in $(kinds_text "${holders# }"), but this folder has no $ENV_FILE"
      echo "  (and no backup of it). The passwords of MongoDB, RabbitMQ and Nginx Proxy"
      echo "  Manager are in these volumes: new passwords would not open them. Put the old"
      echo "  $ENV_FILE back into this folder, or remove the volumes with R if their data is"
      echo "  not needed. Nothing was changed."
      return 0
    fi
  fi
  if [ "${1:-}" = "first" ]; then
    echo "  ${C_BLD}New installation.$C_RST A few questions - engine, domain, proxy, versions - then"
    echo "  the Catalog starts. 0 at any question opens the full menu."
    echo
  elif [ -f "$ENV_FILE" ]; then
    # the files that option 99 or R left (install_wizard)
    echo "  ${C_BLD}New installation$C_RST on the files of this folder: no containers and no data"
    echo "  are left, so the Catalog starts empty. The passwords in $ENV_FILE are kept."
    echo
  fi

  # 1. Internet: the sites the installation needs, the proxy questions only when required ones fail
  # (stopped at its first question: as at the engine's)
  rc=0
  wiz_internet || rc=$?
  if [ "$rc" -ne 0 ]; then
    wiz_stop "I"
    if [ "$rc" -eq 2 ] && [ ! -f "$SETUP_LATER_FILE" ] && touch -- "$SETUP_LATER_FILE" 2>/dev/null; then
      echo "  The next start opens the menu directly."
    fi
    return 0
  fi

  # 2. Engine (stopped at its first question: the next start opens the menu, I starts the installation)
  wiz_head "Install" 2 "${steps[@]}"
  rc=0
  wiz_engine || rc=$?
  if [ "$rc" -ne 0 ]; then
    wiz_stop "I"
    if [ "$rc" -eq 2 ] && [ ! -f "$SETUP_LATER_FILE" ] && touch -- "$SETUP_LATER_FILE" 2>/dev/null; then
      echo "  The next start opens the menu directly."
    fi
    return 0
  fi
  # an engine that did not answer before may hold the installation of this folder: then its repair
  menu_scan_done
  if ! nothing_installed "$(install_kind)"; then
    install_wizard
    return 0
  fi

  # 3. Domain
  before="$CATALOG_DOMAIN"
  wiz_head "Install" 3 "${steps[@]}"
  if ! wiz_domain; then
    wiz_stop "I"
    return 0
  fi

  # 4. Proxy
  wiz_head "Install" 4 "${steps[@]}"
  if ! wiz_proxy "$before"; then
    wiz_stop "I"
    return 0
  fi

  # 5. Versions (Enter takes the recommended ones); first the addresses the answers so far give
  wiz_head "Install" 5 "${steps[@]}"
  ok "The Catalog: $(wiz_addresses)"
  echo
  if ! choose_versions; then
    wiz_stop "I"
    return 0
  fi

  # 6. Install: the summary, the time zone, the check, then the files and the start as one answer
  wiz_head "Install" 6 "${steps[@]}"
  reload_settings
  wiz_summary
  if mongo_rseq_workaround "$MONGO_TAG"; then
    info "MongoDB $(version_core "$MONGO_TAG") on kernel $(engine_kernel) needs a workaround (SERVER-121912):"
    echo "  it starts with GLIBC_TUNABLES=glibc.pthread.rseq=1, which the files get by"
    echo "  themselves. TCMalloc then uses per-thread caches: some performance cost."
  fi
  tz_offer_alignment wizard
  if [ "$TZ_STOPPED" = "true" ]; then
    wiz_stop "I"
    return 0
  fi
  echo
  info "Checking the engine, Compose, the kernel, the ports and vm.max_map_count..."
  rc=0
  out="$(do_check 2>&1)" || rc=$?
  ans=0
  if [ "$rc" -eq 0 ]; then
    # quiet: only the warnings
    awk '/WARN/ { p = 1; print; next } p && /^      / { print; next } { p = 0 }' <<< "$out"
    ok "All required checks passed."
  else
    printf '%s\n' "$out"
    echo
    wiz_yes_no "Some checks failed (see above). Continue anyway?" n || ans=$?
  fi
  if [ "$ans" -eq 0 ]; then
    mem_ask wizard said || ans=$?
  fi
  if [ "$ans" -ne 0 ]; then
    wiz_stop "I"
    return 0
  fi
  echo
  echo "  The first start pulls the images and takes a few minutes."
  ans=0
  wiz_yes_no "Write the files and start the Catalog?" y || ans=$?
  if [ "$ans" -ne 0 ]; then
    wiz_stop "I"
    return 0
  fi
  echo
  rc=0
  wiz_run install_generate || rc=$?
  case "$rc" in
    0) ;;
    4) wiz_stop "I"; return 0 ;;
    *) err "The files could not be written (see above)."; wiz_stop "I"; return 0 ;;
  esac
  echo
  rc=0
  wiz_run run_job "Install: start the Catalog" -- install_start || rc=$?
  case "$rc" in
    0) ;;
    3)
      info "The start goes on in the background (J shows it). When it is done, I"
      echo "  continues with the license and the data (choice 2) - or options 25 and 20."
      if [ -n "$CATALOG_DOMAIN" ] && [ "$INSTALL_NGINX_PROXY_MANAGER" = "true" ]; then
        echo "  Option 24 then sets up Nginx Proxy Manager for $CATALOG_DOMAIN."
      fi
      return 0
      ;;
    *)
      err "The Catalog did not start cleanly (see above)."
      echo "  Option 10 shows the logs, option 16 checks the server; I repairs it."
      wiz_stop "I"
      return 0
      ;;
  esac
  # the proxy host and the certificate of the domain, through the API of Nginx Proxy Manager
  if [ -n "$CATALOG_DOMAIN" ] && [ "$INSTALL_NGINX_PROXY_MANAGER" = "true" ]; then
    echo
    rc=0
    wiz_run npm_setup_domain yes || rc=$?
    if [ "$rc" -ne 0 ]; then
      warn "Nginx Proxy Manager is not set up for $CATALOG_DOMAIN yet (see above)."
      echo "  Option 24 retries it."
    fi
  fi
  ui_pause_tty
  install_license 7 "${steps[@]}"
  install_finish 8 "${steps[@]}"
}

# The last steps of the install task: the catalog data (step DATA-STEP), then the summary. The data
# needs a valid license: without one the summary says so instead.
# install_finish DATA-STEP STEP-NAME...
install_finish() {
  local n="$1" choice since data="no"
  shift
  license_status
  case "$LICENSE_STATE" in
    valid) ;;
    invalid) data="unlicensed" ;;
    *) data="noweb" ;;
  esac
  if [ "$data" = "no" ]; then
    wiz_head "Install" "$n" "$@"
    ok "The Catalog is activated (valid license)."
    echo "  The Catalog is empty until it gets its data from $CATALOG_CLOUD_URL."
    echo
    printf '   %s %s  %s\n' "${C_BLD}1$C_RST" "$(menu_icon run)" "Daily self-sync: the Catalog fetches the data itself $C_DIM(server with internet, option 20)$C_RST"
    printf '   %s %s  %s\n' "${C_BLD}2$C_RST" "$(menu_icon run)" "Download the snapshots here and import them $C_DIM(options 17 and 19)$C_RST"
    printf '   %s    %s\n' "${C_BLD}0$C_RST" "${C_DIM}later$C_RST"
    echo
    ui_ask choice "Select [0]:" || choice="0"
    # what really happened is read afterwards: a mark of the self-sync, and the jobs started meanwhile
    since="$(wiz_last_job)"
    WIZ_MARK="$(mktemp)"
    case "$choice" in
      1) wiz_run local_self_sync || true ;;
      2) wiz_run install_snapshots || true ;;
    esac
    if grep -qx sync "$WIZ_MARK" 2>/dev/null; then
      data="sync"
    fi
    rm -f -- "$WIZ_MARK"
    WIZ_MARK=""
    case "$(wiz_job_since "$since" "Snapshot import")" in
      done) data="snapshot" ;;
      # unfollowed: the import goes on in the Catalog
      running|unfollowed) data="importing" ;;
      "")
        case "$(wiz_job_since "$since" "Snapshot download")" in
          done) data="downloaded" ;;
          running) data="downloading" ;;
        esac
        ;;
    esac
    ui_pause_tty
  fi

  wiz_head "Install" $((n + 1)) "$@"
  ok "The Catalog is installed: $(stack_state)."
  echo
  show_access_info
  echo
  echo "  Catalog Web login: root (default password root unless it was changed) -"
  echo "  change it in the web interface."
  echo
  case "$data" in
    sync)
      echo "  Catalog data: the Catalog synchronizes itself every day"
      echo "  ($AUTOSYNC_CRON in $TZ)."
      ;;
    snapshot) echo "  Catalog data: imported from the snapshots (option 19 imports newer ones)." ;;
    importing) echo "  Catalog data: the import runs in the background (J shows it)." ;;
    downloaded) warn "Catalog data: downloaded, not imported yet - option 19 imports it." ;;
    downloading) echo "  Catalog data: downloading in the background (J); option 19 imports it then." ;;
    unlicensed)
      warn "The Catalog has no data yet: it is not activated (no valid license)."
      echo "  Option 25 activates the Catalog, then options 20 / 17 and 19 load the data."
      ;;
    noweb)
      warn "The Catalog has no data yet: Catalog Web did not answer the license check."
      echo "  Option 9 shows the stack; then option 25 activates the Catalog, and options"
      echo "  20 / 17 and 19 load the data."
      ;;
    *) warn "The Catalog has no data yet: option 20 (daily self-sync), or 17 and 19." ;;
  esac
  echo "  Options: 14 passwords $UI_SEP 15 addresses $UI_SEP 24 domain and HTTPS $UI_SEP 9 status"
  echo "  Next: the full menu - every option (H: help)."
  rm -f -- "$SETUP_LATER_FILE"
}

# U: brings the installation up to date - the installer itself, then Docker Compose (the engine
# behind "podman compose", or the installer's own Compose plugin of Docker) and the Catalog with backup,
# health check and the patch updates of the other components. update_wizard [STEP [NOTICE]]
update_wizard() {
  local -a steps=(Installer Catalog Done)
  local start="${1:-1}" notice="${2:-}" jobs rc ans before after target installed failed_before="no" here
  jobs="$(wiz_running_jobs)"
  if [ -n "$jobs" ]; then
    warn "A background job is running - wait for it or follow it with J first:"
    printf '    %s\n' "$jobs"
    return 0
  fi
  if [ -z "$SCRIPT_PATH" ] || [ ! -w "$SCRIPT_PATH" ]; then
    err "The installer must be a writable file for an update (it keeps the settings and the version)."
    return 0
  fi
  here="$(install_kind)"
  if nothing_installed "$here"; then
    info "Nothing is installed in this folder yet - I installs the Catalog."
    if [ "$here" = "files" ]; then
      echo "  Only $ENV_FILE and $COMPOSE_FILE are here, no containers and no data."
      echo "  Option 22 updates this installer."
    fi
    return 0
  fi

  # 1. The installer (a new version restarts the menu, which comes back to step 2)
  if [ "$start" -le 1 ]; then
    wiz_head "Update" 1 "${steps[@]}"
    echo "  First the installer itself, so the newest checks and steps are used."
    echo
    WIZ_RESUME="resume-update"
    update_installer interactive || warn "The installer was not updated (see above) - continuing with the Catalog."
    WIZ_RESUME=""
    echo
    ans=0
    wiz_yes_no "Continue with the Catalog?" y || ans=$?
    if [ "$ans" -ne 0 ]; then
      wiz_stop "U"
      return 0
    fi
  fi

  # 2. The Catalog and the patch updates of the other components
  wiz_head "Update" 2 "${steps[@]}"
  if [ -n "$notice" ]; then
    ok "$notice"
    echo
  fi
  # the newest Docker Compose; one that does not work with this engine is not installed (root is
  # only needed to write a new one)
  if engine_cli && compose_own; then
    use_sudo || SUDO=()
    install_compose_provider yes || warn "Docker Compose was not updated (see above)."
    echo
  fi
  detect_compose >/dev/null 2>&1 || true
  before="$(running_tag catalog-web 2>/dev/null)" || before=""
  if [ -f "$UPGRADE_FAILED_FILE" ]; then
    failed_before="yes"
  fi
  rc=0
  wiz_run do_upgrade || rc=$?
  reload_settings
  jobs="$(wiz_running_jobs)"
  if [ "$rc" -eq 3 ] || [ -n "$jobs" ]; then
    info "The upgrade goes on in the background - J follows it. Run U again when it is done (patch updates)."
    return 0
  fi
  after="$(running_tag catalog-web 2>/dev/null)" || after=""
  if [ "$rc" -ne 0 ]; then
    echo
    warn "The update did not finish (see above). Catalog: ${after:-unknown} - option 21 goes back or tries again."
    return 0
  fi
  ui_pause_tty

  # 3. Done (do_upgrade read Docker Hub in its subshell: this shell asks once more if it has to)
  wiz_head "Update" 3 "${steps[@]}"
  if [ -z "$HUB_VERSIONS$LATEST_VERSION" ]; then
    fetch_hub_versions >/dev/null 2>&1 || true
  fi
  target="$(recommended_catalog)"
  target="${target:-$LATEST_VERSION}"
  installed="${after:-$(wiz_installed_version)}"
  if [ -f "$UPGRADE_FAILED_FILE" ]; then
    warn "The last upgrade did not become healthy - option 21 goes back. Catalog: ${installed:-unknown}."
  elif [ "$failed_before" = "yes" ] && [ -n "$after" ] && [ "$after" != "$before" ]; then
    ok "Went back to Catalog $after."
  elif [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    ok "Catalog updated: $before $UI_RARR $after $UI_SEP stack: $(stack_state)."
  elif [ -n "$target" ] && is_version "$installed" && version_gt "$target" "$installed"; then
    warn "Not upgraded: Catalog $installed is installed, $target is available - U or option 21 upgrades it."
  else
    ok "Catalog ${installed:-$CATALOG_VERSION} is up to date $UI_SEP stack: $(stack_state)."
  fi
  if [ -z "$after" ]; then
    warn "The stack is not running - option 6 starts it."
  fi
  if mongo_kernel_problem; then
    warn "MongoDB refuses to start on this kernel ($(engine_kernel), SERVER-121912): the files lack the workaround."
    echo "  I (repair) writes them again with GLIBC_TUNABLES=glibc.pthread.rseq=1 and starts the stack."
  fi
  echo
  echo "  Other versions of MongoDB, OpenSearch or RabbitMQ inside the series Raynet runs: option 8."
  echo "  Catalog data: the daily self-sync (option 20) keeps it current; offline servers import"
  echo "  the changes since their last snapshot with options 17 and 19."
}

# Project name of the stack, as Docker Compose names it from the folder
# (or COMPOSE_PROJECT_NAME): lower case, a-z 0-9 _ -, without leading - and _
stack_project() {
  local project="${COMPOSE_PROJECT_NAME:-$(basename -- "$WORK_DIR")}"
  project="$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
  printf '%s' "${project#"${project%%[!_-]*}"}"
}

# Size of files or folders, e.g. "1.2 GB"
wiz_size() {
  local f total=0 kb
  for f in "$@"; do
    if [ -e "$f" ]; then
      kb="$(du -sk -- "$f" 2>/dev/null | awk '{ print $1 }')" || kb=0
      total=$((total + ${kb:-0}))
    fi
  done
  human_size $((total * 1024))
}

# True only when folder $1 surely does not exist (any more): its nearest existing parent can be
# searched. A folder this user cannot look into counts as existing.
wiz_dir_gone() {
  local d="$1"
  if [ -z "$d" ] || [ -e "$d" ]; then
    return 1
  fi
  while [ ! -e "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do
    d="$(dirname -- "$d")"
  done
  [ -d "$d" ] && [ -x "$d" ]
}

# stack_compose_keys services|volumes -> the names that section has in the compose file this
# installer writes (all optional parts included)
stack_compose_keys() {
  local tmp
  tmp="$(mktemp)" || return 0
  (
    COMPOSE_FILE="$tmp"
    INSTALL_NGINX_PROXY_MANAGER="true"
    write_compose_file
  ) >/dev/null 2>&1 || true
  awk -v s="$1:" '$0 == s { on = 1; next } /^[^ ]/ { on = 0 } on && /^  [A-Za-z0-9_.-]+:/ { k = $1; sub(/:$/, "", k); print k }' "$tmp"
  rm -f -- "$tmp"
}

# Containers with the project name of this folder: ID|OWNER|IMAGE, OWNER "here" for this
# installation - started here, or started from a folder that surely no longer exists (moved) with
# a service and an image of this installer - otherwise the folder they were started from.
stack_containers() {
  local id wd svc image services="" repos=""
  while IFS= read -r id; do
    if [ -z "$id" ]; then
      continue
    fi
    if [ -z "$services" ]; then
      services=" $(stack_compose_keys services | tr '\n' ' ') "
      repos=" $(stack_images | sed 's/:[^:/]*$//' | tr '\n' ' ') "
    fi
    IFS='|' read -r wd svc image <<< "$("$ENGINE" container inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}' "$id" 2>/dev/null)"
    image="$(short_ref "$image")"
    if [ -n "$wd" ] && { [ "$wd" = "$WORK_DIR" ] || [ "$wd" -ef "$WORK_DIR" ]; }; then
      printf '%s|here|%s\n' "$id" "$image"
    elif wiz_dir_gone "$wd" && [[ "$services" == *" $svc "* ]] && [[ "$repos" == *" ${image%:*} "* ]]; then
      printf '%s|here|%s\n' "$id" "$image"
    else
      printf '%s|%s|%s\n' "$id" "${wd:-an unknown folder}" "$image"
    fi
  done < <("$ENGINE" ps -aq --filter "label=com.docker.compose.project=$(stack_project)" 2>/dev/null)
}

# Containers of this installation, one ID per line
remove_containers() {
  stack_containers | awk -F'|' '$2 == "here" { print $1 }'
}

# Prints the first folder whose containers share the project name of this folder without being
# this installation; fails when there is none
stack_foreign() {
  local id owner image
  while IFS='|' read -r id owner image; do
    if [ -n "$id" ] && [ "$owner" != "here" ]; then
      printf '%s' "$owner"
      return 0
    fi
  done <<< "$(stack_containers)"
  return 1
}

# Prints the folder of another Catalog installation - running or stopped, its folder still there - with the project name of
# this folder (its data volumes have the same names); fails when there is none
stack_foreign_catalog() {
  local id owner image project dir p mine
  if ! engine_cli; then
    return 1
  fi
  while IFS='|' read -r id owner image; do
    if [ -n "$id" ] && [ "$owner" != "here" ] && [[ "$image" == *rayventory-catalog* ]]; then
      printf '%s' "$owner"
      return 0
    fi
  done <<< "$(stack_containers)"
  mine="$(stack_project)"
  while IFS='|' read -r project dir _; do
    p="${project#"${project%%[!_-]*}"}"
    if [ -n "$dir" ] && [ "$p" = "${mine#"${mine%%[!_-]*}"}" ] && [ "$dir" != "$WORK_DIR" ] && ! [ "$dir" -ef "$WORK_DIR" ] && ! wiz_dir_gone "$dir"; then
      printf '%s' "$dir"
      return 0
    fi
  done <<< "$(find_installations 2>/dev/null)"
  return 1
}

# Catalog stacks under another project name whose folder no longer exists: PROJECT|FOLDER per line.
# It can be this installation after its folder was renamed.
stack_lost() {
  local project wd mine
  mine="$(stack_project)"
  while IFS='|' read -r project wd; do
    if [ -n "$project" ] && [ "$project" != "$mine" ] && wiz_dir_gone "$wd"; then
      printf '%s|%s\n' "$project" "$wd"
    fi
  done < <(catalog_web_containers '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}' | sort -u)
}

# Data volumes of this installation: the volumes this installer declares, named after the project -
# only when the files or the containers here show that it was installed here, and never when
# another Catalog installation has the same project name.
remove_volumes() {
  local project key v
  if [ ! -f "$ENV_FILE" ] && [ ! -f "$COMPOSE_FILE" ] && [ -z "$(remove_containers)" ]; then
    return 0
  fi
  if stack_foreign_catalog >/dev/null; then
    return 0
  fi
  project="$(stack_project)"
  while IFS= read -r key; do
    v="${project}_$key"
    if [ -n "$key" ] && "$ENGINE" volume inspect "$v" >/dev/null 2>&1; then
      printf '%s\n' "$v"
    fi
  done < <(stack_compose_keys volumes)
}

# remove_users VOLUME|IMAGE KIND -> names of containers that are not this installation's and use
# the volume (KIND volume) or the image (KIND ancestor); empty when none
remove_users() {
  local id ours what="$1"
  ours=" $(remove_containers | tr '\n' ' ') "
  if [ "$2" = "ancestor" ]; then
    # Podman matches image names as a pattern: the image ID is exact
    what="$("$ENGINE" image inspect --format '{{.ID}}' "$(qualify_ref "$1")" 2>/dev/null)" || return 0
  fi
  while IFS= read -r id; do
    if [ -n "$id" ] && [[ "$ours" != *" $id "* ]]; then
      "$ENGINE" container inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##'
    fi
  done < <("$ENGINE" ps -aq --filter "$2=$what" 2>/dev/null)
}

# Images of this installation that are here and that no other container uses
remove_images() {
  local img
  {
    stack_containers | awk -F'|' '$2 == "here" { print $3 }'
    if remove_compose_ok; then
      compose config --images 2>/dev/null || true
    fi
    stack_images
  } | while IFS= read -r img; do
    short_ref "$img"
    echo
  done | sort -u | while IFS= read -r img; do
    if [ -n "$img" ] && "$ENGINE" image inspect "$(qualify_ref "$img")" >/dev/null 2>&1 && [ -z "$(remove_users "$img" ancestor)" ]; then
      printf '%s\n' "$img"
    fi
  done
}

# True when the generated files are here and the engine's compose can use them
remove_compose_ok() {
  [ -f "$ENV_FILE" ] && [ -f "$COMPOSE_FILE" ] && detect_compose >/dev/null 2>&1
}

# Worker of the remove task: remove_stack VOLUMES IMAGES (yes or no) - the containers and networks
# always. Fails, naming what is left, when a container or a chosen volume could not be removed.
remove_stack() {
  local volumes="$1" images="$2" ids img v out left="" kept=0 gone=0
  local -a vols=() imgs=()
  require_engine
  if [ "$volumes" = "yes" ]; then
    while IFS= read -r v; do
      if [ -n "$v" ] && [ -z "$(remove_users "$v" volume)" ]; then
        vols+=("$v")
      fi
    done < <(remove_volumes)
  fi
  if [ "$images" = "yes" ]; then
    mapfile -t imgs < <(remove_images)
  fi
  # compose down would also remove the containers of others with the same project name
  if remove_compose_ok && ! stack_foreign >/dev/null; then
    job_step "Removing the containers"
    info "Removing the containers"
    compose down --remove-orphans || warn "$ENGINE compose down reported an error - removing what is left directly."
  fi
  ids="$(remove_containers | tr '\n' ' ')"
  if [ -n "${ids// /}" ]; then
    # shellcheck disable=SC2086
    "$ENGINE" rm -f $ids >/dev/null 2>&1 || true
  fi
  for v in ${vols[@]+"${vols[@]}"}; do
    job_step "Removing the data volumes"
    if "$ENGINE" volume inspect "$v" >/dev/null 2>&1 && "$ENGINE" volume rm "$v" >/dev/null 2>&1; then
      case "$v" in
        *_npm_data|*_npm_letsencrypt) rm -f -- "$NPM_CERT_FILE" "$NPM_LOGIN_FILE" ;;
        # a failed upgrade has no data left to go back to
        *_db_data) rm -f -- "$UPGRADE_FAILED_FILE" ;;
      esac
    fi
  done
  # Docker lists network IDs, Podman names: rm takes both
  while IFS= read -r v; do
    if [ -n "$v" ]; then
      "$ENGINE" network rm "$v" >/dev/null 2>&1 || true
    fi
  done < <("$ENGINE" network ls -q --filter "label=com.docker.compose.project=$(stack_project)" 2>/dev/null)
  for img in ${imgs[@]+"${imgs[@]}"}; do
    job_step "Removing the images"
    if out="$("$ENGINE" image rm "$(qualify_ref "$img")" 2>&1)"; then
      ok "Image removed: $img"
      gone=$((gone + 1))
    else
      warn "Image kept: $img (${out##*: })"
      kept=$((kept + 1))
    fi
  done
  # what is still there?
  ids="$(remove_containers | tr '\n' ' ')"
  if [ -n "${ids// /}" ]; then
    left="$left containers: $ids;"
  fi
  for v in ${vols[@]+"${vols[@]}"}; do
    if "$ENGINE" volume inspect "$v" >/dev/null 2>&1; then
      left="$left volume $v;"
    fi
  done
  if [ -n "$left" ]; then
    err "Still there:${left%;} - $ENGINE_NAME could not remove it (in use?)."
    return 1
  fi
  ok "Containers$(if [ "${#vols[@]}" -gt 0 ]; then printf ' and %s data volume(s)' "${#vols[@]}"; fi) removed$(if [ "$images" = "yes" ]; then printf ', %s image(s) removed, %s kept' "$gone" "$kept"; fi)."
}

# Worker of the remove task: a last MongoDB backup
remove_backup() {
  require_engine
  mongo_backup
}

# remove_files KEY -> the paths of a file item of the remove task, one per line (only those that
# exist). Of snapshots/ and backups/ only the files the installer writes there.
remove_files() {
  local f
  local -a list=()
  case "$1" in
    files) list=("$WORK_DIR/$ENV_FILE" "$WORK_DIR/$COMPOSE_FILE" "$WORK_DIR/$ENV_FILE".bak-* "$WORK_DIR/$COMPOSE_FILE".bak-*) ;;
    jobs) list=("$JOBS_DIR" "$API_KEY_FILE" "$LOCAL_KEY_FILE" "$TZ_KEEP_FILE" "$UPGRADE_FAILED_FILE" "$NPM_CERT_FILE" "$NPM_LOGIN_FILE" "$SETUP_LATER_FILE" "$PROXY_LOGIN_FILE" "$PROXY_CA_COPY" "$PROXY_CA_BUNDLE") ;;
    snapshots) list=("$WORK_DIR"/snapshots/*.tar.gz "$WORK_DIR"/snapshots/*.tar.gz.part "$WORK_DIR"/snapshots/chain-*.tsv "$WORK_DIR"/snapshots/plan-*.tsv) ;;
    backups) list=("$WORK_DIR"/backups/mongo-*.archive.gz) ;;
    bundles) list=("$WORK_DIR"/RN1-Technology-Catalog-*) ;;
    installer-backups) if [ -n "$SCRIPT_PATH" ]; then list=("$SCRIPT_PATH".bak-*); fi ;;
    installer) if [ -n "$SCRIPT_PATH" ] && [ -f "$SCRIPT_PATH" ]; then list=("$SCRIPT_PATH"); fi ;;
  esac
  for f in ${list[@]+"${list[@]}"}; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      printf '%s\n' "$f"
    fi
  done
}

# True when the job logs show that the stack ran from this folder (started, stopped, upgraded ...)
wiz_ran_here() {
  local f
  for f in "$JOBS_DIR"/[0-9]*/title; do
    if [ -f "$f" ]; then
      case "$(cat -- "$f" 2>/dev/null)" in
        "Start / apply changes"|"Full setup"*|"Install: start"*|"Restart the stack"|"Stop the stack"|"Upgrade to"*|"Go back to"*|"Patch updates"*)
          return 0
          ;;
      esac
    fi
  done
  return 1
}

# Size of the files of a remove_files item
remove_size() {
  local -a list=()
  mapfile -t list < <(remove_files "$1")
  wiz_size ${list[@]+"${list[@]}"}
}

# R: removes the installation from this server - choose what goes, type DELETE, done.
remove_wizard() {
  local -a steps=(Overview Choose Confirm Remove Done) keys=() labels=() picked=() toks=() failed=()
  local jobs id ncont=0 nvol=0 nimg=0 vols="" busy="" lost="" foreign="" foreign_catalog="" choice i tok answer rc ans f key v users
  local copies="" removed="" self_gone="no" vol="no" img="no" anything="no" n files_on="no" keep_env="" since sure="yes" hint

  wiz_head "Remove" 1 "${steps[@]}"
  jobs="$(wiz_running_jobs)"
  if [ -n "$jobs" ]; then
    warn "These background jobs are running:"
    printf '    %s\n' "$jobs"
    if ! confirm "Cancel them first? (each cleans up before it stops)" n; then
      info "Cancelled - wait for the jobs or cancel them with J."
      return 0
    fi
    while IFS= read -r id; do
      job_cancel "$id" || true
    done < <(job_running_ids)
  fi

  # 1. Overview - without the engine nothing can be checked, so nothing is removed
  case "$ENGINE_KIND:$OS_KIND" in
    podman:Darwin) hint=" (podman machine start)" ;;
    podman:*) hint=" as root (run as root)" ;;
    *) hint=" ($(engine_down_hint))" ;;
  esac
  if ! engine_cli; then
    if [ -f "$ENV_FILE" ] || [ -f "$COMPOSE_FILE" ]; then
      err "The $ENGINE command is not found (PATH?) - R cannot check what runs, so nothing was removed."
      return 0
    fi
  elif ! "$ENGINE" info >/dev/null 2>&1 || [ "$(engine_rootless)" != "false" ]; then
    err "$ENGINE_NAME does not answer$hint - R cannot check what runs."
    echo "  R needs $ENGINE_NAME to remove the containers and data; nothing was removed."
    return 0
  else
    foreign_catalog="$(stack_foreign_catalog)" || foreign_catalog=""
    foreign="$(stack_foreign)" || foreign=""
    lost="$(stack_lost)"
    if [ -z "$foreign_catalog" ]; then
      ncont="$(count_lines "$(remove_containers)")"
      while IFS= read -r v; do
        if [ -z "$v" ]; then
          continue
        fi
        users="$(remove_users "$v" volume | tr '\n' ' ')"
        if [ -n "$users" ]; then
          busy="$busy$v (used by ${users% }) "
        else
          vols="$vols$v "
        fi
      done < <(remove_volumes)
      nvol="$(count_lines "$(printf '%s' "$vols" | tr ' ' '\n')")"
      nimg="$(count_lines "$(remove_images)")"
    fi
  fi
  echo "  Found in $WORK_DIR (project $(stack_project)):"
  echo
  printf '   %-34s %s\n' "Containers" "$ncont"
  printf '   %-34s %s\n' "Data volumes" "$nvol"
  if [ -n "$vols" ]; then
    printf '%s\n' "${vols% }" | fold -s -w $(($(settings_width) - 12)) | sed "s/^/      $C_DIM/; s/\$/$C_RST/"
  fi
  printf '   %-34s %s\n' "Images of the stack" "$nimg"
  printf '   %-34s %s\n' "$ENV_FILE, $COMPOSE_FILE" "$(if [ -f "$ENV_FILE" ] || [ -f "$COMPOSE_FILE" ]; then echo yes; else echo no; fi)"
  printf '   %-34s %s\n' "Snapshots (snapshots/)" "$(if [ -n "$(remove_files snapshots)" ]; then remove_size snapshots; else echo none; fi)"
  printf '   %-34s %s\n' "MongoDB backups (backups/)" "$(if [ -n "$(remove_files backups)" ]; then remove_size backups; else echo none; fi)"
  printf '   %-34s %s\n' "Offline bundles" "$(if [ -n "$(remove_files bundles)" ]; then remove_size bundles; else echo none; fi)"
  echo
  if [ -n "$foreign_catalog" ]; then
    warn "Another Catalog installation uses the project name \"$(stack_project)\": $foreign_catalog"
    echo "  Its containers and data volumes have the same names, so R removes no containers, volumes or"
    echo "  images here. Remove that installation with R in its own folder."
    echo
  elif [ -n "$foreign" ]; then
    warn "Containers of another folder use the project name \"$(stack_project)\" too ($foreign) - they are kept."
    echo
  fi
  if [ -n "$busy" ]; then
    warn "Data volumes used by other containers are kept: ${busy% }"
    keep_env="their data needs the passwords in $ENV_FILE"
    echo
  fi
  if [ -n "$lost" ]; then
    warn "A Catalog stack runs from a folder that no longer exists: $(printf '%s' "$lost" | tr '\n' ' ' | sed 's/|/ in /g')"
    echo "  It may be this installation after its folder was renamed - option 23 takes it over."
    keep_env="it may need the passwords in $ENV_FILE"
    echo
  fi
  if [ "$nvol" -gt 0 ] && [ "$ncont" -eq 0 ] && ! wiz_ran_here; then
    sure="no"
    warn "No container and no job log here shows that these data volumes are this folder's - they may"
    echo "  belong to another installation in a folder with the same name. They are not selected."
    keep_env="data volumes with this project name exist"
    echo
  fi
  if [ -z "$foreign_catalog" ] && [ "$nvol" -eq 0 ] && [ -z "$busy" ] && [ -n "$(project_volumes)" ]; then
    warn "$ENGINE_NAME volumes of project \"$(stack_project)\" exist, but nothing here shows they belong to this folder - they are kept."
    echo
  fi
  for key in files jobs snapshots backups bundles installer-backups; do
    if [ -n "$(remove_files "$key")" ]; then
      anything="yes"
    fi
  done
  if [ "$ncont" -eq 0 ] && [ "$nvol" -eq 0 ] && [ "$nimg" -eq 0 ] && [ "$anything" = "no" ]; then
    ok "There is nothing to remove in this folder."
    return 0
  fi
  if [ "$ncont" -gt 0 ] && remove_compose_ok && [ -n "$(running_tag mongo 2>/dev/null)" ]; then
    ans=0
    wiz_yes_no "Take a MongoDB backup first (into backups/)?" n || ans=$?
    if [ "$ans" -eq 2 ]; then
      info "Cancelled - nothing was removed."
      return 0
    fi
    if [ "$ans" -eq 0 ]; then
      since="$(wiz_last_job)"
      rc=0
      wiz_run run_job "MongoDB backup before removing" -- remove_backup || rc=$?
      if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
        rc=0
        wiz_wait_job "MongoDB backup before removing" "$since" || rc=$?
      fi
      if [ "$rc" -eq 3 ]; then
        info "The backup goes on in the background (J). R starts again when it is done."
        return 0
      fi
      if [ "$rc" -ne 0 ]; then
        ans=0
        wiz_yes_no "The backup failed. Remove the Catalog anyway?" n || ans=$?
        if [ "$ans" -ne 0 ]; then
          info "Cancelled - nothing was removed."
          return 0
        fi
      fi
    fi
  fi
  ans=0
  wiz_yes_no "Next: a numbered list to pick what to remove. Go on?" y || ans=$?
  if [ "$ans" -ne 0 ]; then
    info "Cancelled - nothing was removed."
    return 0
  fi

  # 2. Choose: what is selected by default goes; snapshots, backups, bundles and the installer only on request
  if [ "$nvol" -gt 0 ] && [ "$sure" = "yes" ]; then
    keys+=(volumes); labels+=("Data volumes: MongoDB, MinIO, RabbitMQ, OpenSearch, license, certificates ($nvol)"); picked+=(1)
  elif [ "$nvol" -gt 0 ]; then
    keys+=(volumes); labels+=("Data volumes with this project name ($nvol) - not selected: they may be another installation's"); picked+=(0)
  fi
  if [ "$nimg" -gt 0 ]; then
    keys+=(images); labels+=("Images of the stack ($nimg)"); picked+=(1)
  fi
  if [ -n "$(remove_files files)" ]; then
    if [ -n "$keep_env" ]; then
      keys+=(files); labels+=("$ENV_FILE (passwords), $COMPOSE_FILE and their backups - kept: $keep_env"); picked+=(0)
    else
      keys+=(files); labels+=("$ENV_FILE (passwords), $COMPOSE_FILE and their backups"); picked+=(1)
    fi
  fi
  # the removal runs as a job, so its log is there afterwards in any case
  if [ -n "$(remove_files jobs)" ] || [ "$ncont" -gt 0 ] || [ "$nvol" -gt 0 ] || [ "$nimg" -gt 0 ]; then
    keys+=(jobs); labels+=("Job logs, stored API keys and markers"); picked+=(1)
  fi
  if [ -n "$(remove_files snapshots)" ]; then
    keys+=(snapshots); labels+=("Downloaded snapshots ($(remove_size snapshots))"); picked+=(0)
  fi
  if [ -n "$(remove_files backups)" ]; then
    keys+=(backups); labels+=("MongoDB backups ($(remove_size backups))"); picked+=(0)
  fi
  if [ -n "$(remove_files bundles)" ]; then
    keys+=(bundles); labels+=("Offline bundles ($(remove_size bundles))"); picked+=(0)
  fi
  n="$(count_lines "$(remove_files installer-backups)")"
  if [ "$n" -gt 0 ]; then
    keys+=(installer-backups); labels+=("Backups of the installer ($n)"); picked+=(0)
  fi
  if [ -n "$(remove_files installer)" ]; then
    keys+=(installer); labels+=("This installer ($SCRIPT_NAME)"); picked+=(0)
  fi
  # only when no other installation on this server needs them
  if net_proxy_files && [ -z "$(find_installations 2>/dev/null)" ]; then
    keys+=(proxy); labels+=("The internet proxy of the engine, the company certificate in the trust store"); picked+=(1)
  fi
  while true; do
    wiz_head "Remove" 2 "${steps[@]}"
    if [ "$ncont" -gt 0 ]; then
      printf '   %s %s  %s\n' "$C_GRN$UI_ON$C_RST" " " "Containers and networks of the stack ($ncont) $C_DIM(always)$C_RST"
    fi
    for i in "${!keys[@]}"; do
      printf '   %s %s  %s\n' "$(if [ "${picked[i]}" = 1 ]; then printf '%s' "$C_RED$UI_ON$C_RST"; else printf '%s' "$C_DIM$UI_OFF$C_RST"; fi)" "$C_BLD$((i + 1))$C_RST" "${labels[i]}"
    done
    echo
    ui_keys "1-${#keys[@]}|toggle" "A|all" "Enter|continue" "0|cancel"
    ui_ask choice "Toggle, or Enter to continue:" || choice="0"
    case "$choice" in
      "") break ;;
      0) info "Cancelled - nothing was removed."; return 0 ;;
      a|A)
        for i in "${!keys[@]}"; do
          picked[i]=1
        done
        ;;
      *)
        read -r -a toks <<< "$choice"
        for tok in ${toks[@]+"${toks[@]}"}; do
          if [[ "$tok" =~ ^[0-9]{1,2}$ ]]; then
            tok=$((10#$tok))
            if [ "$tok" -ge 1 ] && [ "$tok" -le "${#keys[@]}" ]; then
              picked[tok - 1]=$((1 - picked[tok - 1]))
            fi
          fi
        done
        ;;
    esac
  done
  for i in "${!keys[@]}"; do
    if [ "${picked[i]}" = 1 ]; then
      case "${keys[i]}" in
        volumes) vol="yes" ;;
        images) img="yes" ;;
        files) files_on="yes" ;;
      esac
    fi
  done
  # the data stays: the containers show its versions, which the files must not lower at the next start
  if [ "$ncont" -gt 0 ] && [ "$nvol" -gt 0 ] && [ "$vol" = "no" ] && remove_compose_ok && ! downgrade_guard files stop; then
    return 0
  fi

  # 3. Confirm
  wiz_head "Remove" 3 "${steps[@]}"
  warn "This removes from this server (it cannot be undone):"
  if [ "$ncont" -gt 0 ]; then
    echo "    - the containers and networks of the stack"
  fi
  for i in "${!keys[@]}"; do
    if [ "${picked[i]}" = 1 ]; then
      echo "    - ${labels[i]}"
    fi
  done
  if [ "$files_on" = "yes" ] && { { [ "$nvol" -gt 0 ] && [ "$vol" = "no" ]; } || [ -n "$keep_env" ]; }; then
    echo
    warn "Data stays on this server, but its passwords are in $ENV_FILE: without it the data cannot be used again."
  fi
  echo
  if ! read -r -p "Type DELETE to remove it: " answer || [ "$answer" != "DELETE" ]; then
    echo
    info "Cancelled - nothing was removed."
    return 0
  fi

  # 4. Remove: the engine first; the files only when it removed everything chosen
  wiz_head "Remove" 4 "${steps[@]}"
  if [ "$ncont" -gt 0 ] || [ "$vol" = "yes" ] || [ "$img" = "yes" ]; then
    since="$(wiz_last_job)"
    rc=0
    wiz_run run_job "Remove the Catalog" -- remove_stack "$vol" "$img" || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
      rc=0
      wiz_wait_job "Remove the Catalog" "$since" || rc=$?
    fi
    if [ "$rc" -eq 3 ]; then
      info "The removal goes on in the background (J). R starts again when it is done; choose the items again."
      return 0
    fi
    if [ "$rc" -ne 0 ]; then
      err "$ENGINE_NAME could not remove everything (see above) - the files with the passwords were kept. R tries again."
      return 0
    fi
  fi
  for i in "${!keys[@]}"; do
    if [ "${picked[i]}" != 1 ]; then
      continue
    fi
    case "${keys[i]}" in
      volumes|images) continue ;;
      installer) self_gone="yes" ;;
      proxy)
        if net_proxy_cleanup; then
          removed="$removed engine-proxy"
        else
          failed+=("the internet proxy of the engine")
        fi
        continue
        ;;
    esac
    while IFS= read -r f; do
      if [ -z "$f" ]; then
        continue
      fi
      if rm -rf -- "$f" 2>/dev/null && [ ! -e "$f" ]; then
        removed="$removed $(basename -- "$f")"
      else
        failed+=("$f")
      fi
    done < <(remove_files "${keys[i]}")
    case "${keys[i]}" in
      snapshots) rmdir -- "$WORK_DIR/snapshots" 2>/dev/null || true ;;
      backups) rmdir -- "$WORK_DIR/backups" 2>/dev/null || true ;;
    esac
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    echo
    err "These could not be removed (permissions? sudo may be needed):"
    printf '    %s\n' "${failed[@]}"
    warn "The Catalog was only partly removed - R tries again."
    return 0
  fi

  # 5. Done
  wiz_head "Remove" 5 "${steps[@]}"
  if [ "$ncont" -gt 0 ] || [ "$vol" = "yes" ] || [ "$img" = "yes" ] || [ -n "$removed" ]; then
    ok "The Catalog was removed from this server."
  else
    info "Nothing was removed."
  fi
  if [ -n "$removed" ]; then
    echo "  Files removed:$removed" | fold -s -w $(($(settings_width) - 4))
  fi
  if [ "$self_gone" = "yes" ]; then
    echo
    echo "  The installer was removed too. To install again, run this in $WORK_DIR:"
    echo "  $(install_line)"
    # that line starts an installer that is still in the folder (catalog.sh from before the rename, a copy)
    # instead of downloading a new one; nothing is deleted here that was not chosen
    copies=""
    for f in catalog.sh rn1-technology-catalog-installer.sh; do
      # (the last line that is not blank, as the one-line install reads it: blank lines after it do not matter)
      if [ -f "$WORK_DIR/$f" ] && [ "$(sed -n -e '/[^[:space:]]/h' -e '${x;p;}' "$WORK_DIR/$f" 2>/dev/null)" = 'main "$@"; exit $?' ]; then
        copies="$copies $f"
      fi
    done
    if [ -n "$copies" ]; then
      echo
      echo "  Kept, because it was not chosen: another copy of the installer in this folder:$copies"
      echo "  The line above starts it, with its own settings, instead of downloading a new installer."
      echo "  For a new one, delete it first (in $WORK_DIR: rm$copies)."
    fi
    exit 0
  fi
  echo "  I installs it again; the settings at the top of $SCRIPT_NAME were kept."
}

# ui_fit WIDTH TEXT... -> the first TEXT that fits into WIDTH columns (the last one otherwise)
ui_fit() {
  local width="$1" text=""
  shift
  for text in "$@"; do
    if [ "$(ui_len "$text")" -le "$width" ]; then
      break
    fi
  done
  printf '%s' "$text"
}

# wiz_card KEY KIND STACK-STATE WIDTH [VERSION] -> TITLE|COLOR|LINE1|LINE2 of a card at the top of the menu
# (KIND: what is installed here, see install_kind); short texts when the card has less than 34 characters of
# room. VERSION: the installed one (empty: not known - nothing is installed, the engine does not answer, the files
# are incomplete).
wiz_card() {
  local kind="$2" state="$3" width="$4" target current="${5:-}" l1 l2 n=0 missing things reach="yes"
  case "$1" in
    I)
      if [ "$kind" = "incomplete" ]; then
        if [ ! -f "$ENV_FILE" ] && [ ! -f "$COMPOSE_FILE" ]; then
          missing="no files"
        elif [ ! -f "$ENV_FILE" ]; then
          missing="no .env"
        else
          missing="no compose file"
        fi
        case "$state" in
          [0-9]*" container"*) n="${state%% *}" ;;
        esac
        things="$n containers"
        if [ "$n" -eq 1 ]; then
          things="1 container"
        fi
        if [ "$n" -gt 0 ]; then
          l1="$(ui_fit "$width" "$C_YLW!$C_RST Incomplete: $things, but $missing" "$C_YLW!$C_RST Incomplete: $missing")"
        else
          l1="$C_YLW!$C_RST Incomplete: $missing"
        fi
        if [ ! -f "$ENV_FILE" ] && [ -z "$(newest_env_backup)" ]; then
          # a repair would need new passwords, which do not open the existing data
          l2="$(ui_fit "$width" "put the old .env back first, then repair" "put the old .env back first" "put the old .env back")"
        elif [ "$n" -gt 0 ]; then
          l2="$(ui_fit "$width" "repair: check, write the files again, start" "$things $UI_SEP repair: files, start" "$things $UI_SEP repair")"
        else
          l2="$(ui_fit "$width" "repair: check, write the files again, start" "repair: write the files")"
        fi
        printf '%s|%s|%s|%s' "INSTALL" "$C_GRN" "$l1" "$C_DIM$l2$C_RST"
      elif [ "$kind" = "data" ]; then
        # option 13 removed the containers, the data is kept
        if [ -n "$current" ]; then
          l1="$(ui_fit "$width" "$C_GRN$UI_OK$C_RST Catalog $current $UI_SEP data kept, no containers" "$C_GRN$UI_OK$C_RST Data kept, no containers" "$C_GRN$UI_OK$C_RST Data kept")"
        else
          l1="$(ui_fit "$width" "$C_GRN$UI_OK$C_RST Data kept, no containers" "$C_GRN$UI_OK$C_RST Data kept")"
        fi
        l2="$(ui_fit "$width" "6 starts it again $UI_SEP or repair" "6 starts it again")"
        printf '%s|%s|%s|%s' "INSTALL" "$C_GRN" "$l1" "$C_DIM$l2$C_RST"
      elif [ "$kind" = "files" ]; then
        # option 99, or R that kept the files: a start makes a new Catalog
        l1="$(ui_fit "$width" "$C_YLW$WIZ_TODO$C_RST Not installed: no containers, no data" "$C_YLW$WIZ_TODO$C_RST No containers, no data")"
        l2="$(ui_fit "$width" "6 starts a new, empty Catalog $UI_SEP I installs it step by step" "6 starts a new, empty Catalog" "6 starts a new Catalog")"
        printf '%s|%s|%s|%s' "INSTALL" "$C_GRN" "$l1" "$C_DIM$l2$C_RST"
      elif [ "$kind" != "none" ]; then
        case "$state" in
          "0 service(s) running")
            l1="stopped"
            l2="6 starts it $UI_SEP or repair"
            ;;
          [0-9]*" service(s) running")
            l1="${state%% *} running"
            l2="$(ui_fit "$width" "repair: check, files, start again" "repair: check, start again")"
            ;;
          unknown*)
            l1="$ENGINE_NAME not reachable"
            l2="16 checks the server"
            reach="no"
            ;;
          *)
            l1="no $ENGINE_NAME"
            l2="16 checks the server"
            reach="no"
            ;;
        esac
        if [ -n "$current" ]; then
          l1="$(ui_fit "$width" "$C_GRN$UI_OK$C_RST Catalog $current $UI_SEP $l1" "$C_GRN$UI_OK$C_RST Installed $UI_SEP $l1")"
        elif [ "$reach" = "no" ]; then
          # without the engine, not even whether a Catalog is installed is known
          l1="$C_YLW!$C_RST $l1"
        else
          l1="$C_GRN$UI_OK$C_RST Installed $UI_SEP $l1"
        fi
        printf '%s|%s|%s|%s' "INSTALL" "$C_GRN" "$l1" "$C_DIM$l2$C_RST"
      else
        l1="$(ui_fit "$width" "$C_GRN$UI_RUN$C_RST New installation, step by step" "$C_GRN$UI_RUN$C_RST New installation")"
        l2="$(ui_fit "$width" "engine $UI_SEP domain $UI_SEP proxy $UI_SEP versions" "engine $UI_SEP domain $UI_SEP proxy")"
        printf '%s|%s|%s|%s' "INSTALL" "$C_GRN" "$l1" "$C_DIM$l2$C_RST"
      fi
      ;;
    U)
      target="$LATEST_VERSION"
      if nothing_installed "$kind"; then
        printf '%s|%s|%s|%s' "UPDATE" "$C_YLW" "${C_DIM}Nothing installed yet$C_RST" "${C_DIM}install first (I)$C_RST"
        return 0
      fi
      if [ -z "$current" ]; then
        # which Catalog is installed is not known: no "up to date" for the version of the settings
        l1="$UI_UP Installer and Catalog"
        l2="backup $UI_SEP upgrade $UI_SEP checks"
      elif [ "$HUB_STATUS" = "ok" ] && [ -n "$target" ] && is_version "$current" && version_gt "$target" "$current"; then
        l1="$C_YLW$UI_UP $target$C_RST available"
        l2="backup $UI_SEP upgrade $UI_SEP patches"
      elif [ "$HUB_STATUS" = "ok" ]; then
        l1="$C_GRN$UI_OK$C_RST Catalog up to date"
        l2="installer and patches"
      else
        l1="$UI_UP Installer and Catalog"
        l2="backup $UI_SEP upgrade $UI_SEP checks"
      fi
      if [ "$kind" = "incomplete" ]; then
        l2="repair first (I), then U"
      fi
      printf '%s|%s|%s|%s' "UPDATE" "$C_YLW" "$l1" "$C_DIM$l2$C_RST"
      ;;
    R)
      if [ "$kind" = "none" ]; then
        printf '%s|%s|%s|%s' "REMOVE" "$C_RED" "${C_DIM}Nothing installed$C_RST" "${C_DIM}leftover files only$C_RST"
      elif [ "$kind" = "files" ]; then
        l2="$(ui_fit "$width" "you choose: images $UI_SEP files $UI_SEP backups" "you choose: images, files" "you choose what goes")"
        printf '%s|%s|%s|%s' "REMOVE" "$C_RED" "$C_RED$UI_DEL$C_RST Remove what is left" "$C_DIM$l2$C_RST"
      else
        l2="$(ui_fit "$width" "you choose: data $UI_SEP images $UI_SEP files $UI_SEP backups" "you choose: data, images, files" "you choose what goes")"
        printf '%s|%s|%s|%s' "REMOVE" "$C_RED" "$C_RED$UI_DEL$C_RST Remove from this server" "$C_DIM$l2$C_RST"
      fi
      ;;
  esac
}

# tui_cards COLS STACK-STATE HEIGHT KIND VERSION -> the three cards (4 lines, or a 1-line strip), aligned with
# the columns of the menu below them (KIND and VERSION: what tui_draw found installed - install_kind,
# installed_catalog)
tui_cards() {
  local cols="$1" state="$2" height="$3" here="$4" current="$5" col_w w key title color l1 l2 spec r line inner i
  local -a top=() mid1=() mid2=() bot=() strip=() bare=()
  col_w=$(((cols - 4) / 3))
  w=$((col_w - 2))
  inner=$((w - 2))
  for key in I U R; do
    spec="$(wiz_card "$key" "$here" "$state" $((inner - 2)) "$current")"
    IFS='|' read -r title color l1 l2 <<< "$spec"
    top+=("$C_DIM$UI_TL$UI_H$C_RST $C_BLD$key$C_RST  $color$title$C_RST $C_DIM$(ui_repeat "$UI_H" $((inner - ${#key} - ${#title} - 5)))$UI_TR$C_RST")
    mid1+=("$C_DIM$UI_V$C_RST $(ui_pad "$l1" $((inner - 2))) $C_DIM$UI_V$C_RST")
    mid2+=("$C_DIM$UI_V$C_RST $(ui_pad "$l2" $((inner - 2))) $C_DIM$UI_V$C_RST")
    bot+=("$C_DIM$UI_BL$(ui_repeat "$UI_H" "$inner")$UI_BR$C_RST")
    # one line per card on short terminals; all without the title when one state does not fit
    strip+=("$C_BLD$key$C_RST $color$title$C_RST  $l1")
    bare+=("$C_BLD$key$C_RST $l1")
  done
  if [ "$height" -lt 4 ]; then
    for ((i = 0; i < 3; i++)); do
      if [ "$(ui_len "${strip[i]}")" -gt "$w" ]; then
        strip=("${bare[@]}")
        break
      fi
    done
    printf '  %s  %s  %s\n' "$(ui_pad "${strip[0]}" "$w")" "$(ui_pad "${strip[1]}" "$w")" "$(ui_pad "${strip[2]}" "$w")"
    return 0
  fi
  for r in top mid1 mid2 bot; do
    line=" "
    for ((i = 0; i < 3; i++)); do
      case "$r" in
        top) line="$line ${top[i]} " ;;
        mid1) line="$line ${mid1[i]} " ;;
        mid2) line="$line ${mid2[i]} " ;;
        bot) line="$line ${bot[i]} " ;;
      esac
    done
    printf '%s\n' "$line"
  done
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

  This installer runs the local Catalog with $ENGINE_NAME ($ENGINE compose): catalog-web, four workers, MongoDB,
  OpenSearch with Dashboards, RabbitMQ, MinIO and, optionally, Nginx Proxy Manager.

${c}THE ICONS$r
  $(menu_icon edit)  edit      changes settings or files - nothing is started yet
  $(menu_icon run)  run       does something: generates files, starts or stops containers, downloads, imports
  $(menu_icon view)  view      only shows information
  $(menu_icon del)  delete    removes data - you are asked to type DELETE first

${c}START HERE - GUIDED TASKS$r
$(help_item I run "Install" "New installation, step by step: internet, engine, domain name, Nginx Proxy Manager," "versions, then start and catalog data. Runs by itself on the first start.")
$(help_item U run "Update" "This installer first, then the Catalog: backup, new version, health" "check, patch updates of MongoDB, OpenSearch, RabbitMQ and the others.")
$(help_item R del "Remove" "Removes the Catalog from this server: you choose data, images, files," "snapshots, backups, the installer; then type DELETE.")

${c}SETUP $UI_SEP install on this host$r
$(help_item 7 run "Install in one go" "Generates .env and docker-compose.yml, validates them and starts the stack" "in one go; asks only about existing passwords and the time zone (I guides).")
$(help_item 16 view "Check this server" "$ENGINE_NAME, $ENGINE compose, kernel, ports, vm.max_map_count, time zone, internet.")
$(help_item 23 run "Take over installation" "Takes the settings of an existing installation (another folder, an older" "installer here, or the versions that run here and their .env); data stays.")
$(help_item 26 run "Internet access" "Checks the sites the installation needs (Docker Hub, GitHub, Raynet ...)," "sets the proxy and the company certificate for the engine and the Catalog.")

${c}CONFIGURE $UI_SEP edit settings, 2 writes the files, 6 applies them$r
$(help_item 1 edit "Edit settings" "All settings on one screen, grouped by name (CATALOG_*, MINIO_*," "*_TAG ...); checked before they are saved. E opens them in $(editor_short).")
$(help_item 2 run "Generate .env + compose" "Writes .env and docker-compose.yml from the settings. Passwords are kept;" "asks to align TZ with the server's time zone.")
$(help_item 3 edit "Edit .env" "Shows or edits the generated .env (passwords included). 2 writes it" "again from the settings, so lasting changes belong into the settings (1).")
$(help_item 4 edit "Edit docker-compose.yml" "Shows or edits the generated compose file (2 writes it again).")
$(help_item 5 view "Check the files" "Lets $ENGINE compose check both files ($ENGINE compose config); starts nothing.")

${c}ACCESS $UI_SEP addresses and logins$r
$(help_item 14 view "User names + passwords" "User names and passwords of MongoDB, MinIO, RabbitMQ and Nginx Proxy" "Manager from .env.")
$(help_item 15 view "URLs and proxy setup" "Where Catalog Web and the other services answer, the login of Nginx" "Proxy Manager, and in short how to set up its proxy host by hand.")
$(help_item 24 run "Domain and HTTPS" "The domain name of the Catalog. With Nginx Proxy Manager it also sets up" "the proxy host and a Let's Encrypt certificate, through its API.")
$(help_item 25 run "License / activation" "Shows the license and activates the Catalog (without one it takes no data):" "by order number (needs internet), license file or e-mail; root logs in.")

${c}START & STOP $UI_SEP the containers$r
$(help_item 6 run "Start / apply changes" "$ENGINE compose up -d: starts the stack or applies changed files.")
$(help_item 12 run "Restart the stack" "Restarts all containers; the data is kept.")
$(help_item 13 run "Stop (data is kept)" "$ENGINE compose down; the data volumes are kept.")

${c}MONITOR $UI_SEP is it running well?$r
$(help_item 9 view "Status and health" "$ENGINE compose ps: which containers run and their health.")
$(help_item 10 view "Follow the logs" "Follow the logs of all or one service.")
$(help_item J view "Background jobs" "Long tasks run as jobs: they continue when you leave the menu or the" "SSH session ends. Follow, cancel or read their log here.")

${c}CATALOG DATA $UI_SEP snapshots or a daily self-sync$r
$(help_item 17 run "Download snapshot" "Catalog data from $CATALOG_CLOUD_URL (needs an API key): the full" "snapshot + all changes up to today, the changes since a date, or one file.")
$(help_item 18 edit "API keys" "Shows, changes, tests and deletes the keys for the online and the" "local Catalog. Keys are tested before they are saved.")
$(help_item 19 run "Import snapshot" "Uploads downloaded snapshots into the local Catalog, file by file: full" "import, then delta. Catalog 25.x accepts at most 10 GB per file.")
$(help_item 20 run "Daily self-sync" "Lets the local Catalog synchronize itself every day (servers with" "internet access).")
$(help_item 27 run "System Settings" "Parent feed $CATALOG_CLOUD_URL, conflicts resolved automatically, log level" "Info, and in empty fields the API key and the proxy (the activation does it too).")

${c}UPDATE $UI_SEP newer versions$r
$(help_item 8 run "Versions, offline bundle" "Recommended versions of all components, version picker, and" "\"Download only\": an offline bundle for servers without internet.")
$(help_item 11 run "Pull images" "Downloads the images named in docker-compose.yml (2 writes it from the settings).")
$(help_item 21 run "Upgrade the Catalog" "Backup, new Catalog version, health check, patch updates; goes back" "by itself if you cancel it after the switch.")
$(help_item 22 run "Update this installer" "Newest $SCRIPT_NAME from GitHub; your settings are kept (a new" "download of the installer has the default settings - use 22 instead).")

${c}REMOVE $UI_SEP cannot be undone$r
$(help_item 99 del "Reset: delete all data" "Removes all containers AND all data volumes (type DELETE)." "R removes the Catalog step by step and lets you choose what goes.")

${c}KEYS IN THE MENU$r
  Number + Enter   run an option (the lines above the prompt say what it does while you type)
  I U R            guided tasks           H or ?   this help
  J                jobs
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
    1)  settings_editor ;;
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
    24) run_action domain_menu ;;
    25) run_action license_activate ;;
    26) run_action net_menu ;;
    27) run_action catalog_settings_menu ;;
    99) run_action menu_reset ;;
    j|J) run_action jobs_menu ;;
    i|I) install_wizard ;;
    u|U) update_wizard ;;
    r|R) remove_wizard ;;
    h|H|help|\?) show_help ;;
    *) warn "Unknown option: $1"; return 1 ;;
  esac
}

# COLUMN|KEY|KIND|LABEL|DESCRIPTION|WHAT-IT-DOES - KIND: edit (changes settings or files), run (does
# something), view (only shows information), del (deletes data). The description shows on wide screens,
# WHAT-IT-DOES under the menu while the number is typed. KEY "-" is a heading (COLUMN|-||TITLE|SHORT|WIDE:
# what the group is for), an empty KEY a gap. A new option takes the next free number; numbers are
# never reused, so that an old number never runs something else.
menu_items() {
  cat <<EOF
1|-||SETUP|install on this host|check the server, then install or take over
1|7|run|Install in one go|writes files, checks, starts|Generates both files, validates, starts
1|16|view|Check this server|$ENGINE_NAME, ports, kernel, TZ|Checks $ENGINE_NAME, Compose, kernel, ports, TZ
1|23|run|Take over installation|keeps its passwords and data|Takes over an installation (copies its files)
1|26|run|Internet access|sites, proxy, certificate|Checks the sites; sets proxy and certificate
1|||
1|-||CONFIGURE|settings and files|edit settings - 2 writes the files, 6 applies
1|1|edit|Edit settings|version, ports, proxy, TZ|All settings on one screen; 2 writes the files
1|2|run|Generate .env + compose|from settings; passwords kept|Writes both files; the passwords are kept
1|3|edit|Edit .env|by hand; 2 overwrites it|Opens .env (it holds the passwords)
1|4|edit|Edit docker-compose.yml|by hand; 2 overwrites it|Opens docker-compose.yml in the editor
1|5|view|Check the files|$ENGINE compose config|Lets $ENGINE compose check both files
1|||
1|-||ACCESS|addresses and logins|where to sign in, logins, domain, license
1|14|view|User names + passwords|MongoDB, MinIO, RabbitMQ, NPM|Logins of MongoDB, MinIO, RabbitMQ and NPM
1|15|view|URLs and proxy setup|addresses, NPM login|Addresses of all services, the NPM login
1|24|run|Domain and HTTPS|domain, proxy, Let's Encrypt|Sets the domain, proxy host and certificate
1|25|run|License / activation|order number, file, e-mail|Shows the license, activates the Catalog
2|-||START & STOP|the containers|all containers of this stack
2|6|run|Start / apply changes|starts, or applies new files|$ENGINE compose up -d: starts or applies
2|12|run|Restart the stack|all containers, data kept|Restarts all containers; data is kept
2|13|run|Stop (data is kept)|containers go, data stays|$ENGINE compose down - data volumes stay
2|||
2|-||MONITOR|is it running well?|status, logs and background jobs
2|9|view|Status and health|what runs and is healthy|Which containers run, and their health
2|10|view|Follow the logs|all services or one|Follows the logs of all services or one
2|J|view|Background jobs|follow, cancel, read the log|Long tasks: follow, cancel, read the log
2|||
2|-||CATALOG DATA|snapshots, sync|fill the Catalog: snapshots or a sync
2|17|run|Download snapshot|from Raynet, needs a key|Downloads catalog data (needs an API key)
2|18|edit|API keys|online + local: show, test|Shows, changes and tests the API keys
2|19|run|Import snapshot|full import, then delta|Imports the full snapshot, then the deltas
2|20|run|Daily self-sync|Catalog fetches changes daily|The Catalog synchronizes itself daily
2|27|run|System Settings|parent feed, proxy, log level|Parent feed, auto-resolve, proxy, log level
3|-||UPDATE|newer versions|newer Catalog, components, installer
3|8|run|Versions, offline bundle|pick versions, download only|Recommended versions, picker, offline bundle
3|11|run|Pull images|images in docker-compose.yml|Pulls the images named in docker-compose.yml
3|21|run|Upgrade the Catalog|backup, switch, health check|Backup, new version, health check
3|22|run|Update this installer|from GitHub, settings kept|Newest installer; the settings are kept
3|||
3|-||REMOVE|cannot be undone|deletes data - R removes step by step
3|99|del|Reset: delete all data|containers + volumes; DELETE|Removes ALL containers AND data volumes
3|||
3|-||HELP|every option explained|every option, the keys and the files
3|H|view|Help & about Raynet|every option, keys, files|Explains every option, the keys, Raynet
EOF
}

# menu_entry KEY -> KIND|LABEL|WHAT-IT-DOES of a menu option (1 when there is no such option)
menu_entry() {
  local col key kind label desc what
  while IFS='|' read -r col key kind label desc what; do
    if [ "$key" = "$1" ] && [ "$key" != "-" ]; then
      printf '%s|%s|%s' "$kind" "$label" "$what"
      return 0
    fi
  done <<< "$(menu_items)"
  return 1
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
  local key="$1" kind="$2" label="$3" width="$4" desc="${5:-}" wide="${6:-}" text
  if [ -z "$key" ]; then
    printf '%s' "$(ui_repeat ' ' "$width")"
  elif [ "$key" = "-" ]; then
    if [ "$width" -ge 62 ] && [ -n "$wide" ]; then
      desc="$wide"
    fi
    ui_pad "$C_CYN$label$C_RST$C_DIM${desc:+ $UI_SEP $desc}$C_RST" "$width"
  else
    text="$label"
    if [ "$kind" = "del" ]; then
      text="$C_RED$label$C_RST"
    fi
    if [ "$width" -ge 62 ] && [ -n "$desc" ]; then
      text="$(ui_pad "$text" 25) $C_DIM$desc$C_RST"
    fi
    ui_pad "$C_BLD$(printf '%3s' "$key")$C_RST $(menu_icon "$kind") $text" "$width"
  fi
}

# tui_cell "KEY|KIND|LABEL|DESCRIPTION|WIDE" WIDTH -> one cell of the menu grid (empty: blank)
tui_cell() {
  local key kind label desc more
  if [ -z "$1" ]; then
    printf '%s' "$(ui_repeat ' ' "$2")"
    return 0
  fi
  IFS='|' read -r key kind label desc more <<< "$1"
  tui_item "$key" "$kind" "$label" "$2" "$desc" "$more"
}

tui_draw() {
  reload_settings
  menu_scan
  local tz_note sib cols="$1" rows="${2:-40}" line col key kind label desc what i n col_w found head2 head3 version state here need cards keys cur="" inote rnote="" dnote logo room next ni sni
  local -a c1=() c2=() c3=()
  local notes=() nh
  state="$MENU_STACK"
  here="$(install_kind "$state")"
  if ! nothing_installed "$here"; then
    cur="$(installed_catalog)"
  fi
  # the internet check of the menu start, once it is done (tui_menu draws again then)
  nh="$(net_header)"
  room=$((cols - 4))
  case "$nh" in
    ""|"Internet: "*) ;;
    *) room=$((room - 3 - $(ui_len "$nh"))) ;;
  esac
  if nothing_installed "$here"; then
    # no Catalog here: the version a start would install, the newest when it is newer, what option 2 writes
    # when the files name another one than the settings (install_next_text)
    next="$(next_catalog)"
    ni="Catalog ${C_YLW}not installed$C_RST"
    sni="${C_YLW}Not installed$C_RST"
    if [ "$next" != "$CATALOG_VERSION" ]; then
      head2="$(ui_fit "$room" "$ni $UI_SEP $next would be installed (the files) $UI_SEP ${C_YLW}option 2 writes $CATALOG_VERSION$C_RST" \
        "$sni $UI_SEP $next would be installed $UI_SEP ${C_YLW}option 2 writes $CATALOG_VERSION$C_RST" \
        "$sni $UI_SEP $next (the files) $UI_SEP ${C_YLW}2 writes $CATALOG_VERSION$C_RST" "$sni $UI_SEP $next would be installed" "$sni $UI_SEP $next")"
    elif [ "$HUB_STATUS" = "ok" ] && is_version "$next" && version_gt "$LATEST_VERSION" "$next"; then
      head2="$(ui_fit "$room" "$ni $UI_SEP $next would be installed   $C_YLW$UI_UP $(version_with_tag "$LATEST_VERSION") is newer $UI_SEP option 8$C_RST" \
        "$ni $UI_SEP $next would be installed   $C_YLW$UI_UP $LATEST_VERSION is newer$C_RST" \
        "$sni $UI_SEP $next would be installed   $C_YLW$UI_UP $LATEST_VERSION is newer$C_RST" \
        "$sni $UI_SEP $next   $C_YLW$UI_UP $LATEST_VERSION is newer$C_RST" "$sni   $C_YLW$UI_UP $LATEST_VERSION is newer$C_RST")"
    elif [ "$HUB_STATUS" = "ok" ] && [ "$LATEST_VERSION" = "$next" ]; then
      head2="$(ui_fit "$room" "$ni $UI_SEP $next would be installed (the newest)" "$sni $UI_SEP $next would be installed (the newest)" \
        "$sni $UI_SEP $next would be installed" "$sni $UI_SEP $next")"
    else
      head2="$(ui_fit "$room" "$ni $UI_SEP $next would be installed" "$sni $UI_SEP $next would be installed" "$sni $UI_SEP $next")"
    fi
  elif [ -z "$cur" ]; then
    # the engine cannot tell which Catalog is installed (or the files are incomplete): no status
    head2="Catalog $CATALOG_VERSION $C_DIM(the settings)$C_RST"
  else
    version="$(version_label "$here")"
    head2="Catalog $cur"
    if [[ "$version" == *"update available"* ]]; then
      head2="$head2   $C_YLW$UI_UP ${version#*update available: }$C_RST"
      if [ -n "$LATEST_VERSION" ] && is_version "$cur" && version_gt "$LATEST_VERSION" "$cur"; then
        head2="${head2%, option 8*}$C_YLW $UI_SEP U or option 21$C_RST"
      fi
    elif [[ "$version" == *"up to date"* ]]; then
      head2="$head2   $C_GRN$UI_OK up to date$C_RST"
    fi
  fi
  head3="Folder $WORK_DIR"
  if [ -n "$COMPOSE_PROJECT_NAME" ]; then
    head3="$head3 $UI_SEP project $COMPOSE_PROJECT_NAME"
  fi
  head3="$head3 $UI_SEP .env $(if [ -f "$ENV_FILE" ]; then printf '%s' "$C_GRN$UI_OK$C_RST"; else printf '%s' "$C_YLW$UI_NO missing$C_RST"; fi)"
  head3="$head3 $UI_SEP compose $(if [ -f "$COMPOSE_FILE" ]; then printf '%s' "$C_GRN$UI_OK$C_RST"; else printf '%s' "$C_YLW$UI_NO missing$C_RST"; fi)"
  case "$state" in
    *" exist"*) head3="$head3 $UI_SEP $state" ;;
    *) head3="$head3 $UI_SEP stack $state" ;;
  esac
  if [ ! -f "$ENV_FILE" ]; then
    found="$(first_installation_dir)"
    if [ -n "$found" ]; then
      notes+=("$C_YLW$UI_ARROW An installation exists in $found - option 23 takes it over$C_RST")
    fi
  fi
  case "$nh" in
    "") ;;
    "Internet: "*) notes+=("$C_YLW$UI_ARROW $nh$C_RST") ;;
    *) head2="$head2   $C_GRN$nh$C_RST" ;;
  esac
  # (with nothing installed there is nothing to go back to)
  if [ -f "$UPGRADE_FAILED_FILE" ] && ! nothing_installed "$here"; then
    notes+=("$C_YLW$UI_ARROW The last upgrade did not become healthy - option 21 can go back$C_RST")
  fi
  inote="$(install_note)"
  if [ -n "$inote" ]; then
    notes+=("$(ui_fit $((cols - 4)) "$C_YLW$UI_ARROW $inote - option 23 takes the installation's values over$C_RST" "$C_YLW$UI_ARROW $inote - option 23 takes them over$C_RST")")
  else
    rnote="$(raise_note)"
    if [ -n "$rnote" ]; then
      notes+=("$(ui_fit $((cols - 4)) "$C_YLW$UI_ARROW $rnote$C_RST" "$C_YLW$UI_ARROW ${rnote%% - *} - U upgrades it with a backup, 23 keeps it$C_RST" "$C_YLW$UI_ARROW ${rnote%% - *} - U upgrades it$C_RST")")
    fi
  fi
  sib="$(conflicting_sibling)"
  if [ -n "$sib" ]; then
    notes+=("$C_YLW$UI_ARROW $(basename -- "$sib") in this folder has other settings - option 23 takes them over$C_RST")
  elif [ -n "$inote$rnote" ]; then
    :
  elif mongo_kernel_problem; then
    notes+=("$C_YLW$UI_ARROW MongoDB needs the kernel workaround, the files lack it - option 2 or I (repair) adds it$C_RST")
  elif mongo_workaround_unneeded; then
    notes+=("$C_YLW$UI_ARROW This kernel no longer needs the MongoDB workaround - option 2 writes the files again$C_RST")
  elif settings_stale; then
    dnote="$(install_diff_note)"
    if [ -n "$dnote" ]; then
      notes+=("$(ui_fit $((cols - 4)) "$C_YLW$UI_ARROW $dnote - option 23 takes the installation's values over, option 2 writes the settings$C_RST" "$C_YLW$UI_ARROW $dnote - 23 takes them over, 2 writes the settings$C_RST" "$C_YLW$UI_ARROW The settings differ from the installation - 23 takes its values over, 2 writes the settings$C_RST")")
    elif files_older; then
      notes+=("$(ui_fit $((cols - 4)) "$C_YLW$UI_ARROW The files are from an older installer and differ from the settings - option 2 regenerates them$C_RST" "$C_YLW$UI_ARROW The files are from an older installer - option 2 regenerates them$C_RST")")
    else
      notes+=("$C_YLW$UI_ARROW The generated files differ from the settings - option 2 regenerates them$C_RST")
    fi
  fi
  if [ -z "$inote" ] && tz_note="$(tz_menu_note)" && [ -n "$tz_note" ]; then
    notes+=("$C_YLW$UI_ARROW $tz_note$C_RST")
  fi
  clear_screen
  col_w=$(( (cols - 4) / 3 ))
  while IFS='|' read -r col key kind label desc what; do
    # headings carry their wide text in the last field, entries the line shown while typing
    if [ "$key" != "-" ]; then
      what=""
    fi
    case "$col" in
      1) c1+=("$key|$kind|$label|$desc|$what") ;;
      2) c2+=("$key|$kind|$label|$desc|$what") ;;
      3) c3+=("$key|$kind|$label|$desc|$what") ;;
    esac
  done < <(menu_items)
  n=${#c1[@]}
  if [ ${#c2[@]} -gt "$n" ]; then
    n=${#c2[@]}
  fi
  if [ ${#c3[@]} -gt "$n" ]; then
    n=${#c3[@]}
  fi
  # all of it must end above the "Current processes" box (the last 10 rows): on a short terminal
  # the legend moves into the prompt line, then the cards shrink to one line
  need=$((4 + ${#notes[@]} + 1 + 4 + 1 + n + 3 + (${#TUI_NOTICE} > 0 ? 1 : 0)))
  cards=4
  TUI_COMPACT="no"
  # the logo and a blank line above it all only when the full menu still fits below them
  logo="no"
  if [ "$cols" -ge 80 ] && [ $((need + ${#UI_LOGO[@]} + 1)) -le $((rows - 10)) ]; then
    logo="yes"
  fi
  if [ "$need" -gt $((rows - 10)) ]; then
    TUI_COMPACT="yes"
    need=$((need - 3))
  fi
  if [ "$need" -gt $((rows - 10)) ]; then
    cards=1
  fi
  if [ "$logo" = "yes" ]; then
    ui_logo "$cols"
    echo
  fi
  ui_box "$cols" "RAYNET ONE TECHNOLOGY CATALOG $UI_SEP Installation Portal" "$head2" "$head3" ${notes[@]+"${notes[@]}"}
  echo
  tui_cards "$cols" "$state" "$cards" "$here" "$cur"
  echo
  for ((i = 0; i < n; i++)); do
    printf '  %s%s%s\n' "$(tui_cell "${c1[i]:-}" "$col_w")" "$(tui_cell "${c2[i]:-}" "$col_w")" "$(tui_cell "${c3[i]:-}" "$col_w")"
  done
  if [ "$TUI_COMPACT" = "no" ]; then
    echo
    printf '  %s\n' "$(menu_legend)"
    keys="Number + Enter runs it $UI_SEP I U R guided tasks $UI_SEP H help $UI_SEP J jobs $UI_SEP Tab next process $UI_SEP hold X cancel process $UI_SEP Q quit"
    if [ "$(ui_len "$keys")" -gt $((cols - 2)) ]; then
      keys="Number + Enter runs it $UI_SEP I U R guided tasks $UI_SEP H help $UI_SEP J jobs $UI_SEP hold X cancel $UI_SEP Q quit"
    fi
    printf '  %s\n' "$C_DIM$keys$C_RST"
  fi
  menu_scan_done
}
TUI_COMPACT="no"

# tui_draw_hint COLS ROWS TYPED -> the two lines above the prompt: what the typed number does
# (left of the Current processes box)
tui_draw_hint() {
  local cols="$1" rows="$2" buf="$3" w kind="" label="" what="" l1 l2=""
  w=$((cols - 52))
  if [ -z "$buf" ]; then
    l1="${C_DIM}Type a number - what it does shows here$C_RST"
  elif [ "$buf" = "0" ]; then
    l1="${C_BLD}0$C_RST Exit"
    l2="${C_DIM}Leaves the menu; running jobs go on$C_RST"
  else
    IFS='|' read -r kind label what <<< "$(menu_entry "$buf" || true)"
    if [ -z "$label" ]; then
      l1="${C_YLW}No option $buf$C_RST"
    elif [ "$kind" = "del" ]; then
      l1="$C_BLD$buf$C_RST $(menu_icon "$kind") $C_RED$label - asks for DELETE$C_RST"
      l2="$C_DIM$what$C_RST"
    else
      l1="$C_BLD$buf$C_RST $(menu_icon "$kind") $label"
      l2="$C_DIM$what$C_RST"
    fi
  fi
  printf '\0337\033[%d;3H%s\033[%d;3H%s\0338' $((rows - 3)) "$(ui_pad "$l1" "$w")" $((rows - 2)) "$(ui_pad "$l2" "$w")"
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
  local cols rows key buf="" redraw=1 last_box=0 now ids next rest held=0 hint_for
  while true; do
    if [ "$redraw" = 1 ]; then
      cols="$(ui_cols)"
      rows="$(ui_rows)"
      if [ "$cols" -lt 100 ] || [ "$rows" -lt 36 ]; then
        return 2
      fi
      tui_draw "$cols" "$rows"
      if [ -n "$TUI_NOTICE" ]; then
        printf '  %s\n' "$C_GRN$UI_OK $TUI_NOTICE$C_RST"
        TUI_NOTICE=""
      fi
      redraw=0
      last_box=0
      UI_BEAT_LAST=""
      hint_for="-"
    fi
    now="$(ui_now_ms)"
    if [ "$UI_HOLD_PCT" -gt 0 ]; then
      tui_draw_hold
      held=1
    elif [ $((now - last_box)) -ge 1000 ] || [ "$held" = 1 ]; then
      tui_draw_box "$cols" "$rows"
      last_box="$now"
      held=0
      if net_background_done; then
        redraw=1
        continue
      fi
      # a menu left open: the check again once its result is older than NET_CACHE_TTL
      net_background_start
    fi
    if [ "$buf" != "$hint_for" ]; then
      tui_draw_hint "$cols" "$rows" "$buf"
      hint_for="$buf"
    fi
    # padded up to the Current processes box instead of erasing the rest of the line
    printf '\033[%d;3H%s Select: %-*s\033[%d;%dH' $((rows - 1)) "$C_CYN$UI_ARROW$C_RST" $((cols - 62)) "$buf" $((rows - 1)) $((13 + ${#buf}))
    if [ "$TUI_COMPACT" = "yes" ]; then
      printf '\0337\033[%d;%dH%s\0338' $((rows - 1)) $((cols - 44)) "${C_DIM}I U R guided tasks $UI_SEP H help $UI_SEP J jobs $UI_SEP Q quit$C_RST"
    fi
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
      i|I) tui_run I; redraw=1 ;;
      u|U) tui_run U; redraw=1 ;;
      r|R) tui_run R; redraw=1 ;;
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
  case "$1" in
    1) ;;
    H)
      if ! command -v less >/dev/null 2>&1; then
        echo
        pause
      fi
      ;;
    *)
      echo
      pause
      ;;
  esac
  ui_noecho
}

menu() {
  local choice note below notice="${RVC_NOTICE:-}" resume="${1:-}"
  INTERACTIVE="true"
  TUI_NOTICE="$notice"
  unset RVC_NOTICE
  trap 'printf "\n"' INT

  # the first start in a new folder begins with the new installation, which also sets up the engine;
  # an installation, or a folder with its engine chosen, gets its prerequisites first: without the engine
  # nothing can run (both only in a terminal)
  if [ -z "$resume" ] && [ -z "$notice" ] && [ -t 0 ] && [ -t 1 ] && wiz_first_start; then
    install_wizard first || true
    echo
    read -r -p "Press Enter to open the menu..." choice || true
  elif [ -n "$CONTAINER_ENGINE" ] || [ "$(install_state)" != "no" ]; then
    engine_offer
  fi
  # settings older than the installation here (a new download of the installer has its defaults): its
  # values are offered before anything else can write the files or start the containers with them
  note="$(install_note)"
  # (not when the take-over of a new download just said what it did, and asked about the backups: the menu shows the note)
  if [ -n "$note" ] && [ -z "$AUTO_TAKEOVER_SAID" ]; then
    echo
    warn "$note."
    adopt_installation interactive || true
    echo
    pause
  fi
  # the internet check runs in the background; the header shows it when it is done
  net_background_start

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

  if [ "$resume" = "resume-update" ]; then
    clear_screen
    update_wizard 2 "$notice" || true
    notice=""
    TUI_NOTICE=""
    echo
    pause
  fi

  if ui_fancy; then
    trap 'tput cnorm 2>/dev/null || true; stty echo 2>/dev/null || true' EXIT
    ui_noecho
    tui_menu || true
    ui_echo
  fi

  while true; do
    net_background_start
    clear_screen
    # below the menu: the notices, the running processes, the keys and the prompt
    below=$((2 + (${#notice} > 0 ? 2 : 0) + (${#TUI_NOTICE} > 0 ? 2 : 0)))
    if [ -n "$SCRIPT_PATH" ]; then
      choice="$(job_running_ids)"
      if [ -n "$choice" ]; then
        below=$((below + 2 + $(count_lines "$choice")))
      fi
    fi
    show_menu "$below"
    if [ -n "$notice" ]; then
      ok "$notice"
      echo
      notice=""
      TUI_NOTICE=""
    fi
    if [ -n "$TUI_NOTICE" ]; then
      ok "$TUI_NOTICE"
      echo
      TUI_NOTICE=""
    fi
    if [ -n "$SCRIPT_PATH" ] && [ -n "$(job_running_ids)" ]; then
      echo " Running processes (J shows, follows and cancels them):"
      while IFS= read -r choice; do
        printf '   #%s %s  %s\n' "$choice" "$(cat -- "$JOBS_DIR/$choice/title")" "$(job_summary "$choice")"
      done < <(job_running_ids)
      echo
    fi
    printf '  %s\n' "${C_DIM}I install $UI_SEP U update $UI_SEP R remove $UI_SEP H help $UI_SEP 0 exit$C_RST"
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
    if [ "$choice" != "1" ]; then
      echo
      pause
    fi
  done
}

usage() {
  cat <<EOF
Usage: ./$SCRIPT_NAME [command]

Without a command, an interactive menu is shown. The first start in a new folder begins with the
new installation (engine, domain, proxy, versions); 0 at any of its questions opens the menu.

Commands:
  menu                        Interactive menu (default)
  generate [--new-passwords]  Write $ENV_FILE and $COMPOSE_FILE.
                              Existing passwords are kept unless --new-passwords is given.
  validate                    Check the configuration ($ENGINE compose config)
  up                          Validate and start / update the stack ($ENGINE compose up -d)
  setup                       generate + validate + up
  status                      Show container status ($ENGINE compose ps)
  health [SECONDS]            Wait until every service runs and Catalog Web answers
  install-podman              Install Podman and the newest Docker Compose (the engine of podman compose)
  install-docker              Install Docker Engine with its Compose plugin (macOS: Docker Desktop)
  install-engine              Install the engine CONTAINER_ENGINE names (Podman, Docker or Colima)
  logs [service]              Follow the logs of all services or of one service
  pull                        Pull the images
  restart                     Restart all containers
  down                        Stop and remove the containers (data volumes are kept)
  credentials                 Show the generated credentials
  info                        Show URLs and the Nginx Proxy Manager login
  domain [NAME|-]             Domain name and HTTPS: saves it (- removes it), applies it, sets up the
                              proxy host and a Let's Encrypt certificate in Nginx Proxy Manager
  license [status|file PATH|order|text]
                              The license of the Catalog: status (no login), or activation by the
                              license file, the order number (needs internet) or the license text of
                              Raynet's e-mail (a site administrator logs in); without one: as option 25
  settings                    System Settings of the Catalog as option 27: parent feed, automatic conflict
                              resolving, log level Info, the API key and the proxy (an administrator logs in)
  check                       Check prerequisites ($ENGINE_NAME, $ENGINE compose, ports, vm.max_map_count, Docker Hub)
  network-check               Check the sites the installation needs, directly or through INTERNET_PROXY;
                              exit code 0 when every required one answers (no questions; option 26 asks)
  network-hosts               The sites (host:port) the installation needs, for a firewall request
  timezone                    Use the time zone of this server for TZ (the job times are converted)
  updates                     Show available updates for all components
  upgrade                     Guided upgrade (asks first, then runs as a background job)
  self-update [--no-menu]     Update this installer from GitHub (settings kept), then open the menu
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
  local cmd="${1:-}" answer
  if [ "$#" -gt 0 ]; then
    shift
  fi
  cd -- "$WORK_DIR"
  case "$cmd" in
    check-settings|__cron_convert|__settings_groups|__server_hostname|__settings_hash) ;;
    # the release check of CI reads Docker Hub only: the proxy of the settings, no container engine
    __recommended_catalog) proxy_load ;;
    *)
      # the proxy of the settings for every download of this run (and the programs it starts)
      proxy_load
      resolve_engine
      ;;
  esac

  # a new download takes the values of the installation here over before anything else (auto_takeover) - not
  # for the help, the hooks and the jobs, nor for adopt and self-update, which take or carry settings over
  # themselves (the new installer of a self-update does it at its start)
  # The report of a command goes to stderr: what these commands print is read by scripts and written to files
  # (credentials > file, info, versions, network-hosts); only the menu, which is a screen, has it on stdout.
  case "$cmd" in
    ""|menu)
      if [ "$cmd" = "menu" ] || { [ -t 0 ] && [ -t 1 ]; }; then
        if auto_takeover interactive; then
          echo
          # (a pause on input that is not a terminal would take a line the menu is meant to read)
          if [ -t 0 ]; then
            read -r -p "Press Enter to open the menu..." answer || true
          fi
        fi
      else
        auto_takeover cli >&2 || true
      fi
      ;;
    generate|validate|config|up|start|setup|install|status|ps|logs|pull|restart|down|stop|credentials|creds|info|urls|\
    domain|license|check|network-check|network-hosts|timezone|tz|install-podman|install-docker|install-engine|health|updates|\
    upgrade|download|snapshot|import-chain|import|versions|set-version)
      auto_takeover cli >&2 || true
      ;;
  esac

  case "$cmd" in
    "")
      if [ -t 0 ] && [ -t 1 ]; then
        menu
      else
        warn "No terminal detected - running 'generate' (existing passwords are kept). See './$SCRIPT_NAME help'."
        do_generate keep
      fi
      ;;
    menu) menu "${1:-}" ;;
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
    setup|install)
      engine_guard
      downgrade_guard settings
      upgrade_guard settings
      if ! mem_ask confirm; then
        info "Cancelled."
        return 0
      fi
      do_generate keep no-next; echo; do_up
      ;;
    status|ps) do_status ;;
    logs) do_logs "${1:-}" ;;
    pull) do_pull ;;
    restart) do_restart ;;
    down|stop) do_down ;;
    credentials|creds) show_credentials ;;
    info|urls) show_access_info ;;
    domain) domain_menu "${1:-}" ;;
    license) license_cli "$@" ;;
    settings) catalog_settings_menu ;;
    check) do_check ;;
    network-check) net_cli_check ;;
    network-hosts) net_hosts_text ;;
    __net) net_test_hook "$@" ;;
    timezone|tz) timezone_cli ;;
    install-podman) engine_cli_setup podman ;;
    install-docker) engine_cli_setup docker ;;
    install-engine) engine_setup yes ;;
    health) require_files && require_engine && stack_health "${1:-$HEALTH_TIMEOUT}" ;;
    __cron_convert) cron_convert "$@"; echo ;;
    __settings_groups) settings_grouped "$SCRIPT_PATH" ;;
    __menu_items) menu_items ;;
    __engine) printf '%s %s %s\n' "$ENGINE" "$ENGINE_KIND" "$ENGINE_NAME" ;;
    __health_pct) health_pct "$@"; echo; health_web_text "${3:-}"; echo ;;
    __engine_choices) engine_choices ;;
    __engine_choose) engine_choose "${1:-}" ;;
    __wiz_engine_pick) wiz_engine_pick "$(engine_choices)" "${1:-}"; echo ;;
    __choose_versions) choose_versions ;;
    # the release check (tests/check_release_default.sh): the Catalog the versions screen of a new installation
    # selects, the one behind the stable tag ("-" without one), and whether CATALOG_VERSION exists for the
    # Catalog and its worker ("listed" or "missing"); 1 when Docker Hub cannot be read
    __recommended_catalog)
      fetch_hub_versions || return 1
      printf '%s %s %s\n' "$(recommended_catalog)" "${HUB_STABLE:--}" "$(if grep -qxF -- "$CATALOG_VERSION" <<< "$HUB_VERSIONS"; then echo listed; else echo missing; fi)"
      ;;
    # the value of SETTINGS_PUBLISHED_SUM for the settings section of this file (or of FILE), for the maintainer
    # after a change of the defaults and for tests/check_settings_hash.sh
    __settings_hash)
      answer="${1:-$SCRIPT_PATH}"
      case "$answer" in
        /*) ;;
        *) answer="$CALL_DIR/$answer" ;;
      esac
      if ! settings_sum "$answer"; then
        err "${1:-$SCRIPT_NAME} has no settings section from '# CONFIGURE ONLY THIS SECTION' to '# DO NOT CHANGE ANYTHING BELOW'."
        return 1
      fi
      echo
      ;;
    __domain_normalize) domain_normalize "${1:-}"; echo ;;
    __server_hostname) server_hostname; echo ;;
    __domain_checks) domain_checks "${1:-}"; echo "DOMAIN_DNS=$DOMAIN_DNS" ;;
    updates) show_updates_cli ;;
    upgrade) INTERACTIVE="true"; do_upgrade ;;
    self-update)
      case "${1:-}" in
        ""|--no-menu) ;;
        *)
          err "Unknown option for self-update: $1 (only --no-menu)"
          return 2
          ;;
      esac
      update_installer cli
      # in the foreground of a terminal the menu of the (new) installer opens right away;
      # --no-menu, cron, pipes and runs in the background (timeout, &) just end
      if [ "${1:-}" != "--no-menu" ] && ui_foreground; then
        if [ "$INSTALLER_UPDATED" = "yes" ]; then
          export RVC_NOTICE="Installer updated - your settings were kept."
        else
          export RVC_NOTICE="The installer is up to date."
        fi
        exec "$BASH" "$SCRIPT_PATH" menu
      fi
      ;;
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
    import) import_snapshot "${1:-}" cli || exit $? ;;
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
