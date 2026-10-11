#!/usr/bin/env bash
set -u
NEW="$1"
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: neither jq nor python3 - the setup of Nginx Proxy Manager needs one of them."
  exit 0
fi
T="$(mktemp -d)/dom"
rm -rf "$T"; mkdir -p "$T/bin" "$T/dns"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
LE="Let's Encrypt"

# UNH: calls the fakes do not know (checked at the end). NS: the state of the fake Nginx Proxy Manager:
#   version, user (EMAIL|PASSWORD; missing: not set up yet), token, hosts/ID (DOMAIN|CERT|HOST|PORT|SSL_FORCED),
#   certs/ID (DOMAIN|EXPIRES), seq (last id), calls (METHOD PATH CODE), body-* (request bodies),
#   ups (podman compose up -d calls), volumes (the volumes of Nginx Proxy Manager); npm_down: its container
#   does not run, le_fail: Let's Encrypt refuses the certificate, tfa: the user has two-factor authentication.
# DNS: $T/dns/NAME holds the addresses of NAME. LOCAL_IPS: the addresses of this server. LISTEN_PORTS: the
# ports other programs listen on.
export UNH="$T/unhandled.log" NS="$T/npm" DNS="$T/dns" LOCAL_IPS="192.0.2.10 2001:db8::10" LISTEN_PORTS=""
export RN1_COMPOSE_PROVIDER="$T/cli-plugins/docker-compose"
: > "$UNH"

