#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/su"
rm -rf "$T"; mkdir -p "$T/bin" "$T/srv" "$T/inst"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
export SRV="$T/srv"

sed -e 's/^HEALTH_TIMEOUT="600"$/HEALTH_TIMEOUT="600"\nNEW_SETTING="default-of-new-version"/' \
    -e 's/Raynet One Technology Catalog - Installation Portal\${C_RST}   (/Raynet One Technology Catalog - Installation Portal${C_RST} v2   (/' "$NEW" > "$SRV/catalog.sh"
printf '<!doctype html><html>404</html>\n' > "$SRV/broken.sh"

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --proto|--connect-timeout|--max-time|-H|-w) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "${SHIM_SERVE:-new}" in
  new) cat "$SRV/catalog.sh" > "$out" ;;
  broken) cat "$SRV/broken.sh" > "$out" ;;
  down) exit 6 ;;
esac
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

D="$T/inst"; cp "$NEW" "$D/catalog.sh"
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0"/; 0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="9090"/; 0,/^AUTOSYNC_CRON=/s/^AUTOSYNC_CRON=.*/AUTOSYNC_CRON="15 3 * * 1-5"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/catalog.sh"
before="$(cksum < "$D/catalog.sh")"

# 1. Broken or unreachable download -> nothing changed
out="$(SHIM_SERVE=broken bash "$D/catalog.sh" self-update </dev/null 2>&1)"; rc=$?
check "HTML instead of a script is rejected" '[ "$rc" -ne 0 ] && grep -q "not a valid installer" <<< "$out" && [ "$(cksum < "$D/catalog.sh")" = "$before" ]'
out="$(SHIM_SERVE=down bash "$D/catalog.sh" self-update </dev/null 2>&1)"; rc=$?
check "unreachable GitHub: nothing changed" '[ "$rc" -ne 0 ] && [ "$(cksum < "$D/catalog.sh")" = "$before" ]'

# 2. CLI self-update keeps the settings
out="$(bash "$D/catalog.sh" self-update </dev/null 2>&1)"; rc=$?
check "updated" '[ "$rc" -eq 0 ] && grep -q "Installer updated" <<< "$out" && grep -q "Installation Portal\${C_RST} v2" "$D/catalog.sh"'
check "settings kept (MONGO_TAG, port, cron with spaces and *)" 'grep -q "^MONGO_TAG=\"7.0\"$" "$D/catalog.sh" && grep -q "^CATALOG_WEB_PORT=\"9090\"$" "$D/catalog.sh" && grep -q "^AUTOSYNC_CRON=\"15 3 \* \* 1-5\"$" "$D/catalog.sh"'
check "new setting gets its default" 'grep -q "^NEW_SETTING=\"default-of-new-version\"$" "$D/catalog.sh"'
check "template lines untouched" 'grep -q "^MONGO_TAG=\${MONGO_TAG}$" "$D/catalog.sh" && grep -q "^CATALOG_WEB_PORT=\${CATALOG_WEB_PORT}$" "$D/catalog.sh"'
check "backup of the previous version" 'b="$(ls "$D"/catalog.sh.bak-* 2>/dev/null | head -n1)"; [ -n "$b" ] && [ "$(cksum < "$b")" = "$before" ]'
check "updated script still valid" 'bash -n "$D/catalog.sh" && bash "$D/catalog.sh" check-settings >/dev/null 2>&1'

# 3. Again -> up to date
out="$(bash "$D/catalog.sh" self-update </dev/null 2>&1)"
check "second run: up to date" 'grep -q "The installer is up to date." <<< "$out"'

# 4. Menu: update and reload into the new version
cp "$NEW" "$D/catalog.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/catalog.sh"
out="$(printf '22\ny\n0\n' | bash "$D/catalog.sh" menu 2>&1)"; rc=$?
check "menu: reloaded into the new version with notice" '[ "$rc" -eq 0 ] && grep -q "Installer updated - your settings were kept." <<< "$out" && grep -q "Installation Portal v2" <<< "$out"'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
