#!/usr/bin/env bash
set -u
NEW="$1"
SP="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)/t"
rm -rf "$T"; mkdir -p "$T/bin"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$SHIM_LOG"
case "$*" in
  "compose version") echo "Docker Compose version v2.29.0"; exit 0 ;;
  "info") exit 0 ;;
  "--version") echo "Docker version 27.0.0"; exit 0 ;;
  volume\ ls*) printf '%s' "${SHIM_VOLUMES:-}"; exit 0 ;;
esac
if [[ "$*" == compose* ]]; then
  case "$*" in
    *"config --services"*) printf 'opensearch\nmongo\ncatalog-web\n'; exit 0 ;;
    *"ps --services"*) printf 'mongo\ncatalog-web\n'; exit 0 ;;
    *) exit 0 ;;
  esac
fi
exit 0
EOF
chmod +x "$T/bin/docker"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
echo "curl $url" >> "$SHIM_LOG"
if [ -n "${SHIM_HUB_FAIL:-}" ]; then exit 7; fi
case "$url" in
  *rayventory-catalog-worker/tags*) r=rayventory-catalog-worker ;;
  *rayventory-catalog/tags*) r=rayventory-catalog ;;
  *) exit 22 ;;
esac
case "$url" in
  *"page=2&page_size=30"*) cat "$HUB_DIR/$r.p2.json" ;;
  *"page=2"*) exit 22 ;;
  *) cat "$HUB_DIR/$r.p1.json" ;;
esac
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" SHIM_LOG="$T/docker.log" HUB_DIR="$SP/hub"
: > "$SHIM_LOG"
mask() { sed -E 's/^((MONGO_INITDB_ROOT|MINIO_ROOT)_PASSWORD|RABBITMQ_DEFAULT_PASS)=.*/\1=X/' "$1"; }
newdir() { rm -rf "$T/$1"; mkdir -p "$T/$1"; cp "$NEW" "$T/$1/gen.sh"; echo "$T/$1"; }

# 1. Byte-identical output vs original (NPM true / false)
for npm in true false; do
  D="$(newdir "id_$npm")"; O="$T/orig_$npm"; rm -rf "$O"; mkdir -p "$O"
  sed -i "s/^INSTALL_NGINX_PROXY_MANAGER=\"true\"/INSTALL_NGINX_PROXY_MANAGER=\"$npm\"/" "$D/gen.sh"
  sed "s/^INSTALL_NGINX_PROXY_MANAGER=\"true\"/INSTALL_NGINX_PROXY_MANAGER=\"$npm\"/" "$SP/original.sh" | sed 's|^MINIO_TAG="latest"|MINIO_TAG="RELEASE.2025-10-15T17-29-55Z"|; s|image: minio/minio:|image: ghcr.io/golithus/minio:|' > "$O/gen.sh"
  (cd "$O" && bash gen.sh >/dev/null)
  bash "$D/gen.sh" generate </dev/null >/dev/null 2>&1
  check "env identical NPM=$npm" 'diff <(mask "$O/.env") <(mask "$D/.env") >/dev/null'
  check "compose identical NPM=$npm" 'cmp -s "$O/docker-compose.yml" "$D/docker-compose.yml"'
done

# 2. keep / new / unknown flag
D="$(newdir keep)"
bash "$D/gen.sh" generate </dev/null >/dev/null 2>&1; p1="$(grep MONGO_INITDB_ROOT_PASSWORD "$D/.env")"
bash "$D/gen.sh" generate </dev/null >/dev/null 2>&1; p2="$(grep MONGO_INITDB_ROOT_PASSWORD "$D/.env")"
check "generate keeps passwords" '[ "$p1" = "$p2" ]'
out="$(bash "$D/gen.sh" generate --new-passwords </dev/null 2>&1)"; p3="$(grep MONGO_INITDB_ROOT_PASSWORD "$D/.env")"
check "--new-passwords changes passwords" '[ "$p1" != "$p3" ]'
check "--new-passwords warns about volumes" 'grep -q "only work after those volumes are removed" <<< "$out"'
bash "$D/gen.sh" generate --new-password </dev/null >/dev/null 2>&1; rc=$?
check "unknown generate flag -> rc 2" '[ "$rc" -eq 2 ]'
check "compose backup made" 'ls "$D"/docker-compose.yml.bak-* >/dev/null 2>&1'

