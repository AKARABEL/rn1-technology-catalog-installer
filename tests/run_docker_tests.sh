#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/dk"
rm -rf "$T"; mkdir -p "$T/bin" "$T/pbin" "$T/impbin" "$T/state" "$T/inst"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# the internet check (menu start, new installation, option 16, engine setup) has its own suite (run_network_tests)
export RN1_NET_CHECK=off
# openSUSE and SLES: Docker comes from the distribution, the newest Compose from GitHub (more sudo steps)
docker_distro_host() { grep -qiE '^ID(_LIKE)?=.*(suse|sles)' /etc/os-release 2>/dev/null; }
# LOG: the calls of one case. BAD: calls the fakes do not know, for the whole suite.
export LOG="$T/calls.log" ST="$T/state" BAD="$T/bad.log" SUDO_LOG="$T/sudo.log"
: > "$LOG"; : > "$BAD"; : > "$SUDO_LOG"

# Fake Docker 29 with the Compose plugin, and its quirks: "Docker version 29.9.0, build ...", rootless
# only in the security options of docker info, short image names in .Config.Image, .Name with a leading /,
# network ls -q prints IDs, image IDs with sha256:, "docker compose" is the CLI plugin (DOCKER_HOST is
# passed on). Podman's "volume exists", "image exists", "machine" and "save --format" are unknown here.
# State: $ST/up = the containers exist (mongo, catalog-web, worker-search, started from the folder in
# $ST/wd), $ST/net = the network of the project, $ST/vols = the volumes inst_db_data and inst_minio_storage
# (minus $ST/vols.rm), $ST/images = the local images as Docker names them (mongo:8, ghcr.io/...).
# SHIM_DOCKER_SHIM: docker is Podman's emulation (podman-docker). SHIM_DOCKER_DOWN: the daemon does not
# answer. SHIM_DOCKER_ROOTLESS: rootless Docker. SHIM_NO_COMPOSE: no Compose plugin. SHIM_COMPOSE_DISTRO: the
# Compose of the distribution (its version without the v). SHIM_SAVE_OLD: docker save without --platform.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
echo "docker $ARGS" >> "$LOG"
bad() { echo "UNHANDLED docker $ARGS" | tee -a "$LOG" >> "$BAD"; echo "docker: unknown command: docker $ARGS" >&2; exit 125; }
running() { [ -f "$ST/up" ]; }
wdir() { cat "$ST/wd" 2>/dev/null || printf '%s' "$PWD"; }
proj() { basename -- "$(wdir)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'; }
tag() { local t; t="$(cat "$ST/catalog_tag" 2>/dev/null)"; printf '%s' "${t:-25.4.4191.133}"; }
IDS="a1b2c3d4e5f6 b2c3d4e5f6a7 c3d4e5f6a7b8"
svc_of() { case "$1" in a1b2c3d4e5f6) echo mongo ;; b2c3d4e5f6a7) echo catalog-web ;; c3d4e5f6a7b8) echo worker-search ;; esac; }
img_of() {
  case "$1" in
    a1b2c3d4e5f6) echo "mongo:$(cat "$ST/mongo_tag" 2>/dev/null || echo 8)" ;;
    b2c3d4e5f6a7) echo "raynetgmbh/rayventory-catalog:$(tag)" ;;
    c3d4e5f6a7b8) echo "raynetgmbh/rayventory-catalog-worker:$(tag)" ;;
  esac
}
is_ct() { running && [[ " $IDS " == *" $1 "* ]]; }
norm() { local r="${1#docker.io/library/}"; printf '%s' "${r#docker.io/}"; }
img_id() { printf 'sha256:%s' "$(printf '%s' "$(norm "$1")" | sha256sum | cut -c1-64)"; }
img_here() { grep -qxF -- "$(norm "$1")" "$ST/images" 2>/dev/null; }
img_add() { grep -qxF -- "$(norm "$1")" "$ST/images" 2>/dev/null || norm "$1" >> "$ST/images"; echo >> "$ST/images"; sed -i '/^$/d' "$ST/images"; }
VOLS="inst_db_data inst_minio_storage"
vol_exists() { [ -f "$ST/vols" ] && [[ " $VOLS " == *" $1 "* ]] && ! grep -qxF -- "$1" "$ST/vols.rm" 2>/dev/null; }
envval() { sed -n "s/^$1=//p" "${ENVF:-.env}" 2>/dev/null | tail -n 1 | tr -d '"'; }
rp() { local r=""; while [[ "$out" == *"$1"* ]]; do r="$r${out%%"$1"*}$2"; out="${out#*"$1"}"; done; out="$r$out"; }
match() {
  case "$2" in
    label=com.docker.compose.project=*) [ "${2#*project=}" = "$(proj)" ] ;;
    label=com.docker.compose.service=*) [ "${2#*service=}" = "$(svc_of "$1")" ] ;;
    volume=*) [ "$1" = a1b2c3d4e5f6 ] && [ "${2#volume=}" = "$(proj)_db_data" ] ;;
    ancestor=*) [ "${2#ancestor=}" = "$(img_id "$(img_of "$1")")" ] ;;
    *) bad ;;
  esac
}
if [ "${1:-}" = --version ]; then
  if [ -n "${SHIM_DOCKER_SHIM:-}" ]; then echo "podman version 5.7.0"; else echo "Docker version 29.9.0, build 1a2b3c4"; fi
  exit 0
fi
# podman-docker: the installer must refuse it before it uses it
[ -n "${SHIM_DOCKER_SHIM:-}" ] && bad
case "$ARGS" in
  "save --help")
    if [ -n "${SHIM_SAVE_OLD:-}" ]; then echo "Usage:  docker save [OPTIONS] IMAGE [IMAGE...]  -o, --output string"
    else echo "Usage:  docker image save [OPTIONS] IMAGE [IMAGE...]  -o, --output string  --platform string"; fi
    exit 0 ;;
  "context show") echo default; exit 0 ;;
  "compose version")
    [ -n "${SHIM_NO_COMPOSE:-}" ] && { echo "docker: unknown command: docker compose" >&2; exit 1; }
    if [ -n "${SHIM_COMPOSE_DISTRO:-}" ]; then echo "Docker Compose version 2.40.3+ds1-0ubuntu1~24.04.1"; exit 0; fi
    echo "Docker Compose version v2.40.3"; exit 0 ;;
