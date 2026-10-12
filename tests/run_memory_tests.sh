#!/usr/bin/env bash
set -u
NEW="$1"
SP="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)/m"
rm -rf "$T"; mkdir -p "$T/bin" "$T/dbin" "$T/st" "$T/home"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# the internet check (menu start, new installation, option 16, engine setup) has its own suite (run_network_tests)
export RN1_NET_CHECK=off
# LOG: the calls of one case (emptied by fresh). BAD: calls the fakes do not know, for the whole suite.
# ST: the state of the fakes - mem (bytes of memory the engine reports; 32 GB without it), up (the stack
# runs), oom (the kernel stopped mongo for lack of memory; restarts.c1: how often its restart policy started
# it again since; oom-events: "SECONDS SERVICE" of each stop, the oom events of Docker), cache (the cache mongo
# was created with), machine / machine.mb (state and memory of the Podman machine), dead (the machine started,
# but Podman does not answer), restart.n (calls of podman-restart.service since the start), colima.gb,
# brew.colima (the state brew services shows), fail-oom (the next import fails because MongoDB is stopped),
# uploads (the uploaded files).
export LOG="$T/calls.log" BAD="$T/bad.log" ST="$T/st" T
: > "$LOG"; : > "$BAD"

# A PATH without any real podman, docker, colima or Homebrew of this machine (CI runners have them)
mkdir -p "$T/sys"
IFS=: read -r -a dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="${f##*/}"
    case "$b" in podman|docker|docker-compose|podman-compose|colima|brew|sudo) continue ;; esac
    [ -e "$T/sys/$b" ] || ln -s "$f" "$T/sys/$b" 2>/dev/null
  done
done

# The stack the fakes run: mongo (c1) and catalog-web (c2), both labelled with the project "mem"
cat > "$T/stack.sh" <<'EOF'
envval() { sed -n "s/^$1=//p" "${ENVF:-.env}" 2>/dev/null | tail -n 1; }
rp() { local r=""; while [[ "$out" == *"$1"* ]]; do r="$r${out%%"$1"*}$2"; out="${out#*"$1"}"; done; out="$r$out"; }
svc_of() { case "$1" in c1) echo mongo ;; c2) echo catalog-web ;; esac; }
inspect() {
  local fmt="$1" id
  shift
  for id in "$@"; do
    { [ -f "$ST/up" ] && [ -n "$(svc_of "$id")" ]; } || { echo "Error: no such container $id" >&2; return 125; }
    out="$fmt"
    # Podman keeps OOMKilled when the restart policy starts the container again; Docker clears it then
    rp '{{.State.OOMKilled}}' "$(if [ "$ENGINE_FAKE" = podman ] && [ "$id" = c1 ] && [ -f "$ST/oom" ]; then echo true; else echo false; fi)"
    rp '{{index .Config.Labels "com.docker.compose.service"}}' "$(svc_of "$id")"
    rp '{{.State.Status}}|{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}|{{.RestartCount}}' "running|none|0"
    rp '{{.RestartCount}}' "$(cat "$ST/restarts.$id" 2>/dev/null || echo 0)"
    rp '{{.Config.Image}}' "$(if [ "$id" = c1 ]; then echo docker.io/library/mongo:8.0; else echo docker.io/raynetgmbh/rayventory-catalog:25.4.4191.133; fi)"
    case "$out" in *'{{'*) echo "UNHANDLED $ENGINE_FAKE container inspect --format $fmt" >> "$BAD"; return 125 ;; esac
    printf '%s\n' "$out"
  done
}
# compose ARGS: "podman compose" or "docker compose" with --env-file .env -f docker-compose.yml
compose() {
  local all="$*"
  while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; --env-file) ENVF="$2"; shift 2 ;; -f) shift 2 ;; *) break ;; esac; done
  [ -f "${ENVF:-.env}" ] || { echo "open .env: no such file or directory" >&2; return 1; }
  case "$*" in
    "config --services") printf 'mongo\ncatalog-web\n' ;;
    "config --quiet") ;;
    "up -d --remove-orphans")
      touch "$ST/up"
      c="$(envval MONGO_WT_CACHE_GB)"
      # a changed cache is a changed command of mongo: Compose creates it again, which clears OOMKilled
      if [ "$c" != "$(cat "$ST/cache" 2>/dev/null)" ]; then
        printf '%s' "$c" > "$ST/cache"
        rm -f "$ST/oom" "$ST/restarts.c1"
        echo "compose: mongo created with cache=${c:-unset}" >> "$LOG"
      fi ;;
    "ps") echo "NAME STATUS"; [ -f "$ST/up" ] && printf '%s\n' "mem-mongo-1 Up" "mem-catalog-web-1 Up" ;;
    # the installed versions: running containers (-q), also stopped ones (-a -q)
    "ps -q mongo"|"ps -a -q mongo") [ -f "$ST/up" ] && echo c1 ;;
    "ps -q catalog-web"|"ps -a -q catalog-web") [ -f "$ST/up" ] && echo c2 ;;
    "ps --services --filter status=running") [ -f "$ST/up" ] && printf 'mongo\ncatalog-web\n' ;;
    "down --remove-orphans") rm -f "$ST/up" ;;
    *) echo "UNHANDLED $ENGINE_FAKE compose $all" >> "$BAD"; return 1 ;;
  esac
  return 0
}
EOF

# Fake rootful Podman. On macOS (SHIM_OS=Darwin) a Podman machine: it answers only while it runs, its memory
# changes only while it is stopped (as with applehv), and the kernel of the VM keeps 408 MB of it.
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$LOG"
ENGINE_FAKE=podman
. "$T/stack.sh"
bad() { echo "UNHANDLED podman $*" >> "$BAD"; echo "Error: fake podman does not know: $*" >&2; exit 125; }
mac() { [ "${SHIM_OS:-Linux}" = Darwin ]; }
vm_up() { [ "$(cat "$ST/machine" 2>/dev/null || echo running)" = running ]; }
[ "${1:-}" = --version ] && { echo "podman version 5.7.0"; exit 0; }
if [ "${1:-}" = machine ]; then
  mac || bad "$@"
  m=podman-machine-default
  case "$*" in
    "machine list --format {{.Name}}|{{.Running}}") if vm_up; then echo "$m*|true"; else echo "$m*|false"; fi ;;
    "machine list --format {{.Name}}|{{.VMType}}") echo "$m*|applehv" ;;
    "machine inspect --format {{.State}} $m") if vm_up; then echo running; else echo stopped; fi ;;
    "machine stop $m") echo stopped > "$ST/machine" ;;
    "machine set --memory "*" $m")
      if vm_up; then echo "Error: unable to change settings unless vm is stopped" >&2; exit 125; fi
      [ -n "${SHIM_SET_FAIL:-}" ] && { echo "Error: setting memory: invalid argument" >&2; exit 125; }
      # SHIM_SET_NOOP: accepted, but the machine starts with its old memory
      [ -n "${SHIM_SET_NOOP:-}" ] || echo "$4" > "$ST/machine.mb" ;;
    "machine start $m")
      echo running > "$ST/machine"
      rm -f "$ST/restart.n"
      [ -n "${SHIM_START_DEAD:-}" ] && touch "$ST/dead"
      echo $(( ($(cat "$ST/machine.mb" 2>/dev/null || echo 14336) - 408) * 1048576 )) > "$ST/mem" ;;
    # the check of I: Rosetta and vm.max_map_count in the machine
    "machine ssh $m cat /proc/sys/fs/binfmt_misc/rosetta") echo enabled ;;
    "machine ssh $m sysctl -n vm.max_map_count") echo 262144 ;;
    # podman-restart.service is still starting the containers at the first question after a start
    "machine ssh $m systemctl is-active podman-restart.service")
      n="$(cat "$ST/restart.n" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$ST/restart.n"
      if [ "$n" -eq 0 ]; then echo activating; exit 3; fi
      echo active ;;
    *) bad "$@" ;;
  esac
  exit 0
