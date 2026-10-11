#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/w"
rm -rf "$T"; mkdir -p "$T/bin" "$T/dbin" "$T/state" "$T/npm" "$T/dns"
# these tests run Podman: CONTAINER_ENGINE names it (on a CI runner, detection would see its real Docker)
sed 's/^CONTAINER_ENGINE=""$/CONTAINER_ENGINE="podman"/' "$1" > "${T%/*}/podman-installer.sh"; NEW="${T%/*}/podman-installer.sh"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# LOG: the calls of one case (emptied by fresh/installed). BAD: calls the fakes do not know, for the whole suite.
# NS: the state of the fake Nginx Proxy Manager (see curl). DNS: $DNS/NAME holds the addresses of NAME.
# LOCAL_IPS: the addresses of this server. LISTEN_PORTS: the ports other programs listen on.
export LOG="$T/calls.log" ST="$T/state" BAD="$T/bad.log" NS="$T/npm" DNS="$T/dns" LOCAL_IPS="192.0.2.10" LISTEN_PORTS=""
: > "$LOG"; : > "$BAD"
# the NPM cases need jq or python3 (the installer reads the answers of its API with one of them)
NPM_OK="no"
if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then NPM_OK="yes"; fi

# Fake curl:
# - Docker Hub (the Catalog: newest 26.3; SHIM_STABLE=bbbb: "stable" is 26.1) and the registries with the
#   tags of 2026-10-11; a moving tag has the digest of the version it points to (8.0 -> 8.0.32 ...)
# - GitHub: the newest Docker Compose, this installer (served from $ST/new-installer.sh when it exists)
# - Catalog Web on localhost
# - the API of Nginx Proxy Manager on 127.0.0.1:81 and the checks through it (--resolve). Its state in $NS:
#   version, user (EMAIL|PASSWORD; missing: not set up yet), token, hosts/ID (DOMAIN|CERT|HOST|PORT|SSL_FORCED),
#   certs/ID (DOMAIN|EXPIRES), seq (last id), calls (METHOD PATH CODE). SHIM_NPM_HOST_FAIL: it refuses to
#   create a proxy host (HTTP 500).
# Any other URL is written to $BAD.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; out=""; hdr=""; fmt=""; head="no"; url=""; cfg=""; data=""; resolve=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -K) if [ "$2" = "-" ]; then cfg="$(cat)"; fi; shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    --resolve) resolve="$2"; shift 2 ;;
    -H|--connect-timeout|--max-time|--retry|--retry-delay|--proto) shift 2 ;;
    -*) case "$1" in --*) ;; *I*) head="yes" ;; esac; shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $url" >> "$LOG"
emit() { if [ -n "$out" ] && [ "$out" != "-" ]; then printf '%s' "$1" > "$out"; else printf '%s' "$1"; fi; }
done_with() { emit "$2"; if [ -n "$fmt" ]; then printf '%s' "${fmt//%\{http_code\}/$1}"; fi; [ "$1" -ge 400 ] && exit 22; exit 0; }
tags_of() {
  case "$1" in
    library/mongo) echo 7.0.43 8.0.30 8.0.32 8.2.12 8.3.11 9.0.2 7 7.0 8 8.0 8.2 8.3 9 9.0 latest ;;
    opensearchproject/opensearch) echo 2.17.1 2.19.5 2.19.6 3.3.2 3.9.0 2 3 latest ;;
    opensearchproject/opensearch-dashboards) echo 2.17.1 2.19.5 2.19.6 3.9.0 2 3 latest ;;
    library/rabbitmq) echo 3.12.14-management-alpine 3.13.6-management-alpine 3.13.7-management-alpine 4.2.9-management-alpine \
      4.3.6-management-alpine 4.3.6 3-management-alpine 3.12-management-alpine 3.13-management-alpine 4-management-alpine \
      4.3-management-alpine management-alpine ;;
    jc21/nginx-proxy-manager) echo 2.15.1 2.16.0 2 v3 latest ;;
    golithus/minio) echo RELEASE.2025-09-07T16-13-09Z RELEASE.2025-10-15T17-29-55Z latest ;;
    *) echo "UNHANDLED curl tags of $1" >> "$BAD" ;;
  esac
}
target() {
  case "$1:$2" in
    library/mongo:8|library/mongo:8.3) echo 8.3.11 ;;
    library/mongo:8.0) echo 8.0.32 ;;
    library/mongo:9|library/mongo:9.0|library/mongo:latest) echo 9.0.2 ;;
    opensearchproject/*:2) echo 2.19.6 ;;
    opensearchproject/*:3|opensearchproject/*:latest) echo 3.9.0 ;;
    library/rabbitmq:3-management-alpine|library/rabbitmq:3.13-management-alpine) echo 3.13.7-management-alpine ;;
    library/rabbitmq:4-management-alpine|library/rabbitmq:management-alpine) echo 4.3.6-management-alpine ;;
    jc21/nginx-proxy-manager:2|jc21/nginx-proxy-manager:latest) echo 2.16.0 ;;
    golithus/minio:latest) echo RELEASE.2025-10-15T17-29-55Z ;;
    *) echo "$2" ;;
  esac
}
# the Nginx Proxy Manager answers: reply CODE BODY
reply() { echo "$method $path $1" >> "$NS/calls"; done_with "$1" "$2"; }
field() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p" "$data" | head -n 1; }
next_id() { n=$(( $(cat "$NS/seq") + 1 )); echo "$n" > "$NS/seq"; printf '%s' "$n"; }
if [ -n "$resolve" ]; then
  d="${resolve%%:*}"
  echo "PROBE $url via $resolve" >> "$NS/calls"
  case "$resolve|$url" in
    "$d:443:127.0.0.1|https://$d/") want=https ;;
    "$d:80:127.0.0.1|http://$d/") want=http ;;
    *) echo "UNHANDLED curl probe $resolve $url" >> "$BAD"; exit 2 ;;
  esac
  for f in "$NS"/hosts/*; do
    [ -f "$f" ] || continue
    IFS='|' read -r hd hc hf hp hs < "$f"
    if [ "$hd" = "$d" ] && { [ "$want" = http ] || [ "$hc" != 0 ]; }; then printf '200'; exit 0; fi
  done
  printf '000'; exit 35
fi
case "$url" in
  http://localhost:*/) done_with 200 "" ;;
  https://github.com/docker/compose/releases/latest) done_with 200 "$(printf 'HTTP/2 302\r\nlocation: https://github.com/docker/compose/releases/tag/v5.6.0\r\n\r\n')" ;;
  https://raw.githubusercontent.com/*)
    if [ -f "$ST/new-installer.sh" ]; then done_with 200 "$(cat "$ST/new-installer.sh")"; fi
    done_with 404 "404" ;;
  https://hub.docker.com/v2/repositories/raynetgmbh/rayventory-catalog*/tags*)
    done_with 200 '{"count":5,"next":null,"results":[{"name":"latest","digest":"sha256:aaaa"},{"name":"stable","digest":"sha256:'"${SHIM_STABLE:-aaaa}"'"},{"name":"26.3.4789.148","digest":"sha256:aaaa"},{"name":"26.1.4475.137","digest":"sha256:bbbb"},{"name":"25.4.4191.133","digest":"sha256:cccc"}]}' ;;
  https://*/v2/)
    [ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\r\n\r\n' > "$( [ "$hdr" = - ] && echo /dev/stdout || echo "$hdr")"
    done_with 200 "" ;;
  https://*/tags/list*)
    repo="${url#https://*/v2/}"; repo="${repo%/tags/list*}"
    list=""; for t in $(tags_of "$repo"); do list="$list,\"$t\""; done
    [ -n "$hdr" ] && : > "$hdr"
    done_with 200 '{"name":"'"$repo"'","tags":['"${list#,}"']}' ;;
  https://*/manifests/*)
    repo="${url#https://*/v2/}"; repo="${repo%/manifests/*}"
    if [ "$head" = yes ]; then printf 'docker-content-digest: sha256:%s\r\n' "$(printf '%s:%s' "$repo" "$(target "$repo" "${url##*/}")" | sha256sum | cut -c1-12)"; exit 0; fi
    done_with 200 '{}' ;;
  http://127.0.0.1:81/api/*) path="/${url#http://127.0.0.1:81/api/}" ;;
  *) echo "UNHANDLED curl $method $url" >> "$BAD"; done_with 404 "" ;;
esac
# Nginx Proxy Manager 2.16 (strict: an unknown call is written to $BAD)
if [ "$method $path" != "GET /" ] && [ "$method $path" != "POST /tokens" ] && [ "$cfg" != "header = \"Authorization: Bearer $(cat "$NS/token" 2>/dev/null)\"" ]; then
  reply 401 '{"error":{"code":401,"message":"Unauthorized"}}'
