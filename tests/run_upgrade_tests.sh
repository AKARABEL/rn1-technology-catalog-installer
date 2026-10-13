#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/u"
rm -rf "$T"; mkdir -p "$T/bin" "$T/state"
# these tests run Podman: CONTAINER_ENGINE names it (on a CI runner, detection would see its real Docker)
sed 's/^CONTAINER_ENGINE=""$/CONTAINER_ENGINE="podman"/' "$1" > "${T%/*}/podman-installer.sh"; NEW="${T%/*}/podman-installer.sh"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# the internet check (menu start, new installation, option 16, engine setup) has its own suite (run_network_tests)
export RN1_NET_CHECK=off
export LOG="$T/calls.log" ST="$T/state"
: > "$LOG"

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; hdr=""; fmt=""; head="no"; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -I) head="yes"; shift ;;
    -H|--connect-timeout|--max-time|--retry|--retry-delay|--proto|-K) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
emit() { if [ -n "$out" ] && [ "$out" != "-" ]; then printf '%s' "$1" > "$out"; else printf '%s' "$1"; fi; }
# the self-update downloads $SHIM_INSTALLER
case "$url" in
  https://raw.githubusercontent.com/*) { [ -n "${SHIM_INSTALLER:-}" ] && [ -n "$out" ]; } || exit 22; cat "$SHIM_INSTALLER" > "$out"; exit 0 ;;
esac
code=200; body=""
case "$url" in
  http://localhost:*/) [ "${SHIM_WEB_DOWN:-}" = 1 ] && code=502 ;;
  # the license check after a restart; SHIM_LICENSE_VALID=false: the new start does not accept the license;
  # SHIM_LICENSE_HOST: the license is bound to this host name of catalog-web (valid only while it has it)
  http://localhost:*/v1/license/isValid)
    echo "isValid" >> "$ST/asked"
    body="${SHIM_LICENSE_VALID:-true}"
    if [ -n "${SHIM_LICENSE_HOST:-}" ]; then
      h="$(cat "$ST/hostname" 2>/dev/null)"
      [ "${h:-4f9c2d71e8a3}" = "$SHIM_LICENSE_HOST" ] || body=false
    fi ;;
  https://hub.docker.com/v2/repositories/raynetgmbh/rayventory-catalog*/tags*)
    d="sha256:aaaa"
    body='{"count":3,"next":null,"results":[{"name":"stable","digest":"'$d'"},{"name":"26.3.4789.148","digest":"'$d'"},{"name":"26.1.4475.137","digest":"sha256:bbbb"},{"name":"25.4.4191.133","digest":"sha256:cccc"}]}' ;;
  https://*/v2/) [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$( [ "$hdr" = - ] && echo /dev/stdout || echo "$hdr")" ;;
  https://*/tags/list*)
    case "$url" in
      */library/mongo/*) tags='"7.0.41","7.0.43","8.0.4","8.0.30","8.0.32","8","9.0.2"' ;;
      */opensearchproject/opensearch/*|*/opensearchproject/opensearch-dashboards/*) tags='"2.19.5","2.19.6","3.9.0"' ;;
      */library/rabbitmq/*) tags='"3.13.6-management-alpine","3.13.7-management-alpine","4.3.6-management-alpine"' ;;
      */golithus/minio/*) tags='"RELEASE.2025-10-15T17-29-55Z"' ;;
      */jc21/nginx-proxy-manager/*) tags='"2.15.0","2.16.0"' ;;
      *) tags='' ;;
    esac
    [ -n "$hdr" ] && : > "$hdr"
    body='{"name":"x","tags":['"$tags"']}' ;;
  https://*/manifests/*) if [ "$head" = yes ]; then printf 'docker-content-digest: sha256:%s\r\n' "$(printf '%s' "${url##*/}" | sha256sum | cut -c1-12)"; exit 0; fi; body='{}' ;;
  *) code=404 ;;
esac
emit "$body"
if [ -n "$fmt" ]; then f="${fmt//%\{http_code\}/$code}"; printf '%s' "$f"; fi
[ "$code" -ge 400 ] && exit 22
exit 0
EOF

# Fake rootful Podman 5.7.0 (SHIM_PODMAN_VERSION) with "podman compose" built in. Containers are
# "id-SERVICE" while $ST/up exists (they exist stopped while $ST/exited does), $ST/wd is the folder
# the stack was created in. catalog-web has the CATALOG_HOSTNAME of .env at its last start ($ST/hostname;
# without one a new container ID), before the first start the container ID 4f9c2d71e8a3. Calls it does
# not know are logged to $UNH and fail with 125.
export UNH="$T/unhandled.log" RN1_COMPOSE_PROVIDER="$T/cli-plugins/docker-compose"
: > "$UNH"
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$LOG"
SVCS="nginx-proxy-manager opensearch opensearch-dashboards mongo minio rabbitmq catalog-web worker-recognition-1 worker-recognition-2 worker-other worker-search"
running() { [ -f "$ST/up" ]; }
exists() { running || [ -f "$ST/exited" ]; }
bad() { printf 'UNHANDLED podman %s\n' "$*" >> "$UNH"; echo "fake podman: not handled: $*" >&2; exit 125; }
nosuch() { echo "Error: no container with name or ID \"$1\" found: no such container" >&2; exit 125; }
inspect_one() {
  local id="$2" svc="${2#id-}"
  { exists && [ "$svc" != "$id" ] && [[ " $SVCS " == *" $svc "* ]]; } || nosuch "$id"
  case "$1" in
    '{{.Config.Hostname}}')
      [ "$svc" = catalog-web ] || bad container inspect --format "$1" "$id"
      h="$(cat "$ST/hostname" 2>/dev/null)"; echo "${h:-4f9c2d71e8a3}" ;;
    '{{.State.OOMKilled}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.RestartCount}}') echo "false|$svc|0" ;;
    '{{.Config.Image}}')
      # the images the stack was started with ($ST/upenv: the env file of the last "up")
      upenv() { sed -n "s/^$1=//p" "$ST/upenv"; }
      case "$svc" in
        catalog-web) echo "docker.io/raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag")" ;;
        worker-*) echo "docker.io/raynetgmbh/rayventory-catalog-worker:$(cat "$ST/catalog_tag")" ;;
        mongo) echo "docker.io/library/mongo:$(upenv MONGO_TAG)" ;;
        opensearch) echo "docker.io/opensearchproject/opensearch:$(upenv OPENSEARCH_TAG)" ;;
        opensearch-dashboards) echo "docker.io/opensearchproject/opensearch-dashboards:$(upenv OPENSEARCH_DASHBOARDS_TAG)" ;;
        rabbitmq) echo "docker.io/library/rabbitmq:$(upenv RABBITMQ_TAG)" ;;
        minio) echo "ghcr.io/golithus/minio:$(upenv MINIO_TAG)" ;;
        nginx-proxy-manager) echo "docker.io/jc21/nginx-proxy-manager:$(upenv NGINX_PROXY_MANAGER_TAG)" ;;
      esac ;;
    '{{.State.Status}}|{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}|{{.RestartCount}}')
      if ! running; then echo "exited|none|0"
      elif [ "$svc" = catalog-web ] && [ "${SHIM_UNHEALTHY:-}" = 1 ]; then echo "restarting|none|3"
      elif [ "$svc" = rabbitmq ]; then echo "running|healthy|0"
      else echo "running|none|0"; fi ;;
    '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{index .Config.Labels "com.docker.compose.project.environment_file"}}|{{.Config.Image}}|{{.State.Status}}')
      [ "$svc" = catalog-web ] || bad container inspect --format "$1" "$id"
      w="$(cat "$ST/wd")"
      echo "inst|$w|$w/docker-compose.yml|$w/.env|docker.io/raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag")|$(if running; then echo running; else echo exited; fi)" ;;
    *) bad container inspect --format "$1" "$id" ;;
  esac
}
case "${1:-}" in
  --version) [ $# -eq 1 ] || bad "$@"; echo "podman version ${SHIM_PODMAN_VERSION:-5.7.0}" ;;
  info)
    if [ $# -eq 1 ]; then exit 0; fi
    case "$*" in
      "info --format {{.Host.Security.Rootless}}") echo false ;;
      "info --format {{.Host.MemTotal}}") echo "${SHIM_MEMTOTAL:-34359738368}" ;;
      *) bad "$@" ;;
    esac ;;
  volume)
    # the data volumes exist once the stack was created ($ST/wd); "down" keeps them
    [ "$*" = "volume ls -q --filter label=com.docker.compose.project=inst" ] || bad "$@"
    if [ -f "$ST/wd" ]; then
      for v in db_data db_config worker1_token worker2_token worker_token worker_search_token rmq_data rmq_log minio_storage catalog_license opensearch_data npm_data npm_letsencrypt; do echo "inst_$v"; done
    fi ;;
  ps)
    case "$*" in
      "ps -aq --filter label=com.docker.compose.service=catalog-web") exists && echo id-catalog-web ;;
      "ps -aq --filter label=com.docker.compose.project=inst --filter label=com.docker.compose.service=catalog-web") exists && echo id-catalog-web ;;
      "ps -aq --filter label=com.docker.compose.project=inst") if exists; then for s in $SVCS; do echo "id-$s"; done; fi ;;
      *) bad "$@" ;;
    esac ;;
  container)
    { [ "${2:-}" = inspect ] && [ "${3:-}" = --format ] && [ $# -ge 5 ]; } || bad "$@"
    f="$4"; shift 4
    for id in "$@"; do inspect_one "$f" "$id"; done ;;
  exec)
    { [ "${2:-}" = id-mongo ] && running; } || nosuch "${2:-}"
    case "${3:-}" in
      mongod) [ "$*" = "exec id-mongo mongod --version" ] || bad "$@"; echo "db version v$(cat "$ST/mongo_version")" ;;
      sh) { [ $# -eq 5 ] && [ "$4" = -c ] && [[ "$5" == *"mongodump --quiet --archive --gzip"* ]]; } || bad "$@"
        [ "${SHIM_BACKUP_FAIL:-}" = 1 ] && exit 1; printf 'MONGODUMP-ARCHIVE' ;;
      *) bad "$@" ;;
    esac ;;
  compose)
    shift
    [ "${PODMAN_COMPOSE_PROVIDER:-}" = "$RN1_COMPOSE_PROVIDER" ] || bad compose "$@" "(PODMAN_COMPOSE_PROVIDER=${PODMAN_COMPOSE_PROVIDER:-unset})"
    envf=""; cf=""
    while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; --env-file) envf="$2"; shift 2 ;; -f) cf="$2"; shift 2 ;; *) break ;; esac; done
    { [ "$envf" = .env ] && [ "$cf" = docker-compose.yml ] && [ -f "$envf" ] && [ -f "$cf" ]; } || bad compose "$@" "(env file '$envf', compose file '$cf' in $PWD)"
    sub="${1:-}"; shift
    case "$sub" in
      config)
        case "$*" in
          --services) printf '%s\n' $SVCS ;;
          --quiet) ;;
          *) bad compose config "$@" ;;
        esac ;;
      ps)
        if [ "${1:-}" = -q ] && [ $# -eq 2 ]; then running && echo "id-$2"
        elif [ "${1:-}" = -a ] && [ "${2:-}" = -q ] && [ $# -eq 3 ]; then exists && echo "id-$3"
        elif [ $# -eq 0 ]; then echo "NAME STATUS"
        elif [ "$*" = "--services --filter status=running" ]; then if running; then printf '%s\n' $SVCS; fi
        else bad compose ps "$@"; fi ;;
      pull) [ -n "${SHIM_SLOW_PULL:-}" ] && sleep 8; echo "pull $*" >> "$ST/pulls" ;;
      down)
        case "$*" in
          --remove-orphans) rm -f "$ST/up" "$ST/exited" ;;
          # the data volumes go too
          "-v --remove-orphans") rm -f "$ST/up" "$ST/exited" "$ST/wd" ;;
          *) bad compose down "$@" ;;
        esac ;;
      up)
        [ "$*" = "-d --remove-orphans" ] || bad compose up "$@"
        touch "$ST/up"; rm -f "$ST/exited"; pwd -P > "$ST/wd"; cp "$envf" "$ST/upenv"
        h="$(sed -n 's/^CATALOG_HOSTNAME=//p' "$envf")"; echo "${h:-9e1b07c3d5a2}" > "$ST/hostname"
        sed -n 's/^CATALOG_IMAGE=.*://p' "$envf" > "$ST/catalog_tag"
        m="$(sed -n 's/^MONGO_TAG=//p' "$envf")"; [[ "$m" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$m" > "$ST/mongo_version" ;;
      logs) echo "catalog-web | fake log line" ;;
      *) bad compose "$sub" "$@" ;;
    esac ;;
  *) bad "$@" ;;
