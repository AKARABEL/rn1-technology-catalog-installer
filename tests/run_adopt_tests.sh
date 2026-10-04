#!/usr/bin/env bash
set -u
NEW="$1"
SP="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)/ad"
rm -rf "$T"; mkdir -p "$T/bin" "$T/oldroot" "$T/rn1-technology-catalog"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
export LOG="$T/docker.log" OLD="$T/oldroot"
: > "$LOG"

sed -e 's/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="8181"/' -e 's/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/' \
    -e 's/^MONGO_TAG=.*/MONGO_TAG="7.0"/' -e 's/^AUTOSYNC_CRON=.*/AUTOSYNC_CRON="15 3 * * 1-5"/' "$SP/original.sh" > "$OLD/catalog.sh"
(cd "$OLD" && bash catalog.sh >/dev/null 2>&1)
old_env="$(cksum < "$OLD/.env")"; old_compose="$(cksum < "$OLD/docker-compose.yml")"

cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
case "$1" in
  info) exit 0 ;;
  ps)
    if [ "$2" = -a ] && [ "${SHIM_NO_LABELS:-}" != 1 ]; then
      echo "root|$OLD|$OLD/docker-compose.yml||raynetgmbh/rayventory-catalog:25.4.4191.133|Up 3 days"
    fi
    exit 0 ;;
  compose)
    shift
    while [ $# -gt 0 ]; do case "$1" in -p|--env-file|-f) shift 2 ;; *) break ;; esac; done
    case "$1" in
      version) echo "Docker Compose version v2.29.0" ;;
      ps) [ "${2:-}" = --services ] && echo catalog-web ;;
      config) [ "${2:-}" = --services ] && echo catalog-web ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker"
export PATH="$T/bin:$PATH"
D="$T/rn1-technology-catalog"; cp "$NEW" "$D/catalog.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/catalog.sh"

# 1. The menu notices the existing installation
out="$(printf '0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "menu points to the existing installation" 'grep -q "A Catalog installation already exists in $OLD - option 23" <<< "$out"'

# 2. Take over via option 23
out="$(printf '23\ny\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "shows what was found, passwords hidden" 'grep -q "Compose project  *root" <<< "$out" && grep -q "Catalog version  *25.4.4191.133" <<< "$out" && grep -q "MONGO_INITDB_ROOT_PASSWORD  *found (not shown)" <<< "$out" && ! grep -q "$(sed -n "s/^MONGO_INITDB_ROOT_PASSWORD=//p" "$OLD/.env")" <<< "$out"'
same_pw() { local k; for k in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS; do [ "$(grep "^$k=" "$D/.env")" = "$(grep "^$k=" "$OLD/.env")" ] || return 1; done; }
check ".env copied with the same passwords (+ project name)" 'same_pw && grep -q "^COMPOSE_PROJECT_NAME=root$" "$D/.env"'
check "compose file copied unchanged" 'cmp -s "$D/docker-compose.yml" "$OLD/docker-compose.yml"'
check "settings imported into the script" 'grep -q "^CATALOG_WEB_PORT=\"8181\"$" "$D/catalog.sh" && grep -q "^INSTALL_NGINX_PROXY_MANAGER=\"false\"$" "$D/catalog.sh" && grep -q "^MONGO_TAG=\"7.0\"$" "$D/catalog.sh" && grep -q "^AUTOSYNC_CRON=\"15 3 \* \* 1-5\"$" "$D/catalog.sh" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/catalog.sh" && grep -q "^COMPOSE_PROJECT_NAME=\"root\"$" "$D/catalog.sh"'
check "template lines untouched" 'grep -q "^CATALOG_WEB_PORT=\${CATALOG_WEB_PORT}$" "$D/catalog.sh" && grep -q "^MONGO_TAG=\${MONGO_TAG}$" "$D/catalog.sh"'
check "difference to the template shown (MinIO image)" 'grep -q "differs from the one this installer generates" <<< "$out" && grep -q "image: minio/minio" <<< "$out" && grep -q "image: ghcr.io/golithus/minio" <<< "$out"'
check "reloaded with notice" 'grep -q "Installation in $OLD taken over." <<< "$out" && grep -q "Files  : .env present" <<< "$out"'
check "old installation untouched" '[ "$(cksum < "$OLD/.env")" = "$old_env" ] && [ "$(cksum < "$OLD/docker-compose.yml")" = "$old_compose" ]'
check "installer backup kept" 'ls "$D"/catalog.sh.bak-* >/dev/null 2>&1'

# 3. Compose commands now use the old project (same containers, same volumes)
: > "$LOG"; bash "$D/catalog.sh" status </dev/null >/dev/null 2>&1
check "docker compose runs with -p root" 'grep -q "^docker compose -p root --env-file .env -f docker-compose.yml ps" "$LOG"'

# 4. Generating keeps the passwords and the project name
bash "$D/catalog.sh" generate </dev/null >/dev/null 2>&1
check "generate keeps passwords and project" '[ "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env")" = "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$OLD/.env")" ] && grep -q "^COMPOSE_PROJECT_NAME=root$" "$D/.env" && grep -q "^CATALOG_WEB_PORT=8181$" "$D/.env"'

# 5. CLI with a folder when the containers carry no compose labels
D2="$T/second"; mkdir -p "$D2"; cp "$NEW" "$D2/catalog.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D2/catalog.sh"
out="$(SHIM_NO_LABELS=1 bash "$D2/catalog.sh" adopt "$OLD" </dev/null 2>&1)"; rc=$?
check "CLI adopt FOLDER without labels" '[ "$rc" -eq 0 ] && grep -q "^CATALOG_WEB_PORT=\"8181\"$" "$D2/catalog.sh" && grep -q "^COMPOSE_PROJECT_NAME=\"oldroot\"$" "$D2/catalog.sh"'

# 6. Nothing found
D3="$T/third"; mkdir -p "$D3"; cp "$NEW" "$D3/catalog.sh"
out="$(SHIM_NO_LABELS=1 bash "$D3/catalog.sh" adopt "$T/does-not-exist" </dev/null 2>&1)"
check "nothing found message" 'grep -q "No other Catalog installation found" <<< "$out"'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
