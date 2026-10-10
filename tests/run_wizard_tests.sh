#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/w"
rm -rf "$T"; mkdir -p "$T/bin" "$T/state"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# LOG: the calls of one case (emptied by fresh/installed). BAD: calls the fakes do not know, for the whole suite.
export LOG="$T/calls.log" ST="$T/state" BAD="$T/bad.log"
: > "$LOG"; : > "$BAD"

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; fmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -D|-H|--connect-timeout|--max-time|--retry|--retry-delay|--proto|-K) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $url" >> "$LOG"
emit() { if [ -n "$out" ] && [ "$out" != "-" ]; then cat > "$out"; else cat; fi; }
code=200
case "$url" in
  http://localhost:*/) printf '' | emit ;;
  https://github.com/docker/compose/releases/latest) printf 'HTTP/2 302\r\nlocation: https://github.com/docker/compose/releases/tag/v5.6.0\r\n\r\n' | emit ;;
  https://raw.githubusercontent.com/*)
    if [ -f "$ST/new-installer.sh" ]; then emit < "$ST/new-installer.sh"; else code=404; printf '404' | emit; fi ;;
  https://hub.docker.com/v2/repositories/raynetgmbh/rayventory-catalog*/tags*)
    printf '%s' '{"count":2,"next":null,"results":[{"name":"stable","digest":"sha256:aaaa"},{"name":"26.3.4789.148","digest":"sha256:aaaa"},{"name":"25.4.4191.133","digest":"sha256:cccc"}]}' | emit ;;
  https://*/tags/list*) printf '%s' '{"name":"x","tags":[]}' | emit ;;
  *) code=404; printf '' | emit ;;
esac
[ -n "$fmt" ] && printf '%s' "${fmt//%\{http_code\}/$code}"
[ "$code" -ge 400 ] && exit 22
exit 0
EOF

