#!/usr/bin/env bash
set -u
NEW="$1"
SP="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)/b"
rm -rf "$T"; mkdir -p "$T/bin" "$T/remote"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
export LOG="$T/calls.log" STATE="$T/engine.state" REMOTE="$T/remote"
: > "$LOG"; : > "$STATE"

cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
idof() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }
case "$1" in
  info) exit 0 ;;
  pull) echo "pulled ${@: -1}"; exit 0 ;;
  save) out="$3"; ref="$4"; [ "$ref" = "${SHIM_FAIL_SAVE:-}" ] && exit 1; { echo "IMAGE $ref"; head -c 300000 /dev/zero; } > "$out"; exit 0 ;;
  load) ref="$(head -n 1 "$3" | sed 's/^IMAGE //')"; [ "${SHIM_LOAD_UNTAGGED:-}" = 1 ] || echo "$ref" >> "$STATE"; echo "id:$(idof "$ref")" >> "$STATE"; exit 0 ;;
  tag) grep -qx "id:sha256:$2" "$STATE" && { echo "$3" >> "$STATE"; exit 0; }; exit 1 ;;
  image)
    if [ "$2" = inspect ] && [ "$3" = --format ]; then
      case "$4" in *Id*) idof "$5" ;; *Size*) echo 300000 ;; esac; exit 0
    fi
    if [ "$2" = inspect ]; then grep -qxF "$3" "$STATE"; exit $?; fi ;;
esac
exit 0
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
sysdirs="$PATH"
if PATH="$sysdirs" command -v sshpass >/dev/null 2>&1 || PATH="$sysdirs" command -v docker >/dev/null 2>&1 || PATH="$sysdirs" command -v podman >/dev/null 2>&1; then
  mkdir -p "$T/sys"
  IFS=: read -r -a dirs <<< "$sysdirs"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      n="${f##*/}"
      case "$n" in sshpass|docker|podman) continue ;; esac
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
export PATH="$T/bin:$sysdirs"

D="$T/src"; mkdir -p "$D"; cp "$NEW" "$D/rn1-technology-catalog-installer.sh"
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0.43"/; 0,/^OPENSEARCH_TAG=/s/^OPENSEARCH_TAG=.*/OPENSEARCH_TAG="2.19.6"/; 0,/^OPENSEARCH_DASHBOARDS_TAG=/s/^OPENSEARCH_DASHBOARDS_TAG=.*/OPENSEARCH_DASHBOARDS_TAG="2.19.6"/; 0,/^RABBITMQ_TAG=/s/^RABBITMQ_TAG=.*/RABBITMQ_TAG="3.13.7-management-alpine"/; 0,/^NGINX_PROXY_MANAGER_TAG=/s/^NGINX_PROXY_MANAGER_TAG=.*/NGINX_PROXY_MANAGER_TAG="2.16.0"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/rn1-technology-catalog-installer.sh"

# 1. CLI download (all images, archive, no scp)
out="$(bash "$D/rn1-technology-catalog-installer.sh" download </dev/null 2>&1)"; rc=$?
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | grep -v 'tar.gz' | head -n 1)"
check "download rc 0" '[ "$rc" -eq 0 ]'
check "bundle folder name with timestamp" '[[ "$(basename "$B")" =~ ^RN1-Technology-Catalog-[0-9]{8}-[0-9]{6}$ ]]'
check "8 images saved (NPM enabled)" '[ "$(ls "$B/images" | wc -l)" -eq 8 ]'
check "images.txt has 8 lines ref|file|id" '[ "$(grep -c "^[^|]*|images/[^|]*\.tar|[0-9a-f]\{64\}$" "$B/images.txt")" -eq 8 ]'
check "images.txt keeps the short refs" 'grep -q "^mongo:7.0.43|" "$B/images.txt"'
check "pulled fully qualified with --platform linux/amd64" 'grep -q "docker pull --platform linux/amd64 docker.io/library/mongo:7.0.43" "$LOG" && grep -q "docker pull --platform linux/amd64 docker.io/raynetgmbh/rayventory-catalog:" "$LOG" && grep -q "docker pull --platform linux/amd64 ghcr.io/golithus/minio:" "$LOG"'
check "minio file name sanitized" '[ -f "$B/images/ghcr.io_golithus_minio_RELEASE.2025-10-15T17-29-55Z.tar" ]'
check "no .env / compose in bundle" '[ ! -e "$B/.env" ] && [ ! -e "$B/docker-compose.yml" ] && [ ! -e "$D/.env" ]'
check "installer copied with CHECK_FOR_UPDATES=false" 'grep -q "^CHECK_FOR_UPDATES=\"false\"$" "$B/rn1-technology-catalog-installer.sh"'
check "import script executable" '[ -x "$B/import-images.sh" ] && grep -q "./rn1-technology-catalog-installer.sh" "$B/import-images.sh"'
check "import script has no --ignore-missing" '! grep -q -- "--ignore-missing" "$B/import-images.sh"'
check "SHA256SUMS verifies" '(cd "$B" && sha256sum -c --quiet SHA256SUMS)'
check "tar.gz + sha256 created" '[ -f "$B.tar.gz" ] && (cd "$D" && sha256sum -c --quiet "$(basename "$B").tar.gz.sha256")'
check "archive contains the folder" 'tar -tzf "$B.tar.gz" | grep -q "^$(basename "$B")/import-images.sh$"'

