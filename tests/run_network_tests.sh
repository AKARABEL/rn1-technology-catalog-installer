#!/usr/bin/env bash
# Internet access (option 26): the sites, their check and its status words, the proxy questions (address,
# login, NTLM, SOCKS, PAC, WPAD, company certificate), the menu start in the background, option 16, the
# session proxy for the package managers and sudo. Fakes only: curl answers from a table, no real proxy.
set -u
NEW="$1"
T="$(mktemp -d)/n"
rm -rf "$T"; mkdir -p "$T/bin" "$T/d" "$T/etc" "$T/run" "$T/home" "$T/sys"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; if [ -n "${NET_DEBUG:-}" ]; then printf "%s
" "${out:-}" | tail -n 40 | sed "s/^/  | /"; fi; fi; }
unset XDG_CONFIG_HOME COLIMA_HOME http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY \
  RN1_PROXY_SET RN1_NET_CHECK RN1_NET_CACHE_TTL
export LC_ALL=C

# The test login: user DOM\user, a password with every character that needs encoding
PW="p@ss:w%rd\$#\\'x"
PW_ENC='p%40ss%3Aw%25rd%24%23%5C%27x'
USR='DOM\user'
USR_ENC='DOM%5Cuser'
export FAKE_LOGIN="$USR_ENC:$PW_ENC"

# A PATH without the real tools the fakes stand for (CI runners have them): every folder of the PATH in its
# order, one link per command
REAL_UNAME="$(command -v uname)"; export REAL_UNAME
IFS=: read -r -a dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="${f##*/}"
    case "$b" in
      podman|docker|docker-compose|podman-compose|dockerd|brew|colima|curl|wget|sudo|apt-get|apt-config|dnf|yum|zypper|systemctl|pactester|proxy|hostname|id|scutil|uname|update-ca-trust|update-ca-certificates) continue ;;
    esac
    [ -e "$T/sys/$b" ] || ln -s "$f" "$T/sys/$b" 2>/dev/null
  done
done
SYSPATH="$T/sys"
for d in "${dirs[@]}"; do
  case "$d" in */libexec/gnubin) SYSPATH="$d:$SYSPATH" ;; esac
done

# Fake curl: answers from $ANSWERS, one line per answer, the first that matches wins:
#   ROUTE|URL|EXIT|HTTP-CODE|CONNECT-CODE|VERIFY|HEADERS|BODY|EFFECTIVE-URL|ISSUER|DELAY
# ROUTE and URL are patterns. ROUTE is "direct" or "proxy HOST:PORT LOGIN" - LOGIN none, ok (FAKE_LOGIN) or
# wrong; the proxy comes from the config on stdin (-K -), else from https_proxy (a --noproxy '*' means
# direct); the names of noproxy go direct. Every call in $LOG (route and URL, never a password), every
# command line in $ARGV_LOG; a URL no line answers goes to $BAD.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; hdr=""; fmt=""; url=""; cfg=""; nopx=""; verbose=""; fail=""; envpx="yes"; insecure=""
printf 'curl' >> "$ARGV_LOG"; printf ' %q' "$@" >> "$ARGV_LOG"; echo >> "$ARGV_LOG"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -K) if [ "$2" = "-" ]; then cfg="$(cat)"; fi; shift 2 ;;
    --noproxy) nopx="$2"; [ "$2" = "*" ] && envpx="no"; shift 2 ;;
    -x|--proxy) echo "PROXY ON THE COMMAND LINE: $2" >> "$BAD"; shift 2 ;;
    -r|-H|--connect-timeout|--max-time|--proto) shift 2 ;;
    --*) shift ;;
    --insecure) insecure=1; shift ;;
    -*) case "$1" in *v*) verbose=1 ;; esac; case "$1" in *f*) fail=1 ;; esac; case "$1" in *k*) insecure=1 ;; esac; shift ;;
    *) url="$1"; shift ;;
  esac
done
px=""
if [ -n "$cfg" ]; then
  if printf '%s\n' "$cfg" | grep -q '^proxy-insecure' && printf '%s\n' "$cfg" | grep -q '^proxy = "https://[^"]*@'; then
    echo "LOGIN TO AN UNCHECKED HTTPS PROXY" >> "$BAD"
  fi
  px="$(printf '%s\n' "$cfg" | sed -n 's/^proxy = "\(.*\)"$/\1/p')"
  nopx="$(printf '%s\n' "$cfg" | sed -n 's/^noproxy = "\(.*\)"$/\1/p')"
elif [ "$envpx" = "yes" ] && [ -n "${https_proxy:-}" ]; then
  px="$https_proxy"; nopx="${no_proxy:-}"
fi
host="${url#*://}"; host="${host%%[/:?]*}"
if [ -n "$px" ] && [ -n "$nopx" ]; then
  IFS=',' read -r -a nl <<< "$nopx"
  for n in "${nl[@]}"; do n="${n#.}"; if [ -n "$n" ] && { [ "$host" = "$n" ] || [[ "$host" == *".$n" ]]; }; then px=""; fi; done
fi
if [ -z "$px" ]; then
  route="direct"
else
  hp="${px#*://}"; login=""
  if [[ "$hp" == *@* ]]; then login="${hp%@*}"; hp="${hp##*@}"; fi
  hp="${hp%/}"
  if [ -z "$login" ]; then st=none; elif [ "$login" = "${FAKE_LOGIN:-}" ]; then st=ok; else st=wrong; fi
  route="proxy $hp $st"
fi
echo "$route $url" >> "$LOG"
while IFS='|' read -r rp up rc code conn ver hdrs body eff issuer delay; do
  [ -n "$rp" ] || continue
  case "$rp" in \#*) continue ;; esac
  case "$route" in $rp) ;; *) continue ;; esac
  case "$url" in $up) ;; *) continue ;; esac
  if [ -n "$delay" ]; then sleep "$delay"; fi
  # VERIFY T19: 19 until the company certificate is in the trust store (RN1_TRUST_DIR), then 0
  if [ "${ver#T}" != "$ver" ]; then
    if ls "${RN1_TRUST_DIR:-/nonexistent}"/rn1-proxy-ca-* >/dev/null 2>&1; then ver=0; else ver="${ver#T}"; fi
  fi
  # as real curl (OpenSSL): -k loads no certificates, so even a trusted site gives 20; without -k an
  # untrusted certificate ends the request with exit code 60 and no answer
  if [ -n "$insecure" ] && [ "$ver" = 0 ]; then ver=20; fi
  if [ -z "$insecure" ] && [ "$ver" != 0 ] && [ "$rc" = 0 ]; then rc=60; code=000; hdrs=""; body=""; fi
  if [ -n "$hdr" ]; then printf '%b' "$hdrs" > "$hdr"; fi
  if [ -n "$out" ] && [ "$out" != "-" ]; then printf '%b' "$body" > "$out"; else printf '%b' "$body"; fi
  if [ -n "$verbose" ] && [ -n "$issuer" ]; then printf '* Server certificate:\n*  issuer: %s\n' "$issuer" >&2; fi
  if [ -n "$fmt" ]; then
    f="${fmt//%\{http_code\}/$code}"; f="${f//%\{http_connect\}/$conn}"; f="${f//%\{ssl_verify_result\}/$ver}"
    f="${f//%\{url_effective\}/${eff:-$url}}"; f="${f//%\{remote_ip\}/192.0.2.99}"
    printf '%s' "$f"
  fi
  if [ "$rc" != "0" ]; then echo "curl: ($rc) the fake says so" >&2; exit "$rc"; fi
  if [ -n "$fail" ] && [ "$code" -ge 400 ]; then exit 22; fi
  exit 0
done < "$ANSWERS"
echo "UNHANDLED curl $route $url" >> "$BAD"
exit 7
EOF
# the answers of the internet as it should be (any route)
D200='HTTP/1.1 200 OK\r\n\r\n'
cat > "$T/good.answers" <<EOF
*|https://registry-1.docker.io/v2/|0|401|200|0|HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer realm="https://auth.docker.io/token",service="registry.docker.io"\r\n\r\n|{"errors":[]}|||
*|https://auth.docker.io/token*|0|200|200|0|$D200|{"token":"T1","access_token":"T1"}|||
*|https://registry-1.docker.io/v2/*/manifests/*|0|200|200|0|HTTP/1.1 200 OK\r\ndocker-content-digest: sha256:aaaa\r\nratelimit-limit: 100;w=21600\r\nratelimit-remaining: 87;w=21600\r\n\r\n||||
*|https://hub.docker.com/v2/repositories/*/tags/*/images|0|200|200|0|$D200|[{"architecture":"amd64","layers":[{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":5}]}]|||
*|https://registry-1.docker.io/v2/*/blobs/sha256:1111*|0|307|200|0|HTTP/1.1 307 Temporary Redirect\r\nlocation: https://production.cloudfront.docker.com/registry-v2/blobs/sha256/11/data?sig=x\r\n\r\n||||
*|https://production.cloudfront.docker.com/*|0|206|200|0|HTTP/1.1 206 Partial Content\r\n\r\n|x|||
*|https://ghcr.io/v2/|0|401|200|0|HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:user/image:pull"\r\n\r\n||||
*|https://ghcr.io/token*|0|200|200|0|$D200|{"token":"G1"}|||
*|https://ghcr.io/v2/*/manifests/sha256:*|0|200|200|0|$D200|{"schemaVersion":2,"config":{"digest":"sha256:4444"},"layers":[{"digest":"sha256:3333333333333333333333333333333333333333333333333333333333333333","size":9}]}|||
*|https://ghcr.io/v2/*/manifests/*|0|200|200|0|$D200|{"manifests":[{"digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222","platform":{"architecture":"amd64","os":"linux"}}]}|||
*|https://ghcr.io/v2/*/blobs/sha256:3333*|0|307|200|0|HTTP/1.1 307 Temporary Redirect\r\nLocation: https://pkg-containers.githubusercontent.com/ghcr1/blobs/sha256:3333?se=x\r\n\r\n||||
*|https://pkg-containers.githubusercontent.com/*|0|206|200|0|HTTP/1.1 206 Partial Content\r\n\r\n|x|||
*|https://download.docker.com/linux/*/gpg|0|200|200|0|$D200|-----BEGIN PGP PUBLIC KEY BLOCK-----\nx|||
*|https://github.com/docker/compose/releases/latest|0|302|200|0|HTTP/1.1 302 Found\r\nlocation: https://github.com/docker/compose/releases/tag/v5.6.0\r\n\r\n||||
*|https://github.com/docker/compose/releases/latest/download/*|0|206|200|0|HTTP/1.1 206 Partial Content\r\n\r\n|a|https://release-assets.githubusercontent.com/github-production-release-asset/1/x?sp=r||
*|https://hub.docker.com/v2/repositories/*/tags?page_size=1|0|200|200|0|$D200|{"count":3,"next":null,"results":[]}|||
*|https://raw.githubusercontent.com/*|0|206|200|0|HTTP/1.1 206 Partial Content\r\n\r\n|#!/usr/bin/env bash\nif|||
*|https://rayventorycatalog.raynet.de/v1/license/isValid|0|200|200|0|$D200|true|||
*|https://licenses.raynet.de/Account/Login.aspx|0|200|200|0|HTTP/1.1 200 OK\r\nX-Served-By: licenses.raynet.de\r\n\r\n|<html></html>|||
*|https://acme-v02.api.letsencrypt.org/directory|0|200|200|0|$D200|{"newAccount":"https://acme-v02.api.letsencrypt.org/acme/new-acct"}|||
*|https://ip-ranges.amazonaws.com/ip-ranges.json|0|206|200|0|HTTP/1.1 206 Partial Content\r\n\r\n|{"syncToken":"1","createDate":"x","prefixes":[|||
*|https://www.cloudflare.com/ips-v4|0|200|200|0|$D200|192.0.2.0/24\n198.51.100.0/24|||
*|http://deb.example.com/debian/dists/*/InRelease|0|200|200|0|$D200|-----BEGIN PGP SIGNED MESSAGE-----|||
*|https://mirror.example.com/rpm/*/repodata/repomd.xml|0|200|200|0|$D200|<?xml version="1.0"?><repomd>|||
*|https://meta.example.com/metalink*|0|200|200|0|$D200|<?xml version="1.0"?><metalink>|||
*|https://cdn.example.com/|0|403|200|0|HTTP/1.1 403 Forbidden\r\n\r\n||||
EOF
# scen LINE... -> these answers first, then the good internet
scen() { printf '%s\n' "$@" > "$T/answers"; cat "$T/good.answers" >> "$T/answers"; }
P407='HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="corp"\r\n\r\n'
# a proxy that takes the test login (Basic) and passes everything on
LOGIN_PROXY=("proxy proxy.example.com:8080 none|*|56|000|407|0|$P407||||" "proxy proxy.example.com:8080 wrong|*|56|000|407|0|$P407||||")
# no internet name resolves without the proxy
NODNS='direct|*|6|000|000|0||||||'

