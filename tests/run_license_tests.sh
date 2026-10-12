#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/l"
rm -rf "$T"; mkdir -p "$T/bin" "$T/srv" "$T/tmp" "$T/call"
# these tests run Podman: CONTAINER_ENGINE names it (on a CI runner, detection would see its real Docker)
sed 's/^CONTAINER_ENGINE=""$/CONTAINER_ENGINE="podman"/' "$1" > "${T%/*}/podman-installer.sh"; NEW="${T%/*}/podman-installer.sh"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# the internet check (menu start, new installation, option 16, engine setup) has its own suite (run_network_tests)
export RN1_NET_CHECK=off
# LOG: every curl command line. SRV: the fake Catalog - license (its status; missing: none), calls, and what
# the activations received (got-*). BAD: calls the fakes do not know, for the whole suite.
export LOG="$T/curl.log" SRV="$T/srv" BAD="$T/bad.log" SHIM_LOG="$T/podman.log"
: > "$LOG"; : > "$BAD"; : > "$SHIM_LOG"
ROOTPW='R00t-pw!x'
ADMINPW='Adm1n-pw'
LOCALKEY="AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD"
VALID="ABCDEF0-1234567-89ABCDE-F012345"
ORDER="ORD-TEST-0001"
export ROOTPW ADMINPW LOCALKEY VALID ORDER

# The license file (binary: every byte value once, then text) and the license text of an e-mail; fake data
for i in $(seq 0 255); do printf "\\$(printf '%03o' "$i")"; done > "$SRV/valid.rswl"
printf 'not a real license\r\nline 2\n' >> "$SRV/valid.rswl"
cat > "$SRV/valid.txt" <<'EOF'
============================= LICENSE STARTS HERE ==============================
RmFrZSBsaWNlbnNlIHRleHQgZm9yIHRoZSB0ZXN0cyBvZiB0aGUgaW5zdGFsbGVyIC0gbm90IHJlYWw=
VGhpcyBpcyB0aGUgc2Vjb25kIGxpbmUgb2YgdGhlIGZha2UgbGljZW5zZSB0ZXh0Lg==
============================== LICENSE ENDS HERE ===============================
EOF
OKBODY='{"orderNumber":"ORD-TEST-0001","userName":"Test User","companyName":"Example GmbH","email":"it@mail.example.net","activationDate":"2026-10-11T00:00:00","expirationDate":"2027-12-31T00:00:00","licenseHardwareId":"HID8-4B1E","yourHardwareId":"HID8-4B1E-11-22-33","status":"Ok","edition":"Enterprise","version":"26.3"}'
export OKBODY

# Fake curl: Catalog Web on localhost:8080 as the license code of the Catalog behaves - isValid without a
# login; GET /v1/license for any login, the hardware ID only for the SiteAdmin root, the edition and the
# version only for a valid license; the three activations only for root (admin: 403); every controller that
# needs a license answers 520 until the status is Ok. Users: root (SiteAdmin) and admin (Admin); the local key
# has the Admin role. The online catalog answers the manifest for the key $VALID. SHIM_DOWN: Catalog Web does
# not answer ($SRV/down too). SHIM_ISVALID: the answer of isValid (else from the license). SHIM_LIC_ERROR: every
# activation is refused with this message (HTTP 400). SHIM_LIC_PROBLEM: refused with a problem object.
# SHIM_FORBID: activations refused (403). SHIM_ORDER_TIMEOUT: the order activation gets no answer.
# SHIM_ORDER_DOWN: Catalog Web goes down during the order activation. SHIM_ORDER_SLOW: the order activation
# hangs (the PID of the fake in $SRV/curl.pid). SHIM_LIC_UNSAVED: the Catalog takes the license but cannot
# save it (400 unknown-issue, valid until a restart). SHIM_520_UPLOAD / SHIM_520_OPERATION: the upload / the
# operation 520. SHIM_VERSION_JSON: the version in the license details. SHIM_DETAILS_FAIL: the details fail
# (HTTP 400, a damaged license).
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$LOG"
out=/dev/stdout; fmt=""; url=""; cfg=""; method=GET; data=""; form=""; maxtime=""; ctype=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -K) [ "$2" = "-" ] && cfg="$(cat)"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -F) form="$2"; shift 2 ;;
    -H) case "$2" in Content-Type:*) ctype="${2#Content-Type: }" ;; esac; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    --max-time) maxtime="$2"; shift 2 ;;
    --connect-timeout|--retry|--retry-delay|--proto) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ "$method" = GET ] && { [ -n "$form" ] || [ -n "$data" ]; }; then method=POST; fi
reply() { printf '%s' "$2" > "$out"; [ -n "$fmt" ] && printf '%s' "${fmt//%\{http_code\}/$1}"; exit 0; }
if [[ "$url" == https://rayventorycatalog.raynet.de/* ]]; then
  key="$(printf '%s' "$cfg" | sed -n 's/^header = "X-Api-Key: \(.*\)"$/\1/p')"
  [ "$key" = "$VALID" ] || reply 401 '{"detail":"Api key is not registered in the database."}'
  [ "$url" = https://rayventorycatalog.raynet.de/v3/synchronization/manifest ] && reply 200 '{"generatedAt":"2026-10-11T02:00:00Z","dailyDeltas":[],"cumulativeDeltas":[]}'
  echo "UNHANDLED curl $method $url" >> "$BAD"; reply 404 ""
fi
case "$url" in
  http://localhost:8080/*) p="/${url#http://localhost:8080/}" ;;
  *) echo "UNHANDLED curl $method $url" >> "$BAD"; reply 404 "" ;;
esac
{ [ -n "${SHIM_DOWN:-}" ] || [ -f "$SRV/down" ]; } && { printf '000'; exit 7; }
auth="$(printf '%s' "$cfg" | sed -n 's/^header = "\(.*\)"$/\1/p')"
case "$auth" in
  "Authorization: Bearer TOKROOT") role=SiteAdmin ;;
  "Authorization: Bearer TOKADMIN") role=Admin ;;
  "X-Api-Key: $LOCALKEY") role=Admin ;;
  "") role=none ;;
  *) role=bad ;;