# 3. .env missing, backup exists -> reuse backup passwords
rm -f "$D/.env"
out="$(bash "$D/gen.sh" generate </dev/null 2>&1)"; p4="$(grep MONGO_INITDB_ROOT_PASSWORD "$D/.env")"
newest="$(ls "$D"/.env.bak-* | sort | tail -n 1)"; pb="$(grep MONGO_INITDB_ROOT_PASSWORD "$newest" 2>/dev/null)"
check "missing .env reuses newest backup" 'grep -q "reusing the passwords from the newest backup" <<< "$out" && [ -n "$pb" ] && [ "$p4" = "$pb" ]'

# 4. .env missing, no backup, volumes exist -> CLI refuses, --new-passwords proceeds
D="$(newdir vols)"
out="$(SHIM_VOLUMES=$'vols_db_data\nvols_rmq_data\n' bash "$D/gen.sh" generate </dev/null 2>&1)"; rc=$?
check "volumes exist, no .env -> rc 1" '[ "$rc" -eq 1 ] && [ ! -f "$D/.env" ]'
check "volume rm hint lists names on one line" 'grep -q "docker volume rm vols_db_data vols_rmq_data" <<< "$out"'
SHIM_VOLUMES=$'vols_db_data\n' bash "$D/gen.sh" generate --new-passwords </dev/null >/dev/null 2>&1; rc=$?
check "--new-passwords proceeds with volumes" '[ "$rc" -eq 0 ] && [ -f "$D/.env" ]'

# 5. compose argv: up / down use --remove-orphans and pinned files
D="$(newdir argv)"; bash "$D/gen.sh" generate </dev/null >/dev/null 2>&1
: > "$SHIM_LOG"; bash "$D/gen.sh" up </dev/null >/dev/null 2>&1; rc=$?
check "CLI up rc 0" '[ "$rc" -eq 0 ]'
check "up uses --env-file -f and --remove-orphans" 'grep -q "^docker compose --env-file .env -f docker-compose.yml up -d --remove-orphans$" "$SHIM_LOG"'
: > "$SHIM_LOG"; bash "$D/gen.sh" down </dev/null >/dev/null 2>&1
check "down uses --remove-orphans" 'grep -q "down --remove-orphans$" "$SHIM_LOG"'
bash "$D/gen.sh" logs nosuch </dev/null >/dev/null 2>&1; rc=$?
check "logs unknown service -> rc 1" '[ "$rc" -eq 1 ]'
: > "$SHIM_LOG"; bash "$D/gen.sh" logs mongo </dev/null >/dev/null 2>&1; rc=$?
check "logs known service ok" '[ "$rc" -eq 0 ] && grep -q "logs -f --tail=200 mongo$" "$SHIM_LOG"'

# 6. staleness: change setting after generate
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.1.0.1"/' "$D/gen.sh"
out="$(bash "$D/gen.sh" up </dev/null 2>&1)"
check "CLI up warns about stale files" 'grep -q "do not match the settings" <<< "$out"'
out="$(printf '0\n' | bash "$D/gen.sh" menu 2>&1)"
check "menu shows stale banner" 'grep -q "do not match the settings above" <<< "$out"'
bash "$D/gen.sh" generate </dev/null >/dev/null 2>&1
out="$(printf '0\n' | bash "$D/gen.sh" menu 2>&1)"
check "no stale banner after regenerate" '! grep -q "do not match the settings above" <<< "$out"'
check "regenerate applied new version" 'grep -q "rayventory-catalog:26.1.0.1" "$D/.env"'
out="$(printf '6\nn\n\n0\n' | bash "$D/gen.sh" menu 2>&1)"
check "menu up not stale -> no prompt, starts" 'grep -q "Stack is up" <<< "$out"'