# Fake wget (only in $T/wbin, where curl is missing): WGET_MODE ok or nodns
mkdir -p "$T/wbin"
cat > "$T/wbin/wget" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
echo "wget $url" >> "$LOG"
if [ "${WGET_MODE:-ok}" = nodns ]; then echo "wget: unable to resolve host address 'x'" >&2; exit 4; fi
case "$url" in
  https://registry-1.docker.io/v2/|https://ghcr.io/v2/) echo "  HTTP/1.1 401 Unauthorized" >&2; exit 8 ;;
  https://github.com/docker/compose/releases/latest) echo "  HTTP/1.1 302 Found" >&2; exit 0 ;;
esac
echo "  HTTP/1.1 200 OK" >&2
exit 0
EOF
# sudo as configured by default: env_reset drops the proxy variables (PATH and the test's own stay)
cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$SUDO_LOG"
exec env -i PATH="$PATH" HOME="$HOME" T="$T" LOG="$LOG" BAD="$BAD" ARGV_LOG="$ARGV_LOG" ANSWERS="$ANSWERS" FAKE_LOGIN="$FAKE_LOGIN" \
  SUDO_LOG="$SUDO_LOG" REAL_UNAME="$REAL_UNAME" RN1_TRUST_DIR="${RN1_TRUST_DIR:-}" "$@"
EOF
# this server: srv01.corp.example.com
cat > "$T/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-n" ]; then echo "srv01.corp.example.com"; exit 0; fi
exec "$REAL_UNAME" "$@"
EOF
# the package managers: what reached them (the proxy without its password, whether the login is the test's,
# the run files and their modes, the configuration of -c without passwords)
cat > "$T/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
n="${0##*/}"
printf '%s' "$n" >> "$T/pm.log"; printf ' %q' "$@" >> "$T/pm.log"; echo >> "$T/pm.log"
p="${https_proxy:-}"; l=none
if [[ "$p" == *@* ]]; then l="${p#*://}"; l="${l%@*}"; if [ "$l" = "$FAKE_LOGIN" ]; then l=ok; else l=wrong; fi; fi
echo "$n proxy=${p:+${p%%://*}://${p##*@}} login=$l no_proxy=${no_proxy:+set}" >> "$T/pm.env"
for f in "$T"/run/rn1-*; do [ -e "$f" ] && echo "$n file ${f##*/} $(stat -c %a "$f")" >> "$T/pm.env"; done
if [ "${1:-}" = "-c" ]; then sed "s#//[^@\"]*@#//***@#g; s/^/$n conf /" "$2" >> "$T/pm.env"; fi
if [ "${1#--config=}" != "${1:-}" ]; then sed "s#//[^@\"]*@#//***@#g; s/^/$n conf /" "${1#--config=}" >> "$T/pm.env"; fi
exit 0
EOF
cp "$T/bin/apt-get" "$T/bin/dnf"
cat > "$T/bin/apt-config" <<'EOF'
#!/usr/bin/env bash
[ "$*" = "dump" ] || { echo "UNHANDLED apt-config $*" >> "$BAD"; exit 1; }
echo 'APT::Architecture "amd64";'
if [ -f "$T/apt.proxy" ]; then echo "Acquire::http::Proxy \"$(cat "$T/apt.proxy")\";"; fi
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "show docker.service -p Environment")
    if [ -f "$T/docker.env" ]; then echo "Environment=HTTPS_PROXY=http://dockerproxy.example.com:3128 NO_PROXY=localhost"; else echo "Environment="; fi ;;
  "show podman.service -p Environment") echo "Environment=" ;;
  # SHIM_INACTIVE: the units that do not run
  is-active*) case " ${SHIM_INACTIVE:-} " in *" ${*: -1} "*) exit 3 ;; esac ;;
  is-enabled*) exit 0 ;;
  daemon-reload|"restart docker"|"stop podman.service") echo "systemctl $*" >> "$T/systemctl.log" ;;
  *) echo "UNHANDLED systemctl $*" >> "$BAD"; exit 1 ;;
esac
EOF
# the trust stores of the distributions: what they were run with, and the certificates there then
for f in update-ca-trust update-ca-certificates; do
  printf '#!/usr/bin/env bash\necho "%s $* $(ls "${RN1_TRUST_DIR:-/nonexistent}" 2>/dev/null | tr "\\n" " ")" >> "$T/trust.log"\n' "$f" > "$T/bin/$f"
done
# the engines (only on the PATH where a case puts $T/ebin first): their version, no containers or volumes
mkdir -p "$T/ebin"
for e in docker podman; do
  cat > "$T/ebin/$e" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  --version) if [ "${0##*/}" = docker ]; then echo "Docker version 29.9.0, build 1a2b3c4"; else echo "podman version 5.7.0"; fi ;;
  "ps -aq --filter label=com.docker.compose.project="*|"volume ls -q --filter label=com.docker.compose.project="*) ;;
  *) echo "UNHANDLED ${0##*/} $*" >> "$BAD"; exit 1 ;;
esac
EOF
done
chmod +x "$T/ebin/"*
cat > "$T/bin/hostname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -d) echo "${SHIM_DOMAIN:-}" ;;
  -I) echo "192.0.2.10" ;;
  *) echo "srv01" ;;
esac
EOF
cat > "$T/bin/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then echo "${SHIM_UID:-1000}"; exit 0; fi
exec "$T/sys/id" "$@"
EOF
mkdir -p "$T/pbin"
cat > "$T/pbin/pactester" <<'EOF'
#!/usr/bin/env bash
echo "pactester $*" >> "$LOG"
echo "PROXY proxy.example.com:8080; DIRECT"
EOF
chmod +x "$T/bin/"* "$T/wbin/wget" "$T/pbin/"*
for f in sudo apt-get dnf apt-config systemctl hostname id uname; do cp "$T/bin/$f" "$T/wbin/$f"; done

export LOG="$T/calls.log" ARGV_LOG="$T/argv.log" SUDO_LOG="$T/sudo.log" BAD="$T/bad.log" ANSWERS="$T/answers" T
: > "$BAD"; : > "$ARGV_LOG"; : > "$SUDO_LOG"
D="$T/d"
I="$D/rn1-technology-catalog-installer.sh"
OUTS="$T/outputs.log"
# settle -> waits until no check of a menu start runs any more in the background
settle() {
  local i p
  for i in $(seq 1 100); do
    p="$(ps -eo args 2>/dev/null)" || return 0
    [[ "$p" == *"$I"* ]] || return 0
    sleep 0.2
  done
}
fresh() { # fresh [SED...]: the installer with its settings as shipped (CHECK_FOR_UPDATES off), no files
  settle
  rm -rf "$D"; mkdir -p "$D"
  sed 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$NEW" > "$I"
  for e in "$@"; do sed -i "$e" "$I"; done
  : > "$LOG"; rm -f "$T"/pm.log "$T"/pm.env "$T/apt.proxy" "$T/docker.env"; rm -rf "$T/etc"; mkdir -p "$T/etc"
  scen
}
# run ARGS... -> the installer in this folder with the fakes (stdin from the caller); its exit code
run() {
  local rc=0
  (cd "$D" && HOME="$T/home" RN1_ETC_DIR="$T/etc" RN1_RUN_DIR="$T/run" RN1_COMPOSE_PROVIDER="$T/cli/docker-compose" \
    PATH="${XPATH:-$T/bin}:$SYSPATH" bash "$I" "$@") > "$T/run.out" 2>&1 || rc=$?
  cat "$T/run.out" >> "$OUTS"
  cat "$T/run.out"
  return "$rc"
}
setting() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$I"; }
# the status word in front of HOST in the table of the check
status() { awk -v h="$1" 'substr($0, 1, 2) == "  " && substr($0, 17, length(h) + 1) == h " " { s = substr($0, 3, 13); sub(/ +$/, "", s); print s; exit }' <<< "$out"; }

# 1. The sites: built from the settings, the engine, the system and the domain ------------------------
fresh
out="$(run __net rows)"
check "rows: the images (Docker Hub with its token and layer host, ghcr.io with its layer host) are required" 'grep -q "^hub|registry-1.docker.io|443|req|" <<< "$out" && grep -q "^hubauth|auth.docker.io|443|req|" <<< "$out" && grep -q "^hubcdn|production.cloudfront.docker.com|443|req|" <<< "$out" && grep -q "^ghcr|ghcr.io|443|req|" <<< "$out" && grep -q "^ghcrcdn|pkg-containers.githubusercontent.com|443|req|" <<< "$out"'
check "rows: no engine chosen yet - Docker Compose required (Podman), Docker's repository only if chosen" 'grep -q "^github|github.com|443|req|Docker Compose|" <<< "$out" && grep -q "^dockerrepo|download.docker.com|443|opt|Docker Engine (if chosen)|" <<< "$out"'
check "rows: version list, installer, catalog data and license optional" 'grep -q "^hubapi|hub.docker.com|443|opt|" <<< "$out" && grep -q "^installer|raw.githubusercontent.com|443|opt|" <<< "$out" && grep -q "^cloud|rayventorycatalog.raynet.de|443|opt|" <<< "$out" && grep -q "^license|licenses.raynet.de|443|opt|" <<< "$out"'
check "rows: Nginx Proxy Manager without a domain - no Let's Encrypt, its IP ranges optional" 'grep -q "^acme|acme-v02.api.letsencrypt.org|443|-|not needed: no domain|" <<< "$out" && grep -q "^awsip|ip-ranges.amazonaws.com|443|opt|" <<< "$out"'
fresh 's/^CATALOG_DOMAIN=.*/CATALOG_DOMAIN="catalog.example.org"/'
out="$(run __net rows)"
check "rows: a domain with Nginx Proxy Manager needs Let's Encrypt" 'grep -q "^acme|acme-v02.api.letsencrypt.org|443|req|HTTPS certificate|" <<< "$out"'
fresh 's/^CATALOG_DOMAIN=.*/CATALOG_DOMAIN="catalog.local"/'
check "rows: a .local name gets no certificate" 'run __net rows | grep -q "^acme|.*|-|not needed: .local name|"'
fresh 's/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/'
out="$(run __net rows)"
check "rows: without Nginx Proxy Manager neither Let's Encrypt nor IP ranges" '[ "$(grep -c "|-|not needed: no NPM|" <<< "$out")" -eq 3 ]'
fresh 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE="podman"/'
printf '#!/usr/bin/env bash\necho "UNHANDLED podman $*" >> "$BAD"\n' > "$T/bin/podman"; chmod +x "$T/bin/podman"
mkdir -p "$T/etc/apt/sources.list.d"
printf 'deb http://deb.example.com/debian bookworm main\n' > "$T/etc/apt/sources.list"
out="$(run __net rows)"
rm -f "$T/bin/podman"
check "rows: Podman installed - no packages, no Docker repository, Compose from GitHub (none installed yet)" 'grep -q "^repo|deb.example.com|443|-|not needed: Podman is there|" <<< "$out" && grep -q "^dockerrepo|download.docker.com|443|-|not needed: Podman|" <<< "$out" && grep -q "^github|github.com|443|req|" <<< "$out"'
# the package repositories of this Linux (one row per host): apt lists and .sources, dnf and zypper .repo
fresh
mkdir -p "$T/etc/apt/sources.list.d" "$T/etc/yum.repos.d" "$T/etc/zypp/repos.d"
printf '# a comment\ndeb [signed-by=/usr/share/keyrings/x.gpg arch=amd64] http://deb.example.com/debian bookworm main\ndeb-src http://src.example.com/debian bookworm main\n' > "$T/etc/apt/sources.list"
printf 'Types: deb\nURIs: http://deb.example.com/debian\nSuites: bookworm-updates\nComponents: main\n\nTypes: deb\nURIs: http://off.example.com/debian\nSuites: bookworm\nEnabled: no\n' > "$T/etc/apt/sources.list.d/debian.sources"
printf '[base]\nname=Base\nbaseurl=https://mirror.example.com/rpm/9/BaseOS/x86_64/os/\nenabled=1\n\n[meta]\nmetalink=https://meta.example.com/metalink?repo=x&arch=$basearch\n\n[off]\nbaseurl=https://offrpm.example.com/x/\nenabled=0\n\n[rhel]\nbaseurl=https://cdn.example.com/content/dist/rhel9/$releasever/x86_64/baseos/os\nsslclientcert=/etc/pki/entitlement/1.pem\n' > "$T/etc/yum.repos.d/test.repo"
out="$(run __net rows)"
check "repositories: apt lists (no deb-src) and .sources (not the disabled one), one row per host, port 80 for http" 'grep -q "^repo1|deb.example.com|80|req|packages (sources.list)|apt:http://deb.example.com/debian/dists/bookworm/InRelease$" <<< "$out" && ! grep -q "src.example.com\|off.example.com" <<< "$out"'
check "repositories: dnf baseurl (repomd.xml), metalink with \$basearch, a certificate repository (only reachable), not the disabled one" 'grep -q "|mirror.example.com|443|req|packages (test.repo)|repomd:https://mirror.example.com/rpm/9/BaseOS/x86_64/os/repodata/repomd.xml$" <<< "$out" && grep -q "|meta.example.com|443|req|.*|meta:https://meta.example.com/metalink?repo=x&arch=$(uname -m)$" <<< "$out" && grep -q "|cdn.example.com|443|req|.*|any:https://cdn.example.com/$" <<< "$out" && ! grep -q offrpm <<< "$out"'