esac
[ -n "${SHIM_DOCKER_DOWN:-}" ] && { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1; }
case "${1:-}" in
  info)
    case "$ARGS" in
      info) echo "Client: Docker Engine - Community" ;;
      "info --format {{range .SecurityOptions}}{{.}} {{end}}")
        printf 'name=apparmor name=seccomp,profile=builtin name=cgroupns %s\n' "$(if [ -n "${SHIM_DOCKER_ROOTLESS:-}" ]; then echo name=rootless; fi)" ;;
      "info --format {{.KernelVersion}}") echo "${SHIM_KERNEL:-6.8.0-generic}" ;;
      "info --format {{.MemTotal}}") echo "${SHIM_MEMTOTAL:-34359738368}" ;;
      *) bad ;;
    esac ;;
  ps)
    shift; filters=(); quiet=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -a|--all) ;;
        -q|--quiet|-aq|-qa) quiet=1 ;;
        --filter) filters+=("$2"); shift ;;
        *) bad ;;
      esac
      shift
    done
    [ -n "$quiet" ] || bad
    running || exit 0
    for id in $IDS; do
      ok=1
      for f in ${filters[@]+"${filters[@]}"}; do match "$id" "$f" || ok=0; done
      [ "$ok" = 1 ] && echo "$id"
    done ;;
  container)
    { [ "${2:-}" = inspect ] && [ "${3:-}" = --format ] && [ $# -ge 5 ]; } || bad
    fmt="$4"; shift 4; rc=0
    for id in "$@"; do
      if ! is_ct "$id"; then echo "Error response from daemon: No such container: $id" >&2; rc=1; continue; fi
      wd="$(wdir)"; out="$fmt"
      rp '{{index .Config.Labels "com.docker.compose.project"}}' "$(proj)"
      rp '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$wd"
      rp '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$wd/docker-compose.yml"
      rp '{{index .Config.Labels "com.docker.compose.project.environment_file"}}' "$wd/.env"
      rp '{{index .Config.Labels "com.docker.compose.service"}}' "$(svc_of "$id")"
      rp '{{.Config.Image}}' "$(img_of "$id")"
      rp '{{.Name}}' "/$(proj)-$(svc_of "$id")-1"
      rp '{{.State.Status}}' running
      rp '{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}' none
      rp '{{.RestartCount}}' 0
      rp '{{.State.OOMKilled}}' false
      case "$out" in *'{{'*) bad ;; esac
      printf '%s\n' "$out"
    done
    exit "$rc" ;;
  events)
    # the oom events of the stack (Docker clears OOMKilled when the container starts again): none here
    case "$ARGS" in
      "events --since "*" --until "*" --filter type=container --filter event=oom --filter label=com.docker.compose.project=$(proj) --format {{index .Actor.Attributes \"com.docker.compose.service\"}}") ;;
      *) bad ;;
    esac ;;
  exec)
    shift
    is_ct "${1:-}" || { echo "Error response from daemon: No such container: ${1:-}" >&2; exit 1; }
    [ "$1" = a1b2c3d4e5f6 ] || bad
    shift
    case "$*" in
      "mongod --version") echo "db version v8.0.12" ;;
      "sh -c "*) printf 'MONGODUMP-ARCHIVE' ;;
      *) bad ;;
    esac ;;
  rm)
    { [ "${2:-}" = -f ] && [ $# -ge 3 ]; } || bad
    shift 2
    for id in "$@"; do is_ct "$id" || { echo "Error response from daemon: No such container: $id" >&2; exit 1; }; done
    rm -f "$ST/up"
    printf '%s\n' "$@" ;;
  volume)
    case "${2:-}" in
      ls)
        { [ $# -eq 5 ] && [ "$3" = -q ] && [ "$4" = --filter ]; } || bad
        case "$5" in label=com.docker.compose.project=*) ;; *) bad ;; esac
        if [ "${5#*project=}" = inst ]; then
          for v in $VOLS; do vol_exists "$v" && echo "$v"; done
        fi ;;
      inspect)
        [ $# -eq 3 ] || bad
        vol_exists "$3" || { echo "[]"; echo "Error response from daemon: get $3: no such volume" >&2; exit 1; }
        printf '[{"Name": "%s", "Driver": "local"}]\n' "$3" ;;
      rm)
        [ $# -eq 3 ] || bad
        vol_exists "$3" || { echo "Error response from daemon: get $3: no such volume" >&2; exit 1; }
        echo "$3" >> "$ST/vols.rm"
        left=""; for v in $VOLS; do vol_exists "$v" && left=1; done
        [ -n "$left" ] || rm -f "$ST/vols" "$ST/vols.rm"
        echo "$3" ;;
      *) bad ;;
    esac ;;
  network)
    case "${2:-}" in
      ls)
        { [ $# -eq 5 ] && [ "$3" = -q ] && [ "$4" = --filter ]; } || bad
        [ -f "$ST/net" ] && [ "${5#*project=}" = "$(proj)" ] && echo "9e8d7c6b5a40" ;;
      rm)
        [ $# -eq 3 ] || bad
        case "$3" in 9e8d7c6b5a40|"$(proj)_default") rm -f "$ST/net"; echo "$3" ;; *) echo "Error response from daemon: network $3 not found" >&2; exit 1 ;; esac ;;
      *) bad ;;
    esac ;;
  image)
    case "${2:-}" in
      inspect)
        if [ $# -eq 3 ]; then
          img_here "$3" || { echo "[]"; echo "Error response from daemon: No such image: $3" >&2; exit 1; }
          printf '[{"Id": "%s", "RepoTags": ["%s"]}]\n' "$(img_id "$3")" "$(norm "$3")"
          exit 0
        fi
        { [ $# -eq 5 ] && [ "$3" = --format ]; } || bad
        img_here "$5" || { echo "Error response from daemon: No such image: $5" >&2; exit 1; }
        case "$4" in '{{.ID}}') img_id "$5" ;; '{{.Size}}') echo 300000 ;; *) bad ;; esac ;;
      rm)
        [ $# -eq 3 ] || bad
        img_here "$3" || { echo "Error response from daemon: No such image: $3" >&2; exit 1; }
        for id in $IDS; do
          if running && [ "$(img_of "$id")" = "$(norm "$3")" ]; then
            echo "Error response from daemon: conflict: unable to remove repository reference \"$3\" (must force) - container $id is using its referenced image" >&2
            exit 1
          fi
        done
        grep -vxF -- "$(norm "$3")" "$ST/images" > "$ST/images.new"; mv "$ST/images.new" "$ST/images"
        echo "Untagged: $(norm "$3")" ;;
      *) bad ;;
    esac ;;
  pull)
    shift; quiet=""
    while [ $# -gt 1 ]; do
      case "$1" in -q|--quiet) quiet=1; shift ;; --platform) [ "$2" = linux/amd64 ] || bad; shift 2 ;; *) bad ;; esac
    done
    img_add "$1"
    [ -n "$quiet" ] || echo "Status: Downloaded newer image for $(norm "$1")" >&2
    echo "$1" ;;
  save)
    shift; out=""
    while [ $# -gt 1 ]; do
      case "$1" in
        -o|--output) out="$2"; shift 2 ;;
        --platform) { [ -z "${SHIM_SAVE_OLD:-}" ] && [ "$2" = linux/amd64 ]; } || bad; shift 2 ;;
        *) bad ;;
      esac
    done
    [ -n "$out" ] || bad
    img_here "$1" || { echo "Error response from daemon: No such image: $1" >&2; exit 1; }
    { echo "IMAGE $(norm "$1") $(img_id "$1")"; head -c 300000 /dev/zero; } > "$out" ;;
  load)
    { [ "${2:-}" = -i ] && [ $# -eq 3 ]; } || bad
    read -r magic ref id < "$3"
    [ "$magic" = IMAGE ] || { echo "Error: unrecognized image format" >&2; exit 1; }
    img_add "$ref"
    echo "Loaded image: $ref" ;;
  tag)
    [ $# -eq 3 ] || bad
    img_add "$3" ;;
  compose)
    shift
    [ -n "${SHIM_NO_COMPOSE:-}" ] && { echo "docker: unknown command: docker compose" >&2; exit 1; }
    echo "ENV DOCKER_HOST=${DOCKER_HOST-unset} provider=${PODMAN_COMPOSE_PROVIDER-unset} warn=${PODMAN_COMPOSE_WARNING_LOGS-unset}" >> "$LOG"
    ENVF=".env"; CF="docker-compose.yml"
    while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; --env-file) ENVF="$2"; shift 2 ;; -f) CF="$2"; shift 2 ;; *) break ;; esac; done
    sub="${1:-}"; [ $# -gt 0 ] && shift
    case "$sub" in
      config)
        case "$*" in
          --services) printf '%s\n' mongo catalog-web worker-search ;;
          --volumes) printf '%s\n' db_data minio_storage ;;
          --images) sed -n 's/^    image: *//p' "$CF" | while IFS= read -r out; do
              re='[$][{]([A-Za-z_][A-Za-z0-9_]*)[}]'
              while [[ "$out" =~ $re ]]; do v="${BASH_REMATCH[1]}"; rp "\${$v}" "$(envval "$v")"; done
              printf '%s\n' "$out"
            done ;;
          --quiet|"") ;;
          *) bad ;;
        esac ;;
      ps)
        case "$*" in
          "-q "*|"-a -q "*)
            # -a: stopped containers too - these exist only while the stack runs
            if [ "$1" = -a ]; then shift; fi
            [ $# -eq 2 ] || bad
            if running; then case "$2" in mongo) echo a1b2c3d4e5f6 ;; catalog-web) echo b2c3d4e5f6a7 ;; worker-search) echo c3d4e5f6a7b8 ;; esac; fi ;;
          "--services --filter status=running") running && printf '%s\n' mongo catalog-web worker-search ;;
          "") echo "NAME STATUS"; running && printf '%s\n' "inst-mongo-1 Up" "inst-catalog-web-1 Up" "inst-worker-search-1 Up" ;;
          *) bad ;;
        esac ;;
      pull|logs) ;;
      restart) [ "$*" = "-t 30" ] || bad ;;
      down)
        case "$*" in "--remove-orphans"|"-v --remove-orphans") ;; *) bad ;; esac
        rm -f "$ST/up" "$ST/net" ;;
      up)
        [ "$*" = "-d --remove-orphans" ] || bad
        touch "$ST/up" "$ST/net" "$ST/vols"; rm -f "$ST/vols.rm"
        printf '%s\n' "mongo:$(envval MONGO_TAG)" "$(envval CATALOG_IMAGE)" "$(envval CATALOG_WORKER_IMAGE)" > "$ST/images"
        envval CATALOG_IMAGE | sed 's/.*://' > "$ST/catalog_tag"
        envval MONGO_TAG > "$ST/mongo_tag"
        printf '%s\n' "$PWD" > "$ST/wd" ;;
      *) bad ;;
    esac ;;
  *) bad ;;