esac
echo "$method $p $role" >> "$SRV/calls"
st="$(cat "$SRV/license" 2>/dev/null)"; st="${st:-NotPresent}"
case "$method $p" in
  "GET /v1/license/isValid")
    [ -n "${SHIM_ISVALID:-}" ] && reply 200 "$SHIM_ISVALID"
    if [ "$st" = Ok ]; then reply 200 true; fi
    reply 200 false ;;
  "POST /v1/authentication/request")
    body="$(cat "${data#@}")"; printf '%s' "$body" > "$SRV/login-body.json"
    case "$(sed -n 's/.*"username":"\([^"]*\)".*/\1/p' <<< "$body")" in
      root) grep -qF "\"password\":\"$ROOTPW\"" <<< "$body" && reply 200 '{"access_token":"TOKROOT","refresh_token":"R","expires_in":3600}' ;;
      admin) grep -qF "\"password\":\"$ADMINPW\"" <<< "$body" && reply 200 '{"access_token":"TOKADMIN","refresh_token":"R","expires_in":3600}' ;;
    esac
    reply 401 "" ;;
esac
# the license filter comes before the login
case "$p" in
  /v1/databaseconfiguration/*|/v1/synchronization/*|/v1/synchronizationHistory/*|/v1/operation/*)
    [ "$st" = Ok ] || reply 520 ""
    [ -n "${SHIM_520_UPLOAD:-}" ] && [ "$p" = /v1/synchronization/snapshot ] && reply 520 ""
    [ -n "${SHIM_520_OPERATION:-}" ] && [[ "$p" == /v1/operation/* || "$p" == /v1/synchronizationHistory/* ]] && reply 520 ""
    ;;
esac
{ [ "$role" = none ] || [ "$role" = bad ]; } && reply 401 ""
case "$method $p" in
  "GET /v1/license")
    [ -n "${SHIM_DETAILS_FAIL:-}" ] && reply 400 "\"Object reference not set to an instance of an object.\""
    if [ "$role" = SiteAdmin ]; then
      [ "$st" = NotPresent ] && reply 200 '{"status":"NotPresent","yourHardwareId":"HID8-4B1E-11-22-33"}'
      # the product (edition, version) only when the license verifies
      [ "$st" = Ok ] && reply 200 "{\"orderNumber\":\"$ORDER\",\"userName\":\"Test User\",\"companyName\":\"Example GmbH\",\"email\":\"it@mail.example.net\",\"activationDate\":\"2026-10-11T00:00:00\",\"expirationDate\":\"2027-12-31T00:00:00\",\"licenseHardwareId\":\"HID8-4B1E\",\"yourHardwareId\":\"HID8-4B1E-11-22-33\",\"status\":\"$st\",\"edition\":\"Enterprise\",\"version\":${SHIM_VERSION_JSON:-\"26.3\"}}"
      reply 200 "{\"orderNumber\":\"$ORDER\",\"userName\":\"Test User\",\"companyName\":\"Example GmbH\",\"email\":\"it@mail.example.net\",\"activationDate\":\"2026-10-11T00:00:00\",\"expirationDate\":\"2027-12-31T00:00:00\",\"licenseHardwareId\":\"HID8-4B1E\",\"yourHardwareId\":\"HID8-4B1E-11-22-33\",\"status\":\"$st\"}"
    fi
    [ "$st" = NotPresent ] && reply 200 '{"status":"NotPresent"}'
    reply 200 "{\"activationDate\":\"2026-10-11T00:00:00\",\"expirationDate\":\"2027-12-31T00:00:00\",\"licenseHardwareId\":\"HID8-4B1E\",\"status\":\"$st\"}" ;;
  "POST /v1/license/activate/"*)
    { [ "$role" = SiteAdmin ] && [ -z "${SHIM_FORBID:-}" ]; } || reply 403 ""
    way="${p##*/}"
    case "$way" in
      file) f="${form#file=@}"; cp "$f" "$SRV/got-file"; echo "$form" > "$SRV/got-form" ;;
      mail) cp "${data#@}" "$SRV/got-text"; stat -c %a "${data#@}" > "$SRV/got-mode"; printf '%s' "$ctype" > "$SRV/got-ctype" ;;
      order) cp "${data#@}" "$SRV/got-order"; stat -c %a "${data#@}" > "$SRV/got-mode"; printf '%s|%s' "$ctype" "$maxtime" > "$SRV/got-order-opts" ;;
      *) echo "UNHANDLED curl $method $url" >> "$BAD"; reply 404 "" ;;
    esac
    if [ -n "${SHIM_LIC_ERROR:-}" ]; then
      m="${SHIM_LIC_ERROR//\\/\\\\}"; m="${m//\"/\\\"}"
      reply 400 "\"$m\""
    fi
    [ -n "${SHIM_LIC_PROBLEM:-}" ] && reply 400 '{"type":"https://tools.ietf.org/html/rfc9110#section-15.5.1","title":"One or more validation errors occurred.","status":400}'
    [ -n "${SHIM_LIC_UNSAVED:-}" ] && { echo Ok > "$SRV/license"; reply 400 '"license.messages.unknown-issue"'; }
    [ -n "${SHIM_ORDER_TIMEOUT:-}" ] && [ "$way" = order ] && { printf '000'; exit 28; }
    [ -n "${SHIM_ORDER_DOWN:-}" ] && [ "$way" = order ] && { touch "$SRV/down"; printf '000'; exit 52; }
    [ -n "${SHIM_ORDER_SLOW:-}" ] && [ "$way" = order ] && { echo $$ > "$SRV/curl.pid"; exec sleep 30; }
    case "$way" in
      file) cmp -s "$SRV/got-file" "$SRV/valid.rswl" || reply 400 '"The license is malformed. No closing marker is present."' ;;
      mail) cmp -s "$SRV/got-text" "$SRV/valid.txt" || reply 400 '"Activation failed with the following error: Unknown order number. Activation not possible."' ;;
      order) grep -q "\"orderNumber\":\"$ORDER\"" "$SRV/got-order" || reply 400 '"Activation failed with the following error: Unknown order number. Activation not possible."' ;;
    esac
    echo Ok > "$SRV/license"
    reply 200 "$OKBODY" ;;
  "GET /v1/databaseconfiguration/synchronization") reply 204 "" ;;
  "POST /v1/databaseconfiguration/synchronization") cp "${data#@}" "$SRV/sync-settings.json"; reply 204 "" ;;
  "POST /v1/synchronization/snapshot") echo "$form" >> "$SRV/uploads"; reply 202 '{"operationId":"op-1","status":"accepted"}' ;;
  "POST /v1/synchronization/synchronize") reply 202 '{"operationId":"op-2"}' ;;
  "GET /v1/operation/"*) reply 200 '{"status":"finished","progress":100,"message":"done"}' ;;
esac
echo "UNHANDLED curl $method $url" >> "$BAD"
reply 404 ""
EOF
# Fake rootful Podman; SHIM_VOLUMES: names of volumes of the project (before the first _); SHIM_WEB_HOST:
# the catalog-web container c0ffee000001 of the project inst has this host name and runs (SHIM_WEB_STOPPED:
# it is stopped), else there is none. SHIM_ENGINE_DOWN: installed, but it does not answer (only --version)
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$SHIM_LOG"
case "$*" in
  "--version") echo "podman version 5.7.0"; exit 0 ;;
esac
if [ -n "${SHIM_ENGINE_DOWN:-}" ]; then
  echo "Error: unable to connect to Podman socket: connection refused" >&2
  exit 125
fi
case "$*" in
  "info") exit 0 ;;
  "info --format {{.Host.Security.Rootless}}") echo false; exit 0 ;;
  "info --format {{.Host.Kernel}}") echo "6.8.0-generic"; exit 0 ;;
  "ps -aq --filter label=com.docker.compose.project=inst --filter label=com.docker.compose.service=catalog-web")
    [ -n "${SHIM_WEB_HOST:-}" ] && echo c0ffee000001; exit 0 ;;
  "ps -aq --filter label=com.docker.compose.project="*" --filter "*) ;;
  "info --format {{.Host.MemTotal}}") echo "${SHIM_MEMTOTAL:-34359738368}"; exit 0 ;;
  "ps -aq --filter label=com.docker.compose.project="*|"ps -aq --filter label=com.docker.compose.service="*) exit 0 ;;
  "volume ls -q --filter label=com.docker.compose.project="*)
    a="$*"; p="${a##*=}"
    printf '%s' "${SHIM_VOLUMES:-}" | grep "^${p}_" || true
    exit 0 ;;
  "network ls -q --filter label=com.docker.compose.project="*) exit 0 ;;
  "volume inspect "*|"image inspect "*) exit 1 ;;
  # the installed Catalog: the image of catalog-web, the version .env names
  "container inspect --format {{.Config.Image}} c0ffee000001")
    [ -n "${SHIM_WEB_HOST:-}" ] || { echo "Error: no such container c0ffee000001" >&2; exit 125; }
    printf 'docker.io/%s\n' "$(sed -n 's/^CATALOG_IMAGE=//p' .env 2>/dev/null | tail -n 1)"; exit 0 ;;
  "container inspect --format {{.Config.Hostname}} c0ffee000001")
    [ -n "${SHIM_WEB_HOST:-}" ] || { echo "Error: no such container c0ffee000001" >&2; exit 125; }
    printf '%s\n' "$SHIM_WEB_HOST"; exit 0 ;;
esac
if [ "${1:-}" = compose ]; then
  shift
  exec "$PODMAN_COMPOSE_PROVIDER" "$@"
fi
echo "UNHANDLED podman $*" >> "$BAD"
exit 125
EOF
cat > "$T/bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "version") echo "Docker Compose version v5.6.0"; exit 0 ;;
  "version --short") echo "5.6.0"; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--env-file|-f) shift 2 ;;
    *) break ;;
  esac
done
case "$*" in
  "ps -q catalog-web") [ -n "${SHIM_WEB_HOST:-}" ] && [ -z "${SHIM_WEB_STOPPED:-}" ] && echo c0ffee000001; exit 0 ;;
  # the installed versions: also a stopped container
  "ps -a -q catalog-web") [ -n "${SHIM_WEB_HOST:-}" ] && echo c0ffee000001; exit 0 ;;
  "ps -q "*|"ps -a -q "*|"ps --services"*|"config --services") exit 0 ;;
esac
echo "UNHANDLED docker-compose $*" >> "$BAD"
exit 1
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet podman.socket") exit 0 ;;
  "is-enabled podman-restart.service") echo enabled; exit 0 ;;
esac
echo "UNHANDLED systemctl $*" >> "$BAD"
exit 1
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${SHIM_TZ:-Europe/Berlin}"\n' > "$T/bin/timedatectl"
# The names of this server: SHIM_NODENAME (uname -n), SHIM_OS (uname -s), SHIM_SCUTIL (the local host name of
# a Mac; empty: scutil fails), SHIM_SHORT (hostname -s)
REAL_UNAME="$(command -v uname)"
cat > "$T/bin/uname" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  -r) echo "6.8.0-generic" ;;
  -n) printf '%s\n' "\${SHIM_NODENAME-Lic-Test01.example.com}" ;;
  -s) echo "\${SHIM_OS:-Linux}" ;;
  *) exec "$REAL_UNAME" "\$@" ;;
esac
EOF
cat > "$T/bin/hostname" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  -s) printf '%s\n' "${SHIM_SHORT:-Mac-Mini}" ;;
  -I) echo "192.0.2.10 " ;;
  *) echo "UNHANDLED hostname $*" >> "$BAD"; exit 1 ;;