# 2. network-check: every site at once, the table in a fixed order, the verdict, the exit code -------------
fresh
mkdir -p "$T/etc/apt"; printf 'deb http://deb.example.com/debian bookworm main\n' > "$T/etc/apt/sources.list"
out="$(run network-check)"; rc=$?
check "network-check: all good - exit 0, every site OK, the verdict" '[ "$rc" -eq 0 ] && grep -q "Internet access - direct, no proxy" <<< "$out" && [ "$(status registry-1.docker.io)" = OK ] && [ "$(status deb.example.com)" = OK ] && grep -q "Internet access works: [0-9]* of [0-9]* sites answer" <<< "$out"'
check "network-check: the layer hosts learned from the redirects" '[ "$(status production.cloudfront.docker.com)" = OK ] && [ "$(status pkg-containers.githubusercontent.com)" = OK ] && [ "$(status release-assets.githubusercontent.com)" = OK ]'
check "network-check: no Docker Hub pull spent - the manifest only as HEAD, the pulls left shown" '! grep "registry-1.docker.io/v2/.*/manifests/" "$ARGV_LOG" | grep -qv " -I " && grep -q "Docker Hub: 87 of 100 pulls left (shared by everyone behind the same address)" <<< "$out"'
check "network-check: not needed rows say why" 'grep -q "^  -  *acme-v02.api.letsencrypt.org  *not needed: no domain" <<< "$out"'
check "network-check: the rows keep the order of the table" '[ "$(grep -oE "^  [A-Z][A-Z ]*[A-Z] +[a-z0-9.-]+" <<< "$out" | awk "NR <= 4 { printf \"%s \", \$NF }")" = "registry-1.docker.io auth.docker.io production.cloudfront.docker.com ghcr.io " ]'
check "network-check: 80 columns" '[ -z "$(awk "length(\$0) > 80" <<< "$out")" ]'
check "network-check: direct means direct (no proxy of the environment)" '! grep -qv "^direct " "$LOG"'
# slow answers: all at the same time, the order stays
scen "*|https://ghcr.io/v2/|0|401|200|0|HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer realm=\"https://ghcr.io/token\"\r\n\r\n||||2" \
  "*|https://hub.docker.com/v2/repositories/*/tags?page_size=1|0|200|200|0|$D200|{\"results\":[]}|||2" \
  "*|https://licenses.raynet.de/Account/Login.aspx|0|200|200|0|HTTP/1.1 200 OK\r\nX-Served-By: licenses.raynet.de\r\n\r\n||||2"
t0=$SECONDS; out="$(run network-check)"; rc=$?; t1=$((SECONDS - t0))
check "network-check: the sites are checked at the same time (3 answers of 2 s in less than 6 s), order kept" '[ "$rc" -eq 0 ] && [ "$t1" -lt 6 ] && [ "$(grep -oE "^  OK +[a-z0-9.-]+" <<< "$out" | awk "NR == 4 { print \$2 }")" = "ghcr.io" ]'

# 3. The status words (one optional site at a time; the required ones stay fine) ----------------------------
LIC="https://licenses.raynet.de/Account/Login.aspx"
word() { # word EXPECTED DETAIL-PATTERN ANSWER-LINE: the status of licenses.raynet.de
  scen "$3"; out="$(run network-check)"; rc=$?
  w_exp="$1"; w_det="$2"
  check "status $1: $2" '[ "$rc" -eq 0 ] && [ "$(status licenses.raynet.de)" = "$w_exp" ] && grep -q -- "$w_det" <<< "$out"'
}
word "NO DNS" "the name does not resolve - only a proxy can reach out?" "direct|$LIC|6|000|000|0||||"
word "BLOCKED" "no answer in 8 s - a firewall drops it" "direct|$LIC|28|000|000|0||||"
word "REFUSED" "connection refused (firewall, or DNS points at 192.0.2.99)" "direct|$LIC|7|000|000|0||||"
word "TLS INSPECTED" "certificate from \"O=Example, CN=Example Inspection Root CA\"" "direct|$LIC|0|200|000|19|HTTP/1.1 200 OK\r\nX-Served-By: licenses.raynet.de\r\n\r\n||$LIC|O=Example, CN=Example Inspection Root CA|"
word "CLOCK" "check the server clock (date: " "direct|$LIC|0|200|000|10|HTTP/1.1 200 OK\r\nX-Served-By: licenses.raynet.de\r\n\r\n||||"
word "TLS RESET" "TLS was cut - often a filter on the site name" "direct|$LIC|35|000|000|0||||"
word "WRONG ANSWER" "an answer came (HTTP 200), but not from licenses.raynet.de" "direct|$LIC|0|200|000|0|$D200|<html>Please log in</html>||"
word "DENIED" "the proxy or firewall refuses this site" "direct|$LIC|0|403|000|0|HTTP/1.1 403 Forbidden\r\nX-Squid-Error: ERR_ACCESS_DENIED 0\r\n\r\n|||"
check "an optional site that fails: what does not work is named, the exit code stays 0" 'grep -q "Not reachable, so these do not work here: license\." <<< "$out" && [ "$rc" -eq 0 ]'
scen "direct|https://registry-1.docker.io/v2/*/manifests/*|0|429|000|0|HTTP/1.1 429 Too Many Requests\r\n\r\n||||"
out="$(run network-check)"; rc=$?
check "status LIMIT: the pull limit of Docker Hub, a required site - exit 1" '[ "$rc" -eq 1 ] && [ "$(status production.cloudfront.docker.com)" = LIMIT ] && grep -q "Docker Hub pull limit reached" <<< "$out" && grep -q "1 required site(s) cannot be reached. A proxy is probably needed." <<< "$out"'
check "Docker Hub blocked: the way out names an internal registry mirror in one line" 'grep -q "Without Docker Hub: a proxy, the offline bundle" <<< "$out" && grep -q "internet), or an internal registry mirror." <<< "$out"'
scen "direct|https://ghcr.io/*|28|000|000|0||||"
out="$(run network-check)"; rc=$?
check "a required site blocked: exit 1, its layer row not tested" '[ "$rc" -eq 1 ] && [ "$(status ghcr.io)" = BLOCKED ] && grep -q "NOT TESTED.*pkg-containers.githubusercontent.com" <<< "$out" && grep -q "needs the login of ghcr.io first" <<< "$out"'
# no internet name resolves: one lookup, then the short cut
scen "$NODNS"
: > "$LOG"
out="$(run network-check)"; rc=$?
check "no DNS: one request only, the server reaches out only through a proxy - exit 1" '[ "$rc" -eq 1 ] && [ "$(wc -l < "$LOG")" -eq 1 ] && grep -q "This server cannot resolve internet names: it probably reaches the$" <<< "$out" && [ "$(grep -c "^  NO DNS " <<< "$out")" -gt 10 ]'
# wget where curl is missing; neither
mkdir -p "$T/nbin"; cp "$T/bin/"{sudo,id,hostname,systemctl,apt-config} "$T/nbin/"
cp "$T/nbin/"* "$T/wbin/" 2>/dev/null
scen
out="$(XPATH="$T/wbin" run network-check)"; rc=$?
check "wget only: the sites through wget, the layer hosts need curl" '[ "$rc" -eq 0 ] && [ "$(status registry-1.docker.io)" = OK ] && grep -q "NOT TESTED.*production.cloudfront.docker.com" <<< "$out" && grep -q "needs curl" <<< "$out" && grep -q "^wget " "$LOG"'
out="$(WGET_MODE=nodns XPATH="$T/wbin" run network-check)"; rc=$?
check "wget only, no DNS: the short cut too" '[ "$rc" -eq 1 ] && grep -q "This server cannot resolve internet names" <<< "$out"'
out="$(XPATH="$T/nbin" run network-check)"; rc=$?
check "neither curl nor wget: the list of the sites, exit 1" '[ "$rc" -eq 1 ] && grep -q "Neither curl nor wget is installed" <<< "$out" && grep -q "registry-1.docker.io:443  *required" <<< "$out"'

# 4. network-hosts: the list for the firewall team -------------------------------------------------------
fresh 's/^CATALOG_DOMAIN=.*/CATALOG_DOMAIN="catalog.example.org"/'
out="$(run network-hosts)"; rc=$?
check "network-hosts: host:port, required or optional, what for; Let's Encrypt and its port 80" '[ "$rc" -eq 0 ] && grep -q "^registry-1.docker.io:443  *required  *images (Docker Hub)$" <<< "$out" && grep -q "^licenses.raynet.de:443  *optional  *license$" <<< "$out" && grep -q "^packages.packagestore.com:443  *optional" <<< "$out" && grep -q "acme-v02.api.letsencrypt.org:443  *required" <<< "$out" && grep -q "inbound TCP port 80" <<< "$out" && [ ! -s "$LOG" ] && [ -z "$(awk "length(\$0) > 80" <<< "$out")" ]'

# 5. The settings: checked, the Internet group, the proxy of the shell stays -----------------------------
fresh
cs() { cp "$I" "$T/cs.sh"; sed -i "s|^$1=.*|$1=\"$2\"|" "$T/cs.sh"; (cd "$T" && PATH="$T/bin:$SYSPATH" bash cs.sh check-settings 2>&1); }
out="$(cs INTERNET_PROXY "http://u:pw@proxy.example.com:8080")"
check "settings: a login in INTERNET_PROXY refused (the script is no place for it)" 'grep -q "No login in the address: option 26 keeps it in .proxy_login" <<< "$out"'
check "settings: INTERNET_PROXY without scheme, without port, with a path refused" 'cs INTERNET_PROXY proxy.example.com:8080 | grep -q "Give scheme://host:port" && cs INTERNET_PROXY http://proxy.example.com | grep -q "Give the port too" && cs INTERNET_PROXY http://proxy.example.com:8080/x | grep -q "Give scheme://host:port"'
check "settings: INTERNET_PROXY http, https, socks5h and [IPv6] taken" 'for v in http://proxy.example.com:8080 https://proxy.example.com:443 socks5h://proxy.example.com:1080 "http://[2001:db8::1]:3128"; do cs INTERNET_PROXY "$v" >/dev/null || exit 1; done'
check "settings: INTERNET_NO_PROXY without spaces or *" 'cs INTERNET_NO_PROXY "a.example.com, b.example.com" | grep -q "no spaces and no \*" && cs INTERNET_NO_PROXY "*" | grep -q "no spaces" && cs INTERNET_NO_PROXY "corp.example.com,.example.org,192.0.2.0/24" >/dev/null'
echo "no certificate" > "$T/plain.txt"
check "settings: a missing or non-PEM certificate file, a relative PAC path refused" 'cs INTERNET_PROXY_CA_FILE /no/such.pem | grep -q "readable certificate file in PEM" && cs INTERNET_PROXY_CA_FILE "$T/plain.txt" | grep -q "PEM" && cs INTERNET_PROXY_PAC proxy.pac | grep -q "address of the PAC file"'
out="$(printf '1\n0\n0\n' | COLUMNS=120 RN1_NET_CHECK=off run menu)"
check "settings screen: the group Internet access" 'grep -q "Internet access  INTERNET_\*" <<< "$out"'
out="$(HTTP_PROXY=http://shell.example.com:3128 run __net env)"
check "settings: an empty INTERNET_PROXY leaves the proxy of the shell as it is" '[ "$out" = "|http://shell.example.com:3128|||login=none" ]'

# 6. The proxy of this run: exported with the login, NO_PROXY with this server and the internal names -----
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|' 's|^INTERNET_NO_PROXY=.*|INTERNET_NO_PROXY="corp.example.com"|'
(umask 077; printf '%s\n' "$FAKE_LOGIN" > "$D/.proxy_login")
out="$(run __net env)"
check "this run: http(s)_proxy with the saved login, upper case too" '[[ "$out" == "http://$USR_ENC:***@proxy.example.com:8080|http://$USR_ENC:***@proxy.example.com:8080|"* ]] && [[ "$out" == *"|yes|login=saved" ]]'
check "this run: NO_PROXY - this server, the internal names as name and .name, the private ranges" '[[ "$out" == *"|localhost,127.0.0.1,::1,"*",corp.example.com,.corp.example.com,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16|"* ]]'
out="$(RN1_PROXY_SET=yes https_proxy=http://old.example.com:1 run __net found)"
check "a proxy exported by an earlier run is not taken for the shell's" '! grep -q "your shell" <<< "$out"'