# Fake rootful Podman 5.7 with "podman compose": $ST/up = the containers exist (c1 mongo, c2 catalog-web,
# c3 worker-search, started from the folder in $ST/wd), $ST/net = the network of the project exists,
# $ST/vols = the data volumes inst_db_data and inst_minio_storage exist (minus those named in $ST/vols.rm),
# $ST/images = the local images (docker.io-qualified, as Podman stores them), $ST/catalog_tag and
# $ST/mongo_tag = the tags the containers run.
# SHIM_FOREIGN_DIR: the containers of the project were started from that folder (SHIM_FOREIGN_IMAGE: the
# image of its catalog-web). SHIM_PODMAN_DOWN: Podman does not answer. SHIM_VOL_BUSY: data volumes cannot
# be removed. SHIM_CONFIG_FAIL: podman compose config fails (broken files). SHIM_SOCKET_DOWN: podman.socket
# is not active (systemctl). A call the fakes do not know is written to $BAD and fails.
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
echo "podman $ARGS" >> "$LOG"
bad() { echo "UNHANDLED podman $ARGS" | tee -a "$LOG" >> "$BAD"; echo "Error: the fake podman does not know: $ARGS" >&2; exit 125; }
running() { [ -f "$ST/up" ]; }
# containers of another existing folder (a folder that is gone is this installation, moved)
foreign() { [ -n "${SHIM_FOREIGN_DIR:-}" ] && [ -d "$SHIM_FOREIGN_DIR" ]; }
wdir() { if [ -n "${SHIM_FOREIGN_DIR:-}" ]; then printf '%s' "$SHIM_FOREIGN_DIR"; else cat "$ST/wd" 2>/dev/null || printf '%s' "$PWD"; fi; }
proj() { basename -- "$(wdir)" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'; }
tag() { local t; t="$(cat "$ST/catalog_tag" 2>/dev/null)"; printf '%s' "${t:-25.4.4191.133}"; }
svc_of() { case "$1" in c1) echo mongo ;; c2) echo catalog-web ;; c3) echo worker-search ;; esac; }
img_of() {
  case "$1" in
    c1) echo "docker.io/library/mongo:$(cat "$ST/mongo_tag" 2>/dev/null || echo 8)" ;;
    c2) echo "docker.io/${SHIM_FOREIGN_IMAGE:-raynetgmbh/rayventory-catalog:$(tag)}" ;;
    c3) echo "docker.io/raynetgmbh/rayventory-catalog-worker:$(tag)" ;;
  esac
}
is_ct() { running && case "$1" in c1|c2|c3) true ;; *) false ;; esac; }
img_id() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
# Podman gets qualified names from the installer (a short name would go through registries.conf)
img_here() {
  case "$1" in docker.io/*|ghcr.io/*) ;; *) bad ;; esac
  grep -qxF -- "$1" "$ST/images" 2>/dev/null
}
VOLS="inst_db_data inst_minio_storage"
vol_exists() { [ -f "$ST/vols" ] && [[ " $VOLS " == *" $1 "* ]] && ! grep -qxF -- "$1" "$ST/vols.rm" 2>/dev/null; }
envval() { sed -n "s/^$1=//p" "${ENVF:-.env}" 2>/dev/null | tail -n 1 | tr -d '"'; }
# rp TEXT VALUE: every TEXT in $out becomes VALUE (literally, the same in bash 4.2 and 5.x)
rp() { local r=""; while [[ "$out" == *"$1"* ]]; do r="$r${out%%"$1"*}$2"; out="${out#*"$1"}"; done; out="$r$out"; }
match() { # ID FILTER
  case "$2" in
    label=com.docker.compose.project=*) [ "${2#*project=}" = "$(proj)" ] ;;
    label=com.docker.compose.service=*) [ "${2#*service=}" = "$(svc_of "$1")" ] ;;
    volume=*) [ "$1" = c1 ] && [ "${2#volume=}" = "$(proj)_db_data" ] ;;
    ancestor=*) [ "${2#ancestor=}" = "$(img_id "$(img_of "$1")")" ] ;;
    *) bad ;;
  esac
}
case "${1:-}" in
  --version) echo "podman version 5.7.0"; exit 0 ;;
esac
[ -n "${SHIM_PODMAN_DOWN:-}" ] && { echo "Error: unable to connect to Podman: the storage of the engine cannot be opened" >&2; exit 125; }
case "${1:-}" in
  info)
    case "$#|${2:-}|${3:-}" in
      "1||") echo "host: (fake)" ;;
      "3|--format|{{.Host.Security.Rootless}}") echo "${SHIM_ROOTLESS:-false}" ;;
      "3|--format|{{.Host.Kernel}}") echo "${SHIM_KERNEL:-6.8.0-generic}" ;;
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
    for id in c1 c2 c3; do
      ok=1
      for f in ${filters[@]+"${filters[@]}"}; do match "$id" "$f" || ok=0; done
      [ "$ok" = 1 ] && echo "$id"
    done ;;
  container)
    { [ "${2:-}" = inspect ] && [ "${3:-}" = --format ] && [ $# -ge 5 ]; } || bad
    fmt="$4"; shift 4; rc=0
    for id in "$@"; do
      if ! is_ct "$id"; then echo "Error: no such container $id" >&2; rc=125; continue; fi
      wd="$(wdir)"; out="$fmt"
      rp '{{index .Config.Labels "com.docker.compose.project"}}' "$(proj)"
      rp '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$wd"
      rp '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$wd/docker-compose.yml"
      rp '{{index .Config.Labels "com.docker.compose.project.environment_file"}}' "$wd/.env"
      rp '{{index .Config.Labels "com.docker.compose.service"}}' "$(svc_of "$id")"
      rp '{{.Config.Image}}' "$(img_of "$id")"
      rp '{{.Name}}' "$(proj)-$(svc_of "$id")-1"
      rp '{{.State.Status}}' running
      # Podman 5.x: a container without a healthcheck has no .State.Health
      rp '{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}' none
      rp '{{.RestartCount}}' 0
      case "$out" in *'{{'*) bad ;; esac
      printf '%s\n' "$out"
    done
    exit "$rc" ;;
  exec)
    shift
    is_ct "${1:-}" || { echo "Error: no container with name or ID \"${1:-}\" found: no such container" >&2; exit 125; }
    [ "$1" = c1 ] || bad
    shift
    case "$*" in
      "mongod --version") ;; # no version: the settings name it (as before)
      "sh -c "*) printf 'MONGODUMP-ARCHIVE' ;;
      *) bad ;;
    esac ;;
  rm)
    { [ "${2:-}" = -f ] && [ $# -ge 3 ]; } || bad
    shift 2
    for id in "$@"; do is_ct "$id" || { echo "Error: no container with ID or name \"$id\" found: no such container" >&2; exit 1; }; done
    foreign || rm -f "$ST/up"
    printf '%s\n' "$@" ;;
  volume)
    case "${2:-}" in
      ls)
        { [ $# -eq 5 ] && [ "$3" = -q ] && [ "$4" = --filter ]; } || bad
        case "$5" in label=com.docker.compose.project=*) ;; *) bad ;; esac
        if [ "${5#*project=}" = inst ]; then
          for v in $VOLS; do vol_exists "$v" && echo "$v"; done
        fi ;;
      exists) [ $# -eq 3 ] || bad; vol_exists "$3" || exit 1 ;;
      rm)
        [ $# -eq 3 ] || bad
        vol_exists "$3" || { echo "Error: no volume with name \"$3\" found: no such volume" >&2; exit 1; }
        [ -n "${SHIM_VOL_BUSY:-}" ] && { echo "Error: volume $3 is being used by the following container(s): x1: volume is being used" >&2; exit 2; }
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
        case "$5" in label=com.docker.compose.project=*) ;; *) bad ;; esac
        [ -f "$ST/net" ] && [ "${5#*project=}" = "$(proj)" ] && echo "$(proj)_default" ;;
      rm) [ $# -eq 3 ] || bad; rm -f "$ST/net"; echo "$3" ;;
      *) bad ;;
    esac ;;
  image)
    case "${2:-}" in
      exists) [ $# -eq 3 ] || bad; img_here "$3" || exit 1 ;;
      inspect)
        { [ $# -eq 5 ] && [ "$3" = --format ] && [ "$4" = '{{.ID}}' ]; } || bad
        img_here "$5" || { echo "Error: $5: image not known" >&2; exit 125; }
        img_id "$5" ;;
      rm)
        [ $# -eq 3 ] || bad
        img_here "$3" || { echo "Error: $3: image not known" >&2; exit 1; }
        for id in c1 c2 c3; do
          if running && [ "$(img_of "$id")" = "$3" ]; then
            echo "Error: image used by $id: image is in use by a container: consider listing external containers and force-removing image" >&2
            exit 2
          fi
        done
        grep -vxF -- "$3" "$ST/images" > "$ST/images.new"; mv "$ST/images.new" "$ST/images"
        echo "Untagged: $3" ;;
      *) bad ;;
    esac ;;
  compose)
    shift
    # "podman compose" runs the provider the installer names, never one from DOCKER_HOST
    if [ "${PODMAN_COMPOSE_PROVIDER:-}" != "$RN1_COMPOSE_PROVIDER" ] || [ -n "${DOCKER_HOST:-}" ]; then
      echo "UNHANDLED podman compose: PODMAN_COMPOSE_PROVIDER=${PODMAN_COMPOSE_PROVIDER:-} DOCKER_HOST=${DOCKER_HOST:-}" | tee -a "$LOG" >> "$BAD"
    fi
    # the provider talks to Podman through its API socket
    [ -n "${SHIM_SOCKET_DOWN:-}" ] && { echo "Cannot connect to the Docker daemon at unix:///run/podman/podman.sock. Is the docker daemon running?" >&2; exit 1; }
    ENVF=".env"; CF="docker-compose.yml"
    while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; --env-file) ENVF="$2"; shift 2 ;; -f) CF="$2"; shift 2 ;; *) break ;; esac; done
    sub="${1:-}"; [ $# -gt 0 ] && shift
    case "$sub" in
      config)
        [ -n "${SHIM_CONFIG_FAIL:-}" ] && { echo "yaml: line 3: mapping values are not allowed in this context" >&2; exit 1; }
        case "$*" in
          --services) printf '%s\n' mongo catalog-web worker-search ;;
          --volumes) printf '%s\n' db_data minio_storage ;;
          --images)
            # the images of the compose file as written there, the variables from the env file
            re='[$][{]([A-Za-z_][A-Za-z0-9_]*)[}]'
            sed -n 's/^    image: *//p' "$CF" | while IFS= read -r out; do
              while [[ "$out" =~ $re ]]; do
                v="${BASH_REMATCH[1]}"
                rp "\${$v}" "$(envval "$v")"
              done
              printf '%s\n' "$out"
            done ;;
          --quiet) ;;
          "") cat "$CF" ;;
          *) bad ;;
        esac ;;
      ps)
        case "$*" in
          "-q "*)
            [ $# -eq 2 ] || bad
            if running; then case "$2" in mongo) echo c1 ;; catalog-web) echo c2 ;; worker-search) echo c3 ;; esac; fi ;;
          "--services --filter status=running") running && printf '%s\n' mongo catalog-web worker-search ;;
          "") echo "NAME STATUS"; running && printf '%s\n' "inst-mongo-1 Up" "inst-catalog-web-1 Up" "inst-worker-search-1 Up" ;;
          *) bad ;;
        esac ;;
      pull|logs) ;;
      restart) [ "$*" = "-t 30" ] || bad ;;
      down)
        case "$*" in "--remove-orphans"|"-v --remove-orphans") ;; *) bad ;; esac
        [ -n "${SHIM_CONFIG_FAIL:-}" ] && exit 1
        rm -f "$ST/up" "$ST/net"
        if [[ " $* " == *" -v "* ]] && [ -z "${SHIM_VOL_BUSY:-}" ]; then rm -f "$ST/vols" "$ST/vols.rm"; fi ;;
      up)
        [ "$*" = "-d --remove-orphans" ] || bad
        touch "$ST/up" "$ST/net" "$ST/vols"; rm -f "$ST/vols.rm"
        printf '%s\n' "docker.io/library/mongo:$(envval MONGO_TAG)" "docker.io/$(envval CATALOG_IMAGE)" "docker.io/$(envval CATALOG_WORKER_IMAGE)" > "$ST/images"
        envval CATALOG_IMAGE | sed 's/.*://' > "$ST/catalog_tag"
        envval MONGO_TAG > "$ST/mongo_tag"
        printf '%s\n' "$PWD" > "$ST/wd" ;;
      *) bad ;;
    esac ;;
  *) bad ;;
