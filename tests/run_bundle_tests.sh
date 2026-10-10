#!/usr/bin/env bash
set -u
NEW="$1"
SP="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)/b"
rm -rf "$T"; mkdir -p "$T/bin" "$T/remote" "$T/impbin" "$T/root"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# STATE: the images of the fake Podman, one "ID NAME" per line (NAME <none> after a load without tags).
# UNHANDLED: every call a fake did not know, over all runs (LOG is emptied now and then).
export LOG="$T/calls.log" STATE="$T/engine.state" REMOTE="$T/remote" UNHANDLED="$T/unhandled.log" FAKEROOT="$T/root"
: > "$LOG"; : > "$STATE"; : > "$UNHANDLED"

# Fake rootful Podman 5.7: pulls only fully qualified names, IDs without the sha256: prefix,
# load restores the docker.io-qualified names of a docker-archive, tag with a short name makes localhost/...
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$LOG"
idof() { printf '%s' "$1" | sha256sum | cut -c1-64; }
isqual() { local first="${1%%/*}"; [[ "$1" == */* ]] && { [[ "$first" == *.* ]] || [[ "$first" == *:* ]] || [ "$first" = localhost ]; }; }
qual() { if isqual "$1"; then printf '%s' "$1"; elif [[ "$1" == */* ]]; then printf 'docker.io/%s' "$1"; else printf 'docker.io/library/%s' "$1"; fi; }
lookup() { awk -v n="$1" '$2 == n || $1 == n { print $1; f = 1; exit } END { exit !f }' "$STATE"; }
add() { grep -qxF "$1 $2" "$STATE" || echo "$1 $2" >> "$STATE"; }
unhandled() { echo "UNHANDLED podman $*" | tee -a "$UNHANDLED" >> "$LOG"; echo "Error: fake podman does not know: $*" >&2; exit 125; }
if [ -n "${SHIM_ENGINE_DOWN:-}" ] && [ "${1:-}" != --version ]; then
  echo "Error: unable to connect to Podman socket" >&2; exit 125
fi
case "${1:-}" in
  --version) echo "podman version ${SHIM_PODMAN_VERSION:-5.7.0}" ;;
  info)
    case "$*" in
      info) echo "host: fake" ;;
      "info --format {{.Host.Security.Rootless}}") echo false ;;
      "info --format {{.Host.Kernel}}") echo 6.8.0-generic ;;
      *) unhandled "$@" ;;
    esac ;;
  pull)
    shift; quiet=0
    while [ $# -gt 1 ]; do
      case "$1" in -q|--quiet) quiet=1; shift ;; --platform) [ "$2" = linux/amd64 ] || unhandled pull "$@"; shift 2 ;; *) unhandled pull "$@" ;; esac
    done
    ref="${1:-}"
    if ! isqual "$ref"; then
      echo "Error: short-name \"$ref\" did not resolve to an alias and no unqualified-search registries are defined in \"/etc/containers/registries.conf\"" >&2; exit 125
    fi
    add "$(idof "$ref")" "$ref"
    [ "$quiet" = 1 ] || echo "Trying to pull $ref..." >&2
    idof "$ref" ;;
  save)
    shift; out=""; fmt=""
    while [ $# -gt 1 ]; do
      case "$1" in -o|--output) out="$2"; shift 2 ;; --format) fmt="$2"; shift 2 ;; *) unhandled save "$@" ;; esac
    done
    ref="${1:-}"
    [ "$fmt" = docker-archive ] || unhandled save --format "$fmt" "$ref"
    [ "$ref" = "${SHIM_FAIL_SAVE:-}" ] && { echo "Error: saving $ref failed" >&2; exit 125; }
    id="$(lookup "$ref")" || { echo "Error: $ref: image not known" >&2; exit 125; }
    { echo "IMAGE $ref $id"; head -c 300000 /dev/zero; } > "$out" ;;
  load)
    [ "${2:-}" = -i ] || [ "${2:-}" = --input ] || unhandled "$@"
    magic=""; ref=""; id=""
    read -r magic ref id < "$3"
    [ "$magic" = IMAGE ] || { echo "Error: payload does not match any of the supported image formats" >&2; exit 125; }
    if [ "${SHIM_LOAD_UNTAGGED:-}" = 1 ]; then add "$id" "<none>"; echo "Loaded image: sha256:$id"
    else add "$id" "$(qual "$ref")"; echo "Loaded image: $(qual "$ref")"; fi ;;
  tag)
    id="$(lookup "${2#sha256:}")" || { echo "Error: $2: image not known" >&2; exit 125; }
    if isqual "$3"; then add "$id" "$3"; else add "$id" "localhost/$3"; fi ;;
  image)
    case "${2:-}" in
      inspect)
        if [ "${3:-}" = --format ]; then
          id="$(lookup "$5")" || { echo "Error: $5: image not known" >&2; exit 125; }
          case "$4" in "{{.ID}}") echo "$id" ;; "{{.Size}}") echo 300000 ;; *) unhandled "$@" ;; esac
        else
          id="$(lookup "$3")" || { echo "[]"; echo "Error: $3: image not known" >&2; exit 125; }
          printf '[{"Id": "%s"}]\n' "$id"
        fi ;;
      exists) lookup "$3" >/dev/null || exit 1 ;;
      *) unhandled "$@" ;;
    esac ;;
  # no stack on this machine: nothing runs, no volumes, no networks
  compose) [ "${2:-}" = ls ] && [ -n "${SHIM_COMPOSE_LS_FAIL:-}" ] && exit 1 ;;
  ps) ;;
  volume|network) [ "${2:-}" = ls ] || unhandled "$@" ;;
  *) unhandled "$@" ;;