esac
exit 0
EOF
# The Docker Compose binary behind "podman compose" (the fake podman runs compose itself)
mkdir -p "$T/cli-plugins"
cat > "$RN1_COMPOSE_PROVIDER" <<'EOF'
#!/usr/bin/env bash
echo "provider $*" >> "$LOG"
case "$*" in
  version) echo "Docker Compose version v5.6.0" ;;
  "version --short") echo "5.6.0" ;;
  *) printf 'UNHANDLED provider %s\n' "$*" >> "$UNH"; exit 125 ;;
esac
EOF
# podman.socket active, podman-restart.service enabled; anything else is not expected here
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-active --quiet podman.socket"|"is-active podman.socket") exit 0 ;;
  "is-enabled podman-restart.service") echo enabled ;;
  *) printf 'UNHANDLED systemctl %s\n' "$*" >> "$UNH"; exit 1 ;;
esac
EOF
chmod +x "$T/bin/"* "$RN1_COMPOSE_PROVIDER"
cat > "$T/bin/timedatectl" <<'TZEOF'
#!/usr/bin/env bash
printf '%s\n' "${SHIM_TZ:-Europe/Berlin}"
TZEOF
chmod +x "$T/bin/timedatectl"
# the kernel of the test machine must not change the generated files (MongoDB workaround on 6.19 to 7.0.x)
REAL_UNAME="$(command -v uname)"
printf '#!/usr/bin/env bash
if [ "${1:-}" = "-r" ]; then echo "${SHIM_KERNEL:-6.8.0-generic}"; else exec "%s" "$@"; fi
' "$REAL_UNAME" > "$T/bin/uname"
chmod +x "$T/bin/uname"
export PATH="$T/bin:$PATH"

# setup -> an installation of Catalog 25.4 that runs (named here: the default is the newest Catalog of the release)
setup() {
  rm -rf "$T/inst" "$ST"/*; mkdir -p "$T/inst"; cp "$NEW" "$T/inst/rn1-technology-catalog-installer.sh"
  sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/; 0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG="2.19.5"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG="2.19.5"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG="3.13.6-management-alpine"/; 0,/^NGINX_PROXY_MANAGER_TAG=/s/^NGINX_PROXY_MANAGER_TAG=.*/NGINX_PROXY_MANAGER_TAG="2.16.0"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="10"/' "$T/inst/rn1-technology-catalog-installer.sh"
  (cd "$T/inst" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  touch "$ST/up"; echo "25.4.4191.133" > "$ST/catalog_tag"; echo "8.0.4" > "$ST/mongo_version"; (cd "$T/inst" && pwd -P) > "$ST/wd"; cp "$T/inst/.env" "$ST/upenv"
  : > "$LOG"
}
D="$T/inst"

# 1. Full guided upgrade with backup, then patch updates without OpenSearch
setup
p1="$(grep '^MONGO_INITDB_ROOT_PASSWORD=' "$D/.env")"
out="$(printf '21\ny\ny\n1\n\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "detects installed 25.4 and newest 26.3 (stable)" 'grep -q "Installed Catalog: 25.4.4191.133" <<< "$out" && grep -q "Newest Catalog:    26.3.4789.148 (stable)" <<< "$out"'
check "backup written with the archive" 'f="$(ls "$D"/backups/mongo-*.archive.gz 2>/dev/null | head -n1)"; [ -n "$f" ] && [ "$(cat "$f")" = MONGODUMP-ARCHIVE ]'
check "backup runs mongodump with podman exec in the mongo container" 'grep -q "^podman exec id-mongo sh -c" "$LOG" && grep -q "mongodump --quiet --archive --gzip" "$LOG" && ! grep -q "^podman exec -[a-z]* id-mongo sh" "$LOG"'
check "images pulled before down" '[ "$(grep -n "compose.* pull catalog-web" "$LOG" | head -n1 | cut -d: -f1)" -lt "$(grep -n "compose.* down" "$LOG" | head -n1 | cut -d: -f1)" ]'
check "down, then up" 'grep -q "^podman compose --env-file .env -f docker-compose.yml down --remove-orphans$" "$LOG" && grep -q "^podman compose --env-file .env -f docker-compose.yml up -d --remove-orphans$" "$LOG" && [ "$(grep -n "compose.* down" "$LOG" | head -n1 | cut -d: -f1)" -lt "$(grep -n "compose.* up -d" "$LOG" | head -n1 | cut -d: -f1)" ]'
check "CATALOG_VERSION and .env switched to 26.3" 'grep -q "^CATALOG_VERSION=\"26.3.4789.148\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148$" "$D/.env" && grep -q "^CATALOG_WORKER_IMAGE=raynetgmbh/rayventory-catalog-worker:26.3.4789.148$" "$D/.env"'
check "passwords kept" '[ "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env")" = "$p1" ]'
check "health check passed and upgrade reported" 'grep -q "All 11 services run and Catalog Web answers" <<< "$out" && grep -q "Catalog upgraded: 25.4.4191.133 -> 26.3.4789.148." <<< "$out"'
check "patch updates offered (MongoDB, OpenSearch, RabbitMQ)" 'grep -q "MongoDB .*8.0.4 -> 8.0.32" <<< "$out" && grep -q "OpenSearch + Dashboards .*2.19.5 -> 2.19.6" <<< "$out" && grep -q "RabbitMQ .*3.13.6 -> 3.13.7" <<< "$out"'
check "no major or cross-series offer (no 9.0.2 / 3.9.0 / 4.3.6)" '! grep -E -- "-> (9\.0\.2|3\.9\.0|4\.3\.6)" <<< "$out"'
check "selected patches applied, OpenSearch left out" 'grep -q "^MONGO_TAG=\"8.0.32\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^RABBITMQ_TAG=\"3.13.7-management-alpine\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^OPENSEARCH_TAG=\"2.19.5\"$" "$D/rn1-technology-catalog-installer.sh"'
check "MongoDB runs the new patch after up" '[ "$(cat "$ST/mongo_version")" = 8.0.32 ]'
check "the license is still valid after the restarts: nothing said about it" '! grep -q "no valid license after the restart" <<< "$out" && ! grep -q "catalog-web gets the fixed host name" <<< "$out"'

# 2. Already up to date -> only patch check (on Podman 4.9, the oldest one the installer accepts)
out="$(printf '21\n0\n\n0\n' | SHIM_PODMAN_VERSION=4.9.3 bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "up to date: no down, patch list only" 'grep -q "The Catalog is up to date." <<< "$out" && ! grep -q "Upgrade plan" <<< "$out"'

# 3. Unhealthy after up -> rollback to the old version, restore hint (on Podman 4.9)
setup
out="$(printf '21\ny\ny\ny\n\n0\n' | SHIM_UNHEALTHY=1 SHIM_PODMAN_VERSION=4.9.3 bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "unhealthy upgrade detected" 'grep -q "Not healthy after" <<< "$out" && grep -q "is not healthy" <<< "$out" && grep -q "catalog-web(restarting/none)" <<< "$out"'
check "rolled back to 25.4" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133$" "$D/.env"'
check "restore hint printed with the backup file" 'grep -q "mongorestore --drop --archive --gzip" <<< "$out" && grep -q "backups/mongo-" <<< "$out" && grep -qF "podman exec -i \"\$(podman compose ps -q mongo)\" sh -c '"'"'mongorestore" <<< "$out"'
check "logs shown on failure" 'grep -q "fake log line" <<< "$out"'

# 4. Upgrade declined -> nothing changed
setup
out="$(printf '21\nn\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "declined: no change, no down" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/rn1-technology-catalog-installer.sh" && ! grep -q "compose.* down" "$LOG"'

# 5. Backup fails -> user stops -> nothing changed
setup
out="$(printf '21\ny\ny\nn\n\n0\n' | SHIM_BACKUP_FAIL=1 bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "failed backup stops the upgrade on request" 'grep -q "The MongoDB backup failed." <<< "$out" && ! grep -q "compose.* down" "$LOG" && ! ls "$D"/backups/*.gz >/dev/null 2>&1'

# 6. Password never on the host command line during backup
pw="$(sed -n 's/^MONGO_INITDB_ROOT_PASSWORD=//p' "$D/.env")"
check "backup password stays inside the container" 'grep -q "^podman exec id-mongo sh -c" "$LOG" && ! grep -q "MONGO_INITDB_ROOT_PASSWORD=[A-Za-z0-9]" "$LOG" && [ -n "$pw" ] && ! grep -qF -- "$pw" "$LOG"'

# 7. Cancel while the new images are pulled: settings back, the stack keeps running
setup
( printf '21\ny\nn\n\n0\n' | SHIM_SLOW_PULL=1 bash "$D/rn1-technology-catalog-installer.sh" menu > "$T/cancel1.out" 2>&1 ) &
mp=$!
for i in $(seq 1 150); do grep -q "Pulling the images" "$D/.jobs/1/progress" 2>/dev/null && break; sleep 0.2; done
sleep 0.5
out="$(cd "$D" && bash rn1-technology-catalog-installer.sh jobs cancel 1 2>&1)"
wait "$mp"
check "cancel while pulling: job cancelled" '[ "$(cat "$D/.jobs/1/state")" = cancelled ] && grep -q "Job #1 cancelled" <<< "$out"'
check "cancel while pulling: version and .env back, no down" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133$" "$D/.env" && ! grep -q "compose.* down" "$LOG" && [ -f "$ST/up" ]'

# 8. Cancel during the health check after the switch: back to the old version
setup
( printf '21\ny\nn\n\n0\n' | SHIM_UNHEALTHY=1 bash "$D/rn1-technology-catalog-installer.sh" menu > "$T/cancel2.out" 2>&1 ) &
mp=$!
for i in $(seq 1 150); do grep -q "Health check" "$D/.jobs/1/progress" 2>/dev/null && break; sleep 0.2; done
progress="$(cat "$D/.jobs/1/progress" 2>/dev/null)"
out="$(cd "$D" && bash rn1-technology-catalog-installer.sh jobs cancel 1 2>&1)"
wait "$mp"
check "cancel during the switch: job cancelled" '[ "$(cat "$D/.jobs/1/state")" = cancelled ]'
check "health progress: the waiting service first, the ready ones counted, half the bar for the services" '[[ "$progress" =~ ^([0-9]+)\|Health\ check\ [0-9]+s:\ waiting\ for:\ catalog-web\(restarting/none\).*\ ([0-9]+)/([0-9]+)\ services\ ready ]] && [ "${BASH_REMATCH[1]}" -eq $(( BASH_REMATCH[2] * 50 / BASH_REMATCH[3] )) ] || { echo "  | $progress"; false; }'
check "cancel during the switch: 25.4 runs again" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133$" "$D/.env" && [ "$(cat "$ST/catalog_tag")" = 25.4.4191.133 ] && grep -q "going back to Catalog 25.4.4191.133" "$D/.jobs/1/log"'
check "no rollback question after a cancel" '! grep -q "Go back to" "$T/cancel2.out" && [ ! -e "$D/.upgrade-failed" ]'

# 9. The files of an older installer (no fixed host name): a licensed catalog-web keeps the host name it has
# (its container ID), so its license survives the upgrade and the patch updates; said before the upgrade
# starts, without asking the Catalog. A license the new start does not accept (an older version, another host
# name) is named after the upgrade and the patch updates.
setup
sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
out="$(printf '21\nn\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "upgrade of older files: a licensed Catalog keeps its host name - said before the question, the Catalog not asked" 'sed -n "/Upgrade plan/,/Upgrade the Catalog to/p" <<< "$out" | grep -q "catalog-web gets a fixed host name now (CATALOG_HOSTNAME): a licensed$" && grep -q "^  Catalog keeps the one it has, so its license stays valid.$" <<< "$out" && ! grep -q "needs a license" <<< "$out" && ! grep -q "compose.* down" "$LOG" && [ ! -f "$ST/asked" ]'
setup
sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
out="$(printf '21\ny\nn\n\n\n0\n' | SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "upgrade of older files, licensed catalog-web named like a container ID: the name kept (.env, compose file), said once in the job log" 'grep -q "Catalog upgraded: 25.4.4191.133 -> 26.3.4789.148." <<< "$out" && grep -q "^CATALOG_HOSTNAME=4f9c2d71e8a3$" "$D/.env" && grep -q "^    hostname: \${CATALOG_HOSTNAME}$" "$D/docker-compose.yml" && [ "$(cat "$ST/hostname")" = 4f9c2d71e8a3 ] && [ "$(grep -c "catalog-web keeps its host name 4f9c2d71e8a3: the Catalog.s license$" "$D/.jobs/1/log")" -eq 1 ] && grep -q "^  is bound to it (CATALOG_HOSTNAME in .env).$" "$D/.jobs/1/log" && ! grep -q "keeps its host name" "$D/.jobs/2/log"'
check "the license survives the upgrade and the patch updates: the checks afterwards stay quiet" 'grep -q "^MONGO_TAG=\"8.0.32\"$" "$D/rn1-technology-catalog-installer.sh" && ! grep -q -e "no valid license after the restart" -e "needs a license" <<< "$out"'
setup
# (an installation of 26.3: its catalog-web first - generate does not raise a running 25.4 without asking)
echo 26.3.4789.148 > "$ST/catalog_tag"
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$D/rn1-technology-catalog-installer.sh"
(cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
out="$(printf '21\n\n\n0\n' | SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "patch updates of older files, licensed catalog-web: the name kept, the check afterwards quiet" 'grep -q "The Catalog is up to date." <<< "$out" && grep -q "^CATALOG_HOSTNAME=4f9c2d71e8a3$" "$D/.env" && grep -q "catalog-web keeps its host name 4f9c2d71e8a3" "$D/.jobs/1/log" && [ "$(cat "$ST/hostname")" = 4f9c2d71e8a3 ] && grep -q "^MONGO_TAG=\"8.0.32\"$" "$D/rn1-technology-catalog-installer.sh" && ! grep -q "no valid license after the restart" <<< "$out"'
setup
sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
out="$(printf '21\ny\nn\n\n\n0\n' | SHIM_LICENSE_VALID=false bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "license not accepted after the upgrade and the patch updates: named in both jobs" 'grep -q "Catalog upgraded: 25.4.4191.133 -> 26.3.4789.148." <<< "$out" && [ "$(grep -c "The Catalog has no valid license after the restart - option 25 shows why." <<< "$out")" -eq 2 ] && grep -q "A license for an older Catalog version or another host name of catalog-web" <<< "$out" && grep -q "no valid license after the restart" "$D/.jobs/1/log"'
check "older files without a valid license: the name of this server (nothing to lose)" 'h="$(sed -n "s/^CATALOG_HOSTNAME=//p" "$D/.env")"; [ -n "$h" ] && [ "$h" != 4f9c2d71e8a3 ] && [ "$h" = "$(cd "$D" && bash rn1-technology-catalog-installer.sh __server_hostname)" ] && grep -q "catalog-web now has the fixed host name $h (CATALOG_HOSTNAME)." "$D/.jobs/1/log" && ! grep -q "keeps its host name" "$D/.jobs/1/log"'

# 10. The installer upgraded this folder to 26.3 (MongoDB 8.0.32, port 8181), then a new download of an
#     installer whose default was older brought back the default settings (Catalog 25.4)
export SHIM_TZ="Etc/UTC"
N="rn1-technology-catalog-installer.sh"
installation26() {
  setup
  # catalog-web of 26.3 first: generate does not raise a running 25.4 without asking
  echo "26.3.4789.148" > "$ST/catalog_tag"
  sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/; 0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8.0.32"/; 0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="8181"/; 0,/^TZ=/s#^TZ=.*#TZ="Etc/UTC"#; 0,/^AUTOSYNC_CRON=/s/^AUTOSYNC_CRON=.*/AUTOSYNC_CRON="30 5 * * *"/' "$D/$N"
  (cd "$D" && bash "$N" generate </dev/null >/dev/null 2>&1)
  echo "8.0.32" > "$ST/mongo_version"; cp "$D/.env" "$ST/upenv"
  env26="$(cksum < "$D/.env")"; compose26="$(cksum < "$D/docker-compose.yml")"
  : > "$LOG"
}
# the published file with the default Catalog 25.4 and the time zone of the server (option 2 of the old
# installer aligned it)
FRESH="$T/fresh.sh"
sed 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/; 0,/^TZ=/s#^TZ=.*#TZ="Etc/UTC"#; 0,/^AUTOSYNC_CRON=/s/^AUTOSYNC_CRON=.*/AUTOSYNC_CRON="30 5 * * *"/' "$NEW" > "$FRESH"
nocompose() { ! grep -Eq "compose.* (up|down|pull)" "$LOG"; }

# 10a. The screenshot: settings 25.4, .env and the running catalog-web 26.3
installation26
cp "$FRESH" "$D/$N"
out="$(printf 'n\n\n21\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "fresh download: named at the start, its values offered before anything else" '[ "$(grep -n "The settings say Catalog 25.4.4191.133, 26.3.4789.148 is installed\." <<< "$out" | head -n1 | cut -d: -f1)" -lt "$(grep -n "Installation Portal" <<< "$out" | head -n1 | cut -d: -f1)" ] && grep -q "CATALOG_VERSION *25.4.4191.133 -> 26.3.4789.148" <<< "$out" && grep -q "Taking them over writes these values into $N" <<< "$out"'
check "fresh download: the header and the cards show the installed 26.3, the note the settings" 'grep -Eq "Installation Portal +\(Catalog 26\.3\.4789\.148 .* up to date\)" <<< "$out" && grep -Eq "I\) INSTALL +.*Catalog 26\.3\.4789\.148 .* 11 running" <<< "$out" && grep -Eq "U\) UPDATE +.*Catalog up to date" <<< "$out" && grep -q "The settings say Catalog 25.4.4191.133, 26.3.4789.148 is installed - option 23 takes the installation.s values over." <<< "$out" && ! grep -q "option 2 regenerates them" <<< "$out"'
check "fresh download: U / option 21 says up to date" 'grep -q "Installed Catalog: 26.3.4789.148" <<< "$out" && grep -q "The Catalog is up to date." <<< "$out" && grep -q "No updates of MongoDB, OpenSearch, RabbitMQ, MinIO or Nginx Proxy Manager inside their series." <<< "$out"'
check "fresh download: declined - nothing changed" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/$N" && [ "$(cksum < "$D/.env")" = "$env26" ] && nocompose'
out="$(printf 'n\n\n8\ns\ny\nn\n0\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "fresh download: option 8 apply refuses to lower the Catalog and offers the take-over" 'grep -q "Catalog 25.4.4191.133 would replace the installed 26.3.4789.148; the database was migrated by 26.3." <<< "$out" && grep -q "older than the installation (a new download of the installer has its defaults) - nothing was written" <<< "$out" && [ "$(cksum < "$D/.env")" = "$env26" ] && nocompose'
out="$(printf 'y\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "fresh download: the take-over writes the values of the installation, nothing else" 'grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N" && grep -qxF "MONGO_TAG=\"8.0.32\"" "$D/$N" && grep -qxF "CATALOG_WEB_PORT=\"8181\"" "$D/$N" && grep -qxF "OPENSEARCH_TAG=\"2.19.5\"" "$D/$N" && grep -qxF "TZ=\"Etc/UTC\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$env26" ] && [ "$(cksum < "$D/docker-compose.yml")" = "$compose26" ] && nocompose && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$(ls "$D/$N".bak-* | tail -n 1)"'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "fresh download: afterwards no note, the files match the settings" '! grep -q "The settings say" <<< "$out" && ! grep -q "do not match the settings" <<< "$out" && grep -q "(Catalog 26.3.4789.148 - up to date)" <<< "$out"'

# 10b. Option 2 of the old installer then wrote .env and the compose file from the default settings in the
#      same second as their backups; catalog-web and the workers still run 26.3. The installer is updated.
server_state() {
  installation26
  rm -f "$ST/up"
  G="$T/gen25"; rm -rf "$G"; mkdir -p "$G"; cp "$FRESH" "$G/$N"; cp "$D/.env" "$G/.env.bak-20000101-000000"
  (cd "$G" && bash "$N" generate </dev/null >/dev/null 2>&1)
  touch "$ST/up"
  cp -p "$D/.env" "$D/.env.bak-20261011-123742"; cp -p "$D/docker-compose.yml" "$D/docker-compose.yml.bak-20261011-123742"
  cp "$G/.env" "$D/.env"; cp "$G/docker-compose.yml" "$D/docker-compose.yml"; cp "$FRESH" "$D/$N"
  envA="$(cksum < "$D/.env")"
}
server_state
nbak() { ls "$D"/"$1".bak-* | wc -l; }; envbaks="$(nbak .env)"; composebaks="$(nbak docker-compose.yml)"
V2="$T/v2.sh"; sed 's/Raynet One Technology Catalog - Installation Portal\${C_RST}   (/Raynet One Technology Catalog - Installation Portal${C_RST} v2   (/' "$NEW" > "$V2"
check "server state: settings, .env and compose 25.4, catalog-web 26.3, the backups 26.3" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/$N" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133$" "$D/.env" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148$" "$D/.env.bak-20261011-123742" && [ "$(cat "$ST/catalog_tag")" = 26.3.4789.148 ] && [ "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env")" = "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env.bak-20261011-123742")" ]'
out="$(SHIM_INSTALLER="$V2" bash "$D/$N" self-update </dev/null 2>&1)"; rc=$?
check "server state: the update carries the settings over as they are" '[ "$rc" -eq 0 ] && grep -q "Installer updated" <<< "$out" && grep -q "Installation Portal\${C_RST} v2" "$D/$N" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/$N"'
: > "$LOG"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "server state: generate refuses to lower the Catalog, says what would happen, writes nothing" '[ "$rc" -ne 0 ] && grep -q "Catalog 25.4.4191.133 would replace the installed 26.3.4789.148; the database was migrated by 26.3." <<< "$out" && grep -q "adopt \." <<< "$out" && [ "$(cksum < "$D/.env")" = "$envA" ] && [ "$(nbak .env)" -eq "$envbaks" ]'
for c in up setup; do
  out="$(bash "$D/$N" "$c" </dev/null 2>&1)"; rc=$?
  check "server state: '$c' refuses to start 25.4 against the running 26.3" '[ "$rc" -ne 0 ] && grep -q "Catalog 25.4.4191.133 would replace the installed 26.3.4789.148" <<< "$out" && [ "$(cksum < "$D/.env")" = "$envA" ] && nocompose'