fi
if mac && { ! vm_up || [ -f "$ST/dead" ]; }; then echo "Cannot connect to Podman. Please verify your connection to the Linux system" >&2; exit 125; fi
case "$*" in
  info) ;;
  "info --format {{.Host.Security.Rootless}}") echo false ;;
  "info --format {{.Host.Kernel}}") echo 6.8.0-generic ;;
  "info --format {{.Host.MemTotal}}")
    [ -n "${SHIM_NO_MEMTOTAL:-}" ] && exit 125
    cat "$ST/mem" 2>/dev/null || echo 34359738368 ;;
  "logs --timestamps "*) ;;
  "ps -aq --filter label=com.docker.compose.project=mem") [ -f "$ST/up" ] && printf 'c1\nc2\n' ;;
  "ps -aq --filter label=com.docker.compose.project="*|"ps -aq --filter label=com.docker.compose.service="*) ;;
  # the MongoDB that runs (the downgrade check before a start)
  "exec c1 mongod --version") [ -f "$ST/up" ] || exit 125; echo "db version v8.0.4" ;;
  "volume ls -q --filter label=com.docker.compose.project="*) ;;
  "volume inspect --format {{.Mountpoint}} "*) echo "Error: no such volume" >&2; exit 125 ;;
  "container inspect --format "*) shift 3; inspect "$@" || exit 125 ;;
  "compose "*)
    [ "${PODMAN_COMPOSE_PROVIDER:-}" = "$RN1_COMPOSE_PROVIDER" ] || bad "$@"
    shift; compose "$@" || exit 1 ;;
  *) bad "$@" ;;
esac
exit 0
EOF
# Docker (only on the PATH where a case puts $T/dbin first): Docker Engine on Linux or Docker Desktop (context
# desktop-linux; $ST/mem, else 8 GB) or the Colima VM (context colima, its memory in $ST/colima.gb, 14 GB
# without it). Its oom events: those in $ST/oom-events from --since (24h: all) to --until.
cat > "$T/dbin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
ENGINE_FAKE=docker
. "$T/stack.sh"
bad() { echo "UNHANDLED docker $*" >> "$BAD"; echo "docker: the fake does not know: $*" >&2; exit 125; }
ctx="${DOCKER_CONTEXT:-default}"
case "$*" in
  --version) echo "Docker version 29.9.0, build 1a2b3c4"; exit 0 ;;
  "context show") echo "$ctx"; exit 0 ;;
  "context inspect colima") [ "${SHIM_KIND:-}" = colima ] || exit 1; echo "[]"; exit 0 ;;
  "context inspect desktop-linux") [ "${SHIM_KIND:-}" = docker ] || exit 1; echo "[]"; exit 0 ;;
  "compose version") echo "Docker Compose version v2.40.3"; exit 0 ;;
esac
if [ "$ctx" = colima ] && [ ! -f "$ST/colima.running" ]; then echo "Cannot connect to the Docker daemon. Is the docker daemon running?" >&2; exit 1; fi
case "$*" in
  info) echo "Server: Docker Engine - Community" ;;
  "info --format {{.MemTotal}}")
    if [ "$ctx" = colima ]; then echo $(( ($(cat "$ST/colima.gb" 2>/dev/null || echo 14) * 1024 - 400) * 1048576 )); else cat "$ST/mem" 2>/dev/null || echo 8241897472; fi ;;
  "info --format {{.KernelVersion}}") echo 6.12.5-linuxkit ;;
  "logs --timestamps "*) ;;
  "exec c1 mongod --version") [ -f "$ST/up" ] || exit 1; echo "db version v8.0.4" ;;
  "info --format {{range .SecurityOptions}}{{.}} {{end}}") echo "name=seccomp,profile=builtin name=cgroupns " ;;
  "ps -aq --filter label=com.docker.compose.project=mem") [ -f "$ST/up" ] && printf 'c1\nc2\n' ;;
  "ps -aq --filter label=com.docker.compose.project="*|"ps -aq --filter label=com.docker.compose.service="*) ;;
  "container inspect --format "*) shift 3; inspect "$@" || exit 125 ;;
  "events --since "*" --until "*" --filter type=container --filter event=oom --filter label=com.docker.compose.project=mem --format "*)
    [ "${13}" = '{{index .Actor.Attributes "com.docker.compose.service"}}' ] && [[ "$3" =~ ^([0-9]+|24h)$ ]] && [[ "$5" =~ ^[0-9]+$ ]] || bad "$@"
    s="$3"; [ "$s" = 24h ] && s=0
    awk -v s="$s" -v u="$5" '$1 >= s && $1 <= u { print $2 }' "$ST/oom-events" 2>/dev/null ;;
  "volume ls -q --filter label=com.docker.compose.project="*) ;;
  "volume inspect --format {{.Mountpoint}} "*) exit 1 ;;
  "compose "*) shift; compose "$@" || exit 1 ;;
  *) bad "$@" ;;
esac
exit 0
EOF
cat > "$T/dbin/colima" <<'EOF'
#!/usr/bin/env bash
echo "colima $*" >> "$LOG"
case "$*" in
  status) [ -f "$ST/colima.running" ] ;;
  stop) rm -f "$ST/colima.running" ;;
  "start --cpu "*" --memory "*) touch "$ST/colima.running"; echo "$5" > "$ST/colima.gb" ;;
  *) echo "UNHANDLED colima $*" >> "$BAD"; exit 125 ;;
esac
EOF
# Homebrew: brew services with Colima ($ST/brew.colima, none without it). Its colima start -f starts the VM
# with the memory of colima.yaml; stopped, it stops the VM with SHIM_BREW_OWNS (it started it after a login),
# else the VM was started by colima start and runs on.
cat > "$T/bin/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >> "$LOG"
case "$*" in
  --prefix) echo "$T/no-brew" ;;
  "services list")
    echo "Name   Status  User File"
    echo "colima $(cat "$ST/brew.colima" 2>/dev/null || echo none) user ~/Library/LaunchAgents/homebrew.mxcl.colima.plist" ;;
  "services stop colima") echo none > "$ST/brew.colima"; [ -z "${SHIM_BREW_OWNS:-}" ] || rm -f "$ST/colima.running" ;;
  "services start colima")
    echo started > "$ST/brew.colima"; touch "$ST/colima.running"
    sed -n 's/^memory: *//p' "$HOME/.colima/default/colima.yaml" > "$ST/colima.gb" ;;
  *) echo "UNHANDLED brew $*" >> "$BAD"; exit 1 ;;
esac
EOF
# Docker Compose behind "podman compose" (RN1_COMPOSE_PROVIDER): only its version is asked
cat > "$T/bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  version) echo "Docker Compose version v5.6.0" ;;
  *) echo "UNHANDLED docker-compose $*" >> "$BAD"; exit 1 ;;