# 7. The package managers as root: the proxy only for this run, nothing in /etc, no password anywhere -----
: > "$SUDO_LOG"
echo "http://old.example.com:3128" > "$T/apt.proxy"
mkdir -p "$T/etc/dnf"; printf '[main]\ngpgcheck=1\nproxy=http://old.example.com:3128\nproxy_username=olduser\nproxy_password=oldpw\n' > "$T/etc/dnf/dnf.conf"
cs1="$(cksum < "$T/etc/dnf/dnf.conf")"
out="$(run __net run-plan "apt-get update" "DEBIAN_FRONTEND=noninteractive apt-get install -y podman" "dnf install -y podman")"; rc=$?
check "run-plan: the steps shown as they are" '[ "$rc" -eq 0 ] && grep -q "Step 1 of 3: apt-get update$" <<< "$out" && grep -q "Step 3 of 3: dnf install -y podman$" <<< "$out"'
check "run-plan: each step reads the proxy of the run first (sudo drops the environment)" '[ "$(grep -c "^sudo sh -c \. $T/run/rn1-proxy\.[0-9]*\.env; " "$SUDO_LOG")" -eq 3 ] && [ "$(grep -c "proxy=http://proxy.example.com:8080 login=ok no_proxy=set" "$T/pm.env")" -eq 3 ]'
check "run-plan: apt-get and dnf get a copy of their configuration with this proxy (theirs would win)" 'grep -q "^apt-get -c $T/run/rn1-apt\.[0-9]*\.conf update$" "$T/pm.log" && grep -q "^dnf --config=$T/run/rn1-dnf\.[0-9]*\.conf install -y podman$" "$T/pm.log" && grep -q "apt-get conf Acquire::https::Proxy \"http://\*\*\*@proxy.example.com:8080\";" "$T/pm.env" && ! grep -q "^dnf conf proxy" "$T/pm.env" && grep -q "^dnf conf gpgcheck=1" "$T/pm.env"'
check "run-plan: the files of the run are readable only by root and gone afterwards; /etc unchanged" '! grep "file rn1-" "$T/pm.env" | grep -qv " 600$" && [ -z "$(ls -A "$T/run")" ] && [ "$(cksum < "$T/etc/dnf/dnf.conf")" = "$cs1" ]'
rm -f "$T/apt.proxy" "$T/etc/dnf/dnf.conf"; : > "$T/pm.log"; : > "$T/pm.env"
out="$(run __net run-plan 'kill -TERM $PPID; kill -TERM $$' "touch $T/step2")"; rc=$?
check "run-plan: Ctrl+C (TERM) during a step - the next steps do not run, the files of the run are gone" '[ "$rc" -eq 130 ] && [ ! -e "$T/step2" ] && [ -z "$(ls -A "$T/run")" ]'
out="$(SHIM_UID=0 run __net run-plan "apt-get update")"
check "run-plan as root: no sudo, the proxy inherited, no file of the run" '[ "$(grep -c . "$T/pm.env")" -eq 1 ] && grep -q "proxy=http://proxy.example.com:8080 login=ok" "$T/pm.env" && grep -q "^apt-get update$" "$T/pm.log"'
: > "$SUDO_LOG"
out="$(run __net sudo curl -fsSL -o "$T/dl" https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64)"
check "a download as root (Docker Compose): through the proxy of the run" 'grep -q "^proxy proxy.example.com:8080 ok https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64$" "$LOG" && grep -q "^sudo sh -c " "$SUDO_LOG" && [ -z "$(ls -A "$T/run")" ]'
fresh
: > "$SUDO_LOG"
out="$(run __net run-plan "apt-get update")"
check "run-plan without a proxy: the step exactly as before, no file" '[ "$(cat "$SUDO_LOG")" = "sudo sh -c apt-get update" ] && [ -z "$(ls -A "$T/run")" ]'

# 8. Proxies set on the server: found, masked, the default answer -----------------------------------------
fresh
mkdir -p "$T/etc/profile.d" "$T/etc/rhsm" "$T/etc/sysconfig" "$T/etc/docker" "$T/etc/containers" "$T/home/.docker"
printf 'PATH="/usr/bin"\nhttps_proxy="http://envuser:envsecret@proxy2.example.com:3128"\n' > "$T/etc/environment"
printf 'export http_proxy=http://proxy3.example.com:8080\n' > "$T/etc/profile.d/proxy.sh"
printf '[server]\nproxy_hostname = rhsm.example.com\nproxy_port = 3128\n' > "$T/etc/rhsm/rhsm.conf"
printf 'PROXY_ENABLED="yes"\nHTTPS_PROXY="http://suse.example.com:3128"\n' > "$T/etc/sysconfig/proxy"
printf '{ "proxies": { "https-proxy": "http://daemon.example.com:3128" } }\n' > "$T/etc/docker/daemon.json"
printf '[engine]\nenv = ["https_proxy=http://podmanconf.example.com:3128"]\n' > "$T/etc/containers/containers.conf"
printf '{ "proxies": { "default": { "httpsProxy": "http://client.example.com:3128" } } }\n' > "$T/home/.docker/config.json"
echo "http://apt.example.com:3128" > "$T/apt.proxy"; touch "$T/docker.env"
scen "$NODNS"
out="$(printf '0\n' | run __net ask)"
check "found: every place, the password masked" 'grep -q "environment  *http://envuser:\*\*\*@proxy2.example.com:3128" <<< "$out" && grep -q "profile.d/proxy.sh  *http://proxy3.example.com:8080" <<< "$out" && grep -q "rhsm/rhsm.conf  *http://rhsm.example.com:3128" <<< "$out" && grep -q "apt (Acquire::Proxy)  *http://apt.example.com:3128" <<< "$out" && grep -q "sysconfig/proxy  *http://suse.example.com:3128" <<< "$out" && grep -q "docker.service  *http://dockerproxy.example.com:3128" <<< "$out" && grep -q "docker/daemon.json  *http://daemon.example.com:3128" <<< "$out" && grep -q "containers/containers.conf  *http://podmanconf.example.com:3128" <<< "$out" && grep -q "~/.docker/config.json  *http://client.example.com:3128" <<< "$out" && ! grep -q envsecret <<< "$out"'
check "found: the two places that act on more than the installer are named" 'grep -q "hands its proxy to every container Compose starts" <<< "$out" && grep -q "The proxies of docker/daemon.json win" <<< "$out"'
check "found: the list and its warnings fit 80 columns" '[ -z "$(awk "length(\$0) > 80" <<< "$out")" ]'
check "found: the first one is the default answer" 'grep -qx "  Enter takes 1 with http://envuser:\*\*\*@proxy2.example.com:3128" <<< "$out" && grep -qx "  (found in environment)." <<< "$out"'
scen "proxy shellproxy.example.com:3128 *|*|7|000|000|0||||" "$NODNS"
out="$(printf '0\n' | https_proxy=http://shellproxy.example.com:3128 run __net ask)"
check "the proxy of the shell: the check goes through it, it is named first" 'grep -q "Internet access - through the proxy of your shell (https_proxy)" <<< "$out" && grep -q "your shell (https_proxy)  *http://shellproxy.example.com:3128" <<< "$out"'
rm -rf "$T/home/.docker"

# 9. The questions: address, port, Basic login, the check through it, the internal names, saved ---------------
fresh
printf 'search corp.example.com\nnameserver 192.0.2.53\n' > "$T/etc/resolv.conf"
scen "${LOGIN_PROXY[@]}" "$NODNS"
out="$(printf '1\nproxy.example.com\n8080\n%s\n%s\n\ny\n' "$USR" "$PW" | run __net ask)"; rc=$?
check "questions: no DNS - the kinds of internet access are asked" 'grep -q "How does this server reach the internet?" <<< "$out" && grep -q "4  Directly - the firewall will allow the sites" <<< "$out" && grep -q "5  Not at all - offline installation" <<< "$out"'
check "questions: no port - asked, never guessed (the answer saved)" 'grep -q "Internet access - through http://proxy.example.com:8080," <<< "$out"'
check "questions: the proxy asks for a login - user name, then the password (hidden), tried at once" 'grep -q "The proxy asks for a login" <<< "$out" && grep -q "The proxy takes this login" <<< "$out"'
check "questions: every site through the proxy with the login, the internal names directly" 'grep -q "Internet access - through http://proxy.example.com:8080, login DOM.user" <<< "$out" && grep -q "Internet access works" <<< "$out" && grep -q "^proxy proxy.example.com:8080 ok https://ghcr.io/v2/$" "$LOG"'
check "questions: internal names - Enter takes the domain of this server and of the search line" '[ "$(setting INTERNET_NO_PROXY)" = corp.example.com ]'
check "questions: saved - the proxy in the settings, the login percent-encoded in .proxy_login (mode 600)" '[ "$rc" -eq 0 ] && [ "$(setting INTERNET_PROXY)" = "http://proxy.example.com:8080" ] && [ "$(cat "$D/.proxy_login")" = "$(printf "proxy=http://proxy.example.com:8080\n%s" "$FAKE_LOGIN")" ] && [ "$(stat -c %a "$D/.proxy_login")" = 600 ] && grep -q "Saved: the installer uses this proxy from now on." <<< "$out"'
check "questions: the summary before saving names the user, not the password" 'grep -q "Internet proxy http://proxy.example.com:8080$" <<< "$out" && grep -q "login  *DOM.user (password saved, mode 600)" <<< "$out" && ! grep -qF "$PW" <<< "$out" && ! grep -qF "$PW_ENC" <<< "$out"'
check "questions: the check after saving is in the cache (signature of the new settings)" '[ -f "$D/.jobs/internet-check" ] && [ "$(run __net header)" = "Internet ok" ]'
# wrong password three times
fresh
scen "${LOGIN_PROXY[@]}" "$NODNS"
out="$(printf '1\nproxy.example.com:8080\n%s\nnope1\n%s\nnope2\n%s\nnope3\n0\n' "$USR" "$USR" "$USR" | run __net ask)"
check "login: a wrong password - asked again, stopped after 3, nothing saved" '[ "$(grep -c "Wrong user name or password" <<< "$out")" -eq 3 ] && grep -q "Stopped after 3 failed logins." <<< "$out" && [ -z "$(setting INTERNET_PROXY)" ] && [ ! -e "$D/.proxy_login" ]'
# a login typed into the address
fresh
scen "${LOGIN_PROXY[@]}" "$NODNS"
out="$(printf '1\nhttp://%s:%s@proxy.example.com:8080\n\ny\n' "$USR_ENC" "$PW_ENC" | run __net ask)"
check "login in the address: moved to .proxy_login, the address saved without it" 'grep -q "The login goes into .proxy_login (mode 600), not into the address." <<< "$out" && [ "$(setting INTERNET_PROXY)" = "http://proxy.example.com:8080" ] && [ "$(tail -n 1 "$D/.proxy_login")" = "$FAKE_LOGIN" ]'
# NTLM and Kerberos only, Digest only: explained, a relay taken as a normal proxy
fresh
scen "proxy ntlm.example.com:8080 *|*|56|000|407|0|HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: NTLM\r\nProxy-Authenticate: Negotiate\r\n\r\n||||" \
  "proxy digest.example.com:8080 *|*|56|000|407|0|HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Digest realm=\"x\", nonce=\"y\"\r\n\r\n||||" "$NODNS"
out="$(printf '1\nntlm.example.com:8080\ndigest.example.com:8080\n127.0.0.1:3128\n-\ny\n' | run __net ask)"
check "NTLM/Negotiate: no password asked, the two ways out (network team, local relay cntlm or px)" 'grep -q "This proxy accepts only Windows domain logins (NTLM or Kerberos)" <<< "$out" && grep -q "Ask the network team to let this server through without a login" <<< "$out" && grep -q "cntlm (package \"cntlm\")" <<< "$out" && grep -q "pip install px-proxy" <<< "$out" && ! grep -q "Password (hidden)" <<< "$out"'
check "Digest only: treated like NTLM" 'grep -q "This proxy accepts only Digest logins" <<< "$out"'
check "the questions fit 80 columns (the NTLM and Digest explanations, the relay note)" '[ -z "$(awk "length(\$0) > 80" <<< "$out")" ]'
check "a relay on this server: taken as a normal proxy, what the containers need is said" 'grep -q "A relay on this server: the containers reach it as host.docker.internal" <<< "$out" && [ "$(setting INTERNET_PROXY)" = "http://127.0.0.1:3128" ] && [ -z "$(setting INTERNET_NO_PROXY)" ]'
# SOCKS, a name that does not resolve, a port nobody listens on
fresh
scen "proxy bad.example.com:8080 *|*|5|000|000|0||||" "proxy proxy.example.com:9999 *|*|7|000|000|0||||" "$NODNS"
out="$(printf '1\nbad.example.com:8080\nproxy.example.com:9999\nsocks5h://proxy.example.com:1080\n\ny\n' | run __net ask)"
check "proxy: a name that does not resolve and a port nobody listens on are said, asked again" 'grep -q "The name of the proxy does not resolve: bad.example.com" <<< "$out" && grep -q "Nothing listens at proxy.example.com:9999 (wrong port?)." <<< "$out"'
check "proxy: SOCKS taken with the warning" 'grep -q "A SOCKS proxy: Let.s Encrypt in Nginx Proxy Manager and wget cannot use it;" <<< "$out" && [ "$(setting INTERNET_PROXY)" = "socks5h://proxy.example.com:1080" ]'
# directly, offline, back
fresh
scen "$NODNS"
out="$(printf '4\n' | run __net ask)"; rc=$?
check "directly: the sites for the network team" '[ "$rc" -eq 4 ] && grep -q "For the network team - the sites to allow from this server:" <<< "$out" && grep -q "ghcr.io:443  *required" <<< "$out"'
out="$(printf '5\n' | run __net ask)"; rc=$?
check "offline: the offline bundle of option 8" '[ "$rc" -eq 3 ] && grep -q "option 8 (Download only)" <<< "$out"'