done
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "server state: status names the installed Catalog and the settings" 'grep -q "Catalog 26.3.4789.148 installed (the settings say 25.4.4191.133)" <<< "$out" && grep -q "The settings say Catalog 25.4.4191.133, 26.3.4789.148 is installed" <<< "$out"'
out="$(printf 'n\n\n2\nn\n\n6\nn\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "server state: the menu names it, the take-over table comes from the backup of that second" 'grep -q "Installation Portal v2   (Catalog 26.3.4789.148 - up to date)" <<< "$out" && grep -q "option 23 takes the installation.s values over." <<< "$out" && grep -q "MONGO_TAG *8.0 -> 8.0.32" <<< "$out" && grep -q "CATALOG_WEB_PORT *8080 -> 8181" <<< "$out" && grep -q "other values come from .env.bak-20261011-123742" <<< "$out"'
check "server state: options 2 and 6 refuse, nothing changed" 'grep -q "nothing was written" <<< "$out" && grep -q "nothing was started" <<< "$out" && [ "$(grep -c "would replace the installed 26.3.4789.148" <<< "$out")" -ge 2 ] && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/$N" && [ "$(cksum < "$D/.env")" = "$envA" ] && nocompose'
out="$(printf 'y\ny\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "server state: the take-over writes the installation's values" 'grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N" && grep -qxF "MONGO_TAG=\"8.0.32\"" "$D/$N" && grep -qxF "CATALOG_WEB_PORT=\"8181\"" "$D/$N" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$(ls "$D/$N".bak-* | tail -n 1)"'
check "server state: the files of the running Catalog are back, the passwords too, the others kept as backups" '[ "$(cksum < "$D/.env")" = "$env26" ] && [ "$(cksum < "$D/docker-compose.yml")" = "$compose26" ] && grep -l "rayventory-catalog:25.4.4191.133" "$D"/.env.bak-* >/dev/null && [ "$(nbak docker-compose.yml)" -eq $((composebaks + 1)) ] && [ "$(nbak .env)" -eq $((envbaks + 1)) ] && nocompose'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "server state: afterwards no note" '! grep -q "The settings say\|The files say" <<< "$out" && ! grep -q "do not match the settings" <<< "$out"'

# 10c. MongoDB below the running one
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0"/' "$D/$N"
env_before="$(cksum < "$D/.env")"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "MongoDB 7.0 against the running 8.0.32: generate refuses" '[ "$rc" -ne 0 ] && grep -q "MongoDB 7.0 would replace the running 8.0.32" <<< "$out" && [ "$(cksum < "$D/.env")" = "$env_before" ]'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "MongoDB 7.0 against 8.0.32: named in the menu" 'grep -q "The settings say MongoDB 7.0, 8.0.32 is installed - option 23" <<< "$out"'
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8.0.30"/' "$D/$N"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "MongoDB 8.0.30 against the running 8.0.32: a patch back within the series is written" '[ "$rc" -eq 0 ] && grep -qx "MONGO_TAG=8.0.30" "$D/.env" && ! grep -q "would replace" <<< "$out"'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "MongoDB 8.0.30 against 8.0.32: no note" '! grep -q "The settings say MongoDB" <<< "$out"'
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8.0.32"/' "$D/$N"; (cd "$D" && bash "$N" generate </dev/null >/dev/null 2>&1)
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8.0.32"/; 0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG="2.17.0"/' "$D/$N"
out="$(printf 'n\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "OpenSearch 2.17.0 against 2.19.5: named in the menu" 'grep -q "The settings say OpenSearch 2.17.0, 2.19.5 is installed - option 23" <<< "$out" && grep -q "OPENSEARCH_TAG *2.17.0 -> 2.19.5" <<< "$out"'
sed -i '0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG="2.19.5"/' "$D/$N"