esac
exit 0
EOF
# Fake Docker Compose (the provider behind "podman compose"): RN1_COMPOSE_PROVIDER points here
cat > "$T/bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  version) echo "Docker Compose version v5.6.0" ;;
  "version --short") echo "5.6.0" ;;
  *) echo "UNHANDLED docker-compose $*" | tee -a "$UNHANDLED" >> "$LOG"; exit 1 ;;
esac
EOF
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-active --quiet podman.socket") exit 0 ;;
  "is-enabled podman-restart.service") echo enabled; exit 0 ;;
  "enable --now podman.socket"|"enable podman-restart.service") exit 0 ;;
esac
echo "UNHANDLED systemctl $*" | tee -a "$UNHANDLED" >> "$LOG"; exit 1
EOF
# The newest Docker Compose on GitHub: v5.6.0 (the Location of releases/latest), its binary and .sha256.
# SHIM_GH_DOWN: GitHub cannot be reached. SHIM_COMPOSE_BADSUM: the .sha256 does not match.
# Everything else (registries, Docker Hub) is offline.
printf '#!/bin/sh\necho "Docker Compose version v5.6.0"\n' > "$T/compose-v5.6.0"
export COMPOSE_BIN="$T/compose-v5.6.0"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$LOG"
out=""; head=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-D|-H|-K|--connect-timeout|--max-time|--proto|--retry|--retry-delay|-X) shift 2 ;;
    --*) shift ;;
    -*) [[ "$1" == *I* ]] && head=1; shift ;;
    *) url="$1"; shift ;;
  esac