esac
exit 0
EOF
# The Docker Compose binary behind "podman compose" (RN1_COMPOSE_PROVIDER)
cat > "$T/bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
echo "docker-compose $*" >> "$LOG"
case "$*" in
  version) echo "Docker Compose version v5.6.0" ;;
  "version --short") echo "5.6.0" ;;
  *) echo "UNHANDLED docker-compose $*" | tee -a "$LOG" >> "$BAD"; exit 1 ;;
esac
EOF
# The installer uses Podman only: a docker call is a leftover
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "FORBIDDEN docker $*" | tee -a "$LOG" >> "$BAD"
echo "docker: not part of these tests" >&2
exit 99
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-active --quiet podman.socket") [ -z "${SHIM_SOCKET_DOWN:-}" ] ;;
  "is-enabled podman-restart.service") echo enabled ;;
  *) echo "UNHANDLED systemctl $*" | tee -a "$LOG" >> "$BAD"; exit 1 ;;
esac
EOF
REAL_UNAME="$(command -v uname)"
cat > "$T/bin/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-r" ]; then echo "\${SHIM_KERNEL:-6.8.0-generic}"; else exec "$REAL_UNAME" "\$@"; fi
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${SHIM_TZ:-Europe/Berlin}"\n' > "$T/bin/timedatectl"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" RN1_COMPOSE_PROVIDER="$T/bin/docker-compose"
# the calls that change containers, networks, volumes or images
MUTATING='compose.* (down|up)|^podman (rm|volume rm|network rm|image rm) '