esac
exit 0
EOF
# Podman next to Docker (only on the PATH where a case puts $T/pbin first): SHIM_PODMAN_DATA=PROJECT -
# Podman holds a container and a volume of that project. SHIM_PODMAN_VERSION: its version.
cat > "$T/pbin/podman" <<'EOF'
#!/usr/bin/env bash
a="$*"
echo "podman $a" >> "$LOG"
case "$a" in
  --version) echo "podman version ${SHIM_PODMAN_VERSION:-5.7.0}" ;;
  info) echo "host: (fake)" ;;
  "info --format {{.Host.Security.Rootless}}") echo false ;;
  "info --format {{.Host.MemTotal}}") echo "${SHIM_MEMTOTAL:-34359738368}" ;;
  "ps -aq --filter label=com.docker.compose.project="*)
    if [ "${a##*=}" = "${SHIM_PODMAN_DATA:-}" ]; then echo 7f7f7f7f7f7f; fi ;;
  "volume ls -q --filter label=com.docker.compose.project="*)
    if [ "${a##*=}" = "${SHIM_PODMAN_DATA:-}" ]; then echo "${a##*=}_db_data"; fi ;;
  *) echo "UNHANDLED podman $a" | tee -a "$LOG" >> "$BAD"; echo "Error: the fake podman does not know: $a" >&2; exit 125 ;;
esac
exit 0
EOF
# the Docker Compose of "podman compose" (for the Podman cases)
printf '#!/usr/bin/env bash\ncase "$*" in version) echo "Docker Compose version v5.6.0" ;; "version --short") echo 5.6.0 ;; *) echo "UNHANDLED provider $*" >> "$BAD"; exit 1 ;; esac\n' > "$T/pbin/docker-compose"
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-enabled docker.service") if [ -n "${SHIM_DOCKER_DISABLED:-}" ]; then echo disabled; exit 1; fi; echo enabled ;;
  "enable --now docker") ;;
  "is-active --quiet podman.socket") ;;
  "is-active --quiet docker") [ -n "${SHIM_DOCKER_ACTIVE:-}" ] ;;
  "is-enabled podman-restart.service") echo enabled ;;
  *) echo "UNHANDLED systemctl $*" | tee -a "$LOG" >> "$BAD"; exit 1 ;;
esac
EOF
# Catalog Web answers; Docker Hub is offline; GitHub has Docker Compose v5.6.0 (binary and .sha256)
printf '#!/bin/sh\ncase "$*" in version) echo "Docker Compose version v5.6.0" ;; "version --short") echo 5.6.0 ;; "ls -q") ;; esac\n' > "$T/compose-v5.6.0"
chmod +x "$T/compose-v5.6.0"
export COMPOSE_BIN="$T/compose-v5.6.0"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; fmt=""; url=""; head=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -D|-H|-K|--connect-timeout|--max-time|--retry|--retry-delay|--proto|-X) shift 2 ;;
    --*) shift ;;
    -*) [[ "$1" == *I* ]] && head=1; shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $url" >> "$LOG"
