#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/w"
rm -rf "$T"; mkdir -p "$T/bin" "$T/dbin" "$T/state" "$T/npm" "$T/dns"
# these tests run Podman: CONTAINER_ENGINE names it (on a CI runner, detection would see its real Docker)
sed 's/^CONTAINER_ENGINE=""$/CONTAINER_ENGINE="podman"/' "$1" > "${T%/*}/podman-installer.sh"; NEW="${T%/*}/podman-installer.sh"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# cksum of the installer without its SETTINGS_PUBLISHED_SUM line, which the installer blanks at the first start of a file whose settings were changed
body() { grep -v '^SETTINGS_PUBLISHED_SUM=' "$1" | cksum; }
# the internet check (menu start, new installation, option 16, engine setup) has its own suite (run_network_tests)
export RN1_NET_CHECK=off
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
# - Catalog Web on localhost: the license (valid when $ST/license exists), the login of root (password
#   rootpw) and the activation by license file (the file it got: $ST/got-license; a file with "wrong" in it
#   is for another server) or by the text of an e-mail ($ST/got-text; without its last line LICENSE ENDS
#   HERE it is refused); its calls in $ST/local.log
# - the API of Nginx Proxy Manager on 127.0.0.1:81 and the checks through it (--resolve). Its state in $NS:
#   version, user (EMAIL|PASSWORD; missing: not set up yet), token, hosts/ID (DOMAIN|CERT|HOST|PORT|SSL_FORCED),
#   certs/ID (DOMAIN|EXPIRES), seq (last id), calls (METHOD PATH CODE). SHIM_NPM_HOST_FAIL: it refuses to
#   create a proxy host (HTTP 500).
# Any other URL is written to $BAD.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; out=""; hdr=""; fmt=""; head="no"; url=""; cfg=""; data=""; resolve=""; form=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -F) form="$2"; shift 2 ;;
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
if [[ "$url" == http://localhost:*/v1/* ]]; then
  p="/${url#http://localhost:*/}"
  auth="$(printf '%s' "$cfg" | sed -n 's/^header = "\(.*\)"$/\1/p')"
  echo "$method $p" >> "$ST/local.log"
  LICOK='{"status":"Ok","edition":"Enterprise","expirationDate":"2027-12-31T00:00:00","version":"26.3","yourHardwareId":"HID8-4B1E-11-22-33"}'
  case "$method $p" in
    "GET /v1/license/isValid") if [ -f "$ST/license" ]; then done_with 200 true; fi; done_with 200 false ;;
    "POST /v1/authentication/request")
      if grep -q '"username":"root"' "$data" && grep -q '"password":"rootpw"' "$data"; then done_with 200 '{"access_token":"TOKROOT","expires_in":3600}'; fi
      done_with 401 "" ;;
  esac
  [ "$auth" = "Authorization: Bearer TOKROOT" ] || done_with 401 ""
  case "$method $p" in
    "GET /v1/license") if [ -f "$ST/license" ]; then done_with 200 "$LICOK"; fi; done_with 200 '{"status":"NotPresent","yourHardwareId":"HID8-4B1E-11-22-33"}' ;;
    "POST /v1/license/activate/file")
      cp "${form#file=@}" "$ST/got-license"
      grep -q wrong "$ST/got-license" && done_with 400 '"license.messages.invalid-hardware-id"'
      touch "$ST/license"; done_with 200 "$LICOK" ;;
    "POST /v1/license/activate/mail")
      cp "$data" "$ST/got-text"
      grep -q "LICENSE ENDS HERE" "$ST/got-text" || done_with 400 '"Activation failed with the following error: Unknown order number. Activation not possible."'
      touch "$ST/license"; done_with 200 "$LICOK" ;;
    # System Settings, one setting per call: what the activation wrote is kept in setting-NAME
    "GET /v1/databaseconfiguration/"*)
      n="${p##*/}"
      if [ -f "$ST/setting-$n" ]; then done_with 200 "{\"property\":\"$n\",\"value\":\"$(cat "$ST/setting-$n")\"}"; fi
      done_with 204 "" ;;
    "POST /v1/databaseconfiguration")
      n="$(sed -n 's/.*"property":"\([^"]*\)".*/\1/p' "$data")"
      sed -n 's/.*"value":"\([^"]*\)".*/\1/p' "$data" > "$ST/setting-$n"
      done_with 200 "" ;;
  esac
  echo "UNHANDLED curl $method $url" >> "$BAD"; done_with 404 ""
fi
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
# is not active (systemctl). SHIM_ROOTLESS: Podman runs rootless. $ST/stopped: the containers exist, none
# runs. $ST/web-gone: the container of catalog-web was removed, the others are there. A call the fakes do not
# know is written to $BAD and fails.
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
echo "podman $ARGS" >> "$LOG"
bad() { echo "UNHANDLED podman $ARGS" | tee -a "$LOG" >> "$BAD"; echo "Error: the fake podman does not know: $ARGS" >&2; exit 125; }
running() { [ -f "$ST/up" ]; }
# the containers exist, but none runs
stopped() { [ -f "$ST/stopped" ]; }
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
is_ct() { running && case "$1" in c1|c3) true ;; c2) [ ! -f "$ST/web-gone" ] ;; *) false ;; esac; }
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
      "3|--format|{{.Host.MemTotal}}") echo "${SHIM_MEMTOTAL:-34359738368}" ;;
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
      is_ct "$id" || continue
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
      rp '{{.State.Status}}' "$(if stopped; then echo exited; else echo running; fi)"
      # Podman 5.x: a container without a healthcheck has no .State.Health
      rp '{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}' none
      rp '{{.RestartCount}}' 0
      # the host name: from the env file of the last start (none: the container ID), else the env file now
      if [ -f "$ST/hostname" ]; then h="$(cat "$ST/hostname")"; else h="$(envval CATALOG_HOSTNAME)"; fi
      rp '{{.Config.Hostname}}' "${h:-$id}"
      rp '{{.State.OOMKilled}}' false
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
          "-q "*|"-a -q "*)
            # -a: stopped containers too - these exist only while the stack runs
            if [ "$1" = -a ]; then shift; fi
            [ $# -eq 2 ] || bad
            if running; then
              case "$2" in
                mongo) echo c1 ;; catalog-web) is_ct c2 && echo c2 ;; worker-search) echo c3 ;;
                nginx-proxy-manager) [ "$(envval INSTALL_NGINX_PROXY_MANAGER)" = true ] && echo c4 ;;
              esac
            fi ;;
          "--services --filter status=running") if running && ! stopped; then printf '%s\n' mongo catalog-web worker-search; fi ;;
          "") echo "NAME STATUS"; running && printf '%s\n' "inst-mongo-1 Up" "inst-catalog-web-1 Up" "inst-worker-search-1 Up" ;;
          *) bad ;;
        esac ;;
      pull|logs) ;;
      restart) [ "$*" = "-t 30" ] || bad ;;
      down)
        case "$*" in "--remove-orphans"|"-v --remove-orphans") ;; *) bad ;; esac
        [ -n "${SHIM_CONFIG_FAIL:-}" ] && exit 1
        rm -f "$ST/up" "$ST/net" "$ST/stopped"
        if [[ " $* " == *" -v "* ]] && [ -z "${SHIM_VOL_BUSY:-}" ]; then rm -f "$ST/vols" "$ST/vols.rm"; fi ;;
      up)
        [ "$*" = "-d --remove-orphans" ] || bad
        touch "$ST/up" "$ST/net" "$ST/vols"; rm -f "$ST/vols.rm" "$ST/stopped"
        printf '%s\n' "docker.io/library/mongo:$(envval MONGO_TAG)" "docker.io/$(envval CATALOG_IMAGE)" "docker.io/$(envval CATALOG_WORKER_IMAGE)" > "$ST/images"
        envval CATALOG_IMAGE | sed 's/.*://' > "$ST/catalog_tag"
        envval MONGO_TAG > "$ST/mongo_tag"
        envval CATALOG_HOSTNAME > "$ST/hostname"
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
      # the host name: from the env file of the last start (none: the container ID), else the env file now
      if [ -f "$ST/hostname" ]; then h="$(cat "$ST/hostname")"; else h="$(envval CATALOG_HOSTNAME)"; fi
      rp '{{.Config.Hostname}}' "${h:-$id}"
      rp '{{.State.OOMKilled}}' false
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
      up)
        [ "$*" = "-d --remove-orphans" ] || bad
        touch "$ST/up" "$ST/net" "$ST/vols"
        envval CATALOG_IMAGE | sed 's/.*://' > "$ST/catalog_tag"
        envval MONGO_TAG > "$ST/mongo_tag"
        envval CATALOG_HOSTNAME > "$ST/hostname"
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
# installed -> an installation of Catalog 25.4 that runs (named here: the default is the newest Catalog of the release)
installed() {
  fresh 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/'
  (cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  touch "$ST/up" "$ST/net" "$ST/vols" "$ST/license"; echo "25.4.4191.133" > "$ST/catalog_tag"; echo 8.0 > "$ST/mongo_tag"; echo "$D" > "$ST/wd"
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
# files written, stack started with a health check, the license later (the data then too), summary. A
# download older than Docker Hub's newest Catalog: Enter must write the newest
fresh 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/'
out="$(printf 'i\n\n\n\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
check "install: the nine steps shown - the data step skipped without a license" '( for s in 1 2 3 4 5 6 7 9; do grep -q "Install .* step $s of 9" <<< "$out" || exit 1; done ) && ! grep -q "Install .* step 8 of 9" <<< "$out"'
check "install: the engines listed, Podman ready and the default" 'grep -Eq "1  Podman +[^ ]+ ready" <<< "$out" && grep -Eq "2  Docker Engine +installed - the setup completes it" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = podman ] && grep -q "Podman is ready" <<< "$out"'
check "install: no domain - the address of the server" 'grep -q "Catalog then runs on http://192.0.2.10:8080.$" <<< "$out" && [ -z "$(setting CATALOG_DOMAIN)" ] && grep -q "The Catalog: http://192.0.2.10:8080$" <<< "$out"'
check "install: Nginx Proxy Manager - no without a domain (the default)" 'grep -q "Without a domain name it only forwards http://192.0.2.10 to the Catalog" <<< "$out" && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ] && grep -qx "INSTALL_NGINX_PROXY_MANAGER=false" "$D/.env"'
check "install: Enter takes the recommended versions (Catalog the newest, the others inside their series)" '[ "$(grep -Ec "$RECOMMENDED" "$I")" -eq 6 ] && grep -q "recommended" <<< "$out"'
check "install: one summary box before the start" 'grep -q "Summary" <<< "$out" && grep -Eq "Engine +Podman" <<< "$out" && grep -Eq "Address +http://192.0.2.10:8080" <<< "$out" && ! grep -Eq "Direct +http" <<< "$out" && grep -Eq "Proxy +none - Catalog Web answers directly" <<< "$out" && grep -Eq "Versions +Catalog 26.3.4789.148 . MongoDB 8.0.32 . OpenSearch 2.19.6" <<< "$out" && grep -Eq "RabbitMQ 3.13.7 . MinIO RELEASE.2025-10-15T17-29-55Z" <<< "$out" && grep -Eq "Folder +$D" <<< "$out"'
check "install: the check is quiet when it passes" 'grep -q "All required checks passed" <<< "$out" && ! grep -q "Checking prerequisites" <<< "$out" && ! grep -q "OK Podman 5.7.0" <<< "$out"'
check "install: files generated with the versions, stack started" '[ -f "$D/.env" ] && [ -f "$D/docker-compose.yml" ] && grep -qx "MONGO_TAG=8.0.32" "$D/.env" && grep -q "^podman compose .*--env-file .env -f docker-compose.yml up -d --remove-orphans$" "$LOG"'
check "install: after the start straight on to the license (no question in between)" '! grep -q "Continue with the" <<< "$out" && grep -q "Install .* step 7 of 9" <<< "$out"'
check "install: the license step - why, the three ways, Enter is later" 'grep -q "The Catalog needs a license from Raynet: without one it takes no data." <<< "$out" && grep -q "By order number" <<< "$out" && grep -q "By license file" <<< "$out" && grep -q "By e-mail" <<< "$out" && grep -q "Later: option 25 activates the Catalog." <<< "$out" && ! grep -q "activate/" "$ST/local.log"'
check "install: health check, addresses once, summary" 'grep -q "Health check" <<< "$out" && grep -q "The Catalog is installed" <<< "$out" && [ "$(grep -c "Catalog Web (direct)" <<< "$out")" -eq 1 ] && grep -q "http://192.0.2.10:8080" <<< "$out"'
check "install: no license - no data, how to go on; the Catalog Web login; then the full menu" 'grep -q "The Catalog has no data yet: it is not activated (no valid license)." <<< "$out" && grep -q "Option 25 activates the Catalog, then options 20 / 17 and 19 load the data." <<< "$out" && grep -q "Catalog Web login: root (default password root unless it was changed) -" <<< "$out" && grep -q "change it in the web interface." <<< "$out" && grep -q "Options: 14 passwords . 15 addresses . 24 domain and HTTPS . 9 status" <<< "$out" && grep -q "Next: the full menu - every option (H: help)" <<< "$out" && sed -n "/Next: the full menu/,\$p" <<< "$out" | grep -q "START HERE"'
check "install: no Nginx Proxy Manager set up without a domain" '! grep -q "Setting up Nginx Proxy Manager" <<< "$out" && [ ! -s "$NS/calls" ]'

# 3. Install on a folder that is already installed: repair, license and data, update or remove
out="$(printf 'i\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: existing installation found, cancel changes nothing" 'grep -q "This folder already has an installation" <<< "$out" && grep -q "Continue with the license and the catalog data" <<< "$out" && grep -q "Cancelled" <<< "$out"'
out="$(printf 'i\n2\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: continues with the license (step 5), later: the data skipped" 'grep -q "Install .* step 5 of 7" <<< "$out" && ! grep -q "Install .* step 3 of 7" <<< "$out" && ! grep -q "Install .* step 6 of 7" <<< "$out" && grep -q "Install .* step 7 of 7" <<< "$out"'

# 3b. The files of an older installer (no fixed host name; catalog-web runs with its container ID c2): the
# license step activates without a warning (writing the files later keeps the name of a licensed Catalog); a
# repair keeps the name of a licensed catalog-web, and gives an unlicensed one the name of this server
installed; rm -f "$ST/license"; sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
out="$(printf 'i\n2\n\n\n0\n' | bash "$I" menu 2>&1)"
check "license step on files without a fixed host name: no warning, the ways, Enter is later" '! grep -q -e "has no fixed host name yet" -e "still runs with the host name" <<< "$out" && grep -q "By license file" <<< "$out" && grep -q "Later: option 25 activates the Catalog." <<< "$out" && ! grep -q "activate/" "$ST/local.log" && grep -q "Install .* step 7 of 7" <<< "$out"'
out="$(printf 'i\n1\ny\ny\n\ny\ny\ny\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "repair of these files without a license: the name of this server (nothing lost), then the license step without a warning" 'grep -q "catalog-web now has the fixed host name" <<< "$out" && grep -q "holds no valid license now: none is" <<< "$out" && ! grep -q -e "needs a license for" -e "keeps its host name" <<< "$out" && [ -n "$(envv CATALOG_HOSTNAME)" ] && [ "$(envv CATALOG_HOSTNAME)" != c2 ] && grep -q "Install .* step 5 of 7" <<< "$out" && grep -q "By license file" <<< "$out" && ! grep -q "still runs with the host name" <<< "$out"'
installed; sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
out="$(printf 'i\n1\ny\ny\n\ny\ny\ny\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "repair of these files with a license: catalog-web keeps its name, the license stays valid" '[ "$(envv CATALOG_HOSTNAME)" = c2 ] && grep -q "catalog-web keeps its host name c2: the Catalog.s license" <<< "$out" && grep -q "is bound to it (CATALOG_HOSTNAME in .env)." <<< "$out" && ! grep -q -e "needs a license for" -e "fixed host name" <<< "$out" && grep -q "The Catalog is activated (valid license)." <<< "$out" || { printf "%s\n" "$out" | grep -n -i -e "host name" -e "license" -e "step" | head -30; false; }'

# 4. Repair keeps the installed version (an upgrade belongs to U with backup and rollback)
installed
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$I"
out="$(printf 'i\n1\ny\ny\n\ny\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "repair: version of the installation kept" 'grep -q "the repair keeps 25.4.4191.133" <<< "$out" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$I" && grep -q "^CATALOG_IMAGE=.*:25.4.4191.133$" "$D/.env"'
check "repair: the steps of a repair (check, settings, files, start)" 'grep -q "Install .* step 3 of 7" <<< "$out" && grep -q "Install .* step 4 of 7" <<< "$out" && ! grep -q "of 9" <<< "$out"'
# 4b. 26.3 runs, a new download of the installer says 25.4 (and port 8080 instead of 8181): the start offers
#     the values of the installation (declined here), the repair offers them again before it writes anything
installed
# (catalog-web of 26.3 first: generate does not raise a running 25.4 without asking)
echo "26.3.4789.148" > "$ST/catalog_tag"
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/; 0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="8181"/' "$I"
(cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/; 0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="8080"/' "$I"
: > "$LOG"
out="$(printf 'n\n\ni\n1\ny\ny\ny\n\ny\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "repair after a new download: the values of the installation taken over first, 26.3 kept" '[ "$(grep -c "CATALOG_VERSION *25.4.4191.133 -> 26.3.4789.148" <<< "$out")" -eq 2 ] && grep -q "Took over 2 value(s) of the installation" <<< "$out" && grep -q "Catalog version: 26.3.4789.148" <<< "$out" && [ "$(setting CATALOG_VERSION)" = 26.3.4789.148 ] && [ "$(setting CATALOG_WEB_PORT)" = 8181 ] && grep -q "^CATALOG_IMAGE=.*:26.3.4789.148$" "$D/.env" && grep -qx "CATALOG_WEB_PORT=8181" "$D/.env"'
# 4c. The same Catalog version, only the port differs from .env (a new download with the installed version):
#     nothing is offered at the start, the repair offers the values of the installation before it writes
installed
sed -i '0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="8181"/' "$I"
(cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
sed -i '0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="8080"/' "$I"
: > "$LOG"
out="$(printf 'i\n1\ny\ny\ny\n\ny\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "repair with another port in the settings: the port of the installation taken over first, kept" 'grep -q "The settings differ from the installation in CATALOG_WEB_PORT" <<< "$out" && [ "$(grep -c "CATALOG_WEB_PORT *8080 -> 8181" <<< "$out")" -eq 1 ] && grep -q "Took over 1 value(s) of the installation" <<< "$out" && [ "$(setting CATALOG_WEB_PORT)" = 8181 ] && grep -qx "CATALOG_WEB_PORT=8181" "$D/.env"'
# 4d. The host name and the cache of MongoDB that .env derives (CATALOG_HOSTNAME and MONGO_CACHE_GB empty) are
#     no difference: the repair offers nothing and keeps the host name
installed
sed -i 's/^CATALOG_HOSTNAME=.*/CATALOG_HOSTNAME=c2/; s/^MONGO_WT_CACHE_GB=.*/MONGO_WT_CACHE_GB=3/' "$D/.env"
out="$(printf 'i\n1\ny\ny\n\ny\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "repair with the derived host name and cache: nothing offered, the name kept, the cache for the memory" '! grep -q -e "differ from the installation" -e "Taking them over writes" <<< "$out" && [ "$(envv CATALOG_HOSTNAME)" = c2 ] && [ "$(envv MONGO_WT_CACHE_GB)" = 11 ] && [ -z "$(setting CATALOG_HOSTNAME)" ] && [ -z "$(setting MONGO_CACHE_GB)" ] && grep -q "Install .* step 4 of 7" <<< "$out"'
# 4e. Below 24 GB the repair asks at its check (step 1), before it writes: the line of the check is the one
#     warning; no and 0 stop it with the files as they were, yes goes on with the cache for that memory
installed
before="$(cksum < "$D/.env")"
out="$(printf 'i\n1\ny\nn\n\n0\n' | SHIM_MEMTOTAL=15032385536 bash "$I" menu 2>&1)"
check "repair below 24 GB, no: one memory warning (the line of the check), stopped at the check, nothing written" '[ "$(grep -c "GB for the containers - at least 24 GB is recommended" <<< "$out")" -eq 1 ] && grep -q "^WARN Memory: 14 GB for the containers - at least 24 GB is recommended$" <<< "$out" && ! grep -q "This engine has" <<< "$out" && back_in_menu && ! grep -q "Install .* step 2 of 7" <<< "$out" && [ "$(cksum < "$D/.env")" = "$before" ] && ! grep -q "compose.* up" "$LOG"'
out="$(printf 'i\n1\ny\n0\n\n0\n' | SHIM_MEMTOTAL=15032385536 bash "$I" menu 2>&1)"
check "repair below 24 GB, 0: stopped, nothing written" 'back_in_menu && ! grep -q "Install .* step 2 of 7" <<< "$out" && [ "$(cksum < "$D/.env")" = "$before" ]'
out="$(printf 'i\n1\ny\ny\ny\n\ny\ny\nn\n\n0\n' | SHIM_MEMTOTAL=15032385536 bash "$I" menu 2>&1)"
check "repair below 24 GB, yes: the steps go on, the cache for 14 GB" '[ "$(grep -c "GB for the containers - at least 24 GB is recommended" <<< "$out")" -eq 1 ] && grep -q "^WARN Memory: 14 GB for the containers - at least 24 GB is recommended$" <<< "$out" && ! grep -q "This engine has" <<< "$out" && grep -q "Install .* step 4 of 7" <<< "$out" && [ "$(envv MONGO_WT_CACHE_GB)" = 2 ] && grep -q "up -d --remove-orphans" "$LOG"'
# 4f. An older MongoDB in the settings than the installation's, the take-over declined: the repair stops
#     before the check, its Memory line (the one warning below 24 GB) and the question, nothing written
installed
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0"/' "$I"
before="$(cksum < "$D/.env")"
out="$(printf 'n\n\ni\n1\nn\n\n0\n' | SHIM_MEMTOTAL=15032385536 bash "$I" menu 2>&1)"
check "repair with MongoDB 7.0 against the installed 8.0, take-over declined twice: stopped before the check" '[ "$(grep -c "MONGO_TAG *7.0 -> 8.0" <<< "$out")" -eq 2 ] && grep -q "MongoDB 7.0 would replace the" <<< "$out" && grep -q "take the installation.s values over first (option 23)" <<< "$out" && ! grep -q -e "Checking the engine" -e "GB for the containers" -e "anyway?" -e "Install .* step 2 of 7" <<< "$out" && [ "$(cksum < "$D/.env")" = "$before" ] && [ "$(setting MONGO_TAG)" = 7.0 ]'
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
check "install again: a saved no for Nginx Proxy Manager is the default while the domain stays" '[ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ] && ! grep -q "Let.s Encrypt needs a real e-mail address" <<< "$out" && grep -q "Install .* step 5 of 9" <<< "$out" && back_in_menu'
out="$(printf 'i\n\n-\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: - removes the domain" '[ -z "$(setting CATALOG_DOMAIN)" ] && [ "$(setting BASEURL)" = "http://catalog-web" ]'
out="$(printf 'i\n\ncatalog.example.com\n\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: a new domain - Nginx Proxy Manager defaults to yes again" '[ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && grep -q "Let.s Encrypt needs a real e-mail address" <<< "$out" && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = false ]'

# 5a. Below 24 GB of memory the Install step says so once - the line of the check - and asks (on Linux there is
# nothing to offer); no stops before the files, yes goes on with the cache of MongoDB for that memory
fresh
out="$(printf 'i\n\n\n\n\nn\n\n0\n' | SHIM_MEMTOTAL=15032385536 bash "$I" menu 2>&1)"
check "install below 24 GB: one memory warning, the line of the check (not said again); no stops before the files" '[ "$(grep -c "GB for the containers - at least 24 GB is recommended" <<< "$out")" -eq 1 ] && grep -q "^WARN Memory: 14 GB for the containers - at least 24 GB is recommended$" <<< "$out" && ! grep -q "This engine has" <<< "$out" && grep -q "^      A full snapshot import loads MongoDB, the Catalog and OpenSearch at once.$" <<< "$out" && back_in_menu && [ ! -f "$D/.env" ] && ! grep -q "compose.* up" "$LOG"'
fresh
out="$(printf 'i\n\n\n\n\ny\n\n\n\n0\n' | SHIM_MEMTOTAL=15032385536 bash "$I" menu 2>&1)"
check "install below 24 GB: yes goes on - the cache of MongoDB for 14 GB, the Catalog started" '[ "$(grep -c "GB for the containers - at least 24 GB is recommended" <<< "$out")" -eq 1 ] && grep -q "^WARN Memory: 14 GB for the containers - at least 24 GB is recommended$" <<< "$out" && ! grep -q "This engine has" <<< "$out" && grep -qx "MONGO_WT_CACHE_GB=2" "$D/.env" && grep -q "up -d --remove-orphans" "$LOG" && grep -q "The Catalog is installed" <<< "$out"'
fresh
out="$(printf 'i\n\n\n\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
check "install with 32 GB: no warning, no question, the cache of MongoDB for 32 GB" '! grep -q "This engine has" <<< "$out" && ! grep -q "WARN Memory" <<< "$out" && grep -qx "MONGO_WT_CACHE_GB=11" "$D/.env" && grep -q "The Catalog is installed" <<< "$out"'

# 5b. 0 at each question stops the task and returns to the menu; only the answers before are kept
fresh
before="$(body "$I")"
out="$(printf 'i\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the engine: nothing changed, back in the menu, the next start opens the menu" 'grep -q "Stopped. I starts it again" <<< "$out" && back_in_menu && [ "$(body "$I")" = "$before" ] && [ -f "$D/.setup-later" ] && grep -q "The next start opens the menu directly" <<< "$out"'
fresh 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE=""/'
out="$(printf 'i\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the domain: the engine kept, nothing else" 'back_in_menu && [ "$(setting CONTAINER_ENGINE)" = podman ] && [ -z "$(setting CATALOG_DOMAIN)" ] && [ ! -e "$D/.setup-later" ]'
fresh
out="$(printf 'i\n\ncatalog.example.com\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the question about a name not in DNS: the domain not saved" 'back_in_menu && grep -q "catalog.example.com is not in DNS yet" <<< "$out" && [ -z "$(setting CATALOG_DOMAIN)" ]'
fresh
out="$(printf 'i\n\ncatalog.example.com\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "stop at the proxy: the domain kept, Nginx Proxy Manager unchanged" 'back_in_menu && [ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && [ "$(setting INSTALL_NGINX_PROXY_MANAGER)" = true ] && [ -z "$(setting NPM_ADMIN_EMAIL)" ]'
# (a download with an older Catalog than the newest: writing the versions would change it)
fresh 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/'
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
check "0 at the license step means later: installed, the data skipped, the summary shown, the marker gone" '[ -f "$D/.env" ] && grep -q "compose.* up -d" "$LOG" && grep -q "Install .* step 9 of 9" <<< "$out" && grep -q "The Catalog has no data yet: it is not activated" <<< "$out" && ! grep -q "Install .* step 8 of 9" <<< "$out" && ! grep -q "Stopped. I starts it again" <<< "$out"'

# 5c. The license step: activation by the license file (root by default), then the data step with the valid
# license; at 80 columns nothing is wider
fresh
printf 'fake license file\001\002\nline 2\n' > "$T/lic.rswl"
out="$(printf 'i\n\n\n\n\n\n2\n\nrootpw\n%s\n\n\n0\n' "$T/lic.rswl" | bash "$I" menu 2>&1)"
check "license step: activated by the license file, root by default, the exact bytes" 'grep -q "Install .* step 7 of 9" <<< "$out" && grep -q "Catalog Web confirms it: the license is valid." <<< "$out" && cmp -s "$ST/got-license" "$T/lic.rswl" && grep -q "POST /v1/license/activate/file" "$ST/local.log"'
check "license step: the activation fills System Settings (parent feed, automatic conflicts, log level Info)" '[ "$(cat "$ST/setting-ParentInstanceUrl")" = "https://rayventorycatalog.raynet.de" ] && [ "$(cat "$ST/setting-ConflictsResolvingBehavior")" = "Always take incoming" ] && [ "$(cat "$ST/setting-LoggingLevel")" = "Info" ] && grep -q "System Settings filled: ParentInstanceUrl" <<< "$out"'
check "license step: the login shows the hardware ID with the host name catalog-web runs with, before the path" 'sed -n "/Activation needs a site administrator/,/Uploading lic.rswl/p" <<< "$out" | grep -Eq "Hardware ID +HID8-4B1E-11-22-33 \(host name $(envv CATALOG_HOSTNAME)\)" && grep -q "Raynet makes a license file or e-mail text for this hardware ID." <<< "$out"'
check "license step: then the data step names the valid license, later, the summary" 'grep -q "Install .* step 8 of 9" <<< "$out" && grep -q "The Catalog is activated (valid license)." <<< "$out" && grep -q "Install .* step 9 of 9" <<< "$out" && grep -q "The Catalog has no data yet: option 20 (daily self-sync), or 17 and 19." <<< "$out"'
# at 80 columns: the ways, the login with the license, the order screen (cancelled at its first field), a
# refused license file, later, the summary
fresh
printf 'a license for the wrong server\n' > "$T/wrong.rswl"
out="$(printf 'i\n\n\n\n\n\n1\n\nrootpw\n0\n2\n%s\n0\n\n0\n' "$T/wrong.rswl" | COLUMNS=80 LC_ALL=C bash "$I" menu 2>&1)"
wide="$(sed -n '/step 7 of 9/,/Next: the full menu/p' <<< "$out" | awk 'length($0) > 80')"
check "license step at 80 columns: the ways, the order screen, a refusal and the summary fit" 'grep -q "step 7 of 9" <<< "$out" && grep -q "By license file" <<< "$out" && grep -q "it needs internet access" <<< "$out" && grep -q "This license is for another server: the hardware ID does not match." <<< "$out" && grep -q "Another way below, or 0." <<< "$out" && grep -q "Later: option 25 activates the Catalog." <<< "$out" && grep -q "Catalog Web login: root" <<< "$out" && [ -z "$wide" ] || { printf "%s\n" "$wide" | head -5; false; }'

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
check "install: failed check shown in full, continued anyway, failed files step stops before the start" 'grep -q "1 problem(s) found" <<< "$out" && grep -q "OK Podman runs rootful" <<< "$out" && grep -q "The first start pulls the images" <<< "$out" && grep -q "The files could not be written" <<< "$out" && ! grep -q "compose.* up" "$LOG" && ! grep -q "Install .* step 7 of 9" <<< "$out"'

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

# 14b. 26.3 runs, the files say 25.4 (a new download and option 2 of an older installer): R that keeps the
#      data does not remove the containers that show 26.3
installed
echo "26.3.4789.148" > "$ST/catalog_tag"
out="$(printf 'n\n\nr\nn\ny\n1\n\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "remove keeping the data: refused while the files name an older Catalog than the containers" 'grep -q "Catalog 25.4.4191.133 would replace the installed 26.3.4789.148" <<< "$out" && grep -q "nothing was stopped" <<< "$out" && grep -q "Remove .* step 2 of 5" <<< "$out" && ! grep -q "Remove .* step 3 of 5" <<< "$out" && [ -f "$D/.env" ] && ! grep -Eq "$MUTATING" "$LOG"'

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
# (the one-line install with curl; with wget where curl is missing, below: a fake curl is always first on the PATH here)
DL="curl -fsSL https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/install.sh | bash"
installed
out="$(printf 'r\nn\ny\na\n\nDELETE\n' | bash "$I" menu 2>&1)"; rc=$?
check "remove all: installer gone, exits with the one-line install for this folder" '[ "$rc" -eq 0 ] && [ ! -e "$I" ] && grep -q "The installer was removed too. To install again, run this in $D:" <<< "$out" && grep -qF "$DL" <<< "$out"'
# a host with wget and without curl: the PATH of this suite without curl (a real wget is linked, else a stand-in)
mkdir -p "$T/nocurl"
IFS=: read -r -a dirs <<< "$PATH"
for dir in "${dirs[@]}"; do
  for f in "$dir"/*; do
    [ "${f##*/}" = curl ] || [ -e "$T/nocurl/${f##*/}" ] || ln -s "$f" "$T/nocurl/${f##*/}" 2>/dev/null || true
  done
done
if [ ! -e "$T/nocurl/wget" ]; then printf '#!/bin/sh\nexit 1\n' > "$T/nocurl/wget"; chmod +x "$T/nocurl/wget"; fi
installed
out2="$(printf 'r\nn\ny\na\n\nDELETE\n' | PATH="$T/nocurl" bash "$I" menu 2>&1)"; rc2=$?
check "remove all on a host with wget and without curl: the one-line install with wget" '[ "$rc2" -eq 0 ] && [ ! -e "$I" ] && grep -qxF "  wget -nv -O- https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/install.sh | bash" <<< "$out2" && ! grep -q "curl -fsSL" <<< "$out2"'
check "remove all: no other copy of the installer here - no note about one" '! grep -q "another copy of the installer" <<< "$out"'
# a copy of the installer next to it (catalog.sh from before the rename): not chosen, so kept; the one-line install
# would start it, and the end of the removal says so
installed
cp "$I" "$D/catalog.sh"
out="$(printf 'r\nn\ny\na\n\nDELETE\n' | bash "$I" menu 2>&1)"; rc=$?
check "remove all with a catalog.sh copy: installer gone, the copy kept, named with the consequence and how to delete it" '[ "$rc" -eq 0 ] && [ ! -e "$I" ] && [ -f "$D/catalog.sh" ] && grep -q "Kept, because it was not chosen: another copy of the installer in this folder: catalog.sh$" <<< "$out" && grep -q "The line above starts it, with its own settings, instead of downloading a new installer" <<< "$out" && grep -q "delete it first (in $D: rm catalog.sh)" <<< "$out"'
# the same with blank lines after the end of the copy (the one-line install takes such a copy for a whole installer)
installed
{ cat "$I"; printf '\n\n  \n'; } > "$D/catalog.sh"
out="$(printf 'r\nn\ny\na\n\nDELETE\n' | bash "$I" menu 2>&1)"; rc=$?
check "remove all with a catalog.sh copy that ends in blank lines: named as well" '[ "$rc" -eq 0 ] && [ ! -e "$I" ] && [ -f "$D/catalog.sh" ] && grep -q "Kept, because it was not chosen: another copy of the installer in this folder: catalog.sh$" <<< "$out"'
# a catalog.sh that is not an installer (the original generator script) is not named
installed
cp "$(cd "$(dirname "$0")" && pwd)/original.sh" "$D/catalog.sh"
out="$(printf 'r\nn\ny\na\n\nDELETE\n' | bash "$I" menu 2>&1)"; rc=$?
check "remove all with the original generator script as catalog.sh: not named as an installer" '[ "$rc" -eq 0 ] && [ ! -e "$I" ] && [ -f "$D/catalog.sh" ] && ! grep -q "another copy of the installer" <<< "$out"'
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
check "docker ready, Podman missing: Enter takes Docker, Podman is not installed next to it" 'grep -Eq "^   (1  Podman +not installed - the setup installs it|-  Podman )" <<< "$out" && grep -Eq "2  Docker Engine +[^ ]+ ready" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "Docker is ready" <<< "$out" && ! grep -q "Run these commands" <<< "$out" && grep -q "Install .* step 3 of 9" <<< "$out"'
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
before="$(body "$I")"
out="$(printf 'i\n\n0\n' | bash "$I" menu 2>&1)"
check "volumes without their passwords: named before any question, nothing changed" 'grep -q "Data volumes of project \"inst\" are in Podman, but this folder has no .env" <<< "$out" && grep -q "not needed. Nothing was changed." <<< "$out" && ! grep -q "The container engine runs" <<< "$out" && [ "$(body "$I")" = "$before" ] && [ ! -e "$D/.setup-later" ] && ! grep -Eq "$MUTATING" "$LOG"'

# 23c. The containers of this folder are in the engine the Engine step takes (CONTAINER_ENGINE named
# another one): the repair takes over instead of a new installation
fresh
mkdir -p "$ST/docker"; touch "$ST/docker/up" "$ST/docker/vols"; echo "$D" > "$ST/docker/wd"
echo "MONGO_INITDB_ROOT_PASSWORD=x" > "$D/.env.bak-20261001-120000"
out="$(printf 'i\n\n0\n\n0\n' | PATH="$DPATH" bash "$I" menu 2>&1)"
check "containers found by the Engine step: the repair menu, no new installation" 'grep -Eq "2  Docker Engine +[^ ]+ holds the data of this folder" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "This folder already has an installation" <<< "$out" && grep -q "Install .* step 1 of 7" <<< "$out" && ! grep -q "Install .* step 3 of 9" <<< "$out"'

# 24. The engine is not ready and is not set up: try again, another engine, or stop
fresh
if [ "$(id -u)" -eq 0 ]; then RUNQ='n\n'; else RUNQ=''; fi
out="$(printf "i\n\n${RUNQ}2\n2\n0\n\n0\n" | PATH="$DPATH" SHIM_ROOTLESS=true RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "engine not set up: try again, another engine or stop - then another one chosen" 'grep -Eq "1  Podman +installed - the setup completes it" <<< "$out" && grep -q "Podman is not ready - the Catalog cannot start without it" <<< "$out" && grep -q "Choose another engine" <<< "$out" && [ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "Install .* step 3 of 9" <<< "$out"'
if [ "$(id -u)" -ne 0 ]; then
  check "engine not set up: rootless Podman as a normal user - no try again, start it as root" 'grep -q "Rootful Podman needs root: start rn1-technology-catalog-installer.sh again with sudo." <<< "$out" && ! grep -q "Try again" <<< "$out"'
fi
fresh
out="$(printf "i\n\n${RUNQ}2\n\n0\n\n0\n" | PATH="$DPATH" SHIM_ROOTLESS=true RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "engine not set up, choose another: Enter takes another engine than the one that failed" '[ "$(setting CONTAINER_ENGINE)" = docker ] && grep -q "Docker is ready" <<< "$out" && grep -q "Install .* step 3 of 9" <<< "$out"'
fresh
out="$(printf "i\n\n${RUNQ}x\n3\n0\n\n0\n" | SHIM_ROOTLESS=true RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "engine not set up: an invalid answer is asked again, 0 stops (not the first question)" 'grep -q "Invalid choice: x" <<< "$out" && grep -q "Invalid choice: 3" <<< "$out" && back_in_menu && [ ! -e "$D/.setup-later" ] && ! grep -q "Install .* step 3 of 9" <<< "$out"'
# as root the setup shows its commands and asks: 0 there stops the task at once
fresh
out="$(printf 'i\n\n0\n\n0\n' | PATH="$T/rootbin:$PATH" SHIM_ROOTLESS=true RN1_SYSTEMD_DIR="$T" bash "$I" menu 2>&1)"
check "engine setup: 0 at its own question stops the task at once" 'back_in_menu && ! grep -q "Choose another engine" <<< "$out" && ! grep -q "Install .* step 3 of 9" <<< "$out" && ! grep -Eq "^systemctl (enable|start)" "$LOG"'

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
  check "proxy host refused: named with option 24, then the data and the summary" 'grep -q "did not create the proxy host of catalog.example.com (HTTP 500" <<< "$out" && grep -q "Nginx Proxy Manager is not set up for catalog.example.com yet (see above)." <<< "$out" && grep -q "Option 24 retries it." <<< "$out" && grep -q "Install .* step 9 of 9" <<< "$out" && [ ! -e "$D/.domain-certificate" ]'

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
check "domain: not in DNS yet - named, not blocked" 'grep -q "catalog.example.com is not in DNS yet" <<< "$out" && grep -q "Install .* step 4 of 9" <<< "$out"'
fresh
dns catalog.example.com 192.0.2.10
out="$(printf 'i\n\ncatalgo.example.com\nn\ncatalog.example.com\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "domain: a typo not in DNS typed again on the same screen, the typo never saved" 'grep -q "catalgo.example.com is not in DNS yet" <<< "$out" && grep -q "catalog.example.com points to this server" <<< "$out" && [ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && ! grep -q catalgo "$I"'
fresh 's/^CATALOG_DOMAIN=.*/CATALOG_DOMAIN="catalog.example.com"/'
dns catalog.example.com 192.0.2.10
out="$(printf 'i\n\nhttp://\n\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "domain: an input without a host name is refused, the saved domain stays" 'grep -q "Give a host name, e.g. catalog.example.com (- removes the domain)." <<< "$out" && [ "$(setting CATALOG_DOMAIN)" = catalog.example.com ] && grep -q "Install .* step 4 of 9" <<< "$out"'

# 29. .setup-later: the I card still runs the task, and a completed installation removes the marker
fresh
touch "$D/.setup-later"
out="$(printf 'i\n\n\n\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
check "I with .setup-later: the new installation runs, the marker goes when it is done" 'grep -q "Install .* step 2 of 9" <<< "$out" && grep -q "The Catalog is installed" <<< "$out" && [ ! -e "$D/.setup-later" ]'

# 30. What is installed here - the containers, the data volumes, the files - in the header, the I and U cards,
#     status (9) and check (16): "up to date" only for an installed Catalog. After option 99, or R that kept the
#     files, nothing is installed: the header names the version a start would install, I is a new installation.
# states_installed -> Catalog 26.3 (the newest on Docker Hub) installed by this installer and running
states_installed() {
  installed
  # (catalog-web of 26.3 first: generate does not raise a running 25.4 without asking)
  echo "26.3.4789.148" > "$ST/catalog_tag"
  sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="true"/' "$I"
  (cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  : > "$LOG"
}
plain_menu() { printf '0\n' | COLUMNS=80 bash "$I" menu 2>&1; }
# installed: the header and the cards of the plain menu (VERSION STATE-TEXT)
installed_cards() {
  grep -q "Installation Portal   (Catalog 26.3.4789.148 - up to date)$" <<< "$out" && grep -Eq "I\) INSTALL +.* $1$" <<< "$out" \
    && grep -Eq "U\) UPDATE +.* Catalog up to date$" <<< "$out" && ! grep -q "not installed" <<< "$out"
}
# nothing installed, only the files: the header, the cards, no "up to date"
files_cards() {
  grep -q "Installation Portal   (Catalog not installed - 26.3.4789.148 would be installed (the newest))$" <<< "$out" \
    && grep -Eq "I\) INSTALL +.* Not installed: no containers, no data$" <<< "$out" && grep -Eq "U\) UPDATE +Nothing installed yet$" <<< "$out" \
    && grep -Eq "R\) REMOVE +.* Remove what is left$" <<< "$out" && ! grep -q "up to date" <<< "$out"
}
fresh 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="true"/; s/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/'
out="$(plain_menu)"
check "state none: not installed - the version a start would install and the newer one, never up to date" 'grep -q "Installation Portal   (Catalog not installed - 25.4.4191.133 would be installed, newer: 26.3.4789.148 (stable), option 8)$" <<< "$out" && grep -Eq "I\) INSTALL +.* New installation, step by step$" <<< "$out" && grep -Eq "U\) UPDATE +Nothing installed yet$" <<< "$out" && grep -Eq "R\) REMOVE +Nothing installed$" <<< "$out" && ! grep -q "up to date" <<< "$out"'
states_installed
out="$(plain_menu)"
check "state running: the installed Catalog up to date, the I card with the services" 'installed_cards "Catalog 26\.3\.4789\.148 . 3 running"'
touch "$ST/stopped"
out="$(plain_menu)"
check "state stopped (containers, none runs): installed, up to date, the I card says stopped" 'installed_cards "Catalog 26\.3\.4789\.148 . stopped" && grep -q "^Stack  : 0 service(s) running$" <<< "$out"'
out="$(bash "$I" status </dev/null 2>&1)"
check "state stopped: status names it" 'grep -q "^Catalog 26.3.4789.148 installed, stopped - .* up. starts it$" <<< "$out"'
rm -f "$ST/stopped"
out="$(printf '13\ny\n\n0\n' | bash "$I" menu 2>&1)"
check "option 13: the containers go, the data volumes stay" '[ ! -f "$ST/up" ] && [ -f "$ST/vols" ] && grep -q "Stack stopped. Data volumes are kept" <<< "$out"'
out="$(plain_menu)"
check "state data only (after 13): installed, up to date, the I card says the data is kept" 'installed_cards "Data kept, no containers"'
out="$(printf '9\n\n16\n\n0\n' | bash "$I" menu 2>&1)"
check "state data only: status and check say the same" 'grep -q "^Catalog 26.3.4789.148 installed: its data is kept, no containers - menu option 6 starts it again$" <<< "$out" && grep -q "Catalog 26.3.4789.148 is installed here: its data is kept, no containers - menu option 6 starts it again." <<< "$out"'

# after option 99: the files of this installer stay, nothing else - no note about them (the host name and the
# cache of MongoDB in .env are what the next generate writes too)
states_installed
p1="$(envv MONGO_INITDB_ROOT_PASSWORD)"
out="$(printf '99\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "option 99: containers and data volumes gone, the files kept" '[ ! -f "$ST/up" ] && [ ! -f "$ST/vols" ] && [ -f "$D/.env" ] && [ -f "$D/docker-compose.yml" ] && grep -q "Containers and data volumes removed." <<< "$out"'
rm -f "$ST/license"
out="$(plain_menu)"
check "after 99: not installed - the version a start would install, the cards, never up to date" 'files_cards'
check "after 99: the files of this installer are no difference (no note)" '! grep -q -e "option 2 regenerates them" -e "do not match the settings" -e "differ from" <<< "$out"'
out="$(printf '9\n\n16\n\n0\n' | bash "$I" menu 2>&1)"
check "after 99: status says nothing is installed and what a start installs" 'grep -q "^Catalog not installed: no containers and no data volumes, only .env and docker-compose.yml.$" <<< "$out" && grep -q "^A start makes a new, empty Catalog - 26.3.4789.148 would be installed (the newest).$" <<< "$out" && grep -q "^Start it with menu option 6, or step by step with I.$" <<< "$out" && ! grep -q "installed: its data\|installed, stopped" <<< "$out"'
check "after 99: check says the same" 'grep -q "Catalog not installed here: no containers and no data volumes, only .env and docker-compose.yml - a start makes a new, empty Catalog: 26.3.4789.148 would be installed (the newest).$" <<< "$out"'
: > "$LOG"
out="$(printf 'u\n\n21\n\n0\n' | bash "$I" menu 2>&1)"
check "after 99: U and option 21 have nothing to update" 'grep -q "Nothing is installed in this folder yet - I installs the Catalog." <<< "$out" && grep -q "Only .env and docker-compose.yml are here, no containers and no data." <<< "$out" && grep -q "There is nothing to upgrade - option 8 picks the versions, I or option 6 installs the Catalog." <<< "$out" && ! grep -q -e "The Catalog is up to date" -e "Update . step" -e "Installed Catalog:" <<< "$out" && ! grep -Eq "$MUTATING" "$LOG"'
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/' "$I"
out="$(plain_menu)"
check "after 99, older settings: a start installs what the files name, option 2 what the settings say" 'grep -q "(Catalog not installed - 26.3.4789.148 would be installed (the files; option 2 writes 25.4.4191.133))$" <<< "$out" && ! grep -q "up to date" <<< "$out"'
out="$(bash "$I" status </dev/null 2>&1)"
check "after 99, older settings: status names the version of the files" 'grep -q "^A start makes a new, empty Catalog - 26.3.4789.148 would be installed (the files; option 2 writes 25.4.4191.133).$" <<< "$out"'
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$I"
# I on these files: a new installation (the versions of a new one, the passwords of the files), not a repair
: > "$LOG"
out="$(printf 'i\n\n\n\n\n\n\n\n0\n' | bash "$I" menu 2>&1)"
check "I after 99: a new installation on the files, not a repair of nothing" 'grep -q "New installation on the files of this folder: no containers and no data" <<< "$out" && grep -q "Install .* step 6 of 9" <<< "$out" && ! grep -q -e "already has an installation" -e "Repair:" -e "passwords, data and version are kept" <<< "$out"'
check "I after 99: the recommended versions, the passwords of the files, started" 'grep -q "recommended" <<< "$out" && [ "$(setting CATALOG_VERSION)" = 26.3.4789.148 ] && [ "$(envv MONGO_INITDB_ROOT_PASSWORD)" = "$p1" ] && grep -q "up -d --remove-orphans" "$LOG" && [ -f "$ST/up" ] && grep -q "The Catalog is installed" <<< "$out"'
out="$(plain_menu)"
check "I after 99: then installed and running again" 'installed_cards "Catalog 26\.3\.4789\.148 . 3 running"'

# R that keeps the files: the same as after 99
states_installed
out="$(printf 'r\nn\ny\n3\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "R keeping the files: the containers and the data volumes gone, the files kept" '[ ! -f "$ST/up" ] && [ ! -f "$ST/vols" ] && [ -f "$D/.env" ] && [ -f "$D/docker-compose.yml" ] && grep -q "The Catalog was removed from this server" <<< "$out"'
out="$(plain_menu)"
check "after R keeping the files: not installed, never up to date, no note about the files" 'files_cards && ! grep -q -e "option 2 regenerates them" -e "do not match the settings" <<< "$out"'

# a licensed catalog-web that kept its container ID as host name (the repair of older files), the cache of
# MongoDB in .env: after 99 no note either - the next generate keeps that name and writes the cache anew
installed; sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
printf 'i\n1\ny\ny\n\ny\ny\ny\n0\n\n0\n' | bash "$I" menu >/dev/null 2>&1
printf '99\nDELETE\n\n0\n' | bash "$I" menu >/dev/null 2>&1
out="$(plain_menu)"
check "after 99, the container ID kept as host name and the cache in .env: not installed, no note" '[ "$(envv CATALOG_HOSTNAME)" = c2 ] && [ -n "$(envv MONGO_WT_CACHE_GB)" ] && [ ! -f "$ST/vols" ] && grep -q "Installation Portal   (Catalog not installed - 25.4.4191.133 would be installed)$" <<< "$out" && ! grep -q -e "option 2 regenerates them" -e "do not match the settings" <<< "$out"'

# the files of an installer older than the fixed host name: after 99 they really differ from what option 2 writes
states_installed
sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
printf '99\nDELETE\n\n0\n' | bash "$I" menu >/dev/null 2>&1
out="$(plain_menu)"
check "after 99, files of an older installer: not installed, the note names the older installer" 'files_cards && grep -q "The generated files do not match the settings above (written by an older installer) - option 2 regenerates them." <<< "$out"'

# after 99, older settings written into the files (option 2): the version of the settings, the newer one with option 8
states_installed
printf '99\nDELETE\n\n0\n' | bash "$I" menu >/dev/null 2>&1
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/' "$I"
(cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
out="$(plain_menu)"
check "after 99 and option 2 with older settings: the newer version named with option 8, never up to date" '[ "$(envv CATALOG_IMAGE)" = raynetgmbh/rayventory-catalog:25.4.4191.133 ] && grep -q "(Catalog not installed - 25.4.4191.133 would be installed, newer: 26.3.4789.148 (stable), option 8)$" <<< "$out" && ! grep -q -e "up to date" -e "regenerates them" <<< "$out"'
out="$(printf '8\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "after 99: option 8 names the Catalog not installed, never up to date" 'grep -q "Catalog + 4 workers .*25.4.4191.133 .*newer available - not installed" <<< "$out" && ! grep -q "Catalog + 4 workers.*up to date" <<< "$out"'

# the engine cannot tell what is installed: the version of the settings, no "up to date" anywhere
states_installed
printf '99\nDELETE\n\n0\n' | bash "$I" menu >/dev/null 2>&1
out="$(printf '0\n' | SHIM_SOCKET_DOWN=1 COLUMNS=80 bash "$I" menu 2>&1)"
check "after 99, Podman's API down: the settings named, not up to date, U without a claim" 'grep -q "Installation Portal   (Catalog 26.3.4789.148 (the settings))$" <<< "$out" && grep -Eq "I\) INSTALL +! Podman not reachable$" <<< "$out" && grep -Eq "U\) UPDATE +.* Installer and Catalog$" <<< "$out" && ! grep -q "up to date" <<< "$out"'
rm -f "$D/docker-compose.yml"
out="$(plain_menu)"
check "only .env left, nothing else: incomplete, the settings named, not up to date" 'grep -q "Installation Portal   (Catalog 26.3.4789.148 (the settings))$" <<< "$out" && grep -q "Incomplete: no compose file" <<< "$out" && grep -Eq "U\) UPDATE +.* Installer and Catalog .* repair first \(I\), then U$" <<< "$out" && ! grep -q "up to date" <<< "$out"'

# catalog-web's container removed, the other containers of the stack there but stopped: stopped, not "no containers"
states_installed
touch "$ST/stopped" "$ST/web-gone"
out="$(plain_menu)"
check "catalog-web removed, the rest stopped: installed and stopped (from the data), not data only" 'installed_cards "Catalog 26\.3\.4789\.148 . stopped" && ! grep -q "no containers" <<< "$out"'
out="$(bash "$I" status </dev/null 2>&1)"
check "catalog-web removed, the rest stopped: status says stopped" 'grep -q "^Catalog 26.3.4789.148 installed, stopped - .* up. starts it$" <<< "$out" && ! grep -q "no containers" <<< "$out"'
rm -f "$ST/stopped" "$ST/web-gone"

# a failed upgrade leaves a mark (option 21 offers going back): 99 and R with the data remove it - nothing to go
# back to; an older mark is removed by option 21 where nothing is installed
states_installed
echo "25.4.4191.133|26.3.4789.148|backups/mongo-x.archive.gz" > "$D/.upgrade-failed"
printf '99\nDELETE\n\n0\n' | bash "$I" menu >/dev/null 2>&1
check "option 99: the mark of a failed upgrade goes with the data" '[ ! -f "$D/.upgrade-failed" ] && [ ! -f "$ST/vols" ]'
echo "25.4.4191.133|26.3.4789.148|backups/mongo-x.archive.gz" > "$D/.upgrade-failed"
out="$(printf '21\n\n0\n' | bash "$I" menu 2>&1)"
check "after 99, an older mark: option 21 has nothing to go back to and removes it" 'grep -q "There is nothing to upgrade" <<< "$out" && ! grep -q "Go back to" <<< "$out" && [ ! -f "$D/.upgrade-failed" ]'
states_installed
echo "25.4.4191.133|26.3.4789.148|backups/mongo-x.archive.gz" > "$D/.upgrade-failed"
out="$(printf 'r\nn\ny\n3 4\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "R removing the data, keeping the files and the job logs: the mark of a failed upgrade goes with the data" 'grep -q "Job logs, stored API keys and markers" <<< "$out" && [ ! -f "$ST/vols" ] && [ -f "$D/.env" ] && [ -d "$D/.jobs" ] && [ ! -f "$D/.upgrade-failed" ]'

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
  check "first start: the welcome and the new installation, without asking for the engine first" '{ grep -q "New installation. A few questions - engine, domain, proxy, versions - then$" <<< "$out" && grep -q "the Catalog starts. 0 at any question opens the full menu." <<< "$out" && grep -q "Install .* step 2 of 9" <<< "$out" && ! grep -q "Prerequisites are not met" <<< "$out"; } || { printf "%s\n" "$out" | tail -n 40 | sed "s/^/  | /"; false; }'
  check "first start: 0 at the first question - stopped, .setup-later, then the full menu" 'grep -q "Stopped. I starts it again" <<< "$out" && [ -f "$D/.setup-later" ] && grep -q "Type a number - what it does shows here" <<< "$out"'
  out="$(tty_run "bash $I menu" "Select:" q)"
  check "second start after 0: the menu opens directly" '! grep -q "New installation. A few questions" <<< "$out" && grep -q "Type a number - what it does shows here" <<< "$out"'
  fresh
  out="$(tty_run "bash $I menu" "Select \[1\]:" '\n' "Domain name \[none\]:" '\n' "Install Nginx Proxy Manager" '\n' "Enter, or a row:" '\n' "Write the files and start the Catalog" '\n' "Press any key to continue" ' ' "By license file" '' "Select \[0\]:" '\n' "Press Enter to open the menu" '\n' "Select:" q)"
  check "first start in a terminal: installed with Enter only (the license later), then the full menu" '{ [ -f "$D/.env" ] && [ -f "$ST/up" ] && grep -q "The Catalog is installed" <<< "$out" && grep -q "Later: option 25 activates the Catalog." <<< "$out" && grep -q "Next: the full menu" <<< "$out" && grep -q "Type a number - what it does shows here" <<< "$out" && [ ! -e "$D/.setup-later" ]; } || { printf "%s\n" "$out" | tail -n 40 | sed "s/^/  | /"; false; }'
  check "first start in a terminal: the address line on the versions screen, no question after the start" '{ grep -q "The Catalog: http://192.0.2.10:8080" <<< "$out" && ! grep -q "Continue with the catalog data" <<< "$out"; } || { printf "%s\n" "$out" | tail -n 40 | sed "s/^/  | /"; false; }'
  # a failed license step stays on the screen until a key (the summary clears it); later goes on at once
  fresh
  out="$(tty_run "bash $I menu" "Select \[1\]:" '\n' "Domain name \[none\]:" '\n' "Install Nginx Proxy Manager" '\n' "Enter, or a row:" '\n' "Write the files and start the Catalog" '\n' "Press any key to continue" ' ' "By license file" '' "Select \[0\]:" '2\n' "user name \[root\]:" '\n' "Password" 'rootpw\n' "Path of the license file" '/none/1\n' "Select \[0\]:" '2\n' "Path of the license file" '/none/2\n' "Select \[0\]:" '2\n' "Path of the license file" '/none/3\n' "Press any key to continue" ' ' "Press Enter to open the menu" '\n' "Select:" q)"
  check "license step in a terminal: after three failures the reasons stay until a key, then the summary" '{ sed -n "/Stopped after 3 failed attempts/,/step 9 of 9/p" <<< "$out" | grep -q "Press any key to continue" && grep -q "The Catalog has no data yet: it is not activated" <<< "$out"; } || { printf "%s\n" "$out" | tail -n 40 | sed "s/^/  | /"; false; }'
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
  # (without the warning of a bash started with a locale that is not installed - not a text of the installer)
  wide="$(sed -n '/step 1 of 9/,/Checking the engine, Compose/p' <<< "$out" | LC_ALL=C grep -v '[^ -~]' | grep -v '^bash: warning: setlocale: ' | awk 'length($0) > 80')"
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

  # The logo above the menu: 4 rows centred as one block (75 columns wide: 22 columns margin at 120),
  # CATALOG (from column 48) in bold; only from 80 columns and when the whole menu fits below it
  installed
  # the rows as the installer holds them: first the UTF-8 rows, then the ASCII ones
  mapfile -t LOGO_ALL < <(sed -n '/^  UI_LOGO=($/,/^  )$/p' "$I" | sed -n "s/^    '\(.*\)'$/\1/p")
  LOGO_U=("${LOGO_ALL[@]:0:4}")
  LOGO_A=("${LOGO_ALL[@]:4:4}")
  # the rows the installer takes with LC_ALL=C.UTF-8: the UTF-8 ones only where that locale is installed
  # (bash then counts a line character as one), else the ASCII ones (CentOS 7 has no C.UTF-8)
  if [ "$(LC_ALL=C.UTF-8 bash -c 'p="$(printf "\342\224\200")"; printf "%s" "${#p}"' 2>/dev/null)" = 1 ]; then
    LOGO_C=("${LOGO_U[@]}")
  else
    LOGO_C=("${LOGO_A[@]}")
  fi
  BOLD=$'\e[1m' NORM=$'\e[0m'
  # logo_at PAD ROW... -> true when the rows follow each other in $out, each after PAD spaces, then a
  # blank line and the header of the menu
  logo_at() {
    local pad="$1" first i
    shift
    first="$(grep -n -m1 -xF -- "$(printf '%*s' "$pad" '')$1" <<< "$out" | cut -d: -f1)"
    [ -n "$first" ] || return 1
    for ((i = 1; i <= $#; i++)); do
      [ "$(sed -n "$((first + i - 1))p" <<< "$out")" = "$(printf '%*s' "$pad" '')${!i}" ] || return 1
    done
    [ -z "$(sed -n "$((first + $#))p" <<< "$out")" ] || return 1
    sed -n "$((first + $# + 1))p" <<< "$out" | grep -q "RAYNET ONE TECHNOLOGY CATALOG\|Raynet One Technology Catalog - Installation Portal"
  }
  out="$(TTY_SIZE=120x50 tty_run "LC_ALL=C.UTF-8 bash $I menu" "Select:" q)"
  check "logo: 120x50 shows the 4 rows centred above the header box" '[ ${#LOGO_ALL[@]} -eq 8 ] && logo_at 22 "${LOGO_C[@]}" || { printf "%s\n" "$out" | head -n 12 | sed "s/^/  | /"; false; }'
  check "logo: CATALOG in bold, the mark and TECHNOLOGY in normal weight" 'grep -aqF -- "$(printf "%22s" "")${LOGO_C[1]:0:48}$BOLD${LOGO_C[1]:48}$NORM" "$T/tty.log"'
  check "logo: the whole menu below it (legend and keys)" 'grep -q "Number + Enter runs it" <<< "$out" && grep -q "Type a number - what it does shows here" <<< "$out"'
  out="$(TTY_SIZE=120x43 tty_run "LC_ALL=C.UTF-8 bash $I menu" "Select:" q)"
  check "logo: not in a short terminal (120x43), the full menu as before" '! grep -qF -- "${LOGO_U[3]:0:30}" <<< "$out" && grep -q "Number + Enter runs it" <<< "$out"'
  out="$(TTY_SIZE=79x80 tty_run "LC_ALL=C.UTF-8 bash $I menu" "Select an option:" '0\n')"
  check "logo: not at 79 columns (plain menu), even with rows enough" '! grep -qF -- "${LOGO_U[3]:0:30}" <<< "$out" && grep -q "Raynet One Technology Catalog - Installation Portal" <<< "$out"'
  out="$(TTY_SIZE=100x80 tty_run "RVC_UI=plain LC_ALL=C.UTF-8 bash $I menu" "Select an option:" '0\n')"
  check "logo: the plain menu in a tall terminal (100x80) shows it centred above its header" 'logo_at 12 "${LOGO_C[@]}" || { printf "%s\n" "$out" | head -n 12 | sed "s/^/  | /"; false; }'
  out="$(TTY_SIZE=100x40 tty_run "RVC_UI=plain LC_ALL=C.UTF-8 bash $I menu" "Select an option:" '0\n')"
  check "logo: not in the plain menu when it does not fit (100x40)" '! grep -qF -- "${LOGO_U[3]:0:30}" <<< "$out" && grep -q "Raynet One Technology Catalog - Installation Portal" <<< "$out"'
  out="$(TTY_SIZE=120x50 tty_run "LC_ALL=C bash $I menu" "Select:" q)"
  check "logo: ASCII in a C locale, centred the same" '[ ${#LOGO_A[@]} -eq 4 ] && logo_at 22 "${LOGO_A[@]}" && ! grep -qF -- "${LOGO_U[1]:48:3}" <<< "$out" || { printf "%s\n" "$out" | head -n 12 | sed "s/^/  | /"; false; }'

  # 30 in full screen: the header and the cards of each state, at 120x40 and 200x50 (the cards side by side
  # on one line), no text cut
  tui_state() { TTY_SIZE="$1" tty_run "bash $I menu" "Select:" q; }
  uncut() { ! grep -E "running|stopped|starts|kept|containers|installed" <<< "$out" | grep -q "~ "; }
  states_installed
  out="$(tui_state 120x40)"
  check "full screen 120x40, running: up to date, the cards" '{ grep -q "Catalog 26.3.4789.148 .* up to date" <<< "$out" && grep -q "Installed .* 3 running .*Catalog up to date" <<< "$out" && ! grep -q "not installed" <<< "$out" && uncut; } || { printf "%s\n" "$out" | head -n 12 | sed "s/^/  | /"; false; }'
  out="$(tui_state 200x50)"
  check "full screen 200x50, running: the version in the I card" 'grep -q "Catalog 26.3.4789.148 .* up to date" <<< "$out" && grep -q "Catalog 26.3.4789.148 .* 3 running .*Catalog up to date" <<< "$out" && uncut'
  touch "$ST/stopped"
  out="$(tui_state 120x40)"
  check "full screen 120x40, stopped: up to date, the I card says stopped" 'grep -q "Catalog 26.3.4789.148 .* up to date" <<< "$out" && grep -q "Installed .* stopped .*Catalog up to date" <<< "$out" && grep -q "6 starts it .* or repair .*installer and patches" <<< "$out" && uncut'
  out="$(tui_state 200x50)"
  check "full screen 200x50, stopped: the version in the I card" 'grep -q "Catalog 26.3.4789.148 .* stopped .*Catalog up to date" <<< "$out" && uncut'
  rm -f "$ST/stopped"
  printf '13\ny\n\n0\n' | bash "$I" menu >/dev/null 2>&1
  out="$(tui_state 120x40)"
  check "full screen 120x40, data only (after 13): up to date, the data kept" 'grep -q "Catalog 26.3.4789.148 .* up to date" <<< "$out" && grep -q "Data kept, no containers .*Catalog up to date" <<< "$out" && grep -q "6 starts it again .* or repair" <<< "$out" && uncut'
  out="$(tui_state 200x50)"
  check "full screen 200x50, data only: the version in the I card" 'grep -q "Catalog 26.3.4789.148 .* data kept, no containers .*Catalog up to date" <<< "$out" && uncut'
  states_installed
  printf '99\nDELETE\n\n0\n' | bash "$I" menu >/dev/null 2>&1
  for size in 100x40 120x40; do
    out="$(tui_state "$size")"
    check "full screen $size, after 99: not installed, the version a start would install, never up to date" '{ grep -q "Catalog not installed .* 26.3.4789.148 would be installed (the newest)" <<< "$out" && grep -q "No containers, no data .*Nothing installed yet .*Remove what is left" <<< "$out" && grep -q "6 starts a new.*install first (I)" <<< "$out" && ! grep -q -e "up to date" -e "option 2 regenerates" <<< "$out" && uncut; } || { printf "%s\n" "$out" | head -n 12 | sed "s/^/  | /"; false; }'
  done
  out="$(tui_state 200x50)"
  check "full screen 200x50, after 99: the long texts of the cards" 'grep -q "Catalog not installed .* 26.3.4789.148 would be installed (the newest)" <<< "$out" && grep -q "Not installed: no containers, no data .*Nothing installed yet" <<< "$out" && grep -q "6 starts a new, empty Catalog .* I installs it step by step .*install first (I)" <<< "$out" && ! grep -q "up to date" <<< "$out" && uncut'
  # the settings changed after 99: the version of the files, what option 2 writes
  sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/' "$I"
  for size in 100x40 120x40 200x50; do
    out="$(tui_state "$size")"
    check "full screen $size, after 99, older settings: the version of the files, option 2" '{ grep -q "ot installed .*26.3.4789.148 .*option 2 writes 25.4.4191.133" <<< "$out" && ! grep -q "up to date" <<< "$out" && ! grep "ot installed" <<< "$out" | grep -q "~"; } || { printf "%s\n" "$out" | head -n 12 | sed "s/^/  | /"; false; }'
  done
  # option 2 writes the older settings: the newer version, shortened beside the internet line (2 optional sites
  # blocked, the check of the menu start in its cache) - nothing cut
  (cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  mkdir -p "$D/.jobs"
  { printf '%s|%s|5\n' "$(date +%s)" "$(RN1_NET_CHECK=on bash "$I" __net signature)"
    printf '%s\n' "hub|OK|req|site-1.example:443|images|" "cloud|BLOCKED|opt|site-2.example:443|catalog data|" "license|BLOCKED|opt|site-3.example:443|license|"
  } > "$D/.jobs/internet-check"
  for size in 100x40 120x40; do
    out="$(TTY_SIZE="$size" tty_run "RN1_NET_CHECK=on bash $I menu" "Select:" q)"
    check "full screen $size, nothing installed, older settings, the internet line: the newer version, nothing cut" '{ grep -q "ot installed .*26.3.4789.148 is newer .*Internet .* 2 optional sites blocked" <<< "$out" && ! grep "ot installed" <<< "$out" | grep -q "~"; } || { printf "%s\n" "$out" | head -n 12 | sed "s/^/  | /"; false; }'
  done
  # the plain menu at 100 columns: the state of the Catalog on a line of its own, no line wider than the terminal;
  # the logo exactly when the whole menu fits below it
  out="$(TTY_SIZE=100x200 tty_run "RVC_UI=plain LC_ALL=C bash $I menu" "Select an option:" '0\n')"
  wide="$(sed -n '/^Raynet One Technology Catalog - Installation Portal/,/Select an option:/p' <<< "$out" | awk 'length($0) > 100')"
  check "plain menu at 100 columns, nothing installed: the title alone, the Catalog on its own line, nothing wider" '{ grep -qx "Raynet One Technology Catalog - Installation Portal" <<< "$out" && grep -qx "Catalog: not installed - 25.4.4191.133 would be installed, newer: 26.3.4789.148 (stable), option 8" <<< "$out" && [ -z "$wide" ]; } || { printf "%s\n" "$wide" | head -5; false; }'
  first="$(grep -n -m1 -xF -- "$(printf '%12s' '')${LOGO_A[0]}" <<< "$out" | cut -d: -f1)"
  last="$(grep -n -m1 "Select an option:" <<< "$out" | cut -d: -f1)"
  fit=$((${last:-0} - ${first:-0} + 1))
  out="$(TTY_SIZE="100x$fit" tty_run "RVC_UI=plain LC_ALL=C bash $I menu" "Select an option:" '0\n')"
  check "plain menu at 100 columns: the logo when the whole menu fits below it (100x$fit)" '[ -n "$first" ] && logo_at 12 "${LOGO_A[@]}" || { printf "%s\n" "$out" | head -n 8 | sed "s/^/  | /"; false; }'
  out="$(TTY_SIZE="100x$((fit - 1))" tty_run "RVC_UI=plain LC_ALL=C bash $I menu" "Select an option:" '0\n')"
  check "plain menu at 100 columns: no logo a row shorter (100x$((fit - 1)))" '! grep -qF -- "${LOGO_A[3]:0:30}" <<< "$out" && grep -qx "Raynet One Technology Catalog - Installation Portal" <<< "$out"'
  rm -rf "$D/.jobs"
else
  echo "SKIP: script (util-linux) missing - no test of the first start and of the full screen typing hints"
fi

check "fakes: no unknown podman, docker, provider, systemctl, curl or DNS call in the whole suite" '[ ! -s "$BAD" ] || { sort "$BAD" | uniq -c | head -20; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
