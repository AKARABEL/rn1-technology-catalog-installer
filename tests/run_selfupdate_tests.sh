#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/su"
rm -rf "$T"; mkdir -p "$T/bin" "$T/srv" "$T/inst"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
export SRV="$T/srv"

sed -e 's/^HEALTH_TIMEOUT="600"$/HEALTH_TIMEOUT="600"\nNEW_SETTING="default-of-new-version"/' \
    -e 's/Raynet One Technology Catalog - Installation Portal\${C_RST}   (/Raynet One Technology Catalog - Installation Portal${C_RST} v2   (/' "$NEW" > "$SRV/rn1-technology-catalog-installer.sh"
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
echo "$url" >> "$SRV/urls"
case "${SHIM_SERVE:-new}" in
  new) cat "$SRV/rn1-technology-catalog-installer.sh" > "$out" ;;
  broken) cat "$SRV/broken.sh" > "$out" ;;
  same) cat "$SRV/same.sh" > "$out" ;;
  down) exit 6 ;;
esac
EOF
chmod +x "$T/bin/curl"
cat > "$T/bin/timedatectl" <<'TZEOF'
#!/usr/bin/env bash
printf '%s\n' "${SHIM_TZ:-Europe/Berlin}"
TZEOF
chmod +x "$T/bin/timedatectl"
export PATH="$T/bin:$PATH"

D="$T/inst"; cp "$NEW" "$D/rn1-technology-catalog-installer.sh"
sed -i '0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0"/; 0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="9090"/; 0,/^AUTOSYNC_CRON=/s/^AUTOSYNC_CRON=.*/AUTOSYNC_CRON="15 3 * * 1-5"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/rn1-technology-catalog-installer.sh"
before="$(cksum < "$D/rn1-technology-catalog-installer.sh")"

# 1. Broken or unreachable download -> nothing changed
out="$(SHIM_SERVE=broken bash "$D/rn1-technology-catalog-installer.sh" self-update </dev/null 2>&1)"; rc=$?
check "HTML instead of a script is rejected" '[ "$rc" -ne 0 ] && grep -q "not a valid installer" <<< "$out" && [ "$(cksum < "$D/rn1-technology-catalog-installer.sh")" = "$before" ]'
out="$(SHIM_SERVE=down bash "$D/rn1-technology-catalog-installer.sh" self-update </dev/null 2>&1)"; rc=$?
check "unreachable GitHub: nothing changed" '[ "$rc" -ne 0 ] && [ "$(cksum < "$D/rn1-technology-catalog-installer.sh")" = "$before" ]'

# 2. CLI self-update keeps the settings
out="$(bash "$D/rn1-technology-catalog-installer.sh" self-update </dev/null 2>&1)"; rc=$?
check "updated" '[ "$rc" -eq 0 ] && grep -q "Installer updated" <<< "$out" && grep -q "Installation Portal\${C_RST} v2" "$D/rn1-technology-catalog-installer.sh"'
check "settings kept (MONGO_TAG, port, cron with spaces and *)" 'grep -q "^MONGO_TAG=\"7.0\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^CATALOG_WEB_PORT=\"9090\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^AUTOSYNC_CRON=\"15 3 \* \* 1-5\"$" "$D/rn1-technology-catalog-installer.sh"'
check "new setting gets its default" 'grep -q "^NEW_SETTING=\"default-of-new-version\"$" "$D/rn1-technology-catalog-installer.sh"'
check "template lines untouched" 'grep -q "^MONGO_TAG=\${MONGO_TAG}$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^CATALOG_WEB_PORT=\${CATALOG_WEB_PORT}$" "$D/rn1-technology-catalog-installer.sh"'
check "backup of the previous version" 'b="$(ls "$D"/rn1-technology-catalog-installer.sh.bak-* 2>/dev/null | head -n1)"; [ -n "$b" ] && [ "$(cksum < "$b")" = "$before" ]'
check "updated script still valid" 'bash -n "$D/rn1-technology-catalog-installer.sh" && bash "$D/rn1-technology-catalog-installer.sh" check-settings >/dev/null 2>&1'