gh=https://github.com/docker/compose/releases
case "$url" in
  http://localhost:*) [ -n "$fmt" ] && printf '%s' "${fmt//%\{http_code\}/200}"; exit 0 ;;
  "$gh/latest") [ "$head" = 1 ] || exit 22; printf 'HTTP/2 302\r\nlocation: %s/tag/v5.6.0\r\n\r\n' "$gh" ;;
  "$gh/download/v5.6.0/docker-compose-linux-x86_64") cat "$COMPOSE_BIN" > "${out:-/dev/stdout}" ;;
  "$gh/download/v5.6.0/docker-compose-linux-x86_64.sha256")
    printf '%s *docker-compose-linux-x86_64\n' "$(sha256sum < "$COMPOSE_BIN" | cut -c1-64)" > "${out:-/dev/stdout}" ;;
  *) exit 7 ;;
esac
EOF
cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$SUDO_LOG"
case "${1:-}" in
  sh) ;;
  *) exec "$@" ;;
esac
EOF
REAL_UNAME="$(command -v uname)"
cat > "$T/bin/uname" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  -r) echo "\${SHIM_KERNEL:-6.8.0-generic}" ;;
  -m) echo "\${SHIM_ARCH:-x86_64}" ;;
  *) exec "$REAL_UNAME" "\$@" ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${SHIM_TZ:-Europe/Berlin}"\n' > "$T/bin/timedatectl"
# import-images.sh only: id -u says SHIM_UID
printf '#!/usr/bin/env bash\nif [ "$*" = "-u" ]; then echo "${SHIM_UID:-0}"; elif [ "$*" = "-un" ]; then echo user; else exec %s "$@"; fi\n' "$(command -v id)" > "$T/impbin/id"
chmod +x "$T/bin/"* "$T/pbin/"* "$T/impbin/"*

# a PATH without the real podman, docker and Compose of this machine (CI runners have Docker)
sysdirs="$PATH"
if command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
  mkdir -p "$T/sys"
  IFS=: read -r -a dirs <<< "$sysdirs"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      n="${f##*/}"
      case "$n" in podman|docker|docker-compose|dockerd|colima) continue ;; esac
      [ -e "$T/sys/$n" ] || ln -s "$f" "$T/sys/$n" 2>/dev/null || true
    done
  done
  sysdirs="$T/sys"
fi
export PATH="$T/bin:$sysdirs" HOME="$T/home" RN1_COMPOSE_PROVIDER="$T/cli/docker-compose" RN1_SYSTEMD_DIR="$T"
mkdir -p "$HOME"
PPATH="$T/pbin:$PATH"

D="$T/inst"
I="$D/rn1-technology-catalog-installer.sh"
# fresh ENGINE: a new folder whose installer has CONTAINER_ENGINE="ENGINE" (empty: not chosen)
fresh() {
  rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$NEW" "$I"
  sed -i "s/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=\"${1-docker}\"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES=\"false\"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT=\"10\"/" "$I"
  : > "$LOG"; : > "$SUDO_LOG"
}
# installed: the files, and a running stack of Catalog 25.4 in Docker started from this folder (the version named
# here: the default is the newest Catalog of the release)
installed() {
  fresh "${1-docker}"
  sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/' "$I"
  (cd "$D" && bash "$I" generate </dev/null >/dev/null 2>&1)
  touch "$ST/up" "$ST/net" "$ST/vols"; echo 25.4.4191.133 > "$ST/catalog_tag"; echo 8 > "$ST/mongo_tag"; echo "$D" > "$ST/wd"
  printf '%s\n' mongo:8 raynetgmbh/rayventory-catalog:25.4.4191.133 raynetgmbh/rayventory-catalog-worker:25.4.4191.133 > "$ST/images"
  : > "$LOG"
}
mask() { sed -E 's/^((MONGO_INITDB_ROOT|MINIO_ROOT|NPM_ADMIN)_PASSWORD|RABBITMQ_DEFAULT_PASS)=.*/\1=X/' "$1"; }
MUTATING='compose.* (down|up)|^docker (rm|volume rm|network rm|image rm) '

# 1. The generated files are the same for Docker and Podman
fresh docker
(cd "$D" && bash "$I" generate </dev/null >/dev/null 2>&1)
P="$T/pod"; rm -rf "$P"; mkdir -p "$P"; sed 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE="podman"/' "$NEW" > "$P/gen.sh"
# the fake Podman (same SHIM_MEMTOTAL as the fake Docker): without it the cache of MongoDB would come from the
# MemTotal of this machine, not from the memory of the engine
(cd "$P" && PATH="$PPATH" bash gen.sh generate </dev/null >/dev/null 2>&1)
check "the same .env and docker-compose.yml as with Podman" '[ -s "$D/.env" ] && diff <(mask "$D/.env") <(mask "$P/.env") >/dev/null && cmp -s "$D/docker-compose.yml" "$P/docker-compose.yml"'
if ! { diff <(mask "$D/.env") <(mask "$P/.env") && diff "$D/docker-compose.yml" "$P/docker-compose.yml"; } > "$T/gen.diff" 2>&1; then
  sed 's/^/  docker|podman: /' "$T/gen.diff"
fi
check "generate does not touch a container" '! grep -Eq "$MUTATING" "$LOG"'

# 2. Compose commands: docker compose with the pinned files; DOCKER_HOST is kept, nothing of Podman is set
: > "$LOG"
out="$(cd "$D" && DOCKER_HOST=unix:///var/run/docker-alt.sock bash "$I" up </dev/null 2>&1)"; rc=$?
check "up: docker compose up -d --remove-orphans with --env-file and -f" '[ "$rc" -eq 0 ] && grep -q "^docker compose --env-file .env -f docker-compose.yml up -d --remove-orphans$" "$LOG" && grep -q "Starting the stack (docker compose up -d --remove-orphans)" <<< "$out"'
check "up: DOCKER_HOST reaches Docker Compose, no Podman provider or banner setting" 'grep -q "^ENV " "$LOG" && [ -z "$(grep "^ENV " "$LOG" | grep -vxF "ENV DOCKER_HOST=unix:///var/run/docker-alt.sock provider=unset warn=unset")" ]'
check "up: no podman call" '! grep -q "^podman" "$LOG"'
check "addresses: the firewall note names Docker's DOCKER-USER chain" 'grep -q "DOCKER-USER iptables chain" <<< "$out" && ! grep -q "Podman forwards" <<< "$out"'
: > "$LOG"
(cd "$D" && bash "$I" validate </dev/null >/dev/null 2>&1 && bash "$I" status </dev/null >/dev/null 2>&1 && bash "$I" logs mongo </dev/null >/dev/null 2>&1 \
  && bash "$I" pull </dev/null >/dev/null 2>&1 && bash "$I" restart </dev/null >/dev/null 2>&1); rc=$?