esac
EOF
# The local catalog: the stored local key is valid; an upload is accepted as an operation, which fails once
# when $ST/fail-oom exists (MongoDB is stopped by the kernel: $ST/oom), always with SHIM_FAIL_PLAIN (no
# stop), and finishes otherwise; a synchronization (option 20) is an operation too. Catalog Web answers the
# health check (not with SHIM_UNHEALTHY).
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=/dev/stdout; fmt=""; url=""; cfg=""; form=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -K) [ "$2" = "-" ] && cfg="$(cat)"; shift 2 ;;
    -F) form="$2"; shift 2 ;;
    -X|-H|--connect-timeout|--max-time|--data-binary) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $url" >> "$LOG"
reply() { if [ "$out" != /dev/stdout ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi; [ -n "$fmt" ] && printf '%s' "${fmt//%\{http_code\}/$1}"; exit 0; }
case "$url" in
  http://localhost:8080/) if [ -n "${SHIM_UNHEALTHY:-}" ]; then reply 502 ""; fi; reply 200 "" ;;
  # the registries the versions step of I asks: offline
  https://registry-1.docker.io/v2/|https://ghcr.io/v2/|https://hub.docker.com/v2/repositories/*) echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
  http://localhost:8080/v1/*)
    grep -q 'X-Api-Key: LOCALKEY' <<< "$cfg" || reply 401 ""
    case "$url" in
      */v1/databaseconfiguration/synchronization) reply 200 '{}' ;;
      */v1/synchronization/snapshot) f="${form#file=@}"; echo "${f%%;*}" >> "$ST/uploads"; reply 202 '{"operationId":"op-1","status":"accepted"}' ;;
      */v1/synchronization/synchronize) echo sync >> "$ST/uploads"; reply 202 '{"operationId":"op-1","status":"accepted"}' ;;
      */v1/synchronizationHistory/progress/op-1) reply 200 0 ;;
      */v1/operation/recent*) reply 200 '[]' ;;
      */v1/operation/op-1)
        if [ -f "$ST/fail-oom" ]; then
          rm -f "$ST/fail-oom"; touch "$ST/oom"; echo $(( $(cat "$ST/restarts.c1" 2>/dev/null || echo 0) + 1 )) > "$ST/restarts.c1"
          echo "$(date +%s) mongo" >> "$ST/oom-events"
          reply 200 '{"status":"failed","progress":40,"message":"Error while applying synchronization file."}'
        fi
        [ -n "${SHIM_FAIL_PLAIN:-}" ] && reply 200 '{"status":"failed","progress":10,"message":"The file is not a snapshot."}'
        reply 200 '{"status":"finished","progress":100,"message":"done"}' ;;
    esac ;;
esac
echo "UNHANDLED curl $url" >> "$BAD"; exit 22
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet podman.socket") ;;
  "is-enabled podman-restart.service") echo enabled ;;
  "is-enabled docker.service") echo enabled ;;
  *) echo "UNHANDLED systemctl $*" >> "$BAD"; exit 1 ;;
esac
EOF
REAL_UNAME="$(command -v uname)"
cat > "$T/bin/uname" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  -s) echo "\${SHIM_OS:-Linux}" ;;
  -r) echo 6.8.0-generic ;;
  -n) echo testhost ;;
  *) exec "$REAL_UNAME" "\$@" ;;
esac
EOF
# macOS: an Apple Silicon Mac with 48 GB (SHIM_MEMSIZE), macOS 26, no address of its own (the Catalog on localhost)
cat > "$T/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-n hw.memsize") echo "${SHIM_MEMSIZE:-51539607552}" ;;
  "-n hw.optional.arm64") echo 1 ;;
  "-n hw.ncpu") echo 10 ;;
  *) echo "UNHANDLED sysctl $*" >> "$BAD"; exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\necho 26.1\n' > "$T/bin/sw_vers"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/ipconfig"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" Europe/Berlin\n' > "$T/bin/timedatectl"
# nothing here runs with sudo (on macOS the Podman machine and Colima belong to the user)
printf '#!/usr/bin/env bash\necho "UNHANDLED sudo $*" >> "$BAD"\nexit 1\n' > "$T/bin/sudo"
chmod +x "$T/bin/"* "$T/dbin/"*
export PATH="$T/bin:$T/sys" HOME="$T/home" RN1_COMPOSE_PROVIDER="$T/bin/docker-compose" RN1_MAC_BOOTSTRAPPED=1 COLUMNS=120
DPATH="$T/dbin:$PATH"

D="$T/mem"
I="$D/rn1-technology-catalog-installer.sh"
GIB=1073741824
# fresh [SED]: a new folder with the installer (Podman, no Nginx Proxy Manager), nothing running, 32 GB
fresh() {
  rm -rf "$D" "$ST" "$T/home"; mkdir -p "$D" "$ST" "$T/home"
  sed "s/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=\"podman\"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES=\"false\"/; s/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER=\"false\"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT=\"30\"/; ${1:-}" "$NEW" > "$I"
  : > "$LOG"
}
run() { (cd "$D" && bash "$I" "$@" </dev/null 2>&1); }
menu() { (cd "$D" && printf "$1" | bash "$I" menu 2>&1); }
mem() { echo "$1" > "$ST/mem"; }
envv() { sed -n "s/^$1=//p" "$D/.env"; }
setting() { sed -n "/^# CONFIGURE ONLY THIS SECTION/,/^# DO NOT CHANGE ANYTHING BELOW/s/^$1=\"\(.*\)\"$/\1/p" "$I"; }
# a running installation with a snapshot to import and the local key stored
installed() {
  fresh "${1:-}"
  run generate >/dev/null
  run up >/dev/null
  mkdir -p "$D/snapshots"
  head -c 2000 /dev/urandom | gzip -1 > "$D/snapshots/2026-09-28-full.tar.gz"
  printf 'LOCALKEY\n' > "$D/.catalog_local_api_key"; chmod 600 "$D/.catalog_local_api_key"
  : > "$LOG"; rm -f "$ST/uploads"
}
before() { [ "$(grep -n -m1 -- "$1" "$LOG" | cut -d: -f1)" -lt "$(grep -n -m1 -- "$2" "$LOG" | cut -d: -f1)" ]; }
MEMWARN="GB for the containers - at least 24 GB is recommended"
MEMOK="GB for the containers - enough for a full snapshot import"
# narrow OUT -> true when the lines of the memory messages in OUT fit into 80 columns; else prints the wider ones
NEWMSG='stopped by the kernel|The engine has|macOS gives|restarts \(about|More memory for|has to be raised|VM settings or hardware|does not limit the cache|about half of the memory|This Mac has|and keep 8 GB|A daily snapshot builds|option 19, a chain|A snapshot import replaces|Memory: [0-9]+ GB|A full snapshot import loads|This engine has|Docker Desktop: Settings|A job is running|when the job is done|still has|of memory now|MongoDB gets a cache|restarts with 24 GB|does not answer after|could not be changed|does not run cleanly|in the background \(J\)|podman machine (stop|set|start) podman|colima stop|brew services|memory: 24 in|Linux VM gets|a Mac with 32'
narrow() { ! sed 's/\x1b\[[0-9;]*m//g' <<< "$1" | grep -E "$NEWMSG" | awk 'length($0) > 80 { print "  | " length($0) ": " $0; bad = 1 } END { exit !bad }'; }