# 10d. A new catalog.sh next to the installer of the installation: it names it at its start and takes the
#      settings of that installer over
cp "$FRESH" "$D/catalog.sh"
out="$(printf 'y\nn\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "catalog.sh next to it: named at the start, the settings of the installer taken over" 'grep -q "The settings say Catalog 25.4.4191.133, 26.3.4789.148 is installed\." <<< "$out" && grep -q "$N in this folder has other settings than catalog.sh" <<< "$out" && grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/catalog.sh" && [ -f "$D/$N" ] && nocompose'
rm -f "$D/catalog.sh" "$D/catalog.sh".bak-*

# 10e. In the server state the containers are what shows 26.3: stopping them is refused, and a stopped
#      catalog-web still counts
server_state
out="$(bash "$D/$N" down </dev/null 2>&1)"; rc=$?
check "server state: 'down' refuses to remove the containers that show 26.3" '[ "$rc" -ne 0 ] && grep -q "Catalog 25.4.4191.133 would replace the installed 26.3.4789.148" <<< "$out" && grep -q "nothing was stopped" <<< "$out" && nocompose && [ -f "$ST/up" ]'
out="$(printf 'n\n\n13\nn\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "server state: option 13 refuses too" 'grep -q "nothing was stopped" <<< "$out" && nocompose && [ -f "$ST/up" ]'
rm -f "$ST/up"; touch "$ST/exited"
out="$(bash "$D/$N" up </dev/null 2>&1)"; rc=$?
check "a stopped catalog-web 26.3: 'up' refuses the 25.4 files" '[ "$rc" -ne 0 ] && grep -q "Catalog 25.4.4191.133 would replace the installed 26.3.4789.148" <<< "$out" && nocompose && [ ! -f "$ST/up" ]'
out="$(printf 'n\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "a stopped catalog-web 26.3: named at the start, the values of that second offered" 'grep -q "The settings say Catalog 25.4.4191.133, 26.3.4789.148 is installed\." <<< "$out" && grep -q "other values come from .env.bak-20261011-123742" <<< "$out" && grep -q "(Catalog 26.3.4789.148" <<< "$out"'
rm -f "$ST/exited"; touch "$ST/up"

# 10f. On the command line: 'adopt .' takes the values over; 'up' then points to generate, not back to adopt
out="$(bash "$D/$N" adopt . </dev/null 2>&1)"; rc=$?
check "CLI 'adopt .': the values taken over, the files left, generate named" '[ "$rc" -eq 0 ] && grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N" && grep -qxF "CATALOG_WEB_PORT=\"8181\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$envA" ] && grep -q "generate. writes them from the settings" <<< "$out" && nocompose'
out="$(bash "$D/$N" up </dev/null 2>&1)"; rc=$?
check "CLI 'up' afterwards: refused, points to generate" '[ "$rc" -ne 0 ] && grep -q "The settings fit the installation: write the files from them first (.*generate.)" <<< "$out" && ! grep -q "adopt \." <<< "$out" && nocompose'
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "CLI generate writes 26.3 with the values and passwords of the installation" '[ "$rc" -eq 0 ] && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148" "$D/.env" && grep -qx "CATALOG_WEB_PORT=8181" "$D/.env" && [ "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env")" = "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env.bak-20261011-123742")" ]'
out="$(bash "$D/$N" up </dev/null 2>&1)"; rc=$?
check "CLI 'up' then starts 26.3" '[ "$rc" -eq 0 ] && [ "$(cat "$ST/catalog_tag")" = 26.3.4789.148 ]'

# 10g. No .env and no backup of it names the installed Catalog: only the versions are known
server_state; rm -f "$D"/.env.bak-*
out="$(printf 'n\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "no backup names the installed Catalog: the versions offered, no broken sentence" 'grep -q "CATALOG_VERSION *25.4.4191.133 -> 26.3.4789.148" <<< "$out" && grep -q "No .env and no backup of it names the installed Catalog 26.3.4789.148" <<< "$out" && ! grep -q "other values come from" <<< "$out"'

# 10h. A new download whose default is the installed Catalog: the versions fit, other values differ. The
#      menu names them instead of "option 2 regenerates them", no time zone note (the Catalog runs in the
#      server's), nothing offered at the start; option 23 takes them over
installation26
sed 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$NEW" > "$D/$N"
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "same version, new download: the differing values named, not option 2" 'grep -q "The settings differ from the installation in TZ, CATALOG_WEB_PORT, AUTOSYNC_CRON - option 23 takes the installation.s values over, option 2 writes the settings\." <<< "$out" && ! grep -q "option 2 regenerates them" <<< "$out" && ! grep -q "option 2 offers to align it" <<< "$out" && ! grep -q "Taking them over writes" <<< "$out"'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "same version: status names the values too" 'grep -q "The settings differ from the installation in TZ, CATALOG_WEB_PORT, AUTOSYNC_CRON - .*adopt \.. takes the installation.s values over" <<< "$out"'
out="$(printf '23\ny\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "same version: option 23 lists and takes the values of this folder over, the files stay" 'grep -q "CATALOG_WEB_PORT *8080 -> 8181" <<< "$out" && grep -q "TZ *Europe/Berlin -> Etc/UTC" <<< "$out" && grep -qxF "CATALOG_WEB_PORT=\"8181\"" "$D/$N" && grep -qxF "TZ=\"Etc/UTC\"" "$D/$N" && grep -qxF "AUTOSYNC_CRON=\"30 5 * * *\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$env26" ] && nocompose'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "same version: afterwards no note" '! grep -q "differ from the installation" <<< "$out" && ! grep -q "regenerates them" <<< "$out"'

# 10i. After a reset (option 99) nothing is installed: .env no longer holds back an older Catalog
installation26
out="$(printf '99\nDELETE\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "reset: containers and data volumes gone, .env still names 26.3" '[ ! -f "$ST/up" ] && [ ! -f "$ST/wd" ] && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148" "$D/.env"'
out="$(bash "$D/$N" set-version 25.4.4191.133 </dev/null 2>&1)"; rc=$?
check "after a reset an older Catalog is selected and written" '[ "$rc" -eq 0 ] && grep -qxF "CATALOG_VERSION=\"25.4.4191.133\"" "$D/$N" && bash "$D/$N" generate </dev/null >/dev/null 2>&1 && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133" "$D/.env"'

# 10j. The values .env derives: CATALOG_HOSTNAME empty (automatic) with the kept container-ID name of a
#      licensed Catalog in .env, MONGO_CACHE_GB empty with a cache in .env the memory no longer gives - no
#      difference, nothing to take over; the start writes the cache without a note of other settings
installation26
sed -i 's/^CATALOG_HOSTNAME=.*/CATALOG_HOSTNAME=4f9c2d71e8a3/; s/^MONGO_WT_CACHE_GB=.*/MONGO_WT_CACHE_GB=3/' "$D/.env"
cp "$D/.env" "$ST/upenv"; echo 4f9c2d71e8a3 > "$ST/hostname"
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "derived values: the menu names no difference, offers nothing" '! grep -q -e "differ from the installation" -e "do not match the settings" -e "The settings say" -e "Taking them over writes" <<< "$out"'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "derived values: status names no difference" '! grep -q -e "differ from the installation" -e "CATALOG_HOSTNAME" -e "MONGO_" <<< "$out"'
out="$(printf '23\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "derived values: option 23 has nothing to take over, the settings stay automatic" '! grep -q -e "has other values than the settings" -e "Took over" <<< "$out" && grep -qx "CATALOG_HOSTNAME=\"\"" "$D/$N" && grep -qx "MONGO_CACHE_GB=\"\"" "$D/$N" && ! ls "$D/$N".bak-* >/dev/null 2>&1'
out="$(SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" up </dev/null 2>&1)"; rc=$?
check "derived values: up writes the cache for the memory, no false difference, the host name kept" '[ "$rc" -eq 0 ] && grep -q "MongoDB gets a cache of 11 GB (was 3 GB)" <<< "$out" && ! grep -q -e "do not match the settings" -e "differ from the installation" -e "would replace" <<< "$out" && grep -qx "MONGO_WT_CACHE_GB=11" "$D/.env" && grep -qx "CATALOG_HOSTNAME=4f9c2d71e8a3" "$D/.env" && [ "$(cat "$ST/hostname")" = 4f9c2d71e8a3 ]'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "derived values: after the refresh still no note" '! grep -q -e "differ from the installation" -e "do not match the settings" <<< "$out"'
# a fixed CATALOG_HOSTNAME of the settings that differs from .env is a difference
sed -i 's/^CATALOG_HOSTNAME=""$/CATALOG_HOSTNAME="catalog-other"/' "$D/$N"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "a fixed CATALOG_HOSTNAME other than .env: named" 'grep -q "The settings differ from the installation in CATALOG_HOSTNAME" <<< "$out"'
sed -i 's/^CATALOG_HOSTNAME="catalog-other"$/CATALOG_HOSTNAME=""/' "$D/$N"

# 10k. A refused start asks nothing before: 'setup' and option 7 in the server state on an engine with 8 GB
#      stop at the version, before the memory question
server_state
out="$(SHIM_MEMTOTAL=8589934592 bash "$D/$N" setup </dev/null 2>&1)"; rc=$?
check "server state, 8 GB: 'setup' refused before the memory question, nothing written" '[ "$rc" -ne 0 ] && grep -q "Catalog 25.4.4191.133 would replace the installed 26.3.4789.148" <<< "$out" && ! grep -q "GB of memory; at least" <<< "$out" && [ "$(cksum < "$D/.env")" = "$envA" ] && nocompose'
out="$(printf 'n\n\n7\nn\n\n0\n' | SHIM_MEMTOTAL=8589934592 bash "$D/$N" menu 2>&1)"
check "server state, 8 GB: option 7 refused before the memory question" 'grep -q "nothing was written" <<< "$out" && ! grep -q "GB of memory; at least" <<< "$out" && ! grep -q "Continue with .* GB anyway" <<< "$out" && [ "$(cksum < "$D/.env")" = "$envA" ] && nocompose'

# 10l. A new download after a licensed Catalog kept its container-ID name (CATALOG_HOSTNAME in the backup
#      of that second, the server's name in the new .env): the take-over keeps the licensed name, with the
#      backups put back and without them
lic_state() {
  server_state
  sed -i 's/^CATALOG_HOSTNAME=.*/CATALOG_HOSTNAME=4f9c2d71e8a3/' "$D/.env.bak-20261011-123742"
  cp "$D/.env.bak-20261011-123742" "$ST/upenv"; echo 4f9c2d71e8a3 > "$ST/hostname"
}
lic_state
out="$(printf 'y\ny\n\n0\n' | SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" menu 2>&1)"
check "licensed name in the backup: the take-over puts it back" 'grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N" && grep -qx "CATALOG_HOSTNAME=4f9c2d71e8a3" "$D/.env"'
out="$(SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "licensed name in the backup: generate and up keep it, the license stays valid, no note" '[ "$rc" -eq 0 ] && grep -qx "CATALOG_HOSTNAME=4f9c2d71e8a3" "$D/.env" && ! grep -q "needs a license" <<< "$out" && SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" up </dev/null >/dev/null 2>&1 && [ "$(cat "$ST/hostname")" = 4f9c2d71e8a3 ] && ! printf "0\n" | bash "$D/$N" menu 2>&1 | grep -q -e "differ from the installation" -e "do not match the settings"'
lic_state
out="$(printf 'y\nn\n\n0\n' | SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" menu 2>&1)"
check "licensed name in the backup, the backups not put back: the name taken over" 'grep -q "CATALOG_HOSTNAME *(empty) -> 4f9c2d71e8a3" <<< "$out" && grep -qxF "CATALOG_HOSTNAME=\"4f9c2d71e8a3\"" "$D/$N"'
out="$(SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "licensed name, the backups not put back: generate writes it, not the name of the server" '[ "$rc" -eq 0 ] && grep -qx "CATALOG_HOSTNAME=4f9c2d71e8a3" "$D/.env" && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148" "$D/.env"'

