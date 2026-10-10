#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/u"
rm -rf "$T"; mkdir -p "$T/bin" "$T/state"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
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
code=200; body=""
case "$url" in
  http://localhost:*/) [ "${SHIM_WEB_DOWN:-}" = 1 ] && code=502 ;;
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
# "id-SERVICE" while $ST/up exists, $ST/wd is the folder the stack was created in. Calls it does
# not know are logged to $UNH and fail with 125.
export UNH="$T/unhandled.log" RN1_COMPOSE_PROVIDER="$T/cli-plugins/docker-compose"
: > "$UNH"
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$LOG"
SVCS="nginx-proxy-manager opensearch opensearch-dashboards mongo minio rabbitmq catalog-web worker-recognition-1 worker-recognition-2 worker-other worker-search"
running() { [ -f "$ST/up" ]; }
bad() { printf 'UNHANDLED podman %s\n' "$*" >> "$UNH"; echo "fake podman: not handled: $*" >&2; exit 125; }
nosuch() { echo "Error: no container with name or ID \"$1\" found: no such container" >&2; exit 125; }
inspect_one() {
  local id="$2" svc="${2#id-}"
  { running && [ "$svc" != "$id" ] && [[ " $SVCS " == *" $svc "* ]]; } || nosuch "$id"
  case "$1" in
    '{{.Config.Image}}')
      [ "$svc" = catalog-web ] || bad container inspect --format "$1" "$id"
      echo "docker.io/raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag")" ;;
    '{{.State.Status}}|{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}|{{.RestartCount}}')
      if [ "$svc" = catalog-web ] && [ "${SHIM_UNHEALTHY:-}" = 1 ]; then echo "restarting|none|3"
      elif [ "$svc" = rabbitmq ]; then echo "running|healthy|0"
      else echo "running|none|0"; fi ;;
    '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{index .Config.Labels "com.docker.compose.project.environment_file"}}|{{.Config.Image}}|{{.State.Status}}')
      [ "$svc" = catalog-web ] || bad container inspect --format "$1" "$id"
      w="$(cat "$ST/wd")"
      echo "inst|$w|$w/docker-compose.yml|$w/.env|docker.io/raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag")|running" ;;
    *) bad container inspect --format "$1" "$id" ;;
  esac
}
case "${1:-}" in
  --version) [ $# -eq 1 ] || bad "$@"; echo "podman version ${SHIM_PODMAN_VERSION:-5.7.0}" ;;
  info)
    if [ $# -eq 1 ]; then exit 0; fi
    [ "$*" = "info --format {{.Host.Security.Rootless}}" ] || bad "$@"
    echo false ;;
  volume)
    # the data volumes exist once the stack was created ($ST/wd); "down" keeps them
    [ "$*" = "volume ls -q --filter label=com.docker.compose.project=inst" ] || bad "$@"
    if [ -f "$ST/wd" ]; then
      for v in db_data db_config worker1_token worker2_token worker_token worker_search_token rmq_data rmq_log minio_storage catalog_license opensearch_data npm_data npm_letsencrypt; do echo "inst_$v"; done
    fi ;;
  ps)
    case "$*" in
      "ps -aq --filter label=com.docker.compose.service=catalog-web") running && echo id-catalog-web ;;
      "ps -aq --filter label=com.docker.compose.project=inst") if running; then for s in $SVCS; do echo "id-$s"; done; fi ;;
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
        elif [ $# -eq 0 ]; then echo "NAME STATUS"
        elif [ "$*" = "--services --filter status=running" ]; then if running; then printf '%s\n' $SVCS; fi
        else bad compose ps "$@"; fi ;;
      pull) [ -n "${SHIM_SLOW_PULL:-}" ] && sleep 8; echo "pull $*" >> "$ST/pulls" ;;
      down) [ "$*" = "--remove-orphans" ] || bad compose down "$@"; rm -f "$ST/up" ;;
      up)
        [ "$*" = "-d --remove-orphans" ] || bad compose up "$@"
        touch "$ST/up"; pwd -P > "$ST/wd"
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

setup() {
  rm -rf "$T/inst" "$ST"/*; mkdir -p "$T/inst"; cp "$NEW" "$T/inst/rn1-technology-catalog-installer.sh"
  sed -i '0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG="2.19.5"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG="2.19.5"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG="3.13.6-management-alpine"/; 0,/^NGINX_PROXY_MANAGER_TAG=/s/^NGINX_PROXY_MANAGER_TAG=.*/NGINX_PROXY_MANAGER_TAG="2.16.0"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="10"/' "$T/inst/rn1-technology-catalog-installer.sh"
  (cd "$T/inst" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  touch "$ST/up"; echo "25.4.4191.133" > "$ST/catalog_tag"; echo "8.0.4" > "$ST/mongo_version"; (cd "$T/inst" && pwd -P) > "$ST/wd"
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
out="$(cd "$D" && bash rn1-technology-catalog-installer.sh jobs cancel 1 2>&1)"
wait "$mp"
check "cancel during the switch: job cancelled" '[ "$(cat "$D/.jobs/1/state")" = cancelled ]'
check "cancel during the switch: 25.4 runs again" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133$" "$D/.env" && [ "$(cat "$ST/catalog_tag")" = 25.4.4191.133 ] && grep -q "going back to Catalog 25.4.4191.133" "$D/.jobs/1/log"'
check "no rollback question after a cancel" '! grep -q "Go back to" "$T/cancel2.out" && [ ! -e "$D/.upgrade-failed" ]'

check "no Podman, Compose or systemctl call the fakes do not know" '[ ! -s "$UNH" ] || { cat "$UNH"; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