D="$T/inst"
I="$D/rn1-technology-catalog-installer.sh"
fresh() {
  rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$NEW" "$I"
  sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="10"/' "$I"
  : > "$LOG"
}
installed() {
  fresh
  (cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  touch "$ST/up" "$ST/net" "$ST/vols"; echo "25.4.4191.133" > "$ST/catalog_tag"; echo 8 > "$ST/mongo_tag"; echo "$D" > "$ST/wd"
  printf '%s\n' docker.io/library/mongo:8 docker.io/raynetgmbh/rayventory-catalog:25.4.4191.133 docker.io/raynetgmbh/rayventory-catalog-worker:25.4.4191.133 > "$ST/images"
  : > "$LOG"
}

# 1. The plain menu starts with the guided tasks and names them again above the prompt
fresh
out="$(printf '0\n' | bash "$I" menu 2>&1)"
check "menu: START HERE with I, U and R first" 'grep -q "START HERE" <<< "$out" && grep -q "I) INSTALL" <<< "$out" && grep -q "U) UPDATE" <<< "$out" && grep -q "R) REMOVE" <<< "$out" && [ "$(grep -n "START HERE" <<< "$out" | cut -d: -f1)" -lt "$(grep -n " SETUP" <<< "$out" | cut -d: -f1)" ]'
check "menu: the tasks named above the prompt" 'tail -n 2 <<< "$out" | grep -q "I install . U update . R remove"'
check "help: guided tasks explained, 7 no longer the start" 'out2="$(printf "h\n\n0\n" | bash "$I" menu 2>&1)"; grep -q "START HERE - GUIDED TASKS" <<< "$out2" && ! grep -q "Start here on a new server" <<< "$out2"'

# 2. Install: check, settings, files, start with health check, data later, summary
fresh
out="$(printf 'i\ny\ny\n9090\ny\ny\ny\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install: all six steps shown" '( for s in 1 2 3 4 5 6; do grep -q "Install . step $s of 6" <<< "$out" || exit 1; done )'
check "install: setting from the questions written" 'grep -q "^CATALOG_WEB_PORT=\"9090\"$" "$I" && grep -q "CATALOG_WEB_PORT = \"9090\"" <<< "$out"'
check "install: files generated, stack started" '[ -f "$D/.env" ] && [ -f "$D/docker-compose.yml" ] && grep -q "^podman compose .*--env-file .env -f docker-compose.yml up -d --remove-orphans$" "$LOG"'
check "install: health check, addresses once, summary" 'grep -q "Health check" <<< "$out" && grep -q "The Catalog is installed" <<< "$out" && [ "$(grep -c "Catalog Web (direct)" <<< "$out")" -eq 1 ] && grep -q "http://.*:9090" <<< "$out"'
check "install: no data yet named in the summary" 'grep -q "The Catalog has no data yet" <<< "$out"'

# 3. Install on a folder that is already installed: repair, data, update or remove
out="$(printf 'i\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: existing installation found, cancel changes nothing" 'grep -q "This folder already has an installation" <<< "$out" && grep -q "Continue with the catalog data" <<< "$out" && grep -q "Cancelled" <<< "$out"'
out="$(printf 'i\n2\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: continues with the catalog data (step 5)" 'grep -q "Install . step 5 of 6" <<< "$out" && ! grep -q "Install . step 3 of 6" <<< "$out"'

# 4. Repair keeps the installed version (an upgrade belongs to U with backup and rollback)
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$I"
out="$(printf 'i\n1\ny\ny\n\ny\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "repair: version of the installation kept" 'grep -q "the repair keeps 25.4.4191.133" <<< "$out" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$I" && grep -q "^CATALOG_IMAGE=.*:25.4.4191.133$" "$D/.env"'

# 5. Install stops when a step is declined or the input ends; nothing is half written
fresh
out="$(printf 'i\ny\ny\n\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "install: declined before the files - nothing written" '[ ! -f "$D/.env" ] && grep -q "Stopped. I starts it again" <<< "$out"'
fresh
printf 'i\ny\n' | bash "$I" menu >/dev/null 2>&1
check "install: end of input at a question changes no setting" 'grep -q "^INSTALL_NGINX_PROXY_MANAGER=\"true\"$" "$I"'

# 6. A port that another setting uses is refused at once
fresh
out="$(printf 'i\ny\ny\n80\n\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "install: port taken by another setting refused" 'grep -q "Port 80 is already set for NPM_HTTP_PORT" <<< "$out" && grep -q "^CATALOG_WEB_PORT=\"8080\"$" "$I"'

# 7. A step that fails stops the task (no start with broken files)
fresh
sed -i 's/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="0900"/' "$I"
out="$(printf 'i\ny\ny\n\ny\n\n0\n' | bash "$I" menu 2>&1)"
check "install: failed files step stops before the start" 'grep -q "The files could not be written" <<< "$out" && ! grep -q "compose.* up" "$LOG" && ! grep -q "Install . step 4 of 6" <<< "$out"'

# 7b. Step 5: a cancelled self-sync is not reported as set up
installed
out="$(printf 'i\n2\n1\n\n\n0\n' | bash "$I" menu 2>&1)"
check "install: cancelled data step - summary says there is no data yet" 'grep -q "The Catalog has no data yet" <<< "$out" && ! grep -q "synchronizes itself every day" <<< "$out"'

# 7c. A folder the installer cannot write to
fresh
chmod 555 "$D"
if ! touch "$D/probe" 2>/dev/null; then
  out="$(printf 'i\n\n0\n' | bash "$I" menu 2>&1)"
  check "install: folder not writable - stops at once" 'grep -q "is not writable - the installation writes its files there" <<< "$out" && [ ! -e "$D/.jobs" ]'
fi
chmod 755 "$D"

# 8. MongoDB 8 on a kernel 6.19 to 7.0.x: no switch to 7.0 any more, the files get the rseq workaround
fresh
out="$(printf 'i\nn\n\n0\n' | SHIM_KERNEL=7.0.0-15-generic bash "$I" menu 2>&1)"
check "install: MongoDB 8 kept on kernel 7.0.0, the workaround named, the check passes" 'grep -q "starts with GLIBC_TUNABLES=glibc.pthread.rseq=1" <<< "$out" && grep -q "^MONGO_TAG=\"8\"$" "$I" && ! grep -q "Use MongoDB 7.0 instead" <<< "$out" && grep -q "All required checks passed" <<< "$out" && ! grep -q "lack the workaround" <<< "$out"'
GLIBC_LINE='      GLIBC_TUNABLES: "${MONGO_GLIBC_TUNABLES:-glibc.pthread.rseq=1}"'
(cd "$D" && SHIM_KERNEL=7.0.0-15-generic bash "$I" generate </dev/null >/dev/null 2>&1)
check "generate on kernel 7.0.0: GLIBC_TUNABLES for mongo in compose and .env" 'grep -qxF "$GLIBC_LINE" "$D/docker-compose.yml" && grep -qx "MONGO_GLIBC_TUNABLES=glibc.pthread.rseq=1" "$D/.env" && [ "$(sed -n "/^  mongo:/,/^  minio:/p" "$D/docker-compose.yml" | grep -c GLIBC_TUNABLES)" -eq 1 ]'
out="$(cd "$D" && SHIM_KERNEL=7.0.0-15-generic bash "$I" check </dev/null 2>&1)"
check "check on kernel 7.0.0 with the workaround: no MongoDB problem" '! grep -q "refuses to start" <<< "$out" && grep -q "starts with GLIBC_TUNABLES=glibc.pthread.rseq=1" <<< "$out"'
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0"/' "$I"
(cd "$D" && SHIM_KERNEL=7.0.0-15-generic bash "$I" generate </dev/null >/dev/null 2>&1); rc=$?
check "MongoDB 7.0 on kernel 7.0.0: the workaround goes away (not needed)" '[ "$rc" -eq 0 ] && grep -qx "MONGO_TAG=7.0" "$D/.env" && ! grep -q MONGO_GLIBC_TUNABLES "$D/.env" && ! grep -q GLIBC_TUNABLES "$D/docker-compose.yml"'
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8"/' "$I"
(cd "$D" && SHIM_KERNEL=7.0.0-15-generic bash "$I" generate </dev/null >/dev/null 2>&1)
out="$(cd "$D" && printf '0
' | SHIM_KERNEL=7.0.14-200.fc44.x86_64 bash "$I" menu 2>&1)"
check "kernel 7.0.14 with files from 7.0.0: the menu names the kernel, not hand edits" 'grep -q "This kernel no longer needs the MongoDB workaround" <<< "$out" && ! grep -q "changed settings or manual edits" <<< "$out"'
(cd "$D" && bash "$I" generate </dev/null >/dev/null 2>&1)
check "generate on kernel 6.8: no workaround (files as before)" '! grep -q GLIBC_TUNABLES "$D/docker-compose.yml" && ! grep -q MONGO_GLIBC_TUNABLES "$D/.env"'
out="$(cd "$D" && SHIM_KERNEL=7.0.0-15-generic bash "$I" check </dev/null 2>&1)"
check "files from another kernel: check says regenerate (a warning, not a failed check)" 'grep -q "the files lack the workaround" <<< "$out" && grep -q "Regenerate them (option 2" <<< "$out" && ! grep -q "ERROR MongoDB" <<< "$out"'
installed
out="$(printf 'i\n1\n\ny\ny\n\ny\ny\nn\n\n0\n' | SHIM_KERNEL=7.0.0-15-generic bash "$I" menu 2>&1)"
check "repair on kernel 7.0.0 with old files: not stopped by the check, the files get the workaround" '! grep -q "Some checks failed" <<< "$out" && grep -qxF "$GLIBC_LINE" "$D/docker-compose.yml" || { grep -E "WARN|ERROR|Stopped|Step" <<< "$out" | head -20; false; }'

# 9. Another folder's installation with the same project name is not taken for this one
fresh
touch "$ST/up" "$ST/net" "$ST/vols"
OTHER="$T/other/inst"; mkdir -p "$OTHER"
out="$(printf 'i\n0\n\n0\n' | SHIM_FOREIGN_DIR="$OTHER" bash "$I" menu 2>&1)"
check "install: installation of another folder found, take over offered" 'grep -q "A Catalog installation already exists on this server: $OTHER" <<< "$out" && grep -q "Take it over" <<< "$out" && ! grep -q "This folder already has an installation" <<< "$out"'
(cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1); : > "$LOG"
out="$(printf 'r\ny\n\nDELETE\n\n0\n' | SHIM_FOREIGN_DIR="$OTHER" bash "$I" menu 2>&1)"
check "remove: other installation's containers and volumes untouched" 'grep -q "Another Catalog installation uses the project name" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG" && [ -f "$ST/up" ] && [ -f "$ST/vols" ]'

# 10. Update: installer first (not reachable here), then the Catalog
installed
out="$(printf 'u\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "update: installer step, then the Catalog" 'grep -q "Update . step 1 of 3" <<< "$out" && grep -q "The installer was not updated" <<< "$out" && grep -q "Newest Catalog:    26.3.4789.148" <<< "$out"'
check "update: Docker Compose checked against its newest release" 'grep -q "Docker Compose 5.6.0 (the newest) runs .podman compose." <<< "$out" && grep -q "^curl https://github.com/docker/compose/releases/latest$" "$LOG"'
check "update: declined upgrade is not reported as done" 'grep -q "Not upgraded: Catalog 25.4.4191.133 is installed, 26.3.4789.148 is available" <<< "$out" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$I" && ! grep -q "compose.* down" "$LOG"'

# 11. Update with a new installer: replaced, menu restarted, the update goes on with the Catalog
installed
sed 's/^HEALTH_TIMEOUT="600"$/HEALTH_TIMEOUT="600"\nNEW_SETTING="x"/' "$NEW" > "$ST/new-installer.sh"
out="$(printf 'u\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "update: new installer installed, settings kept" 'grep -q "^NEW_SETTING=\"x\"$" "$I" && grep -q "^CHECK_FOR_UPDATES=\"false\"$" "$I" && grep -q "Installer updated" <<< "$out"'
check "update: goes on with step 2 after the restart, notice shown" 'grep -q "Update . step 2 of 3" <<< "$out" && grep -q "Installer updated - your settings were kept" <<< "$out" && grep -q "Newest Catalog:" <<< "$out"'
rm -f "$ST/new-installer.sh"
out="$(printf '22\n0\n' | bash "$I" menu 2>&1)"
check "update: the resume does not leak into later runs" '! grep -q "Update . step" <<< "$out"'

# 12. Update on an empty folder
fresh
out="$(printf 'u\n\n0\n' | bash "$I" menu 2>&1)"
check "update: nothing installed - points to I" 'grep -q "Nothing is installed in this folder yet" <<< "$out"'

# 13. Remove: wrong word changes nothing
installed
mkdir -p "$D/snapshots"; echo x > "$D/snapshots/a.tar.gz"
out="$(printf 'r\nn\ny\n\nnope\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: overview lists containers, the volumes by name and images" 'grep -q "Containers  *3" <<< "$out" && grep -q "Data volumes  *2" <<< "$out" && grep -q "inst_db_data inst_minio_storage" <<< "$out" && grep -q "Images of the stack  *3" <<< "$out"'
check "remove: without DELETE nothing is removed" 'grep -q "Cancelled - nothing was removed" <<< "$out" && [ -f "$D/.env" ] && ! grep -Eq "$MUTATING" "$LOG"'

# 14. Remove with the defaults: containers, volumes, images, files; snapshots and installer kept
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: compose down, then the data volumes one by one" 'grep -q "^podman compose .*--env-file .env -f docker-compose.yml down --remove-orphans$" "$LOG" && grep -q "^podman volume rm inst_db_data$" "$LOG" && grep -q "^podman volume rm inst_minio_storage$" "$LOG" && [ ! -f "$ST/vols" ]'
check "remove: images of the stack removed once each, by their qualified names" '[ "$(grep -c "^podman image rm docker.io/library/mongo:8$" "$LOG")" -eq 1 ] && [ "$(grep -c "^podman image rm docker.io/raynetgmbh/rayventory-catalog:25.4.4191.133$" "$LOG")" -eq 1 ] && [ "$(grep -c "^podman image rm " "$LOG")" -eq 3 ] && [ ! -s "$ST/images" ]'
check "remove: generated files gone, snapshots and installer kept" '[ ! -f "$D/.env" ] && [ ! -f "$D/docker-compose.yml" ] && [ ! -e "$D/.jobs" ] && [ -f "$D/snapshots/a.tar.gz" ] && [ -f "$I" ]'
check "remove: done, I installs again" 'grep -q "The Catalog was removed from this server" <<< "$out" && grep -q "I installs it again" <<< "$out"'

# 15. Data volumes that cannot be removed: the files with the passwords stay
installed
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | SHIM_VOL_BUSY=1 bash "$I" menu 2>&1)"
check "remove: volume left - .env kept, not reported as removed" 'grep -q "Still there:.*volume inst_db_data" <<< "$out" && grep -q "the files with the passwords were kept" <<< "$out" && [ -f "$D/.env" ] && ! grep -q "The Catalog was removed" <<< "$out"'