# 10m. The backups of that second come from an older installer: no CATALOG_HOSTNAME, no MONGO_WT_CACHE_GB, and
#      catalog-web runs with its container ID, to which the license is bound. The take-over fixes that name (the
#      new .env has the server's), no cache; put back, the next generate keeps the name and computes the cache
#      again - with the setting automatic too
old_state() {
  server_state
  sed -i '/^CATALOG_HOSTNAME=/d; /^MONGO_WT_CACHE_GB=/d' "$D/.env.bak-20261011-123742"
  sed -i '/hostname: \${CATALOG_HOSTNAME}/d; /wiredTigerCacheSizeGB/d' "$D/docker-compose.yml.bak-20261011-123742"
  cp "$D/.env.bak-20261011-123742" "$ST/upenv"; rm -f "$ST/hostname"
}
old_state
out="$(printf 'y\ny\n\n0\n' | SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" menu 2>&1)"
check "older backups put back: the licensed container-ID name in the table, no cache, the files of that installer back" 'grep -q "CATALOG_HOSTNAME *(empty) -> 4f9c2d71e8a3" <<< "$out" && ! grep -q -e "MONGO_CACHE_GB " -e "MONGO_WT_CACHE_GB" <<< "$(sed -n "/has other values than the settings/,/Taking them over/p" <<< "$out")" && grep -q "Took over" <<< "$out" && grep -qxF "CATALOG_HOSTNAME=\"4f9c2d71e8a3\"" "$D/$N" && ! grep -q "^CATALOG_HOSTNAME=" "$D/.env" && ! grep -q "hostname: \${CATALOG_HOSTNAME}" "$D/docker-compose.yml"'
cp -p "$D/.env" "$T/old.env"; cp -p "$D/docker-compose.yml" "$T/old.yml"
out="$(SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "older backups put back: generate writes the licensed container-ID name, the cache computed again" '[ "$rc" -eq 0 ] && grep -qx "CATALOG_HOSTNAME=4f9c2d71e8a3" "$D/.env" && ! grep -q "needs a license" <<< "$out" && grep -qx "MONGO_WT_CACHE_GB=11" "$D/.env" && grep -q "^    hostname: \${CATALOG_HOSTNAME}$" "$D/docker-compose.yml" && [ "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env")" = "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env.bak-20261011-123742")" ]'
out="$(SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" up </dev/null 2>&1)"; rc=$?
check "older backups put back: the start keeps the license" '[ "$rc" -eq 0 ] && [ "$(cat "$ST/hostname")" = 4f9c2d71e8a3 ] && ! grep -q -e "no valid license" -e "would replace" <<< "$out"'
cp -p "$T/old.env" "$D/.env"; cp -p "$T/old.yml" "$D/docker-compose.yml"
sed -i 's/^CATALOG_HOSTNAME="4f9c2d71e8a3"$/CATALOG_HOSTNAME=""/' "$D/$N"
out="$(SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "older files, the setting automatic: generate keeps the licensed container-ID name" '[ "$rc" -eq 0 ] && grep -q "catalog-web keeps its host name 4f9c2d71e8a3: the Catalog.s license" <<< "$out" && grep -qx "CATALOG_HOSTNAME=4f9c2d71e8a3" "$D/.env" && grep -qx "MONGO_WT_CACHE_GB=11" "$D/.env"'

# 10n. The same older backups, not put back: the take-over still fixes the licensed name, so 'generate' (which
#      the files-stay path suggests) keeps it instead of the server's name of the new .env
old_state
out="$(printf 'y\nn\n\n0\n' | SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" menu 2>&1)"
check "older backups not put back: the licensed container-ID name taken over" 'grep -q "CATALOG_HOSTNAME *(empty) -> 4f9c2d71e8a3" <<< "$out" && grep -qxF "CATALOG_HOSTNAME=\"4f9c2d71e8a3\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$envA" ]'
out="$(SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "older backups not put back: generate keeps the licensed name, not the server's" '[ "$rc" -eq 0 ] && grep -qx "CATALOG_HOSTNAME=4f9c2d71e8a3" "$D/.env" && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148" "$D/.env" && ! grep -q "needs a license" <<< "$out"'
out="$(SHIM_LICENSE_HOST=4f9c2d71e8a3 bash "$D/$N" up </dev/null 2>&1)"; rc=$?
check "older backups not put back: the start keeps the license" '[ "$rc" -eq 0 ] && [ "$(cat "$ST/hostname")" = 4f9c2d71e8a3 ] && ! grep -q -e "no valid license" -e "would replace" <<< "$out"'
# without a valid license there is nothing to keep: the name is not offered
old_state
out="$(printf 'y\nn\n\n0\n' | SHIM_LICENSE_VALID=false bash "$D/$N" menu 2>&1)"
check "older backups, no valid license: the host name not offered" 'grep -q "Took over" <<< "$out" && ! grep -q "CATALOG_HOSTNAME " <<< "$out" && grep -qxF "CATALOG_HOSTNAME=\"\"" "$D/$N"'

# 10o. A new download with the default of a release (the newest Catalog, 26.3) next to an installation of 25.4:
#      the menu names it and offers nothing at the start; setup, generate, up and options 2, 6 and 7 ask before
#      they raise the Catalog without the upgrade's MongoDB backup (no answer, or no: nothing written or
#      started); option 21 upgrades it with the backup, option 23 keeps 25.4
newer_download() {
  setup
  sed 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$NEW" > "$D/$N"
  env25="$(cksum < "$D/.env")"
}
newer_download
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "newer download: the menu names it - U or 21 upgrades, 23 keeps 25.4 - nothing offered at the start" 'grep -q "The settings say Catalog 26.3.4789.148, 25.4.4191.133 is installed - U or option 21 upgrades it (MongoDB backup, health check, rollback), option 23 keeps 25.4.4191.133\.$" <<< "$out" && grep -q "Installation Portal *(Catalog 25.4.4191.133" <<< "$out" && ! grep -q -e "Taking them over writes" -e "option 2 regenerates them" <<< "$out" && nocompose'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "newer download: status names it with the commands" 'grep -q "Catalog 25.4.4191.133 installed (the settings say 26.3.4789.148)" <<< "$out" && grep -q "The settings say Catalog 26.3.4789.148, 25.4.4191.133 is installed - .*upgrade. upgrades it (MongoDB backup, health check, rollback), .*adopt \.. keeps 25.4.4191.133\.$" <<< "$out"'
for c in setup generate; do
  out="$(bash "$D/$N" "$c" </dev/null 2>&1)"; rc=$?
  check "newer download: '$c' without an answer - no upgrade without the backup, nothing written or started" '[ "$rc" -ne 0 ] && grep -q "Catalog 26.3.4789.148 would replace the installed 25.4.4191.133 without a MongoDB backup, health check or rollback" <<< "$out" && grep -q "upgrade. upgrades it with them; .*adopt \.. keeps Catalog 25.4.4191.133\." <<< "$out" && grep -q "Nothing was written." <<< "$out" && [ "$(cksum < "$D/.env")" = "$env25" ] && nocompose && [ ! -d "$D/backups" ]'
done
out="$(printf 'n\n' | bash "$D/$N" setup 2>&1)"; rc=$?
check "newer download: 'setup' answered no - nothing written or started" '[ "$rc" -ne 0 ] && grep -q "would replace the installed 25.4.4191.133 without a MongoDB backup" <<< "$out" && grep -q "Nothing was written." <<< "$out" && [ "$(cksum < "$D/.env")" = "$env25" ] && nocompose'
out="$(printf '2\nn\n\n7\nn\n\n6\nn\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "newer download: options 2 and 7 ask (no: nothing written), option 6 names it and starts only the files as they are" '[ "$(grep -c "would replace the installed 25.4.4191.133 without a MongoDB backup" <<< "$out")" -eq 2 ] && [ "$(grep -c "Nothing was written." <<< "$out")" -eq 2 ] && grep -q "U or option 21 upgrades it with them; option 23 keeps Catalog 25.4.4191.133." <<< "$out" && grep -q "WARN The settings say Catalog 26.3.4789.148, 25.4.4191.133 is installed - U or option 21" <<< "$out" && grep -q "Cancelled." <<< "$out" && [ "$(cksum < "$D/.env")" = "$env25" ] && nocompose'
# answered yes, the user's choice: written and started, asked once
out="$(printf 'y\n' | bash "$D/$N" setup 2>&1)"; rc=$?
check "newer download: 'setup' answered yes - asked once, 26.3 written and started" '[ "$rc" -eq 0 ] && [ "$(grep -c "would replace the installed" <<< "$out")" -eq 1 ] && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148" "$D/.env" && [ "$(cat "$ST/catalog_tag")" = 26.3.4789.148 ]'
# 'generate' answered yes: the files name 26.3, 25.4 runs - named, 'up' and option 6 ask, option 21 upgrades with the backup
newer_download
out="$(printf 'y\n' | bash "$D/$N" generate 2>&1)"; rc=$?
check "newer download: 'generate' answered yes writes 26.3 and starts nothing" '[ "$rc" -eq 0 ] && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148" "$D/.env" && nocompose'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "files of 26.3 next to the running 25.4: the menu names them" 'grep -q "The files say Catalog 26.3.4789.148, 25.4.4191.133 is installed - U or option 21 upgrades it (MongoDB backup, health check, rollback), option 23 keeps 25.4.4191.133\.$" <<< "$out"'
out="$(bash "$D/$N" up </dev/null 2>&1)"; rc=$?
check "files of 26.3: 'up' without an answer starts nothing" '[ "$rc" -ne 0 ] && grep -q "names Catalog 26.3.4789.148, the catalog-web container has 25.4.4191.133\.$" <<< "$out" && grep -q "Nothing was started." <<< "$out" && nocompose'
out="$(printf '6\nn\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "files of 26.3: option 6 asks, no - nothing started" 'grep -q "would replace the installed 25.4.4191.133 without a MongoDB backup" <<< "$out" && grep -q "Nothing was started." <<< "$out" && nocompose && [ "$(cat "$ST/catalog_tag")" = 25.4.4191.133 ]'
out="$(printf '21\ny\ny\n0\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "files of 26.3: option 21 upgrades 25.4 with the MongoDB backup, asks nothing about it" 'grep -q "Installed Catalog: 25.4.4191.133" <<< "$out" && ls "$D"/backups/mongo-*.archive.gz >/dev/null 2>&1 && grep -q "Catalog upgraded: 25.4.4191.133 -> 26.3.4789.148." <<< "$out" && ! grep -q "without a backup anyway" <<< "$out" && [ "$(cat "$ST/catalog_tag")" = 26.3.4789.148 ]'
# option 23 keeps the installed Catalog: the settings take 25.4, the files stay
newer_download
out="$(printf '23\ny\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "newer download: option 23 keeps 25.4 - the settings take the installed Catalog, the files stay" 'grep -q "CATALOG_VERSION *26.3.4789.148 -> 25.4.4191.133" <<< "$out" && grep -qxF "CATALOG_VERSION=\"25.4.4191.133\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$env25" ] && nocompose'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "newer download kept at 25.4: afterwards no note" '! grep -q -e "The settings say" -e "The files say" <<< "$out"'