# 1. The memory of the engine in the check: whole GB, 92 % of 24 GB counts as enough
fresh
out="$(run check)"
check "check: 32 GB of Podman - an OK line" 'grep -q "^ OK Memory: 32 $MEMOK$" <<< "$out" && grep -q "^podman info --format {{.Host.MemTotal}}$" "$LOG"'
mem $(((14336 - 408) * 1048576))
out="$(run check)"
check "check: the 13928 MB of a 14 GB VM - a WARN line with 14 GB, why on a line of its own" 'grep -q "^WARN Memory: 14 $MEMWARN$" <<< "$out" && grep -q "^      A full snapshot import loads MongoDB, the Catalog and OpenSearch at once.$" <<< "$out" && narrow "$out"'
mem $((22610 * 1048576)); out="$(run check)"
check "check: 92 % of 24 GB (22610 MB) counts as enough" 'grep -q "^ OK Memory: 23 $MEMOK$" <<< "$out"'
mem $((22609 * 1048576)); out="$(run check)"
check "check: below 92 % of 24 GB (22609 MB) is a warning" 'grep -q "^WARN Memory: 23 GB for the containers" <<< "$out"'
rm -f "$ST/mem"
kb="$(awk '$1 == "MemTotal:" { print $2 }' /proc/meminfo 2>/dev/null)"
if [ -n "$kb" ]; then
  out="$(SHIM_NO_MEMTOTAL=1 run check)"
  check "check: Podman does not say its memory - MemTotal of /proc/meminfo on Linux" 'grep -q "Memory: $(( (kb / 1024 + 1023) / 1024 )) GB for the containers" <<< "$out"'
fi

# 2. The cache of MongoDB: automatic for the memory of the engine, through .env into the command of mongo
for spec in "14 2" "24 7" "32 11" "64 27" "12 1" "13 1.5"; do
  read -r gb want <<< "$spec"
  fresh; mem $(((gb * 1024 - 408) * 1048576))
  out="$(run generate)"
  check "cache of MongoDB with $gb GB: $want GB" '[ "$(envv MONGO_WT_CACHE_GB)" = "$want" ] && grep -q "MongoDB cache  : $want GB (automatic, for the memory of Podman)" <<< "$out"'
done
check "compose: mongo starts with the cache of .env (1 GB when .env has none)" '[ "$(sed -n "/^  mongo:/,/^  minio:/p" "$D/docker-compose.yml" | grep -c "^    command: \[\"--wiredTigerCacheSizeGB\", \"\${MONGO_WT_CACHE_GB:-1}\"\]$")" -eq 1 ] && [ "$(grep -c wiredTigerCacheSizeGB "$D/docker-compose.yml")" -eq 1 ]'
fresh 's/^MONGO_CACHE_GB=.*/MONGO_CACHE_GB="4.5"/'
mem $((14 * GIB)); out="$(run generate)"
check "MONGO_CACHE_GB set: its value, whatever the memory" '[ "$(envv MONGO_WT_CACHE_GB)" = 4.5 ] && grep -q "MongoDB cache  : 4.5 GB (MONGO_CACHE_GB)" <<< "$out"'
for v in 0.2 abc 1,5 01 "-2"; do
  sed -i "s/^MONGO_CACHE_GB=.*/MONGO_CACHE_GB=\"$v\"/" "$I"
  out="$(run check-settings)"; rc=$?
  check "MONGO_CACHE_GB=\"$v\" refused" '[ "$rc" -ne 0 ] && grep -q "MONGO_CACHE_GB must be GB like 4 or 2.5 (at least 0.25) or empty (is \"$v\")." <<< "$out"'
done
for v in 0.25 3 2.5 64; do
  sed -i "s/^MONGO_CACHE_GB=.*/MONGO_CACHE_GB=\"$v\"/" "$I"
  run check-settings >/dev/null; rc=$?
  check "MONGO_CACHE_GB=\"$v\" accepted" '[ "$rc" -eq 0 ]'
done
fresh
out="$(menu '1\nMONGO_CACHE_GB\n0.1\n6\n0\nn\n0\n')"
check "settings screen: the help text, a value below 0.25 refused" 'grep -q "Cache of MongoDB in GB (at least 0.25); empty: automatic, (memory of the engine - 10 GB) / 2" <<< "$out" && grep -q "Give the cache in GB, e.g. 4 or 2.5 (at least 0.25)" <<< "$out"'
out="$(menu '1\nMONGO_CACHE_GB\n6\ns\n0\n')"
check "settings screen: MONGO_CACHE_GB saved" '[ "$(setting MONGO_CACHE_GB)" = 6 ]'

# 3. Recomputed at every start: a VM that got more memory gives MongoDB more; the setting stays automatic
fresh
mem $(((14336 - 408) * 1048576)); run generate >/dev/null; run up >/dev/null
check "start with 14 GB: mongo created with a cache of 2 GB" '[ "$(envv MONGO_WT_CACHE_GB)" = 2 ] && grep -q "compose: mongo created with cache=2$" "$LOG"'
: > "$LOG"
mem $(((24576 - 408) * 1048576))
out="$(run up)"
check "start after the VM got 24 GB: 7 GB, mongo created again, no stale files" '[ "$(envv MONGO_WT_CACHE_GB)" = 7 ] && grep -q "MongoDB gets a cache of 7 GB (was 2 GB) for the memory of Podman." <<< "$out" && grep -q "compose: mongo created with cache=7$" "$LOG" && ! grep -q "do not match the settings" <<< "$out"'
: > "$LOG"; out="$(run up)"
check "start with the same memory: .env and mongo as they are" '! grep -q "MongoDB gets a cache" <<< "$out" && ! grep -q "compose: mongo created" "$LOG"'
check "the setting stays empty (automatic); the menu sees no stale files" '[ -z "$(setting MONGO_CACHE_GB)" ] && grep -q "^MONGO_CACHE_GB=\"\"$" "$I" && ! grep -q "do not match the settings above" <<< "$(menu "0\n")"'
out="$(menu '2\n1\n\n0\n')"
check "regenerated from the menu: the value of now, the setting still empty" '[ "$(envv MONGO_WT_CACHE_GB)" = 7 ] && [ -z "$(setting MONGO_CACHE_GB)" ]'
sed -i 's/^MONGO_CACHE_GB=.*/MONGO_CACHE_GB="3"/' "$I"
check "MONGO_CACHE_GB changed: the menu names the files stale" 'grep -q "do not match the settings above" <<< "$(menu "0\n")"'
: > "$LOG"; out="$(run up)"
check "start: the set value reaches .env and mongo" '[ "$(envv MONGO_WT_CACHE_GB)" = 3 ] && grep -q "compose: mongo created with cache=3$" "$LOG"'