# 15b. Folder moved after the installation (its containers name the old folder): still this stack
# KNOWN INSTALLER BUG (fails until fixed): stack_foreign_catalog's second loop takes the old folder from
# find_installations (catalog-web labels: project inst, working_dir /srv/gone/inst) for another
# installation, although stack_containers counts its containers as this one's - R removes nothing.
installed
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | SHIM_FOREIGN_DIR=/srv/gone/inst bash "$I" menu 2>&1)"
check "remove: moved folder - its stack is found and removed" 'grep -q "Containers  *3" <<< "$out" && grep -q "compose.* down --remove-orphans" "$LOG" && [ ! -f "$D/.env" ] && [ ! -f "$ST/vols" ]'

# 15d. A folder this user cannot look into is not "gone": its installation is left alone
installed
mkdir -p "$T/locked/inst"; chmod 000 "$T/locked"
if ! ls "$T/locked" >/dev/null 2>&1; then
  out="$(printf 'r\ny\n\nDELETE\n\n0\n' | SHIM_FOREIGN_DIR="$T/locked/inst" bash "$I" menu 2>&1)"
  check "remove: unreadable folder's installation untouched" 'grep -q "Another Catalog installation uses the project name" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG" && [ -f "$ST/vols" ]'
fi
chmod 755 "$T/locked"