fi
case "$method $path" in
  "GET /")
    setup=false; [ -f "$NS/user" ] && setup=true
    reply 200 "{\"status\":\"OK\",\"setup\":$setup,\"version\":{\"major\":2,\"minor\":16,\"revision\":0}}" ;;
  "POST /tokens")
    IFS='|' read -r ue up < "$NS/user" 2>/dev/null
    if [ -f "$NS/user" ] && [ "$(field identity | tr '[:upper:]' '[:lower:]')" = "$ue" ] && [ "$(field secret)" = "$up" ]; then
      echo "tok-$RANDOM" > "$NS/token"
      reply 200 "{\"token\":\"$(cat "$NS/token")\",\"expires\":\"2099-01-01T00:00:00.000Z\"}"
    fi
    reply 400 '{"error":{"code":400,"message":"Invalid email or password"}}' ;;
  "PUT /users/me")
    IFS='|' read -r ue up < "$NS/user"
    printf '%s|%s\n' "$(field email)" "$up" > "$NS/user"
    reply 200 "{\"id\":1,\"email\":\"$(field email)\"}" ;;
  "GET /nginx/proxy-hosts")
    items=""
    for f in "$NS"/hosts/*; do
      [ -f "$f" ] || continue
      IFS='|' read -r hd hc hf hp hs < "$f"
      items="$items${items:+,}{\"id\":${f##*/},\"domain_names\":[\"$hd\"],\"certificate_id\":$hc,\"forward_scheme\":\"http\",\"forward_host\":\"$hf\",\"forward_port\":$hp,\"ssl_forced\":$hs,\"enabled\":true}"
    done
    reply 200 "[$items]" ;;
  "POST /nginx/proxy-hosts")
    [ -n "${SHIM_NPM_HOST_FAIL:-}" ] && reply 500 '{"error":{"code":500,"message":"Internal Error"}}'
    d="$(sed -n 's/.*"domain_names":\["\([^"]*\)"\].*/\1/p' "$data")"
    id="$(next_id)"
    printf '%s|%s|%s|%s|%s\n' "$d" "$(field certificate_id)" "$(field forward_host)" "$(field forward_port)" "$(field ssl_forced)" > "$NS/hosts/$id"
    reply 201 "{\"id\":$id,\"domain_names\":[\"$d\"]}" ;;
  "GET /nginx/certificates")
    items=""
    for f in "$NS"/certs/*; do
      [ -f "$f" ] || continue
      IFS='|' read -r cd ce < "$f"
      items="$items${items:+,}{\"id\":${f##*/},\"provider\":\"letsencrypt\",\"nice_name\":\"$cd\",\"domain_names\":[\"$cd\"],\"expires_on\":\"$ce\"}"
    done
    reply 200 "[$items]" ;;
  "POST /nginx/certificates")
    d="$(sed -n 's/.*"domain_names":\["\([^"]*\)"\].*/\1/p' "$data")"
    id="$(next_id)"
    printf '%s|%s\n' "$d" "2099-01-01 00:00:00" > "$NS/certs/$id"
    reply 201 "{\"id\":$id,\"provider\":\"letsencrypt\",\"domain_names\":[\"$d\"],\"expires_on\":\"2099-01-01 00:00:00\"}" ;;
esac
echo "UNHANDLED curl $method $url" >> "$BAD"
exit 2
EOF

# Fake rootful Podman 5.7 with "podman compose": $ST/up = the containers exist (c1 mongo, c2 catalog-web,
# c3 worker-search, started from the folder in $ST/wd), $ST/net = the network of the project exists,
# $ST/vols = the data volumes inst_db_data and inst_minio_storage exist (minus those named in $ST/vols.rm),
# $ST/images = the local images (docker.io-qualified, as Podman stores them), $ST/catalog_tag and
# $ST/mongo_tag = the tags the containers run. With Nginx Proxy Manager in .env, "up" also starts it, and
# it creates its admin from INITIAL_ADMIN_EMAIL / INITIAL_ADMIN_PASSWORD (as version 2.13 and newer do).
# SHIM_FOREIGN_DIR: the containers of the project were started from that folder (SHIM_FOREIGN_IMAGE: the
# image of its catalog-web). SHIM_PODMAN_DOWN: Podman does not answer. SHIM_VOL_BUSY: data volumes cannot
# be removed. SHIM_CONFIG_FAIL: podman compose config fails (broken files). SHIM_SOCKET_DOWN: podman.socket
# is not active (systemctl). SHIM_ROOTLESS: Podman runs rootless. A call the fakes do not know is written
# to $BAD and fails.
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
    c1) echo "docker.io/library/mongo:$(cat "$ST/mongo_tag" 2>/dev/null || echo 8.0)" ;;
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
      inspect) [ $# -eq 3 ] || bad; vol_exists "$3" || { echo "Error: no such volume" >&2; exit 125; }; echo "[{\"Name\": \"$3\"}]" ;;
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
      inspect)
        if [ $# -eq 3 ]; then
          img_here "$3" || { echo "Error: $3: image not known" >&2; exit 125; }
          echo "[{\"Id\": \"$(img_id "$3")\"}]"
          exit 0
        fi
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
            if running; then
              case "$2" in
                mongo) echo c1 ;; catalog-web) echo c2 ;; worker-search) echo c3 ;;
                nginx-proxy-manager) [ "$(envval INSTALL_NGINX_PROXY_MANAGER)" = true ] && echo c4 ;;
              esac
            fi ;;
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
        printf '%s\n' "$PWD" > "$ST/wd"
        if [ "$(envval INSTALL_NGINX_PROXY_MANAGER)" = true ] && [ ! -f "$NS/user" ] && grep -q 'INITIAL_ADMIN_PASSWORD: "${NPM_ADMIN_PASSWORD}"' "$CF"; then
          e="$(envval NPM_ADMIN_EMAIL)"
          printf '%s|%s\n' "${e:-admin@example.com}" "$(envval NPM_ADMIN_PASSWORD)" > "$NS/user"
        fi ;;
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
# A Docker that is installed, whose daemon does not answer, and that holds nothing of the project: the
# installer, set to Podman, only looks whether this project's containers or volumes are there (one engine
# per server) and, in the list of engines, whether it is ready. Any other docker call is a leftover.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
case "$*" in
  --version) echo "Docker version 29.9.0, build 1a2b3c4" ;;
  "ps -aq --filter label=com.docker.compose.project="*|"volume ls -q --filter label=com.docker.compose.project="*) ;;
  "info --format {{range .SecurityOptions}}{{.}} {{end}}")
    echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
    exit 1 ;;
  *)
    echo "FORBIDDEN docker $*" | tee -a "$LOG" >> "$BAD"
    echo "docker: not part of these tests" >&2
    exit 99
    ;;
esac
EOF
# Docker 29 with the Compose plugin, ready (only on the PATH where a case puts $T/dbin first), as in
# run_docker_tests: rootless only in the security options of docker info, short image names in
# .Config.Image, .Name with a leading /, network ls -q prints IDs. Its state is in $ST/docker: up = the
# containers exist, vols = the volumes inst_db_data and inst_minio_storage, wd = the folder of the stack.
cat > "$T/dbin/docker" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
echo "docker $ARGS" >> "$LOG"
ST="$ST/docker"; mkdir -p "$ST"
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
VOLS="inst_db_data inst_minio_storage"
vol_exists() { [ -f "$ST/vols" ] && [[ " $VOLS " == *" $1 "* ]]; }
envval() { sed -n "s/^$1=//p" "${ENVF:-.env}" 2>/dev/null | tail -n 1 | tr -d '"'; }
rp() { local r=""; while [[ "$out" == *"$1"* ]]; do r="$r${out%%"$1"*}$2"; out="${out#*"$1"}"; done; out="$r$out"; }
match() {
  case "$2" in
    label=com.docker.compose.project=*) [ "${2#*project=}" = "$(proj)" ] ;;
    label=com.docker.compose.service=*) [ "${2#*service=}" = "$(svc_of "$1")" ] ;;
    *) bad ;;
  esac
}
case "$ARGS" in
  --version) echo "Docker version 29.9.0, build 1a2b3c4"; exit 0 ;;
  "compose version") echo "Docker Compose version v2.40.3"; exit 0 ;;