done
gh=https://github.com/docker/compose/releases
case "$url" in
  "$gh"/*) [ -n "${SHIM_GH_DOWN:-}" ] && exit 6 ;;
  *) exit 7 ;;
esac
case "$url" in
  "$gh/latest")
    [ "$head" = 1 ] || exit 22
    printf 'HTTP/2 302\r\ndate: Sat, 10 Oct 2026 10:00:00 GMT\r\nlocation: %s/tag/v5.6.0\r\n\r\n' "$gh" ;;
  "$gh/download/v5.6.0/docker-compose-linux-x86_64")
    cat "$COMPOSE_BIN" > "${out:-/dev/stdout}" ;;
  "$gh/download/v5.6.0/docker-compose-linux-x86_64.sha256")
    if [ -n "${SHIM_COMPOSE_BADSUM:-}" ]; then sum="$(printf 'other' | sha256sum)"; else sum="$(sha256sum < "$COMPOSE_BIN")"; fi
    printf '%s *docker-compose-linux-x86_64\n' "${sum%% *}" > "${out:-/dev/stdout}" ;;
  *) exit 22 ;;
esac
EOF
cat > "$T/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$LOG"
for a in "$@"; do [ "$a" = "-O" ] && exit 0; done
cmd="${@: -1}"
cmd="$(printf '%s' "$cmd" | sed "s#'/#'$REMOTE/#g")"
mkdir -p "$REMOTE"; cd "$REMOTE" && bash -c "$cmd"
EOF
cat > "$T/bin/scp" <<'EOF'
#!/usr/bin/env bash
echo "scp $*" >> "$LOG"
dest="${@: -1}"; src="${@: -2:1}"; rdir="${dest#*:}"
mkdir -p "$REMOTE/$rdir"; cp -r "$src" "$REMOTE/$rdir/"
echo "$(basename "$src")   100%  fake progress"
EOF
cat > "$T/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
echo "sshpass $1 SSHPASS=${SSHPASS:-<unset>}" >> "$LOG"
shift; exec "$@"
EOF
ssh-keygen -q -t ed25519 -N "" -f "$T/hostkey" >/dev/null
export HOSTKEY="$(cut -d' ' -f1-2 "$T/hostkey.pub")"
cat > "$T/bin/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
echo "ssh-keyscan $*" >> "$LOG"
port=22
while [ $# -gt 0 ]; do case "$1" in -p) port="$2"; shift 2 ;; --) shift ;; *) host="$1"; shift ;; esac; done
if [ "$port" = 22 ]; then name="$host"; else name="[$host]:$port"; fi
echo "$name $HOSTKEY"
EOF
chmod +x "$T/bin/"*
export HOME="$T/home"; mkdir -p "$HOME"
export RN1_COMPOSE_PROVIDER="$T/bin/docker-compose"
sysdirs="$PATH"
if PATH="$sysdirs" command -v sshpass >/dev/null 2>&1 || PATH="$sysdirs" command -v docker >/dev/null 2>&1 \
  || PATH="$sysdirs" command -v podman >/dev/null 2>&1 || PATH="$sysdirs" command -v docker-compose >/dev/null 2>&1; then
  mkdir -p "$T/sys"
  IFS=: read -r -a dirs <<< "$sysdirs"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      n="${f##*/}"
      case "$n" in sshpass|docker|podman|docker-compose) continue ;; esac
      [ -e "$T/sys/$n" ] || ln -s "$f" "$T/sys/$n" 2>/dev/null || true
    done
  done
  sysdirs="$T/sys"
fi
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
# Only for import-images.sh: id -u says SHIM_UID (default 0, also when the tests do not run as root), and
# what it puts under /usr/local/lib/docker lands in $FAKEROOT instead of the real system.
printf '#!/usr/bin/env bash
if [ "$*" = "-u" ]; then echo "${SHIM_UID:-0}"; elif [ "$*" = "-un" ] && [ "${SHIM_UID:-0}" != 0 ]; then echo user; else exec "%s" "$@"; fi
' "$(command -v id)" > "$T/impbin/id"
for tool in mkdir install; do
  printf '#!/usr/bin/env bash
echo "%s $*" >> "$LOG"
args=()
for a in "$@"; do case "$a" in /usr/local/lib/docker|/usr/local/lib/docker/*) a="$FAKEROOT$a" ;; esac; args+=("$a"); done
exec "%s" "${args[@]}"
' "$tool" "$(command -v "$tool")" > "$T/impbin/$tool"
done
chmod +x "$T/impbin/"*
export PATH="$T/bin:$sysdirs"
IMPPATH="$T/impbin:$PATH"
has_image() { awk -v n="$1" '$2 == n { f = 1 } END { exit !f }' "$STATE"; }
TARGET_COMPOSE="$FAKEROOT/usr/local/lib/docker/cli-plugins/docker-compose"
# import-images.sh installs Docker Compose there (instead of /usr/local/lib/docker/...) and enables the units
export RN1_COMPOSE_TARGET="$TARGET_COMPOSE" RN1_SYSTEMD_DIR="$T"

D="$T/src"; mkdir -p "$D"; cp "$NEW" "$D/rn1-technology-catalog-installer.sh"
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0.43"/; 0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG="2.19.6"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG="2.19.6"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG="3.13.7-management-alpine"/; 0,/^NGINX_PROXY_MANAGER_TAG=/s/^NGINX_PROXY_MANAGER_TAG=.*/NGINX_PROXY_MANAGER_TAG="2.16.0"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/rn1-technology-catalog-installer.sh"