check "validate, status, logs, pull, restart: docker compose" '[ "$rc" -eq 0 ] && grep -q "^docker compose .* config --quiet$" "$LOG" && grep -q "^docker compose .* ps$" "$LOG" && grep -q "^docker compose .* logs -f --tail=200 mongo$" "$LOG" && grep -q "^docker compose .* pull$" "$LOG" && grep -q "^docker compose .* restart -t 30$" "$LOG"'

# 3. Health: every service runs and Catalog Web answers
out="$(cd "$D" && bash "$I" health 10 </dev/null 2>&1)"; rc=$?
check "health: all services run, Catalog Web answers" '[ "$rc" -eq 0 ] && grep -q "All 3 services run and Catalog Web answers" <<< "$out" && grep -q "^docker container inspect --format {{.State.Status}}" "$LOG"'

# 4. Check (option 16)
out="$(cd "$D" && bash "$I" check </dev/null 2>&1)"
check "check: Docker, its daemon rootful, docker compose, all required checks" 'grep -q "Container engine: Docker$" <<< "$out" && grep -q "OK Docker 29.9.0" <<< "$out" && grep -q "The Docker daemon answers and runs rootful" <<< "$out" && grep -q "Compose: docker compose with Docker Compose version v2.40.3" <<< "$out" && grep -q "All required checks passed" <<< "$out"'
check "check: nothing about Podman" '! grep -qi "podman" <<< "$out"'
out="$(cd "$D" && SHIM_DOCKER_DISABLED=1 bash "$I" check </dev/null 2>&1)"
check "check: docker.service not enabled is named" 'grep -q "docker.service is not enabled" <<< "$out" && grep -q "systemctl enable --now docker" <<< "$out"'
out="$(cd "$D" && bash "$I" __menu_items 2>&1; bash "$I" help 2>&1)"
check "menu and help name docker compose" 'grep -q "docker compose down - data volumes stay" <<< "$out" && grep -q "Check the configuration (docker compose config)" <<< "$out" && ! grep -q "podman compose" <<< "$(grep -v install-podman <<< "$out")"'

# 5. R removes the stack from Docker: compose down, the volumes, the network by its ID, the images
installed docker
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: overview counts the containers, volumes and images in Docker" 'grep -q "Containers  *3" <<< "$out" && grep -q "Data volumes  *2" <<< "$out" && grep -q "Images of the stack  *3" <<< "$out"'
check "remove: docker compose down, volumes one by one (checked with volume inspect)" 'grep -q "^docker compose --env-file .env -f docker-compose.yml down --remove-orphans$" "$LOG" && grep -q "^docker volume inspect inst_db_data$" "$LOG" && grep -q "^docker volume rm inst_db_data$" "$LOG" && grep -q "^docker volume rm inst_minio_storage$" "$LOG" && [ ! -f "$ST/vols" ]'
check "remove: images by their qualified names, checked with image inspect" '[ "$(grep -c "^docker image rm " "$LOG")" -eq 3 ] && grep -q "^docker image rm docker.io/library/mongo:8$" "$LOG" && [ ! -s "$ST/images" ]'
check "remove: files gone, the Catalog removed" '[ ! -f "$D/.env" ] && grep -q "The Catalog was removed from this server" <<< "$out"'
installed docker
rm -f "$D/docker-compose.yml"
out="$(printf 'r\ny\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "remove without a compose file: docker rm -f, the network by the ID docker network ls prints" 'grep -q "^docker rm -f a1b2c3d4e5f6 b2c3d4e5f6a7 c3d4e5f6a7b8 *$" "$LOG" && grep -q "^docker network rm 9e8d7c6b5a40$" "$LOG" && [ ! -f "$ST/net" ] && [ ! -f "$ST/up" ] && ! grep -q "compose.* down" "$LOG"'
installed docker
mkdir -p "$D/backups"
out="$(printf 'r\ny\ny\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: the MongoDB backup runs with docker exec in the mongo container" 'grep -q "^docker exec a1b2c3d4e5f6 sh -c" "$LOG" && ls "$D"/backups/mongo-*.archive.gz >/dev/null 2>&1'

# 6. Offline bundle with Docker: pull for linux/amd64, docker save, the image IDs without sha256:
fresh docker
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8.0.12"/' "$I"
: > "$ST/images"
out="$(cd "$D" && bash "$I" download </dev/null 2>&1)"; rc=$?
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | grep -v 'tar.gz' | head -n 1)"
MID="$(printf '%s' mongo:8.0.12 | sha256sum | cut -c1-64)"
check "download: rc 0, every image pulled qualified for linux/amd64" '[ "$rc" -eq 0 ] && [ -n "$B" ] && grep -q "^docker pull --platform linux/amd64 docker.io/library/mongo:8.0.12$" "$LOG" && [ "$(grep -c "^docker pull --platform linux/amd64 " "$LOG")" -eq 8 ]'
check "download: docker save -o with --platform linux/amd64" 'grep -q "^docker save --platform linux/amd64 -o .*/images/mongo_8\.0\.12\.tar docker\.io/library/mongo:8\.0\.12$" "$LOG" && ! grep -q "^docker save --format" "$LOG"'
check "download: images.txt with the image ID without sha256:" 'grep -q "^mongo:8\.0\.12|images/mongo_8\.0\.12\.tar|$MID$" "$B/images.txt"'
check "download: the bundled installer names no engine (the target finds its own)" 'grep -q "^CONTAINER_ENGINE=\"\"$" "$B/rn1-technology-catalog-installer.sh" && grep -q "^CONTAINER_ENGINE=\"docker\"$" "$I"'
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"
out="$(cd "$D" && SHIM_SAVE_OLD=1 bash "$I" download </dev/null 2>&1)"; rc=$?
check "download: a docker save without --platform is called without it" '[ "$rc" -eq 0 ] && grep -q "^docker save -o .*/images/mongo_8\.0\.12\.tar docker\.io/library/mongo:8\.0\.12$" "$LOG"'
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | grep -v 'tar.gz' | head -n 1)"