# 3. Again -> up to date
out="$(bash "$D/rn1-technology-catalog-installer.sh" self-update </dev/null 2>&1)"
check "second run: up to date" 'grep -q "The installer is up to date." <<< "$out"'
check "no terminal (script, cron): the menu does not open" '! grep -q "Installation Portal" <<< "$out"'

# 4. Menu: update and reload into the new version
cp "$NEW" "$D/rn1-technology-catalog-installer.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/rn1-technology-catalog-installer.sh"
out="$(printf '22\ny\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"; rc=$?
check "menu: reloaded into the new version with notice" '[ "$rc" -eq 0 ] && grep -q "Installer updated - your settings were kept." <<< "$out" && grep -q "Installation Portal v2" <<< "$out"'

# 4b. self-update in a terminal opens the menu of the new version (0 leaves it)
if command -v script >/dev/null 2>&1 && [ "$(uname -s)" = "Linux" ]; then
  cp "$NEW" "$D/rn1-technology-catalog-installer.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/rn1-technology-catalog-installer.sh"
  # tty_run COMMAND: runs it in a pseudo-terminal, types 0 once the menu asks (or the command ended),
  # keeps the input open until the command has ended, then prints what the terminal showed
  tty_run() {
    local log="$T/tty.log" i
    : > "$log"
    { for i in $(seq 1 240); do grep -q "Select an option\|TTY-END" "$log" 2>/dev/null && break; sleep 0.5; done
      printf '0\n'
      for i in $(seq 1 240); do grep -q "TTY-END" "$log" 2>/dev/null && break; sleep 0.5; done
    } | TERM=dumb timeout 300 script -qfec "$1; echo TTY-END" /dev/null > "$log" 2>&1
    sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g' "$log" | tr -d '\r'
  }
  SU="bash $D/rn1-technology-catalog-installer.sh self-update"
  out="$(tty_run "$SU")"
  check "terminal: updated, then the new menu with the notice" 'grep -q "Installer updated (previous version" <<< "$out" && grep -q "Installer updated - your settings were kept." <<< "$out" && grep -q "Installation Portal v2" <<< "$out" && grep -q TTY-END <<< "$out"'
  out="$(tty_run "$SU")"
  check "terminal: up to date, the menu opens too" 'grep -q "The installer is up to date." <<< "$out" && grep -q "Installation Portal v2" <<< "$out"'
  out="$(tty_run "$SU --no-menu")"
  check "terminal: --no-menu just ends" 'grep -q "The installer is up to date." <<< "$out" && ! grep -q "Installation Portal" <<< "$out" && grep -q TTY-END <<< "$out"'
  out="$(tty_run "timeout 120 $SU")"
  check "terminal, but in the background (timeout): no menu, no stop" 'grep -q "The installer is up to date." <<< "$out" && ! grep -q "Installation Portal" <<< "$out" && grep -q TTY-END <<< "$out"'
  out="$(SHIM_SERVE=down tty_run "$SU")"
  check "terminal: failed download, no menu" 'grep -q "not a valid installer" <<< "$out" && ! grep -q "Installation Portal" <<< "$out"'
  out="$(bash "$D/rn1-technology-catalog-installer.sh" self-update --menu </dev/null 2>&1)"; rc=$?
  check "unknown self-update option refused" '[ "$rc" -eq 2 ] && grep -q "only --no-menu" <<< "$out"'
else
  echo "SKIP: script (util-linux) missing - no terminal test of self-update"
fi

# 5. Installation from before the rename: catalog.sh with the old update address
NEWURL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh"
OLDURL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/catalog.sh"
L="$T/legacy"; mkdir -p "$L"; cp "$NEW" "$L/catalog.sh"
sed -i "s#^INSTALLER_URL=.*#INSTALLER_URL=\"$OLDURL\"#; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES=\"false\"/; 0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT=\"9191\"/" "$L/catalog.sh"
: > "$SRV/urls"
out="$(bash "$L/catalog.sh" self-update </dev/null 2>&1)"; rc=$?
check "old address: downloads the renamed installer" '[ "$rc" -eq 0 ] && [ "$(tail -n 1 "$SRV/urls")" = "$NEWURL" ]'
check "old address replaced by the new one, other settings kept" 'grep -q "^INSTALLER_URL=\"$NEWURL\"$" "$L/catalog.sh" && grep -q "^CATALOG_WEB_PORT=\"9191\"$" "$L/catalog.sh"'
check "old file name kept, backup next to it" '[ -f "$L/catalog.sh" ] && ls "$L"/catalog.sh.bak-* >/dev/null 2>&1 && [ ! -e "$L/rn1-technology-catalog-installer.sh" ]'