# 1. CLI download (all images, archive, no scp)
out="$(bash "$D/rn1-technology-catalog-installer.sh" download </dev/null 2>&1)"; rc=$?
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | grep -v 'tar.gz' | head -n 1)"; NB="$(basename "$B")"
MONGO_ID="$(printf '%s' docker.io/library/mongo:7.0.43 | sha256sum | cut -c1-64)"
COMPOSE_SUM="$(sha256sum < "$COMPOSE_BIN" | cut -c1-64)"
check "download rc 0" '[ "$rc" -eq 0 ]'
check "bundle folder name with timestamp" '[[ "$NB" =~ ^RN1-Technology-Catalog-[0-9]{8}-[0-9]{6}$ ]]'
check "8 images saved (NPM enabled)" '[ "$(ls "$B/images" | wc -l)" -eq 8 ]'
check "images.txt has 8 lines ref|file|id" '[ "$(grep -c "^[^|]*|images/[^|]*\.tar|[0-9a-f]\{64\}$" "$B/images.txt")" -eq 8 ]'
check "images.txt: mongo with its file and the Podman image ID" 'grep -Eq "^(docker\.io/library/)?mongo:7\.0\.43\|images/mongo_7\.0\.43\.tar\|$MONGO_ID$" "$B/images.txt"'
check "pulled fully qualified with --platform linux/amd64" 'grep -q "^podman pull --platform linux/amd64 docker.io/library/mongo:7.0.43$" "$LOG" && grep -q "^podman pull --platform linux/amd64 docker.io/raynetgmbh/rayventory-catalog:" "$LOG" && grep -q "^podman pull --platform linux/amd64 ghcr.io/golithus/minio:" "$LOG"'
check "all 8 pulls fully qualified" '[ "$(grep -c "^podman pull --platform linux/amd64 \(docker\.io\|ghcr\.io\)/" "$LOG")" -eq 8 ] && [ "$(grep -c "^podman pull" "$LOG")" -eq 8 ]'
check "ID and size from podman image inspect" 'grep -q "^podman image inspect --format {{.ID}} docker.io/library/mongo:7.0.43$" "$LOG" && grep -q "^podman image inspect --format {{.Size}} docker.io/library/mongo:7.0.43$" "$LOG"'
check "saved as docker-archive with the qualified name" 'grep -q "^podman save --format docker-archive -o .*/$NB/images/mongo_7\.0\.43\.tar docker\.io/library/mongo:7\.0\.43$" "$LOG" && head -n 1 "$B/images/mongo_7.0.43.tar" | grep -q "^IMAGE docker.io/library/mongo:7.0.43 "'
check "minio file name sanitized" '[ -f "$B/images/ghcr.io_golithus_minio_RELEASE.2025-10-15T17-29-55Z.tar" ]'
check "no .env / compose in bundle" '[ ! -e "$B/.env" ] && [ ! -e "$B/docker-compose.yml" ] && [ ! -e "$D/.env" ]'
check "installer copied with CHECK_FOR_UPDATES=false" 'grep -q "^CHECK_FOR_UPDATES=\"false\"$" "$B/rn1-technology-catalog-installer.sh"'
check "import script executable" '[ -x "$B/import-images.sh" ] && grep -q "./rn1-technology-catalog-installer.sh" "$B/import-images.sh"'
check "import script has no --ignore-missing" '! grep -q -- "--ignore-missing" "$B/import-images.sh"'
check "newest Compose tag from the Location of releases/latest" 'grep -q "^curl -fsSI .*https://github.com/docker/compose/releases/latest$" "$LOG"'
check "Compose binary and .sha256 of v5.6.0 over https only" 'grep -q "^curl -fsSL --proto =https .*-o .*/$NB/compose/docker-compose-linux-x86_64 https://github.com/docker/compose/releases/download/v5.6.0/docker-compose-linux-x86_64$" "$LOG" && grep -q "^curl -fsSL --proto =https .* https://github.com/docker/compose/releases/download/v5.6.0/docker-compose-linux-x86_64.sha256$" "$LOG"'
check "bundle carries Docker Compose (executable, the downloaded file)" '[ -x "$B/compose/docker-compose-linux-x86_64" ] && cmp -s "$B/compose/docker-compose-linux-x86_64" "$COMPOSE_BIN"'
check "Compose listed in SHA256SUMS" '[ "$(grep -c "^$COMPOSE_SUM  compose/docker-compose-linux-x86_64$" "$B/SHA256SUMS")" -eq 1 ]'
check "SHA256SUMS verifies" '(cd "$B" && sha256sum -c --quiet SHA256SUMS)'
check "tar.gz + sha256 created" '[ -f "$B.tar.gz" ] && (cd "$D" && sha256sum -c --quiet "$NB.tar.gz.sha256")'
check "archive contains the folder" 'tar -tzf "$B.tar.gz" | grep -q "^$NB/import-images.sh$"'
check "archive contains Docker Compose" 'tar -tzf "$B.tar.gz" | grep -q "^$NB/compose/docker-compose-linux-x86_64$"'