# 7. import-images.sh on a Docker server: no root needed, docker load, the daemon enabled, Compose only when missing
X="$T/target"; rm -rf "$X"; mkdir -p "$X"; cp -r "$B" "$X/"; NB="$(basename "$B")"
: > "$ST/images"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$T/impbin:$PATH" SHIM_UID=1000 RN1_COMPOSE_TARGET="$T/target-compose" ./import-images.sh 2>&1)"; rc=$?
check "import: the Docker of this server found, not root, all loaded" '[ "$rc" -eq 0 ] && grep -q "Container engine: docker" <<< "$out" && grep -q "8 image(s) loaded, 0 failed" <<< "$out" && [ "$(grep -c "^docker load -i images/" "$LOG")" -eq 8 ] && grep -q "^docker image inspect docker.io/library/mongo:8.0.12$" "$LOG"'
check "import: not root - the daemon and Compose are left alone" '! grep -q "^systemctl enable" "$LOG" && [ ! -e "$T/target-compose" ]'
: > "$ST/images"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$T/impbin:$PATH" SHIM_UID=0 RN1_COMPOSE_TARGET="$T/target-compose" ./import-images.sh 2>&1)"; rc=$?
check "import as root: Docker's daemon enabled, its own Compose plugin kept" '[ "$rc" -eq 0 ] && grep -q "^systemctl enable --now docker$" "$LOG" && ! grep -q "podman" "$LOG" && [ ! -e "$T/target-compose" ]'
: > "$ST/images"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$T/impbin:$PATH" SHIM_UID=0 SHIM_NO_COMPOSE=1 RN1_COMPOSE_TARGET="$T/target-compose" ./import-images.sh 2>&1)"; rc=$?
check "import as root, Docker without Compose: the Compose of the bundle installed" '[ "$rc" -eq 0 ] && grep -qF "OK Docker Compose installed: $T/target-compose" <<< "$out" && cmp -s "$T/target-compose" "$COMPOSE_BIN"'
: > "$ST/images"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$T/impbin:$T/pbin:$PATH" SHIM_UID=1000 SHIM_COMPOSE_DISTRO=1 ./import-images.sh 2>&1)"; rc=$?
check "import: Podman installed, no engine named - Podman is taken (it needs root)" '[ "$rc" -ne 0 ] && grep -q "Run it as root (sudo ./import-images.sh): the Catalog runs in the Podman of root" <<< "$out" && ! grep -q "^docker load" "$LOG"'
sed -i 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE="docker"/' "$X/$NB/rn1-technology-catalog-installer.sh"
: > "$ST/images"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$T/impbin:$T/pbin:$PATH" SHIM_UID=0 SHIM_COMPOSE_DISTRO=1 RN1_COMPOSE_TARGET="$T/target-compose2" ./import-images.sh 2>&1)"; rc=$?
check "import: the engine the installer names (docker) wins over an installed Podman" '[ "$rc" -eq 0 ] && grep -q "Container engine: docker" <<< "$out" && ! grep -q "^podman load" "$LOG"'
check "import: the Compose of the distribution (2.40.3+ds1, no v) counts as Docker's own" '[ ! -e "$T/target-compose2" ]'

# 8. What the installer refuses: podman-docker, rootless Docker, a Docker that does not answer, no Compose
installed docker
out="$(cd "$D" && SHIM_DOCKER_SHIM=1 bash "$I" up </dev/null 2>&1)"; rc=$?
check "podman-docker (docker is Podman) refused" '[ "$rc" -ne 0 ] && grep -q "'"'"'docker'"'"' on this machine is Podman (podman-docker), not Docker" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG"'
out="$(cd "$D" && SHIM_DOCKER_SHIM=1 bash "$I" check </dev/null 2>&1)"
check "check: podman-docker named as a problem" 'grep -q "is Podman (podman-docker), not Docker" <<< "$out" && ! grep -q "All required checks passed" <<< "$out"'
out="$(cd "$D" && SHIM_DOCKER_ROOTLESS=1 bash "$I" up </dev/null 2>&1)"; rc=$?
check "rootless Docker refused" '[ "$rc" -ne 0 ] && grep -q "Docker runs rootless here; the Catalog needs the rootful Docker daemon" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG"'
out="$(cd "$D" && SHIM_DOCKER_DOWN=1 bash "$I" up </dev/null 2>&1)"; rc=$?
check "Docker daemon down: says how to start it" '[ "$rc" -ne 0 ] && grep -q "Docker does not answer (docker info failed) - start the daemon (systemctl enable --now docker)" <<< "$out"'
out="$(cd "$D" && SHIM_NO_COMPOSE=1 bash "$I" validate </dev/null 2>&1)"; rc=$?
check "Docker without the Compose plugin: refused with the install command" '[ "$rc" -ne 0 ] && grep -q "Docker Compose (.docker compose.) is missing or too old - .*install-docker" <<< "$out"'
out="$(cd "$D" && SHIM_COMPOSE_DISTRO=1 bash "$I" validate </dev/null 2>&1)"; rc=$?
check "the Compose of the distribution (version 2.40.3+ds1, without the v) is taken" '[ "$rc" -eq 0 ] && grep -q "^docker compose .* config --quiet$" "$LOG"'
# the Docker snap: docker is a link to /usr/bin/snap
mkdir -p "$T/snapbin" "$T/snapsys"
printf '#!/usr/bin/env bash\nexec "%s/bin/docker" "$@"\n' "$T" > "$T/snapsys/snap"; chmod +x "$T/snapsys/snap"
ln -sf "$T/snapsys/snap" "$T/snapbin/docker"
: > "$LOG"; : > "$SUDO_LOG"
out="$(cd "$D" && PATH="$T/snapbin:$PATH" bash "$I" up </dev/null 2>&1)"; rc=$?
check "the Docker snap: up refused, it says how to replace it" '[ "$rc" -ne 0 ] && grep -q "Docker is installed as a snap, which the Catalog cannot use" <<< "$out" && grep -q "snap remove docker" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG"'
out="$(cd "$D" && PATH="$T/impbin:$T/snapbin:$PATH" SHIM_UID=1000 bash "$I" install-docker </dev/null 2>&1)"; rc=$?
check "the Docker snap: install-docker refused, no systemctl enable" '[ "$rc" -ne 0 ] && grep -q "installed as a snap" <<< "$out" && [ ! -s "$SUDO_LOG" ]'
out="$(cd "$D" && PATH="$T/snapbin:$PATH" bash "$I" check </dev/null 2>&1)"
check "the Docker snap: check names it, no docker.service warning" 'grep -q "installed as a snap" <<< "$out" && ! grep -q "docker.service is not enabled" <<< "$out" && ! grep -q "All required checks passed" <<< "$out"'