# 10. PAC: one fixed proxy, the candidates tried, the sites only DIRECT reaches go to the internal names --------
fresh
printf 'search corp.example.com\n' > "$T/etc/resolv.conf"
printf 'function FindProxyForURL(url, host) {\n  if (dnsDomainIs(host, ".corp.example.com")) return "DIRECT";\n  return "PROXY p1.example.com:3128; PROXY proxy.example.com:8080; DIRECT";\n}\n' > "$T/proxy.pac"
out="$(run __net pac "$T/proxy.pac")"
check "PAC: the candidates in their order, DIRECT" '[ "$(echo $out)" = "DIRECT http://p1.example.com:3128 http://proxy.example.com:8080 DIRECT" ]'
scen "proxy p1.example.com:3128 *|*|7|000|000|0||||" \
  "proxy proxy.example.com:8080 *|https://ghcr.io/*|56|000|403|0|HTTP/1.1 403 Forbidden\r\n\r\n||||" \
  "proxy proxy.example.com:8080 *|https://pkg-containers.githubusercontent.com/*|56|000|403|0|HTTP/1.1 403 Forbidden\r\n\r\n||||" \
  "direct|https://registry-1.docker.io/*|28|000|000|0||||" "direct|https://auth.docker.io/*|28|000|000|0||||" \
  "direct|https://github.com/*|28|000|000|0||||"
out="$(printf '2\n%s\n\ny\n' "$T/proxy.pac" | run __net ask)"; rc=$?
check "PAC: the first candidate that (with DIRECT) reaches every required site is taken" '[ "$rc" -eq 0 ] && grep -q "proxy.example.com:8080 reaches all [0-9]* required sites - it will be used." <<< "$out" && [ "$(setting INTERNET_PROXY)" = "http://proxy.example.com:8080" ] && [ "$(setting INTERNET_PROXY_PAC)" = "$T/proxy.pac" ]'
check "PAC: the sites only DIRECT reaches go to the internal names, the check honours them" 'grep -q "Only reached directly, so they go to the internal names: ghcr.io,pkg-containers.githubusercontent.com" <<< "$out" && [ "$(setting INTERNET_NO_PROXY)" = "corp.example.com,ghcr.io,pkg-containers.githubusercontent.com" ] && grep -q "Internet access works" <<< "$out"'
check "PAC: its failover is lost - said" 'grep -q "its failover between proxies is lost" <<< "$out"'
fresh
scen "proxy p1.example.com:3128 *|*|7|000|000|0||||" "proxy proxy.example.com:8080 *|https://ghcr.io/*|56|000|403|0|HTTP/1.1 403 Forbidden\r\n\r\n||||" "$NODNS"
out="$(printf '2\n%s\n0\n' "$T/proxy.pac" | run __net ask)"
check "PAC: no single proxy reaches every required site - said clearly, nothing saved" 'grep -q "No single proxy of the PAC file reaches all [0-9]* required sites.$" <<< "$out" && grep -q "The best one, proxy.example.com:8080, reaches" <<< "$out" && [ -z "$(setting INTERNET_PROXY)" ]'
printf 'var x = 1;\n' > "$T/nopac.js"
out="$(printf '2\n%s\n0\n' "$T/nopac.js" | run __net ask)"
check "PAC: a file without FindProxyForURL is refused" 'grep -q "No PAC file at $T/nopac.js (it must contain FindProxyForURL)." <<< "$out"'
# a PAC address (fetched directly), evaluated by pactester when it is installed
fresh
scen "direct|http://pac.example.com/proxy.pac|0|200|000|0|$D200|$(tr '\n' ' ' < "$T/proxy.pac")|||" "$NODNS"
out="$(printf '2\nhttp://pac.example.com/proxy.pac\n\ny\n' | XPATH="$T/pbin:$T/bin" run __net ask)"
check "PAC: fetched from its address, pactester asked for every required site" 'grep -q "^pactester -p .* -u https://registry-1.docker.io/$" "$LOG" && grep -q "The PAC file names: proxy.example.com:8080, DIRECT." <<< "$out" && [ "$(setting INTERNET_PROXY)" = "http://proxy.example.com:8080" ] && [ "$(setting INTERNET_PROXY_PAC)" = "http://pac.example.com/proxy.pac" ]'
# WPAD: only when chosen, the domains walked up but never below two labels, the address confirmed
fresh
printf 'search a.corp.example.com\n' > "$T/etc/resolv.conf"
out="$(SHIM_DOMAIN=lab.example.net run __net wpad)"
check "WPAD: the search domains and the domain of the server, walked up to two labels" '[ "$(echo $out)" = "http://wpad.a.corp.example.com/wpad.dat http://wpad.corp.example.com/wpad.dat http://wpad.example.com/wpad.dat http://wpad.lab.example.net/wpad.dat http://wpad.example.net/wpad.dat" ]'
scen "direct|http://wpad.a.corp.example.com/wpad.dat|6|000|000|0||||" "direct|http://wpad.corp.example.com/wpad.dat|0|200|000|0|$D200|$(tr '\n' ' ' < "$T/proxy.pac")|||" "$NODNS"
out="$(printf '3\ny\n\ny\n' | run __net ask)"
check "WPAD: the PAC file found is shown and used after a yes" 'grep -q "Found: http://wpad.corp.example.com/wpad.dat" <<< "$out" && [ "$(setting INTERNET_PROXY_PAC)" = "http://wpad.corp.example.com/wpad.dat" ] && ! grep -q "wpad.example.com/" "$LOG"'
cp "$T/answers" "$T/answers.wpad"
fresh
cp "$T/answers.wpad" "$T/answers"
printf 'search a.corp.example.com\n' > "$T/etc/resolv.conf"
out="$(printf '3\nn\n0\n' | run __net ask)"
check "WPAD: a no keeps it unused" 'grep -q "Found: http://wpad.corp.example.com/wpad.dat" <<< "$out" && [ -z "$(setting INTERNET_PROXY_PAC)" ] && [ -z "$(setting INTERNET_PROXY)" ]'

# 11. TLS inspection: the company's root certificate, its fingerprint, kept after a yes -----------------------
cat > "$T/ca.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
MIIDUTCCAjmgAwIBAgIUNgU3G2lpIQm8Vs5AQFeKx/TK6gowDQYJKoZIhvcNAQEL
BQAwNzEQMA4GA1UECgwHRXhhbXBsZTEjMCEGA1UEAwwaRXhhbXBsZSBJbnNwZWN0
aW9uIFJvb3QgQ0EwIBcNMjYxMDExMTUyNjQwWhgPMjEyNjA5MTcxNTI2NDBaMDcx
EDAOBgNVBAoMB0V4YW1wbGUxIzAhBgNVBAMMGkV4YW1wbGUgSW5zcGVjdGlvbiBS
b290IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA0vN9qAjPhBQk
OUd1NLD6EMpZhyyl2avvf7KMRzKVuT2AaVnj9aMc0OeWa5m8+rdFsngzB/iboyX4
7IXjv7jt/vo/qXAJ5TA1mP6nTd31VqlYwjUiYXF1z52DjFuBe9YduqO+EWKqJvdn
s6ip73ctCXtGXBCvcf6YucCo7Qlkr0JXdiWiyBzNKiwp5+70HzaI+Sa2R5lN+lmc
3v4Ickc6M05+AsHRKYNNu8yfoRr7S25Y+U1AicswIUnUgsWTWCmE2HRQLyBj1lPN
Tcr6e02WORMXZVi9DWaVgLBFFW8NTmzgr27AyU7M+ibqi4uJCCwcCqh82BbjsQRA
sBXkOA2diwIDAQABo1MwUTAdBgNVHQ4EFgQUUQeEKagX///KYJIBxtHYLCzCZ1Ew
HwYDVR0jBBgwFoAUUQeEKagX///KYJIBxtHYLCzCZ1EwDwYDVR0TAQH/BAUwAwEB
/zANBgkqhkiG9w0BAQsFAAOCAQEADdgimVtwCS6tVy5vZC3mcPNg7HAOxqxpt+N0
gR/ZvxMxUYNQdQ4Vra9EgwdcPFikXzm57FXisK1Q2kSkEMHjhOXgyGrBgDrVgQEY
EMu3D1m4aL0BcAulew4xtu919oxqMPn+ZzTCoVs3z6VjsnhlM7eQ36xOhydnZmnL
5Fb6D1KGgL94GT4JUAf9z51w/UzQx62Q/R1g90vZ+XY6ppGv6wLVc35RRIKoD4UE
Id96nP2txKaS8I/pHZOqTUK4m9zi1D7vArhFcITLSqBFF38+tKIruWWniMhnF4dC
ttcWpZ+qw9jivytj4JE69LpLqYu+0+nVwQgDgf82CuSpl3Qq+A==
-----END CERTIFICATE-----
EOF
cat > "$T/leaf.pem" <<'EOF'
-----BEGIN CERTIFICATE-----
MIIDMzCCAhugAwIBAgIUItq7Qy4YCv8RLn1lTrDIb9UHnIIwDQYJKoZIhvcNAQEL
BQAwNzEQMA4GA1UECgwHRXhhbXBsZTEjMCEGA1UEAwwaRXhhbXBsZSBJbnNwZWN0
aW9uIFJvb3QgQ0EwIBcNMjYxMDExMTUyNjQwWhgPMjEyNjA5MTcxNTI2NDBaMB8x
HTAbBgNVBAMMFHJlZ2lzdHJ5LTEuZG9ja2VyLmlvMIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAo8zZLGAuQz+zJLVmUiGglYKRXsADfYJtGw1POCwQg+nW
YQb6OftYme5KAmMAkyck8c2tAPQFccjqVQn+XKsWVke6Q3lxMt2I9gjXd3d5/oR1
X97+Evap2eS8yKLmBtswXOtZjRHPOadiUiOSGZ4eFCynfPwGkprqLxoYP55rRhwe
jTW5XaAM//jSxkjTiXiDs+eS6TiNKtnV8o6XJXKT162ydS3/NLzC7hVVp68izvfV
dro89E46ZFbJCTZJm6o6XtWi7Tj4ZPRBQ1HWTopl6TqvSAlP4m1Zff3tyFFRD/aC
HTPTtCouiPBdqwUa4x94XMaG2M+2/Ssujk8bKiQ/CwIDAQABo00wSzAJBgNVHRME
AjAAMB0GA1UdDgQWBBR7l/DszXiI18usI1OzDXjhCmIE0jAfBgNVHSMEGDAWgBRR
B4QpqBf//8pgkgHG0dgsLMJnUTANBgkqhkiG9w0BAQsFAAOCAQEApdb8wnyRW/Ao
osON+uEXiUUzDSFV3nC6fk7j+nCsj1naAxY3P3g2PdrP7Z+e0w4P/xUEO1ii7cyO
mTgTckqdnK5Da/9o4ijV6DkHgVeH++ts6NDQbh2TZT0GDwRJMG4oW0s9yq4SO1n0
pZ3OSipCSHzw8MMXv+5T+EySJyPmxBWLwaOzdTVDFX1MKJAVFOCr4ILlY1aKOnLJ
m2RjytLc2OTNgNk+GrBOU2LAj25Fxj5/Sug2kFVQORwn+BBCVelnRO3swrfKhkqD
aUnhBkGun4Pv/tLlKba4fY6yvgpgFsCoEVTbao35T0REEN/N3vIeon3AfIdTFbJC
IbxGllII9A==
-----END CERTIFICATE-----
EOF
FP="$(sed '/-----/d' "$T/ca.pem" | base64 -d | sha256sum | cut -c1-64 | tr 'a-f' 'A-F' | sed 's/../&:/g; s/:$//')"
printf -- '-----BEGIN PRIVATE KEY-----\nnot a real key\n-----END PRIVATE KEY-----\n' > "$T/key.pem"
cat "$T/ca.pem" "$T/leaf.pem" > "$T/bundle.pem"
fresh
INSP="O=Example, CN=Example Inspection Root CA"
scen "direct|https://registry-1.docker.io/v2/|0|401|000|19|HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer realm=\"https://auth.docker.io/token\"\r\n\r\n|||$INSP|" \
  "direct|https://ghcr.io/v2/|0|401|000|20|HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer realm=\"https://ghcr.io/token\"\r\n\r\n|||$INSP|"
out="$(printf '%s\n%s\n%s\nn\n%s\ny\n' "$T/key.pem" /no/such.crt "$T/bundle.pem" "$T/ca.pem" | run __net ask)"
check "TLS inspection only: the certificate is asked first (not the proxy), with the issuer" 'grep -q "Your network inspects HTTPS: the certificates come from" <<< "$out" && grep -q "\"$INSP\"\." <<< "$out" && ! grep -q "How does this server reach the internet?" <<< "$out"'
check "certificate: a private key and a missing file refused" 'grep -q "holds a private key - only the certificate is needed" <<< "$out" && grep -q "No readable file: /no/such.crt" <<< "$out"'
check "certificate: a bundle shows each certificate" 'grep -q "Certificate 2:" <<< "$out"'
check "certificate: its SHA-256 fingerprint shown, compared with IT, kept after a yes (mode 644)" 'grep -q "SHA-256      ${FP:0:47}" <<< "$out" && grep -q "Compare the fingerprint with your IT department." <<< "$out" && cmp -s "$T/ca.pem" "$D/proxy-ca.pem" && [ "$(stat -c %a "$D/proxy-ca.pem")" = 644 ] && [ "$(setting INTERNET_PROXY_CA_FILE)" = "$D/proxy-ca.pem" ]'
if command -v openssl >/dev/null 2>&1; then
  check "certificate (openssl): the name, a CA:FALSE certificate warned" 'grep -q "Certificate 1: .*Example Inspection Root CA" <<< "$out" && grep -q "This is no CA certificate (CA:FALSE)" <<< "$out"'
  openssl x509 -in "$T/ca.pem" -outform der -out "$T/ca.der"
  fresh
  out="$(printf '%s\ny\n' "$T/ca.der" | run __net ca "$INSP")"
  check "certificate (openssl): DER is taken and kept as PEM" 'cmp -s "$T/ca.pem" "$D/proxy-ca.pem"'