# 2. Import on the "target" with Podman, as root
X="$T/target1"; mkdir -p "$X"; tar -xzf "$B.tar.gz" -C "$X"; : > "$STATE"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$IMPPATH" ./import-images.sh 2>&1)"; rc=$?
check "import rc 0, 8 loaded" '[ "$rc" -eq 0 ] && grep -q "8 image(s) loaded, 0 failed" <<< "$out"'
check "import names the engine: podman" 'grep -q "Container engine: podman" <<< "$out"'
check "import names next step" 'grep -q "Next: ./rn1-technology-catalog-installer.sh" <<< "$out"'
check "podman load -i per image file" '[ "$(grep -c "^podman load -i images/.*\.tar$" "$LOG")" -eq 8 ] && grep -q "^podman load -i images/mongo_7.0.43.tar$" "$LOG"'
check "docker.io-qualified names after import, none under localhost/" 'has_image docker.io/library/mongo:7.0.43 && has_image docker.io/opensearchproject/opensearch:2.19.6 && has_image ghcr.io/golithus/minio:RELEASE.2025-10-15T17-29-55Z && ! grep -q " localhost/" "$STATE"'
check "import checks the qualified name" 'grep -q "^podman image inspect docker.io/library/mongo:7.0.43$" "$LOG" && ! grep -q "^podman image inspect mongo:" "$LOG"'

# 2b. Not root: refused before anything is loaded (the Catalog runs in the Podman of root)
rm -f "$TARGET_COMPOSE"; : > "$STATE"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$IMPPATH" SHIM_UID=1000 ./import-images.sh 2>&1)"; rc=$?
check "not root: refused, nothing loaded or installed" '[ "$rc" -ne 0 ] && grep -q "Run it as root (sudo ./import-images.sh)" <<< "$out" && ! grep -q "^podman load" "$LOG" && ! grep -q "^install " "$LOG" && [ ! -e "$TARGET_COMPOSE" ]'

# 3. Import where load does not restore tags -> retag by image ID, with the qualified name
: > "$STATE"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$IMPPATH" SHIM_LOAD_UNTAGGED=1 ./import-images.sh 2>&1)"; rc=$?
check "import retags by image id" '[ "$rc" -eq 0 ] && grep -q "8 image(s) loaded, 0 failed" <<< "$out" && has_image docker.io/library/mongo:7.0.43'
check "retag uses the ID from images.txt and the qualified name (never localhost/)" 'grep -q "^podman tag $MONGO_ID docker.io/library/mongo:7.0.43$" "$LOG" && ! grep -q "^podman tag [^ ]* [^ ./]*:" "$LOG" && ! grep -q " localhost/" "$STATE"'

# 4. Import without Podman: clear error, nothing loaded
: > "$STATE"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$sysdirs" ./import-images.sh 2>&1)"; rc=$?
check "import without podman fails with a clear error" '[ "$rc" -ne 0 ] && grep -q "Podman is not installed" <<< "$out" && ! grep -q "^podman " "$LOG"'