# 7. menu: options 3/4 without files show error then pause
D="$(newdir menu_nofiles)"
out="$(printf '3\n\n4\n\n0\n' | bash -x "$D/gen.sh" menu 2>&1)"
check "option 3 without files errors + pause" 'grep -A12 "^ERROR .env not found" <<< "$out" | grep -q "^+ pause"'
check "menu hint says menu option" 'grep -q "menu option 2" <<< "$out"'

# 8. menu option 2 (ask), keep; full setup cancel
D="$(newdir menu_gen)"
printf '2\n\n0\n' | bash "$D/gen.sh" menu >/dev/null 2>&1; p1="$(grep MONGO_INITDB_ROOT_PASSWORD "$D/.env")"
printf '2\n1\n\n0\n' | bash "$D/gen.sh" menu >/dev/null 2>&1; p2="$(grep MONGO_INITDB_ROOT_PASSWORD "$D/.env")"
check "menu 2 keep" '[ -n "$p1" ] && [ "$p1" = "$p2" ]'
: > "$SHIM_LOG"
out="$(printf '7\n0\n\n0\n' | bash "$D/gen.sh" menu 2>&1)"
check "full setup cancel does not start" '! grep -q " up -d" "$SHIM_LOG" && grep -q "Cancelled" <<< "$out"'
: > "$SHIM_LOG"
out="$(printf '7\n1\n\n0\n' | bash "$D/gen.sh" menu 2>&1)"
check "full setup keep starts" 'grep -q " up -d --remove-orphans" "$SHIM_LOG"'
out="$(printf '99\nnope\n\n0\n' | bash "$D/gen.sh" menu 2>&1)"
check "reset needs DELETE" 'grep -q "Cancelled" <<< "$out" && ! grep -q "down -v" "$SHIM_LOG"'

# 9. edit_config: broken edit -> decline -> restored; good edit -> reload
D="$(newdir edit)"
cat > "$T/bin/ed-break" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"; sed -i 's/^OPENSEARCH_HEAP=.*/OPENSEARCH_HEAP=-Xms1g -Xmx1g/' "$f"
EOF
cat > "$T/bin/ed-good" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"; sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.2.0.5"/' "$f"
EOF
cat > "$T/bin/ed-none" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$T/bin/ed-exit1" <<'EOF'
#!/usr/bin/env bash
f="${@: -1}"; sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="27.0.0.1"/' "$f"; exit 1
EOF
chmod +x "$T/bin/"ed-*
cs1="$(cksum < "$D/gen.sh")"
out="$(printf '1\nn\n\n0\n' | EDITOR=ed-break bash "$D/gen.sh" menu 2>&1)"; rc=$?
check "broken edit detected" 'grep -q "cannot start with these settings" <<< "$out"'
check "broken edit restored + menu continues" '[ "$rc" -eq 0 ] && [ "$(cksum < "$D/gen.sh")" = "$cs1" ] && grep -q "previous version" <<< "$out"'
out="$(printf '1\n\n0\n' | EDITOR=ed-none bash "$D/gen.sh" menu 2>&1)"
check "no-change edit says No changes" 'grep -q "No changes" <<< "$out"'
out="$(printf '1\n0\n' | EDITOR=ed-good bash "$D/gen.sh" menu 2>&1)"
check "good edit reloads with new version" 'grep -q "Configuration reloaded" <<< "$out" && grep -q "Catalog 26.2.0.5" <<< "$out"'
out="$(printf '1\n0\n' | EDITOR=ed-exit1 bash "$D/gen.sh" menu 2>&1)"
check "editor rc!=0 with changes still reloads" 'grep -q "Catalog 27.0.0.1" <<< "$out"'
out="$(printf '1\n\n0\n' | EDITOR=no-such-editor bash -x "$D/gen.sh" menu 2>&1)"
check "missing editor error visible before pause" 'grep -A12 "^ERROR Editor .no-such-editor. not found" <<< "$out" | grep -q "^+ pause"'