else
  echo "SKIP: openssl missing - no test of DER and of the certificate names"
fi

# 12. The menu: option 26 in SETUP, the check at every menu start in the background, its header line --------
fresh
out="$(run __menu_items)"
check "menu: option 26 Internet access in SETUP" 'grep -qx "1|26|run|Internet access|sites, proxy, certificate|Checks the sites; sets proxy and certificate" <<< "$out"'
SLOW="*|https://registry-1.docker.io/v2/|0|401|200|0|HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer realm=\"https://auth.docker.io/token\"\r\n\r\n||||"
scen "${SLOW}4"
t0=$SECONDS; out="$(printf '0\n' | run menu)"; t1=$((SECONDS - t0))
check "menu start: not slowed by the check (a site that answers after 4 s), nothing shown yet" '[ "$t1" -lt 4 ] && grep -q "I install - U update" <<< "$out" && ! grep -q "^Internet" <<< "$out"'
settle
check "menu quit: its check stops too - no cache, no temporary folder, no curl left" '[ ! -f "$D/.jobs/internet-check" ] && ! ps -eo args 2>/dev/null | grep -v grep | grep -q "$T/bin/curl"'
scen "${SLOW}2"
out="$( { sleep 6; printf '0\n'; } | run menu)"
check "menu start: the check ends in the background, its result cached with a time stamp" '[ -f "$D/.jobs/internet-check" ] && [[ "$(head -n 1 "$D/.jobs/internet-check")" =~ ^[0-9]+\|[0-9]+\| ]]'
settle
: > "$LOG"
out="$(printf '0\n' | run menu)"
check "menu start again: the fresh cache is used (no request), the header line shown" '[ ! -s "$LOG" ] && grep -q "^Internet ok$" <<< "$out"'
sed -i "1s/^[0-9]*/$(( $(date +%s) - 3600 ))/" "$D/.jobs/internet-check"
scen "direct|https://ghcr.io/*|28|000|000|0||||"
out="$(printf '0\n' | run menu)"
for i in $(seq 1 80); do grep -q "^ghcr|BLOCKED" "$D/.jobs/internet-check" 2>/dev/null && break; sleep 0.25; done
settle
out="$(printf '16\n\n0\n' | run menu)"
check "an old cache is checked again; blocked required sites in the header, 26 shows them" 'grep -q "^Internet: 1 required site blocked - 26 shows them$" <<< "$out"'
check "option 16: the internet line" 'grep -q "Internet: 1 required site(s) cannot be reached - menu option 26 shows them." <<< "$out"'
out="$(RN1_NET_CHECK=off run check)"
check "RN1_NET_CHECK=off: no internet line in the check" '! grep -q "Internet:" <<< "$out"'
fresh
out="$(run check)"
check "check (option 16) without a cache: checks now, one line" 'grep -q "Checking the internet access" <<< "$out" && grep -q "Internet: all [0-9]* sites the installation needs answer." <<< "$out"'
# option 26: the settings, the check, what to change; remove
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
(umask 077; printf '%s\n' "$FAKE_LOGIN" > "$D/.proxy_login")
scen "${LOGIN_PROXY[@]}" "$NODNS"
out="$(printf '26\n4\n\n26\n2\ny\n\n0\n' | run menu)"
check "option 26: the proxy and its login shown, the check through it, the list for the network team" 'grep -q "Proxy  *http://proxy.example.com:8080, login DOM.user (password saved)" <<< "$out" && grep -q "Internet access - through http://proxy.example.com:8080, login DOM.user" <<< "$out" && grep -q "^registry-1.docker.io:443  *required" <<< "$out"'
check "option 26: the proxy removed with its login" 'grep -q "The proxy is removed: the installer goes out directly." <<< "$out" && [ -z "$(setting INTERNET_PROXY)" ] && [ ! -e "$D/.proxy_login" ]'
# the full screen: the header line appears when the background check is done
if command -v script >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  fresh
  touch "$D/.setup-later"
  scen "${SLOW}2"
  log="$T/tty.log"; : > "$log"
  { for i in $(seq 1 60); do grep -q "Select:" "$log" 2>/dev/null && break; sleep 0.5; done
    for i in $(seq 1 40); do grep -aqE "Internet (✔|ok)" "$log" 2>/dev/null && break; sleep 0.5; done
    sleep 1; printf q; sleep 1
  } | (cd "$D" && HOME="$T/home" RN1_ETC_DIR="$T/etc" RN1_RUN_DIR="$T/run" RN1_COMPOSE_PROVIDER="$T/cli/docker-compose" PATH="$T/bin:$SYSPATH" \
      TERM=xterm LC_ALL=C.UTF-8 LANG=C.UTF-8 timeout 60 script -qfec "stty sane; stty cols 120 rows 40; bash $I menu" /dev/null > "$log" 2>&1)
  first_prompt="$(grep -abo "Type a number" "$log" | awk -F: 'NR == 1 { print $1 }')"
  first_net="$(grep -aboE "Internet (✔|ok)" "$log" | awk -F: 'NR == 1 { print $1 }')"
  check "full screen: no internet header at first, drawn again with it when the check is done" '[ -n "$first_prompt" ] && [ -n "$first_net" ] && [ "$first_prompt" -lt "$first_net" ] || { tail -c 3000 "$log" | sed "s/\x1b[[(][0-9;?]*[A-Za-z]//g" | tr -d "\r" | tail -n 20 | sed "s/^/  | /"; false; }'
else
  echo "SKIP: script (util-linux) missing - no test of the full screen"
fi

# 13. The new installation: Internet is its first step ---------------------------------------------------
fresh
out="$(printf 'i\n0\n0\n' | LC_ALL=C run menu)"
check "new installation: step 1 of 9 is Internet, the check, then the engine (step 2)" 'grep -q "Install . step 1 of 9" <<< "$out" && grep -q "Internet access works" <<< "$out" && grep -q "Install . step 2 of 9" <<< "$out"'
fresh
scen "$NODNS"
out="$(printf 'i\n0\n0\n' | LC_ALL=C run menu)"
check "new installation without internet: the questions; 0 at the first one stops (the next start opens the menu)" 'grep -q "How does this server reach the internet?" <<< "$out" && grep -q "Stopped. I starts it again" <<< "$out" && [ -f "$D/.setup-later" ] && ! grep -q "step 2 of 9" <<< "$out"'
fresh
scen "$NODNS"
out="$(printf 'i\n4\n0\n0\n' | LC_ALL=C run menu)"
check "new installation: directly (the firewall opens the sites) goes on with the engine" 'grep -q "Directly: the downloads work once the firewall allows these sites." <<< "$out" && grep -q "Install . step 2 of 9" <<< "$out"'
fresh
out="$(printf 'i\n0\n0\n' | RN1_NET_CHECK=off LC_ALL=C run menu)"
check "RN1_NET_CHECK=off: the step says so, no request" 'grep -q "The internet check is off (RN1_NET_CHECK=off)." <<< "$out" && [ ! -s "$LOG" ]'

# 14. Before the engine is set up: only the sites of its setup, only those that fail ------------------------------
fresh
scen "direct|https://github.com/*|28|000|000|0||||"
out="$(run __net engine podman)"; rc=$?
check "engine setup: the sites it needs that fail (GitHub for Docker Compose), nothing else" '[ "$rc" -eq 1 ] && grep -q "Checking the sites the setup of Podman downloads from..." <<< "$out" && grep -q "The setup of Podman downloads from these sites, which cannot be$" <<< "$out" && grep -q "BLOCKED  *github.com" <<< "$out" && ! grep -q "registry-1.docker.io" <<< "$out" && ! grep -q "registry-1" "$LOG"'
scen
out="$(run __net engine podman)"; rc=$?
check "engine setup: all reachable - only the line before the check" '[ "$rc" -eq 0 ] && [ "$(grep -c . <<< "$out")" -eq 1 ] && grep -q "Checking the sites the setup of Podman" <<< "$out"'

# 15. The engine (Linux): drop-ins that point to the env file of the proxy (mode 600), a restart after a yes -------
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|' 's|^INTERNET_NO_PROXY=.*|INTERNET_NO_PROXY="corp.example.com"|'
(umask 077; printf '%s\n' "$FAKE_LOGIN" > "$D/.proxy_login")
mkdir -p "$T/sd"
EP="$T/etc/rn1-technology-catalog/engine-proxy.env"
DD="$T/etc/systemd/system/docker.service.d/50-rn1-proxy.conf"
PD="$T/etc/systemd/system/podman.service.d/50-rn1-proxy.conf"
PC="$T/etc/containers/containers.conf.d/50-rn1-proxy.conf"
# erun ARGS...: run with systemd and the engines on the PATH
erun() { RN1_SYSTEMD_DIR="$T/sd" XPATH="$T/ebin:$T/bin" run "$@"; }
: > "$SUDO_LOG"; rm -f "$T/systemctl.log"
out="$(printf 'y\n' | erun __net engine-write ask docker)"; rc=$?
check "Docker: the drop-in points to the env file; both written as root through stdin (mode 644 and 600)" '[ "$rc" -eq 0 ] && [ "$(sed -n 2,3p "$DD")" = "$(printf "[Service]\nEnvironmentFile=-%s" "$EP")" ] && [ "$(stat -c %a "$DD")" = 644 ] && [ "$(stat -c %a "$EP")" = 600 ] && grep -q "^sudo sh -c umask 022 .* sh $EP 600$" "$SUDO_LOG"'
check "Docker: the env file - the proxy with its login in both cases, NO_PROXY with this server, the internal names and the ranges, the folder" 'grep -qx "HTTPS_PROXY=.http://$USR_ENC:$PW_ENC@proxy.example.com:8080." "$EP" && grep -qx "http_proxy=.http://$USR_ENC:$PW_ENC@proxy.example.com:8080." "$EP" && grep -qx "NO_PROXY=.localhost,127.0.0.1,::1,srv01,srv01.corp.example.com,192.0.2.10,corp.example.com,.corp.example.com,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16." "$EP" && grep -qx "# Folder: $D" "$EP"'
check "Docker: running - restarted after a yes (the outage said), the units reloaded first" 'grep -q "the Catalog is unreachable for$" <<< "$out" && [ "$(cat "$T/systemctl.log")" = "$(printf "systemctl daemon-reload\nsystemctl restart docker")" ]'
rm -f "$T/systemctl.log"
out="$(erun __net engine-write ask docker </dev/null)"
check "Docker: the same proxy again - nothing written, no restart" '[ -z "$out" ] && [ ! -e "$T/systemctl.log" ]'
out="$(erun __net engine-write ask podman </dev/null)"
check "Podman: its drop-in, the same env file, no proxy handed to the containers; its service stopped (no question)" '[ "$(sed -n 3p "$PD")" = "EnvironmentFile=-$EP" ] && grep -qx "http_proxy = false" "$PC" && grep -qx "\[containers\]" "$PC" && grep -qx "systemctl stop podman.service" "$T/systemctl.log" && ! grep -q "Restart" <<< "$out"'
out="$(erun __net stale)"
check "option 16: no engine named while they have the proxy of the settings" '[ -z "$out" ]'
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
out="$(erun __net stale)"
check "option 16: the engines without the proxy of the settings are named" '[ "$(echo $out)" = "docker podman" ]'
out="$(printf 'n\n' | erun __net apply)"
check "applied (option 26): every engine of this server gets the proxy, Docker restarts only after a yes" '[ -f "$DD" ] && [ -f "$PD" ] && grep -q "Docker reads the change at its next restart" <<< "$out" && [ -z "$(erun __net stale)" ]'
rm -f "$DD" "$PD" "$PC" "$EP"
mkdir -p "$T/etc/docker"; printf '{ "proxies": { "https-proxy": "http://u:pw@daemon.example.com:3128" } }\n' > "$T/etc/docker/daemon.json"
out="$(erun __net engine-write ask docker </dev/null)"
check "Docker: a proxy in daemon.json (it wins) is left alone - no drop-in, said, its password masked" '[ ! -e "$DD" ] && grep -q "Docker.s proxy is set in .*/docker/daemon.json, which wins over$" <<< "$out" && grep -qx "    http://u:\*\*\*@daemon.example.com:3128" <<< "$out"'
rm -f "$T/etc/docker/daemon.json"
mkdir -p "${DD%/*}"; printf '[Service]\nEnvironment="HTTPS_PROXY=http://own.example.com:3128"\n' > "${DD%/*}/http-proxy.conf"
out="$(printf 'n\n' | erun __net engine-write ask docker)"
check "Docker: the proxy of another drop-in - said, kept after a no" 'grep -q "Docker has a proxy of its own: http://own.example.com:3128$" <<< "$out" && grep -q "^  ($T/etc/systemd/system/docker.service.d/http-proxy.conf).$" <<< "$out" && grep -q "Docker keeps its own proxy." <<< "$out" && [ ! -e "$DD" ] && [ ! -e "$EP" ]'
rm -f "$T/systemctl.log"
out="$(printf 'y\nn\n' | erun __net engine-write ask docker)"
check "Docker: ... after a yes the installer's drop-in (it wins), theirs stays; not restarted after a no" '[ -f "$DD" ] && [ -f "${DD%/*}/http-proxy.conf" ] && grep -q "Docker reads the change at its next restart (systemctl restart docker)." <<< "$out" && [ "$(cat "$T/systemctl.log")" = "systemctl daemon-reload" ]'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY=""|' "$I"; rm -f "$T/systemctl.log"
out="$(printf 'n\n' | erun __net engine-write ask docker)"
check "no proxy any more: only the installer's files go (the other drop-in stays), the units reloaded" '[ ! -e "$DD" ] && [ ! -e "$EP" ] && [ -f "${DD%/*}/http-proxy.conf" ] && grep -q "Docker has no proxy of the installer any more" <<< "$out" && grep -qx "systemctl daemon-reload" "$T/systemctl.log"'
# the files of the installer in another folder: one engine serves both
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
mkdir -p "$T/other"
printf 'INTERNET_PROXY="http://proxy.example.com:8080"\n' > "$T/other/rn1-technology-catalog-installer.sh"
erun __net engine-write ask podman </dev/null >/dev/null
sed -i "s|^# Folder: .*|# Folder: $T/other|" "$EP"
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY=""|' "$I"
out="$(erun __net engine-write ask podman </dev/null)"
check "no proxy here, but the engine has the one of another folder's installer: it stays" '[ -f "$PD" ] && [ -f "$EP" ] && grep -q "Podman keeps the proxy the installer in $T/other gave it." <<< "$out"'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy2.example.com:3128"|' "$I"
out="$(printf 'n\n' | erun __net engine-write ask podman)"
check "another proxy than the one of another folder: said, replaced only after a yes" 'grep -q "The installer in $T/other gave the engine another proxy:$" <<< "$out" && grep -qx "  http://proxy.example.com:8080 - one engine serves both folders." <<< "$out" && grep -q "proxy.example.com:8080" "$EP" && ! grep -q proxy2 "$EP"'
sed -i "s|^# Folder: .*|# Folder: $D|" "$EP"
out="$(erun __net cleanup </dev/null)"; rc=$?
check "R: the installer's proxy files of the engines go" '[ "$rc" -eq 0 ] && [ ! -e "$PD" ] && [ ! -e "$PC" ] && [ ! -e "$EP" ]'