# 5. Import as root: Docker Compose from the bundle becomes the provider of podman compose
rm -f "$TARGET_COMPOSE"; : > "$STATE"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$IMPPATH" SHIM_UID=0 ./import-images.sh 2>&1)"; rc=$?
check "root: import rc 0 and Docker Compose installed" '[ "$rc" -eq 0 ] && grep -q "8 image(s) loaded, 0 failed" <<< "$out" && grep -qF "OK Docker Compose installed: $TARGET_COMPOSE" <<< "$out"'
check "import script: Docker Compose goes to /usr/local/lib/docker/cli-plugins" 'grep -qF -- "\${RN1_COMPOSE_TARGET:-/usr/local/lib/docker/cli-plugins/docker-compose}" "$X/$NB/import-images.sh"'
check "root: import enables the API socket and the restart service" 'grep -q "^systemctl enable --now podman.socket$" "$LOG" && grep -q "^systemctl enable podman-restart.service$" "$LOG"'
check "root: installed with mode 755 to the cli-plugins path" 'grep -qF "install -m 755 compose/docker-compose-linux-x86_64 $TARGET_COMPOSE" "$LOG" && [ -x "$TARGET_COMPOSE" ] && cmp -s "$TARGET_COMPOSE" "$COMPOSE_BIN" && [ "$(stat -c %a "$TARGET_COMPOSE")" = 755 ]'

# 5b. A bundled Docker Compose that does not work with this Podman: the installed one stays
printf '#!/bin/sh\necho "Docker Compose version v5.5.0"\n' > "$TARGET_COMPOSE"; chmod 755 "$TARGET_COMPOSE"; before="$(cksum < "$TARGET_COMPOSE")"; : > "$STATE"; : > "$LOG"
out="$(cd "$X/$NB" && PATH="$IMPPATH" SHIM_COMPOSE_LS_FAIL=1 ./import-images.sh 2>&1)"; rc=$?
check "root: a bundled Compose that fails against this Podman is not installed" '[ "$rc" -eq 0 ] && grep -q "does not work with this Podman - the installed one stays" <<< "$out" && [ "$(cksum < "$TARGET_COMPOSE")" = "$before" ] && ! grep -q "^install " "$LOG" && grep -q "^podman compose ls -q$" "$LOG"'
: > "$STATE"
out="$(cd "$X/$NB" && PATH="$IMPPATH" ./import-images.sh 2>&1)"; rc=$?
check "root: a bundled Compose that works replaces the old one, kept as .previous" '[ "$rc" -eq 0 ] && cmp -s "$TARGET_COMPOSE" "$COMPOSE_BIN" && [ "$(cksum < "$TARGET_COMPOSE.previous")" = "$before" ]'

# 6. Tampered file -> checksum failure; edited installer does not block; missing image fails
: > "$STATE"; sed -i 's/^TZ=.*/TZ="UTC"/' "$X/$NB/rn1-technology-catalog-installer.sh"
out="$(cd "$X/$NB" && PATH="$IMPPATH" ./import-images.sh 2>&1)"; rc=$?
check "edited rn1-technology-catalog-installer.sh does not block import" '[ "$rc" -eq 0 ] && grep -q "8 image(s) loaded, 0 failed" <<< "$out"'
: > "$STATE"; echo x >> "$X/$NB/images/mongo_7.0.43.tar"
out="$(cd "$X/$NB" && PATH="$IMPPATH" ./import-images.sh 2>&1)"; rc=$?
check "tampered image detected" '[ "$rc" -ne 0 ] && grep -q "Checksum mismatch" <<< "$out"'
X2="$T/target2"; mkdir -p "$X2"; tar -xzf "$B.tar.gz" -C "$X2"; rm -f "$X2/$NB/images/mongo_7.0.43.tar"; : > "$STATE"
out="$(cd "$X2/$NB" && PATH="$IMPPATH" ./import-images.sh 2>&1)"; rc=$?
check "missing image counts as failure" '[ "$rc" -ne 0 ]'
X3="$T/target3"; mkdir -p "$X3"; tar -xzf "$B.tar.gz" -C "$X3"; echo x >> "$X3/$NB/compose/docker-compose-linux-x86_64"; : > "$STATE"; : > "$LOG"
out="$(cd "$X3/$NB" && PATH="$IMPPATH" SHIM_UID=0 ./import-images.sh 2>&1)"; rc=$?
check "tampered Docker Compose detected, nothing loaded or installed" '[ "$rc" -ne 0 ] && grep -q "Checksum mismatch" <<< "$out" && ! grep -q "^podman load" "$LOG" && ! grep -q "^install " "$LOG"'