# 9. One engine per server: the data of this project in the other engine stops up, setup, upgrade and the setup of the engine
installed docker
rm -f "$ST/up" "$ST/vols" "$ST/net"; : > "$LOG"
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" up </dev/null 2>&1)"; rc=$?
check "Docker folder, data in Podman: up refused, nothing started" '[ "$rc" -ne 0 ] && grep -q "project \"inst\" are in Podman, but this folder uses Docker" <<< "$out" && grep -q "CONTAINER_ENGINE=\"podman\"" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG"'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" setup </dev/null 2>&1)"; rc=$?
check "setup refused before the files are written" '[ "$rc" -ne 0 ] && grep -q "are in Podman" <<< "$out" && ! grep -q "Writing" <<< "$out"'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" upgrade </dev/null 2>&1)"; rc=$?
check "upgrade refused" '[ "$rc" -ne 0 ] && grep -q "are in Podman" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG"'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" install-docker </dev/null 2>&1)"; rc=$?
check "install-docker refused (it would remove Podman on RHEL)" '[ "$rc" -ne 0 ] && grep -q "are in Podman" <<< "$out" && [ ! -s "$SUDO_LOG" ]'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" check </dev/null 2>&1)"
check "check names the data in the other engine as a problem" 'grep -q "are in Podman, but this folder uses Docker" <<< "$out" && ! grep -q "All required checks passed" <<< "$out"'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=other bash "$I" up </dev/null 2>&1)"; rc=$?
check "another project in Podman does not count" '[ "$rc" -eq 0 ] && grep -q "Stack is up" <<< "$out"'
installed podman
out="$(cd "$D" && PATH="$PPATH" RN1_COMPOSE_PROVIDER="$T/pbin/docker-compose" bash "$I" up </dev/null 2>&1)"; rc=$?
check "Podman folder, data in Docker: up refused" '[ "$rc" -ne 0 ] && grep -q "project \"inst\" are in Docker, but this folder uses Podman" <<< "$out" && ! grep -q "compose.* up" "$LOG"'
cs="$(cksum < "$I")"
out="$(cd "$D" && PATH="$PPATH" bash "$I" __engine_choose docker </dev/null 2>&1)"; rc=$?
check "engine_choose: Docker holds the data - docker can be chosen" '[ "$rc" -eq 0 ] && grep -q "^CONTAINER_ENGINE=\"docker\"$" "$I"'
sed -i 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE="docker"/' "$I"
out="$(cd "$D" && PATH="$PPATH" bash "$I" __engine_choose podman </dev/null 2>&1)"; rc=$?
check "engine_choose: podman refused while Docker holds the data" '[ "$rc" -ne 0 ] && grep -q "Podman cannot be used here: The containers or data volumes of this installation are in Docker" <<< "$out" && grep -q "^CONTAINER_ENGINE=\"docker\"$" "$I"'
out="$(printf '1\nCONTAINER_ENGINE\npodman\n\nCONTAINER_ENGINE\ncolima\nlxc\n\n0\n0\n' | PATH="$PPATH" bash "$I" menu 2>&1)"
check "settings screen: podman refused while Docker holds the data" 'grep -q "are in Docker - one engine per server: keep \"docker\"" <<< "$out" && grep -q "^CONTAINER_ENGINE=\"docker\"$" "$I"'
check "settings screen: colima only on macOS, unknown engines refused" 'grep -q "Colima runs only on macOS - use podman or docker" <<< "$out" && grep -q "Use podman, docker or \"\"" <<< "$out"'
cat > "$T/bin/ed-podman" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"; sed -i 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE="podman"/' "$f"
EOF
chmod +x "$T/bin/ed-podman"
cs="$(cksum < "$I")"
out="$(printf '1\ne\nn\n0\n0\n' | PATH="$PPATH" EDITOR=ed-podman bash "$I" menu 2>&1)"
check "editor: a CONTAINER_ENGINE that leaves the data behind is refused, the file restored" 'grep -q "CONTAINER_ENGINE \"podman\": The containers or data volumes" <<< "$out" && [ "$(cksum < "$I")" = "$cs" ]'

# 9b. Data in both engines (old Docker volumes next to a Podman installation, or the other way round):
# the engine of the folder goes on and names the other; switching to the other one is allowed
installed docker
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" up </dev/null 2>&1)"; rc=$?
check "both engines hold data, folder uses Docker: up goes on and names Podman" '[ "$rc" -eq 0 ] && grep -q "Stack is up" <<< "$out" && grep -q "project \"inst\" are also in Podman; this folder uses Docker" <<< "$out" && grep -q "R with CONTAINER_ENGINE=\"podman\"" <<< "$out"'
check "both engines: the note comes once" '[ "$(grep -c "are also in Podman" <<< "$out")" -eq 1 ]'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" check </dev/null 2>&1)"
check "both engines: check warns, not a problem" 'grep -q "are also in Podman" <<< "$out" && ! grep -q "but this folder uses" <<< "$out"'
out="$(printf '1\nCONTAINER_ENGINE\npodman\n0\ny\n0\n' | PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" menu 2>&1)"
check "both engines: the settings screen switches to podman (to remove its data with R)" 'grep -q "^CONTAINER_ENGINE=\"podman\"$" "$I" && ! grep -q "one engine per server" <<< "$out"'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" __engine_choose docker </dev/null 2>&1)"; rc=$?
check "both engines: and back to docker" '[ "$rc" -eq 0 ] && grep -q "^CONTAINER_ENGINE=\"docker\"$" "$I"'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" __engine_choices </dev/null 2>&1)"
check "both engines: both can be chosen" 'grep -q "^podman|Podman|data|$" <<< "$out" && grep -q "^docker|Docker Engine|data|$" <<< "$out"'
sed -i 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=""/' "$I"; : > "$LOG"
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst RN1_COMPOSE_PROVIDER="$T/pbin/docker-compose" bash "$I" up </dev/null 2>&1)"; rc=$?
check "both engines, CONTAINER_ENGINE empty: up refused until one is chosen" '[ "$rc" -ne 0 ] && grep -q "project \"inst\" are in Podman and in Docker" <<< "$out" && grep -q "choose the one to go on with: CONTAINER_ENGINE=\"podman\" or \"docker\"" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG"'

# 10. CONTAINER_ENGINE empty: the engine is found
eng() { (cd "$D" && bash "$I" __engine </dev/null 2>/dev/null); }
installed ""
check "data only in Docker, Podman installed: Docker" '[ "$(PATH="$PPATH" eng)" = "docker docker Docker" ]'
rm -f "$ST/up" "$ST/vols" "$ST/net"
check "no data, Podman installed: Podman" '[ "$(PATH="$PPATH" eng)" = "podman podman Podman" ]'
check "no data, no Podman, Docker answers: Docker" '[ "$(eng)" = "docker docker Docker" ]'
out="$(cd "$D" && bash "$I" check </dev/null 2>&1)"
check "check names the engine found for an empty CONTAINER_ENGINE" 'grep -q "Container engine: Docker (CONTAINER_ENGINE is empty: the one found on this server)" <<< "$out"'
check "no data, no Podman, Docker does not answer: Podman" '[ "$(SHIM_DOCKER_DOWN=1 eng)" = "podman podman Podman" ]'
touch "$ST/vols"
check "data in both: Podman (Docker only when it alone holds the data)" '[ "$(PATH="$PPATH" SHIM_PODMAN_DATA=inst eng)" = "podman podman Podman" ]'
check "podman-docker is not Docker: Podman" '[ "$(SHIM_DOCKER_SHIM=1 eng)" = "podman podman Podman" ]'
out="$(cd "$D" && bash "$I" __settings_groups | grep "|CONTAINER_ENGINE|")"
check "settings screen: CONTAINER_ENGINE in the general group" '[ "$out" = "-|CONTAINER_ENGINE|" ]'