# 11. The installer installed the Catalog with the values of its new installation (the time zone of the server,
#     no Nginx Proxy Manager, the synchronization at 8:30), then it was downloaded again into the folder: the
#     published defaults (Europe/Berlin, true, 30 7). The new download takes the installation's values over by
#     itself at its start - the menu, 'status', 'generate' and 'up' - before anything else; an edited file only
#     names them. PUB: a release of these tests (the Podman of the fakes, no update check) with its own sum.
publish() { sed -i "s/^SETTINGS_PUBLISHED_SUM=.*/SETTINGS_PUBLISHED_SUM=\"$(bash "$1" __settings_hash)\"/" "$1"; }
PUB="$T/published.sh"; sed 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$NEW" > "$PUB"; publish "$PUB"
# the line of the sum, whether it is gone (a one-way state: the installer wrote a setting, or a start found the
# section changed or had nothing to take over), and the file without it
sumline() { sed -n 's/^SETTINGS_PUBLISHED_SUM=//p' "$1"; }
gone() { [ "$(sumline "$1")" = '""' ]; }
body() { grep -v '^SETTINGS_PUBLISHED_SUM=' "$1" | cksum; }
export SHIM_TZ="Europe/Istanbul"
wizard_installation() {
  rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$PUB" "$D/$N"
  sed -i '0,/^TZ=/s#^TZ=.*#TZ="Europe/Istanbul"#; 0,/^INSTALL_NGINX_PROXY_MANAGER=/s/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/; 0,/^AUTOSYNC_CRON=/s/^AUTOSYNC_CRON=.*/AUTOSYNC_CRON="30 8 * * *"/' "$D/$N"
  (cd "$D" && bash "$N" generate </dev/null >/dev/null 2>&1)
  touch "$ST/up"; sed -n 's/^CATALOG_IMAGE=.*://p' "$D/.env" > "$ST/catalog_tag"; echo "8.0.4" > "$ST/mongo_version"
  (cd "$D" && pwd -P) > "$ST/wd"; cp "$D/.env" "$ST/upenv"
  cp "$PUB" "$D/$N"
  envW="$(cksum < "$D/.env")"; composeW="$(cksum < "$D/docker-compose.yml")"
  : > "$LOG"
}
# line PATTERN -> the number of the first line of $out with PATTERN (999999: none)
line() { local n; n="$(grep -n -m 1 -- "$1" <<< "$out" | cut -d: -f1)"; echo "${n:-999999}"; }
said() { grep -q "^ This installer is a new download with its default settings; the installation$" <<< "$out" && grep -q "^ here has other values - taken over:$" <<< "$out"; }
table3() { [ "$(grep -c "^   [A-Z][A-Z_]* .* -> " <<< "$out")" -eq 3 ] && grep -q "^   TZ  *Europe/Berlin -> Europe/Istanbul$" <<< "$out" && grep -q "^   INSTALL_NGINX_PROXY_MANAGER  *true -> false$" <<< "$out" && grep -qF "   AUTOSYNC_CRON                  30 7 * * * -> 30 8 * * *" <<< "$out"; }
written() { grep -qxF "TZ=\"Europe/Istanbul\"" "$D/$N" && grep -qxF "INSTALL_NGINX_PROXY_MANAGER=\"false\"" "$D/$N" && grep -qxF "AUTOSYNC_CRON=\"30 8 * * *\"" "$D/$N" && [ "$(ls "$D/$N".bak-* | wc -l)" -eq 1 ] && cmp -s "$(ls "$D/$N".bak-*)" "$PUB"; }
untouched() { [ "$(cksum < "$D/.env")" = "$envW" ] && [ "$(cksum < "$D/docker-compose.yml")" = "$composeW" ] && nocompose; }
check "published test release: its settings are as published" '[ "$(bash "$PUB" __settings_hash)" = "$(sed -n "s/^SETTINGS_PUBLISHED_SUM=\"\(.*\)\"$/\1/p" "$PUB")" ]'
wizard_installation
# (n: a question would keep the values - there is none; a pipe has no pause before the menu, the n is the menu's)
out="$(printf 'n\n0\n' | bash "$D/$N" menu 2>&1)"
check "new download, menu: the installation's values taken over first, without a question, then the menu" 'said && table3 && [ "$(line "This installer is a new download")" -lt "$(line "Installation Portal")" ] && grep -q "Taken over: 3 value(s) - .env, docker-compose.yml and the containers stay.$" <<< "$out" && grep -q "^    Previous version: $N.bak-" <<< "$out" && ! grep -q "Cancelled" <<< "$out"'
check "new download, menu: the values written, the installer kept as a backup, .env, compose and containers untouched" 'written && untouched'
check "new download, menu: no note of other values afterwards" '! grep -q -e "differ from the installation" -e "do not match the settings" -e "The settings say" <<< "$out"'
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "new download: the second start says nothing" '! grep -q -e "new download" -e "differ from the installation" -e "Press Enter to open the menu" <<< "$out" && [ "$(ls "$D/$N".bak-* | wc -l)" -eq 1 ]'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "new download: a later 'status' says nothing either" '! grep -q -e "new download" -e "differ from the installation" <<< "$out" && grep -q "Catalog 26.3.4789.148 installed$" <<< "$out"'
wizard_installation
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "new download, 'status': taken over first, then the status without a note" 'said && table3 && [ "$(line "This installer is a new download")" -lt "$(line "NAME STATUS")" ] && ! grep -q "differ from the installation" <<< "$out" && written && untouched'
wizard_installation
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "new download, 'generate': taken over first, then the same files written" '[ "$rc" -eq 0 ] && said && table3 && written && [ "$(cksum < "$D/.env")" = "$envW" ] && [ "$(cksum < "$D/docker-compose.yml")" = "$composeW" ] && nocompose'
wizard_installation
out="$(bash "$D/$N" up </dev/null 2>&1)"; rc=$?
check "new download, 'up': taken over first, then the files started as they are, no note" '[ "$rc" -eq 0 ] && said && table3 && written && [ "$(line "This installer is a new download")" -lt "$(line "Starting the stack")" ] && ! grep -q "do not match the settings" <<< "$out" && [ "$(cksum < "$D/.env")" = "$envW" ] && grep -q "compose.* up -d --remove-orphans$" "$LOG"'
# changed on purpose: one setting edited after the download, or a hand edit of the section that changes no value
wizard_installation
sed -i 's/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="900"/' "$D/$N"; edited="$(body "$D/$N")"
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "one setting edited after the download: not taken over, the menu names the values" '! grep -q "new download" <<< "$out" && grep -q "The settings differ from the installation in TZ, INSTALL_NGINX_PROXY_MANAGER, AUTOSYNC_CRON - option 23 takes the installation.s values over, option 2 writes the settings\." <<< "$out" && [ "$(body "$D/$N")" = "$edited" ] && gone "$D/$N" && ! ls "$D/$N".bak-* >/dev/null 2>&1 && untouched'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "one setting edited: 'status' names them, takes nothing over" '! grep -q "new download" <<< "$out" && grep -q "The settings differ from the installation in TZ, INSTALL_NGINX_PROXY_MANAGER, AUTOSYNC_CRON - .*adopt \.. takes the installation.s values over" <<< "$out" && [ "$(body "$D/$N")" = "$edited" ]'
out="$(printf '23\ny\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "one setting edited: option 23 takes the values over, the edit stays" 'grep -q "Took over 3 value(s) of the installation" <<< "$out" && grep -qxF "TZ=\"Europe/Istanbul\"" "$D/$N" && grep -qxF "HEALTH_TIMEOUT=\"900\"" "$D/$N" && untouched'
wizard_installation
sed -i 's/^# General$/# General (checked)/' "$D/$N"; edited="$(body "$D/$N")"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "a hand edit of the settings section that changes no value: not a new download, only named" '! grep -q "new download" <<< "$out" && grep -q "The settings differ from the installation in TZ" <<< "$out" && [ "$(body "$D/$N")" = "$edited" ] && gone "$D/$N"'
# the file cannot be written: said, and the notes as before
if [ "$(id -u)" -ne 0 ]; then
  wizard_installation
  chmod a-w "$D/$N"
  out="$(bash "$D/$N" status </dev/null 2>&1)"
  check "a new download that is not writable: said, nothing taken over, the note as before" 'grep -q "^ here has other values, but the file is not writable: nothing was taken over.$" <<< "$out" && grep -q "The settings differ from the installation in TZ" <<< "$out" && cmp -s "$D/$N" "$PUB" && ! ls "$D/$N".bak-* >/dev/null 2>&1'
  chmod u+w "$D/$N"
else
  echo "SKIP: running as root, for whom every file is writable - the case of a new download that is not writable is not tested here (run the suite as a normal user, for example in the CentOS 7 container of tests/run_in_container.sh)"
fi
# while a job runs it waits for the next start
wizard_installation
sleep 60 & sp=$!
mkdir -p "$D/.jobs/1"; echo "Pull" > "$D/.jobs/1/title"; echo running > "$D/.jobs/1/state"; echo "$sp" > "$D/.jobs/1/pid"
out="$(bash "$D/$N" status </dev/null 2>&1)"
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
check "a new download while a job runs: taken over at the next start" 'grep -q "^ here has other values - taken over at the next start, when no job runs (J).$" <<< "$out" && cmp -s "$D/$N" "$PUB"'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "a new download, the job done: taken over" 'said && table3 && written'
# a self-update of a new download carries its settings over: the old file takes nothing over; they are the
# defaults of the new version too, so that one is a new download and takes the values over at its start
PUB2="$T/published2.sh"
sed 's/Raynet One Technology Catalog - Installation Portal\${C_RST}   (/Raynet One Technology Catalog - Installation Portal${C_RST} v2   (/; s/^HEALTH_TIMEOUT=\(.*\)$/HEALTH_TIMEOUT=\1\nNEW_SETTING="default-of-new-version"/' "$PUB" > "$PUB2"; publish "$PUB2"
wizard_installation
out="$(SHIM_INSTALLER="$PUB2" bash "$D/$N" self-update </dev/null 2>&1)"; rc=$?
check "self-update of a new download: the old file takes nothing over, the new one is a new download too" '[ "$rc" -eq 0 ] && grep -q "Installer updated" <<< "$out" && ! grep -q "new download" <<< "$out" && cmp -s "$D/$N" "$PUB2" && cmp -s "$(ls "$D/$N".bak-*)" "$PUB" && untouched'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "self-update of a new download: the next start takes the installation's values over" 'said && table3 && grep -qxF "TZ=\"Europe/Istanbul\"" "$D/$N" && grep -qxF "NEW_SETTING=\"default-of-new-version\"" "$D/$N" && [ "$(ls "$D/$N".bak-* | wc -l)" -eq 2 ] && untouched'
# the user's installer, a version without the sum (nothing proves its settings are the published ones, so it is
# never a new download): option 22 brings this version, which has no sum either - the note and option 23 as before
wizard_installation
sed -i '/^SETTINGS_PUBLISHED_SUM=/d' "$D/$N"
out="$(printf '22\ny\n\n0\n' | SHIM_INSTALLER="$PUB2" bash "$D/$N" menu 2>&1)"
check "an installer without the sum, option 22: the new version names the values (option 23), takes nothing over by itself" 'grep -q "The settings differ from the installation in TZ, INSTALL_NGINX_PROXY_MANAGER, AUTOSYNC_CRON" <<< "$out" && ! grep -q "new download" <<< "$out" && grep -q "Installation Portal v2" <<< "$out" && gone "$D/$N" && grep -qxF "TZ=\"Europe/Berlin\"" "$D/$N" && untouched'
out="$(printf '23\ny\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "an installer without the sum, option 23 takes the values over as before" 'grep -q "Took over 3 value(s) of the installation" <<< "$out" && grep -qxF "TZ=\"Europe/Istanbul\"" "$D/$N" && untouched'
# a new download of a release whose default is a newer Catalog than the installed 25.4: the versions of the
# containers and the series of the installation taken over (U or option 21 upgrades it with the backup)
export SHIM_TZ="Europe/Berlin"
setup
cp "$PUB" "$D/$N"; env25="$(cksum < "$D/.env")"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "a new download next to Catalog 25.4: the installed versions taken over, nothing raised" 'said && grep -q "^   CATALOG_VERSION  *26.3.4789.148 -> 25.4.4191.133$" <<< "$out" && grep -q "^   OPENSEARCH_TAG  *2 -> 2.19.5$" <<< "$out" && grep -qxF "CATALOG_VERSION=\"25.4.4191.133\"" "$D/$N" && ! grep -q "The settings say" <<< "$out" && grep -q "Catalog 25.4.4191.133 installed$" <<< "$out" && [ "$(cksum < "$D/.env")" = "$env25" ] && nocompose'
# the server state (.env names 25.4, catalog-web runs 26.3) with a new download of a release that had 25.4: the
# values of the backup of that second taken over by themselves, putting the backups back is still asked
export SHIM_TZ="Etc/UTC"
server_state
cp "$FRESH" "$D/$N"; publish "$D/$N"
out="$(printf 'n\n0\n' | bash "$D/$N" menu 2>&1)"
check "server state, new download: the installation's values taken over, the backups not put back after no" 'said && grep -q "^   CATALOG_VERSION  *25.4.4191.133 -> 26.3.4789.148$" <<< "$out" && grep -q "other values come from .env.bak-20261011-123742" <<< "$out" && grep -q "The files stay as they are - option 6 would start Catalog 25.4.4191.133" <<< "$out" && grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N" && grep -qxF "CATALOG_WEB_PORT=\"8181\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$envA" ] && nocompose && ! grep -q "The settings say" <<< "$out" && [ "$(grep -c "belong to it\.$" <<< "$out")" -eq 1 ] && [ "$(grep -c "The files stay as they are - option 6 would start" <<< "$out")" -eq 1 ]'
server_state
cp "$FRESH" "$D/$N"; publish "$D/$N"
out="$(printf 'y\n0\n' | bash "$D/$N" menu 2>&1)"
check "server state, new download: the backups put back after yes" 'said && grep -q ".env and docker-compose.yml name the installed Catalog 26.3.4789.148 again." <<< "$out" && grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$env26" ] && [ "$(cksum < "$D/docker-compose.yml")" = "$compose26" ] && nocompose && ! grep -q -e "The settings say" -e "The files say" <<< "$out"'
server_state
cp "$FRESH" "$D/$N"; publish "$D/$N"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "server state, new download, 'generate': the values taken over, the backups named, then 26.3 written" '[ "$rc" -eq 0 ] && said && grep -q "Menu option 23 puts them back, or .* generate. writes them from the settings, which now fit the installation." <<< "$out" && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148" "$D/.env" && grep -qx "CATALOG_WEB_PORT=8181" "$D/.env" && [ "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env")" = "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env.bak-20261011-123742")" ] && nocompose && ! grep -q "would replace" <<< "$out"'