# 7. Interactive: Updates -> d, deselect 1 2, tar.gz, scp with password (sshpass), fingerprint confirmed
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"; rm -rf "$REMOTE"; mkdir -p "$REMOTE"
in='8\nd\n1 2\n\n\ny\ny\ntesthost\n\nroot\n/opt/offline\n2\ny\nS3cr3t!\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"; rc=$?
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | grep -v 'tar.gz' | head -n 1)"
check "menu download: 6 images (1 and 2 deselected)" '[ "$(ls "$B/images" | wc -l)" -eq 6 ] && ! ls "$B/images" | grep -q rayventory'
check "background job pulls quietly, fully qualified" 'grep -q "^podman pull -q --platform linux/amd64 docker.io/library/mongo:7.0.43$" "$LOG" && ! grep -q "^podman pull --platform" "$LOG"'
check "menu bundle carries Docker Compose" '[ -x "$B/compose/docker-compose-linux-x86_64" ] && grep -q "  compose/docker-compose-linux-x86_64$" "$B/SHA256SUMS"'
check "scp copied archive + checksum" '[ -f "$REMOTE/opt/offline/$(basename "$B").tar.gz" ] && [ -f "$REMOTE/opt/offline/$(basename "$B").tar.gz.sha256" ]'
check "remote verification ok" 'grep -q "checksums match" <<< "$out"'
check "password passed via SSHPASS env (sshpass -e)" 'grep -q "sshpass -e SSHPASS=S3cr3t!" "$LOG"'
check "password not on any command line" '! grep "^ssh \|^scp " "$LOG" | grep -q "S3cr3t"'
check "host key confirmed, then strict checking" 'grep -q "New host - SSH key fingerprint" <<< "$out" && grep -q "StrictHostKeyChecking=yes" "$LOG" && ! grep -q "accept-new" "$LOG" && grep -q "^testhost ssh-ed25519" "$HOME/.ssh/known_hosts"'
check "fingerprint asked before the password is used" '[ "$(grep -n "^ssh-keyscan" "$LOG" | head -n1 | cut -d: -f1)" -lt "$(grep -n "^sshpass" "$LOG" | head -n1 | cut -d: -f1)" ]'
check "mkdir on remote before copy" 'grep -q "mkdir -p -- '"'"'/opt/offline'"'"'" "$LOG"'
check "local .env never generated" '[ ! -e "$D/.env" ] && [ ! -e "$D/docker-compose.yml" ]'

# 8. Known host on 22, new host key on port 2222, no sshpass -> ControlMaster
rm -f "$T/bin/sshpass"; rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"; rm -rf "$REMOTE"; mkdir -p "$REMOTE"
in='8\nd\n\n\nn\ny\ntesthost\n2222\nadmin\n~\n2\ny\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | head -n 1)"
check "no archive -> folder copied" '[ -d "$REMOTE/./$(basename "$B")/images" ]'
check "folder copy carries Docker Compose" '[ -f "$REMOTE/./$(basename "$B")/compose/docker-compose-linux-x86_64" ]'
check "ControlMaster used without sshpass" 'grep -q "ControlMaster=auto" "$LOG" && grep -q "Port=2222" "$LOG"'
check "remote folder checksums verified" 'grep -q "checksums match" <<< "$out"'
check "port-specific known_hosts entry" 'grep -q "^\[testhost\]:2222 ssh-ed25519" "$HOME/.ssh/known_hosts"'

# 9. Known host again -> no fingerprint question
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"; rm -rf "$REMOTE"; mkdir -p "$REMOTE"
in='8\nd\n\n\nn\ny\ntesthost\n2222\nadmin\n~\n2\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "known host: no keyscan, copy works" '! grep -q "^ssh-keyscan" "$LOG" && grep -q "checksums match" <<< "$out"'

# 10. Declined fingerprint -> nothing is sent
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"
in='8\nd\n\n\nn\ny\nnewhost\n\nroot\n/opt/x\n2\nn\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "declined fingerprint: no ssh/scp call" '! grep -q "^ssh \|^scp " "$LOG" && grep -q "Cancelled" <<< "$out"'