# 4. Files of an older installer: .env without the cache (and a compose file without it, or with it)
fresh
mkdir -p "$T/old"; (cd "$T/old" && bash "$SP/original.sh" >/dev/null 2>&1); cp "$T/old/.env" "$T/old/docker-compose.yml" "$D/"
out="$(run up)"; rc=$?
check "old .env and compose file: they start as they are (no cache added)" '[ "$rc" -eq 0 ] && ! grep -q MONGO_WT_CACHE_GB "$D/.env" && ! grep -q wiredTiger "$D/docker-compose.yml" && grep -q "do not match the settings" <<< "$out"'
mem $(((14336 - 408) * 1048576))
out="$(run setup)"
check "old files below 24 GB: setup warns and writes them, no note about the old files" 'grep -q "This engine has 14 GB of memory" <<< "$out" && ! grep -q "does not limit the cache" <<< "$out" && [ "$(envv MONGO_WT_CACHE_GB)" = 2 ]'
cp "$T/old/.env" "$T/old/docker-compose.yml" "$D/"
mkdir -p "$D/snapshots"; head -c 2000 /dev/urandom | gzip -1 > "$D/snapshots/2026-09-28-full.tar.gz"
printf 'LOCALKEY\n' > "$D/.catalog_local_api_key"; chmod 600 "$D/.catalog_local_api_key"; rm -f "$ST/uploads"
out="$(menu '19\n1\nn\n\n0\n')"
check "old files below 24 GB, an import: the note that they do not limit the cache of MongoDB yet" 'grep -q "^  docker-compose.yml does not limit the cache of MongoDB yet, which takes$" <<< "$out" && grep -q "^  about half of the memory: menu option 2 writes the files again.$" <<< "$out" && grep -q "Cancelled." <<< "$out" && narrow "$out"'
rm -f "$ST/mem"; run generate >/dev/null
check "generate: the old .env gets the cache, the passwords stay" '[ "$(envv MONGO_WT_CACHE_GB)" = 11 ] && [ "$(envv MONGO_INITDB_ROOT_PASSWORD)" = "$(sed -n "s/^MONGO_INITDB_ROOT_PASSWORD=//p" "$T/old/.env")" ]'
sed -i '/^MONGO_WT_CACHE_GB=/d' "$D/.env"
: > "$LOG"; out="$(run up)"; rc=$?
check "new compose file, .env without the cache: added before the start, where generate writes it, not stale" '[ "$rc" -eq 0 ] && [ "$(envv MONGO_WT_CACHE_GB)" = 11 ] && grep -q "compose: mongo created with cache=11$" "$LOG" && grep -A1 "^MONGO_PORT_HOST=" "$D/.env" | grep -q "^MONGO_WT_CACHE_GB=11$" && ! grep -q "do not match the settings" <<< "$out" && ! grep -q "do not match the settings above" <<< "$(menu "0\n")"'

# 5. The kernel stopped MongoDB for lack of memory: named in the status and the check
installed
mem $(((14336 - 408) * 1048576)); touch "$ST/oom"
out="$(run status)"
check "status: the out-of-memory stop named, with the memory and how to get more on Linux" 'grep -q "^WARN MongoDB was stopped by the kernel: out of memory.$" <<< "$out" && grep -q "^  The engine has 14 GB of memory; at least 24 GB is recommended.$" <<< "$out" && grep -q "^  The memory of this server has to be raised by whoever runs it$" <<< "$out" && grep -q "^  (VM settings or hardware); MONGO_CACHE_GB (option 1) lowers MongoDB.s part.$" <<< "$out" && narrow "$out"'
out="$(run check)"
check "check: the out-of-memory stop named" 'grep -q "MongoDB was stopped by the kernel: out of memory" <<< "$out"'
rm -f "$ST/oom"; out="$(run status)"
check "status without a stop: nothing named" '! grep -q "stopped by the kernel" <<< "$out"'
mem $((32 * GIB)); touch "$ST/oom"; out="$(run status)"
check "status with 32 GB: the stop named with the memory and MONGO_CACHE_GB, nothing to raise" 'grep -q "^WARN MongoDB was stopped by the kernel: out of memory.$" <<< "$out" && grep -q "^  The engine has 32 GB of memory.$" <<< "$out" && grep -q "^  MONGO_CACHE_GB (option 1) lowers the part MongoDB takes.$" <<< "$out" && ! grep -q "has to be raised\|is recommended" <<< "$out"'

# 6. Import below 24 GB on Linux: warned and asked first (with piped input the prompts do not show; section 11
# has them in a terminal); an out-of-memory stop offers the same import again
installed
mem $(((14336 - 408) * 1048576)); touch "$ST/fail-oom"
out="$(menu '19\n1\ny\n\n\n0\n')"
check "import below 24 GB: warned, no offer on Linux; y imports" 'grep -q "This engine has 14 GB of memory; at least 24 GB is recommended." <<< "$out" && ! grep -q "macOS" <<< "$out" && [ -s "$ST/uploads" ]'
check "import: the failed job names the out-of-memory stop" 'grep -q "MongoDB was stopped by the kernel: out of memory." <<< "$out" && grep -q "The engine has 14 GB of memory; at least 24 GB is recommended." <<< "$out" && grep -q "MongoDB was stopped by the kernel" "$D/.jobs/1/log" && narrow "$out"'
check "import: yes to the same file again - imported again, the memory not asked about again" 'grep -q "A snapshot import replaces the data, so the half import does no harm." <<< "$out" && [ "$(grep -c "2026-09-28-full.tar.gz" "$ST/uploads")" -eq 2 ] && [ "$(grep -c "This engine has 14 GB" <<< "$out")" -eq 1 ] && grep -q "Job #2 finished: Snapshot import" <<< "$out"'
installed
mem $(((14336 - 408) * 1048576)); touch "$ST/fail-oom"
out="$(menu '19\n1\ny\nn\n\n0\n')"
check "import: no to the same file again - imported once" '[ "$(grep -c . "$ST/uploads")" -eq 1 ] && grep -q "A snapshot import replaces the data" <<< "$out" && [ ! -d "$D/.jobs/2" ]'
out="$(menu '19\n1\n\n\n0\n')"
check "import below 24 GB: Enter is no - cancelled, nothing imported" 'grep -q "This engine has 14 GB of memory" <<< "$out" && grep -q "Cancelled." <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 1 ]'
installed; mem $((32 * GIB))
out="$(menu '19\n1\n\n0\n')"
check "import with 32 GB: no warning, imported" '! grep -q "This engine has" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 1 ] && grep -q "Job #1 finished" <<< "$out"'
installed; mem $((32 * GIB)); touch "$ST/fail-oom"
out="$(menu '19\n1\n\n\n0\n')"
check "an out-of-memory stop with 32 GB: offered again too, nothing to raise" 'grep -q "MongoDB was stopped by the kernel: out of memory." <<< "$out" && grep -q "The engine has 32 GB of memory.$" <<< "$out" && ! grep -q "has to be raised\|is recommended" <<< "$out" && grep -q "A snapshot import replaces the data" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 2 ]'
installed; mem $((32 * GIB))
out="$(SHIM_FAIL_PLAIN=1 menu '19\n1\n\n0\n')"
check "a failed import without an out-of-memory stop: not offered again" '! grep -q "A snapshot import replaces the data" <<< "$out" && ! grep -q "stopped by the kernel" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 1 ]'
installed; mem $((32 * GIB)); touch "$ST/oom"; echo 1 > "$ST/restarts.c1"
out="$(SHIM_FAIL_PLAIN=1 menu '19\n1\n\n0\n')"
check "a stop from before the import (OOMKilled kept by the restart): not named for this failure, not offered again" '! grep -q "stopped by the kernel" <<< "$out" && ! grep -q "stopped by the kernel" "$D/.jobs/1/log" && ! grep -q "A snapshot import replaces the data" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 1 ] && grep -q "MongoDB was stopped by the kernel" <<< "$(run status)"'
installed; mem $(((14336 - 408) * 1048576)); touch "$ST/fail-oom"
out="$(run import "$D/snapshots/2026-09-28-full.tar.gz")"; rc=$?
check "import command without a terminal: the warning, the import, the stop named, no question" '[ "$rc" -ne 0 ] && grep -q "This engine has 14 GB of memory" <<< "$out" && grep -q "MongoDB was stopped by the kernel: out of memory" <<< "$out" && ! grep -q "A snapshot import replaces the data" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 1 ]'
CHAIN="$D/snapshots/chain-2026-09-28-full-to-2026-09-28.tsv"
installed; mem $(((14336 - 408) * 1048576)); touch "$ST/fail-oom"
printf 'full\t2026-09-28\t2000\tsha256:x\tfull/2026-09-28.tar.gz\t\n' > "$CHAIN"
out="$(menu '19\n1\ny\n\n\n0\n')"
check "chain import below 24 GB: warned, the chain imported again after the out-of-memory stop" 'grep -q "This engine has 14 GB of memory" <<< "$out" && grep -q "MongoDB was stopped by the kernel" <<< "$out" && grep -q "A snapshot import replaces the data" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 2 ] && grep -q "Job #2 finished: Snapshot import (1 files" <<< "$out"'
# a daily snapshot builds on the day before: after the stop it is not offered again by itself
installed; mem $(((14336 - 408) * 1048576)); touch "$ST/fail-oom"
sleep 1; head -c 2000 /dev/urandom | gzip -1 > "$D/snapshots/2026-09-29-daily.tar.gz"
out="$(menu '19\n1\n\ny\n\n0\n')"
check "daily snapshot after an out-of-memory stop: named, no claim that it replaces the data, not offered again" 'grep -q "MongoDB was stopped by the kernel" <<< "$out" && ! grep -q "replaces the data" <<< "$out" && grep -q "^  A daily snapshot builds on the day before: import again from a full snapshot$" <<< "$out" && grep -q "^  on (option 19, a chain from option 17).$" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 1 ] && grep -q 2026-09-29-daily.tar.gz "$ST/uploads" && [ ! -d "$D/.jobs/2" ] && narrow "$out"'
# the end of a failed synchronization job (option 20) names the stop too
installed; mem $(((14336 - 408) * 1048576)); touch "$ST/fail-oom"
mkdir -p "$D/.jobs/7"; echo import > "$D/.jobs/7/class"; echo "Synchronization" > "$D/.jobs/7/title"; echo running > "$D/.jobs/7/state"
: > "$D/.jobs/7/oom-marks"
(cd "$D" && umask 077 && printf 'X-Api-Key: LOCALKEY' > .jobs/7/secret && bash "$I" __job 7 self_sync_run </dev/null > .jobs/7/log 2>&1)
check "a failed synchronization job: its end names the out-of-memory stop" '[ "$(cat "$D/.jobs/7/state")" = failed ] && grep -q "sync" "$ST/uploads" && grep -q "^WARN MongoDB was stopped by the kernel: out of memory.$" "$D/.jobs/7/log"'