esac
case "${1:-}" in
  info)
    case "$ARGS" in
      info) echo "Client: Docker Engine - Community" ;;
      "info --format {{range .SecurityOptions}}{{.}} {{end}}") echo "name=apparmor name=seccomp,profile=builtin name=cgroupns " ;;
      "info --format {{.KernelVersion}}") echo "${SHIM_KERNEL:-6.8.0-generic}" ;;
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
      case "$out" in *'{{'*) bad ;; esac
      printf '%s\n' "$out"
    done
    exit "$rc" ;;
  volume)
    case "${2:-}" in
      ls)
        { [ $# -eq 5 ] && [ "$3" = -q ] && [ "$4" = --filter ]; } || bad
        case "$5" in label=com.docker.compose.project=*) ;; *) bad ;; esac
        if [ "${5#*project=}" = inst ]; then
          for v in $VOLS; do vol_exists "$v" && echo "$v"; done
        fi ;;
      *) bad ;;
    esac ;;
  network)
    case "${2:-}" in
      ls)
        { [ $# -eq 5 ] && [ "$3" = -q ] && [ "$4" = --filter ]; } || bad
        [ -f "$ST/net" ] && [ "${5#*project=}" = "$(proj)" ] && echo "9e8d7c6b5a40" ;;
      *) bad ;;
    esac ;;
  compose)
    shift
    ENVF=".env"; CF="docker-compose.yml"
    while [ $# -gt 0 ]; do case "$1" in -p) shift 2 ;; --env-file) ENVF="$2"; shift 2 ;; -f) CF="$2"; shift 2 ;; *) break ;; esac; done
    sub="${1:-}"; [ $# -gt 0 ] && shift
    case "$sub" in
      config)
        case "$*" in
          --services) printf '%s\n' mongo catalog-web worker-search ;;
          --volumes) printf '%s\n' db_data minio_storage ;;
          --quiet|"") ;;
          *) bad ;;
        esac ;;
      ps)
        case "$*" in
          "-q "*)
            [ $# -eq 2 ] || bad
            if running; then case "$2" in mongo) echo a1b2c3d4e5f6 ;; catalog-web) echo b2c3d4e5f6a7 ;; worker-search) echo c3d4e5f6a7b8 ;; esac; fi ;;
          "--services --filter status=running") running && printf '%s\n' mongo catalog-web worker-search ;;
          "") echo "NAME STATUS"; running && printf '%s\n' "inst-mongo-1 Up" "inst-catalog-web-1 Up" "inst-worker-search-1 Up" ;;
          *) bad ;;
        esac ;;
      pull|logs) ;;
      up)
        [ "$*" = "-d --remove-orphans" ] || bad
        touch "$ST/up" "$ST/net" "$ST/vols"
        envval CATALOG_IMAGE | sed 's/.*://' > "$ST/catalog_tag"
        envval MONGO_TAG > "$ST/mongo_tag"
        printf '%s\n' "$PWD" > "$ST/wd" ;;
      *) bad ;;
    esac ;;
  *) bad ;;
esac
exit 0
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-active --quiet podman.socket") [ -z "${SHIM_SOCKET_DOWN:-}" ] ;;
  "is-enabled podman-restart.service") echo enabled ;;
  "is-enabled docker.service") echo enabled ;;
  *) echo "UNHANDLED systemctl $*" | tee -a "$LOG" >> "$BAD"; exit 1 ;;
esac
EOF
REAL_UNAME="$(command -v uname)"
cat > "$T/bin/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-r" ]; then echo "\${SHIM_KERNEL:-6.8.0-generic}"; else exec "$REAL_UNAME" "\$@"; fi
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${SHIM_TZ:-Europe/Berlin}"\n' > "$T/bin/timedatectl"
# DNS, the addresses of this server and the ports in use
cat > "$T/bin/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ahostsv4|ahostsv6) ;;
  *) echo "UNHANDLED getent $*" >> "$BAD"; exit 1 ;;
esac
[ -f "$DNS/$2" ] || exit 2
found=0
while read -r ip; do
  if [ "$1" = ahostsv4 ] && [[ "$ip" != *:* ]]; then
    printf '%-15s STREAM %s\n' "$ip" "$2"; found=1
  elif [ "$1" = ahostsv6 ]; then
    if [[ "$ip" == *:* ]]; then printf '%s STREAM %s\n' "$ip" "$2"; else printf '::ffff:%s STREAM %s\n' "$ip" "$2"; fi
    found=1
  fi
done < "$DNS/$2"
[ "$found" = 1 ] || exit 2
EOF
REAL_HOSTNAME="$(command -v hostname)"
printf '#!/usr/bin/env bash
if [ "${1:-}" = "-I" ]; then echo "$LOCAL_IPS "; else exec "%s" "$@"; fi
' "$REAL_HOSTNAME" > "$T/bin/hostname"
cat > "$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-o addr show") echo "1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever" ;;
  *) echo "UNHANDLED ip $*" >> "$BAD"; exit 1 ;;
esac
EOF
cat > "$T/bin/ss" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  -ltn)
    echo "State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
    for p in $LISTEN_PORTS; do printf 'LISTEN 0      511    0.0.0.0:%s        0.0.0.0:*\n' "$p"; done ;;
  *) echo "UNHANDLED ss $*" >> "$BAD"; exit 1 ;;
esac
EOF
# id -u says 0 (only where a case puts $T/rootbin first): the engine setup then asks before it runs anything
mkdir -p "$T/rootbin"
printf '#!/usr/bin/env bash\nif [ "$*" = "-u" ]; then echo 0; else exec %s "$@"; fi\n' "$(command -v id)" > "$T/rootbin/id"
chmod +x "$T/bin/"* "$T/dbin/"* "$T/rootbin/"*
# NOPPATH: no Podman at all (a CI runner's own one left out too), the ready Docker 29 and the other fakes
mkdir -p "$T/nopod"
for f in "$T/bin/"*; do [ "${f##*/}" = podman ] || ln -s "$f" "$T/nopod/${f##*/}"; done
sysdirs="$PATH"
if command -v podman >/dev/null 2>&1; then
  mkdir -p "$T/sys"
  IFS=: read -r -a dirs <<< "$sysdirs"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      [ "${f##*/}" = podman ] || [ -e "$T/sys/${f##*/}" ] || ln -s "$f" "$T/sys/${f##*/}" 2>/dev/null || true
    done
  done
  sysdirs="$T/sys"
fi
NOPPATH="$T/dbin:$T/nopod:$sysdirs"
export PATH="$T/bin:$PATH" RN1_COMPOSE_PROVIDER="$T/bin/docker-compose" COLUMNS=120
DPATH="$T/dbin:$PATH"
# the calls that change containers, networks, volumes or images
MUTATING='compose.* (down|up)|^podman (rm|volume rm|network rm|image rm) '

