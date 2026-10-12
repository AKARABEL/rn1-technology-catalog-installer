#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/v"
rm -rf "$T"; mkdir -p "$T/bin" "$T/state"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# the internet check (menu start, new installation, option 16, engine setup) has its own suite (run_network_tests)
export RN1_NET_CHECK=off
export LOG="$T/calls.log" ST="$T/state" UNH="$T/unhandled.log"
: > "$LOG"; : > "$UNH"

# Docker Hub (the Catalog) and the registries with the tags of 2026-10-11. A moving tag has the
# digest of the version it points to (8 -> 8.3.11, 8.0 -> 8.0.32, 3-management-alpine -> 3.13.7 ...).
# SHIM_REG_DOWN: no https address answers. SHIM_STABLE=bbbb: "stable" is 26.1, not the newest 26.3.
# SHIM_SLOW: every call takes 3 seconds.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${SHIM_SLOW:-}" ] && sleep 3
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
echo "curl $url" >> "$LOG"
emit() { if [ -n "$out" ] && [ "$out" != "-" ]; then printf '%s' "$1" > "$out"; else printf '%s' "$1"; fi; }
tags_of() {
  case "$1" in
    library/mongo) echo 7.0.43 8.0.30 8.0.32 8.2.12 8.3.11 9.0.2 7 7.0 8 8.0 8.2 8.3 9 9.0 latest ;;
    opensearchproject/opensearch) echo 2.17.1 2.19.5 2.19.6 3.3.2 3.9.0 2 3 latest ;;
    opensearchproject/opensearch-dashboards) echo 2.17.1 2.19.5 2.19.6 3.9.0 2 3 latest ;;
    library/rabbitmq) echo 3.12.14-management-alpine 3.13.6-management-alpine 3.13.7-management-alpine 4.2.9-management-alpine \
      4.3.6-management-alpine 4.3.6 3-management-alpine 3.12-management-alpine 3.13-management-alpine 4-management-alpine \
      4.3-management-alpine management-alpine 4.4.0-rc.1-management-alpine ;;
    jc21/nginx-proxy-manager) echo 2.15.1 2.16.0 2 v3 latest ;;
    golithus/minio) echo RELEASE.2025-09-07T16-13-09Z RELEASE.2025-10-15T17-29-55Z RELEASE.2025-10-15T17-29-55Z-amd64 latest ;;
    *) echo "UNHANDLED curl tags of $1" >> "$UNH" ;;
  esac
}
target() {
  case "$1:$2" in
    library/mongo:8|library/mongo:8.3) echo 8.3.11 ;;
    library/mongo:8.0) echo 8.0.32 ;;
    library/mongo:8.2) echo 8.2.12 ;;
    library/mongo:9|library/mongo:9.0|library/mongo:latest) echo 9.0.2 ;;
    library/mongo:7|library/mongo:7.0) echo 7.0.43 ;;
    opensearchproject/*:2) echo 2.19.6 ;;
    opensearchproject/*:3|opensearchproject/*:latest) echo 3.9.0 ;;
    library/rabbitmq:3-management-alpine|library/rabbitmq:3.13-management-alpine) echo 3.13.7-management-alpine ;;
    library/rabbitmq:3.12-management-alpine) echo 3.12.14-management-alpine ;;
    library/rabbitmq:4-management-alpine|library/rabbitmq:4.3-management-alpine|library/rabbitmq:management-alpine) echo 4.3.6-management-alpine ;;
    jc21/nginx-proxy-manager:2|jc21/nginx-proxy-manager:latest) echo 2.16.0 ;;
    golithus/minio:latest) echo RELEASE.2025-10-15T17-29-55Z ;;
    *) echo "$2" ;;
  esac
}
code=200; body=""
if [ -n "${SHIM_REG_DOWN:-}" ] && [ "${url#https://}" != "$url" ]; then
  exit 7
fi
case "$url" in
  http://localhost:*/) ;;
  # the license check after a restart: still valid
  http://localhost:*/v1/license/isValid) body=true ;;
  https://hub.docker.com/v2/repositories/raynetgmbh/rayventory-catalog*/tags*)
    body='{"count":6,"next":null,"results":[{"name":"latest","digest":"sha256:aaaa"},{"name":"stable","digest":"sha256:'"${SHIM_STABLE:-aaaa}"'"},{"name":"26.3.4789.148","digest":"sha256:aaaa"},{"name":"26.1.4475.137","digest":"sha256:bbbb"},{"name":"25.4.4191.133","digest":"sha256:cccc"},{"name":"25","digest":"sha256:cccc"}]}' ;;
  https://*/v2/) [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$( [ "$hdr" = - ] && echo /dev/stdout || echo "$hdr")" ;;
  https://*/tags/list*)
    repo="${url#https://*/v2/}"; repo="${repo%/tags/list*}"
    list=""; for t in $(tags_of "$repo"); do list="$list,\"$t\""; done
    [ -n "$hdr" ] && : > "$hdr"
    body='{"name":"'"$repo"'","tags":['"${list#,}"']}' ;;
  https://*/manifests/*)
    repo="${url#https://*/v2/}"; repo="${repo%/manifests/*}"
    if [ "$head" = yes ]; then printf 'docker-content-digest: sha256:%s\r\n' "$(printf '%s:%s' "$repo" "$(target "$repo" "${url##*/}")" | sha256sum | cut -c1-12)"; exit 0; fi
    body='{}' ;;
  *) echo "UNHANDLED curl $url" >> "$UNH"; code=404 ;;
esac
emit "$body"
if [ -n "$fmt" ]; then f="${fmt//%\{http_code\}/$code}"; printf '%s' "$f"; fi
[ "$code" -ge 400 ] && exit 22
exit 0
EOF