# 11. engine_choices and engine_choose
fresh ""
out="$(cd "$D" && PATH="$PPATH" RN1_COMPOSE_PROVIDER="$T/pbin/docker-compose" bash "$I" __engine_choices 2>&1 | grep -v '^bash: warning: setlocale: ')"
check "choices on Linux: podman and docker, both ready, no colima" '[ "$(wc -l <<< "$out")" -eq 2 ] && grep -qx "podman|Podman|ready|" <<< "$out" && grep -qx "docker|Docker Engine|ready|" <<< "$out"'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_VERSION=4.3.1 bash "$I" __engine_choices 2>&1)"
check "choices: a Podman that is too old has its reason" 'grep -qx "podman|Podman|installed|Podman 4.3.1 is too old: 4.9.0 or newer is needed." <<< "$out"'
out="$(cd "$D" && PATH="$PPATH" SHIM_PODMAN_DATA=inst bash "$I" __engine_choices 2>&1)"
check "choices: Podman holds the data - docker is not selectable" 'grep -q "^podman|Podman|data|$" <<< "$out" && grep -q "^docker|Docker Engine|ready|The containers or data volumes of this installation are in Podman - one engine per server.$" <<< "$out"'
out="$(cd "$D" && SHIM_ARCH=aarch64 bash "$I" __engine_choices 2>&1)"
check "choices on ARM: both refused, the images are amd64 only" '[ "$(grep -c "exist only for amd64" <<< "$out")" -eq 2 ]'
out="$(cd "$D" && bash "$I" __engine_choose docker 2>&1)"; rc=$?
check "engine_choose docker: written into the settings" '[ "$rc" -eq 0 ] && grep -q "^CONTAINER_ENGINE=\"docker\"$" "$I" && grep -q "CONTAINER_ENGINE = \"docker\" (Docker Engine)" <<< "$out"'
out="$(cd "$D" && bash "$I" __engine_choose colima 2>&1)"; rc=$?
check "engine_choose colima on Linux: refused" '[ "$rc" -ne 0 ] && grep -q "Unknown container engine \"colima\" - choose one of: podman, docker." <<< "$out" && grep -q "^CONTAINER_ENGINE=\"docker\"$" "$I"'
out="$(cd "$D" && bash "$I" check-settings 2>&1)"; rc=$?
sed -i 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE="colima"/' "$I"
out2="$(cd "$D" && bash "$I" check-settings 2>&1)"; rc2=$?
check "check-settings: docker valid, colima refused on Linux" '[ "$rc" -eq 0 ] && [ "$rc2" -ne 0 ] && grep -q "CONTAINER_ENGINE must be \"podman\", \"docker\", \"colima\" (only on macOS) or empty" <<< "$out2"'

# 12. install-docker where Docker is installed (a CI runner): only its daemon is enabled; the choice is written
fresh ""
out="$(cd "$D" && PATH="$T/impbin:$PATH" SHIM_UID=1000 bash "$I" install-docker </dev/null 2>&1)"; rc=$?
check "install-docker with Docker there: nothing installed from packages, its daemon enabled with sudo" '[ "$rc" -eq 0 ] && grep -q "^sudo sh -c systemctl enable --now docker$" "$SUDO_LOG" && ! grep -qE "apt-get|dnf |yum |zypper" "$SUDO_LOG" && { docker_distro_host || [ "$(grep -c . "$SUDO_LOG")" -eq 1 ]; } && grep -q "Docker 29.9.0 is ready" <<< "$out"'
check "install-docker: CONTAINER_ENGINE set to docker" 'grep -q "^CONTAINER_ENGINE=\"docker\"$" "$I" && grep -q "this folder uses Docker from now on" <<< "$out"'
fresh podman
out="$(cd "$D" && bash "$I" install-docker </dev/null 2>&1)"; rc=$?
check "install-docker in a Podman folder: refused, nothing run" '[ "$rc" -ne 0 ] && grep -q "This folder uses CONTAINER_ENGINE=\"podman\"" <<< "$out" && [ ! -s "$SUDO_LOG" ]'

# 13. install-docker with an internet proxy: the env file of the proxy and the drop-in of docker.service are
# written as root before the daemon step, the units reloaded first; a running Docker is restarted only after a
# question
# (not on openSUSE and SLES: there the Compose download runs as root through the proxy, which this sudo skips)
if ! docker_distro_host; then
  fresh ""
  sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|' "$I"
  out="$(cd "$D" && PATH="$T/impbin:$PATH" SHIM_UID=1000 SHIM_DOCKER_ACTIVE=1 RN1_ETC_DIR="$T/etc13" RN1_RUN_DIR="$T/run13" bash "$I" install-docker </dev/null 2>&1)"; rc=$?
  line_of() { grep -n -- "$1" "$SUDO_LOG" | head -n 1 | cut -d: -f1; }
  check "install-docker with a proxy: the env file (600) and the drop-in (644) as root before the daemon steps, the units reloaded first" '[ "$rc" -eq 0 ] && w1="$(line_of "sh $T/etc13/rn1-technology-catalog/engine-proxy.env 600$")" && w2="$(line_of "sh $T/etc13/systemd/system/docker.service.d/50-rn1-proxy.conf 644$")" && r="$(line_of "systemctl daemon-reload$")" && e="$(line_of "systemctl enable --now docker$")" && [ -n "$w1" ] && [ -n "$w2" ] && [ -n "$r" ] && [ -n "$e" ] && [ "$w1" -lt "$r" ] && [ "$w2" -lt "$r" ] && [ "$r" -lt "$e" ] && grep -q "Docker gets the internet proxy before these steps" <<< "$out"'
  check "install-docker with a proxy: Docker ran already - not restarted without a question, said how" 'grep -q "Docker reads the change at its next restart (systemctl restart docker)." <<< "$out" && ! grep -q "restart docker$" "$SUDO_LOG"'
fi

check "fakes: no unknown docker, podman or systemctl call in the whole suite" '[ ! -s "$BAD" ] || { sort "$BAD" | uniq -c | head -20; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