cat > "$T/bin/timedatectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "Europe/Berlin"
EOF
# An empty, ready Podman engine: rootful Podman 5.7.0, podman.socket active, the Docker Compose provider
# in place. "up -d" does what Nginx Proxy Manager 2.13+ does on its first start: it creates its admin from
# INITIAL_ADMIN_EMAIL / INITIAL_ADMIN_PASSWORD, when the compose file passes them.
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
a="$*"
case "$a" in
  --version) echo "podman version 5.7.0" ;;
  info) ;;
  "info --format {{.Host.Security.Rootless}}") echo false ;;
  "volume ls -q --filter label=com.docker.compose.project=inst") cat "$NS/volumes" 2>/dev/null ;;
  "volume ls -q --filter label=com.docker.compose.project="*) ;;
  "ps -aq --filter label="*|"ps -a --filter label="*) ;;
  "compose --env-file .env -f docker-compose.yml "*)
    [ "${PODMAN_COMPOSE_PROVIDER:-}" = "$RN1_COMPOSE_PROVIDER" ] || { printf 'UNHANDLED podman %s (PODMAN_COMPOSE_PROVIDER=%s)\n' "$a" "${PODMAN_COMPOSE_PROVIDER:-unset}" >> "$UNH"; exit 125; }
    case "${a#compose --env-file .env -f docker-compose.yml }" in
      "config --quiet"|ps|"ps --services --filter status=running"|"ps -q catalog-web"|"ps -q mongo"|"ps -a -q catalog-web"|"ps -a -q mongo") ;;
      "ps -q nginx-proxy-manager") [ -f "$NS/npm_down" ] || echo 5f1c0e7a9b ;;
      "up -d --remove-orphans")
        echo up >> "$NS/ups"
        if grep -qx 'INSTALL_NGINX_PROXY_MANAGER=true' .env; then
          printf 'inst_npm_data\ninst_npm_letsencrypt\n' > "$NS/volumes"
          if [ ! -f "$NS/user" ] && grep -q 'INITIAL_ADMIN_PASSWORD: "${NPM_ADMIN_PASSWORD}"' docker-compose.yml; then
            e="$(sed -n 's/^NPM_ADMIN_EMAIL=//p' .env)"
            printf '%s|%s\n' "${e:-admin@example.com}" "$(sed -n 's/^NPM_ADMIN_PASSWORD=//p' .env)" > "$NS/user"
          fi
        fi ;;
      "down -v --remove-orphans")
        echo down >> "$NS/downs"
        rm -f "$NS/volumes" "$NS/user" "$NS/token" "$NS"/hosts/* "$NS"/certs/* ;;
      *) printf 'UNHANDLED podman %s\n' "$a" >> "$UNH"; exit 125 ;;
    esac ;;
  *) printf 'UNHANDLED podman %s\n' "$a" >> "$UNH"; exit 125 ;;
esac
exit 0
EOF
mkdir -p "$T/cli-plugins"
cat > "$RN1_COMPOSE_PROVIDER" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  version) echo "Docker Compose version v5.6.0" ;;
  "version --short") echo "5.6.0" ;;
  *) printf 'UNHANDLED provider %s\n' "$*" >> "$UNH"; exit 125 ;;
esac
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "is-active --quiet podman.socket"|"is-active podman.socket") exit 0 ;;
  "is-enabled podman-restart.service") echo enabled ;;
  *) printf 'UNHANDLED systemctl %s\n' "$*" >> "$UNH"; exit 1 ;;
esac
EOF
cat > "$T/bin/getent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ahostsv4|ahostsv6) ;;
  *) printf 'UNHANDLED getent %s\n' "$*" >> "$UNH"; exit 1 ;;
esac
[ -f "$DNS/$2" ] || exit 2
found=0
while read -r ip; do
  if [ "$1" = ahostsv4 ] && [[ "$ip" != *:* ]]; then
    printf '%-15s STREAM %s\n%-15s DGRAM\n%-15s RAW\n' "$ip" "$2" "$ip" "$ip"; found=1
  elif [ "$1" = ahostsv6 ]; then
    # like glibc: without an AAAA record the IPv4 addresses come back as ::ffff:a.b.c.d
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
  *) printf 'UNHANDLED ip %s\n' "$*" >> "$UNH"; exit 1 ;;
esac
EOF
cat > "$T/bin/ss" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  -ltn)
    echo "State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
    for p in $LISTEN_PORTS; do printf 'LISTEN 0      511    0.0.0.0:%s        0.0.0.0:*\n' "$p"; done ;;
  *) printf 'UNHANDLED ss %s\n' "$*" >> "$UNH"; exit 1 ;;
esac
EOF
# Fake curl: the API of Nginx Proxy Manager on 127.0.0.1:81 and the checks through it (--resolve)
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET; out=/dev/null; wfmt=""; data=""; resolve=""; url=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    -H|--connect-timeout|--max-time) shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    --resolve) resolve="$2"; shift 2 ;;
    -K) if [ "$2" = "-" ]; then cfg="$(cat)"; fi; shift 2 ;;
    -s|-sS) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) printf 'UNHANDLED curl argument %s\n' "$1" >> "$UNH"; exit 2 ;;
  esac
done
reply() {
  printf '%s' "$2" > "$out"
  echo "$method $path $1" >> "$NS/calls"
  if [ -n "$wfmt" ]; then printf '%s' "$1"; fi
  exit 0
}
field() { sed -n "s/.*\"$1\":\"\{0,1\}\([^\",}]*\).*/\1/p" "$data" | head -n 1; }
next_id() { n=$(( $(cat "$NS/seq") + 1 )); echo "$n" > "$NS/seq"; printf '%s' "$n"; }
if [ -n "$resolve" ]; then
  d="${resolve%%:*}"
  echo "PROBE $url via $resolve" >> "$NS/calls"
  case "$resolve|$url" in
    "$d:443:127.0.0.1|https://$d/") want=https ;;
    "$d:80:127.0.0.1|http://$d/") want=http ;;
    *) printf 'UNHANDLED curl probe %s %s\n' "$resolve" "$url" >> "$UNH"; exit 2 ;;
  esac
  for f in "$NS"/hosts/*; do
    [ -f "$f" ] || continue
    IFS='|' read -r hd hc hf hp hs < "$f"
    if [ "$hd" = "$d" ] && { [ "$want" = http ] || [ "$hc" != 0 ]; }; then printf '200'; exit 0; fi
  done
  printf '000'; exit 35
fi
case "$url" in
  http://127.0.0.1:81/api/*) path="/${url#http://127.0.0.1:81/api/}" ;;
  *) printf 'UNHANDLED curl %s %s\n' "$method" "$url" >> "$UNH"; exit 2 ;;
esac
if [ -f "$NS/npm_down" ]; then printf '000'; exit 7; fi
if [ "$method $path" != "GET /" ] && [ "$method $path" != "POST /tokens" ] && [ "$cfg" != "header = \"Authorization: Bearer $(cat "$NS/token" 2>/dev/null)\"" ]; then
  reply 401 '{"error":{"code":401,"message":"Unauthorized"}}'
fi
case "$method $path" in
  "GET /")
    IFS=. read -r ma mi re < "$NS/version"
    setup=false; [ -f "$NS/user" ] && setup=true
    reply 200 "{\"status\":\"OK\",\"setup\":$setup,\"version\":{\"major\":$ma,\"minor\":$mi,\"revision\":$re}}" ;;
  "POST /tokens")
    cp "$data" "$NS/body-token"
    IFS='|' read -r ue up < "$NS/user" 2>/dev/null
    if [ -f "$NS/user" ] && [ "$(field identity | tr '[:upper:]' '[:lower:]')" = "$ue" ] && [ "$(field secret)" = "$up" ]; then
      if [ -f "$NS/tfa" ]; then reply 200 '{"requires_2fa":true,"challenge_token":"c-1"}'; fi
      echo "tok-$RANDOM" > "$NS/token"
      reply 200 "{\"token\":\"$(cat "$NS/token")\",\"expires\":\"2099-01-01T00:00:00.000Z\"}"
    fi
    reply 400 '{"error":{"code":400,"message":"Invalid email or password"}}' ;;
  "PUT /users/me")
    cp "$data" "$NS/body-user"
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
    d="$(sed -n 's/.*"domain_names":\["\([^"]*\)"\].*/\1/p' "$data")"
    for f in "$NS"/hosts/*; do
      [ -f "$f" ] || continue
      if [ "$(cut -d'|' -f1 "$f")" = "$d" ]; then reply 400 "{\"error\":{\"code\":400,\"message\":\"$d is already in use\"}}"; fi
    done
    id="$(next_id)"
    cp "$data" "$NS/body-host-$id"
    printf '%s|%s|%s|%s|%s\n' "$d" "$(field certificate_id)" "$(field forward_host)" "$(field forward_port)" "$(field ssl_forced)" > "$NS/hosts/$id"
    reply 201 "{\"id\":$id,\"domain_names\":[\"$d\"]}" ;;
  "PUT /nginx/proxy-hosts/"*)
    id="${path##*/}"
    [ -f "$NS/hosts/$id" ] || reply 404 '{"error":{"code":404,"message":"Not Found"}}'
    cp "$data" "$NS/body-put-$id"
    IFS='|' read -r hd hc hf hp hs < "$NS/hosts/$id"
    printf '%s|%s|%s|%s|%s\n' "$hd" "$(field certificate_id)" "$hf" "$hp" "$(field ssl_forced)" > "$NS/hosts/$id"
    reply 200 "{\"id\":$id}" ;;
  "GET /nginx/certificates")
    items=""
    for f in "$NS"/certs/*; do
      [ -f "$f" ] || continue
      IFS='|' read -r cd ce < "$f"
      items="$items${items:+,}{\"id\":${f##*/},\"provider\":\"letsencrypt\",\"nice_name\":\"$cd\",\"domain_names\":[\"$cd\"],\"expires_on\":\"$ce\"}"
    done
    reply 200 "[$items]" ;;
  "POST /nginx/certificates")
    cp "$data" "$NS/body-cert"
    d="$(sed -n 's/.*"domain_names":\["\([^"]*\)"\].*/\1/p' "$data")"
    if [ -f "$NS/le_fail" ] || [ "$(cut -d'|' -f1 "$NS/user")" = admin@example.com ]; then
      reply 500 "{\"error\":{\"code\":500,\"message\":\"Internal Error\"},\"debug\":{\"stack\":[\"CommandError: Saving debug log to /var/log/letsencrypt/letsencrypt.log\",\"Some challenges have failed.\",\"Certbot failed to authenticate some domains (authenticator: webroot). The Certificate Authority reported these problems:\",\"  Domain: $d\",\"  Type:   dns\",\"  Detail: DNS problem: NXDOMAIN looking up A for $d - check that a DNS record exists for this domain\",\"    at ChildProcess.exithandler (node:child_process:430:12)\"]}}"
    fi
    id="$(next_id)"
    printf '%s|%s\n' "$d" "2099-01-01 00:00:00" > "$NS/certs/$id"
    reply 201 "{\"id\":$id,\"provider\":\"letsencrypt\",\"domain_names\":[\"$d\"],\"expires_on\":\"2099-01-01 00:00:00\"}" ;;
esac
printf 'UNHANDLED curl %s %s\n' "$method" "$url" >> "$UNH"
exit 2
EOF
chmod +x "$T/bin/"* "$RN1_COMPOSE_PROVIDER"
# the kernel of the test machine must not change the generated files (MongoDB workaround on 6.19 to 7.0.x)
REAL_UNAME="$(command -v uname)"
printf '#!/usr/bin/env bash
if [ "${1:-}" = "-r" ]; then echo "6.8.0-generic"; else exec "%s" "$@"; fi
' "$REAL_UNAME" > "$T/bin/uname"
chmod +x "$T/bin/uname"
export PATH="$T/bin:$PATH"

N="rn1-technology-catalog-installer.sh"
D="$T/inst"; I="$D/$N"
fresh() {
  rm -rf "$D" "$NS"; mkdir -p "$D" "$NS/hosts" "$NS/certs"
  cp "$NEW" "$I"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$I"
  echo 2.16.0 > "$NS/version"; echo 0 > "$NS/seq"; : > "$NS/calls"; : > "$NS/ups"
  rm -f "$DNS"/*
}
# generated and started once: Nginx Proxy Manager has created its admin user
installed() { fresh; bash "$I" generate </dev/null >/dev/null 2>&1; bash "$I" up </dev/null >/dev/null 2>&1; : > "$NS/calls"; }
# set NAME OLD NEW: one setting in the settings section (the generator below has lines like NAME=${NAME})
set_to() { sed -i "s|^$1=\"$2\"\$|$1=\"$3\"|" "${4:-$I}"; }
val() { sed -n "/^# CONFIGURE ONLY THIS SECTION/,/^# DO NOT CHANGE ANYTHING BELOW/s/^$1=\"\(.*\)\"$/\1/p" "$I"; }
envv() { sed -n "s/^$1=//p" "$D/.env"; }
dns() { local n="$1"; shift; printf '%s\n' "$@" > "$DNS/$n"; }
nhosts() { ls "$NS/hosts" | wc -l; }
host_of() { cat "$NS/hosts/$1" 2>/dev/null; }
calls() { grep -c "^$1" "$NS/calls"; }

# 1. Generated files: the NPM admin from .env, its password kept like the others, the trusted proxy networks
fresh
bash "$I" generate </dev/null >/dev/null 2>&1
check ".env: NPM password generated, e-mail and domain empty" 'grep -Eq "^NPM_ADMIN_PASSWORD=[A-Za-z0-9]{32}$" "$D/.env" && grep -qx "NPM_ADMIN_EMAIL=" "$D/.env" && grep -qx "CATALOG_DOMAIN=" "$D/.env"'
check "compose: NPM creates its admin from .env (placeholder address when empty)" 'grep -qF "      INITIAL_ADMIN_EMAIL: \"\${NPM_ADMIN_EMAIL:-admin@example.com}\"" "$D/docker-compose.yml" && grep -qF "      INITIAL_ADMIN_PASSWORD: \"\${NPM_ADMIN_PASSWORD}\"" "$D/docker-compose.yml"'
kn="$(awk '/^  catalog-web:/ { on = 1; next } /^  [a-z]/ { on = 0 } on && /ForwardedHeaders__KnownNetworks__/ { gsub(/ /, ""); print }' "$D/docker-compose.yml" | tr '\n' ' ')"
check "compose: catalog-web trusts X-Forwarded-Proto from the private networks" '[ "$kn" = "ForwardedHeaders__KnownNetworks__0:\"10.0.0.0/8\" ForwardedHeaders__KnownNetworks__1:\"172.16.0.0/12\" ForwardedHeaders__KnownNetworks__2:\"192.168.0.0/16\" " ] && [ "$(grep -c ForwardedHeaders "$D/docker-compose.yml")" -eq 3 ]'
p1="$(envv NPM_ADMIN_PASSWORD)"
bash "$I" generate </dev/null >/dev/null 2>&1
check "generate keeps the NPM password" '[ -n "$p1" ] && [ "$(envv NPM_ADMIN_PASSWORD)" = "$p1" ]'
out="$(printf '0\n' | bash "$I" menu 2>&1)"
check "the files match the settings after generate" '! grep -q "do not match the settings" <<< "$out"'
out="$(bash "$I" credentials 2>&1)"
check "credentials: NPM login and password" 'grep -qx "  NPM login      : admin@example.com" <<< "$out" && grep -qx "  NPM password   : $p1" <<< "$out"'
sed -i '/^NPM_ADMIN_PASSWORD=/d' "$D/.env"
m1="$(envv MONGO_INITDB_ROOT_PASSWORD)"
out="$(printf '0\n' | bash "$I" menu 2>&1)"
check ".env of an older installer (no NPM password): the files differ" 'grep -q "do not match the settings" <<< "$out"'
out="$(bash "$I" generate </dev/null 2>&1)"
check "generate adds the NPM password, the others stay" 'grep -q "NPM_ADMIN_PASSWORD not found" <<< "$out" && grep -Eq "^NPM_ADMIN_PASSWORD=[A-Za-z0-9]{32}$" "$D/.env" && [ "$(envv MONGO_INITDB_ROOT_PASSWORD)" = "$m1" ]'
p1="$(envv NPM_ADMIN_PASSWORD)"
out="$(bash "$I" generate --new-passwords </dev/null 2>&1)"
check "--new-passwords also renews the NPM password and names Nginx Proxy Manager" '[ "$(envv NPM_ADMIN_PASSWORD)" != "$p1" ] && grep -q "MongoDB, RabbitMQ and Nginx Proxy Manager keep the original ones" <<< "$out"'
out="$(bash "$I" credentials 2>&1)"
check "--new-passwords before the first start: the login of .env is shown" '[ ! -f "$D/.npm-login" ] && grep -qx "  NPM login      : admin@example.com" <<< "$out" && grep -qx "  NPM password   : $(envv NPM_ADMIN_PASSWORD)" <<< "$out"'
set_to INSTALL_NGINX_PROXY_MANAGER true false
p1="$(envv NPM_ADMIN_PASSWORD)"
bash "$I" generate </dev/null >/dev/null 2>&1
out="$(bash "$I" credentials 2>&1)"
check "NPM off: no INITIAL_ADMIN_*, no trusted networks, password kept, not shown" '! grep -q "INITIAL_ADMIN" "$D/docker-compose.yml" && ! grep -q ForwardedHeaders "$D/docker-compose.yml" && [ "$(envv NPM_ADMIN_PASSWORD)" = "$p1" ] && ! grep -q "NPM" <<< "$out"'

# 2. Domain names: normalized, checked; IP addresses are refused
nz() { bash "$I" __domain_normalize "$1"; }
check "normalize: scheme, port, path, query and case go" '[ "$(nz "HTTPS://Catalog.Example.COM:8443/path?x=1")" = catalog.example.com ]'
check "normalize: spaces, user and the final dot go" '[ "$(nz " it@catalog.example.com. ")" = catalog.example.com ] && [ "$(nz catalog.example.com)" = catalog.example.com ]'
check "normalize: an IPv6 address keeps its brackets" '[ "$(nz "[2001:db8::1]:443")" = "[2001:db8::1]" ]'
fresh
cs="$(cksum < "$I")"
out="$(bash "$I" domain http://192.0.2.10:8080/ </dev/null 2>&1)"; rc=$?
check "domain: an IP address is refused" '[ "$rc" -eq 1 ] && grep -q "\"192.0.2.10\" is an IP address - leave it empty to use the IP address." <<< "$out" && [ "$(cksum < "$I")" = "$cs" ]'
out="$(bash "$I" domain "[2001:db8::1]" </dev/null 2>&1)"; rc=$?
check "domain: an IPv6 address is refused" '[ "$rc" -eq 1 ] && grep -q "is an IP address" <<< "$out"'
for bad in intranet -catalog.example.com catalog_web.example.com "$(printf 'a%.0s' {1..64}).example.com"; do
  out="$(bash "$I" domain "$bad" </dev/null 2>&1)"; rc=$?
  check "domain: \"${bad:0:20}\" is no host name" '[ "$rc" -eq 1 ] && grep -q "Give a host name in lower case" <<< "$out" && [ "$(cksum < "$I")" = "$cs" ]'
done
cp "$I" "$T/cs.sh"; set_to CATALOG_DOMAIN "" Catalog.example.com "$T/cs.sh"
out="$(bash "$T/cs.sh" check-settings 2>&1)"; rc=$?
check "check-settings: upper case refused" '[ "$rc" -ne 0 ] && grep -q "CATALOG_DOMAIN: Give a host name" <<< "$out"'
cp "$I" "$T/cs.sh"; set_to NPM_ADMIN_EMAIL "" nobody "$T/cs.sh"
out="$(bash "$T/cs.sh" check-settings 2>&1)"; rc=$?
check "check-settings: an e-mail address without @ refused" '[ "$rc" -ne 0 ] && grep -q "NPM_ADMIN_EMAIL: Give an e-mail address" <<< "$out"'
out="$(bash "$T/cs.sh" generate </dev/null 2>&1)"; rc=$?
check "generate refuses an invalid e-mail address" '[ "$rc" -ne 0 ] && [ ! -f "$T/.env" ]'
cp "$I" "$T/cs.sh"; set_to NPM_ADMIN_EMAIL "" IT@Mail.example.net "$T/cs.sh"
out="$(bash "$T/cs.sh" check-settings 2>&1)"; rc=$?
check "check-settings: an e-mail address with capitals refused (NPM logins are lower case)" '[ "$rc" -ne 0 ] && grep -q "NPM_ADMIN_EMAIL: Give the e-mail address in lower case (it@mail.example.net)" <<< "$out"'
check "check-settings: both may be empty" 'bash "$I" check-settings >/dev/null 2>&1'
out="$(printf '1\nCATALOG_DOMAIN\n192.0.2.1\ncatalog.example.com\nNPM_ADMIN_EMAIL\nnobody\nit@mail.example.net\ns\n0\n' | bash "$I" menu 2>&1)"
check "settings screen: checks both, saves them" 'grep -q "is an IP address" <<< "$out" && grep -q "Give an e-mail address" <<< "$out" && [ "$(val CATALOG_DOMAIN)" = catalog.example.com ] && [ "$(val NPM_ADMIN_EMAIL)" = it@mail.example.net ]'
printf '1\nCATALOG_DOMAIN\n""\nNPM_ADMIN_EMAIL\n""\ns\n0\n' | bash "$I" menu >/dev/null 2>&1
check "settings screen: both can be emptied again" '[ "$(val CATALOG_DOMAIN)" = "" ] && [ "$(val NPM_ADMIN_EMAIL)" = "" ]'
out="$(bash "$I" __settings_groups)"
check "settings screen: the domain with Catalog, the e-mail with Nginx Proxy Manager" 'grep -q "^CATALOG_|CATALOG_DOMAIN|$" <<< "$out" && grep -q "^NPM_|NPM_ADMIN_EMAIL|$" <<< "$out"'

# 3. DNS records: this server, another address (NAT), none, a stray AAAA record, /etc/hosts only
dc() { bash "$I" __domain_checks "$1" 2>&1; }
dns catalog.example.com 192.0.2.10
out="$(dc catalog.example.com)"
check "DNS: points to this server (no IPv6 warning for ::ffff: addresses)" 'grep -q "catalog.example.com points to this server (192.0.2.10)." <<< "$out" && grep -q "DOMAIN_DNS=ok" <<< "$out" && ! grep -q "IPv6" <<< "$out"'
dns nat.example.com 203.0.113.7
out="$(dc nat.example.com)"
check "DNS: another address is fine behind NAT, not blocked" 'grep -q "nat.example.com points to 203.0.113.7 - not an address of this server, which is fine behind NAT" <<< "$out" && grep -q "DOMAIN_DNS=other" <<< "$out"'
out="$(dc new.example.com)"
check "DNS: not in DNS yet" 'grep -q "new.example.com is not in DNS yet (no A or AAAA record)" <<< "$out" && grep -q "DOMAIN_DNS=missing" <<< "$out"'
dns v6.example.com 192.0.2.10 2001:db8::99
out="$(dc v6.example.com)"
check "DNS: an AAAA record elsewhere is named" 'grep -q "points to this server (192.0.2.10)" <<< "$out" && grep -q "IPv6 address 2001:db8::99 (AAAA record), which is not on this server" <<< "$out"'
dns six.example.com 2001:db8::10
out="$(dc six.example.com)"
check "DNS: an IPv6 address of this server counts" 'grep -q "six.example.com points to this server (2001:db8::10)." <<< "$out"'
dns box.example.com 127.0.1.1
out="$(dc box.example.com)"
check "DNS: only /etc/hosts of this server" 'grep -q "box.example.com points to 127.0.1.1 only on this server (/etc/hosts)" <<< "$out" && grep -q "DOMAIN_DNS=loopback" <<< "$out"'
dns catalog.local 192.0.2.10
out="$(dc catalog.local)"
check "DNS: a .local name gets no certificate" 'grep -q "$LE gives no certificates for names ending in .local" <<< "$out" && grep -q "DOMAIN_DNS=ok" <<< "$out"'

# 4. 'domain' before an installation: the settings change together, BASEURL follows them
fresh
out="$(printf 'admin@example.com\nit@mail.example.net\n' | bash "$I" domain catalog.example.com 2>&1)"; rc=$?
check "domain: settings saved in one go" '[ "$rc" -eq 0 ] && [ "$(val CATALOG_DOMAIN)" = catalog.example.com ] && [ "$(val NPM_ADMIN_EMAIL)" = it@mail.example.net ] && [ "$(val BASEURL)" = https://catalog.example.com ] && [ "$(val INSTALL_NGINX_PROXY_MANAGER)" = true ]'
check "domain: the placeholder address is refused for $LE" 'grep -q "$LE does not take addresses at example.com" <<< "$out"'
check "domain: no backup left, nothing generated, the next step named" '! ls "$D"/$N.bak-* >/dev/null 2>&1 && [ ! -f "$D/.env" ] && grep -q "Nothing is installed here yet: the installation uses these settings, then .* domain. sets up Nginx Proxy Manager" <<< "$out"'
out="$(bash "$I" domain - </dev/null 2>&1)"
check "domain -: removed, BASEURL back to its default, the e-mail stays" '[ "$(val CATALOG_DOMAIN)" = "" ] && [ "$(val BASEURL)" = http://catalog-web ] && [ "$(val NPM_ADMIN_EMAIL)" = it@mail.example.net ]'
fresh
out="$(printf 'it@example.org\nit@example.net\nIT@Mail.Example.NET\n' | bash "$I" domain catalog.example.com 2>&1)"
check "domain: example.org and example.net refused for $LE, the address saved in lower case" 'grep -q "$LE does not take addresses at example.org" <<< "$out" && grep -q "$LE does not take addresses at example.net" <<< "$out" && [ "$(val NPM_ADMIN_EMAIL)" = it@mail.example.net ]'
fresh
set_to INSTALL_NGINX_PROXY_MANAGER true false
out="$(printf '\n' | LISTEN_PORTS="22 80 81" bash "$I" domain catalog.example.com 2>&1)"
check "ports of Nginx Proxy Manager in use: named, Enter keeps it off" 'grep -q "In use on this server: port 80, 81 - Nginx Proxy Manager cannot start" <<< "$out" && [ "$(val INSTALL_NGINX_PROXY_MANAGER)" = false ] && [ "$(val CATALOG_DOMAIN)" = catalog.example.com ]'
out="$(printf '\nit@mail.example.net\n' | bash "$I" domain catalog.example.com 2>&1)"
check "ports free: Enter turns Nginx Proxy Manager on" '! grep -q "In use on this server" <<< "$out" && [ "$(val INSTALL_NGINX_PROXY_MANAGER)" = true ] && [ "$(val BASEURL)" = https://catalog.example.com ]'
fresh
set_to INSTALL_NGINX_PROXY_MANAGER true false
out="$(printf 'n\n' | bash "$I" domain Catalog.Example.com 2>&1)"
check "no Nginx Proxy Manager: http on the port of Catalog Web, no e-mail asked" '[ "$(val CATALOG_DOMAIN)" = catalog.example.com ] && [ "$(val BASEURL)" = http://catalog.example.com:8080 ] && [ "$(val INSTALL_NGINX_PROXY_MANAGER)" = false ] && ! grep -q "E-mail address" <<< "$out"'
fresh
set_to INSTALL_NGINX_PROXY_MANAGER true false; set_to CATALOG_WEB_PORT 8080 80
printf 'n\n' | bash "$I" domain catalog.example.com >/dev/null 2>&1
check "no Nginx Proxy Manager, Catalog Web on port 80: http://domain" '[ "$(val BASEURL)" = http://catalog.example.com ]'
bash "$I" domain - </dev/null >/dev/null 2>&1
cs="$(cksum < "$I")"
out="$(printf 'y\nit@mail.example.net\n' | bash "$I" domain catalog.example.com 2>&1)"; rc=$?
check "settings that clash (port 80 twice) change nothing" '[ "$rc" -ne 0 ] && grep -q "the settings do not work together" <<< "$out" && grep -q "host port 80 is used by more than one setting" <<< "$out" && [ "$(cksum < "$I")" = "$cs" ]'

# 5. Installed stack: domain, e-mail, certificate first, then the proxy host; a second run changes nothing
installed
check "first start: Nginx Proxy Manager created its admin from .env" '[ "$(cut -d"|" -f1 "$NS/user")" = admin@example.com ] && [ "$(cut -d"|" -f2 "$NS/user")" = "$(envv NPM_ADMIN_PASSWORD)" ]'
dns catalog.example.com 192.0.2.10
out="$(printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com 2>&1)"; rc=$?
check "domain: files written again, stack applied" '[ "$rc" -eq 0 ] && [ "$(envv CATALOG_DOMAIN)" = catalog.example.com ] && [ "$(envv BASEURL)" = https://catalog.example.com ] && [ "$(envv NPM_ADMIN_EMAIL)" = it@mail.example.net ] && [ "$(wc -l < "$NS/ups")" -eq 2 ]'
check "NPM: login with the placeholder, then the login becomes the e-mail address" 'grep -q "Logged in to Nginx Proxy Manager 2.16.0 as admin@example.com" <<< "$out" && grep -q "login is now it@mail.example.net" <<< "$out" && [ "$(cut -d"|" -f1 "$NS/user")" = it@mail.example.net ] && grep -qx "{\"email\":\"it@mail.example.net\"}" "$NS/body-user"'
check "NPM: certificate first, then the proxy host with it" '[ "$(grep -E "^POST /nginx/(certificates|proxy-hosts) " "$NS/calls" | tr "\n" ",")" = "POST /nginx/certificates 201,POST /nginx/proxy-hosts 201," ]'
check "NPM: the certificate request" 'grep -qxF "{\"provider\":\"letsencrypt\",\"domain_names\":[\"catalog.example.com\"],\"meta\":{\"dns_challenge\":false}}" "$NS/body-cert"'
hb="$(cat "$NS/body-host-2" 2>/dev/null)"
check "NPM: the proxy host forwards to catalog-web:80 with certificate, websockets, forced HTTPS, HTTP/2" 'grep -qF "\"domain_names\":[\"catalog.example.com\"],\"forward_scheme\":\"http\",\"forward_host\":\"catalog-web\",\"forward_port\":80,\"certificate_id\":1,\"ssl_forced\":true,\"http2_support\":true,\"block_exploits\":true,\"allow_websocket_upgrade\":true" <<< "$hb" && grep -qF "\"advanced_config\":\"client_max_body_size 0;\\nproxy_request_buffering off;\\nproxy_read_timeout 3600s;" <<< "$hb"'
check "NPM: every call after the login carries the token" '! grep -q " 401$" "$NS/calls" && [ "$(calls "GET /nginx/proxy-hosts 200")" -eq 1 ]'
check "outcome: https, checked on this server, remembered" 'grep -q "https://catalog.example.com/ answers through Nginx Proxy Manager (checked on this server)." <<< "$out" && grep -q "The Catalog: https://catalog.example.com - Nginx Proxy Manager renews the certificate" <<< "$out" && [ "$(cat "$D/.domain-certificate")" = catalog.example.com ]'
check "the password of NPM is not in the output of the setup" '! grep -q "$(cut -d"|" -f2 "$NS/user")" <<< "$(sed -n "/Setting up Nginx Proxy Manager/,\$p" <<< "$out")"'
out="$(bash "$I" info 2>&1)"
check "info: main address https, the NPM login and where its password is" 'grep -Eq "^  Catalog Web +https://catalog.example.com$" <<< "$out" && grep -q "login it@mail.example.net, password: .*credentials" <<< "$out" && [ "$(grep -c "Catalog Web (direct)" <<< "$out")" -eq 1 ] && grep -q "Nginx Proxy Manager forwards catalog.example.com to Catalog Web" <<< "$out"'
: > "$NS/calls"
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "again: nothing changes, the host is reused, nothing is requested" '[ "$rc" -eq 0 ] && grep -q "The settings stay as they are." <<< "$out" && grep -q "has a certificate already" <<< "$out" && ! grep -q "^POST /nginx" "$NS/calls" && [ "$(nhosts)" -eq 1 ] && [ "$(wc -l < "$NS/ups")" -eq 2 ]'
out="$(bash "$I" domain - </dev/null 2>&1)"
check "domain removed: BASEURL default, files and stack applied, the old host named" '[ "$(envv CATALOG_DOMAIN)" = "" ] && [ "$(envv BASEURL)" = http://catalog-web ] && [ "$(wc -l < "$NS/ups")" -eq 3 ] && grep -q "The proxy host of catalog.example.com stays in Nginx Proxy Manager" <<< "$out" && [ ! -f "$D/.domain-certificate" ]'

# 6. Let's Encrypt refuses: the host is created for HTTP only; the next run adds the certificate to it
installed
dns catalog.example.com 192.0.2.10
touch "$NS/le_fail"
out="$(printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com 2>&1)"; rc=$?
check "certificate refused: the reason, the cause and the retry are named" '[ "$rc" -eq 0 ] && grep -q "$LE gave no certificate for catalog.example.com (HTTP 500)" <<< "$out" && grep -q "Detail: DNS problem: NXDOMAIN looking up A for catalog.example.com" <<< "$out" && grep -q "DNS: catalog.example.com has no A/AAAA record yet" <<< "$out" && grep -q "no certificate yet: $LE refused it" <<< "$out" && grep -q "requests it ($LE allows 5 failed attempts per hour)" <<< "$out"'
check "certificate refused: one attempt, the host for HTTP only" '[ "$(calls "POST /nginx/certificates")" -eq 1 ] && [ "$(host_of 1)" = "catalog.example.com|0|catalog-web|80|false" ] && grep -q "Proxy host #1: catalog.example.com to catalog-web:80, HTTP only." <<< "$out" && grep -q "http://catalog.example.com/ answers through Nginx Proxy Manager" <<< "$out"'
out="$(bash "$I" info 2>&1)"
check "info: http and no certificate yet" '[ ! -f "$D/.domain-certificate" ] && grep -q "http://catalog.example.com   (no certificate yet - .*domain.)" <<< "$out"'
rm -f "$NS/le_fail"; : > "$NS/calls"
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "retry: the certificate is added to the existing host, no second host" '[ "$rc" -eq 0 ] && [ "$(nhosts)" -eq 1 ] && ! grep -q "^POST /nginx/proxy-hosts" "$NS/calls" && grep -q "^PUT /nginx/proxy-hosts/1 200$" "$NS/calls" && [ "$(host_of 1)" = "catalog.example.com|2|catalog-web|80|true" ] && grep -qx "{\"certificate_id\":2,\"ssl_forced\":true,\"http2_support\":true}" "$NS/body-put-1"'
check "retry: https" 'grep -q "certificate #2 added, HTTPS forced" <<< "$out" && [ "$(cat "$D/.domain-certificate")" = catalog.example.com ]'

# 7. A certificate of the domain that is still valid is used; an expired one is not
installed
dns catalog.example.com 192.0.2.10
printf '%s\n' "catalog.example.com|2099-06-01 00:00:00" > "$NS/certs/7"; echo 7 > "$NS/seq"
printf '%s\n' "other.example.com|2099-06-01 00:00:00" > "$NS/certs/3"
out="$(printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com 2>&1)"
check "existing certificate used, none requested" '! grep -q "^POST /nginx/certificates" "$NS/calls" && grep -q "certificate for catalog.example.com already (#7) - it is used" <<< "$out" && [ "$(host_of 8)" = "catalog.example.com|7|catalog-web|80|true" ]'
installed
dns catalog.example.com 192.0.2.10
printf '%s\n' "catalog.example.com|2020-06-01 00:00:00" > "$NS/certs/7"; echo 7 > "$NS/seq"
printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com >/dev/null 2>&1
check "expired certificate: a new one is requested" '[ "$(calls "POST /nginx/certificates 201")" -eq 1 ] && [ "$(host_of 9)" = "catalog.example.com|8|catalog-web|80|true" ]'

# 8. When the setup stops or leaves the certificate out
installed
dns catalog.example.com 192.0.2.10
echo 2.12.6 > "$NS/version"
out="$(printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com 2>&1)"; rc=$?
check "NPM 2.12.6 refused, no login tried" '[ "$rc" -ne 0 ] && grep -q "Nginx Proxy Manager 2.12.6 is too old: the automatic setup needs 2.13.0 or newer" <<< "$out" && ! grep -q "^POST /tokens" "$NS/calls"'
echo 2.16.0 > "$NS/version"; touch "$NS/npm_down"; : > "$NS/calls"
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "NPM not running: says so at once" '[ "$rc" -ne 0 ] && grep -q "Nginx Proxy Manager does not run - start the stack first" <<< "$out" && [ ! -s "$NS/calls" ]'
rm -f "$NS/npm_down"; mv "$NS/user" "$NS/user.off"
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "NPM without its admin user: regenerate and apply" '[ "$rc" -ne 0 ] && grep -q "has no admin user yet" <<< "$out" && grep -q "Write the files again" <<< "$out"'
printf '%s\n' "someone@example.net|another-password" > "$NS/user"
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "NPM set up on its own page: login refused (the last known login first), the manual way named" '[ "$rc" -ne 0 ] && grep -q "Nginx Proxy Manager refused the login of .env (admin@example.com it@mail.example.net; HTTP 400)" <<< "$out" && grep -q "set up the proxy host by hand" <<< "$out" && [ "$(nhosts)" -eq 0 ]'
out="$(bash "$I" credentials 2>&1)"
check "after the refused login: no NPM login or password shown as valid" '[ "$(cat "$D/.npm-login")" = "-" ] && grep -q "NPM login      : as set up in Nginx Proxy Manager" <<< "$out" && ! grep -q "NPM password" <<< "$out"'
mv "$NS/user.off" "$NS/user"; touch "$NS/tfa"
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "NPM user with two-factor authentication: by hand" '[ "$rc" -ne 0 ] && grep -q "two-factor authentication" <<< "$out"'
rm -f "$NS/tfa"
installed
out="$(printf 'it@mail.example.net\n' | bash "$I" domain new.example.com 2>&1)"; rc=$?
check "not in DNS yet: no attempt, HTTP only" '[ "$rc" -eq 0 ] && ! grep -q "^POST /nginx/certificates" "$NS/calls" && [ "$(host_of 1)" = "new.example.com|0|catalog-web|80|false" ] && grep -q "no certificate yet: new.example.com is not in DNS yet" <<< "$out"'
installed
dns catalog.local 192.0.2.10
out="$(printf 'it@mail.example.net\n' | bash "$I" domain catalog.local 2>&1)"; rc=$?
check ".local name: no attempt, HTTP only" '[ "$rc" -eq 0 ] && ! grep -q "^POST /nginx/certificates" "$NS/calls" && grep -q "no certificate yet: $LE gives no certificates for names ending in .local" <<< "$out"'
installed
dns catalog.example.com 192.0.2.10
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "no e-mail address: no attempt, HTTP only" '[ "$rc" -eq 0 ] && grep -q "Without an e-mail address" <<< "$out" && ! grep -q "^POST /nginx/certificates" "$NS/calls" && grep -q "needs a real e-mail address, the Nginx Proxy Manager login is admin@example.com" <<< "$out" && [ "$(nhosts)" -eq 1 ]'
printf '%s\n' "catalog.example.com|0|10.0.0.5|8080|false" > "$NS/hosts/1"
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"
check "a host made by hand to another target is left as it is" 'grep -q "forwards to 10.0.0.5:8080, not to catalog-web:80 - it is left as it is" <<< "$out" && [ "$(nhosts)" -eq 1 ]'
installed
dns catalog.example.com 192.0.2.10
printf '%s\n' "catalog.example.com|0|10.0.0.5|8080|false" > "$NS/hosts/1"; echo 1 > "$NS/seq"
out="$(printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com 2>&1)"; rc=$?
check "a host to another target with a real e-mail: no certificate, not changed, the setup stops" '[ "$rc" -ne 0 ] && grep -q "Point it to catalog-web, port 80, or delete it there" <<< "$out" && ! grep -q "^POST /nginx/certificates" "$NS/calls" && ! grep -q "^PUT /nginx/proxy-hosts" "$NS/calls" && [ "$(host_of 1)" = "catalog.example.com|0|10.0.0.5|8080|false" ] && [ ! -f "$D/.domain-certificate" ] && ! grep -q "The Catalog: https" <<< "$out"'

# 9. Menu option 24: asks for domain and e-mail, applies the files as a job, asks before Let's Encrypt
installed
dns catalog.example.com 192.0.2.10
out="$(printf '24\ncatalog.example.com\nit@mail.example.net\ny\n\n0\n' | bash "$I" menu 2>&1)"
check "option 24: domain and e-mail asked, files applied as a job, yes to $LE: https" 'grep -q "Domain and HTTPS" <<< "$out" && grep -q "Started as job" <<< "$out" && [ "$(wc -l < "$NS/ups")" -eq 2 ] && [ "$(val NPM_ADMIN_EMAIL)" = it@mail.example.net ] && grep -q "$LE certificate #1 for catalog.example.com." <<< "$out" && [ "$(cat "$D/.domain-certificate" 2>/dev/null)" = catalog.example.com ] && [ "$(nhosts)" -eq 1 ]'
out="$(printf '24\n\n\n0\n' | bash "$I" menu 2>&1)"
check "option 24 again: Enter keeps the domain, nothing requested twice" 'grep -q "The settings stay as they are." <<< "$out" && grep -q "has a certificate already" <<< "$out" && [ "$(calls "POST /nginx/certificates")" -eq 1 ]'
out="$(printf '15\n\n0\n' | bash "$I" menu 2>&1)"
check "option 15: https address and the NPM login with the menu option of its password" 'grep -Eq "^  Catalog Web +https://catalog.example.com$" <<< "$out" && grep -q "login it@mail.example.net, password: menu option 14" <<< "$out"'
installed
dns catalog.example.com 192.0.2.10
out="$(printf '24\ncatalog.example.com\nit@mail.example.net\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "option 24: no to $LE - HTTP only, nothing requested" '! grep -q "^POST /nginx/certificates" "$NS/calls" && grep -q "no certificate yet: not requested" <<< "$out" && [ "$(nhosts)" -eq 1 ]'
out="$(bash "$I" help 2>&1)"
check "usage names the command" 'grep -q "domain \[NAME|-\]" <<< "$out"'
check "menu: option 24 in ACCESS" 'bash "$I" __menu_items | grep -qx "1|24|run|Domain and HTTPS|domain, proxy, $LE|Sets the domain, proxy host and certificate"'

# 10. Files edited by hand: 'domain' keeps them and still sets up the certificate; the menu asks first
installed
dns catalog.example.com 192.0.2.10
touch "$NS/le_fail"
printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com >/dev/null 2>&1
rm -f "$NS/le_fail"
printf '# kept by hand\n' >> "$D/docker-compose.yml"
: > "$NS/calls"
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "files edited by hand: 'domain' keeps them, no restart, the certificate is added" '[ "$rc" -eq 0 ] && grep -q "do not match the settings" <<< "$out" && grep -q "The files stay as they are" <<< "$out" && grep -qx "# kept by hand" "$D/docker-compose.yml" && [ "$(wc -l < "$NS/ups")" -eq 2 ] && [ "$(host_of 1)" = "catalog.example.com|2|catalog-web|80|true" ]'
installed
dns catalog.example.com 192.0.2.10
touch "$NS/le_fail"
printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com >/dev/null 2>&1
rm -f "$NS/le_fail"
printf '# kept by hand\n' >> "$D/docker-compose.yml"
out="$(printf '24\n\nn\ny\n\n0\n' | bash "$I" menu 2>&1)"
check "option 24, files edited by hand, no to writing them: kept, the certificate is still requested" 'grep -q "The files stay as they are" <<< "$out" && grep -qx "# kept by hand" "$D/docker-compose.yml" && [ "$(wc -l < "$NS/ups")" -eq 2 ] && [ "$(host_of 1)" = "catalog.example.com|2|catalog-web|80|true" ]'

# 11. The NPM login: lower case end to end, the address it was created with, new passwords, reset
fresh
dns catalog.example.com 192.0.2.10
printf 'IT@Mail.Example.NET\n' | bash "$I" domain catalog.example.com >/dev/null 2>&1
bash "$I" generate </dev/null >/dev/null 2>&1; bash "$I" up </dev/null >/dev/null 2>&1
out="$(bash "$I" domain catalog.example.com </dev/null 2>&1)"; rc=$?
check "e-mail typed with capitals: NPM created its admin in lower case, the login works" '[ "$rc" -eq 0 ] && [ "$(cut -d"|" -f1 "$NS/user")" = it@mail.example.net ] && grep -q "Logged in to Nginx Proxy Manager 2.16.0 as it@mail.example.net" <<< "$out" && ! grep -q "login is now" <<< "$out" && grep -q "The Catalog: https://catalog.example.com" <<< "$out"'
installed
check "first start: the login NPM was created with is remembered" '[ "$(cat "$D/.npm-login")" = admin@example.com ]'
set_to NPM_ADMIN_EMAIL "" it@mail.example.net
bash "$I" generate </dev/null >/dev/null 2>&1; bash "$I" up </dev/null >/dev/null 2>&1
out="$(bash "$I" credentials 2>&1)"
check "e-mail changed after the first start: the login NPM still has is shown" '[ "$(cut -d"|" -f1 "$NS/user")" = admin@example.com ] && grep -qx "  NPM login      : admin@example.com" <<< "$out" && grep -qx "  NPM password   : $(envv NPM_ADMIN_PASSWORD)" <<< "$out"'
out="$(bash "$I" generate --new-passwords </dev/null 2>&1)"
check "--new-passwords with the NPM volume: its admin keeps the old login" '[ "$(cat "$D/.npm-login")" = "-" ] && grep -q "Nginx Proxy Manager keep the original ones" <<< "$out"'
out="$(bash "$I" credentials 2>&1)"
check "credentials after new passwords: the NPM login as set up there, no password" 'grep -qx "  NPM login      : as set up in Nginx Proxy Manager (its admin was not created from .env)" <<< "$out" && ! grep -q "NPM password" <<< "$out"'
out="$(bash "$I" info 2>&1)"
check "info after new passwords: the NPM login as set up there" 'grep -Eq "^  Nginx Proxy Manager +http://.*:81   login as set up in Nginx Proxy Manager$" <<< "$out"'
out="$(printf '99\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "option 99: the volumes and both markers are gone" '[ -s "$NS/downs" ] && [ ! -f "$NS/user" ] && [ ! -f "$D/.npm-login" ] && [ ! -f "$D/.domain-certificate" ]'
bash "$I" up </dev/null >/dev/null 2>&1
out="$(bash "$I" credentials 2>&1)"
check "start after the reset: NPM creates its admin from .env again, shown" '[ "$(cut -d"|" -f2 "$NS/user")" = "$(envv NPM_ADMIN_PASSWORD)" ] && [ "$(cat "$D/.npm-login")" = it@mail.example.net ] && grep -qx "  NPM login      : it@mail.example.net" <<< "$out"'
installed
dns catalog.example.com 192.0.2.10
printf 'it@mail.example.net\n' | bash "$I" domain catalog.example.com >/dev/null 2>&1
out="$(printf '99\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
out="$(bash "$I" info 2>&1)"
check "reset after https: no stale certificate marker, info says no certificate yet" '[ ! -f "$D/.domain-certificate" ] && grep -q "http://catalog.example.com   (no certificate yet" <<< "$out"'
installed
sed -i '/^NPM_ADMIN_PASSWORD=/d' "$D/.env"; rm -f "$D/.npm-login"
out="$(bash "$I" credentials 2>&1)"
check "installation of an older installer (NPM running, no password in .env): no NPM login shown" 'grep -q "NPM login      : as set up in Nginx Proxy Manager" <<< "$out"'
bash "$I" generate </dev/null >/dev/null 2>&1
out="$(bash "$I" credentials 2>&1)"
check "its first generate: the new NPM password is not shown as the login of the existing admin" '[ "$(cat "$D/.npm-login")" = "-" ] && grep -q "NPM login      : as set up in Nginx Proxy Manager" <<< "$out" && ! grep -q "NPM password" <<< "$out"'

check "no podman, compose, curl, getent, ss or systemctl call the fakes do not know" '[ ! -s "$UNH" ] || { sort -u "$UNH"; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