# Fake rootful Podman 5.7.0 with "podman compose" built in. Containers are "id-SERVICE" while $ST/up
# exists ($ST/mongo_version: what mongod --version says), $ST/wd is the folder the stack was
# created in. Calls it does not know are logged to $UNH and fail with 125.
export RN1_COMPOSE_PROVIDER="$T/cli-plugins/docker-compose"
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
    '{{.State.OOMKilled}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.RestartCount}}') echo "false|$svc|0" ;;
    '{{.Config.Image}}')
      [ "$svc" = catalog-web ] || bad container inspect --format "$1" "$id"
      echo "docker.io/raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag")" ;;
    '{{.State.Status}}|{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}|{{.RestartCount}}')
      if [ "$svc" = rabbitmq ]; then echo "running|healthy|0"; else echo "running|none|0"; fi ;;
    '{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.Image}}')
      echo "$(cat "$ST/wd")|$svc|docker.io/raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag")" ;;
    '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{index .Config.Labels "com.docker.compose.project.environment_file"}}|{{.Config.Image}}|{{.State.Status}}')
      [ "$svc" = catalog-web ] || bad container inspect --format "$1" "$id"
      w="$(cat "$ST/wd")"
      echo "inst|$w|$w/docker-compose.yml|$w/.env|docker.io/raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag")|running" ;;
    *) bad container inspect --format "$1" "$id" ;;
  esac
}
case "${1:-}" in
  --version) [ $# -eq 1 ] || bad "$@"; echo "podman version 5.7.0" ;;
  info)
    if [ $# -eq 1 ]; then exit 0; fi
    case "$*" in
      "info --format {{.Host.Security.Rootless}}") echo false ;;
      "info --format {{.Host.MemTotal}}") echo "${SHIM_MEMTOTAL:-34359738368}" ;;
      *) bad "$@" ;;
    esac ;;
  volume)
    [ "$*" = "volume ls -q --filter label=com.docker.compose.project=inst" ] || bad "$@"
    if [ -f "$ST/wd" ]; then
      for v in db_data rmq_data minio_storage opensearch_data; do echo "inst_$v"; done
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
    [ "$*" = "exec id-mongo mongod --version" ] || bad "$@"
    echo "db version v$(cat "$ST/mongo_version")" ;;
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
        elif [ "${1:-}" = -a ] && [ "${2:-}" = -q ] && [ $# -eq 3 ]; then running && echo "id-$3"
        elif [ $# -eq 0 ]; then echo "NAME STATUS"
        elif [ "$*" = "--services --filter status=running" ]; then if running; then printf '%s\n' $SVCS; fi
        else bad compose ps "$@"; fi ;;
      pull) echo "pull $*" >> "$ST/pulls" ;;
      up)
        [ "$*" = "-d --remove-orphans" ] || bad compose up "$@"
        touch "$ST/up"; pwd -P > "$ST/wd"
        sed -n 's/^CATALOG_IMAGE=.*://p' "$envf" > "$ST/catalog_tag"
        m="$(sed -n 's/^MONGO_TAG=//p' "$envf")"; [[ "$m" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$m" > "$ST/mongo_version" ;;
      *) bad compose "$sub" "$@" ;;
    esac ;;
  *) bad "$@" ;;
esac
exit 0
EOF
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
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-active --quiet podman.socket"|"is-active podman.socket") exit 0 ;;
  "is-enabled podman-restart.service") echo enabled ;;
  *) printf 'UNHANDLED systemctl %s\n' "$*" >> "$UNH"; exit 1 ;;
esac
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${SHIM_TZ:-Europe/Berlin}"\n' > "$T/bin/timedatectl"
REAL_UNAME="$(command -v uname)"
printf '#!/usr/bin/env bash
if [ "${1:-}" = "-r" ]; then echo "${SHIM_KERNEL:-6.8.0-generic}"; else exec "%s" "$@"; fi
' "$REAL_UNAME" > "$T/bin/uname"
chmod +x "$T/bin/"* "$RN1_COMPOSE_PROVIDER"
# wide tables: no column is cut
export PATH="$T/bin:$PATH" COLUMNS=200

D="$T/inst"
I="$D/rn1-technology-catalog-installer.sh"
# fresh [sed program] -> a new folder with the installer (CHECK_FOR_UPDATES off) and nothing installed
fresh() {
  rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$NEW" "$I"
  sed -i "s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES=\"false\"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT=\"10\"/; ${1:-}" "$I"
  : > "$LOG"
}
# setting NAME -> its value in the installer
setting() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$I" | head -n 1; }
tags() { printf '%s|' "$(setting CATALOG_VERSION)" "$(setting MONGO_TAG)" "$(setting OPENSEARCH_TAG)" "$(setting OPENSEARCH_DASHBOARDS_TAG)" "$(setting RABBITMQ_TAG)" "$(setting MINIO_TAG)" "$(setting NGINX_PROXY_MANAGER_TAG)"; }
choose() { printf "$1" | bash "$I" __choose_versions 2>&1; }
OLD_TAGS='0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG="3-management-alpine"/; 0,/^NGINX_PROXY_MANAGER_TAG=/s/^NGINX_PROXY_MANAGER_TAG=.*/NGINX_PROXY_MANAGER_TAG="latest"/'
OUTSIDE='9\.0\.2|8\.3\.11|8\.2\.12|3\.9\.0|3\.3\.2|4\.2\.9|4\.3\.6|v3'
# a Catalog older than the newest on Docker Hub (the default is the newest stable one of the release)
OLD_CATALOG='s/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/'
# the default of a release: the newest stable Catalog on the fake Docker Hub
RELEASE_CATALOG='s/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/'