# 10. symlink-free path: run from another dir writes next to script
D="$(newdir otherdir)"; mkdir -p "$T/elsewhere"
(cd "$T/elsewhere" && bash ../otherdir/gen.sh generate </dev/null >/dev/null 2>&1)
check "files written next to script" '[ -f "$D/.env" ] && [ ! -f "$T/elsewhere/.env" ]'
out="$(cd "$T/elsewhere" && bash ../otherdir/gen.sh down </dev/null 2>&1)"
check "CLI hint uses \$0 path" 'grep -q "../otherdir/gen.sh up" <<< "$out"'

# 11. check-settings subcommand
D="$(newdir cs)"
check "check-settings ok" 'bash "$D/gen.sh" check-settings >/dev/null 2>&1'
sed -i 's/^MONGO_PORT_HOST=.*/MONGO_PORT_HOST="8080"/' "$D/gen.sh"
check "duplicate port rejected" '! bash "$D/gen.sh" check-settings >/dev/null 2>&1'

# 12. old docker-compose v1 rejected
cat > "$T/bin2-docker" <<'EOF'
EOF
mkdir -p "$T/bin_old"
cat > "$T/bin_old/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in "info") exit 0 ;; "compose version") exit 1 ;; *) exit 0 ;; esac
EOF
cat > "$T/bin_old/docker-compose" <<'EOF'
#!/usr/bin/env bash
case "$*" in "version --short") echo "1.25.0" ;; esac
exit 0
EOF
chmod +x "$T/bin_old/"*
D="$(newdir oldcompose)"; bash "$D/gen.sh" generate </dev/null >/dev/null 2>&1
out="$(PATH="$T/bin_old:$PATH" bash "$D/gen.sh" validate </dev/null 2>&1)"; rc=$?
check "docker-compose 1.25 rejected" '[ "$rc" -ne 0 ] && grep -q "too old" <<< "$out"'

# 13. Catalog versions from Docker Hub
D="$(newdir ver)"
out="$(bash "$D/gen.sh" versions 2>&1)"; rc=$?
check "versions rc 0" '[ "$rc" -eq 0 ]'
check "versions lists exactly 4" '[ "$(grep -cE "^  [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" <<< "$out")" -eq 4 ]'
check "versions newest first + stable marker" '[ "$(grep -E "^  [0-9]" <<< "$out" | head -n 1)" = "  26.3.4789.148 (stable)" ]'
check "versions has no latest marker" '! grep -qi "latest" <<< "$out"'
check "versions marks selected" 'grep -q "25.4.4191.133  (selected)" <<< "$out"'
check "pagination followed with unescaped &" 'grep -q "page=2&page_size=30" "$SHIM_LOG"'
check "catalog-only tags excluded (12.2.x)" '! bash "$D/gen.sh" set-version 12.2.1580.13 >/dev/null 2>&1'
out="$(printf '0\n' | bash "$D/gen.sh" menu 2>&1)"
check "header shows update available with stable" 'grep -q "update available: 26.3.4789.148 (stable), option 8" <<< "$out"'