# 12. One way: only a file that has never been changed is a new download. A value the user (or the installer for
#     the user) puts back to the published one - option 1 and S, the editor, set-version, timezone, by hand -
#     leaves the settings as the published file again, and the next start must not take the installation's
#     value over against that. SETTINGS_PUBLISHED_SUM goes at the first change, and at the first start that
#     finds the section changed or has nothing to take over.
# an installation made by an installer that was edited by hand (setting NAME VALUE ...), then started: it is not
# a new download (its first start flips the sum), the files are as that installer made them
edited_installation() {
  rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$PUB" "$D/$N"
  while [ $# -ge 2 ]; do sed -i "0,/^$1=/s#^$1=.*#$1=\"$2\"#" "$D/$N"; shift 2; done
  # EI_HOOK: files the installation has before it is generated (the login of a proxy, a certificate)
  if [ -n "${EI_HOOK:-}" ]; then eval "$EI_HOOK"; fi
  (cd "$D" && bash "$N" generate </dev/null >/dev/null 2>&1)
  touch "$ST/up"; sed -n 's/^CATALOG_IMAGE=.*://p' "$D/.env" > "$ST/catalog_tag"; echo "8.0.4" > "$ST/mongo_version"
  (cd "$D" && pwd -P) > "$ST/wd"; cp "$D/.env" "$ST/upenv"
  envW="$(cksum < "$D/.env")"; : > "$LOG"
}
setv() { sed -i "0,/^$1=/s#^$1=.*#$1=\"$2\"#" "$D/$N"; }
export SHIM_TZ="Europe/Berlin"
edited_installation CATALOG_WEB_PORT 9393
check "an edited installer: its first start ended the new download for good (the sum is gone)" 'gone "$D/$N" && [ "$(grep "^CATALOG_WEB_PORT=" "$D/.env")" = "CATALOG_WEB_PORT=9393" ]'
out="$(printf '1\nCATALOG_WEB_PORT\n8080\ns\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "option 1 and S: a port set back to the published default stays - the next start takes nothing over" '! grep -q "new download" <<< "$out" && ! grep -qE "Taken over|taken over" <<< "$out" && grep -qxF "CATALOG_WEB_PORT=\"8080\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$envW" ] && grep -q "setting(s) saved" <<< "$out" && [ "$(body "$D/$N")" = "$(body "$PUB")" ] && gone "$D/$N"'
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "...and generate writes it into .env (the settings are what was chosen)" '[ "$rc" -eq 0 ] && ! grep -q "new download" <<< "$out" && grep -qx "CATALOG_WEB_PORT=8080" "$D/.env"'
edited_installation CATALOG_WEB_PORT 9393
setv CATALOG_WEB_PORT 8080
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "a hand edit back to the default, then generate: written, not taken back over" '[ "$rc" -eq 0 ] && ! grep -q "new download" <<< "$out" && grep -qx "CATALOG_WEB_PORT=8080" "$D/.env" && grep -qxF "CATALOG_WEB_PORT=\"8080\"" "$D/$N" && gone "$D/$N"'
edited_installation CATALOG_VERSION 25.4.4191.133
out="$(bash "$D/$N" set-version 26.3.4789.148 </dev/null 2>&1)"
check "set-version to the default of this release: the sum goes with the write, the file equals the published one otherwise" 'grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N" && gone "$D/$N" && [ "$(body "$D/$N")" = "$(body "$PUB")" ]'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "...the next start leaves 26.3 in the settings (the user chose it; U or option 21 upgrades)" '! grep -q "new download" <<< "$out" && grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N" && grep -q "The settings say Catalog 26.3.4789.148, 25.4.4191.133 is installed" <<< "$out"'
edited_installation TZ Etc/UTC AUTOSYNC_CRON "30 5 * * *"
out="$(printf 'y\ny\n' | SHIM_TZ=Europe/Berlin bash "$D/$N" timezone 2>&1)"
check "timezone: TZ and the job times are the published ones afterwards (the sum is gone)" 'grep -q "TZ is now Europe/Berlin" <<< "$out" && [ "$(body "$D/$N")" = "$(body "$PUB")" ] && gone "$D/$N"'
out="$(SHIM_TZ=Europe/Berlin bash "$D/$N" status </dev/null 2>&1)"
check "...the next start does not take Etc/UTC back over" '! grep -q "new download" <<< "$out" && grep -qxF "TZ=\"Europe/Berlin\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$envW" ]'
# Nginx Proxy Manager: taken over from a new download, then switched on again in option 1
edited_installation INSTALL_NGINX_PROXY_MANAGER false
cp "$PUB" "$D/$N"
out="$(printf '0\n' | bash "$D/$N" menu 2>&1)"
check "a new download takes INSTALL_NGINX_PROXY_MANAGER false over, and the sum is gone" 'grep -q "^   INSTALL_NGINX_PROXY_MANAGER  *true -> false$" <<< "$out" && gone "$D/$N"'
out="$(printf '1\nINSTALL_NGINX_PROXY_MANAGER\ny\ns\n\n0\n' | bash "$D/$N" menu 2>&1)"
check "option 1 and S switches Nginx Proxy Manager on (the default): it stays on at the restart" '! grep -q "new download" <<< "$out" && grep -qxF "INSTALL_NGINX_PROXY_MANAGER=\"true\"" "$D/$N" && grep -q "setting(s) saved" <<< "$out" && ! grep -q "true -> false" <<< "$out"'
# the editor (E in option 1)
wizard_installation
printf '#!/usr/bin/env bash\nf="${@: -1}"; sed -i "0,/^INSTALL_NGINX_PROXY_MANAGER=/s/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER=\\"true\\"/" "$f"\n' > "$T/bin/ed-npm"; chmod +x "$T/bin/ed-npm"
sed -i '0,/^INSTALL_NGINX_PROXY_MANAGER=/s/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/' "$D/$N"
out="$(printf '1\ne\n\n0\n' | EDITOR=ed-npm bash "$D/$N" menu 2>&1)"
check "the editor puts a value back to the default: the restart takes nothing over" '! grep -q "new download" <<< "$out" && grep -q "Configuration reloaded" <<< "$out" && grep -qxF "INSTALL_NGINX_PROXY_MANAGER=\"true\"" "$D/$N" && gone "$D/$N" && [ "$(cksum < "$D/.env")" = "$envW" ]'
# the editor changed the file of a new download that had nothing to take over yet (no .env): whatever it changed,
# the file is chosen now (here a comment outside the settings, so the section still has its published cksum)
rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$PUB" "$D/$N"
printf '#!/usr/bin/env bash\nf="${@: -1}"; sed -i "s/^# Installers from before the rename/# Installers from before the Rename/" "$f"\n' > "$T/bin/ed-outside"; chmod +x "$T/bin/ed-outside"
out="$(printf '1\ne\n\n0\n' | EDITOR=ed-outside bash "$D/$N" menu 2>&1)"
check "the editor changed the file of a new download: the sum is gone, also when the settings are still the published ones" 'grep -q "Configuration reloaded" <<< "$out" && grep -q "^# Installers from before the Rename" "$D/$N" && [ "$(bash "$D/$N" __settings_hash)" = "$(bash "$PUB" __settings_hash)" ] && gone "$D/$N"'
# a hand edit of a new download, then undone before anything else ran: the first start has already seen it
wizard_installation
setv HEALTH_TIMEOUT 900
out="$(bash "$D/$N" credentials </dev/null 2>&1)"
check "a hand edit of a new download: the first start ends the state (named, not taken over)" '! grep -q "new download" <<< "$out" && gone "$D/$N"'
setv HEALTH_TIMEOUT 600
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "...and undoing the edit does not bring it back" '! grep -q "new download" <<< "$out" && grep -qxF "TZ=\"Europe/Berlin\"" "$D/$N" && [ "$(body "$D/$N")" = "$(body "$PUB")" ]'
# nothing to take over: the first start ends the state, every later start skips the check
rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$PUB" "$D/$N"
(cd "$D" && bash "$N" generate </dev/null >/dev/null 2>&1)
touch "$ST/up"; sed -n 's/^CATALOG_IMAGE=.*://p' "$D/.env" > "$ST/catalog_tag"; echo "8.0.4" > "$ST/mongo_version"; (cd "$D" && pwd -P) > "$ST/wd"; cp "$D/.env" "$ST/upenv"
check "a new download in front of an installation with its defaults: still a new download before the start" '! gone "$D/$N" && [ "$(bash "$D/$N" __settings_hash)" = "$(sumline "$D/$N" | tr -d \")" ]'
: > "$LOG"; out="$(bash "$D/$N" status </dev/null 2>&1)"; first="$(grep -c . "$LOG")"
check "...nothing differs: said nothing, and the sum is gone" '! grep -q "new download" <<< "$out" && gone "$D/$N" && ! ls "$D/$N".bak-* >/dev/null 2>&1'
: > "$LOG"; out="$(bash "$D/$N" status </dev/null 2>&1)"
check "...the next start does not look for the installation's values again (fewer engine calls)" '[ "$(grep -c . "$LOG")" -lt "$first" ]'

# 13. The engine does not answer at the start (stopped, the Podman machine down): it shows no containers, so the
#     installed versions are unknown and .env alone is not the installation - nothing is taken over, the notes
#     stay as they are, and the next start (the engine back) takes the values over
export SHIM_TZ="Etc/UTC"
server_state
cp "$PUB" "$D/$N"
mkdir -p "$T/down"; printf '#!/usr/bin/env bash\necho "Cannot connect to Podman" >&2\nexit 125\n' > "$T/down/podman"; chmod +x "$T/down/podman"
out="$(PATH="$T/down:$PATH" bash "$D/$N" status </dev/null 2>&1)"
check "the engine does not answer: nothing is taken over from .env alone, the file stays a new download" '! grep -q "new download" <<< "$out" && cmp -s "$D/$N" "$PUB" && [ "$(cksum < "$D/.env")" = "$envA" ]'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "...the engine back: the next start takes the values over, the versions from the containers (26.3, not .env's 25.4)" 'said && grep -q "^   CATALOG_WEB_PORT  *8080 -> 8181$" <<< "$out" && ! grep -q "^   CATALOG_VERSION" <<< "$out" && grep -qxF "CATALOG_WEB_PORT=\"8181\"" "$D/$N" && grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$D/$N"'

# 14. A leftover installation is no installation: after option 99 (or R) .env and docker-compose.yml are still
#     there, but no container and no data volume - the installer a new download then makes starts a new
#     installation with its own defaults (the newest Catalog), it takes nothing over. The data volumes alone
#     (containers removed, option 13) are an installation. And .env and the compose file must be a Catalog's.
export SHIM_TZ="Europe/Berlin"
setup
cp "$PUB" "$D/$N"
rm -f "$ST/up" "$ST/exited" "$ST/wd"
: > "$LOG"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "after a reset (files left, no container, no data volume): a new download takes nothing over" '! grep -q "new download" <<< "$out" && cmp -s "$D/$N" "$PUB" && ! ls "$D/$N".bak-* >/dev/null 2>&1'
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "...and 'generate' writes the newest Catalog of the download, not the removed 25.4" '[ "$rc" -eq 0 ] && grep -qx "CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148" "$D/.env" && ! grep -q "25.4.4191.133" "$D/.env"'
setup
cp "$PUB" "$D/$N"
rm -f "$ST/up" "$ST/exited"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "containers removed, the data volumes kept (option 13): an installation - the versions of .env taken over" 'said && grep -q "^   CATALOG_VERSION  *26.3.4789.148 -> 25.4.4191.133$" <<< "$out" && grep -qxF "CATALOG_VERSION=\"25.4.4191.133\"" "$D/$N"'
setup
cp "$PUB" "$D/$N"
printf 'COMPOSE_PROJECT_NAME=wiki\nTZ=UTC\nLOG_LEVEL_DEFAULT=Debug\nQUEUE_PREFIX=wikiq\nDB_PASSWORD=secret\n' > "$D/.env"
printf 'services:\n  wiki:\n    image: ghcr.io/example/wiki:2.5\n    env_file: .env\n' > "$D/docker-compose.yml"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "another application's .env and compose file next to volumes of this project: not a Catalog's, nothing taken over" '! grep -q "new download" <<< "$out" && cmp -s "$D/$N" "$PUB" && ! grep -q "^COMPOSE_PROJECT_NAME=\"wiki\"" "$D/$N"'

# 15. .env names another Catalog than the one that runs, and no backup of .env names the one that runs (one generate
#     so far, then .env edited by hand): only the versions of the containers would be known. Nothing is taken over -
#     the new download behaves as it did without the take-over: the note, option 23, and a generate that writes
#     nothing (it would put the defaults over every other value of .env)
export SHIM_TZ="Europe/Berlin"
edited_installation CATALOG_VERSION 25.4.4191.133 CATALOG_WEB_PORT 9393 TZ Europe/Istanbul
sed -i 's/^CATALOG_IMAGE=\(.*\):.*/CATALOG_IMAGE=\1:26.3.4789.148/; s/^CATALOG_WORKER_IMAGE=\(.*\):.*/CATALOG_WORKER_IMAGE=\1:26.3.4789.148/' "$D/.env"
envD="$(cksum < "$D/.env")"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "no backup of .env names the installed Catalog: nothing taken over, generate writes nothing (rc 1, as before the take-over)" '[ "$rc" -eq 1 ] && ! said && grep -q "Nothing was written" <<< "$out" && [ "$(cksum < "$D/.env")" = "$envD" ] && [ "$(body "$D/$N")" = "$(body "$PUB")" ] && ! ls "$D/$N".bak-* >/dev/null 2>&1'
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "...the state is over for good (no check at the next start) and the note names the way out" '! said && gone "$D/$N" && grep -q "The files say Catalog 26.3.4789.148, 25.4.4191.133 is installed" <<< "$out"'