# 1. Defaults: inside the series, so installs without the wizard stay there; the Catalog an exact version
fresh
check "defaults: an exact Catalog, MongoDB 8.0, OpenSearch 2, RabbitMQ 3.13, Nginx Proxy Manager 2" '[[ "$(tags)" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\|8\.0\|2\|2\|3\.13-management-alpine\|RELEASE\.2025-10-15T17-29-55Z\|2\|$ ]]'
check "the allowed series sit below the settings section (the installer update brings them)" 'grep -q "^declare -A SERIES_ALLOWED=(\[mongo\]=\"8.0\" \[opensearch\]=\"2\" \[rabbitmq\]=\"3\" \[npm\]=\"2\" \[minio\]=\"\")$" "$I" && [ "$(grep -n "^declare -A SERIES_ALLOWED=" "$I" | cut -d: -f1)" -gt "$(grep -n "^# DO NOT CHANGE ANYTHING BELOW" "$I" | cut -d: -f1)" ]'

# 2. Option 8 table (updates): recommended = the newest inside the series, the Catalog the newest
out="$(bash "$I" updates 2>&1)"
check "updates: the registries are read once" 'grep -q "Checking Docker Hub and GHCR" <<< "$out"'
check "updates: RECOMMENDED column" 'grep -q "RECOMMENDED" <<< "$out" && ! grep -q "NEWEST" <<< "$out"'
row() { grep -E "^ *$1 " <<< "$out" | head -n 1; }
check "updates: recommended 26.3 / 2.19.6 / 8.0.32 / 3.13.7 / RELEASE.2025-10-15 / 2.16.0" 'row 1 | grep -q "26.3.4789.148" && row 2 | grep -q "2 .* 2.19.6 .*2.19.6" && row 3 | grep -q "8.0 .* 8.0.32 .*8.0.32" && row 4 | grep -q "3.13-management-alpine .* 3.13.7 .*3.13.7 " && row 5 | grep -q "RELEASE.2025-10-15T17-29-55Z" && row 6 | grep -q "2 .* 2.16.0 .*2.16.0"'
check "updates: every component up to date with the default tags" '[ "$(grep -c "up to date" <<< "$out")" -eq 5 ]'
check "updates: no version outside the series in the table" '! grep -E "^ *[1-6] " <<< "$out" | grep -Eq "$OUTSIDE"'
check "updates: one line names the newer series" 'grep -q "MongoDB 9.0, OpenSearch 3 and RabbitMQ 4 exist - not released for the Catalog yet" <<< "$out"'

fresh "$OLD_TAGS; 0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG=\"2.17.1\"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG=\"2.17.1\"/"
out="$(bash "$I" updates 2>&1)"
check "updates: MongoDB 8 (= 8.3.11) is outside the series 8.0, 8.0.32 recommended" 'row 3 | grep -q "8.3.11" && row 3 | grep -q "8.0.32" && row 3 | grep -q "outside the series 8.0"'
check "updates: OpenSearch 2.17.1 -> update available: 2.19.6 (minor step inside the series)" 'row 2 | grep -q "update available: 2.19.6"'
check "updates: RabbitMQ 3 (= 3.13.7) and Nginx Proxy Manager latest (= 2.16.0) up to date" 'row 4 | grep -q "up to date" && row 6 | grep -q "latest .*2.16.0 .*up to date"'
fresh '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0.43"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG="3.12.14-management-alpine"/'
out="$(bash "$I" updates 2>&1)"
check "updates: MongoDB 7.0.43 -> major update to 8.0.32, RabbitMQ 3.12 -> 3.13.7" 'row 3 | grep -q "8.0.32 .*major update" && row 4 | grep -q "update available: 3.13.7"'

# 3. Option 8 picker: only the series is offered, a typed version outside it is refused with the reason
fresh "$OLD_TAGS"
out="$(printf '8\n3\n9.0.2\n8.3.11\n0\n0\n' | bash "$I" menu 2>&1)"
mongo_list="$(sed -n '/Series 8.0: the versions/,/cancel/p' <<< "$out" | grep -E "^   [1-9]  ")"
check "pick MongoDB: only 8.0.x offered, 8.0.32 recommended" '[ -n "$mongo_list" ] && ! grep -Evq "  8\.0\.[0-9]+ " <<< "$mongo_list" && grep -q "1  8.0.32 .*recommended" <<< "$mongo_list"'
check "pick MongoDB: the current 8.3.11 is named outside the series" 'grep -q "8.3.11 is outside the series" <<< "$out" && grep -q "Series 8.0: the versions Raynet runs with the Catalog" <<< "$out"'
check "pick MongoDB: typed 9.0.2 and 8.3.11 refused with the reason" 'grep -q "9.0.2 is outside the series 8.0 Raynet runs with the Catalog - it is not offered." <<< "$out" && grep -q "8.3.11 is outside the series 8.0 Raynet runs with the Catalog - it is not offered." <<< "$out" && [ "$(setting MONGO_TAG)" = 8 ]'
check "pick MongoDB: the newer series named, dim" 'grep -q "MongoDB 9.0 exists - not released for the Catalog yet" <<< "$out"'
out="$(printf '8\n4\n4.3.6\n4.2.9-management-alpine\n3.13.7\n0\n' | bash "$I" menu 2>&1)"
rabbit_list="$(sed -n '/Series 3: the versions/,/cancel/p' <<< "$out" | grep -E "^   [1-9]  ")"
check "pick RabbitMQ: only 3.x offered (never 4)" '[ -n "$rabbit_list" ] && ! grep -Eq "  4\." <<< "$rabbit_list" && grep -q "  3.13.7 " <<< "$rabbit_list" && grep -q "RabbitMQ 4 exists - not released for the Catalog yet" <<< "$out"'
check "pick RabbitMQ: typed 4.3.6 and 4.2.9-management-alpine refused" 'grep -q "4.3.6 is outside the series 3 " <<< "$out" && grep -q "4.2.9-management-alpine is outside the series 3 " <<< "$out"'
check "pick RabbitMQ: typed 3.13.7 taken as the exact tag (the same version: no feature flag hint)" '[ "$(setting RABBITMQ_TAG)" = 3.13.7-management-alpine ] && ! grep -q "enable all feature flags" <<< "$out"'
out="$(printf '8\n2\n3.9.0\n0\n6\nv3\n0\n0\n' | bash "$I" menu 2>&1)"
check "pick OpenSearch: 3.9.0 refused, list is 2.x" 'grep -q "3.9.0 is outside the series 2 " <<< "$out" && ! sed -n "/Series 2: the versions/,/cancel/p" <<< "$out" | grep -Eq "^   [1-9]  3\."'
check "pick Nginx Proxy Manager: v3 is no version" 'grep -q "Invalid choice: v3" <<< "$out" && [ "$(setting NGINX_PROXY_MANAGER_TAG)" = latest ]'
fresh '0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG="2.17.1"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG="2.17.1"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG="3.12.14-management-alpine"/'
out="$(printf '8\n2\n1\n4\n1\n0\n' | bash "$I" menu 2>&1)"
check "pick OpenSearch from 2.17.1: 2.19.6, 2.19.5 and the current 2.17.1; both settings move together" 'sed -n "/Series 2: the versions/,/cancel/p" <<< "$out" | grep -E "^   [1-9]  " | awk "{print \$2}" | tr "\n" " " | grep -qx "2.19.6 2.19.5 2.17.1 " && [ "$(setting OPENSEARCH_TAG)" = 2.19.6 ] && [ "$(setting OPENSEARCH_DASHBOARDS_TAG)" = 2.19.6 ]'
check "pick RabbitMQ from 3.12.14: 3.13 offered with the feature flag hint" '[ "$(setting RABBITMQ_TAG)" = 3.13.7-management-alpine ] && grep -q "Before RabbitMQ 3.12.14 -> 3.13.7 enable all feature flags (with the stack running): podman exec rabbitmq rabbitmqctl enable_feature_flag all" <<< "$out"'