# 6. Own update address (mirror) stays as it is
M="$T/mirror"; mkdir -p "$M"; cp "$NEW" "$M/rn1-technology-catalog-installer.sh"
sed -i 's#^INSTALLER_URL=.*#INSTALLER_URL="https://mirror.example/installer.sh"#; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$M/rn1-technology-catalog-installer.sh"
: > "$SRV/urls"
out="$(bash "$M/rn1-technology-catalog-installer.sh" self-update </dev/null 2>&1)"; rc=$?
check "own address used and kept" '[ "$rc" -eq 0 ] && [ "$(tail -n 1 "$SRV/urls")" = "https://mirror.example/installer.sh" ] && grep -q "^INSTALLER_URL=\"https://mirror.example/installer.sh\"$" "$M/rn1-technology-catalog-installer.sh"'

# 7. Same version, only the old update address: no "new version", the address is updated in place
U="$T/urlonly"; mkdir -p "$U"; cp "$NEW" "$U/catalog.sh"; cp "$NEW" "$SRV/same.sh"
sed -i "s#^INSTALLER_URL=.*#INSTALLER_URL=\"$OLDURL\"#; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES=\"false\"/" "$U/catalog.sh"
out="$(SHIM_SERVE=same bash "$U/catalog.sh" self-update </dev/null 2>&1)"; rc=$?
check "same version: only the address changes, no backup" '[ "$rc" -eq 0 ] && grep -qF "The installer is up to date. Its update address is now $NEWURL." <<< "$out" && grep -qxF "INSTALLER_URL=\"$NEWURL\"" "$U/catalog.sh" && ! ls "$U"/catalog.sh.bak-* >/dev/null 2>&1'
out="$(SHIM_SERVE=same bash "$U/catalog.sh" self-update </dev/null 2>&1)"
check "then: up to date" 'grep -q "The installer is up to date.$" <<< "$out"'

# 8. Settings in single quotes or without quotes are carried over
Q="$T/quotes"; mkdir -p "$Q"; cp "$NEW" "$Q/rn1-technology-catalog-installer.sh"
sed -i "0,/^TZ=/s#^TZ=.*#TZ='Asia/Singapore'#; 0,/^CATALOG_WEB_PORT=/s#^CATALOG_WEB_PORT=.*#CATALOG_WEB_PORT=9090#; 0,/^BASEURL=/s#^BASEURL=.*#BASEURL=\"https://catalog.example.com\"   \# public address#; 0,/^QUEUE_PREFIX=/s#^QUEUE_PREFIX=.*#QUEUE_PREFIX='rvc\$x'#; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES=\"false\"/" "$Q/rn1-technology-catalog-installer.sh"
out="$(bash "$Q/rn1-technology-catalog-installer.sh" self-update </dev/null 2>&1)"; rc=$?
check "quoted, unquoted and commented settings kept as bash reads them" '[ "$rc" -eq 0 ] && grep -qxF "TZ=\"Asia/Singapore\"" "$Q/rn1-technology-catalog-installer.sh" && grep -qxF "CATALOG_WEB_PORT=\"9090\"" "$Q/rn1-technology-catalog-installer.sh" && grep -qxF "BASEURL=\"https://catalog.example.com\"" "$Q/rn1-technology-catalog-installer.sh" && grep -qxF "QUEUE_PREFIX=\"rvc\\\$x\"" "$Q/rn1-technology-catalog-installer.sh"'