# 16. .env saved with Windows line endings (CRLF): its values are read as they are written. The Catalog it names is
#     the one that runs, so it - not an older backup of it - is where the other values come from
installation26
sed 's/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT=7070/; s#^TZ=.*#TZ=Asia/Tokyo#' "$D/.env" > "$D/.env.bak-20260101-000000"
sed -i 's/$/\r/' "$D/.env"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "CRLF in .env: the take-over reads .env, not an older backup that happens to name the same Catalog" 'said && grep -q "^   CATALOG_WEB_PORT  *8080 -> 8181$" <<< "$out" && ! grep -q -e "7070" -e "Asia/Tokyo" -e "newest backup" <<< "$out" && grep -qxF "CATALOG_WEB_PORT=\"8181\"" "$D/$N" && grep -qxF "TZ=\"Etc/UTC\"" "$D/$N"'

# 17. A take-over that cannot be done is said once and not tried again: a value of .env that makes the settings fail
#     together (the port of catalog-web 9001 is MinIO's too) rolls everything back - no backup of the installer is
#     left, the state of a new download is over, the notes stay. A value that does not fit its own setting (yes for
#     a true/false) is named and skipped; the others are taken over.
edited_installation TZ Europe/Istanbul
sed -i 's/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT=9001/' "$D/.env"
envG="$(cksum < "$D/.env")"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "values that do not work together: said, nothing taken over, no backup of the installer left" 'grep -q "used by more than one setting" <<< "$out" && grep -q "nothing was taken over" <<< "$out" && ! grep -q "Taken over" <<< "$out" && [ "$(body "$D/$N")" = "$(body "$PUB")" ] && ! ls "$D/$N".bak-* >/dev/null 2>&1 && [ "$(cksum < "$D/.env")" = "$envG" ]'
check "...and the state of a new download is over (no second try)" 'gone "$D/$N"'
sleep 1
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "...the next start repeats nothing and leaves no backup; the note names the values" '! grep -q -e "new download" -e "used by more than one setting" <<< "$out" && ! ls "$D/$N".bak-* >/dev/null 2>&1 && grep -q "The settings differ from the installation in" <<< "$out"'
edited_installation TZ Europe/Istanbul
sed -i 's/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER=yes/' "$D/.env"
envG="$(cksum < "$D/.env")"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "a value that does not fit its setting (yes): named and skipped, the others taken over - and 'taken over' only after it worked" 'said && grep -q "^   TZ  *Europe/Berlin -> Europe/Istanbul$" <<< "$out" && ! grep -q "^   INSTALL_NGINX_PROXY_MANAGER" <<< "$out" && grep -q "Not taken over:.*INSTALL_NGINX_PROXY_MANAGER" <<< "$out" && grep -qxF "TZ=\"Europe/Istanbul\"" "$D/$N" && grep -qxF "INSTALL_NGINX_PROXY_MANAGER=\"true\"" "$D/$N" && [ "$(cksum < "$D/.env")" = "$envG" ]'

# 18. The internet proxy, the company certificate and the cache of MongoDB: .env holds them as RN1_HTTPS_PROXY,
#     RN1_NO_PROXY, the bundle in the compose file and MONGO_WT_CACHE_GB - none of them the name of a setting - so
#     they are taken over too (the login stays in .proxy_login, never in the script), else the next generate drops
#     them. What cannot be taken over safely is named.
export SHIM_TZ="Europe/Berlin"
proxy_lines() { grep -c '^RN1_.*PROXY=' "$D/.env"; }
compose_proxy() { grep -c 'HTTPS_PROXY: "${RN1_HTTPS_PROXY}"' "$D/docker-compose.yml"; }
edited_installation INTERNET_PROXY "http://proxy.example.com:3128" INTERNET_NO_PROXY "corp.example.com" TZ Europe/Istanbul
check "the installation goes out through a proxy (3 lines in .env, catalog-web and Nginx Proxy Manager in the compose file)" '[ "$(proxy_lines)" -eq 3 ] && [ "$(compose_proxy)" -eq 2 ]'
envP="$(grep '^RN1_' "$D/.env" | cksum)"; composeP="$(cksum < "$D/docker-compose.yml")"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "proxy: taken over with its internal names, shown in the table" 'said && grep -q "^   INTERNET_PROXY  *(empty) -> http://proxy.example.com:3128$" <<< "$out" && grep -q "^   INTERNET_NO_PROXY  *(empty) -> corp.example.com$" <<< "$out" && grep -qxF "INTERNET_PROXY=\"http://proxy.example.com:3128\"" "$D/$N" && grep -qxF "INTERNET_NO_PROXY=\"corp.example.com\"" "$D/$N"'
check "...and the next generate writes the same proxy into .env and the compose file" '[ "$rc" -eq 0 ] && [ "$(proxy_lines)" -eq 3 ] && [ "$(compose_proxy)" -eq 2 ] && [ "$(grep "^RN1_" "$D/.env" | cksum)" = "$envP" ] && [ "$(cksum < "$D/docker-compose.yml")" = "$composeP" ]'
# the login of the proxy: in .env and .proxy_login, never in the script
EI_HOOK='printf "proxy=http://proxy.example.com:3128\nuser:p%%40ss\n" > "$D/.proxy_login"; chmod 600 "$D/.proxy_login"'
edited_installation INTERNET_PROXY "http://proxy.example.com:3128" TZ Europe/Istanbul
EI_HOOK=""
loginP="$(cksum < "$D/.proxy_login")"; envP="$(grep '^RN1_' "$D/.env" | cksum)"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "proxy with a login: the address taken over, the login not (not in the script, its backups, the table)" '[ "$rc" -eq 0 ] && grep -q "^   INTERNET_PROXY  *(empty) -> http://proxy.example.com:3128$" <<< "$out" && grep -q "user:p%40ss" "$D/.env" && ! grep -qF -e "p%40ss" -e "p@ss" "$D/$N" "$D/$N".bak-* && ! grep -qF -e "p%40ss" -e "p@ss" <<< "$out"'
check "...the login file stays as it was (mode 600) and the next generate writes the same login into .env" '[ "$(cksum < "$D/.proxy_login")" = "$loginP" ] && [ "$(stat -c %a "$D/.proxy_login")" = 600 ] && [ "$(grep "^RN1_" "$D/.env" | cksum)" = "$envP" ]'
rm -f "$D/.proxy_login"; cp "$PUB" "$D/$N"; rm -f "$D/$N".bak-*
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "...a lost .proxy_login is written again from .env (mode 600), the script still has no login" '[ "$rc" -eq 0 ] && [ "$(cksum < "$D/.proxy_login")" = "$loginP" ] && [ "$(stat -c %a "$D/.proxy_login")" = 600 ] && grep -q "Its proxy login is kept in .proxy_login (mode 600)" <<< "$out" && ! grep -qF -e "p%40ss" -e "p@ss" "$D/$N" "$D/$N".bak-* && [ "$(grep "^RN1_" "$D/.env" | cksum)" = "$envP" ]'
# the company certificate
EI_HOOK='printf -- "-----BEGIN CERTIFICATE-----\nMIIBtest\n-----END CERTIFICATE-----\n" > "$D/proxy-ca.pem"'
edited_installation INTERNET_PROXY "http://proxy.example.com:3128" INTERNET_PROXY_CA_FILE "$D/proxy-ca.pem" TZ Europe/Istanbul
EI_HOOK=""
composeP="$(cksum < "$D/docker-compose.yml")"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "company certificate: INTERNET_PROXY_CA_FILE taken over, the compose file keeps its mount" '[ "$rc" -eq 0 ] && grep -q "^   INTERNET_PROXY_CA_FILE  *(empty) -> $D/proxy-ca.pem$" <<< "$out" && grep -qxF "INTERNET_PROXY_CA_FILE=\"$D/proxy-ca.pem\"" "$D/$N" && grep -q "proxy-ca-bundle.pem" "$D/docker-compose.yml" && [ "$(cksum < "$D/docker-compose.yml")" = "$composeP" ]'
# the cache of MongoDB
edited_installation MONGO_CACHE_GB 4
check "the installation has a cache of 4 GB (the automatic one is 11 GB for the 32 GB of the fake engine)" 'grep -qx "MONGO_WT_CACHE_GB=4" "$D/.env"'
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" generate </dev/null 2>&1)"; rc=$?
check "cache of MongoDB: a value that is not the automatic one is taken over as MONGO_CACHE_GB, and generate keeps it" '[ "$rc" -eq 0 ] && grep -q "^   MONGO_CACHE_GB  *(empty) -> 4$" <<< "$out" && grep -qxF "MONGO_CACHE_GB=\"4\"" "$D/$N" && grep -qx "MONGO_WT_CACHE_GB=4" "$D/.env"'
edited_installation TZ Europe/Istanbul
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "...the automatic cache (11 GB) is no setting: not taken over" 'said && ! grep -q "MONGO_CACHE_GB" <<< "$out" && grep -qxF "MONGO_CACHE_GB=\"\"" "$D/$N"'
# what cannot be taken over is named
edited_installation TZ Europe/Istanbul
printf "RN1_HTTPS_PROXY='ftp://proxy.example.com:21'\n" >> "$D/.env"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "a proxy address that is none (ftp://): named as not taken over, the rest taken over" 'said && grep -q "^   TZ  *Europe/Berlin -> Europe/Istanbul$" <<< "$out" && grep -q "Not taken over: INTERNET_PROXY \"ftp://proxy.example.com:21\" - not a proxy address with a port" <<< "$out" && grep -qxF "INTERNET_PROXY=\"\"" "$D/$N"'
edited_installation
printf "RN1_HTTPS_PROXY='socks4://proxy.example.com:1080'\n" >> "$D/.env"
cp "$PUB" "$D/$N"
out="$(bash "$D/$N" status </dev/null 2>&1)"
check "...when nothing else differs it is said as well, and the state of a new download is over" 'grep -q "^ here has other values, but none of them could be taken over:$" <<< "$out" && grep -q "Not taken over: INTERNET_PROXY \"socks4://proxy.example.com:1080\"" <<< "$out" && gone "$D/$N" && ! ls "$D/$N".bak-* >/dev/null 2>&1'

# 19. The report of the automatic take-over goes to stderr for every command (what they print on stdout is read by
#     scripts and written to files); in the menu it is part of the screen. The pause before the menu is only
#     for a terminal: on a pipe it would take a line of input the menu is meant to read.
export SHIM_TZ="Europe/Istanbul"
for c in credentials info versions; do
  wizard_installation
  bash "$D/$N" $c </dev/null > "$T/$c.out" 2> "$T/$c.err"
  check "$c: the report is on stderr, stdout starts with the command's own output" 'grep -q "^ This installer is a new download with its default settings; the installation$" "$T/$c.err" && grep -q "^   TZ  *Europe/Berlin -> Europe/Istanbul$" "$T/$c.err" && ! grep -q -e "new download" -e " -> " "$T/$c.out" && [ -s "$T/$c.out" ] && written'
done
wizard_installation
out="$(printf 'x\n0\n' | bash "$D/$N" menu 2>&1)"
check "menu on a pipe: no pause, so the first line of input is the menu's (Unknown option: x)" 'said && grep -q "Unknown option: x" <<< "$out" && ! grep -q "Press Enter to open the menu" <<< "$out"'

# 21. The pause before the menu exists only in a terminal (a pipe has no prompt to show), so a test in a terminal is the
#     one that sees it: shown after the take-over said something, absent when nothing differs
default_installation() {
  rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$PUB" "$D/$N"
  (cd "$D" && bash "$N" generate </dev/null >/dev/null 2>&1)
  touch "$ST/up"; sed -n 's/^CATALOG_IMAGE=.*://p' "$D/.env" > "$ST/catalog_tag"; echo "8.0.4" > "$ST/mongo_version"
  (cd "$D" && pwd -P) > "$ST/wd"; cp "$D/.env" "$ST/upenv"; : > "$LOG"
}
if command -v script >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  # tty_run COMMAND [PATTERN KEYS]... -> runs COMMAND in a pseudo-terminal in $D: waits for each PATTERN in what the
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
  wizard_installation
  out="$(tty_run "bash $N" "Press Enter to open the menu" '\n' "Select an option" '0\n')"
  check "terminal: the take-over is shown, then the pause, then the menu" 'said && table3 && grep -q "Press Enter to open the menu\.\.\." <<< "$out" && [ "$(line "This installer is a new download")" -lt "$(line "Press Enter to open the menu")" ] && [ "$(line "Press Enter to open the menu")" -lt "$(line "Select an option")" ] && grep -q TTY-END <<< "$out"'
  default_installation
  out="$(tty_run "bash $N" "Select an option" '0\n')"
  check "terminal: nothing to take over - no pause, the menu opens at once" '! said && ! grep -q "Press Enter to open the menu" <<< "$out" && grep -q "Select an option" <<< "$out" && grep -q TTY-END <<< "$out"'
else
  echo "SKIP: script (util-linux) missing - no terminal test of the pause before the menu"
fi

check "no Podman, Compose or systemctl call the fakes do not know" '[ ! -s "$UNH" ] || { cat "$UNH"; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