fresh "$OLD_TAGS"
out="$(printf '8\np\n0\n' | bash "$I" menu 2>&1)"
check "pin: a moving tag that points outside the series is not pinned" 'grep -q "MongoDB: \"8\" points to 8.3.11, outside the series 8.0 Raynet runs - not pinned" <<< "$out" && [ "$(setting MONGO_TAG)" = 8 ]'
check "pin: moving tags inside the series pinned (RabbitMQ 3.13.7, Nginx Proxy Manager 2.16.0)" '[ "$(setting RABBITMQ_TAG)" = 3.13.7-management-alpine ] && [ "$(setting NGINX_PROXY_MANAGER_TAG)" = 2.16.0 ] && [ "$(setting OPENSEARCH_TAG)" = 2.19.6 ]'

# 4. The versions screen of the wizard (choose_versions), a download with an older Catalog than the newest
fresh "$OLD_CATALOG"
cp "$I" "$T/before.sh"
out="$(choose '\n')"; rc=$?
check "versions screen: reads the registries once, one row each, NPM included" '[ "$rc" -eq 0 ] && [ "$(grep -c "Checking Docker Hub and GHCR" <<< "$out")" -eq 1 ] && grep -q "Catalog + 4 workers" <<< "$out" && grep -q "Nginx Proxy Manager" <<< "$out" && grep -q "MinIO" <<< "$out"'
check "versions screen: Enter writes the exact recommended tags" '[ "$(tags)" = "26.3.4789.148|8.0.32|2.19.6|2.19.6|3.13.7-management-alpine|RELEASE.2025-10-15T17-29-55Z|2.16.0|" ]'
check "versions screen: only those settings changed, no backup left" '[ "$(diff "$T/before.sh" "$I" | grep -c "^[<>]")" -eq 12 ] && ! ls "$D"/*.bak-* >/dev/null 2>&1'
check "versions screen: nothing outside the series shown, the newer series named" '! grep -E "^ +[1-6] " <<< "$out" | grep -Eq "$OUTSIDE" && grep -q "MongoDB 9.0, OpenSearch 3 and RabbitMQ 4 exist - not released for the Catalog yet" <<< "$out"'
check "versions screen: the settings are named" 'grep -q "MONGO_TAG = \"8.0.32\"" <<< "$out" && grep -q "CATALOG_VERSION = \"26.3.4789.148\"" <<< "$out"'
out="$(choose '\n')"; rc=$?
check "versions screen again: nothing to change" '[ "$rc" -eq 0 ] && grep -q "The versions stay as they are." <<< "$out"'
# a download of a release: its default is the newest stable Catalog - CURRENT is SELECTED, recommended, no
# upgrade, and Enter leaves CATALOG_VERSION as it is
for loc in C C.UTF-8; do
  fresh "$RELEASE_CATALOG"
  out="$(LC_ALL=$loc choose '\n')"; rc=$?
  row="$(grep "Catalog + 4 workers" <<< "$out" | head -n 1)"
  check "release download ($loc): the Catalog row CURRENT = SELECTED, stable and recommended, no arrow" '[ "$rc" -eq 0 ] && [[ "$row" =~ Catalog\ \+\ 4\ workers\ +26\.3\.4789\.148\ +26\.3\.4789\.148\ .*stable.*recommended ]] && ! grep -q -e "->" -e "→" -e "your choice" -e "kept" <<< "$row" || { echo "  | $row"; false; }'
  check "release download ($loc): Enter does not write CATALOG_VERSION, the others pinned" '[ "$(setting CATALOG_VERSION)" = 26.3.4789.148 ] && ! grep -q "CATALOG_VERSION = " <<< "$out" && grep -q "MONGO_TAG = \"8.0.32\"" <<< "$out"'
done

