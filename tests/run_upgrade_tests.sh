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

cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
running() { [ -f "$ST/up" ]; }
case "$1" in
  info) exit 0 ;;
  inspect)
    fmt="$3"; id="$4"; svc="${id#id-}"
    case "$fmt" in
      *Config.Image*) echo "raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag")" ;;
      *State.Status*)
        if [ "$svc" = catalog-web ] && [ "${SHIM_UNHEALTHY:-}" = 1 ]; then echo "restarting none 3"
        elif [ "$svc" = rabbitmq ]; then echo "running healthy 0"
        else echo "running none 0"; fi ;;
    esac
    exit 0 ;;
  compose)
    shift
    while [ $# -gt 0 ]; do case "$1" in --env-file|-f) shift 2 ;; *) break ;; esac; done
    sub="$1"; shift
    case "$sub" in
      version) echo "Docker Compose version v2.29.0" ;;
      config)
        if [ "${1:-}" = --services ]; then printf '%s\n' nginx-proxy-manager opensearch opensearch-dashboards mongo minio rabbitmq catalog-web worker-recognition-1 worker-recognition-2 worker-other worker-search; fi ;;
      ps) if [ "${1:-}" = -q ]; then running && echo "id-$2"; else echo "NAME STATUS"; fi ;;
      pull) [ -n "${SHIM_SLOW_PULL:-}" ] && sleep 8; echo "pull $*" >> "$ST/pulls" ;;
      down) rm -f "$ST/up" ;;
      up)
        touch "$ST/up"
        sed -n 's/^CATALOG_IMAGE=.*://p' .env > "$ST/catalog_tag"
        m="$(sed -n 's/^MONGO_TAG=//p' .env)"; [[ "$m" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$m" > "$ST/mongo_version" ;;
      exec)
        if [ "$3" = mongod ]; then echo "db version v$(cat "$ST/mongo_version")"
        elif [ "$3" = sh ]; then [ "${SHIM_BACKUP_FAIL:-}" = 1 ] && exit 1; printf 'MONGODUMP-ARCHIVE'; fi ;;
      logs) echo "catalog-web | fake log line" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

setup() {
  rm -rf "$T/inst" "$ST"/*; mkdir -p "$T/inst"; cp "$NEW" "$T/inst/catalog.sh"
  sed -i '0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG="2.19.5"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG="2.19.5"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG="3.13.6-management-alpine"/; 0,/^NGINX_PROXY_MANAGER_TAG=/s/^NGINX_PROXY_MANAGER_TAG=.*/NGINX_PROXY_MANAGER_TAG="2.16.0"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="10"/' "$T/inst/catalog.sh"
  (cd "$T/inst" && bash catalog.sh generate </dev/null >/dev/null 2>&1)
  touch "$ST/up"; echo "25.4.4191.133" > "$ST/catalog_tag"; echo "8.0.4" > "$ST/mongo_version"
  : > "$LOG"
}
D="$T/inst"

# 1. Full guided upgrade with backup, then patch updates without OpenSearch
setup
p1="$(grep '^MONGO_INITDB_ROOT_PASSWORD=' "$D/.env")"
out="$(printf '21\ny\ny\n1\n\n\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "detects installed 25.4 and newest 26.3 (stable)" 'grep -q "Installed Catalog: 25.4.4191.133" <<< "$out" && grep -q "Newest Catalog:    26.3.4789.148 (stable)" <<< "$out"'
check "backup written with the archive" 'f="$(ls "$D"/backups/mongo-*.archive.gz 2>/dev/null | head -n1)"; [ -n "$f" ] && [ "$(cat "$f")" = MONGODUMP-ARCHIVE ]'
check "images pulled before down" '[ "$(grep -n "compose.* pull catalog-web" "$LOG" | head -n1 | cut -d: -f1)" -lt "$(grep -n "compose.* down" "$LOG" | head -n1 | cut -d: -f1)" ]'
check "down, then up" 'grep -q "compose.* down --remove-orphans" "$LOG" && grep -q "compose.* up -d --remove-orphans" "$LOG"'
check "CATALOG_VERSION and .env switched to 26.3" 'grep -q "^CATALOG_VERSION=\"26.3.4789.148\"$" "$D/catalog.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148$" "$D/.env" && grep -q "^CATALOG_WORKER_IMAGE=raynetgmbh/rayventory-catalog-worker:26.3.4789.148$" "$D/.env"'
check "passwords kept" '[ "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env")" = "$p1" ]'
check "health check passed and upgrade reported" 'grep -q "All 11 services run and Catalog Web answers" <<< "$out" && grep -q "Catalog upgraded: 25.4.4191.133 -> 26.3.4789.148." <<< "$out"'
check "patch updates offered (MongoDB, OpenSearch, RabbitMQ)" 'grep -q "MongoDB .*8.0.4 -> 8.0.32" <<< "$out" && grep -q "OpenSearch + Dashboards .*2.19.5 -> 2.19.6" <<< "$out" && grep -q "RabbitMQ .*3.13.6 -> 3.13.7" <<< "$out"'
check "no major or cross-series offer (no 9.0.2 / 3.9.0 / 4.3.6)" '! grep -E -- "-> (9\.0\.2|3\.9\.0|4\.3\.6)" <<< "$out"'
check "selected patches applied, OpenSearch left out" 'grep -q "^MONGO_TAG=\"8.0.32\"$" "$D/catalog.sh" && grep -q "^RABBITMQ_TAG=\"3.13.7-management-alpine\"$" "$D/catalog.sh" && grep -q "^OPENSEARCH_TAG=\"2.19.5\"$" "$D/catalog.sh"'
check "MongoDB runs the new patch after up" '[ "$(cat "$ST/mongo_version")" = 8.0.32 ]'