# 2. Import on the "target" with docker
X="$T/target1"; mkdir -p "$X"; tar -xzf "$B.tar.gz" -C "$X"; : > "$STATE"
out="$(cd "$X/$(basename "$B")" && ./import-images.sh 2>&1)"; rc=$?
check "import (docker) rc 0, 8 loaded" '[ "$rc" -eq 0 ] && grep -q "8 image(s) loaded, 0 failed" <<< "$out"'
check "import names next step" 'grep -q "Next: ./rn1-technology-catalog-installer.sh" <<< "$out"'
check "short ref usable after import" 'grep -qx "mongo:7.0.43" "$STATE"'

# 3. Import where load does not restore tags -> retag by id
: > "$STATE"
out="$(cd "$X/$(basename "$B")" && SHIM_LOAD_UNTAGGED=1 ./import-images.sh 2>&1)"; rc=$?
check "import retags by image id" '[ "$rc" -eq 0 ] && grep -q "8 image(s) loaded" <<< "$out" && grep -qx "mongo:7.0.43" "$STATE"'

# 4. Import with podman (docker absent)
mkdir -p "$T/podbin"; cp "$T/bin/docker" "$T/podbin/podman"; sed -i 's/^echo "docker/echo "podman/' "$T/podbin/podman"
: > "$STATE"
out="$(cd "$X/$(basename "$B")" && PATH="$T/podbin:$(printf '%s' "$PATH" | sed "s#$T/bin:##")" ./import-images.sh 2>&1)"; rc=$?
check "import detects podman" '[ "$rc" -eq 0 ] && grep -q "Container engine: podman" <<< "$out"'

# 5. Tampered file -> checksum failure; edited installer does not block; missing image fails
: > "$STATE"; sed -i 's/^TZ=.*/TZ="UTC"/' "$X/$(basename "$B")/rn1-technology-catalog-installer.sh"
out="$(cd "$X/$(basename "$B")" && ./import-images.sh 2>&1)"; rc=$?
check "edited rn1-technology-catalog-installer.sh does not block import" '[ "$rc" -eq 0 ] && grep -q "8 image(s) loaded, 0 failed" <<< "$out"'
: > "$STATE"; echo x >> "$X/$(basename "$B")/images/mongo_7.0.43.tar"
out="$(cd "$X/$(basename "$B")" && ./import-images.sh 2>&1)"; rc=$?
check "tampered image detected" '[ "$rc" -ne 0 ] && grep -q "Checksum mismatch" <<< "$out"'
X2="$T/target2"; mkdir -p "$X2"; tar -xzf "$B.tar.gz" -C "$X2"; rm -f "$X2/$(basename "$B")/images/mongo_7.0.43.tar"; : > "$STATE"
out="$(cd "$X2/$(basename "$B")" && ./import-images.sh 2>&1)"; rc=$?
check "missing image counts as failure" '[ "$rc" -ne 0 ]'