fresh
out="$(choose '3\n2\n1\n26.1.4475.137\n2\n9.0.2\n8.3.11\n2\n\n')"; rc=$?
check "versions screen: a row can be changed (OpenSearch 2.19.5, Catalog 26.1 typed, MongoDB 8.0.30)" '[ "$rc" -eq 0 ] && [ "$(tags)" = "26.1.4475.137|8.0.30|2.19.5|2.19.5|3.13.7-management-alpine|RELEASE.2025-10-15T17-29-55Z|2.16.0|" ]'
check "versions screen: a typed version outside the series is refused" 'grep -q "9.0.2 is outside the series 8.0 Raynet runs with the Catalog - it is not offered." <<< "$out" && grep -q "8.3.11 is outside the series 8.0 Raynet runs with the Catalog - it is not offered." <<< "$out"'
check "versions screen: the row list holds only the series" 'sed -n "/series 8.0: the versions/,/back/p" <<< "$out" | grep -E "^   [1-9]  " | grep -q "  8\.0\.30 " && ! sed -n "/series 8.0: the versions/,/back/p" <<< "$out" | grep -E "^   [1-9]  " | grep -Evq "  8\.0\."'
fresh
out="$(choose '4\n4.3.6\n0\n\n')"; rc=$?
check "versions screen: RabbitMQ 4 refused, back keeps the recommendation" '[ "$rc" -eq 0 ] && grep -q "4.3.6 is outside the series 3 " <<< "$out" && [ "$(setting RABBITMQ_TAG)" = 3.13.7-management-alpine ]'

fresh
before="$(cksum < "$I")"
out="$(choose '')"; rc=$?
check "versions screen: end of input changes nothing" '[ "$rc" -eq 1 ] && [ "$(cksum < "$I")" = "$before" ] && grep -q "nothing was changed" <<< "$out"'
out="$(choose '2\n')"; rc=$?
check "versions screen: end of input in a row changes nothing" '[ "$rc" -eq 1 ] && [ "$(cksum < "$I")" = "$before" ]'
out="$(choose '0\n')"; rc=$?
check "versions screen: 0 cancels, nothing changed" '[ "$rc" -eq 1 ] && [ "$(cksum < "$I")" = "$before" ] && grep -q "Cancelled - nothing was changed." <<< "$out"'
out="$(choose '9\nx\n0\n')"; rc=$?
check "versions screen: an unknown row is refused" '[ "$rc" -eq 1 ] && grep -q "Invalid choice: 9" <<< "$out" && grep -q "Invalid choice: x" <<< "$out" && [ "$(cksum < "$I")" = "$before" ]'

fresh 's/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/'
out="$(choose '\n')"; rc=$?
check "versions screen without Nginx Proxy Manager: no row, its tag stays" '[ "$rc" -eq 0 ] && ! grep -q "Nginx Proxy Manager" <<< "$out" && [ "$(setting NGINX_PROXY_MANAGER_TAG)" = 2 ] && [ "$(setting MONGO_TAG)" = 8.0.32 ]'

# 5. Registry not reachable: the moving tags of the series, the Catalog stays (an older one: with Docker Hub it would change)
fresh "$OLD_TAGS; $OLD_CATALOG"
out="$(SHIM_REG_DOWN=1 choose '\n')"; rc=$?
check "registry down: the series tags (8.0, 3.13-management-alpine, 2), the Catalog kept, said so" '[ "$rc" -eq 0 ] && [ "$(tags)" = "25.4.4191.133|8.0|2|2|3.13-management-alpine|RELEASE.2025-10-15T17-29-55Z|2|" ] && grep -q "could not be read" <<< "$out" && grep -q "the Catalog stays 25.4.4191.133" <<< "$out"'
fresh '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8.0.30"/'
out="$(SHIM_REG_DOWN=1 choose '\n')"; rc=$?
check "registry down: an exact version inside the series is kept" '[ "$rc" -eq 0 ] && [ "$(setting MONGO_TAG)" = 8.0.30 ] && [ "$(setting RABBITMQ_TAG)" = 3.13-management-alpine ]'

# 6. A folder that is installed already (Catalog 25.4): versions outside the series and the Catalog are kept
fresh "$OLD_TAGS; $OLD_CATALOG; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG=\"3.12.14-management-alpine\"/"
echo "MONGO_TAG=8" > "$D/.env"
out="$(choose '\n')"; rc=$?
check "installed: MongoDB 8.3.11 outside the series kept with a warning (never downgraded automatically)" '[ "$rc" -eq 0 ] && [ "$(setting MONGO_TAG)" = 8 ] && grep -q "MongoDB 8.3.11 is outside the series 8.0 Raynet runs with the Catalog - kept: it is never downgraded automatically." <<< "$out"'
check "installed: the Catalog stays (U upgrades it), the others step inside the series" '[ "$(setting CATALOG_VERSION)" = 25.4.4191.133 ] && grep -q "U upgrades it with backup and rollback" <<< "$out" && [ "$(setting OPENSEARCH_TAG)" = 2.19.6 ] && [ "$(setting RABBITMQ_TAG)" = 3.13.7-management-alpine ] && [ "$(setting NGINX_PROXY_MANAGER_TAG)" = 2.16.0 ]'
check "installed: the RabbitMQ step names the feature flags" 'grep -q "Before RabbitMQ 3.12.14 -> 3.13.7 enable all feature flags" <<< "$out"'