cp "$D/gen.sh" "$T/ver_before.sh"
: > "$SHIM_LOG"
out="$(printf '8\n1\n1\ns\ny\n0\n\n0\n' | bash "$D/gen.sh" menu 2>&1)"
check "option 8 sets CATALOG_VERSION in script" 'grep -q "^CATALOG_VERSION=\"26.3.4789.148\"$" "$D/gen.sh"'
check "only the CATALOG_VERSION line changed" '[ "$(diff "$T/ver_before.sh" "$D/gen.sh" | grep -c "^[<>]")" -eq 2 ]'
check "web and worker image use the new version" 'grep -q "^CATALOG_IMAGE=raynetgmbh/rayventory-catalog:26.3.4789.148$" "$D/.env" && grep -q "^CATALOG_WORKER_IMAGE=raynetgmbh/rayventory-catalog-worker:26.3.4789.148$" "$D/.env"'
check "option 8 apply started the stack" 'grep -q " up -d --remove-orphans" "$SHIM_LOG"'
check "header up to date after selection" 'grep -q "Catalog 26.3.4789.148 - up to date" <<< "$out"'
check "script still runs after self-edit" 'bash -n "$D/gen.sh" && bash "$D/gen.sh" check-settings >/dev/null 2>&1'

out="$(printf '8\n1\n4\nn\n0\n\n0\n' | bash "$D/gen.sh" menu 2>&1)"
check "downgrade warns and can be declined" 'grep -q "OLDER than" <<< "$out" && grep -q "^CATALOG_VERSION=\"26.3.4789.148\"$" "$D/gen.sh"'
out="$(printf '8\n1\n26.1.4475.136\nn\n0\n\n0\n' | bash "$D/gen.sh" menu 2>&1)"
check "typed version accepted (downgrade declined)" 'grep -q "26.1.4475.136 is OLDER" <<< "$out"'
out="$(printf '8\n1\n9\n0\n0\n\n0\n' | bash "$D/gen.sh" menu 2>&1)"
check "out-of-range choice rejected" 'grep -q "Invalid choice: 9" <<< "$out"'

D="$(newdir ver_cli)"
out="$(bash "$D/gen.sh" set-version stable 2>&1)"; rc=$?
check "set-version stable" '[ "$rc" -eq 0 ] && grep -q "^CATALOG_VERSION=\"26.3.4789.148\"$" "$D/gen.sh"'
bash "$D/gen.sh" set-version latest >/dev/null 2>&1; rc=$?
check "set-version latest rejected" '[ "$rc" -eq 1 ]'
bash "$D/gen.sh" set-version >/dev/null 2>&1; rc=$?
check "set-version without arg rc 2" '[ "$rc" -eq 2 ]'
out="$(bash "$D/gen.sh" set-version 26.1.4475.136 2>&1)"; rc=$?
check "set-version older warns but sets" '[ "$rc" -eq 0 ] && grep -q "OLDER" <<< "$out" && grep -q "^CATALOG_VERSION=\"26.1.4475.136\"$" "$D/gen.sh"'

# 14. Docker Hub not reachable / disabled
D="$(newdir ver_off)"
out="$(printf '8\n1\n0\n\n0\n' | SHIM_HUB_FAIL=1 bash "$D/gen.sh" menu 2>&1)"
check "header says Docker Hub not reachable" 'grep -q "Docker Hub not reachable" <<< "$out"'
check "option 8 errors when offline" 'grep -q "Could not read the versions from Docker Hub" <<< "$out"'
out="$(SHIM_HUB_FAIL=1 bash "$D/gen.sh" set-version 26.3.4789.148 2>&1)"; rc=$?
check "offline set-version exact version allowed with warning" '[ "$rc" -eq 0 ] && grep -q "not checked" <<< "$out"'
SHIM_HUB_FAIL=1 bash "$D/gen.sh" set-version stable >/dev/null 2>&1; rc=$?
check "offline set-version stable rejected" '[ "$rc" -eq 1 ]'
sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/gen.sh"
: > "$SHIM_LOG"
out="$(printf '0\n' | bash "$D/gen.sh" menu 2>&1)"
check "CHECK_FOR_UPDATES=false skips lookup" '! grep -q "^curl" "$SHIM_LOG" && ! grep -q "Checking Docker Hub" <<< "$out"'
check "header plain when disabled" 'grep -q "Installation Portal   (Catalog 26.3.4789.148)$" <<< "$out"'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