# 2. Already up to date -> only patch check
out="$(printf '21\n0\n\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "up to date: no down, patch list only" 'grep -q "The Catalog is up to date." <<< "$out" && ! grep -q "Upgrade plan" <<< "$out"'

# 3. Unhealthy after up -> rollback to the old version, restore hint
setup
out="$(printf '21\ny\ny\ny\n\n0\n' | SHIM_UNHEALTHY=1 bash "$D/catalog.sh" menu 2>&1)"
check "unhealthy upgrade detected" 'grep -q "Not healthy after" <<< "$out" && grep -q "is not healthy" <<< "$out" && grep -q "catalog-web(restarting/none)" <<< "$out"'
check "rolled back to 25.4" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/catalog.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133$" "$D/.env"'
check "restore hint printed with the backup file" 'grep -q "mongorestore --drop --archive --gzip" <<< "$out" && grep -q "backups/mongo-" <<< "$out"'
check "logs shown on failure" 'grep -q "fake log line" <<< "$out"'

# 4. Upgrade declined -> nothing changed
setup
out="$(printf '21\nn\n\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "declined: no change, no down" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/catalog.sh" && ! grep -q "compose.* down" "$LOG"'

# 5. Backup fails -> user stops -> nothing changed
setup
out="$(printf '21\ny\ny\nn\n\n0\n' | SHIM_BACKUP_FAIL=1 bash "$D/catalog.sh" menu 2>&1)"
check "failed backup stops the upgrade on request" 'grep -q "The MongoDB backup failed." <<< "$out" && ! grep -q "compose.* down" "$LOG" && ! ls "$D"/backups/*.gz >/dev/null 2>&1'

# 6. Password never on the host command line during backup
check "backup password stays inside the container" '! grep -q "MONGO_INITDB_ROOT_PASSWORD=[A-Za-z0-9]" "$LOG"'

# 7. Cancel while the new images are pulled: settings back, the stack keeps running
setup
( printf '21\ny\nn\n\n0\n' | SHIM_SLOW_PULL=1 bash "$D/catalog.sh" menu > "$T/cancel1.out" 2>&1 ) &
mp=$!
for i in $(seq 1 150); do grep -q "Pulling the images" "$D/.jobs/1/progress" 2>/dev/null && break; sleep 0.2; done
sleep 0.5
out="$(cd "$D" && bash catalog.sh jobs cancel 1 2>&1)"
wait "$mp"
check "cancel while pulling: job cancelled" '[ "$(cat "$D/.jobs/1/state")" = cancelled ] && grep -q "Job #1 cancelled" <<< "$out"'
check "cancel while pulling: version and .env back, no down" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/catalog.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133$" "$D/.env" && ! grep -q "compose.* down" "$LOG" && [ -f "$ST/up" ]'

# 8. Cancel during the health check after the switch: back to the old version
setup
( printf '21\ny\nn\n\n0\n' | SHIM_UNHEALTHY=1 bash "$D/catalog.sh" menu > "$T/cancel2.out" 2>&1 ) &
mp=$!
for i in $(seq 1 150); do grep -q "Health check" "$D/.jobs/1/progress" 2>/dev/null && break; sleep 0.2; done
out="$(cd "$D" && bash catalog.sh jobs cancel 1 2>&1)"
wait "$mp"
check "cancel during the switch: job cancelled" '[ "$(cat "$D/.jobs/1/state")" = cancelled ]'
check "cancel during the switch: 25.4 runs again" 'grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/catalog.sh" && grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:25.4.4191.133$" "$D/.env" && [ "$(cat "$ST/catalog_tag")" = 25.4.4191.133 ] && grep -q "going back to Catalog 25.4.4191.133" "$D/.jobs/1/log"'
check "no rollback question after a cancel" '! grep -q "Go back to" "$T/cancel2.out" && [ ! -e "$D/.upgrade-failed" ]'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