# 7. Patch updates after the Catalog check (option 21): steps inside the series only
# inst SED MONGO [CATALOG] -> an installed stack that runs (MongoDB MONGO, Catalog 26.3.4789.148 or CATALOG)
inst() {
  local cat="${3:-26.3.4789.148}"
  fresh "$1; s/^CATALOG_VERSION=.*/CATALOG_VERSION=\"$cat\"/"
  (cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  touch "$ST/up"; echo "$cat" > "$ST/catalog_tag"; echo "$2" > "$ST/mongo_version"; (cd "$D" && pwd -P) > "$ST/wd"
  : > "$LOG"
}
inst "$OLD_TAGS; 0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG=\"2.17.1\"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG=\"2.17.1\"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG=\"3.12.14-management-alpine\"/; 0,/^NGINX_PROXY_MANAGER_TAG=/s/^NGINX_PROXY_MANAGER_TAG=.*/NGINX_PROXY_MANAGER_TAG=\"2.15.1\"/; 0,/^MINIO_TAG=/s/^MINIO_TAG=.*/MINIO_TAG=\"RELEASE.2025-09-07T16-13-09Z\"/" 8.3.11
before="$(tags)"
out="$(printf '21\n0\n' | bash "$I" menu 2>&1)"
check "patch: Catalog 26.3 up to date, MongoDB 8.3.11 kept with a warning" 'grep -q "The Catalog is up to date." <<< "$out" && grep -q "MongoDB 8.3.11 runs here, outside the series 8.0 Raynet runs with the Catalog - it is kept (never downgraded automatically)." <<< "$out" && ! grep -q "MongoDB .*->" <<< "$out"'
check "patch: minor and patch steps inside the series" 'grep -q "OpenSearch + Dashboards .*2.17.1 -> 2.19.6" <<< "$out" && grep -q "RabbitMQ .*3.12.14 -> 3.13.7" <<< "$out" && grep -q "Nginx Proxy Manager .*2.15.1 -> 2.16.0" <<< "$out" && grep -q "MinIO (golithus fork) .*RELEASE.2025-09-07T16-13-09Z -> RELEASE.2025-10-15T17-29-55Z" <<< "$out"'
check "patch: the RabbitMQ step names the feature flags" 'grep -q "Before RabbitMQ 3.12.14 -> 3.13.7 enable all feature flags" <<< "$out"'
check "patch: nothing outside the series offered" '! grep -E -- "-> ($OUTSIDE|8\.0\.)" <<< "$out"'
check "patch: skipped, nothing changed" '[ "$(tags)" = "$before" ] && grep -q "No patch updates applied." <<< "$out"'
out="$(printf '21\n\n\n0\n' | bash "$I" menu 2>&1)"
check "patch: applied, the exact tags written" '[ "$(tags)" = "26.3.4789.148|8|2.19.6|2.19.6|3.13.7-management-alpine|RELEASE.2025-10-15T17-29-55Z|2.16.0|" ] && grep -q "All 11 services run" <<< "$out"'
check "patch: only the changed services pulled (not MongoDB with its moving tag 8)" '[ "$(cat "$ST/pulls")" = "pull opensearch opensearch-dashboards rabbitmq minio nginx-proxy-manager" ]'

# MongoDB "8" runs 8.0.30 (in the series): offered with OpenSearch; turned off it is neither pulled nor changed
inst "$OLD_TAGS; 0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG=\"2.17.1\"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG=\"2.17.1\"/" 8.0.30
out="$(printf '21\n2\n\n\n0\n' | bash "$I" menu 2>&1)"
check "patch: MongoDB 8 running 8.0.30 offered 8.0.32, the moving tag named although an update is offered" 'grep -q "MongoDB .*8.0.30 -> 8.0.32" <<< "$out" && grep -q "MongoDB uses the moving tag \"8\", which can leave the series 8.0 with a later pull - the update below pins 8.0.32." <<< "$out"'
check "patch: MongoDB turned off - only OpenSearch pulled, MONGO_TAG stays 8" '[ "$(cat "$ST/pulls")" = "pull opensearch opensearch-dashboards" ] && [ "$(setting MONGO_TAG)" = 8 ] && [ "$(setting OPENSEARCH_TAG)" = 2.19.6 ] && [ "$(cat "$ST/mongo_version")" = 8.0.30 ]'

inst '0,/^NGINX_PROXY_MANAGER_TAG=/s/^NGINX_PROXY_MANAGER_TAG=.*/NGINX_PROXY_MANAGER_TAG="2.15.1"/; s/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/' 8.0.32
out="$(printf '21\n0\n' | bash "$I" menu 2>&1)"
check "patch: Nginx Proxy Manager not installed - no update offered for it" '! grep -q "Nginx Proxy Manager .*->" <<< "$out" && grep -q "No updates of MongoDB, OpenSearch, RabbitMQ, MinIO or Nginx Proxy Manager inside their series." <<< "$out"'
inst "" 8.0.4
out="$(printf '21\n0\n' | bash "$I" menu 2>&1)"
check "patch: MongoDB 8.0.4 (default tag 8.0) -> 8.0.32" 'grep -q "MongoDB .*8.0.4 -> 8.0.32" <<< "$out"'
inst '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0"/' 7.0.43
out="$(printf '21\n0\n' | bash "$I" menu 2>&1)"
check "patch: MongoDB 7.0.43 is not upgraded here, option 8 named" 'grep -q "MongoDB 7.0.43 runs here. 8.0.32 of the series 8.0 is an upgrade for option 8" <<< "$out" && ! grep -q "MongoDB .*->" <<< "$out"'

inst "$OLD_TAGS" 8.0.32
out="$(printf '21\n0\n' | bash "$I" menu 2>&1)"
check "patch: a moving tag that can leave the series is named (MongoDB 8, Nginx Proxy Manager latest)" 'grep -q "MongoDB uses the moving tag \"8\", which can leave the series 8.0 with a later pull - option 8 sets a version of the series." <<< "$out" && grep -q "Nginx Proxy Manager uses the moving tag \"latest\", which can leave the series 2" <<< "$out" && ! grep -q "RabbitMQ uses the moving tag" <<< "$out"'

# 8. An installation that runs: for MongoDB the version that runs counts, not where "8" points today
inst "$OLD_TAGS" 8.0.30
out="$(bash "$I" updates 2>&1)"
check "updates: MongoDB 8 running 8.0.30 is inside the series (update available: 8.0.32)" 'row 3 | grep -q "8.0.30" && row 3 | grep -q "update available: 8.0.32" && ! row 3 | grep -q "8.3.11"'
out="$(choose '\n')"; rc=$?
check "installed, MongoDB 8 running 8.0.30: the versions screen pins 8.0.32, no warning" '[ "$rc" -eq 0 ] && [ "$(setting MONGO_TAG)" = 8.0.32 ] && ! grep -q "outside the series" <<< "$out"'
inst "$OLD_TAGS" 8.3.11
out="$(choose '\n')"; rc=$?
check "installed, MongoDB 8 running 8.3.11: kept with the warning" '[ "$rc" -eq 0 ] && [ "$(setting MONGO_TAG)" = 8 ] && grep -q "MongoDB 8.3.11 is outside the series 8.0 Raynet runs with the Catalog - kept: it is never downgraded automatically." <<< "$out"'

# the Catalog of an installation is upgraded by U or option 21 only (backup, health check, rollback)
inst "" 8.0.32 25.4.4191.133
out="$(choose '1\n1\n0\n\n')"; rc=$?
check "installed Catalog 25.4: a newer one picked on the versions screen is refused" '[ "$rc" -eq 0 ] && [ "$(setting CATALOG_VERSION)" = 25.4.4191.133 ] && grep -q "U or option 21 upgrades the Catalog of an installation (MongoDB backup, health check, rollback) - not this screen." <<< "$out" && grep -q "25.4.4191.133 .*installed" <<< "$out"'

# the newest Catalog is not the stable one: the newest is recommended and the upgrade target
fresh "$OLD_CATALOG"
out="$(SHIM_STABLE=bbbb choose '1\n0\n\n')"; rc=$?
check "stable 26.1, newest 26.3: the row marks 26.1 stable and 26.3 recommended" 'grep -E "^   [0-9]  26\.1\.4475\.137 " <<< "$out" | grep -q "stable" && ! grep -E "^   [0-9]  26\.1\.4475\.137 " <<< "$out" | grep -q "recommended" && grep -E "^   [0-9]  26\.3\.4789\.148 " <<< "$out" | grep -q "recommended" && ! grep -E "^   [0-9]  26\.3\.4789\.148 " <<< "$out" | grep -q "stable"'
check "stable 26.1, newest 26.3: Enter writes the newest" '[ "$rc" -eq 0 ] && [ "$(setting CATALOG_VERSION)" = 26.3.4789.148 ]'
inst "" 8.0.32 26.1.4475.137
out="$(printf '21\nn\n0\n' | SHIM_STABLE=bbbb bash "$I" menu 2>&1)"
check "stable 26.1, newest 26.3: option 21 upgrades to the newest" 'grep -q "Newest Catalog:    26.3.4789.148$" <<< "$out" && grep -q "CATALOG_VERSION 26.1.4475.137 -> 26.3.4789.148" <<< "$out" && grep -q "Cancelled - nothing was changed." <<< "$out" && [ "$(setting CATALOG_VERSION)" = 26.1.4475.137 ]'
if command -v script >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  # tui_header -> the full screen menu at 120x40 (the first start put off: no new installation)
  tui_header() {
    local log="$T/tui.log" n
    touch "$D/.setup-later"
    { for n in $(seq 1 120); do grep -q "Select:" "$log" 2>/dev/null && break; sleep 0.5; done; sleep 1; printf q; sleep 2; } \
      | SHIM_STABLE=bbbb TERM=xterm LANG=C.UTF-8 timeout 90 script -qfec "stty cols 120 rows 40; bash $I menu" /dev/null > "$log" 2>&1
    sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g' "$log" | tr -d '\r'
  }
  inst 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="true"/' 8.0.32 26.1.4475.137
  out="$(tui_header)"
  check "full screen, Catalog 26.1 (stable) installed, newest 26.3: the header points to U or option 21" 'grep -q "Catalog 26.1.4475.137 .*26.3.4789.148 .*U or option 21" <<< "$out" && ! grep -q "26.3.4789.148, option 8" <<< "$out"'
  fresh 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="true"/; s/^CATALOG_VERSION=.*/CATALOG_VERSION="26.1.4475.137"/'
  out="$(tui_header)"
  check "full screen, nothing installed, the settings 26.1 (stable), newest 26.3: the version a start would install, option 8" 'grep -q "Catalog not installed .* 26.1.4475.137 would be installed .* 26.3.4789.148 is newer .* option 8" <<< "$out" && ! grep -q -e "U or option 21" -e "up to date" <<< "$out"'
else
  echo "SKIP: script (util-linux) missing - no full screen header test"
fi

# 80 columns, plain and UTF-8 lines: no line of the versions screen is wider; an installation shows
# its current values below the rows
# widest LOCALE <<< TEXT -> the length of the longest line in characters
widest() {
  local LC_ALL="$1" line max=0
  while IFS= read -r line; do
    if [ "${#line}" -gt "$max" ]; then max="${#line}"; fi
  done
  echo "$max"
}
for loc in C C.UTF-8; do
  fresh
  out="$(LC_ALL=$loc COLUMNS=80 choose '\n')"; rc=$?
  check "80 columns ($loc): no line wider than 80, SELECTED without CURRENT" '[ "$rc" -eq 0 ] && [ "$(widest "$loc" <<< "$out")" -le 80 ] && grep -q "COMPONENT *SELECTED" <<< "$out" && ! grep -q "CURRENT" <<< "$out" && grep -q "RELEASE.2025-10-15T17-29-55Z  " <<< "$out"'
  inst "$OLD_TAGS" 8.0.30
  out="$(LC_ALL=$loc COLUMNS=80 choose '\n')"; rc=$?
  check "80 columns ($loc), installed: the current value on its own line" '[ "$rc" -eq 0 ] && [ "$(widest "$loc" <<< "$out")" -le 80 ] && grep -Eq "^ {29}now 8 .*8\.0\.30$" <<< "$out"'
done

# Ctrl+C (here TERM: a background job ignores INT) while the registries are read: the screen ends,
# nothing is changed, the installer does not die with 130
fresh
before="$(cksum < "$I")"
printf '\n' > "$T/enter"
SHIM_SLOW=1 bash "$I" __choose_versions < "$T/enter" > "$T/int.out" 2>&1 &
pid=$!
sleep 1
kill -TERM "$pid"
wait "$pid"; rc=$?
check "interrupted registry check: cancelled, nothing changed, exit 1 (not 130)" '[ "$rc" -eq 1 ] && grep -q "Cancelled - nothing was changed." "$T/int.out" && [ "$(cksum < "$I")" = "$before" ]'
sleep 3

# 9. The release check of CI (tests/check_release_default.sh): the default Catalog is on Docker Hub and not
#    behind the newest stable one there, which the installer itself reads (__recommended_catalog);
#    GITHUB_ACTIONS empty for the plain output (GitHub Actions sets it for the tests too)
RCHECK="$(cd "$(dirname "$0")" && pwd)/check_release_default.sh"
fresh "$RELEASE_CATALOG"
check "release check hook: what the versions screen selects, the stable one, the default listed" '[ "$(bash "$I" __recommended_catalog)" = "26.3.4789.148 26.3.4789.148 listed" ] && [ "$(SHIM_STABLE=bbbb bash "$I" __recommended_catalog)" = "26.3.4789.148 26.1.4475.137 listed" ] && [ "$(SHIM_STABLE=zzzz bash "$I" __recommended_catalog)" = "26.3.4789.148 - listed" ]'
out="$(GITHUB_ACTIONS= bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check: the default is the newest stable Catalog - passes, no warning" '[ "$rc" -eq 0 ] && grep -q "Docker Hub.s newest stable Catalog is 26.3.4789.148" <<< "$out" && ! grep -q "WARNING" <<< "$out"'
# a typo of the version, or one Docker Hub does not have (yet): sort would put it above the stable one
fresh 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.184"/'
out="$(GITHUB_ACTIONS= bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check: a default Docker Hub does not have fails and names what to set" '[ "$(bash "$I" __recommended_catalog)" = "26.3.4789.148 26.3.4789.148 missing" ] && [ "$rc" -eq 1 ] && grep -qxF "ERROR CATALOG_VERSION 26.3.4789.184 is not on Docker Hub for the Catalog and its worker - set the newest stable Catalog, 26.3.4789.148, before publishing" <<< "$out"'
# no version has the stable tag: the newest one counts, and the message says so
fresh "$OLD_CATALOG"
out="$(SHIM_STABLE=zzzz GITHUB_ACTIONS= bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check without a stable tag: the newest counts, named as such" '[ "$rc" -eq 1 ] && grep -qxF "ERROR CATALOG_VERSION is 25.4.4191.133 but Docker Hub'"'"'s newest Catalog (no stable tag) is 26.3.4789.148 - set the default before publishing" <<< "$out"'
fresh "$OLD_CATALOG"
out="$(GITHUB_ACTIONS= bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check: an older default fails and names what to set" '[ "$rc" -eq 1 ] && grep -qxF "ERROR CATALOG_VERSION is 25.4.4191.133 but Docker Hub'"'"'s newest stable Catalog is 26.3.4789.148 - set the default before publishing" <<< "$out"'
out="$(GITHUB_ACTIONS=true bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check on GitHub Actions: an error annotation" '[ "$rc" -eq 1 ] && grep -q "^::error::CATALOG_VERSION is 25.4.4191.133 but" <<< "$out"'
out="$(SHIM_STABLE=bbbb GITHUB_ACTIONS= bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check: the stable tag counts, not a newer version without it" '[ "$rc" -eq 1 ] && grep -q "newest stable Catalog is 26.1.4475.137 - set the default" <<< "$out"'
fresh 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.1.4475.137"/'
out="$(SHIM_STABLE=bbbb GITHUB_ACTIONS= bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check: the stable one while a newer is not stable yet - passes" '[ "$rc" -eq 0 ] && grep -q "newest stable Catalog is 26.1.4475.137, the versions screen of a new installation selects 26.3.4789.148" <<< "$out"'
# ... with a warning: the versions screen of a new installation selects the newer one
out="$(SHIM_STABLE=bbbb GITHUB_ACTIONS=true bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check: a newer Catalog without the stable tag - a warning annotation, no failure" '[ "$rc" -eq 0 ] && grep -qxF "::warning::Docker Hub has Catalog 26.3.4789.148, newer than CATALOG_VERSION 26.1.4475.137 but without the stable tag: the versions screen of a new installation selects it - set it as the default once it is stable" <<< "$out"'
fresh "$OLD_CATALOG"
out="$(SHIM_REG_DOWN=1 GITHUB_ACTIONS=true bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check without Docker Hub: a warning, no failure" '[ "$rc" -eq 0 ] && grep -q "^::warning::Docker Hub could not be read - CATALOG_VERSION 25.4.4191.133 was not compared" <<< "$out"'
fresh 's/^CATALOG_VERSION=.*/CATALOG_VERSION="stable"/'
out="$(GITHUB_ACTIONS= bash "$RCHECK" "$I" 2>&1)"; rc=$?
check "release check: a tag as the default fails" '[ "$rc" -eq 1 ] && grep -q "the default must be an exact version" <<< "$out"'

check "no Podman, Compose, systemctl or curl call the fakes do not know" '[ ! -s "$UNH" ] || { sort -u "$UNH"; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