D="$T/inst"
I="$D/rn1-technology-catalog-installer.sh"
fresh() {
  rm -rf "$D" "$ST"/* "$NS"; mkdir -p "$D" "$NS/hosts" "$NS/certs"; cp "$NEW" "$I"
  sed -i "s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES=\"false\"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT=\"10\"/; ${1:-}" "$I"
  echo 0 > "$NS/seq"; : > "$NS/calls"; rm -f "$DNS"/*
  LISTEN_PORTS=""
  : > "$LOG"
}
installed() {
  fresh
  (cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  touch "$ST/up" "$ST/net" "$ST/vols"; echo "25.4.4191.133" > "$ST/catalog_tag"; echo 8.0 > "$ST/mongo_tag"; echo "$D" > "$ST/wd"
  printf '%s\n' docker.io/library/mongo:8.0 docker.io/raynetgmbh/rayventory-catalog:25.4.4191.133 docker.io/raynetgmbh/rayventory-catalog-worker:25.4.4191.133 > "$ST/images"
  : > "$LOG"
}
# setting NAME -> its value in the settings section of the installer
setting() { sed -n "/^# CONFIGURE ONLY THIS SECTION/,/^# DO NOT CHANGE ANYTHING BELOW/s/^$1=\"\(.*\)\"$/\1/p" "$I"; }
envv() { sed -n "s/^$1=//p" "$D/.env"; }
dns() { local n="$1"; shift; printf '%s\n' "$@" > "$DNS/$n"; }
# after "Stopped.": the menu again
back_in_menu() { sed -n '/Stopped. I starts it again/,$p' <<< "$out" | grep -q "START HERE"; }
RECOMMENDED='^CATALOG_VERSION="26.3.4789.148"$|^MONGO_TAG="8.0.32"$|^OPENSEARCH_TAG="2.19.6"$|^OPENSEARCH_DASHBOARDS_TAG="2.19.6"$|^RABBITMQ_TAG="3.13.7-management-alpine"$|^MINIO_TAG="RELEASE.2025-10-15T17-29-55Z"$'

# 1. The plain menu starts with the guided tasks and names them again above the prompt; without a
# terminal the new installation does not start by itself
fresh
out="$(printf '0\n' | bash "$I" menu 2>&1)"
check "menu: START HERE with I, U and R first" 'grep -q "START HERE" <<< "$out" && grep -q "I) INSTALL" <<< "$out" && grep -q "U) UPDATE" <<< "$out" && grep -q "R) REMOVE" <<< "$out" && [ "$(grep -n "START HERE" <<< "$out" | cut -d: -f1)" -lt "$(grep -n " SETUP" <<< "$out" | cut -d: -f1)" ]'
check "menu: the tasks named above the prompt" 'tail -n 2 <<< "$out" | grep -q "I install . U update . R remove"'
check "menu: the I card of a new folder" 'grep -q "New installation, step by step" <<< "$out"'
check "menu without a terminal: no automatic start of the new installation" '! grep -q "New installation. A few questions" <<< "$out" && ! grep -q "Install .* step" <<< "$out" && [ ! -e "$D/.setup-later" ]'
check "help: guided tasks explained, 7 no longer the start" 'out2="$(printf "h\n\n0\n" | bash "$I" menu 2>&1)"; grep -q "START HERE - GUIDED TASKS" <<< "$out2" && ! grep -q "Start here on a new server" <<< "$out2" && grep -q "engine, domain name, Nginx Proxy Manager" <<< "$out2"'

# 2. New installation with Enter only: Podman, no domain, no Nginx Proxy Manager, the recommended versions,
# files written, stack started with a health check, data later, summary
fresh
out="$(printf 'i\n\n\n\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
check "install: all seven steps shown" '( for s in 1 2 3 4 5 6 7; do grep -q "Install .* step $s of 7" <<< "$out" || exit 1; done )'
check "install: the engines listed, Podman ready and the default" 'grep -Eq "1  Podman +[^ ]+ ready" <<< "$out" && grep -Eq "2  Docker Engine +installed - the setup completes it" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = podman ] && grep -q "Podman is ready" <<< "$out"'
check "install: no domain - the address of the server" 'grep -q "Catalog then runs on http://192.0.2.10:8080.$" <<< "$out" && [ -z "$(setting CATALOG_DOMAIN)" ] && grep -q "The Catalog: http://192.0.2.10:8080$" <<< "$out"'
check "install: Nginx Proxy Manager - no without a domain (the default)" 'grep -q "Without a domain name it only forwards http://192.0.2.10 to the Catalog" <<< "$out" && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ] && grep -qx "INSTALL_NGINX_PROXY_MANAGER=false" "$D/.env"'
check "install: Enter takes the recommended versions (Catalog the newest, the others inside their series)" '[ "$(grep -Ec "$RECOMMENDED" "$I")" -eq 6 ] && grep -q "recommended" <<< "$out"'
check "install: one summary box before the start" 'grep -q "Summary" <<< "$out" && grep -Eq "Engine +Podman" <<< "$out" && grep -Eq "Address +http://192.0.2.10:8080" <<< "$out" && ! grep -Eq "Direct +http" <<< "$out" && grep -Eq "Proxy +none - Catalog Web answers directly" <<< "$out" && grep -Eq "Versions +Catalog 26.3.4789.148 . MongoDB 8.0.32 . OpenSearch 2.19.6" <<< "$out" && grep -Eq "RabbitMQ 3.13.7 . MinIO RELEASE.2025-10-15T17-29-55Z" <<< "$out" && grep -Eq "Folder +$D" <<< "$out"'
check "install: the check is quiet when it passes" 'grep -q "All required checks passed" <<< "$out" && ! grep -q "Checking prerequisites" <<< "$out" && ! grep -q "OK Podman 5.7.0" <<< "$out"'
check "install: files generated with the versions, stack started" '[ -f "$D/.env" ] && [ -f "$D/docker-compose.yml" ] && grep -qx "MONGO_TAG=8.0.32" "$D/.env" && grep -q "^podman compose .*--env-file .env -f docker-compose.yml up -d --remove-orphans$" "$LOG"'
check "install: after the start straight on to the data (no question in between)" '! grep -q "Continue with the catalog data" <<< "$out" && grep -q "Install .* step 6 of 7" <<< "$out"'
check "install: health check, addresses once, summary" 'grep -q "Health check" <<< "$out" && grep -q "The Catalog is installed" <<< "$out" && [ "$(grep -c "Catalog Web (direct)" <<< "$out")" -eq 1 ] && grep -q "http://192.0.2.10:8080" <<< "$out"'
check "install: no data yet named, then the full menu" 'grep -q "The Catalog has no data yet" <<< "$out" && grep -q "Options: 14 passwords . 15 addresses . 24 domain and HTTPS . 9 status" <<< "$out" && grep -q "Next: the full menu - every option (H: help)" <<< "$out" && sed -n "/Next: the full menu/,\$p" <<< "$out" | grep -q "START HERE"'
check "install: no Nginx Proxy Manager set up without a domain" '! grep -q "Setting up Nginx Proxy Manager" <<< "$out" && [ ! -s "$NS/calls" ]'

# 3. Install on a folder that is already installed: repair, data, update or remove
out="$(printf 'i\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: existing installation found, cancel changes nothing" 'grep -q "This folder already has an installation" <<< "$out" && grep -q "Continue with the catalog data" <<< "$out" && grep -q "Cancelled" <<< "$out"'
out="$(printf 'i\n2\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: continues with the catalog data (step 5)" 'grep -q "Install .* step 5 of 6" <<< "$out" && ! grep -q "Install .* step 3 of 6" <<< "$out"'

# 4. Repair keeps the installed version (an upgrade belongs to U with backup and rollback)
installed
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$I"
out="$(printf 'i\n1\ny\ny\n\ny\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "repair: version of the installation kept" 'grep -q "the repair keeps 25.4.4191.133" <<< "$out" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$I" && grep -q "^CATALOG_IMAGE=.*:25.4.4191.133$" "$D/.env"'
check "repair: the steps of a repair (check, settings, files, start)" 'grep -q "Install .* step 3 of 6" <<< "$out" && grep -q "Install .* step 4 of 6" <<< "$out" && ! grep -q "of 7" <<< "$out"'
# 0 at the time zone question stops the repair; outside the guided tasks (option 2) 0 is a no, as before
TZDATA="no"
if [ -f /usr/share/zoneinfo/America/New_York ] && [ -f /usr/share/zoneinfo/Europe/Berlin ]; then TZDATA="yes"; fi
if [ "$TZDATA" = "yes" ]; then
  installed
  before="$(cksum < "$D/.env")"
  out="$(printf 'i\n1\ny\ny\n\n0\n\n0\n' | SHIM_TZ=America/New_York bash "$I" menu 2>&1)"
  check "repair: 0 at the time zone - stopped, TZ and the files as they were" 'grep -q "This server runs in the time zone America/New_York" <<< "$out" && back_in_menu && [ "$(setting TZ)" = Europe/Berlin ] && [ ! -e "$D/.timezone-kept" ] && [ "$(cksum < "$D/.env")" = "$before" ]'
  out="$(printf '2\n1\n0\n\n0\n' | SHIM_TZ=America/New_York bash "$I" menu 2>&1)"
  check "option 2: 0 at the time zone is a no - kept, not asked again, the files written" 'grep -q "TZ stays Europe/Berlin. This is not asked again" <<< "$out" && ! grep -q "Stopped" <<< "$out" && [ -f "$D/.timezone-kept" ] && [ "$(setting TZ)" = Europe/Berlin ] && grep -q "Created .env and docker-compose.yml" <<< "$out"'
fi

# 5. The new installation stops when a step is declined or the input ends; nothing is half written
fresh
out="$(printf 'i\n\n\n\n\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "install: declined before the files - nothing written" '[ ! -f "$D/.env" ] && [ ! -f "$D/docker-compose.yml" ] && grep -q "Stopped. I starts it again" <<< "$out" && ! grep -q "compose.* up" "$LOG"'
check "install: the answers before are saved (it starts again with them)" '[ "$(setting MONGO_TAG)" = 8.0.32 ] && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ]'
fresh
printf 'i\n\ncatalog.example.com\n\n' | bash "$I" menu >/dev/null 2>&1
check "install: end of input at a question - the answers before saved, nothing else" '[ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = true ] && [ "$(setting MONGO_TAG)" = 8.0 ] && [ ! -f "$D/.env" ]'
# run again: the saved answers are the defaults (the domain not in DNS: Enter keeps it)
out="$(printf 'i\n\n\n\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: the saved domain is the default (Enter keeps it), so Nginx Proxy Manager defaults to yes" '[ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && grep -q "Let.s Encrypt needs a real e-mail address" <<< "$out" && back_in_menu'
sed -i 's/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/' "$I"
out="$(printf 'i\n\n\n\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: a saved no for Nginx Proxy Manager is the default while the domain stays" '[ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ] && ! grep -q "Let.s Encrypt needs a real e-mail address" <<< "$out" && grep -q "Install .* step 4 of 7" <<< "$out" && back_in_menu'
out="$(printf 'i\n\n-\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: - removes the domain" '[ -z "$(setting CATALOG_DOMAIN)" ] && [ "$(setting BASEURL)" = "http://catalog-web" ]'
out="$(printf 'i\n\ncatalog.example.com\n\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: a new domain - Nginx Proxy Manager defaults to yes again" '[ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && grep -q "Let.s Encrypt needs a real e-mail address" <<< "$out" && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ]'

# 5b. 0 at each question stops the task and returns to the menu; only the answers before are kept
fresh
before="$(cksum < "$I")"
out="$(printf 'i\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the engine: nothing changed, back in the menu, the next start opens the menu" 'grep -q "Stopped. I starts it again" <<< "$out" && back_in_menu && [ "$(cksum < "$I")" = "$before" ] && [ -f "$D/.setup-later" ] && grep -q "The next start opens the menu directly" <<< "$out"'
fresh 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=""/'
out="$(printf 'i\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the domain: the engine kept, nothing else" 'back_in_menu && [ "$(setting CONTAINER_ENGINE)" = podman ] && [ -z "$(setting CATALOG_DOMAIN)" ] && [ ! -e "$D/.setup-later" ]'
fresh
out="$(printf 'i\n\ncatalog.example.com\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the question about a name not in DNS: the domain not saved" 'back_in_menu && grep -q "catalog.example.com is not in DNS yet" <<< "$out" && [ -z "$(setting CATALOG_DOMAIN)" ]'
fresh
out="$(printf 'i\n\ncatalog.example.com\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the proxy: the domain kept, Nginx Proxy Manager unchanged" 'back_in_menu && [ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = true ] && [ -z "$(setting NPM_ADMIN_EMAIL)" ]'
fresh
out="$(printf 'i\n\ncatalog.example.com\n\nn\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the versions: the proxy answer kept, the versions unchanged" 'back_in_menu && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ] && [ "$(setting BASEURL)" = "http://catalog.example.com:8080" ] && [ "$(setting MONGO_TAG)" = 8.0 ] && [ "$(setting CATALOG_VERSION)" = 25.4.4191.133 ]'
fresh 's/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/'
out="$(printf 'i\n\ncatalog.example.com\n\ny\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the e-mail address: Nginx Proxy Manager and the address not saved" 'back_in_menu && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ] && [ -z "$(setting NPM_ADMIN_EMAIL)" ] && [ "$(setting BASEURL)" = "http://catalog.example.com:8080" ]'
fresh
out="$(printf 'i\n\n\n\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the start: the versions kept, no files" 'back_in_menu && [ "$(setting MONGO_TAG)" = 8.0.32 ] && [ ! -f "$D/.env" ] && ! grep -Eq "$MUTATING" "$LOG"'
if [ "$TZDATA" = "yes" ]; then
  fresh
  out="$(printf 'i\n\n\n\n\n0\n\n0\n' | SHIM_TZ=America/New_York bash "$I" menu 2>&1)"
  check "stop at the time zone: TZ unchanged and not marked as kept, no files" 'grep -q "This server runs in the time zone America/New_York" <<< "$out" && back_in_menu && [ "$(setting TZ)" = Europe/Berlin ] && [ ! -e "$D/.timezone-kept" ] && [ ! -f "$D/.env" ] && [ "$(setting MONGO_TAG)" = 8.0.32 ]'
fi
fresh 's/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="0900"/'
out="$(printf 'i\n\n\ny\n\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "failed check, n at Continue anyway: stopped, no files" 'grep -q "1 problem(s) found" <<< "$out" && back_in_menu && [ ! -f "$D/.env" ] && ! grep -q "The first start pulls the images" <<< "$out"'
fresh
out="$(printf 'i\n\n\n\n\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "0 at the data step means later: installed, the summary shown, the marker gone" '[ -f "$D/.env" ] && grep -q "compose.* up -d" "$LOG" && grep -q "Install .* step 7 of 7" <<< "$out" && grep -q "The Catalog has no data yet" <<< "$out" && ! grep -q "Stopped. I starts it again" <<< "$out"'

# 6. Ports in use: Nginx Proxy Manager defaults to no; Catalog Web gets another port (a port of another
# setting is refused at once)
fresh
LISTEN_PORTS="443"
dns catalog.example.com 192.0.2.10
out="$(printf 'i\n\ncatalog.example.com\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "ports in use: named, Nginx Proxy Manager defaults to no even with a domain" 'grep -q "Port 443 is in use on this server: Nginx Proxy Manager" <<< "$out" && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ] && [ "$(setting BASEURL)" = "http://catalog.example.com:8080" ]'
fresh
LISTEN_PORTS="80 443 81"
out="$(printf 'i\n\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "ports in use: several named in one sentence" 'grep -q "Ports 80, 443 and 81 are in use on this server: Nginx Proxy Manager" <<< "$out" && grep -q "cannot start while another program listens there" <<< "$out"'
fresh
LISTEN_PORTS="8080"
out="$(printf 'i\n\n\ny\n80\n\nn\n9090\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "port of Catalog Web in use: asked again" 'grep -q "Port 8080 (Catalog Web) is in use on this server - choose another" <<< "$out" && grep -q "Port 80 is already set for NPM_HTTP_PORT" <<< "$out" && grep -q "Port 8080 is already in use on this server" <<< "$out" && [ "$(setting CATALOG_WEB_PORT)" = 9090 ] && grep -q "The Catalog: http://192.0.2.10:9090" <<< "$out"'
# data volumes of an earlier installation (with the passwords in a backup of .env): the port is still checked
fresh
LISTEN_PORTS="8080"
touch "$ST/vols"; echo "MONGO_INITDB_ROOT_PASSWORD=x" > "$D/.env.bak-20261001-120000"
out="$(printf 'i\n\n\n\n\nn\n9090\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "port of Catalog Web in use, volumes left: Enter does not keep the busy port" 'grep -Eq "1  Podman +[^ ]+ holds the data of this folder" <<< "$out" && grep -q "Port 8080 is already in use on this server" <<< "$out" && [ "$(setting CATALOG_WEB_PORT)" = 9090 ]'

# 7. A step that fails stops the task (no start with broken files)
fresh 's/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="0900"/'
out="$(printf 'i\n\n\ny\n\ny\n\n\n0\n' | bash "$I" menu 2>&1)"
check "install: failed check shown in full, continued anyway, failed files step stops before the start" 'grep -q "1 problem(s) found" <<< "$out" && grep -q "OK Podman runs rootful" <<< "$out" && grep -q "The first start pulls the images" <<< "$out" && grep -q "The files could not be written" <<< "$out" && ! grep -q "compose.* up" "$LOG" && ! grep -q "Install .* step 6 of 7" <<< "$out"'

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
out="$(printf 'i\n\n\n\n\nn\n\n0\n' | SHIM_KERNEL=7.0.0-15-generic bash "$I" menu 2>&1)"
check "install: MongoDB 8.0 kept on kernel 7.0.0, the workaround named, the check passes" 'grep -q "starts with GLIBC_TUNABLES=glibc.pthread.rseq=1" <<< "$out" && grep -q "^MONGO_TAG=\"8.0.32\"$" "$I" && ! grep -q "Use MongoDB 7.0 instead" <<< "$out" && grep -q "All required checks passed" <<< "$out" && ! grep -q "lack the workaround" <<< "$out"'
GLIBC_LINE='      GLIBC_TUNABLES: "${MONGO_GLIBC_TUNABLES:-glibc.pthread.rseq=1}"'
(cd "$D" && SHIM_KERNEL=7.0.0-15-generic bash "$I" generate </dev/null >/dev/null 2>&1)
check "generate on kernel 7.0.0: GLIBC_TUNABLES for mongo in compose and .env" 'grep -qxF "$GLIBC_LINE" "$D/docker-compose.yml" && grep -qx "MONGO_GLIBC_TUNABLES=glibc.pthread.rseq=1" "$D/.env" && [ "$(sed -n "/^  mongo:/,/^  minio:/p" "$D/docker-compose.yml" | grep -c GLIBC_TUNABLES)" -eq 1 ]'
out="$(cd "$D" && SHIM_KERNEL=7.0.0-15-generic bash "$I" check </dev/null 2>&1)"
check "check on kernel 7.0.0 with the workaround: no MongoDB problem" '! grep -q "refuses to start" <<< "$out" && grep -q "starts with GLIBC_TUNABLES=glibc.pthread.rseq=1" <<< "$out"'
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0"/' "$I"
(cd "$D" && SHIM_KERNEL=7.0.0-15-generic bash "$I" generate </dev/null >/dev/null 2>&1); rc=$?
check "MongoDB 7.0 on kernel 7.0.0: the workaround goes away (not needed)" '[ "$rc" -eq 0 ] && grep -qx "MONGO_TAG=7.0" "$D/.env" && ! grep -q MONGO_GLIBC_TUNABLES "$D/.env" && ! grep -q GLIBC_TUNABLES "$D/docker-compose.yml"'
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="8.0"/' "$I"
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
check "install: installation of another folder found, take over offered" 'grep -q "A Catalog installation already exists on this server: $OTHER" <<< "$out" && grep -q "Take it over" <<< "$out" && ! grep -q "This folder already has an installation" <<< "$out" && ! grep -q "The container engine runs" <<< "$out"'
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
touch "$D/.setup-later"
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: compose down, then the data volumes one by one" 'grep -q "^podman compose .*--env-file .env -f docker-compose.yml down --remove-orphans$" "$LOG" && grep -q "^podman volume rm inst_db_data$" "$LOG" && grep -q "^podman volume rm inst_minio_storage$" "$LOG" && [ ! -f "$ST/vols" ]'
check "remove: images of the stack removed once each, by their qualified names" '[ "$(grep -c "^podman image rm docker.io/library/mongo:8\.0$" "$LOG")" -eq 1 ] && [ "$(grep -c "^podman image rm docker.io/raynetgmbh/rayventory-catalog:25.4.4191.133$" "$LOG")" -eq 1 ] && [ "$(grep -c "^podman image rm " "$LOG")" -eq 3 ] && [ ! -s "$ST/images" ]'
check "remove: generated files gone, snapshots and installer kept" '[ ! -f "$D/.env" ] && [ ! -f "$D/docker-compose.yml" ] && [ ! -e "$D/.jobs" ] && [ ! -e "$D/.setup-later" ] && [ -f "$D/snapshots/a.tar.gz" ] && [ -f "$I" ]'
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
check "remove: images found without containers" 'grep -q "Images of the stack  *3" <<< "$out" && grep -q "^podman image rm docker.io/library/mongo:8\.0$" "$LOG"'
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

# 22. Docker: chosen in the list, set up, the files written and the stack started in Docker
fresh 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=""/'
out="$(printf 'i\n2\n\n\n\n\n\n\n0\n' | PATH="$DPATH" bash "$I" menu 2>&1)"
check "docker: both engines ready, Podman the default, Docker chosen" 'grep -Eq "1  Podman +[^ ]+ ready" <<< "$out" && grep -Eq "2  Docker Engine +[^ ]+ ready" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "Docker is ready" <<< "$out"'
check "docker: files written, docker compose up, the stack runs in Docker" '[ -f "$D/.env" ] && grep -q "^docker compose --env-file .env -f docker-compose.yml up -d --remove-orphans$" "$LOG" && [ -f "$ST/docker/up" ] && [ ! -f "$ST/up" ] && ! grep -q "^podman compose" "$LOG" && grep -q "The Catalog is installed" <<< "$out" && grep -q "DOCKER-USER" <<< "$out"'
check "docker: the summary names Docker, the quiet check passed" 'grep -Eq "Engine +Docker" <<< "$out" && grep -q "All required checks passed" <<< "$out"'

# 22b. Docker ready, Podman not installed, CONTAINER_ENGINE empty: Enter takes the Docker that is there
fresh 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=""/'
out="$(printf 'i\n\n0\n\n0\n' | PATH="$NOPPATH" RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "docker ready, Podman missing: Enter takes Docker, Podman is not installed next to it" 'grep -Eq "^   (1  Podman +not installed - the setup installs it|-  Podman )" <<< "$out" && grep -Eq "2  Docker Engine +[^ ]+ ready" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "Docker is ready" <<< "$out" && ! grep -q "Run these commands" <<< "$out" && grep -q "Install .* step 2 of 7" <<< "$out"'
mkdir -p "$T/pick"; sed 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=""/' "$NEW" > "$T/pick/inst.sh"
pick() { (cd "$T/pick" && bash inst.sh __wiz_engine_pick "$@" </dev/null 2>/dev/null); }
check "the default engine: a ready one first, Podman when both are, never the one whose setup failed" '[ "$(PATH="$NOPPATH" RN1_SYSTEMD_DIR="$T" pick)" = docker ] && [ "$(PATH="$DPATH" pick)" = podman ] && [ "$(PATH="$DPATH" pick podman)" = docker ] && [ "$(SHIM_ROOTLESS=true PATH="$DPATH" pick)" = docker ]'

# 23. The data of this folder in one engine: only that engine can be chosen, and it is the default (the
# passwords of the data are in a backup of .env)
fresh
mkdir -p "$ST/docker"; touch "$ST/docker/vols"; echo "MONGO_INITDB_ROOT_PASSWORD=x" > "$D/.env.bak-20261001-120000"
out="$(printf 'i\n1\n\n0\n\n0\n' | PATH="$DPATH" bash "$I" menu 2>&1)"
check "engine locked: the engine with the data is the default, the other one says why" 'grep -Eq "2  Docker Engine +[^ ]+ holds the data of this folder" <<< "$out" && grep -Eq "^   -  Podman +The containers or data volumes of this installation are in Docker" <<< "$out"'
check "engine locked: the other engine is refused, Enter takes the one with the data" 'grep -q "Podman cannot be used here: The containers or data volumes" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = docker ]'

# 23b. Data volumes, but no .env and no backup of it: new passwords would not open them - nothing is asked
fresh
touch "$ST/vols"
before="$(cksum < "$I")"
out="$(printf 'i\n\n0\n' | bash "$I" menu 2>&1)"
check "volumes without their passwords: named before any question, nothing changed" 'grep -q "Data volumes of project \"inst\" are in Podman, but this folder has no .env" <<< "$out" && grep -q "not needed. Nothing was changed." <<< "$out" && ! grep -q "The container engine runs" <<< "$out" && [ "$(cksum < "$I")" = "$before" ] && [ ! -e "$D/.setup-later" ] && ! grep -Eq "$MUTATING" "$LOG"'

# 23c. The containers of this folder are in the engine the Engine step takes (CONTAINER_ENGINE named
# another one): the repair takes over instead of a new installation
fresh
mkdir -p "$ST/docker"; touch "$ST/docker/up" "$ST/docker/vols"; echo "$D" > "$ST/docker/wd"
echo "MONGO_INITDB_ROOT_PASSWORD=x" > "$D/.env.bak-20261001-120000"
out="$(printf 'i\n\n0\n\n0\n' | PATH="$DPATH" bash "$I" menu 2>&1)"
check "containers found by the Engine step: the repair menu, no new installation" 'grep -Eq "2  Docker Engine +[^ ]+ holds the data of this folder" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "This folder already has an installation" <<< "$out" && grep -q "Install .* step 1 of 6" <<< "$out" && ! grep -q "Install .* step 2 of 7" <<< "$out"'

# 24. The engine is not ready and is not set up: try again, another engine, or stop
fresh
if [ "$(id -u)" -eq 0 ]; then RUNQ='n\n'; else RUNQ=''; fi
out="$(printf "i\n\n${RUNQ}2\n2\n0\n\n0\n" | PATH="$DPATH" SHIM_ROOTLESS=true RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "engine not set up: try again, another engine or stop - then another one chosen" 'grep -Eq "1  Podman +installed - the setup completes it" <<< "$out" && grep -q "Podman is not ready - the Catalog cannot start without it" <<< "$out" && grep -q "Choose another engine" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "Install .* step 2 of 7" <<< "$out"'
if [ "$(id -u)" -ne 0 ]; then
  check "engine not set up: rootless Podman as a normal user - no try again, start it as root" 'grep -q "Rootful Podman needs root: start rn1-technology-catalog-installer.sh again with sudo." <<< "$out" && ! grep -q "Try again" <<< "$out"'
fi
fresh
out="$(printf "i\n\n${RUNQ}2\n\n0\n\n0\n" | PATH="$DPATH" SHIM_ROOTLESS=true RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "engine not set up, choose another: Enter takes another engine than the one that failed" '[ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "Docker is ready" <<< "$out" && grep -q "Install .* step 2 of 7" <<< "$out"'
fresh
out="$(printf "i\n\n${RUNQ}x\n3\n0\n\n0\n" | SHIM_ROOTLESS=true RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "engine not set up: an invalid answer is asked again, 0 stops (not the first question)" 'grep -q "Invalid choice: x" <<< "$out" && grep -q "Invalid choice: 3" <<< "$out" && back_in_menu && [ ! -e "$D/.setup-later" ] && ! grep -q "Install .* step 2 of 7" <<< "$out"'
# as root the setup shows its commands and asks: 0 there stops the task at once
fresh
out="$(printf 'i\n\n0\n\n0\n' | PATH="$T/rootbin:$PATH" SHIM_ROOTLESS=true RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "engine setup: 0 at its own question stops the task at once" 'back_in_menu && ! grep -q "Choose another engine" <<< "$out" && ! grep -q "Install .* step 2 of 7" <<< "$out" && ! grep -Eq "^systemctl (enable|start)" "$LOG"'

# 25. A domain with Nginx Proxy Manager and an e-mail address: proxy host and certificate, HTTPS
if [ "$NPM_OK" = "yes" ]; then
  fresh
  dns catalog.example.com 192.0.2.10
  out="$(printf 'i\n\nhttps://Catalog.Example.com/x\n\nit@mail.example.net\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
  check "domain: the URL cut down to its name, the DNS checked and named" '[ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && grep -q "catalog.example.com points to this server (192.0.2.10)" <<< "$out"'
  check "domain: Nginx Proxy Manager explained and the default with a domain" 'grep -q "With it the Catalog answers on https://catalog.example.com with a free$" <<< "$out" && grep -q "Let.s Encrypt certificate, set up automatically." <<< "$out" && grep -q "Let.s Encrypt needs a real e-mail address" <<< "$out"'
  check "domain: the settings saved together, BASEURL https" '[ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = true ] && [ "$(setting NPM_ADMIN_EMAIL)" = it@mail.example.net ] && [ "$(setting BASEURL)" = "https://catalog.example.com" ] && grep -qx "BASEURL=https://catalog.example.com" "$D/.env"'
  check "domain: the address line and the summary say https" 'grep -q "The Catalog: https://catalog.example.com . http://192.0.2.10:8080" <<< "$out" && grep -Eq "Address +https://catalog.example.com " <<< "$out" && grep -Eq "Direct +http://192.0.2.10:8080 " <<< "$out" && grep -Eq "Proxy +Nginx Proxy Manager 2.16.0 \(admin page: port 81\)" <<< "$out" && grep -Eq "HTTPS +Let.s Encrypt certificate at the start \(it@mail.example.net\)" <<< "$out"'
  check "domain: after the start a certificate and the proxy host to catalog-web with HTTPS forced" '[ "$(ls "$NS/certs" | wc -l)" -eq 1 ] && grep -qx "catalog.example.com|1|catalog-web|80|true" "$NS/hosts/2" && grep -q "Logged in to Nginx Proxy Manager 2.16.0 as it@mail.example.net" <<< "$out"'
  check "domain: outcome https, shown at the end" 'grep -q "The Catalog: https://catalog.example.com - Nginx Proxy Manager renews the certificate" <<< "$out" && [ "$(cat "$D/.domain-certificate")" = catalog.example.com ] && grep -Eq "Catalog Web +https://catalog.example.com$" <<< "$out"'

  # 25b. The summary at 80 columns: one value per row, nothing cut off
  fresh
  dns catalog.example.com 192.0.2.10
  out="$(printf 'i\n\ncatalog.example.com\n\nit@mail.example.net\n\nn\n\n0\n' | COLUMNS=80 bash "$I" menu 2>&1)"
  check "summary at 80 columns: nothing cut off" 'grep -Eq "HTTPS +Let.s Encrypt certificate at the start \(it@mail.example.net\)" <<< "$out" && grep -Eq "RabbitMQ 3.13.7 . MinIO RELEASE.2025-10-15T17-29-55Z" <<< "$out" && sed -n "/Summary/,/Folder/p" <<< "$out" | grep -q "Direct" && ! sed -n "/Summary/,/Folder/p" <<< "$out" | grep -q "~"'

  # 26. A domain with Nginx Proxy Manager, no e-mail address: the proxy host for HTTP only, option 24 later
  fresh
  dns catalog.example.com 192.0.2.10
  out="$(printf 'i\n\ncatalog.example.com\n\n\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
  check "domain without e-mail: no certificate now, said before the start" 'grep -q "No e-mail address: HTTP only for now - option 24 adds HTTPS later." <<< "$out" && [ -z "$(setting NPM_ADMIN_EMAIL)" ] && grep -q "The Catalog: http://catalog.example.com (HTTPS: option 24)" <<< "$out" && grep -Eq "HTTPS +HTTP for now: no e-mail address - option 24 adds HTTPS" <<< "$out"'
  check "domain without e-mail: the proxy host for HTTP only, no certificate requested" 'grep -qx "catalog.example.com|0|catalog-web|80|false" "$NS/hosts/1" && [ -z "$(ls "$NS/certs")" ] && ! grep -q "POST /nginx/certificates" "$NS/calls"'
  check "domain without e-mail: outcome http with the reason, option 24 retries" 'grep -q "The Catalog: http://catalog.example.com - no certificate yet: Let.s Encrypt needs a real e-mail address" <<< "$out" && grep -q "menu option 24 requests it" <<< "$out" && [ ! -e "$D/.domain-certificate" ]'

  # 26b. Nginx Proxy Manager refuses the proxy host: the installation goes on, option 24 retries it
  fresh
  dns catalog.example.com 192.0.2.10
  out="$(printf 'i\n\ncatalog.example.com\n\nit@mail.example.net\n\n\n\n\n0\n' | SHIM_NPM_HOST_FAIL=1 bash "$I" menu 2>&1)"
  check "proxy host refused: named with option 24, then the data and the summary" 'grep -q "did not create the proxy host of catalog.example.com (HTTP 500" <<< "$out" && grep -q "Nginx Proxy Manager is not set up for catalog.example.com yet (see above)." <<< "$out" && grep -q "Option 24 retries it." <<< "$out" && grep -q "Install .* step 7 of 7" <<< "$out" && [ ! -e "$D/.domain-certificate" ]'

  # 26c. A name Let's Encrypt gives no certificate for (.lan): HTTP through Nginx Proxy Manager, no e-mail
  # asked, no HTTPS promised
  fresh
  dns catalog.corp.lan 192.0.2.10
  out="$(printf 'i\n\ncatalog.corp.lan\n\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
  check ".lan: no Let's Encrypt promised, no e-mail asked" 'grep -q "Let.s Encrypt gives no certificates for .lan names - HTTPS needs an own" <<< "$out" && ! grep -q "set up automatically" <<< "$out" && ! grep -q "Let.s Encrypt needs a real e-mail address" <<< "$out" && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = true ]'
  check ".lan: BASEURL http, the address line and the summary say HTTP" '[ "$(setting BASEURL)" = "http://catalog.corp.lan" ] && grep -q "The Catalog: http://catalog.corp.lan . http://192.0.2.10:8080" <<< "$out" && grep -Eq "HTTPS +HTTP only - no Let.s Encrypt for .lan names" <<< "$out" && ! grep -q "option 24 adds HTTPS" <<< "$out"'
  check ".lan: the proxy host for HTTP only, no certificate requested, the reason named" 'grep -qx "catalog.corp.lan|0|catalog-web|80|false" "$NS/hosts/1" && ! grep -q "POST /nginx/certificates" "$NS/calls" && grep -q "no certificate yet: Let.s Encrypt gives no certificates for names ending in .lan" <<< "$out"'

  # 27. An e-mail address Let's Encrypt refuses is asked again
  fresh
  out="$(printf 'i\n\ncatalog.example.com\n\n\nit@example.com\nIT@Mail.Example.net\n0\n\n0\n' | bash "$I" menu 2>&1)"
  check "domain: an e-mail at example.com refused, the next one taken in lower case" 'grep -q "Let.s Encrypt does not take addresses at example.com - give a real one" <<< "$out" && [ "$(setting NPM_ADMIN_EMAIL)" = it@mail.example.net ]'
  check "domain not in DNS: the proxy text says HTTPS comes when it points here" 'grep -q "Let.s Encrypt certificate once the name points to this server - until then on" <<< "$out" && grep -q "The Catalog: http://catalog.example.com (HTTPS: option 24)" <<< "$out"'
else
  echo "SKIP: neither jq nor python3 - no test of the setup of Nginx Proxy Manager"
fi

# 28. An invalid domain name and an IP address are asked again; a name not in DNS can be typed again
fresh
out="$(printf 'i\n\nbad_name\n192.0.2.10\ncatalog.example.com\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "domain: an invalid name and an IP address refused, asked again" 'grep -q "Give a host name in lower case, e.g. catalog.example.com" <<< "$out" && grep -q "\"192.0.2.10\" is an IP address - leave it empty to use the IP address" <<< "$out" && [ "$(setting CATALOG_DOMAIN)" = catalog.example.com ]'
check "domain: not in DNS yet - named, not blocked" 'grep -q "catalog.example.com is not in DNS yet" <<< "$out" && grep -q "Install .* step 3 of 7" <<< "$out"'
fresh
dns catalog.example.com 192.0.2.10
out="$(printf 'i\n\ncatalgo.example.com\nn\ncatalog.example.com\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "domain: a typo not in DNS typed again on the same screen, the typo never saved" 'grep -q "catalgo.example.com is not in DNS yet" <<< "$out" && grep -q "catalog.example.com points to this server" <<< "$out" && [ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && ! grep -q catalgo "$I"'
fresh 's/^CATALOG_DOMAIN=.*/CATALOG_DOMAIN="catalog.example.com"/'
dns catalog.example.com 192.0.2.10
out="$(printf 'i\n\nhttp://\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "domain: an input without a host name is refused, the saved domain stays" 'grep -q "Give a host name, e.g. catalog.example.com (- removes the domain)." <<< "$out" && [ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && grep -q "Install .* step 3 of 7" <<< "$out"'

# 29. .setup-later: the I card still runs the task, and a completed installation removes the marker
fresh
touch "$D/.setup-later"
out="$(printf 'i\n\n\n\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
check "I with .setup-later: the new installation runs, the marker goes when it is done" 'grep -q "Install .* step 1 of 7" <<< "$out" && grep -q "The Catalog is installed" <<< "$out" && [ ! -e "$D/.setup-later" ]'

# 21. Full screen and terminal: the first start, and the lines above the prompt say what the typed number does
if command -v script >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  # tty_run COMMAND [PATTERN KEYS]... -> runs COMMAND in a pseudo-terminal (TTY_SIZE, default 120x40): waits
  # for each PATTERN in what the terminal shows after the keys before, then types its KEYS; prints what the
  # terminal showed
  tty_run() {
    local cmd="$1" log="$T/tty.log" i from=1 size="${TTY_SIZE:-120x40}"
    shift
    : > "$log"
    { while [ $# -ge 2 ]; do
        for i in $(seq 1 120); do tail -c +"$from" "$log" 2>/dev/null | grep -aq -- "$1" && break; sleep 0.5; done
        sleep 0.5
        from=$(($(wc -c < "$log") + 1))
        printf "$2"
        shift 2
      done
      sleep 2
    } | TERM=xterm LANG=C.UTF-8 timeout 150 script -qfec "stty sane; stty cols ${size%x*} rows ${size#*x}; $cmd" /dev/null > "$log" 2>&1
    sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g' "$log" | tr -d '\r'
  }
  fresh
  out="$(tty_run "bash $I menu" "Select \[1\]:" '0\n' "Press Enter to open the menu" '\n' "Select:" q)"
  check "first start: the welcome and the new installation, without asking for the engine first" '{ grep -q "New installation. A few questions - engine, domain, proxy, versions - then$" <<< "$out" && grep -q "the Catalog starts. 0 at any question opens the full menu." <<< "$out" && grep -q "Install .* step 1 of 7" <<< "$out" && ! grep -q "Prerequisites are not met" <<< "$out"; } || { printf "%s\n" "$out" | tail -n 40 | sed "s/^/  | /"; false; }'
  check "first start: 0 at the first question - stopped, .setup-later, then the full menu" 'grep -q "Stopped. I starts it again" <<< "$out" && [ -f "$D/.setup-later" ] && grep -q "Type a number - what it does shows here" <<< "$out"'
  out="$(tty_run "bash $I menu" "Select:" q)"
  check "second start after 0: the menu opens directly" '! grep -q "New installation. A few questions" <<< "$out" && grep -q "Type a number - what it does shows here" <<< "$out"'
  fresh
  out="$(tty_run "bash $I menu" "Select \[1\]:" '\n' "Domain name \[none\]:" '\n' "Install Nginx Proxy Manager" '\n' "Enter, or a row:" '\n' "Write the files and start the Catalog" '\n' "Press any key to continue" ' ' "Select \[0\]:" '\n' "Press any key to continue" ' ' "Press Enter to open the menu" '\n' "Select:" q)"
  check "first start in a terminal: installed with Enter only, then the full menu" '{ [ -f "$D/.env" ] && [ -f "$ST/up" ] && grep -q "The Catalog is installed" <<< "$out" && grep -q "Next: the full menu" <<< "$out" && grep -q "Type a number - what it does shows here" <<< "$out" && [ ! -e "$D/.setup-later" ]; } || { printf "%s\n" "$out" | tail -n 40 | sed "s/^/  | /"; false; }'
  check "first start in a terminal: the address line on the versions screen, no question after the start" '{ grep -q "The Catalog: http://192.0.2.10:8080" <<< "$out" && ! grep -q "Continue with the catalog data" <<< "$out"; } || { printf "%s\n" "$out" | tail -n 40 | sed "s/^/  | /"; false; }'
  out="$(tty_run "bash $I menu" "Select:" q)"
  check "no automatic start in an installed folder" '! grep -q "New installation. A few questions" <<< "$out" && grep -q "Type a number - what it does shows here" <<< "$out"'
  fresh
  out="$(tty_run "bash $I menu resume-update" "Press Enter to return to the menu" '\n' "Select:" q)"
  check "no automatic start when the menu resumes the update" '! grep -q "New installation. A few questions" <<< "$out" && grep -q "Nothing is installed in this folder yet" <<< "$out" && [ ! -e "$D/.setup-later" ]'
  out="$(tty_run "RVC_NOTICE=Restarted bash $I menu" "Select:" q)"
  check "no automatic start after a restart with a notice" '! grep -q "New installation. A few questions" <<< "$out" && grep -q "Restarted" <<< "$out"'
  fresh
  touch "$ST/up" "$ST/net" "$ST/vols"
  out="$(tty_run "SHIM_FOREIGN_DIR=$OTHER bash $I menu" "Select:" q)"
  check "no automatic start when another installation runs on this server" '! grep -q "New installation. A few questions" <<< "$out" && ! grep -q "Install .* step" <<< "$out" && grep -q "Type a number - what it does shows here" <<< "$out"'
  fresh
  mkdir -p "$D/.jobs/1"; echo "Snapshot download" > "$D/.jobs/1/title"; echo running > "$D/.jobs/1/state"
  sleep 300 & JOBPID=$!; echo "$JOBPID" > "$D/.jobs/1/pid"
  out="$(tty_run "bash $I menu" "Select:" q)"
  kill "$JOBPID" 2>/dev/null; wait "$JOBPID" 2>/dev/null
  check "no automatic start while a job runs" '! grep -q "New installation. A few questions" <<< "$out" && ! grep -q "Install .* step" <<< "$out" && grep -q "Type a number - what it does shows here" <<< "$out"'
  fresh
  touch "$ST/vols"
  out="$(tty_run "bash $I menu" "Press Enter to open the menu" '\n' "Select:" q)"
  check "first start with data volumes but no .env: named at once, no question" 'grep -q "Data volumes of project \"inst\" are in Podman" <<< "$out" && ! grep -q "New installation. A few questions" <<< "$out" && ! grep -q "Select \[1\]:" <<< "$out" && [ ! -e "$D/.setup-later" ]'

  # 80x24 (PuTTY and many SSH clients): the screens of the new installation fit, the summary is not cut
  fresh
  out="$(TTY_SIZE=80x24 tty_run "bash $I menu" "Select \[1\]:" '\n' "Domain name \[none\]:" '\n' "Install Nginx Proxy Manager" '\n' "Enter, or a row:" '\n' "Write the files and start the Catalog" 'n\n' "Press Enter to open the menu" '\n' "Select:" q)"
  wide="$(sed -n '/step 1 of 7/,/Checking the engine, Compose/p' <<< "$out" | LC_ALL=C grep -v '[^ -~]' | awk 'length($0) > 80')"
  check "80 columns: the texts of the new installation fit, the summary is not cut" 'grep -q "Summary" <<< "$out" && ! sed -n "/Summary/,/Folder/p" <<< "$out" | grep -q "~" && [ -z "$wide" ] || { printf "%s\n" "$wide" | head -5; false; }'

  touch "$D/.setup-later"
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
    } | TERM=xterm LANG=C.UTF-8 timeout 90 script -qfec "stty sane; stty cols ${2:-120} rows 40; bash $I menu" /dev/null > "$log" 2>&1
    sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g' "$log" | tr -d '\r'
  }
  out="$(tui_type "")"
  check "full screen: asks for a number and says it will explain it" 'grep -q "Type a number - what it does shows here" <<< "$out"'
  check "full screen: the I card of a new folder" '{ grep -q "New installation, step by step" <<< "$out" && grep -q "engine .* domain .* proxy" <<< "$out"; } || { printf "%s\n" "$out" | tail -n 40 | sed "s/^/  | /"; false; }'
  out="$(tui_type 13 120 "data volumes stay")"
  check "full screen: typing 13 says what it does" 'grep -q "13 .* Stop (data is kept)" <<< "$out" && grep -q "podman compose down - data volumes stay" <<< "$out"'
  out="$(tui_type 99 120 "AND data volumes")"
  check "full screen: typing 99 warns" 'grep -q "Reset: delete all data - asks for DELETE" <<< "$out" && grep -q "Removes ALL containers AND data volumes" <<< "$out"'
  out="$(tui_type 98 120 "No option 98")"
  check "full screen: an unknown number is named" 'grep -q "No option 98" <<< "$out"'
  installed; rm -f "$D/.env"
  out="$(tui_type "" 132)"
  check "full screen, 132 columns: the cards fit (no cut texts) and name what is missing" 'grep -q "Incomplete: no .env" <<< "$out" && grep -q "put the old .env back first" <<< "$out" && grep -q "you choose: data, images, files" <<< "$out" && ! grep -q "~ " <<< "$(grep -E "Incomplete|choose|old .env" <<< "$out")"'
else
  echo "SKIP: script (util-linux) missing - no test of the first start and of the full screen typing hints"
fi

check "fakes: no unknown podman, docker, provider, systemctl, curl or DNS call in the whole suite" '[ ! -s "$BAD" ] || { sort "$BAD" | uniq -c | head -20; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