# 15e. backups/ and snapshots/: only the installer's own files go
installed
mkdir -p "$D/backups/laptop" "$D/snapshots"
echo x > "$D/backups/laptop/home.tar"; echo x > "$D/backups/mongo-20261001-1200.archive.gz"
echo x > "$D/snapshots/2026-10-05-daily.tar.gz"; echo x > "$D/snapshots/notes.txt"
out="$(printf 'r\nn\ny\na\n\nDELETE\n' | bash "$I" menu 2>&1)"
check "remove: user files in backups/ and snapshots/ kept" '[ -f "$D/backups/laptop/home.tar" ] && [ ! -e "$D/backups/mongo-20261001-1200.archive.gz" ] && [ -f "$D/snapshots/notes.txt" ] && [ ! -e "$D/snapshots/2026-10-05-daily.tar.gz" ]'

# 15c. Broken compose file: the volumes of the project are still found
installed
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | SHIM_CONFIG_FAIL=1 bash "$I" menu 2>&1)"
check "remove: compose config fails - volumes still offered and removed" 'grep -q "Data volumes  *2" <<< "$out" && grep -q "^podman volume rm inst_db_data$" "$LOG" && [ ! -f "$D/.env" ]'
check "remove: compose down fails - containers and network removed directly" 'grep -q "^podman rm -f c1 c2 c3 *$" "$LOG" && [ ! -f "$ST/up" ] && grep -q "^podman network rm inst_default$" "$LOG" && [ ! -f "$ST/net" ]'