# 7. The install path outside the guided task (option 7, setup): below 24 GB asked, no stops it
fresh; mem $(((14336 - 408) * 1048576))
out="$(menu '7\nn\n\n0\n')"
check "option 7 below 24 GB: warned, no - nothing written" 'grep -q "This engine has 14 GB of memory; at least 24 GB is recommended." <<< "$out" && grep -q "Cancelled." <<< "$out" && [ ! -f "$D/.env" ]'
out="$(menu '7\ny\n\n0\n')"
check "option 7 below 24 GB: yes - written and started" '[ "$(envv MONGO_WT_CACHE_GB)" = 2 ] && [ -f "$ST/up" ]'
fresh; mem $(((14336 - 408) * 1048576))
out="$(run setup)"; rc=$?
check "setup without a terminal: the warning, then on" '[ "$rc" -eq 0 ] && grep -q "This engine has 14 GB of memory" <<< "$out" && [ -f "$D/.env" ] && [ "$(envv MONGO_WT_CACHE_GB)" = 2 ]'

# 8. macOS with a Podman machine of 14 GB on a Mac with 48 GB: the offer, only after a yes, without sudo
mac_fresh() { fresh "${1:-}"; echo running > "$ST/machine"; echo 14336 > "$ST/machine.mb"; mem $(((14336 - 408) * 1048576)); }
mac_fresh
out="$(SHIM_OS=Darwin menu '7\nn\nn\n\n0\n')"
check "macOS: no to the offer - the machine untouched, no to going on - nothing written" '! grep -q "^podman machine stop" "$LOG" && ! grep -q "^podman machine set" "$LOG" && grep -q "Cancelled." <<< "$out" && [ ! -f "$D/.env" ]'
mac_fresh
out="$(SHIM_OS=Darwin menu '7\ny\n\n0\n')"
check "macOS: yes - stop, set --memory 24576, start, in this order, as the user" 'before "^podman machine stop podman-machine-default$" "^podman machine set --memory 24576 podman-machine-default$" && before "^podman machine set --memory 24576" "^podman machine start podman-machine-default$" && ! grep -q sudo "$BAD"'
check "macOS: after the start it waits while podman-restart.service starts the containers, then writes the files" '[ "$(grep -c "^podman machine ssh podman-machine-default systemctl is-active podman-restart.service$" "$LOG")" -eq 2 ] && before "^podman machine start" "^podman machine ssh" && before "^podman machine ssh" "compose: mongo created" && narrow "$out"'
check "macOS: the machine has 24 GB, the installation goes on without asking" 'grep -q "The Podman machine has 24 GB of memory now." <<< "$out" && [ "$(envv MONGO_WT_CACHE_GB)" = 7 ] && before "^podman machine start" "compose: mongo created with cache=7"'
mac_fresh
out="$(SHIM_OS=Darwin SHIM_MEMSIZE=$((24 * GIB)) menu '7\nn\n\n0\n')"
check "macOS with 24 GB: no offer (macOS keeps 8 GB), then the question" 'grep -q "^  This Mac has 24 GB: not enough to give the containers 24 GB$" <<< "$out" && grep -q "^  and keep 8 GB for macOS.$" <<< "$out" && ! grep -q "^podman machine stop" "$LOG" && grep -q "Cancelled." <<< "$out"'
mac_fresh
out="$(SHIM_OS=Darwin SHIM_SET_FAIL=1 menu '7\ny\nn\n\n0\n')"
check "macOS: the memory cannot be set - the machine started again, said so, then the question" 'before "^podman machine set --memory" "^podman machine start podman-machine-default$" && grep -q "The memory of the Podman machine could not be changed (see above)." <<< "$out" && grep -q "Cancelled." <<< "$out" && [ "$(cat "$ST/machine")" = running ] && [ ! -f "$D/.env" ]'
mac_fresh
out="$(SHIM_OS=Darwin SHIM_SET_NOOP=1 menu '7\ny\nn\n\n0\n')"
check "macOS: the machine comes back with its old memory - a warning, not OK, then the question" 'grep -q "^WARN The Podman machine still has 14 GB of memory.$" <<< "$out" && ! grep -q "of memory now" <<< "$out" && grep -q "Cancelled." <<< "$out" && [ ! -f "$D/.env" ]'
mac_fresh 's/^MEM_ENGINE_WAIT=.*/MEM_ENGINE_WAIT=3/'
out="$(SHIM_OS=Darwin SHIM_START_DEAD=1 menu '7\ny\n\n0\n')"
check "macOS: Podman does not answer after the restart - said so, nothing written, no question" 'grep -q "Podman does not answer after the restart:" <<< "$out" && grep -q "start the Podman machine: podman machine start podman-machine-default." <<< "$out" && grep -q "Cancelled." <<< "$out" && ! grep -q "anyway?" <<< "$out" && [ ! -f "$D/.env" ]'
mac_fresh
mkdir -p "$D/.jobs/4"; echo stack > "$D/.jobs/4/class"; echo "Pull" > "$D/.jobs/4/title"; echo running > "$D/.jobs/4/state"
sleep 60 & echo $! > "$D/.jobs/4/pid"; sleeper=$!
out="$(SHIM_OS=Darwin menu '7\nn\n\n0\n')"
kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null
check "macOS with a job running: no restart of the machine, then the question" 'grep -q "^  A job is running (J): the Podman machine gets more memory with a restart,$" <<< "$out" && ! grep -q "^podman machine stop" "$LOG" && grep -q "Cancelled." <<< "$out"'
# I (the guided installation): 0 at the offer stops it like its other questions
mac_fresh
out="$(SHIM_OS=Darwin menu 'i\n\n\n\n\n0\n\n0\n')"
check "macOS, I: 0 at the offer for the Podman machine stops the guided task, nothing changed" '{ grep -q "^  macOS gives the Podman machine memory only as it uses it.$" <<< "$out" && grep -q "Stopped. I starts it again" <<< "$out" && ! grep -q "^podman machine stop" "$LOG" && [ ! -f "$D/.env" ]; } || { tail -n 25 <<< "$out" | sed "s/^/  | /"; false; }'
mac_fresh
out="$(SHIM_OS=Darwin menu 'i\n\n\n\n\ny\n\n\n\n0\n')"
check "macOS, I: yes at the offer - the machine gets 24 GB, the installation goes on without the question" '{ before "^podman machine set --memory 24576" "compose: mongo created with cache=7" && grep -q "The Podman machine has 24 GB of memory now." <<< "$out" && grep -q "The Catalog is installed" <<< "$out"; } || { tail -n 25 <<< "$out" | sed "s/^/  | /"; false; }'