# 9. The default address of this version is the renamed file
check "default address is rn1-technology-catalog-installer.sh" 'grep -q "^INSTALLER_URL=\"$NEWURL\"$" "$NEW"'

# 10. A write that stops half way (disk full) is undone from the backup
if [ "$(uname -s)" = "Linux" ] && [ -d "/proc/$$/fd" ]; then
  W="$T/wfail"; mkdir -p "$W/bin"; cp "$NEW" "$W/rn1-technology-catalog-installer.sh"
  sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$W/rn1-technology-catalog-installer.sh"
  before="$(cksum < "$W/rn1-technology-catalog-installer.sh")"
  REAL_CAT="$(command -v cat)"
  cat > "$W/bin/cat" <<'EOF'
#!/usr/bin/env bash
# the first write into the installer stops after 1000 bytes
if [ ! -e "$CAT_FAILED" ] && [ "$(readlink -f "/proc/$$/fd/1")" = "$CAT_TARGET" ]; then
  touch "$CAT_FAILED"
  head -c 1000 -- "${@: -1}"
  echo "cat: write error: No space left on device" >&2
  exit 1
fi
exec "$REAL_CAT" "$@"
EOF
  chmod +x "$W/bin/cat"
  out="$(PATH="$W/bin:$PATH" REAL_CAT="$REAL_CAT" CAT_FAILED="$W/failed" CAT_TARGET="$(readlink -f "$W/rn1-technology-catalog-installer.sh")" bash "$W/rn1-technology-catalog-installer.sh" self-update </dev/null 2>&1)"; rc=$?
  check "failed write: installer restored, not reported as updated" '[ "$rc" -ne 0 ] && [ -e "$W/failed" ] && grep -q "it was restored from" <<< "$out" && ! grep -q "Installer updated" <<< "$out" && [ "$(cksum < "$W/rn1-technology-catalog-installer.sh")" = "$before" ]'
fi

# 11. /tmp full after the download: the settings cannot be carried over, so nothing is replaced
#     (on the command line and with option 22, which runs the update without errexit)
F="$T/fulltmp"; mkdir -p "$F/bin"
REAL_MKTEMP="$(command -v mktemp)"
cat > "$F/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
# temp files work until the installer was downloaded, then fail like on a full /tmp
if [ "$(cat "$SRV/urls" 2>/dev/null | wc -l)" -gt "$URLS_BEFORE" ]; then
  echo "mktemp: failed to create file via template: No space left on device" >&2
  exit 1
fi
exec "$REAL_MKTEMP" "$@"
EOF
chmod +x "$F/bin/mktemp"
for how in cli menu; do
  cp "$NEW" "$F/rn1-technology-catalog-installer.sh"
  sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/; 0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="9090"/' "$F/rn1-technology-catalog-installer.sh"
  before="$(cksum < "$F/rn1-technology-catalog-installer.sh")"
  ub="$(cat "$SRV/urls" 2>/dev/null | wc -l)"
  if [ "$how" = cli ]; then
    out="$(PATH="$F/bin:$PATH" REAL_MKTEMP="$REAL_MKTEMP" URLS_BEFORE="$ub" bash "$F/rn1-technology-catalog-installer.sh" self-update </dev/null 2>&1)"; rc=$?
    check "full /tmp (command line): not updated, settings untouched" '[ "$rc" -ne 0 ] && grep -q "Cannot carry the setting .* over (disk full?) - not updated." <<< "$out" && ! grep -q "Installer updated" <<< "$out" && [ "$(cksum < "$F/rn1-technology-catalog-installer.sh")" = "$before" ]'
  else
    out="$(printf '22\n\n\n0\n' | PATH="$F/bin:$PATH" REAL_MKTEMP="$REAL_MKTEMP" URLS_BEFORE="$ub" bash "$F/rn1-technology-catalog-installer.sh" menu 2>&1)"
    check "full /tmp (option 22): not updated, settings untouched" 'grep -q "not updated." <<< "$out" && ! grep -q "Installer updated" <<< "$out" && [ "$(cksum < "$F/rn1-technology-catalog-installer.sh")" = "$before" ]'
  fi
done

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