# 16. Podman not reachable: nothing removed
installed
out="$(printf 'r\n\n0\n' | SHIM_PODMAN_DOWN=1 bash "$I" menu 2>&1)"
check "remove: Podman not reachable - stops, files kept" 'grep -q "Podman does not answer" <<< "$out" && grep -q "nothing was removed" <<< "$out" && [ -f "$D/.env" ] && ! grep -Eq "$MUTATING" "$LOG"'
: > "$LOG"
out="$(printf 'r\n\n0\n' | SHIM_ROOTLESS=true bash "$I" menu 2>&1)"
check "remove: rootless Podman (not the stack's) - stops, files kept" 'grep -q "Podman does not answer as root" <<< "$out" && grep -q "nothing was removed" <<< "$out" && [ -f "$D/.env" ] && [ -f "$ST/up" ] && ! grep -Eq "$MUTATING" "$LOG"'

# 16b. podman.socket not active (podman compose cannot work): the removal stops before it changes anything
installed
out="$(printf 'r\ny\n\nDELETE\n\n0\n' | SHIM_SOCKET_DOWN=1 bash "$I" menu 2>&1)"
check "remove: podman.socket not active - nothing removed, files kept" 'grep -q "The Podman API socket is not active" <<< "$out" && grep -q "the files with the passwords were kept" <<< "$out" && [ -f "$D/.env" ] && [ -f "$ST/up" ] && [ -f "$ST/vols" ] && [ -s "$ST/images" ] && ! grep -Eq "$MUTATING" "$LOG"'

# 17. After "Stop the stack" (no containers) the images are still found and removed
installed
rm -f "$ST/up" "$ST/net"
out="$(printf 'r\ny\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: images found without containers" 'grep -q "Images of the stack  *3" <<< "$out" && grep -q "^podman image rm docker.io/library/mongo:8$" "$LOG"'
check "remove: volumes with no proof they are this folder's - not selected, .env kept" 'grep -q "not selected: they may be another installation" <<< "$out" && [ -f "$ST/vols" ] && [ -f "$D/.env" ]'