# 9. macOS, an import with the Catalog running: no to the offer and on with 14 GB - the out-of-memory stop;
# then yes - the machine and the Catalog restart, the health check, then the same import again
mac_running() {
  mac_fresh "${1:-}"
  (cd "$D" && SHIM_OS=Darwin bash "$I" generate </dev/null >/dev/null 2>&1 && SHIM_OS=Darwin bash "$I" up </dev/null >/dev/null 2>&1)
  mkdir -p "$D/snapshots"; head -c 2000 /dev/urandom | gzip -1 > "$D/snapshots/2026-09-28-full.tar.gz"
  printf 'LOCALKEY\n' > "$D/.catalog_local_api_key"; chmod 600 "$D/.catalog_local_api_key"
  : > "$LOG"; rm -f "$ST/uploads"
}
mac_running; touch "$ST/fail-oom"
out="$(SHIM_OS=Darwin menu '19\n1\nn\ny\ny\n\n\n0\n')"
check "macOS import: the stop named with the commands for the Podman machine, one per line" 'grep -q "MongoDB was stopped by the kernel: out of memory." <<< "$out" && grep -q "^  The engine has 14 GB of memory; at least 24 GB is recommended.$" <<< "$out" && grep -q "^  More memory for the Podman machine (macOS gives it only what it uses):$" <<< "$out" && grep -q "^      podman machine stop podman-machine-default$" <<< "$out" && grep -q "^      podman machine set --memory 24576 podman-machine-default$" <<< "$out" && grep -q "^      podman machine start podman-machine-default$" <<< "$out" && narrow "$out"'
check "macOS import: 24 GB, the Catalog started again and healthy, then the same import again" 'before "^podman machine set --memory 24576" "compose: mongo created with cache=7" && grep -q "Job #2 finished: Start the Catalog again" <<< "$out" && grep -q "All 2 services run and Catalog Web answers" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 2 ] && grep -q "Job #3 finished: Snapshot import" <<< "$out"'
check "macOS import: the start job before the second upload, mongo created again (OOMKilled gone)" '[ "$(grep -c "^podman machine start" "$LOG")" -eq 1 ] && [ ! -f "$ST/oom" ] && [ "$(envv MONGO_WT_CACHE_GB)" = 7 ] && grep -q "Start the Catalog again" "$D/.jobs/2/title" && grep -q "Snapshot import" "$D/.jobs/3/title"'
mac_running 's/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="4"/'
out="$(SHIM_OS=Darwin SHIM_UNHEALTHY=1 menu '19\n1\ny\n\n0\n')"
check "macOS import: the Catalog does not become healthy after the restart - said so, the import cancelled" 'grep -q "The Podman machine has 24 GB of memory now." <<< "$out" && grep -q "Job #1 failed: Start the Catalog again" <<< "$out" && grep -q "^WARN The Catalog does not run cleanly again yet.$" <<< "$out" && grep -q "Cancelled." <<< "$out" && ! grep -q "anyway?" <<< "$out" && [ ! -s "$ST/uploads" ]'

# 10. Colima and Docker Desktop
for kind in colima docker; do
  fresh "s/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=\"$kind\"/"
  mkdir -p "$T/home/.colima/default" "$D/snapshots"; printf 'cpu: 6\nmemory: 14\nvmType: vz\n' > "$T/home/.colima/default/colima.yaml"
  touch "$ST/colima.running"; head -c 2000 /dev/urandom | gzip -1 > "$D/snapshots/2026-09-28-full.tar.gz"
  if [ "$kind" = colima ]; then
    out="$(cd "$D" && printf '19\n1\ny\n0\n\n0\n' | SHIM_OS=Darwin SHIM_KIND=colima PATH="$DPATH" bash "$I" menu 2>&1)"
    check "Colima: yes - colima stop, then colima start with its CPUs and 24 GB, no question after" 'grep -q "This engine has 14 GB of memory" <<< "$out" && before "^colima stop$" "^colima start --cpu 6 --memory 24$" && grep -q "The Colima VM has 24 GB of memory now." <<< "$out" && grep -q "Access to the local catalog" <<< "$out" && grep -q "^      colima stop && colima start --cpu 6 --memory 24$" <<< "$out" && ! grep -q "^brew services st" "$LOG" && narrow "$out"'
    # brew services starts Colima at login: its colima start -f started the VM (SHIM_BREW_OWNS) or ends at once
    # while the VM runs ("stopped" for brew) - stopped through brew services, the memory into colima.yaml
    for svc in started stopped; do
      printf 'cpu: 6\nmemory: 14\nvmType: vz\n' > "$T/home/.colima/default/colima.yaml"; rm -f "$ST/colima.gb"
      touch "$ST/colima.running"; echo "$svc" > "$ST/brew.colima"; : > "$LOG"
      out="$(cd "$D" && printf '19\n1\ny\n0\n\n0\n' | SHIM_OS=Darwin SHIM_KIND=colima SHIM_BREW_OWNS="$([ "$svc" = started ] && echo 1)" PATH="$DPATH" bash "$I" menu 2>&1)"
      check "Colima under brew services ($svc): brew services stop, memory: 24 in colima.yaml, brew services start" 'before "^brew services stop colima$" "^brew services start colima$" && ! grep -q "^colima start" "$LOG" && grep -q "^memory: 24$" "$T/home/.colima/default/colima.yaml" && [ "$(grep -c "^memory:" "$T/home/.colima/default/colima.yaml")" -eq 1 ] && grep -q "The Colima VM has 24 GB of memory now." <<< "$out" && grep -q "^      brew services stop colima; colima stop$" <<< "$out" && grep -q "^      memory: 24 in $T/home/.colima/default/colima.yaml$" <<< "$out" && [ "$(cat "$ST/brew.colima")" = started ] && narrow "$out"'
      if [ "$svc" = started ]; then
        check "Colima under brew services, the VM stopped with it: no colima stop" '! grep -q "^colima stop" "$LOG"'
      else
        check "Colima under brew services, the VM still runs: colima stop before the start" 'before "^colima stop$" "^brew services start colima$"'
      fi
    done
    echo none > "$ST/brew.colima"
  else
    out="$(cd "$D" && printf '19\n1\nn\n\n0\n' | SHIM_OS=Darwin SHIM_KIND=docker PATH="$DPATH" bash "$I" menu 2>&1)"
    check "Docker Desktop: where its memory is set, nothing changed" 'grep -q "This engine has 8 GB of memory; at least 24 GB is recommended." <<< "$out" && grep -q "Docker Desktop: Settings > Resources > Memory - 24 GB, then Apply & restart." <<< "$out" && grep -q "Cancelled." <<< "$out" && ! grep -q "^colima" "$LOG"'
  fi