# 6. Interactive: Updates -> d, deselect 1 2, tar.gz, scp with password (sshpass), fingerprint confirmed
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"; rm -rf "$REMOTE"; mkdir -p "$REMOTE"
in='8\nd\n1 2\n\n\ny\ny\ntesthost\n\nroot\n/opt/offline\n2\ny\nS3cr3t!\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"; rc=$?
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | grep -v 'tar.gz' | head -n 1)"
check "menu download: 6 images (1 and 2 deselected)" '[ "$(ls "$B/images" | wc -l)" -eq 6 ] && ! ls "$B/images" | grep -q rayventory'
check "scp copied archive + checksum" '[ -f "$REMOTE/opt/offline/$(basename "$B").tar.gz" ] && [ -f "$REMOTE/opt/offline/$(basename "$B").tar.gz.sha256" ]'
check "remote verification ok" 'grep -q "checksums match" <<< "$out"'
check "password passed via SSHPASS env (sshpass -e)" 'grep -q "sshpass -e SSHPASS=S3cr3t!" "$LOG"'
check "password not on any command line" '! grep "^ssh \|^scp " "$LOG" | grep -q "S3cr3t"'
check "host key confirmed, then strict checking" 'grep -q "New host - SSH key fingerprint" <<< "$out" && grep -q "StrictHostKeyChecking=yes" "$LOG" && ! grep -q "accept-new" "$LOG" && grep -q "^testhost ssh-ed25519" "$HOME/.ssh/known_hosts"'
check "fingerprint asked before the password is used" '[ "$(grep -n "^ssh-keyscan" "$LOG" | head -n1 | cut -d: -f1)" -lt "$(grep -n "^sshpass" "$LOG" | head -n1 | cut -d: -f1)" ]'
check "mkdir on remote before copy" 'grep -q "mkdir -p -- '"'"'/opt/offline'"'"'" "$LOG"'
check "local .env never generated" '[ ! -e "$D/.env" ] && [ ! -e "$D/docker-compose.yml" ]'

# 7. Known host on 22, new host key on port 2222, no sshpass -> ControlMaster
rm -f "$T/bin/sshpass"; rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"; rm -rf "$REMOTE"; mkdir -p "$REMOTE"
in='8\nd\n\n\nn\ny\ntesthost\n2222\nadmin\n~\n2\ny\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
B="$(ls -d "$D"/RN1-Technology-Catalog-* 2>/dev/null | head -n 1)"
check "no archive -> folder copied" '[ -d "$REMOTE/./$(basename "$B")/images" ]'
check "ControlMaster used without sshpass" 'grep -q "ControlMaster=auto" "$LOG" && grep -q "Port=2222" "$LOG"'
check "remote folder checksums verified" 'grep -q "checksums match" <<< "$out"'
check "port-specific known_hosts entry" 'grep -q "^\[testhost\]:2222 ssh-ed25519" "$HOME/.ssh/known_hosts"'

# 8. Known host again -> no fingerprint question
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"; rm -rf "$REMOTE"; mkdir -p "$REMOTE"
in='8\nd\n\n\nn\ny\ntesthost\n2222\nadmin\n~\n2\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "known host: no keyscan, copy works" '! grep -q "^ssh-keyscan" "$LOG" && grep -q "checksums match" <<< "$out"'

# 9. Declined fingerprint -> nothing is sent
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"
in='8\nd\n\n\nn\ny\nnewhost\n\nroot\n/opt/x\n2\nn\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "declined fingerprint: no ssh/scp call" '! grep -q "^ssh \|^scp " "$LOG" && grep -q "Cancelled" <<< "$out"'

# 10. IPv6 literal -> brackets for scp only
rm -rf "$D"/RN1-Technology-Catalog-*; : > "$LOG"
in='8\nd\n\n\nn\ny\n[2001:db8::1]\n\nroot\n/opt/v6\n2\ny\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "IPv6: ssh plain, scp bracketed" 'grep -q "^ssh .* root@2001:db8::1 " "$LOG" && grep -q "^scp .* root@\[2001:db8::1\]:/opt/v6/" "$LOG"'

# 11. Leading dash in host -> rejected
: > "$LOG"
in='8\nd\n\n\nn\ny\n-oProxyCommand=x\n\nroot\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "host starting with - rejected" 'grep -q "must not start with" <<< "$out" && ! grep -q "^ssh \|^ssh-keyscan" "$LOG"'

# 12. Failed save -> incomplete bundle removed
rm -rf "$D"/RN1-Technology-Catalog-*
out="$(SHIM_FAIL_SAVE=docker.io/library/mongo:7.0.43 bash "$D/rn1-technology-catalog-installer.sh" download </dev/null 2>&1)"; rc=$?
check "failed save: rc!=0 and no half bundle left" '[ "$rc" -ne 0 ] && grep -q "Incomplete bundle removed" <<< "$out" && ! ls -d "$D"/RN1-Technology-Catalog-* >/dev/null 2>&1'

# 13. '~' in the bundle folder prompt
rm -rf "$D"/RN1-Technology-Catalog-* "$HOME/bundles"
in='8\nd\n\n~/bundles\nn\nn\n0\n\n0\n'
out="$(printf "$in" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "~ expands to HOME" 'ls -d "$HOME"/bundles/RN1-Technology-Catalog-* >/dev/null 2>&1 && [ ! -e "$D/~" ]'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