# 16. catalog-web and Nginx Proxy Manager: the proxy through .env (HTTPS only), the other services get none ------
fresh 's|^CONTAINER_ENGINE=.*|CONTAINER_ENGINE="podman"|'
run generate >/dev/null
cp "$D/.env" "$T/env.none"; cp "$D/docker-compose.yml" "$T/compose.none"
check "no proxy: nothing of it in .env or the compose file" '[ -s "$T/compose.none" ] && ! grep -qE "RN1_|_PROXY:|_proxy:|IP_RANGES|extra_hosts|ca-bundle" "$T/env.none" "$T/compose.none"'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|; s|^INTERNET_NO_PROXY=.*|INTERNET_NO_PROXY="corp.example.com"|' "$I"
(umask 077; printf '%s\n' "$FAKE_LOGIN" > "$D/.proxy_login")
run generate >/dev/null
svc() { awk -v s="  $1:" '$0 == s { on = 1; next } /^  [a-z]/ || /^[a-z]/ { on = 0 } on' "$D/docker-compose.yml"; }
check ".env: the proxy of the containers with its login (percent-encoded, no \$ left), HTTPS only; mode 600" 'grep -qx "RN1_HTTPS_PROXY=.http://$USR_ENC:$PW_ENC@proxy.example.com:8080." "$D/.env" && grep -qx "RN1_HTTP_PROXY=.." "$D/.env" && ! grep "^RN1_" "$D/.env" | grep -qF "\$" && [ "$(stat -c %a "$D/.env")" = 600 ]'
check ".env: NO_PROXY - every service (worker-search too), the host names of the engines, this server, the internal names" 'grep -q "^RN1_NO_PROXY=.localhost,127.0.0.1,::1,mongo,minio,rabbitmq,opensearch,opensearch-dashboards,catalog-web,nginx-proxy-manager,worker-recognition-1,worker-recognition-2,worker-other,worker-search,host.docker.internal,host.containers.internal,srv01,srv01.corp.example.com,.*192.0.2.10,corp.example.com,.corp.example.com,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16.$" "$D/.env"'
check "compose: catalog-web and Nginx Proxy Manager get the proxy in both cases, HTTP_PROXY and ALL_PROXY empty" '( for s in catalog-web nginx-proxy-manager; do b="$(svc $s)"; grep -qx "      HTTPS_PROXY: \"\${RN1_HTTPS_PROXY}\"" <<< "$b" && grep -qx "      no_proxy: \"\${RN1_NO_PROXY}\"" <<< "$b" && grep -qx "      ALL_PROXY: \"\"" <<< "$b" && grep -qx "      HTTP_PROXY: \"\${RN1_HTTP_PROXY:-}\"" <<< "$b" || exit 1; done )'
check "compose: MongoDB, MinIO, RabbitMQ, OpenSearch and the workers get no proxy - every name empty (an engine's own proxy cannot reach them)" '[ "$(grep -c "RN1_HTTPS_PROXY" "$D/docker-compose.yml")" -eq 4 ] && ( for s in mongo minio rabbitmq opensearch opensearch-dashboards worker-recognition-1 worker-recognition-2 worker-other worker-search; do b="$(svc $s)"; [ "$(grep -ci "_proxy: \"\"$" <<< "$b")" -eq 8 ] && ! grep -i "_proxy:" <<< "$b" | grep -qv ": \"\"$" || exit 1; done )'
check "compose: Nginx Proxy Manager does not fetch the address ranges of the CDNs at its start" 'svc nginx-proxy-manager | grep -qx "      IP_RANGES_FETCH_ENABLED: \"false\"" && ! svc catalog-web | grep -q IP_RANGES'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://127.0.0.1:3128"|' "$I"
run generate >/dev/null
check "a relay on this server: host.containers.internal for Podman, no extra_hosts" 'grep -qx "RN1_HTTPS_PROXY=.http://$USR_ENC:$PW_ENC@host.containers.internal:3128." "$D/.env" && ! grep -q extra_hosts "$D/docker-compose.yml"'
sed -i 's|^CONTAINER_ENGINE=.*|CONTAINER_ENGINE="docker"|' "$I"
run generate >/dev/null
check "a relay on this server: host.docker.internal for Docker, host-gateway in catalog-web and Nginx Proxy Manager" 'grep -q "@host.docker.internal:3128.$" "$D/.env" && [ "$(grep -c "^      - \"host.docker.internal:host-gateway\"$" "$D/docker-compose.yml")" -eq 2 ] && svc catalog-web | grep -qx "    extra_hosts:"'
sed -i "s|^INTERNET_PROXY_CA_FILE=.*|INTERNET_PROXY_CA_FILE=\"$T/ca.pem\"|" "$I"
run generate >/dev/null
check "company certificate: read-only into catalog-web and Nginx Proxy Manager, with the three variables" '( for s in catalog-web nginx-proxy-manager; do b="$(svc $s)"; grep -qx "      - ./proxy-ca-bundle.pem:/etc/rn1/ca-bundle.pem:ro,z" <<< "$b" && grep -qx "      SSL_CERT_FILE: \"/etc/rn1/ca-bundle.pem\"" <<< "$b" && grep -qx "      REQUESTS_CA_BUNDLE: \"/etc/rn1/ca-bundle.pem\"" <<< "$b" && grep -qx "      NODE_EXTRA_CA_CERTS: \"/etc/rn1/ca-bundle.pem\"" <<< "$b" || exit 1; done ) && [ "$(grep -c "ca-bundle.pem" "$D/docker-compose.yml")" -eq 8 ]'
check "company certificate: proxy-ca-bundle.pem holds the certificates of this system and then the company's (mode 644)" '[ "$(stat -c %a "$D/proxy-ca-bundle.pem")" = 644 ] && [ "$(tail -n 20 "$D/proxy-ca-bundle.pem")" = "$(tail -n 20 "$T/ca.pem")" ]'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY=""|; s|^INTERNET_PROXY_CA_FILE=.*|INTERNET_PROXY_CA_FILE=""|; s|^CONTAINER_ENGINE=.*|CONTAINER_ENGINE="podman"|' "$I"
run generate >/dev/null
check "proxy and certificate removed: .env and the compose file byte for byte as without them" 'cmp -s "$T/env.none" "$D/.env" && cmp -s "$T/compose.none" "$D/docker-compose.yml"'
# saved in option 26 while the files are there: they are generated again at once
fresh
run generate >/dev/null
scen "${LOGIN_PROXY[@]}" "$NODNS"
out="$(printf '1\nproxy.example.com:8080\n%s\n%s\n\ny\n' "$USR" "$PW" | run __net ask)"
check "saved with the files there: the summary names the engine and the Catalog, .env generated again with the proxy" 'grep -q "^    engine        a drop-in of its service when it is set up" <<< "$out" && grep -q "^    Catalog       catalog-web and Nginx Proxy Manager, through .env (HTTPS" <<< "$out" && grep -q "written again from the settings, passwords kept." <<< "$out" && grep -q "^RN1_HTTPS_PROXY=" "$D/.env" && grep -q "use them from their next start$" <<< "$out"'

# 17. The company certificate in the trust store of this server after a yes; out again when it is forgotten --------
fresh
mkdir -p "$T/trust"
scen "direct|https://registry-1.docker.io/v2/|0|401|000|T19|HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer realm=\"https://auth.docker.io/token\"\r\n\r\n|||$INSP|" \
  "direct|https://ghcr.io/v2/|0|401|000|T19|HTTP/1.1 401 Unauthorized\r\nwww-authenticate: Bearer realm=\"https://ghcr.io/token\"\r\n\r\n|||$INSP|"
out="$(printf '%s\ny\ny\n' "$T/bundle.pem" | RN1_TRUST_DIR="$T/trust" run __net ask)"
laststatus() { awk -v h="$1" 'substr($0, 1, 2) == "  " && substr($0, 17, length(h) + 1) == h " " { s = substr($0, 3, 13); sub(/ +$/, "", s) } END { print s }' <<< "$out"; }
check "trust store: after the fingerprint and a yes - one file per certificate, then the command of this Linux" '[ "$(ls "$T/trust" | grep -c "^rn1-proxy-ca-[0-9]*-[12]\.\(crt\|pem\)$")" -eq 2 ] && grep -qE "^update-ca-(trust extract|certificates) +rn1-proxy-ca-[0-9]+-1" "$T/trust.log"'
check "trust store: the check again - the inspected sites are trusted now" 'grep -q "The check again, now with the trusted certificate:" <<< "$out" && [ "$(status registry-1.docker.io)" = "TLS INSPECTED" ] && [ "$(laststatus registry-1.docker.io)" = "OK" ]'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|' "$I"
(umask 077; printf '%s\n' "$FAKE_LOGIN" > "$D/.proxy_login")
echo "another folder" > "$T/trust/rn1-proxy-ca-1-1.pem"
scen "${LOGIN_PROXY[@]}" "$NODNS"
out="$(printf '26\n2\ny\ny\ny\n\n0\n' | RN1_TRUST_DIR="$T/trust" run menu)"
check "option 26 remove: the certificate forgotten, and out of the trust store after its own yes (another folder's stays)" '[ "$(ls -A "$T/trust")" = "rn1-proxy-ca-1-1.pem" ] && [ ! -e "$D/proxy-ca.pem" ] && [ -z "$(setting INTERNET_PROXY_CA_FILE)" ] && grep -q "The company certificate is out of the trust store of this server." <<< "$out"'
settle