# 18. Remove everything including the installer; a toggle with a leading zero works
# (the download line uses curl where wget is missing, as on RHEL minimal)
if command -v wget >/dev/null 2>&1; then DL="wget -nv -O rn1-technology-catalog-installer.sh"; else DL="curl -fsSL -o rn1-technology-catalog-installer.sh"; fi
installed
out="$(printf 'r\nn\ny\na\n\nDELETE\n' | bash "$I" menu 2>&1)"; rc=$?
check "remove all: installer gone, exits with the download line" '[ "$rc" -eq 0 ] && [ ! -e "$I" ] && grep -q "The installer was removed too" <<< "$out" && grep -q "$DL" <<< "$out"'
installed
out="$(printf 'r\nn\ny\n04\n0\n\n0\n' | bash "$I" menu 2>&1)"; rc=$?
check "remove: toggle 04 understood (no octal error)" '[ "$rc" -eq 0 ] && grep -q "Cancelled - nothing was removed" <<< "$out" && ! grep -q "value too great" <<< "$out"'

# 19. Remove on an empty folder; leftover bundles are still offered
fresh
out="$(printf 'r\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: nothing to remove" 'grep -q "There is nothing to remove in this folder" <<< "$out"'
mkdir -p "$D/RN1-Technology-Catalog-26.3-20261001"
out="$(printf 'r\ny\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: leftover offline bundle offered" '! grep -q "There is nothing to remove" <<< "$out" && grep -q "Offline bundles (" <<< "$out" && ! grep -q "(passwords)" <<< "$out"'

# 20. Containers of this folder but no .env: "incomplete", not "installed", and repair names the passwords
installed
rm -f "$D/.env"
out="$(printf '0\n' | bash "$I" menu 2>&1)"
check "menu: containers without .env shown as incomplete" 'grep -Eq "I\) INSTALL +! Incomplete: 3 containers, but no .env" <<< "$out" && grep -q "Stack  : 3 containers exist" <<< "$out" && ! grep -q "Installed" <<< "$out"'
out="$(printf 'i\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install: repair warns that .env and its passwords are missing" 'grep -q ".env is missing and has no backup" <<< "$out" && grep -q "new passwords would not open the existing data" <<< "$out"'
installed; cp "$D/.env" "$D/.env.bak-20261001-120000"; rm -f "$D/.env"
out="$(printf 'i\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install: repair takes the passwords from the newest .env backup" 'grep -q "a repair takes the passwords from its newest backup .*\.env\.bak-20261001-120000" <<< "$out"'

# 21. Full screen: the lines above the prompt say what the typed number does
if command -v script >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  fresh
  tui_type() { # KEYS [COLUMNS] [TEXT TO WAIT FOR BEFORE QUITTING]
    local log="$T/tui.log" i k
    : > "$log"
    { for i in $(seq 1 120); do grep -q "Select:" "$log" 2>/dev/null && break; sleep 0.5; done
      for ((k = 0; k < ${#1}; k++)); do printf '%s' "${1:k:1}"; sleep 0.3; done
      if [ -n "${3:-}" ]; then
        for i in $(seq 1 60); do grep -aq -- "$3" "$log" 2>/dev/null && break; sleep 0.5; done
      else
        sleep 2
      fi
      printf q; sleep 2
    } | TERM=xterm LANG=C.UTF-8 timeout 90 script -qfec "stty cols ${2:-120} rows 40; bash $I menu" /dev/null > "$log" 2>&1
    sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g' "$log" | tr -d '\r'
  }
  out="$(tui_type "")"
  check "full screen: asks for a number and says it will explain it" 'grep -q "Type a number - what it does shows here" <<< "$out"'
  out="$(tui_type 13 120 "data volumes stay")"
  check "full screen: typing 13 says what it does" 'grep -q "13 .* Stop (data is kept)" <<< "$out" && grep -q "podman compose down - data volumes stay" <<< "$out"'
  out="$(tui_type 99 120 "AND data volumes")"
  check "full screen: typing 99 warns" 'grep -q "Reset: delete all data - asks for DELETE" <<< "$out" && grep -q "Removes ALL containers AND data volumes" <<< "$out"'
  out="$(tui_type 24 120 "No option 24")"
  check "full screen: an unknown number is named" 'grep -q "No option 24" <<< "$out"'
  installed; rm -f "$D/.env"
  out="$(tui_type "" 132)"
  check "full screen, 132 columns: the cards fit (no cut texts) and name what is missing" 'grep -q "Incomplete: no .env" <<< "$out" && grep -q "put the old .env back first" <<< "$out" && grep -q "you choose: data, images, files" <<< "$out" && ! grep -q "~ " <<< "$(grep -E "Incomplete|choose|old .env" <<< "$out")"'
else
  echo "SKIP: script (util-linux) missing - no full screen test of the typing hints"
fi

check "fakes: no unknown podman, provider or systemctl call and no docker call in the whole suite" '[ ! -s "$BAD" ] || { sort "$BAD" | uniq -c | head -20; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