done

# 10a. Docker clears OOMKilled when the restart policy starts the container again: its oom events count.
# Docker Engine on Linux with 14 GB, then Docker Desktop with 8 GB.
dk() { (cd "$D" && PATH="$DPATH" bash "$I" "$@" </dev/null 2>&1); }
docker_installed() {
  fresh "s/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=\"docker\"/"
  dk generate >/dev/null; dk up >/dev/null
  mkdir -p "$D/snapshots"; head -c 2000 /dev/urandom | gzip -1 > "$D/snapshots/2026-09-28-full.tar.gz"
  printf 'LOCALKEY\n' > "$D/.catalog_local_api_key"; chmod 600 "$D/.catalog_local_api_key"
  : > "$LOG"; rm -f "$ST/uploads"
}
docker_installed; mem $(((14336 - 408) * 1048576)); touch "$ST/fail-oom"
out="$(cd "$D" && printf '19\n1\ny\n\n\n0\n' | PATH="$DPATH" bash "$I" menu 2>&1)"
check "Docker: the stop of the import named from its oom event (OOMKilled cleared by the restart), imported again" 'grep -q "^docker events --since [0-9]* --until [0-9]* --filter type=container --filter event=oom" "$LOG" && grep -q "MongoDB was stopped by the kernel: out of memory." "$D/.jobs/1/log" && grep -q "A snapshot import replaces the data" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 2 ] && grep -q "Job #2 finished: Snapshot import" <<< "$out"'
out="$(dk status)"
check "Docker: status names the stop of the last 24 hours" 'grep -q "^docker events --since 24h --until" "$LOG" && grep -q "^WARN MongoDB was stopped by the kernel: out of memory.$" <<< "$out"'
docker_installed; mem $((32 * GIB)); echo "$(($(date +%s) - 100)) mongo" > "$ST/oom-events"
out="$(cd "$D" && printf '19\n1\n\n0\n' | SHIM_FAIL_PLAIN=1 PATH="$DPATH" bash "$I" menu 2>&1)"
check "Docker: a stop from before the import is not named for its failure, not offered again" '! grep -q "stopped by the kernel" "$D/.jobs/1/log" && ! grep -q "replaces the data" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 1 ] && grep -q "stopped by the kernel" <<< "$(dk check)"'
docker_installed; touch "$ST/fail-oom"
out="$(cd "$D" && printf '19\n1\ny\n\n\n0\n' | SHIM_OS=Darwin SHIM_KIND=docker PATH="$DPATH" bash "$I" menu 2>&1)"
check "Docker Desktop: after the stop its Settings named once, then the same file again" 'grep -q "MongoDB was stopped by the kernel" "$D/.jobs/1/log" && [ "$(awk "/stopped by the kernel/ { n = 0 } /Docker Desktop: Settings > Resources > Memory/ { n++ } END { print n + 0 }" <<< "$out")" -eq 1 ] && [ "$(grep -c . "$ST/uploads")" -eq 2 ] && narrow "$out"'

# 11. In a terminal (the prompts show): the questions as they read
if command -v script >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  # tty_run COMMAND [PATTERN KEYS]... -> runs COMMAND in a pseudo-terminal: waits for each PATTERN in what the
  # terminal shows after the keys before, then types its KEYS; prints what the terminal showed
  tty_run() {
    local cmd="$1" log="$T/tty.log" i from=1
    shift
    : > "$log"
    { while [ $# -ge 2 ]; do
        for i in $(seq 1 120); do tail -c +"$from" "$log" 2>/dev/null | grep -aq -- "$1" && break; sleep 0.5; done
        sleep 0.5
        from=$(($(wc -c < "$log") + 1))
        printf "$2"
        shift 2
      done
      for i in $(seq 1 120); do grep -aq TTY-END "$log" 2>/dev/null && break; sleep 0.5; done
    } | TERM=dumb NO_COLOR=1 timeout 150 script -qfec "stty sane; cd $D && $cmd; echo TTY-END" /dev/null > "$log" 2>&1
    tr -d '\r' < "$log"
  }
  installed; mem $(((14336 - 408) * 1048576)); touch "$ST/fail-oom"
  out="$(tty_run "bash $I import $D/snapshots/2026-09-28-full.tar.gz" "anyway?" 'y\n' "again?" '\n')"
  check "terminal, import: the question below 24 GB and the same file again" '{ grep -q "Continue with 14 GB anyway? \[y/N\]" <<< "$out" && grep -q "Import the same file again? \[Y/n\]" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 2 ] && grep -q TTY-END <<< "$out"; } || { tail -n 30 <<< "$out" | sed "s/^/  | /"; false; }'
  mac_fresh
  out="$(SHIM_OS=Darwin tty_run "bash $I setup" "now?" 'n\n' "anyway?" 'n\n')"
  check "terminal, macOS setup: the offer for the Podman machine, then the question; no - nothing done" '{ grep -q "^  macOS gives the Podman machine memory only as it uses it.$" <<< "$out" && grep -q "^  The machine restarts (about a minute).$" <<< "$out" && grep -q "^Give the Podman machine 24 GB now? \[Y/n\]" <<< "$out" && narrow "$out" && grep -q "Continue with 14 GB anyway? \[y/N\]" <<< "$out" && ! grep -q "^podman machine stop" "$LOG" && [ ! -f "$D/.env" ]; } || { tail -n 30 <<< "$out" | sed "s/^/  | /"; false; }'
  mac_running; touch "$ST/fail-oom"
  out="$(SHIM_OS=Darwin tty_run "bash $I import $D/snapshots/2026-09-28-full.tar.gz" "now?" 'n\n' "anyway?" 'y\n' "now?" 'y\n' "again?" '\n')"
  check "terminal, macOS import with the Catalog running: it restarts too; after the stop the offer, then the same file again" '{ grep -q "^  The machine restarts (about a minute), and the Catalog with it.$" <<< "$out" && [ "$(grep -c "^Give the Podman machine 24 GB now? \[Y/n\]" <<< "$out")" -eq 2 ] && narrow "$out" && grep -q "Import the same file again? \[Y/n\]" <<< "$out" && [ "$(grep -c . "$ST/uploads")" -eq 2 ] && grep -q "All 2 services run and Catalog Web answers" <<< "$out"; } || { tail -n 40 <<< "$out" | sed "s/^/  | /"; false; }'
else
  echo "SKIP: script (util-linux) missing - no test of the questions in a terminal"
fi

check "fakes: no unknown podman, docker, colima, compose, curl, sysctl or sudo call" '[ ! -s "$BAD" ] || { sort "$BAD" | uniq -c; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