# 18. macOS: the LaunchAgent of the Podman machine and colima.yaml carry the proxy ---------------------------------
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
(umask 077; printf 'macuser:macpass\n' > "$D/.proxy_login")
out="$(run __net agent podman-machine-default)"
check "LaunchAgent: the proxy with its login in EnvironmentVariables (Podman sets it in the machine at every start)" 'grep -q "<key>EnvironmentVariables</key><dict><key>HTTP_PROXY</key><string>http://macuser:macpass@proxy.example.com:8080</string>" <<< "$out" && grep -q "<key>no_proxy</key><string>localhost,127.0.0.1,::1,srv01," <<< "$out"'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY=""|' "$I"
out="$(run __net agent podman-machine-default)"
check "LaunchAgent without a proxy: as before" '! grep -q EnvironmentVariables <<< "$out" && [ "$(grep -c . <<< "$out")" -eq 10 ]'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|' "$I"
Y="$T/colima.yaml"
printf '# Environment variables for the virtual machine.\n# Default: {}\nenv: {}\n\n# Mounts\nmounts: []\n' > "$Y"
out="$(run __net colima "$Y")"
check "colima.yaml: env: {} becomes the proxy (mode 600), the rest stays" '[ "$out" = "rc=0" ] && grep -qx "  HTTPS_PROXY: .http://macuser:macpass@proxy.example.com:8080." "$Y" && grep -qx "env:" "$Y" && grep -qx "mounts: \[\]" "$Y" && grep -qx "# Default: {}" "$Y" && [ "$(stat -c %a "$Y")" = 600 ]'
check "colima.yaml: the same again - unchanged" '[ "$(run __net colima "$Y")" = "rc=1" ]'
printf 'cpu: 4\nenv:\n  FOO: bar\n  HTTP_PROXY: http://old.example.com:1\nmounts: []\n' > "$Y"
out="$(run __net colima "$Y")"
check "colima.yaml: its other variables stay, an old proxy is replaced" '[ "$out" = "rc=0" ] && grep -qx "  FOO: bar" "$Y" && ! grep -q old.example.com "$Y" && [ "$(grep -c "_PROXY:\|_proxy:" "$Y")" -eq 6 ] && grep -qx "cpu: 4" "$Y"'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY=""|' "$I"
out="$(run __net colima "$Y")"
check "colima.yaml without a proxy: the installer's variables go, the others stay" '[ "$out" = "rc=0" ] && grep -qx "  FOO: bar" "$Y" && ! grep -qi "proxy" "$Y"'
printf 'env:\n  HTTPS_PROXY: x\n' > "$Y"; run __net colima "$Y" >/dev/null
check "colima.yaml: nothing else in env: - env: {}" '[ "$(cat "$Y")" = "env: {}" ]'
printf 'env: {FOO: bar}\n' > "$Y"
check "colima.yaml: an env: the installer does not change is left alone" '[ "$(run __net colima "$Y")" = "rc=3" ] && [ "$(cat "$Y")" = "env: {FOO: bar}" ]'

# 19. A failed download names the check; adopt takes the proxy over ------------------------------------------------
fresh
out="$(run __net offer "The download of the images")"
check "a failed download without a terminal: the check is named" 'grep -q "network-check. checks the internet access (a proxy may be missing)." <<< "$out"'
mkdir -p "$T/old"
printf "TZ=Europe/Berlin\nRN1_HTTPS_PROXY='http://olduser:oldpass@host.docker.internal:3128'\n" > "$T/old/.env"
out="$(run __net adopt "$T/old" "$T/old/.env")"
check "adopt: the proxy of its .env (the relay is 127.0.0.1 again), its login into .proxy_login (mode 600)" '[ "$(setting INTERNET_PROXY)" = "http://127.0.0.1:3128" ] && [ "$(cat "$D/.proxy_login")" = "$(printf "proxy=http://127.0.0.1:3128\nolduser:oldpass")" ] && [ "$(stat -c %a "$D/.proxy_login")" = 600 ]'
(umask 077; printf 'x:y\n' > "$T/old/.proxy_login"); cp "$T/ca.pem" "$T/old/proxy-ca.pem"
fresh
out="$(run __net adopt "$T/old" "$T/old/.env")"
check "adopt: its .proxy_login and proxy-ca.pem are taken over" '[ "$(cat "$D/.proxy_login")" = "x:y" ] && cmp -s "$T/ca.pem" "$D/proxy-ca.pem" && [ "$(setting INTERNET_PROXY_CA_FILE)" = "$D/proxy-ca.pem" ]'

# 21. The review: what goes where, and when it must not ---------------------------------------------------------
# the saved login belongs to its proxy: a proxy changed in option 1 never gets it
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
(umask 077; printf 'proxy=http://proxy.example.com:8080\n%s\n' "$FAKE_LOGIN" > "$D/.proxy_login")
check "login: used for the proxy it was saved for" '[[ "$(run __net env)" == *"login=saved" ]]'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy-b.example.com:3128"|' "$I"
out="$(run __net env)"
check "login: another proxy in the settings gets no login (not in the environment, not for the engine)" '[[ "$out" == "http://proxy-b.example.com:3128|"*"|login=none" ]]'
scen
out="$(run network-check)"
check "login: the check through the other proxy sends none" 'grep -q "^proxy proxy-b.example.com:3128 none " "$LOG" && ! grep -q "proxy-b.example.com:3128 \(ok\|wrong\)" "$LOG"'
# the check never takes certificates unchecked (-k would make every site look inspected)
check "check: no request of the check with -k (only the issuer is read with it)" '! grep -q "^curl -sS -k\|^curl -sS .* -k " "$ARGV_LOG" && [ "$(status registry-1.docker.io)" = OK ]'
# an https:// proxy with a login: its certificate is checked (the fake reports a login sent unchecked)
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="https://proxy.example.com:8080"|'
(umask 077; printf '%s\n' "$FAKE_LOGIN" > "$D/.proxy_login")
out="$(run network-check)"; rc=$?
check "https:// proxy with a login: checked through it, its certificate not skipped" '[ "$rc" -eq 0 ] && grep -q "^proxy proxy.example.com:8080 ok " "$LOG" && ! grep -q "LOGIN TO AN UNCHECKED HTTPS PROXY" "$BAD"'
# proxy_sudo: a kill during the command - the root-only file with the login goes first
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
(umask 077; printf '%s\n' "$FAKE_LOGIN" > "$D/.proxy_login")
out="$(run __net sudo sh -c 'kill -TERM $PPID; sleep 1')"; rc=$?
check "a download as root killed (TERM): the file of the run is gone, the signal ends the installer" '[ "$rc" -ne 0 ] && [ -z "$(ls -A "$T/run")" ]'
# the containers' NO_PROXY: an internal online catalog is named
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|' 's|^CATALOG_CLOUD_URL=.*|CATALOG_CLOUD_URL="https://192.0.2.50"|'
run generate >/dev/null
check "NO_PROXY of the containers: an internal online catalog (by address) is reached directly" 'grep -q "^RN1_NO_PROXY=.*,192.0.2.50," "$D/.env"'
sed -i 's|^CATALOG_CLOUD_URL=.*|CATALOG_CLOUD_URL="https://parent.corp.example.com"|' "$I"
printf 'search corp.example.com\n' > "$T/etc/resolv.conf"
run generate >/dev/null
check "NO_PROXY of the containers: an online catalog in the server's domain too" 'grep -q "^RN1_NO_PROXY=.*,parent.corp.example.com," "$D/.env"'
sed -i 's|^CATALOG_CLOUD_URL=.*|CATALOG_CLOUD_URL="https://rayventorycatalog.raynet.de"|' "$I"
run generate >/dev/null
check "NO_PROXY of the containers: not the online catalog on the internet" '! grep -q "^RN1_NO_PROXY=.*raynet" "$D/.env"'
# option 26 never applies other pending settings with the proxy
fresh
run generate >/dev/null
sed -i 's|^MONGO_TAG=".*|MONGO_TAG="0.0.1-test"|; s|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|' "$I"
cp "$D/.env" "$T/env.before"
out="$(run __net apply </dev/null)"
check "apply: other settings not applied yet - nothing written, option 2 named" 'grep -q "Other settings differ from .env and docker-compose.yml as well" <<< "$out" && cmp -s "$T/env.before" "$D/.env"'
sed -i 's|^MONGO_TAG=".*|MONGO_TAG="'"$(sed -n 's/^MONGO_TAG="\(.*\)"$/\1/p' "$NEW")"'"|' "$I"
out="$(run __net apply </dev/null)"
check "apply: only the proxy differs - the files are written with it" 'grep -q "written again from the settings, passwords kept." <<< "$out" && grep -q "^RN1_HTTPS_PROXY=" "$D/.env"'
# WPAD: never a public suffix
fresh
printf 'search corp.example.co.uk\n' > "$T/etc/resolv.conf"
out="$(run __net wpad)"
check "WPAD: walked up to the company's domain, never to a public suffix (co.uk)" '[ "$(echo $out)" = "http://wpad.corp.example.co.uk/wpad.dat http://wpad.example.co.uk/wpad.dat" ]'
# PAC: when DIRECT reaches every required site, no proxy is taken
fresh
scen "proxy proxy.example.com:8080 *|*|7|000|000|0||||"
out="$(run __net pacask "$T/proxy.pac" </dev/null)"
check "PAC: every required site answers directly - no proxy needed, a dead candidate is not taken" 'grep -q "All [0-9]* required sites answer directly - no proxy needed." <<< "$out" && [ -z "$(setting INTERNET_PROXY)" ]'
# offline (choice 5): remembered - the menu start checks nothing, no header line
fresh
scen "$NODNS"
out="$(printf '5\n' | run __net ask)"
check "offline: the choice is remembered" '[ -f "$D/.jobs/internet-offline" ] && grep -q "The menu no longer checks the internet at its start" <<< "$out"'
: > "$LOG"
out="$(printf '0\n' | run menu)"
settle
check "offline: the menu start checks nothing and shows no internet line" '[ ! -s "$LOG" ] && ! grep -q "^Internet" <<< "$out"'
# directly (choice 4) with a saved proxy: it goes after a yes
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
scen "proxy proxy.example.com:8080 *|*|7|000|000|0||||" "$NODNS"
out="$(printf '26\n1\n4\ny\n\n0\n' | run menu)"
check "option 26, a dead proxy: the choices stay; directly removes the saved proxy after a yes" 'grep -q "Remove the proxy" <<< "$out" && grep -q "The proxy is removed: the installer goes out directly." <<< "$out" && [ -z "$(setting INTERNET_PROXY)" ]'
# a proxy only the shell has: named, saved after a yes
fresh
mkdir -p "$T/sd"
out="$(https_proxy=http://shellproxy.example.com:3128 RN1_SYSTEMD_DIR="$T/sd" XPATH="$T/ebin:$T/bin" run __net stale)"
check "shell proxy only: the engines do not read it - named for option 16" '[ "$(echo $out)" = "docker podman" ]'
out="$(https_proxy=http://shellproxy.example.com:3128 run network-check)"
check "shell proxy only: network-check says the engine and the containers do not read it" 'grep -q "Only your shell has this proxy (https_proxy)" <<< "$out"'
out="$(printf '26\ny\n\n-\ny\n\n\n0\n' | https_proxy=http://shellproxy.example.com:3128 run menu)"
check "shell proxy only: option 26 saves it after a yes" '[ "$(setting INTERNET_PROXY)" = "http://shellproxy.example.com:3128" ] && grep -q "Only your shell has this proxy" <<< "$out" && grep -q "Saved: the installer uses this proxy" <<< "$out"'
# one engine, two folders with the same proxy: the files stay while the other one uses them
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
rm -rf "$T/etc/rn1-technology-catalog" "$T/etc/systemd" "$T/etc/containers"; mkdir -p "$T/other"
printf 'INTERNET_PROXY="http://proxy.example.com:8080"\n' > "$T/other/rn1-technology-catalog-installer.sh"
erun __net engine-write ask podman </dev/null >/dev/null
sed -i "s|^# Folder: .*|# Folder: $T/other|" "$EP"
out="$(erun __net engine-write ask podman </dev/null)"
check "same proxy as another folder: both folders recorded, no question" 'grep -qx "# Folder: $T/other" "$EP" && grep -qx "# Folder: $D" "$EP" && ! grep -q "another proxy" <<< "$out"'
sed -i 's|^INTERNET_PROXY=.*|INTERNET_PROXY=""|' "$I"
out="$(erun __net engine-write ask podman </dev/null)"
check "same proxy, this folder removes it: the files stay for the other one, this folder no longer recorded" '[ -f "$PD" ] && [ -f "$EP" ] && grep -q "Podman keeps the proxy the installer in $T/other gave it." <<< "$out" && ! grep -qx "# Folder: $D" "$EP"'
# Podman with a proxy of its own, kept: it still hands it to no container
fresh 's|^INTERNET_PROXY=.*|INTERNET_PROXY="http://proxy.example.com:8080"|'
rm -rf "$T/etc/rn1-technology-catalog" "$T/etc/systemd" "$T/etc/containers"
mkdir -p "${PD%/*}"; printf '[Service]\nEnvironment="HTTPS_PROXY=http://own.example.com:3128"\n' > "${PD%/*}/proxy.conf"
out="$(printf 'n\n' | erun __net engine-write ask podman)"
check "Podman keeps its own proxy: containers.conf.d still hands it to no container" 'grep -q "Podman keeps its own proxy." <<< "$out" && [ ! -e "$PD" ] && grep -qx "http_proxy = false" "$PC"'
rm -rf "$T/other"

settle
# 20. The secrets: the password in no command line, log, output or file but those of mode 600 ---------------------
leak="$(grep -rlF -e "$PW" -e "$PW_ENC" "$T" 2>/dev/null | grep -v "^$T/answers$" | while IFS= read -r f; do [ "$(stat -c %a "$f")" = 600 ] || echo "$f"; done)"
check "the test password only in files of mode 600 (.proxy_login, .env, the env file of the engine) - not in the script, the cache, a log or an output" '[ -z "$leak" ] || { echo "$leak"; false; }'
check "no proxy address with a login on any command line" '! grep -qF "$USR_ENC:" "$ARGV_LOG" && ! grep -qF "$USR_ENC:" "$SUDO_LOG"'
check "the installer is valid bash" 'bash -n "$NEW"'
check "fakes: no unknown curl, apt-config, systemctl or podman call, no proxy on a command line" '[ ! -s "$BAD" ] || { sort "$BAD" | uniq -c | head -20; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