esac
EOF
cat > "$T/bin/scutil" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "--get LocalHostName" ] || { echo "UNHANDLED scutil $*" >> "$BAD"; exit 1; }
[ -n "${SHIM_SCUTIL:-}" ] || { echo "LocalHostName: not set" >&2; exit 1; }
printf '%s\n' "$SHIM_SCUTIL"
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" RN1_COMPOSE_PROVIDER="$T/bin/docker-compose" COLUMNS=100
D="$T/inst"; mkdir -p "$D"; I="$D/rn1-technology-catalog-installer.sh"
cp "$NEW" "$I"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$I"
setting() { sed -n "/^# CONFIGURE ONLY THIS SECTION/,/^# DO NOT CHANGE ANYTHING BELOW/s/^$1=\"\(.*\)\"$/\1/p" "$I"; }
# set_setting NAME VALUE: only in the settings section (the template of .env has lines of the same names)
set_setting() { sed -i "/^# CONFIGURE ONLY THIS SECTION/,/^# DO NOT CHANGE ANYTHING BELOW/s/^$1=.*/$1=\"$2\"/" "$I"; }
envv() { sed -n "s/^$1=//p" "$D/.env"; }
run() { (cd "$D" && bash "$I" "$@" 2>&1); }
probe="$T/p"; : > "$probe"; chmod 600 "$probe"; if [ "$(stat -c %a "$probe")" = 600 ]; then CHMOD_WORKS=yes; else CHMOD_WORKS=no; fi
# nothing secret on a command line: the passwords, the order number, the license text
secrets_hidden() { ! grep -qF -e "$ROOTPW" -e "$ADMINPW" -e "$ORDER" -e "RmFrZSBsaWNlbnNl" -e "$LOCALKEY" "$LOG"; }
# calls of the fake Catalog since the mark: mark; ...; since
mark() { MARK="$(wc -l < "$SRV/calls" 2>/dev/null || echo 0)"; }
since() { tail -n +"$((MARK + 1))" "$SRV/calls" 2>/dev/null; }
VOLS=$'inst_db_data\ninst_catalog_license\n'

# 1. The host name of catalog-web: the short name of this server, in .env and in the compose file
out="$(run generate </dev/null)"; rc=$?
check "generate: CATALOG_HOSTNAME is the short name of this server in lower case" '[ "$rc" -eq 0 ] && [ "$(envv CATALOG_HOSTNAME)" = lic-test01 ] && grep -q "Host name      : lic-test01 (catalog-web; the license is bound to it)" <<< "$out"'
check "compose: catalog-web gets hostname: \${CATALOG_HOSTNAME}" '[ "$(sed -n "/^  catalog-web:/,/^  worker-recognition-1:/p" "$D/docker-compose.yml" | grep -cxF "    hostname: \${CATALOG_HOSTNAME}")" -eq 1 ] && [ "$(grep -c "CATALOG_HOSTNAME" "$D/docker-compose.yml")" -eq 1 ]'
check "a new installation (no volumes): no note about the license" '! grep -q "needs a license for" <<< "$out"'
out="$(SHIM_NODENAME=renamed-server run generate </dev/null)"
check "generate again on a renamed server: the host name in .env is kept (the license stays valid)" '[ "$(envv CATALOG_HOSTNAME)" = lic-test01 ]'
out="$(printf '0\n' | SHIM_NODENAME=renamed-server run menu)"
check "renamed server: the files still match the settings (no banner)" '! grep -q "do not match the settings" <<< "$out"'
set_setting CATALOG_HOSTNAME Catalog-01
out="$(run generate </dev/null)"; rc=$?
check "an explicit CATALOG_HOSTNAME wins over .env" '[ "$rc" -eq 0 ] && [ "$(envv CATALOG_HOSTNAME)" = Catalog-01 ]'
set_setting CATALOG_HOSTNAME ''
run generate </dev/null >/dev/null
check "empty again: the name in .env stays" '[ "$(envv CATALOG_HOSTNAME)" = Catalog-01 ]'
for bad in bad.name -lead trail- "with space" mongo opensearch-dashboards localhost "$(printf 'a%.0s' $(seq 1 64))"; do
  set_setting CATALOG_HOSTNAME "$bad"
  out="$(run generate </dev/null)"; rc=$?
  check "CATALOG_HOSTNAME \"${bad:0:20}\" refused" '[ "$rc" -ne 0 ] && grep -q "CATALOG_HOSTNAME: " <<< "$out" && [ "$(envv CATALOG_HOSTNAME)" = Catalog-01 ]'
done
set_setting CATALOG_HOSTNAME mongo
check "a service name refused with the reason" 'run check-settings | grep -q "\"mongo\" is a service of the stack"'
set_setting CATALOG_HOSTNAME bad.name
check "a name with a dot refused with the rule" 'run check-settings | grep -q "Give a host name without the domain: letters, digits and -, at most 63 characters, no dots"'
set_setting CATALOG_HOSTNAME LocalHost
check "localhost refused with the reason" 'run check-settings | grep -q "localhost is every machine.s name for itself - give a name of its own, e.g. catalog01."'
set_setting CATALOG_HOSTNAME ''
sed -i 's/^CATALOG_HOSTNAME=.*/CATALOG_HOSTNAME="Catalog-01"/' "$D/.env"
out="$(SHIM_VOLUMES="$VOLS" run generate </dev/null)"
check "a quoted name in .env (as Compose reads it) is kept, without a note" '[ "$(envv CATALOG_HOSTNAME)" = Catalog-01 ] && ! grep -q -e "no usable host name" -e "another host name" <<< "$out"'