# 11. IPv6 literal -> brackets for scp only
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"
in='8\nd\n\n\nn\ny\n[2001:db8::1]\n\nroot\n/opt/v6\n2\ny\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "IPv6: ssh plain, scp bracketed" 'grep -q "^ssh .* root@2001:db8::1 " "$LOG" && grep -q "^scp .* root@\[2001:db8::1\]:/opt/v6/" "$LOG"'

# 12. Leading dash in host -> rejected
: > "$LOG"
in='8\nd\n\n\nn\ny\n-oProxyCommand=x\n\nroot\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "host starting with - rejected" 'grep -q "must not start with" <<< "$out" && ! grep -q "^ssh \|^ssh-keyscan" "$LOG"'

# 13. Failed save -> incomplete bundle removed
rm -rf "$D"/RN1-Technology-Catalog-*
out="$(SHIM_FAIL_SAVE=docker.io/library/mongo:7.0.43 bash "$D/rn1-technology-catalog-installer.sh" download </dev/null 2>&1)"; rc=$?
check "failed save: rc!=0 and no half bundle left" '[ "$rc" -ne 0 ] && grep -q "Incomplete bundle removed" <<< "$out" && ! ls -d "$D"/RN1-Technology-Catalog-* >/dev/null 2>&1'

# 14. '~' in the bundle folder prompt
rm -rf "$D"/RN1-Technology-Catalog-* "$HOME/bundles"
in='8\nd\n\n~/bundles\nn\nn\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "~ expands to HOME" 'ls -d "$HOME"/bundles/RN1-Technology-Catalog-* >/dev/null 2>&1 && [ ! -e "$D/~" ]'

# 15. GitHub unreachable -> the bundle is made without Docker Compose (with a warning) and imports
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"
out="$(SHIM_GH_DOWN=1 bash "$D/rn1-technology-catalog-installer.sh" download </dev/null 2>&1)"; rc=$?
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | grep -v 'tar.gz' | head -n 1)"
check "GitHub down: bundle made, warning, no compose/" '[ "$rc" -eq 0 ] && [ -n "$B" ] && grep -q "GitHub cannot be reached - the bundle has no Docker Compose" <<< "$out" && [ ! -e "$B/compose" ] && ! grep -q "compose/" "$B/SHA256SUMS" && ! grep -q "/download/" "$LOG"'
: > "$STATE"; : > "$LOG"
out="$(cd "$B" && sha256sum -c --quiet SHA256SUMS && PATH="$IMPPATH" SHIM_UID=0 ./import-images.sh 2>&1)"; rc=$?
check "GitHub down: bundle verifies and imports, nothing to install" '[ "$rc" -eq 0 ] && grep -q "8 image(s) loaded, 0 failed" <<< "$out" && ! grep -q "^install " "$LOG"'

# 16. Wrong checksum of the Compose download -> not in the bundle
rm -rf "$D"/RN1-Technology-Catalog-*
out="$(SHIM_COMPOSE_BADSUM=1 bash "$D/rn1-technology-catalog-installer.sh" download </dev/null 2>&1)"; rc=$?
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | grep -v 'tar.gz' | head -n 1)"
check "Compose checksum mismatch: bundle without it, warning" '[ "$rc" -eq 0 ] && [ -n "$B" ] && grep -q "checksum of Docker Compose does not match" <<< "$out" && [ ! -e "$B/compose" ] && (cd "$B" && sha256sum -c --quiet SHA256SUMS)'

# 17. Podman does not answer on the download machine -> nothing is made
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"
out="$(SHIM_ENGINE_DOWN=1 bash "$D/rn1-technology-catalog-installer.sh" download </dev/null 2>&1)"; rc=$?
check "download without a working Podman: error, no bundle, no pull" '[ "$rc" -ne 0 ] && grep -q "Downloading needs Podman" <<< "$out" && ! ls -d "$D"/RN1-Technology-Catalog-* >/dev/null 2>&1 && ! grep -q "^podman pull" "$LOG"'

check "the fakes saw no unknown call" '[ ! -s "$UNHANDLED" ] || { sed "s/^/  /" "$UNHANDLED"; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