# 2. Files that get their fixed host name for the first time (an older installer: no CATALOG_HOSTNAME in the
# settings, in .env or in its newest backup): a licensed catalog-web keeps the name it has (its container ID),
# so its license survives; without a valid license, or without a container, it gets the name of this server.
# Only writing the files asks the Catalog, never the menu.
asked() { grep -c "/v1/license/isValid" "$LOG"; }
oldfiles() { sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"; }
oldfiles; echo Ok > "$SRV/license"; : > "$LOG"
out="$(printf '0\n' | SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run menu)"
check "files of an older installer (no host name): the menu says they differ, without asking the Catalog" 'grep -q "do not match the settings above" <<< "$out" && [ "$(asked)" -eq 0 ]'
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check "licensed catalog-web named like a container ID: it keeps the name (.env, compose file), said once" '[ "$(envv CATALOG_HOSTNAME)" = c0ffee000001 ] && [ "$(sed -n "/^  catalog-web:/,/^  worker-recognition-1:/p" "$D/docker-compose.yml" | grep -cxF "    hostname: \${CATALOG_HOSTNAME}")" -eq 1 ] && grep -q "OK catalog-web keeps its host name c0ffee000001: the Catalog.s license$" <<< "$out" && grep -q "^  is bound to it (CATALOG_HOSTNAME in .env).$" <<< "$out" && grep -q "Host name      : c0ffee000001 (catalog-web; the license is bound to it)" <<< "$out" && ! grep -q -e "needs a license for" -e "fixed host name" <<< "$out" && [ "$(asked)" -eq 1 ]'
check "generate asks isValid with a short time limit (15 s instead of 120 s)" 'grep "/v1/license/isValid" "$LOG" | grep -q -- "--max-time 120 .*--max-time 15 http://localhost:8080/v1/license/isValid$"'
: > "$LOG"
out="$(SHIM_NODENAME=renamed-server SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check "generate again (also on a renamed server): the kept name stays, no note, the Catalog not asked" '[ "$(envv CATALOG_HOSTNAME)" = c0ffee000001 ] && ! grep -q "keeps its host name" <<< "$out" && [ "$(asked)" -eq 0 ]'
out="$(printf '0\n' | SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run menu)"
check "the kept name: the files match the settings (no banner)" '! grep -q "do not match the settings" <<< "$out"'
oldfiles; : > "$LOG"
out="$(SHIM_DOWN=1 SHIM_WEB_STOPPED=1 SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000002 run generate </dev/null)"
check "Catalog Web does not answer (stack stopped), its container exists: its name is kept too" '[ "$(envv CATALOG_HOSTNAME)" = c0ffee000002 ] && grep -q "catalog-web keeps its host name c0ffee000002" <<< "$out" && [ "$(asked)" -eq 1 ] && ! grep -q "curl:" <<< "$out"'
oldfiles; rm -f "$SRV/license"
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check "Catalog Web answers that it has no valid license: the name of this server, nothing lost - said so" '[ "$(envv CATALOG_HOSTNAME)" = lic-test01 ] && grep -q "catalog-web now has the fixed host name lic-test01 (CATALOG_HOSTNAME).$" <<< "$out" && grep -q "The Catalog binds its license to it and holds no valid license now: none is$" <<< "$out" && grep -q "lost. After the next start, .*license. activates one for this name.$" <<< "$out" && ! grep -q -e "keeps its host name" -e "needs a license for" <<< "$out"'
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check "the note comes only once" '! grep -q "fixed host name" <<< "$out" && [ "$(envv CATALOG_HOSTNAME)" = lic-test01 ]'
oldfiles; echo Ok > "$SRV/license"; : > "$LOG"
out="$(SHIM_VOLUMES="$VOLS" run generate </dev/null)"
check "no catalog-web container: the name of this server, the Catalog not asked" '[ "$(envv CATALOG_HOSTNAME)" = lic-test01 ] && grep -q "now has the fixed host name lic-test01" <<< "$out" && ! grep -q "keeps its host name" <<< "$out" && [ "$(asked)" -eq 0 ]'
oldfiles; : > "$LOG"
set_setting CATALOG_HOSTNAME catalog-01
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check "an explicit CATALOG_HOSTNAME wins over the licensed name: named, with the license it needs" '[ "$(envv CATALOG_HOSTNAME)" = catalog-01 ] && grep -q "catalog-web now has the fixed host name catalog-01 (CATALOG_HOSTNAME)." <<< "$out" && grep -q "container so far: after the next start it needs a license for catalog-01.$" <<< "$out" && grep -q "The license activated before does not fit the new name. .*license." <<< "$out" && grep -q "shows the hardware ID: the order number fetches a license for it from" <<< "$out" && grep -q "Raynet, or Raynet makes a license file or e-mail text for it." <<< "$out" && ! grep -q "keeps its host name" <<< "$out" && [ "$(asked)" -eq 0 ]'
oldfiles; set_setting CATALOG_HOSTNAME c0ffee000001
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check "an explicit CATALOG_HOSTNAME that catalog-web has already: no note that a license is needed" '[ "$(envv CATALOG_HOSTNAME)" = c0ffee000001 ] && ! grep -q -e "needs a license for" -e "fixed host name" -e "another host name" -e "keeps its host name" <<< "$out"'
set_setting CATALOG_HOSTNAME catalog-01
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=catalog-01 run generate </dev/null)"
check "another name in .env, catalog-web runs with the one of the settings: no note" '[ "$(envv CATALOG_HOSTNAME)" = catalog-01 ] && ! grep -q -e "needs a license for" -e "another host name" <<< "$out"'
set_setting CATALOG_HOSTNAME ''
oldfiles; : > "$LOG"
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=catalog.corp.example run generate </dev/null)"
check "a licensed catalog-web with a domain in its host name keeps the part before the dot (all the Catalog reads)" '[ "$(envv CATALOG_HOSTNAME)" = catalog ] && grep -q "catalog-web keeps its host name catalog: the Catalog.s license$" <<< "$out" && [ "$(asked)" -eq 1 ]'
oldfiles; : > "$LOG"
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=catalog_web run generate </dev/null)"
check "a licensed catalog-web whose name cannot be a fixed one: the name of this server, the license it needs said" '[ "$(envv CATALOG_HOSTNAME)" = lic-test01 ] && grep -q "catalog-web gets another host name: lic-test01 (before: catalog_web).$" <<< "$out" && grep -q "^  catalog_web cannot be a fixed host name (letters, digits and -, at most 63$" <<< "$out" && grep -q "^  name: after the next start it needs a license for lic-test01.$" <<< "$out" && grep -q "The license activated before does not fit the new name." <<< "$out" && ! grep -q -e "none is" -e "keeps its host name" <<< "$out" && [ "$(asked)" -eq 1 ]'
oldfiles; rm -f "$SRV/license"
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=catalog_web run generate </dev/null)"
check "the same without a valid license: the name of this server, none is lost" '[ "$(envv CATALOG_HOSTNAME)" = lic-test01 ] && grep -q "holds no valid license now: none is$" <<< "$out" && ! grep -q -e "needs a license for" -e "another host name" <<< "$out"'
oldfiles; echo Ok > "$SRV/license"; cp "$D/.env" "$T/env.old"; cp "$D/docker-compose.yml" "$T/compose.old"; nbak="$(ls -A "$D" | grep -c '\.bak-')"; : > "$LOG"
out="$(SHIM_ENGINE_DOWN=1 SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"; rc=$?
check "older files, the engine does not answer: nothing written (no backup either), said why" '[ "$rc" -ne 0 ] && cmp -s "$D/.env" "$T/env.old" && cmp -s "$D/docker-compose.yml" "$T/compose.old" && [ "$(ls -A "$D" | grep -c "\.bak-")" -eq "$nbak" ] && grep -q "Podman does not answer - run .* as root, with podman.socket active.$" <<< "$out" && grep -q "^  Nothing was written: catalog-web gets a fixed host name now, and a licensed$" <<< "$out" && grep -q "^  Catalog keeps the one its container has, which only Podman can tell.$" <<< "$out" && [ "$(asked)" -eq 0 ]'
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check "the engine answers again: the licensed name is kept" '[ "$(envv CATALOG_HOSTNAME)" = c0ffee000001 ] && grep -q "catalog-web keeps its host name c0ffee000001" <<< "$out"'
out="$(SHIM_ENGINE_DOWN=1 run generate </dev/null)"; rc=$?
check "files with a host name: generate needs no engine" '[ "$rc" -eq 0 ] && [ "$(envv CATALOG_HOSTNAME)" = c0ffee000001 ]'
D2="$T/new"; mkdir -p "$D2"; cp "$I" "$D2/"
out="$(cd "$D2" && SHIM_ENGINE_DOWN=1 bash "$D2/${I##*/}" generate </dev/null 2>&1)"; rc=$?
check "a new installation (no .env, no backup): generate needs no engine" '[ "$rc" -eq 0 ] && [ "$(sed -n "s/^CATALOG_HOSTNAME=//p" "$D2/.env")" = lic-test01 ]'
oldfiles; mv "$D/.env" "$T/env.saved"; for f in "$D"/.env.bak-*; do sed -i '/^CATALOG_HOSTNAME=/d' "$f"; done
out="$(SHIM_VOLUMES=$'inst_db_data\n' SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check ".env gone, its backup without a host name: the licensed name is kept too" 'grep -q "reusing the passwords from the newest backup" <<< "$out" && [ "$(envv CATALOG_HOSTNAME)" = c0ffee000001 ] && grep -q "catalog-web keeps its host name c0ffee000001" <<< "$out"'
rm -f "$D/.env"; : > "$LOG"
{ cat "$T/env.saved"; echo "CATALOG_HOSTNAME=from-backup"; } > "$D/.env.bak-29991231-235959"
out="$(SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run generate </dev/null)"
check ".env gone, its newest backup with a host name: that one, the Catalog not asked" 'grep -q "reusing the passwords from the newest backup" <<< "$out" && [ "$(envv CATALOG_HOSTNAME)" = from-backup ] && ! grep -q "keeps its host name" <<< "$out" && [ "$(asked)" -eq 0 ]'
rm -f "$D/.env.bak-29991231-235959"
{ cat "$T/env.saved"; echo "CATALOG_HOSTNAME=lic-test01"; } > "$D/.env"; run generate </dev/null >/dev/null

# 2b. The settings editor (option 1) shows the host name catalog-web has or gets; changing it on a licensed
# Catalog says that the license must be activated again. Only its edit screen asks the Catalog.
: > "$LOG"
out="$(printf '1\n0\n0\n' | SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=lic-test01 run menu)"
check "settings screen: the Catalog not asked" 'grep -q "HOSTNAME" <<< "$out" && [ "$(asked)" -eq 0 ]'
out="$(printf '1\nCATALOG_HOSTNAME\nother-name\n0\nn\n0\n' | SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=lic-test01 run menu)"
check "settings: CATALOG_HOSTNAME empty shows the effective name; another one on a licensed Catalog: activate again" 'grep -q "Effective  lic-test01  (catalog-web has it; the license is bound to it)" <<< "$out" && grep -q "In .env    lic-test01" <<< "$out" && ! grep -q "option 2 regenerates it" <<< "$out" && grep -q "The Catalog.s license is bound to the host name lic-test01." <<< "$out" && grep -q "With other-name it must be activated again: option 25, after 2 and 6." <<< "$out" && [ -z "$(setting CATALOG_HOSTNAME)" ]'
rm -f "$SRV/license"
out="$(printf '1\nCATALOG_HOSTNAME\nother-name\n0\nn\n0\n' | SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=lic-test01 run menu)"
check "settings: another name on a Catalog without a valid license: no warning" 'grep -q "Effective  lic-test01  (catalog-web has it)" <<< "$out" && ! grep -q "must be activated again" <<< "$out"'
: > "$LOG"
out="$(printf '1\nCATALOG_HOSTNAME\nother-name\n0\nn\n0\n' | SHIM_DOWN=1 SHIM_WEB_STOPPED=1 SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=lic-test01 run menu)"
check "settings: Catalog Web does not answer - another name: only if it holds a license, activate again" 'grep -q "If the Catalog holds a license, it is bound to the host name lic-test01." <<< "$out" && grep -q "With other-name it must be activated again: option 25, after 2 and 6." <<< "$out" && ! grep -q "The Catalog.s license is bound" <<< "$out" && grep "/v1/license/isValid" "$LOG" | grep -q -- "--max-time 15 http"'
echo Ok > "$SRV/license"; cp "$D/.env" "$T/env.lic"; oldfiles
out="$(printf '1\nCATALOG_HOSTNAME\n\n0\n0\n' | SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run menu)"
check "settings: files of an older installer, licensed - the container ID name kept" 'grep -q "Effective  c0ffee000001  (catalog-web has it; the license is bound to it)" <<< "$out"'
out="$(printf '1\nCATALOG_HOSTNAME\ncatalog-01\n0\nn\n0\n' | SHIM_VOLUMES="$VOLS" SHIM_WEB_HOST=c0ffee000001 run menu)"
check "settings: files of an older installer, licensed - another name: activate again" 'grep -q "The Catalog.s license is bound to the host name c0ffee000001." <<< "$out" && grep -q "With catalog-01 it must be activated again" <<< "$out"'
cp "$T/env.lic" "$D/.env"; rm -f "$SRV/license"
set_setting CATALOG_HOSTNAME other-name
out="$(SHIM_VOLUMES="$VOLS" run generate </dev/null)"
check "an explicit name replaces the fixed one of an installation: named, with the license it needs" '[ "$(envv CATALOG_HOSTNAME)" = other-name ] && grep -q "catalog-web gets another host name: other-name (before: lic-test01)." <<< "$out" && grep -q "needs a license for other-name.$" <<< "$out"'
set_setting CATALOG_HOSTNAME lic-test01; run generate </dev/null >/dev/null; set_setting CATALOG_HOSTNAME ''
sed -i 's/^CATALOG_HOSTNAME=.*/CATALOG_HOSTNAME=bad.name/' "$D/.env"
out="$(SHIM_VOLUMES="$VOLS" run generate </dev/null)"
check "a name in .env that is no host name: replaced, not quietly" '[ "$(envv CATALOG_HOSTNAME)" = lic-test01 ] && grep -q "CATALOG_HOSTNAME in .env is no usable host name: bad.name" <<< "$out" && grep -q "catalog-web gets lic-test01 instead (letters, digits and -, no dots)." <<< "$out" && grep -q "catalog-web gets another host name: lic-test01 (before: bad.name)." <<< "$out"'

# 3. The name of this server: Linux (uname -n), macOS (local host name, else hostname -s)
# (without the warning of a bash started with a locale that is not installed)
hn() { (cd "$D" && RN1_MAC_BOOTSTRAPPED=1 bash "$I" __server_hostname 2>&1) | grep -v '^bash: warning: setlocale: '; }
check "Linux: the domain cut off, lower case" '[ "$(SHIM_NODENAME=Srv01.Corp.Example.COM hn)" = srv01 ]'
check "Linux: other characters become -" '[ "$(SHIM_NODENAME=web_01 hn)" = web-01 ]'
check "Linux: the name of a service of the stack gets catalog- in front" '[ "$(SHIM_NODENAME=MONGO hn)" = catalog-mongo ]'
check "Linux: no name at all - catalog-web" '[ "$(SHIM_NODENAME= hn)" = catalog-web ]'
check "Linux: localhost (no name set yet) - catalog-web" '[ "$(SHIM_NODENAME=localhost.localdomain hn)" = catalog-web ] && [ "$(SHIM_NODENAME=LOCALHOST hn)" = catalog-web ]'
check "macOS: the local host name (scutil)" '[ "$(SHIM_OS=Darwin SHIM_SCUTIL=Ardas-MacBook-Pro hn)" = ardas-macbook-pro ]'
check "macOS without a local host name: hostname -s" '[ "$(SHIM_OS=Darwin SHIM_SCUTIL= SHIM_SHORT=Mac-Mini.local hn)" = mac-mini ]'

# 4. Status without a login
: > "$LOG"; rm -f "$SRV/license"; : > "$SRV/calls"
out="$(run license status </dev/null)"; rc=$?
check "license status: not activated, rc 1, no login" '[ "$rc" -eq 1 ] && grep -q "The Catalog is not activated yet (no valid license)." <<< "$out" && [ "$(cat "$SRV/calls")" = "GET /v1/license/isValid none" ]'
out="$(SHIM_DOWN=1 run license status </dev/null)"; rc=$?
check "license status: Catalog Web down" '[ "$rc" -eq 1 ] && grep -q "Catalog Web does not answer at http://localhost:8080 - is the stack running (option 6)?" <<< "$out" && ! grep -q "curl:" <<< "$out"'

# 5. 520 = not activated: import, its upload and operation, self-sync, the local key test
mkdir -p "$D/snapshots"; (cd "$T" && mkdir -p s && echo x > s/x && tar -czf "$D/snapshots/2026-10-02-full.tar.gz" s)
printf '%s\n' "$LOCALKEY" > "$D/.catalog_local_api_key"; chmod 600 "$D/.catalog_local_api_key"
out="$(run import "$D/snapshots/2026-10-02-full.tar.gz" </dev/null)"; rc=$?
check "import without a license: not activated, how to activate (CLI)" '[ "$rc" -ne 0 ] && grep -q "The Catalog is not activated yet (no valid license) - .*license. activates it." <<< "$out" && ! grep -q -e "Unexpected answer" -e "Upload failed" <<< "$out" && [ ! -s "$SRV/uploads" ]'
printf 'full\t2026-10-02\t10\tx\tfull/2026-10-02.tar.gz\t\n' > "$D/snapshots/chain-2026-10-02-full-to-2026-10-02.tsv"
out="$(run import-chain "$D/snapshots/chain-2026-10-02-full-to-2026-10-02.tsv" </dev/null)"; rc=$?
check "import chain without a license: not activated" '[ "$rc" -ne 0 ] && grep -q "The Catalog is not activated yet (no valid license)" <<< "$out" && [ ! -s "$SRV/uploads" ]'
echo Ok > "$SRV/license"
out="$(SHIM_520_UPLOAD=1 run import "$D/snapshots/2026-10-02-full.tar.gz" </dev/null)"; rc=$?
check "upload answered 520: not activated" '[ "$rc" -ne 0 ] && grep -q "The Catalog is not activated yet (no valid license)" <<< "$out" && ! grep -q "Upload failed" <<< "$out"'
out="$(SHIM_520_OPERATION=1 run import "$D/snapshots/2026-10-02-full.tar.gz" </dev/null)"; rc=$?
check "the followed import answered 520: not activated, no waiting" '[ "$rc" -ne 0 ] && grep -q "The Catalog is not activated yet (no valid license)" <<< "$out" && ! grep -q -e "Still running" -e "Import finished" <<< "$out"'
rm -f "$SRV/license"
out="$(printf '20\n\n0\n' | run menu)"
check "self-sync without a license: named at once with option 25, no key asked" 'grep -q "The Catalog is not activated yet (no valid license) - option 25 activates it." <<< "$out" && ! grep -q "needs your API key" <<< "$out"'
printf '%s\n' "$VALID" > "$D/.catalog_api_key"; chmod 600 "$D/.catalog_api_key"
out="$(printf '20\n\n0\n' | SHIM_ISVALID=true run menu)"
check "self-sync, the settings answered 520: not activated, not 'needs an administrator'" 'grep -q "The API key is valid." <<< "$out" && grep -q "The Catalog is not activated yet (no valid license) - option 25 activates it." <<< "$out" && ! grep -q -e "needs a local administrator" -e "Unexpected answer" <<< "$out"'
out="$(printf '18\n7\n0\n\n0\n' | run menu)"
check "local key test without a license: not activated" 'grep -q "The Catalog is not activated yet (no valid license) - option 25 activates it." <<< "$out" && ! grep -q "Unexpected answer" <<< "$out"'
rm -f "$D/.catalog_local_api_key" "$SRV/uploads"
out="$(printf '19\n1\n2\nadmin\n%s\n\n0\n' "$ADMINPW" | run menu)"
check "import with a login without a license: stopped before the upload" 'grep -q "Logged in to the local catalog." <<< "$out" && grep -q "The Catalog is not activated yet (no valid license)" <<< "$out" && [ ! -s "$SRV/uploads" ] && [ ! -d "$D/.jobs" ]'
rm -f "$D/.catalog_api_key"
check "nothing secret on a command line (keys, passwords)" 'secrets_hidden'

# 6. Activation by license file: the exact bytes, any file name, from the folder of the call
rm -f "$SRV/license"; : > "$LOG"; rm -rf "$T/tmp"; mkdir -p "$T/tmp"
LIC="$T/call/my license;v1,final.rswl"; cp "$SRV/valid.rswl" "$LIC"
out="$(cd "$T/call" && printf 'root\n%s\n' "$ROOTPW" | TMPDIR="$T/tmp" bash "$I" license file "my license;v1,final.rswl" 2>&1)"; rc=$?
check "license file: activated (relative path from the folder of the call)" '[ "$rc" -eq 0 ] && grep -q "The Catalog took the license:" <<< "$out" && grep -q "Catalog Web confirms it: the license is valid." <<< "$out" && [ "$(cat "$SRV/license")" = Ok ]'
check "license file: the Catalog got the exact bytes" 'cmp -s "$SRV/got-file" "$SRV/valid.rswl"'
check "license file: status, edition, expiry and versions shown" 'grep -Eq "License +.* valid" <<< "$out" && grep -Eq "Edition +Enterprise" <<< "$out" && grep -Eq "Expires +2027-12-31" <<< "$out" && grep -Eq "For +Catalog up to 26.3" <<< "$out"'
check "license file: root logs in (site administrator named)" 'grep -q "Activation needs a site administrator (role SiteAdmin: root, not admin)." <<< "$out" && grep -q "\"username\":\"root\"" "$SRV/login-body.json"'
check "license file: no temporary file left, nothing secret on a command line" '[ -z "$(ls -A "$T/tmp")" ] && secrets_hidden'
out="$(run license status </dev/null)"; rc=$?
check "license status: valid, rc 0" '[ "$rc" -eq 0 ] && grep -q "The Catalog is activated (valid license)." <<< "$out"'
rm -f "$SRV/license"; mark
out="$(printf 'root\n%s\n' "$ROOTPW" | run license file "$T/call/none.rswl")"; rc=$?
check "license file: a missing file named before the login (no password asked for nothing)" '[ "$rc" -ne 0 ] && grep -q "No license file at $T/call/none.rswl." <<< "$out" && ! grep -q "Activation needs a site administrator" <<< "$out" && [ -z "$(since)" ]'
out="$(cd "$T/call" && bash "$I" license file nothere.rswl </dev/null 2>&1)"; rc=$?
check "license file: a mistyped relative path named before the login" '[ "$rc" -ne 0 ] && grep -q "No license file at nothere.rswl." <<< "$out" && ! grep -q "Activation needs a site administrator" <<< "$out" && [ -z "$(since)" ]'
out="$(run license file </dev/null)"; rc=$?
check "license file without a path: how to call it, rc 2" '[ "$rc" -eq 2 ] && grep -q "license file PATH" <<< "$out"'

# 7. Activation by e-mail: the pasted text with its line breaks, from its first to its last line
rm -f "$SRV/license" "$SRV/got-text"; : > "$LOG"; rm -rf "$T/tmp"; mkdir -p "$T/tmp"
out="$({ printf 'root\n%s\n\n' "$ROOTPW"; cat "$SRV/valid.txt"; printf 'text after the license\n'; } | TMPDIR="$T/tmp" run license text)"; rc=$?
check "license text: activated" '[ "$rc" -eq 0 ] && grep -q "Catalog Web confirms it: the license is valid." <<< "$out" && grep -q "Sending the license text (4 lines)" <<< "$out"'
check "license text: sent with its line breaks, from its first to its last line, as text/plain" 'cmp -s "$SRV/got-text" "$SRV/valid.txt" && [ "$(cat "$SRV/got-ctype")" = text/plain ]'
check "license text: sent from a file of mode 600, none left, not on a command line" '{ [ "$(cat "$SRV/got-mode")" = 600 ] || [ "$CHMOD_WORKS" = no ]; } && [ -z "$(ls -A "$T/tmp")" ] && secrets_hidden'
rm -f "$SRV/license" "$SRV/got-text"
out="$({ printf 'root\n%s\n' "$ROOTPW"; printf 'Dear customer,\n\nhere is your license:\n\n'; sed 's/^/> /' "$SRV/valid.txt"; printf '>\n> Best regards\n'; } | run license text)"; rc=$?
check "license text: the greeting before its first line and the quotes of the e-mail dropped" '[ "$rc" -eq 0 ] && cmp -s "$SRV/got-text" "$SRV/valid.txt" && grep -q "Catalog Web confirms it" <<< "$out"'
rm -f "$SRV/license" "$SRV/got-text"
out="$({ printf 'root\n%s\n' "$ROOTPW"; head -n 2 "$SRV/valid.txt"; echo; tail -n 2 "$SRV/valid.txt"; } | run license text)"; rc=$?
check "license text: one empty line inside the text does not end it" '[ "$rc" -eq 0 ] && cmp -s "$SRV/got-text" "$SRV/valid.txt"'
rm -f "$SRV/license"
out="$({ printf 'root\n%s\n' "$ROOTPW"; head -n 3 "$SRV/valid.txt"; printf '\n\nmore text\n'; } | run license text)"; rc=$?
check "license text: two empty lines end it (the lines after them are not sent)" '[ "$rc" -ne 0 ] && [ "$(cat "$SRV/got-text")" = "$(head -n 3 "$SRV/valid.txt")" ] && grep -q "This is not a license the Catalog can read." <<< "$out" && grep -q "LICENSE STARTS HERE" <<< "$out"'
out="$({ printf 'root\n%s\n' "$ROOTPW"; sed -n 2,3p "$SRV/valid.txt"; printf '\nmore text\n'; } | run license text)"; rc=$?
check "license text: a text without its first and last line ends at an empty line" '[ "$(cat "$SRV/got-text")" = "$(sed -n 2,3p "$SRV/valid.txt")" ]'
out="$({ printf 'root\n%s\n' "$ROOTPW"; head -n 2 "$SRV/valid.txt"; } | run license text)"; rc=$?
check "license text: the end of the input ends it" '[ "$(cat "$SRV/got-text")" = "$(head -n 2 "$SRV/valid.txt")" ]'
mark
out="$(printf 'root\n%s\nHello,\n\nthe license follows.\n' "$ROOTPW" | run license text)"; rc=$?
check "license text: only a greeting - no license text found, nothing sent" '[ "$rc" -ne 0 ] && grep -q "No license text found: its line LICENSE STARTS HERE is missing." <<< "$out" && ! since | grep -q "activate/mail"'
mark
out="$(printf 'root\n%s\n0\n' "$ROOTPW" | run license text)"; rc=$?
check "license text: 0 cancels, nothing sent" 'grep -q "Cancelled." <<< "$out" && ! since | grep -q "activate/mail"'

# 8. Activation by order number: internet named first, the four fields as JSON, a long timeout
rm -f "$SRV/license"; : > "$LOG"; rm -rf "$T/tmp"; mkdir -p "$T/tmp"
set_setting NPM_ADMIN_EMAIL it@mail.example.net
out="$(printf '\n%s\n%s\nTest User\nExample "Test" GmbH\n\n' "$ROOTPW" "$ORDER" | TMPDIR="$T/tmp" run license order)"; rc=$?
check "order: activated" '[ "$rc" -eq 0 ] && grep -q "Catalog Web confirms it: the license is valid." <<< "$out"'
check "order: internet and the data sent to Raynet named" 'grep -q "Catalog Web fetches the license from Raynet.s license server$" <<< "$out" && grep -q "(licenses.raynet.de): it needs internet access. The order number, your name," <<< "$out" && grep -q "company and e-mail address go to Raynet." <<< "$out"'
check "order: the four fields as JSON (quotes escaped, e-mail from NPM_ADMIN_EMAIL)" '[ "$(cat "$SRV/got-order")" = "{\"orderNumber\":\"$ORDER\",\"userName\":\"Test User\",\"companyName\":\"Example \\\"Test\\\" GmbH\",\"email\":\"it@mail.example.net\"}" ]'
check "order: JSON, up to 450 s, a note that it takes time" '[ "$(cat "$SRV/got-order-opts")" = "application/json|450" ] && grep -q "this can take a few minutes" <<< "$out"'
check "order: Enter at the user name is root; mode 600, no file left, nothing on a command line" 'grep -q "\"username\":\"root\"" "$SRV/login-body.json" && { [ "$(cat "$SRV/got-mode")" = 600 ] || [ "$CHMOD_WORKS" = no ]; } && [ -z "$(ls -A "$T/tmp")" ] && secrets_hidden'
rm -f "$SRV/license"
out="$(printf 'root\n%s\n%s\nTest User\nExample GmbH\nnot-an-address\nit@mail.example.net\n' "$ROOTPW" "$ORDER" | SHIM_LIC_ERROR="Unable to connect to activation server." run license order)"; rc=$?
check "order offline: Raynet's license server not reached, HTTPS named, the other ways offered" '[ "$rc" -ne 0 ] && grep -q "Give an e-mail address" <<< "$out" && grep -q "Catalog Web could not reach Raynet.s license server (licenses.raynet.de)." <<< "$out" && grep -q "HTTPS (port 443) to licenses.raynet.de" <<< "$out" && grep -q "Without it: the license file or the e-mail text." <<< "$out"'
out="$(printf 'root\n%s\n%s\nTest User\nExample GmbH\nit@mail.example.net\n' "$ROOTPW" "$ORDER" | SHIM_ORDER_TIMEOUT=1 run license order)"; rc=$?
check "order without an answer in time: named with HTTPS" '[ "$rc" -ne 0 ] && grep -q "Catalog Web got no license from Raynet.s license server in time." <<< "$out" && grep -q "HTTPS (port 443)" <<< "$out"'
out="$(printf 'root\n%s\n%s\nTest User\nExample GmbH\nit@mail.example.net\n' "$ROOTPW" "$ORDER" | SHIM_ORDER_DOWN=1 run license order)"; rc=$?
rm -f "$SRV/down"
check "order, Catalog Web gone meanwhile: named as such, not as Raynet's server" '[ "$rc" -ne 0 ] && grep -q "Catalog Web does not answer at http://localhost:8080 any more." <<< "$out" && ! grep -q -e "in time" -e "HTTPS (port 443)" <<< "$out"'
out="$(printf 'root\n%s\nORD-OTHER\nTest User\nExample GmbH\nit@mail.example.net\n' "$ROOTPW" | run license order)"; rc=$?
check "order: an unknown order number named" '[ "$rc" -ne 0 ] && grep -q "Raynet.s license server has no license for this order number." <<< "$out"'
mark
out="$(printf 'root\n%s\n%s\n\n' "$ROOTPW" "$ORDER" | run license order)"; rc=$?
check "order: Enter at a field cancels, nothing sent" 'grep -q "Cancelled." <<< "$out" && ! since | grep -q "activate/order"'
set_setting NPM_ADMIN_EMAIL ''
check "nothing secret written into the folder of the installer (no log, no file)" '! grep -rqF -e "$ROOTPW" -e "$ORDER" -e "RmFrZSBsaWNlbnNl" "$D"'

# 9. Only a site administrator activates: admin is refused before the questions, a 403 is named too
rm -f "$SRV/license"
out="$(printf 'admin\n%s\n' "$ADMINPW" | run license file "$LIC")"; rc=$?
check "admin: not a site administrator, before the upload" '[ "$rc" -ne 0 ] && grep -q "admin is not a site administrator: only the role SiteAdmin activates.$" <<< "$out" && grep -q "root is one; admin is not enough." <<< "$out" && ! grep -q "activate/file Admin" "$SRV/calls"'
out="$(printf 'root\n%s\n' "$ROOTPW" | SHIM_FORBID=1 run license file "$LIC")"; rc=$?
check "an activation refused with 403: the site administrator named" '[ "$rc" -ne 0 ] && grep -q "root is not a site administrator: only the role SiteAdmin activates" <<< "$out"'
out="$(printf 'root\nwrong\n' | run license file "$LIC")"; rc=$?
check "a wrong password: the login fails, nothing sent" '[ "$rc" -ne 0 ] && grep -q "Wrong user name or password" <<< "$out"'
rm -f "$SRV/license"
out="$(printf 'root\n%s\n' "$ROOTPW" | SHIM_DETAILS_FAIL=1 run license file "$LIC")"; rc=$?
check "the license cannot be read (a damaged one): named, the activation replaces it" '[ "$rc" -eq 0 ] && grep -q "The license could not be read (HTTP 400) - an activation replaces it." <<< "$out" && grep -q "Catalog Web confirms it" <<< "$out"'

# 10. Every refusal of the Catalog in plain words, with what helps
rm -f "$SRV/license"
why() { printf 'root\n%s\n' "$ROOTPW" | SHIM_LIC_ERROR="$1" run license file "$LIC"; }
whyo() { printf 'root\n%s\n%s\nTest User\nExample GmbH\nit@mail.example.net\n' "$ROOTPW" "$ORDER" | SHIM_LIC_ERROR="$1" run license order; }
# the Catalog of this installation: the one .env names
catv() { local v; v="$(envv CATALOG_IMAGE)"; printf '%s' "${v##*:}"; }
check "invalid-hardware-id: another server, the host name named" 'out="$(why license.messages.invalid-hardware-id)"; grep -q "This license is for another server: the hardware ID does not match." <<< "$out" && grep -q "host name of catalog-web: lic-test01$" <<< "$out" && grep -q "A license made for another name works with that name in CATALOG_HOSTNAME$" <<< "$out" && grep -q "(at the top of rn1-technology-catalog-installer.sh, then .*generate. and .*up.)." <<< "$out"'
check "license-expired" 'why license.messages.license-expired | grep -q "This license has expired - Raynet makes a new one."'
check "another-product" 'why license.messages.another-product | grep -q "This license is for another Raynet product, not the Technology Catalog."'
check "wrong-version: an older Catalog, the version of this one" '[ -n "$(catv)" ] && why license.messages.wrong-version | grep -qF "This license is for an older Catalog - this one is $(catv)."'
check "check-connection: Raynet's license server not reached" 'out="$(why license.messages.check-connection)"; grep -q "could not reach Raynet.s license server (licenses.raynet.de)" <<< "$out" && grep -q "HTTPS (port 443)" <<< "$out"'
check "Could not connect to the activation server." 'whyo "Could not connect to the activation server." | grep -q "could not reach Raynet.s license server"'
check "Unable to connect ... (server error: ...)" 'whyo "Unable to connect to activation server (server error: ServiceUnavailable)." | grep -q "Raynet.s license server failed (server error: ServiceUnavailable)."'
check "The license could not be activated (server error: ...)" 'whyo "The license could not be activated (server error: InternalServerError)." | grep -q "Raynet.s license server failed (server error: InternalServerError)."'
check "The license could not be activated. (no answer to the request): the network named" 'out="$(whyo "The license could not be activated.")"; grep -q "Raynet.s license server (licenses.raynet.de) did not answer." <<< "$out" && grep -q "HTTPS (port 443) to licenses.raynet.de" <<< "$out"'
check "invalid-license: refused, the fields to check" 'out="$(whyo license.messages.invalid-license)"; grep -q "Raynet.s license server refused the request." <<< "$out" && grep -q "Check the order number and the other fields" <<< "$out"'
check "unknown-issue: the log of catalog-web" 'out="$(why license.messages.unknown-issue)"; grep -q "could not activate the license (it gives no reason)" <<< "$out" && grep -q "The log of catalog-web: .*logs catalog-web.." <<< "$out" && ! grep -q "could not save it" <<< "$out"'
check "unknown-issue, but the license took (its volume cannot be written): lost at the next restart" 'out="$(printf "root\n%s\n" "$ROOTPW" | SHIM_LIC_UNSAVED=1 run license file "$LIC")"; grep -q "The Catalog took the license, but could not save it in its volume" <<< "$out" && grep -q "catalog_license: the license is lost at the next restart of catalog-web." <<< "$out"'
rm -f "$SRV/license"
check "malformed: damaged, the reason and how to use it" 'out="$(why "The license is malformed. Signature does not match the content.")"; grep -q "The license is damaged or incomplete: Signature does not match the content." <<< "$out" && grep -q "LICENSE ENDS HERE" <<< "$out"'
check "a damaged text (Base-64): how to use it" 'out="$(why "The input is not a valid Base-64 string as it contains a non-base 64 character, more than two padding characters, or an illegal character among the padding characters.")"; grep -q "The license text is damaged: it is not the text as Raynet sent it." <<< "$out" && grep -q "LICENSE ENDS HERE" <<< "$out"'
check "not valid (code)" 'out="$(why "This license is not valid (0x0007)")"; grep -q "The Catalog does not accept this license:$" <<< "$out" && grep -q "^  This license is not valid (0x0007)" <<< "$out"'
check "no file" 'why "File must be uploaded." | grep -q "The Catalog received no file."'
check "a message of Raynet's server with quotes: passed on" 'whyo "Order \"X-1\" is blocked" | grep -q "Raynet.s license server: Order \"X-1\" is blocked"'
check "a problem object: its title, as the Catalog's own refusal" 'printf "root\n%s\n" "$ROOTPW" | SHIM_LIC_PROBLEM=1 run license file "$LIC" | grep -q "The Catalog refused the request: One or more validation errors occurred."'
check "a problem object on the order way: not blamed on Raynet's server" 'out="$(printf "root\n%s\n%s\nTest User\nExample GmbH\nit@mail.example.net\n" "$ROOTPW" "$ORDER" | SHIM_LIC_PROBLEM=1 run license order)"; grep -q "The Catalog refused the request: One or more validation errors occurred." <<< "$out" && ! grep -q "Raynet.s license server:" <<< "$out"'
check "no translation left raw" '! why license.messages.license-expired | grep -q "license.messages"'

# 11. Option 25: the license shown after the login; activate again only on yes; three failures stop
echo Ok > "$SRV/license"; : > "$SRV/calls"
out="$(printf '25\n\n%s\n\n\n0\n' "$ROOTPW" | run menu)"
check "option 25, valid: the details, the hardware ID with the host name, 'Activate again?' no" 'grep -q "The Catalog is activated (valid license)." <<< "$out" && grep -Eq "Edition +Enterprise" <<< "$out" && grep -Eq "Hardware ID +HID8-4B1E-11-22-33 \(host name lic-test01\)" <<< "$out" && ! grep -q "Raynet makes a license file" <<< "$out" && ! grep -q "By license file" <<< "$out" && ! grep -q "activate/" "$SRV/calls"'
rm -f "$SRV/license"
out="$(printf '25\n\n%s\n2\n%s\n\n0\n' "$ROOTPW" "$LIC" | SHIM_WEB_HOST=lic-test01 run menu)"
check "option 25, none yet (catalog-web runs with the fixed name): shown, the hardware ID for Raynet, the file activates" 'grep -q "The Catalog is not activated yet (no valid license)." <<< "$out" && grep -Eq "License +none yet" <<< "$out" && grep -Eq "Hardware ID +HID8-4B1E-11-22-33 \(host name lic-test01\)" <<< "$out" && grep -q "Raynet makes a license file or e-mail text for this hardware ID." <<< "$out" && ! grep -q "still runs with the host name" <<< "$out" && grep -q "By order number" <<< "$out" && grep -q "By e-mail" <<< "$out" && grep -q "Catalog Web confirms it" <<< "$out"'
echo InvalidHardwareId > "$SRV/license"
out="$(printf '25\n\n%s\n0\n\n0\n' "$ROOTPW" | run menu)"
check "option 25, a license of another server: why and the host name" 'grep -Eq "License +.* not valid \(InvalidHardwareId\)" <<< "$out" && grep -q "The license is for another server: the hardware ID does not match." <<< "$out" && grep -q "host name of catalog-web: lic-test01$" <<< "$out" && grep -q "(option 1, then 2 and 6). The order number gets a license for this name." <<< "$out" && grep -q "Cancelled." <<< "$out"'
echo OldVersion > "$SRV/license"
out="$(printf '25\n\n%s\n0\n\n0\n' "$ROOTPW" | run menu)"
check "option 25, a license for an older Catalog (no product in the answer): this version named" 'grep -Eq "License +.* not valid \(OldVersion\)" <<< "$out" && [ -n "$(catv)" ] && grep -qF "The license is for an older Catalog - this one is $(catv)." <<< "$out" && ! grep -Eq "For +Catalog up to" <<< "$out" && ! grep -Eq "Edition +" <<< "$out"'
rm -f "$SRV/license"
out="$(printf '25\n\n%s\n2\n/none/1\n2\n/none/2\n2\n/none/3\n2\n%s\n\n0\n' "$ROOTPW" "$LIC" | run menu)"
check "option 25: three failures stop it (no endless loop)" 'grep -q "Stopped after 3 failed attempts - option 25 tries again." <<< "$out" && [ "$(grep -c "No license file at" <<< "$out")" -eq 3 ] && [ ! -f "$SRV/license" ]'
out="$(printf '25\n\n%s\n2\n/none/1\n\n\n0\n' "$ROOTPW" | run menu)"
check "option 25: after a failure Enter leaves (default 0)" 'grep -q "Another way below, or 0." <<< "$out" && grep -q "Cancelled." <<< "$out" && ! grep -q "Stopped after" <<< "$out"'
out="$(printf '25\n\nwrong\n\n0\n' | run menu)"
check "option 25: a failed login ends it" 'grep -q "Wrong user name or password" <<< "$out" && ! grep -q "By license file" <<< "$out"'
mark
out="$(printf '25\n0\n\n0\n' | run menu)"
check "option 25: 0 at the user name cancels - no warning about a failed step" 'grep -q "Cancelled." <<< "$out" && ! grep -q "did not finish successfully" <<< "$out" && ! since | grep -q "authentication"'
out="$(printf '25\n\n0\n' | SHIM_DOWN=1 run menu)"
check "option 25: Catalog Web down - named, no login asked" 'grep -q "Catalog Web does not answer at http://localhost:8080" <<< "$out" && ! grep -q "Activation needs a site administrator" <<< "$out"'
out="$(printf '25\n\n\n0\n' | SHIM_WEB_HOST=c0ffee000001 run menu)"
check "option 25, catalog-web still runs with its container ID (files not applied): why to apply them first, no is the default" 'grep -q "catalog-web still runs with the host name c0ffee000001." <<< "$out" && grep -q "A license activated now stops working when the files with the fixed host name" <<< "$out" && grep -q "lic-test01 (CATALOG_HOSTNAME) are applied." <<< "$out" && grep -q "menu option 6 applies them - activate then." <<< "$out" && grep -q "Cancelled." <<< "$out" && ! grep -q "Activation needs a site administrator" <<< "$out" || { printf "%s
" "$out" | tail -n 25; false; }'
sed -i '/^CATALOG_HOSTNAME=/d' "$D/.env"
out="$(printf '25\n\n%s\n0\n\n0\n' "$ROOTPW" | SHIM_WEB_HOST=c0ffee000001 run menu)"
check "option 25, files without a fixed host name: no warning (writing them keeps the name of a licensed Catalog), the hardware ID of the name it runs with" '! grep -q -e "has no fixed host name yet" -e "still runs with the host name" <<< "$out" && grep -q "Activation needs a site administrator" <<< "$out" && grep -Eq "Hardware ID +HID8-4B1E-11-22-33 \(host name c0ffee000001\)" <<< "$out" && grep -q "Cancelled." <<< "$out"'
set_setting CATALOG_HOSTNAME catalog-01
out="$(SHIM_WEB_HOST=c0ffee000001 run license file "$LIC" </dev/null)"; rc=$?
check "license file on these files with another CATALOG_HOSTNAME set: the commands named, no is the default" '[ "$rc" -ne 0 ] && grep -q "catalog-web still runs with the host name c0ffee000001." <<< "$out" && grep -q "catalog-01 (CATALOG_HOSTNAME) are applied." <<< "$out" && grep -q "generate. writes them, .*up. applies them - activate then." <<< "$out" && ! grep -q "Activation needs a site administrator" <<< "$out"'
set_setting CATALOG_HOSTNAME ''
run generate </dev/null >/dev/null

# 12. Ctrl+C (here TERM) during the order call or the paste: no file with the order data or the license
# text is left
rm -f "$SRV/license" "$SRV/curl.pid" "$SRV/got-text"; rm -rf "$T/tmp"; mkdir -p "$T/tmp"
printf 'root\n%s\n%s\nTest User\nExample GmbH\nit@mail.example.net\n' "$ROOTPW" "$ORDER" > "$T/in"
cd "$D" && { SHIM_ORDER_SLOW=1 TMPDIR="$T/tmp" bash "$I" license order < "$T/in" > "$T/int.out" 2>&1 & pid=$!; }; cd - >/dev/null
for i in $(seq 1 100); do [ -s "$SRV/curl.pid" ] && break; sleep 0.1; done
had="$(ls -A "$T/tmp")"
kill -TERM "$pid" 2>/dev/null; sleep 0.3; kill -TERM "$(cat "$SRV/curl.pid" 2>/dev/null)" 2>/dev/null
wait "$pid"; rc=$?
check "TERM during the order call: stopped (130), the file with the order data removed" '[ -n "$had" ] && [ "$rc" -eq 130 ] && [ -z "$(ls -A "$T/tmp")" ] || { echo "rc=$rc had=$had left=$(ls -A "$T/tmp")"; tail -n 5 "$T/int.out"; false; }'
rm -f "$T/fifo"; mkfifo "$T/fifo"
cd "$D" && { TMPDIR="$T/tmp" bash "$I" license text < "$T/fifo" > "$T/int.out" 2>&1 & pid=$!; }; cd - >/dev/null
exec 8> "$T/fifo"
printf 'root\n%s\n' "$ROOTPW" >&8; head -n 2 "$SRV/valid.txt" >&8
for i in $(seq 1 100); do grep -q "Paste the license text" "$T/int.out" && [ -n "$(ls -A "$T/tmp")" ] && break; sleep 0.1; done
sleep 0.5; had="$(ls -A "$T/tmp")"
kill -TERM "$pid" 2>/dev/null; sleep 0.3; exec 8>&-
wait "$pid"; rc=$?
check "TERM during the paste: stopped (130), the file with the text removed" '[ -n "$had" ] && [ "$rc" -eq 130 ] && [ -z "$(ls -A "$T/tmp")" ] && [ ! -s "$SRV/got-text" ] || { echo "rc=$rc had=$had left=$(ls -A "$T/tmp")"; tail -n 5 "$T/int.out"; false; }'

# 13. In a terminal: what the paste brought after the last line (empty lines, a signature) is not taken as
# the answer to the next question
if command -v script >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  tty_run() {
    local cmd="$1" log="$T/tty.log" i from=1
    shift
    : > "$log"
    { while [ $# -ge 2 ]; do
        for i in $(seq 1 60); do tail -c +"$from" "$log" 2>/dev/null | grep -aq -- "$1" && break; sleep 0.5; done
        sleep 0.5
        from=$(($(wc -c < "$log") + 1))
        printf "$2"
        shift 2
      done
      sleep 2
    } | TERM=xterm LANG=C.UTF-8 timeout 60 script -qfec "stty sane; stty cols 100 rows 40; $cmd" /dev/null > "$log" 2>&1
    sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g' "$log" | tr -d '\r'
  }
  rm -f "$SRV/license" "$SRV/got-text"
  paste="$(head -n 3 "$SRV/valid.txt"; echo "a line that breaks it"; tail -n 1 "$SRV/valid.txt"; printf '\nBest regards\n')"
  out="$(tty_run "cd $D && bash $I license" "user name \[root\]:" '\n' "Password" "$ROOTPW\\n" "Select \[0\]:" '3\n' "Paste the license text" "${paste//$'\n'/\\n}\\n" "Select \[0\]:" 'x\n' "Select \[0\]:" '0\n')"
  check "terminal: the lines after the pasted text are dropped, the next question waits for its answer" '{ grep -q "This is not a license the Catalog can read." <<< "$out" && grep -q "Unknown choice: x" <<< "$out" && ! grep -q "Unknown choice: Best regards" <<< "$out" && grep -q "Cancelled." <<< "$out" && [ "$(tail -n 1 "$SRV/got-text")" = "$(tail -n 1 "$SRV/valid.txt")" ]; } || { printf "%s\n" "$out" | tail -n 30 | sed "s/^/  | /"; false; }'
else
  echo "SKIP: script (util-linux) missing - no test of a paste in a terminal"
fi

# 14. Menu, help and command line
check "menu: option 25 in ACCESS" 'bash "$I" __menu_items | grep -qx "1|25|run|License / activation|order number, file, e-mail|Shows the license, activates the Catalog"'
check "help: option 25 and the command" 'run help | grep -q "license \[status|file PATH|order|text\]" && printf "h\n\n0\n" | run menu | grep -q "License / activation"'
check "help: option 25 in plain words" 'printf "h\n\n0\n" | run menu | grep -q "Shows the license and activates the Catalog (without one it takes no data):"'
out="$(run license nonsense </dev/null)"; rc=$?
check "license with an unknown argument: rc 2" '[ "$rc" -eq 2 ] && grep -q "Unknown option for license: nonsense" <<< "$out"'

check "fakes: no unknown curl, podman, compose, hostname or scutil call" '[ ! -s "$BAD" ] || { sort "$BAD" | uniq -c | head -20; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
