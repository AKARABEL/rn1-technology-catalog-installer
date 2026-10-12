#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/s"
rm -rf "$T"; mkdir -p "$T/bin" "$T/srv/daily" "$T/srv/full"
# these tests run Podman: CONTAINER_ENGINE names it (on a CI runner, detection would see its real Docker)
sed 's/^CONTAINER_ENGINE=""$/CONTAINER_ENGINE="podman"/' "$1" > "${T%/*}/podman-installer.sh"; NEW="${T%/*}/podman-installer.sh"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# the internet check (menu start, new installation, option 16, engine setup) has its own suite (run_network_tests)
export RN1_NET_CHECK=off
export LOG="$T/curl.log" SRV="$T/srv"
: > "$LOG"
VALID="ABCDEF0-1234567-89ABCDE-F012345"
NOSYNC="1111111-2222222-3333333-4444444"
LOCALADMIN="AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD"
LOCALSYNC="EEEEEEE-FFFFFFF-0000000-1111111"
export VALID NOSYNC LOCALADMIN LOCALSYNC

(cd "$T" && mkdir -p d && echo daily > d/x && tar -czf "$SRV/daily/2026-10-02.tar.gz" d && echo daily1 > d/x && tar -czf "$SRV/daily/2026-10-01.tar.gz" d && echo full > d/x && tar -czf "$SRV/full/2026-09-28.tar.gz" d)
sum() { printf 'sha256:%s' "$(sha256sum "$1" | cut -d' ' -f1)"; }
size() { stat -c %s "$1"; }
cat > "$SRV/manifest.json" <<EOF
{"generatedAt":"2026-10-03T02:31:00Z","latestFullSnapshot":{"date":"2026-09-28","sizeBytes":$(size "$SRV/full/2026-09-28.tar.gz"),"checksum":"$(sum "$SRV/full/2026-09-28.tar.gz")","downloadPath":"full/2026-09-28.tar.gz","directDownloadUrl":"https://s3.example/x","regionUrls":{"eu":"https://s3.example/y"},"entityCounts":{"manufacturers":1}},
"dailyDeltas":[{"basedOnDate":"2026-09-30","includesEpochReplace":false,"date":"2026-10-01","sizeBytes":$(size "$SRV/daily/2026-10-01.tar.gz"),"checksum":"$(sum "$SRV/daily/2026-10-01.tar.gz")","downloadPath":"daily/2026-10-01.tar.gz","entityCounts":{"manufacturers":2}},
{"basedOnDate":"2026-10-01","includesEpochReplace":false,"date":"2026-10-02","sizeBytes":$(size "$SRV/daily/2026-10-02.tar.gz"),"checksum":"$(sum "$SRV/daily/2026-10-02.tar.gz")","downloadPath":"daily/2026-10-02.tar.gz","entityCounts":{"manufacturers":3}}],
"cumulativeDeltas":[]}
EOF

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$LOG"
out=/dev/stdout; fmt=""; url=""; cfg=""; method=GET; data=""; form=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -K) [ "$2" = "-" ] && cfg="$(cat)"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    -F) form="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -H|--connect-timeout|--retry|--retry-delay|--max-time|--proto) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ "$method" = GET ] && { [ -n "$form" ] || [ -n "$data" ]; }; then method=POST; fi
reply() { [ -n "$fmt" ] && printf '%s' "${fmt//%\{http_code\}/$1}"; exit 0; }
if [[ "$url" == http://localhost:* ]]; then
  auth="$(printf '%s' "$cfg" | sed -n 's/^header = "\(.*\)"$/\1/p')"
  tok=""; case "$auth" in *TOKEN123) tok=" token=1" ;; *TOKEN456) tok=" token=2" ;; esac
  echo "local $method ${url#http://localhost:*/} auth=${auth%% *}$tok" >> "$LOG"
  [ "${SHIM_LOCAL_DOWN:-}" = 1 ] && { printf '000'; exit 7; }
  path="/${url#http://localhost:*/}"
  polls="$(cat "$SRV/polls" 2>/dev/null || echo 0)"
  case "$auth" in
    "X-Api-Key: $LOCALADMIN"|"Authorization: Bearer TOKEN456") role=admin ;;
    # the access token of a login expires: SHIM_EXPIRE_AFTER progress polls
    "Authorization: Bearer TOKEN123") if [ -n "${SHIM_EXPIRE_AFTER:-}" ] && [ "$polls" -ge "$SHIM_EXPIRE_AFTER" ]; then role=none; else role=admin; fi ;;
    "X-Api-Key: $LOCALSYNC") role=sync ;;
    *) role=none ;;
  esac
  # the license check needs no login (run_license_tests checks a Catalog without a license)
  if [ "$path" = /v1/license/isValid ]; then printf 'true' > "$out"; reply 200; fi
  if [ "$path" = /v1/authentication/request ]; then
    body="$(cat "${data#@}")"; echo "$body" > "$SRV/login-body.json"
    if grep -q '"username":"admin"' <<< "$body" && grep -qF '"password":"p@ss\"w0rd"' <<< "$body"; then
      printf '{"access_token":"TOKEN123","refresh_token":"RTOKEN-1","expires_in":%s}' "${SHIM_TTL:-1800}" > "$out"; reply 200
    fi
    : > "$out"; reply 401
  fi
  # the refresh token comes in curl's stdin config (RefreshTokenWrapper), the new pair in the answer (the
  # Catalog gives a new refresh token near the end of the old one only; here the first renewal does)
  if [ "$path" = /v1/authentication/refresh ]; then
    rt="$(printf '%s' "$cfg" | sed -n 's/^data-binary = "{\\"refreshToken\\":\\"\(.*\)\\"}"$/\1/p')"
    echo "local refresh $(case "$rt" in (RTOKEN-1|RTOKEN-2) echo known ;; (*) echo unknown ;; esac)" >> "$LOG"
    if [ "$method" = POST ] && { [ "$rt" = RTOKEN-1 ] || [ "$rt" = RTOKEN-2 ]; } && [ -z "${SHIM_REFRESH_FAIL:-}" ]; then
      printf '{"access_token":"TOKEN456","refresh_token":"RTOKEN-2","expires_in":%s}' "${SHIM_TTL:-1800}" > "$out"; reply 200
    fi
    printf '"Invalid refresh token."' > "$out"; reply 400
  fi
  [ "$role" = none ] && { : > "$out"; reply 401; }
  case "$method $path" in
    "GET /v1/databaseconfiguration/synchronization")
      [ "$role" = admin ] || { : > "$out"; reply 403; }
      if [ -n "${SHIM_NEW_CATALOG:-}" ]; then : > "$out"; reply 204; fi
      if [ -n "${SHIM_REFUSE_ADMIN:-}" ]; then : > "$out"; reply 403; fi
      printf '{"parentInstanceUrl":"","parentInstanceKey":"","proxyInfo":{"address":"proxy:3128"}}' > "$out"; reply 200 ;;
    "POST /v1/databaseconfiguration/synchronization")
      cat "${data#@}" > "$SRV/sync-settings.json"; : > "$out"; reply 204 ;;
    "POST /v1/synchronization/snapshot")
      echo "$form" > "$SRV/upload-form.txt"; echo "$form" >> "$SRV/uploads.log"
      if [ -n "${SHIM_STORE_SECS:-}" ]; then
        f="${form#file=@}"; f="${f%%;*}"
        while IFS= read -r -n 4096 _; do :; done < "$f"
        sleep "$SHIM_STORE_SECS"
      fi
      echo 0 > "$SRV/polls"; echo 0 > "$SRV/pct"; echo op-1 > "$SRV/opid"
      printf '{"operationId":"op-1","status":"accepted"}' > "$out"; reply 202 ;;
    "POST /v1/synchronization/synchronize")
      echo 0 > "$SRV/polls"; echo 0 > "$SRV/pct"; echo op-2 > "$SRV/opid"
      printf '{"operationId":"op-2"}' > "$out"; reply 202 ;;
    # the progress of the synchronization history, a bare number: SHIM_PROGRESS, one value per poll
    "GET /v1/synchronizationHistory/progress/$(cat "$SRV/opid" 2>/dev/null)")
      n=$((polls + 1)); echo "$n" > "$SRV/polls"
      set -- ${SHIM_PROGRESS:-40 100}; if [ "$n" -le $# ]; then p="${!n}"; else p="${!#}"; fi
      echo "$p" > "$SRV/pct"; printf '%s' "$p" > "$out"; reply 200 ;;
    "GET /v1/synchronizationHistory/lastSynchronizationHistory")
      p="$(cat "$SRV/pct" 2>/dev/null || echo 0)"
      if [ -n "${SHIM_OTHER_SYNC:-}" ]; then
        printf '{"synchronizationHistoryId":"h-7","startDate":"2026-10-11T11:58:02.112Z","synchronizationStatus":"2","synchronizationType":"2","progress":63,"instanceUrl":"rayventorycatalog.raynet.de","operationId":"op-other"}' > "$out"
      elif [ "$p" -lt 100 ]; then
        printf '{"synchronizationHistoryId":"h-1","startDate":"2026-10-10T02:00:00Z","endDate":"2026-10-10T03:10:00Z","synchronizationStatus":"3","synchronizationType":"1","progress":100,"operationId":"op-0"}' > "$out"
      elif [ "${SHIM_OP_RESULT:-finished}" = failed ]; then
        printf '{"synchronizationHistoryId":"h-2","startDate":"2026-10-11T12:00:00Z","endDate":"2026-10-11T12:40:00Z","synchronizationStatus":"4","synchronizationType":"1","progress":100,"summaryDetails":"Error while applying the snapshot: No space left on device, 0 bytes free","operationId":"%s"}' "$(cat "$SRV/opid")" > "$out"
      else
        printf '{"synchronizationHistoryId":"h-2","startDate":"2026-10-11T12:00:00Z","endDate":"2026-10-11T12:40:00Z","synchronizationStatus":"3","synchronizationType":"1","progress":100,"summaryDetails":"Synchronized, \\"full\\" snapshot","operationId":"%s"}' "$(cat "$SRV/opid")" > "$out"
      fi
      reply 200 ;;
    # only Admin and SiteAdmin may read operations; the progress there stays 0.0 during an import
    "GET /v1/operation/recent?type=index&maxItems=1")
      [ "$role" = admin ] || { : > "$out"; reply 403; }
      printf '[{"operationId":"op-9","type":"index","name":"Index","progress":0.0,"status":"started","message":"Starting..."}]' > "$out"; reply 200 ;;
    "GET /v1/operation/$(cat "$SRV/opid" 2>/dev/null)")
      [ "$role" = admin ] || { : > "$out"; reply 403; }
      p="$(cat "$SRV/pct" 2>/dev/null || echo 0)"
      if [ -n "${SHIM_OP_CANCEL:-}" ]; then st=cancelled; pr=0.0; msg="The operation was cancelled, because synchronization is currently being processed."
      elif [ "$p" -lt 100 ]; then st=started; pr=0.0; msg="Starting..."
      elif [ "${SHIM_OP_RESULT:-finished}" = failed ]; then st=failed; pr=100.0; msg="Operation [$(cat "$SRV/opid")] failed: No space left on device, 0 bytes free"
      else st=finished; pr=100.0; msg="Operation finished."; fi
      [ -n "${SHIM_STATUS_CASE:-}" ] && st="$(printf '%s' "${st:0:1}" | tr a-z A-Z)${st:1}"
      printf '{"operationId":"%s","type":"Synchronize","name":"Synchronization","payload":"{\\"SynchronizationType\\":1,\\"File\\":\\"dbSnapshot.tar.gz\\"}","progress":%s,"status":"%s","message":"%s"}' "$(cat "$SRV/opid")" "$pr" "$st" "$msg" > "$out"
      reply 200 ;;
  esac
  : > "$out"; reply 404
fi
key="$(printf '%s' "$cfg" | sed -n 's/^header = "X-Api-Key: \(.*\)"$/\1/p')"
echo "cfg-key-present=$([ -n "$key" ] && echo yes || echo no)" >> "$LOG"
path="${url#https://rayventorycatalog.raynet.de}"
code=200
if [ "${SHIM_OFFLINE:-}" = 1 ]; then printf '000'; exit 7; fi
if [ "${SHIM_OLD_SERVER:-}" = 1 ] && [[ "$path" == /v3/* ]]; then : > "$out"; reply 404; fi
if [ "$key" = "$NOSYNC" ]; then code=403; : > "$out"
elif [ "$key" != "$VALID" ]; then code=401; printf '{"title":"Authentication Error","status":401,"detail":"Api key is not registered in the database."}' > "$out"
else
  case "$path" in
    /v3/synchronization/manifest) if [ "${SHIM_NO_MANIFEST:-}" = 1 ]; then code=404; : > "$out"; else cat "${SHIM_MANIFEST:-$SRV/manifest.json}" > "$out"; fi ;;
    /v3/synchronization/snapshot/*) f="$SRV/${path#/v3/synchronization/snapshot/}"; if [ -f "$f" ]; then cat "$f" > "$out"; [ "${SHIM_CORRUPT:-}" = 1 ] && echo x >> "$out"; else code=404; : > "$out"; fi ;;
    *) code=404; : > "$out" ;;
  esac
fi
[ -n "$fmt" ] && printf '%s' "${fmt//%\{http_code\}/$code}"
exit 0
EOF
chmod +x "$T/bin/curl"
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
# Fake rootful Podman with 32 GB of memory and no containers (a CI runner's own Podman would bring its memory
# into the import); RN1_COMPOSE_PROVIDER names no file, so there is no "podman compose" (the upload limit
# comes from the settings). Calls it does not know are logged to $UNH.
export UNH="$T/unhandled.log" RN1_COMPOSE_PROVIDER="$T/no-compose"
: > "$UNH"
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  --version) echo "podman version 5.7.0" ;;
  info) ;;
  "info --format {{.Host.Security.Rootless}}") echo false ;;
  "info --format {{.Host.MemTotal}}") echo "${SHIM_MEMTOTAL:-34359738368}" ;;
  "ps -aq --filter label=com.docker.compose.project="*|"ps -aq --filter label=com.docker.compose.service="*) ;;
  "volume ls -q --filter label=com.docker.compose.project="*) ;;
  "volume inspect --format {{.Mountpoint}} "*) echo "Error: no such volume" >&2; exit 125 ;;
  *) echo "UNHANDLED podman $*" >> "$UNH"; echo "Error: fake podman does not know: $*" >&2; exit 125 ;;
esac
EOF
chmod +x "$T/bin/podman"
export PATH="$T/bin:$PATH"
D="$T/inst"; mkdir -p "$D"; cp "$NEW" "$D/rn1-technology-catalog-installer.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/rn1-technology-catalog-installer.sh"
K="$D/.catalog_api_key"
probe="$T/p"; : > "$probe"; chmod 600 "$probe"; if [ "$(stat -c %a "$probe")" = 600 ]; then CHMOD_WORKS=yes; else CHMOD_WORKS=no; fi

# 1. Option 17 without a stored key: wrong key, then valid key, save, download the latest daily (3)
out="$(printf "17\nWRONGKEY\n$VALID\ny\n3\n\n0\n" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "wrong key rejected with server detail" 'grep -q "not valid: Api key is not registered in the database." <<< "$out"'
check "valid key accepted after retry" 'grep -q "The API key is valid." <<< "$out"'
check "key saved with mode 600" '[ -f "$K" ] && [ "$(tr -d "\r\n" < "$K")" = "$VALID" ] && { [ "$(stat -c %a "$K")" = 600 ] || [ "$CHMOD_WORKS" = no ]; }'
check "daily snapshot listed with based-on date" 'grep -q "Latest daily snapshot   2026-10-02" <<< "$out" && grep -q "applies on top of 2026-10-01" <<< "$out"'
check "newest daily downloaded and verified" '[ -f "$D/snapshots/2026-10-02-daily.tar.gz" ] && grep -q "sha256 verified" <<< "$out" && [ ! -e "$D/snapshots/2026-10-02-daily.tar.gz.part" ]'
check "key never on a command line" '! grep "^curl " "$LOG" | grep -q -e "$VALID" -e WRONGKEY'
check "key passed via curl config on stdin" 'grep -q "cfg-key-present=yes" "$LOG" && grep -q -- "-K -" "$LOG"'
check "https only, no redirects followed" 'grep "^curl " "$LOG" | grep -q -- "--proto =https" && ! grep "^curl " "$LOG" | grep -q -e " -L" -e "--location"'

# 2. Stored key: full snapshot via the menu
out="$(printf '17\n4\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "stored key tested and used" 'grep -q "Testing the stored API key ABCDEF0...2345" <<< "$out"'
check "full snapshot downloaded" '[ -f "$D/snapshots/2026-09-28-full.tar.gz" ]'

# 3. Same file again -> already downloaded
out="$(printf '17\n3\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "already downloaded detected" 'grep -q "Already downloaded" <<< "$out"'

# 4. Corrupt download -> removed, error
rm -f "$D/snapshots/2026-10-02-daily.tar.gz"
out="$(printf '17\n3\n\n0\n' | SHIM_CORRUPT=1 bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "checksum mismatch rejected and cleaned" 'grep -q "Checksum mismatch" <<< "$out" && [ ! -e "$D/snapshots/2026-10-02-daily.tar.gz" ] && [ ! -e "$D/snapshots/2026-10-02-daily.tar.gz.part" ]'

# 5. CLI snapshot (stored key, non-interactive)
out="$(bash "$D/rn1-technology-catalog-installer.sh" snapshot daily </dev/null 2>&1)"; rc=$?
check "CLI snapshot daily" '[ "$rc" -eq 0 ] && [ -f "$D/snapshots/2026-10-02-daily.tar.gz" ]'

# 6. API key menu: masked display, show full, test, delete
out="$(printf '18\n1\ny\n3\n0\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "menu shows masked key" 'grep -q "Online catalog (https://rayventorycatalog.raynet.de): ABCDEF0...2345" <<< "$out"'
check "show full key after confirmation" 'grep -q "   $VALID" <<< "$out"'
check "test stored key" 'grep -q "The API key is valid." <<< "$out"'
out="$(printf '18\n4\ny\n0\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "delete key" '[ ! -e "$K" ] && grep -q "Key deleted." <<< "$out"'

# 7. Add key via menu: forbidden key not saved; valid key saved after immediate test
out="$(printf "18\n2\n$NOSYNC\n\n0\n\n0\n" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "key without sync role rejected, not saved" 'grep -q "no synchronization permission" <<< "$out" && [ ! -e "$K" ]'
out="$(printf "18\n2\n$(printf '%s' "$VALID" | tr 'A-F' 'a-f')\ny\n0\n\n0\n" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "lower-case key normalized, tested and saved" '[ "$(tr -d "\r\n" < "$K")" = "$VALID" ] && grep -q "API key saved." <<< "$out"'

# 8. Do not save when declined
rm -f "$K"
out="$(printf "17\n$VALID\nn\n0\n\n0\n" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "declined save leaves no key file" '[ ! -e "$K" ]'

# 9. CLI without key; offline; no manifest yet
out="$(bash "$D/rn1-technology-catalog-installer.sh" snapshot </dev/null 2>&1)"; rc=$?
check "CLI without stored key fails" '[ "$rc" -ne 0 ] && grep -q "No API key stored" <<< "$out"'
api_key_save_file() { printf '%s\n' "$VALID" > "$K"; chmod 600 "$K"; }
api_key_save_file
out="$(SHIM_OFFLINE=1 bash "$D/rn1-technology-catalog-installer.sh" snapshot </dev/null 2>&1)"; rc=$?
check "offline: clear message, no 'invalid'" '[ "$rc" -ne 0 ] && grep -q "could not be checked" <<< "$out" && ! grep -q "not valid" <<< "$out"'
out="$(SHIM_NO_MANIFEST=1 bash "$D/rn1-technology-catalog-installer.sh" snapshot </dev/null 2>&1)"; rc=$?
check "no manifest yet: valid key, nothing to download" '[ "$rc" -eq 0 ] && grep -q "has no snapshot yet" <<< "$out"'

out="$(SHIM_OLD_SERVER=1 bash "$D/rn1-technology-catalog-installer.sh" snapshot </dev/null 2>&1)"; rc=$?
check "server without v3 API: not reported as valid" '[ "$rc" -ne 0 ] && grep -q "offers no snapshot API" <<< "$out" && ! grep -q "The API key is valid" <<< "$out"'

# 10. Key file is not part of an offline bundle copy and not in help as plain text
check "help lists snapshot command" 'bash "$D/rn1-technology-catalog-installer.sh" help | grep -q "snapshot \[daily|full\]"'

# 11. Import a downloaded snapshot: local key asked, tested, saved; upload; progress followed
LK="$D/.catalog_local_api_key"; rm -f "$LK" "$SRV/polls"; : > "$LOG"
out="$(printf "19\n1\ny\n1\n$LOCALSYNC\ny\n\n0\n" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "local key tested (non-admin) and saved" 'grep -q "Access to the local catalog works (no administrator rights)." <<< "$out" && [ "$(tr -d "\r\n" < "$LK")" = "$LOCALSYNC" ]'
check "snapshot uploaded as gzip file part" 'grep -q "^file=@.*2026-10-02-daily.tar.gz;type=application/gzip$" "$SRV/upload-form.txt"'
check "operation followed until finished" 'grep -q "Import finished." <<< "$out" && [ "$(cat "$SRV/polls")" -ge 2 ]'
check "local key never on a command line" '! grep "^curl " "$LOG" | grep -q "$LOCALSYNC"'

# 12. CLI import with the stored local key; failed operation reported
rm -f "$SRV/polls"
out="$(SHIM_OP_RESULT=failed bash "$D/rn1-technology-catalog-installer.sh" import "$D/snapshots/2026-09-28-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "CLI import, a key without the right to read operations: the failed import from its synchronization history, whole text" '[ "$rc" -ne 0 ] && grep -q "Import failed: Error while applying the snapshot: No space left on device, 0 bytes free$" <<< "$out" && grep -q "^local GET v1/operation/op-1 auth=X-Api-Key:$" "$LOG"'
out="$(bash "$D/rn1-technology-catalog-installer.sh" import /nonexistent.tar.gz </dev/null 2>&1)"; rc=$?
check "CLI import: missing file" '[ "$rc" -ne 0 ] && grep -q "File not found" <<< "$out"'
rm -f "$SRV/polls"
out="$(SHIM_STORE_SECS=4 bash "$D/rn1-technology-catalog-installer.sh" import "$D/snapshots/2026-09-28-full.tar.gz" </dev/null 2>&1)"; rc=$?
if [ -r /proc/self/io ]; then
  check "CLI import: after the last byte the Catalog stores the snapshot - said, then the import followed" '[ "$rc" -eq 0 ] && grep -q "Upload finished - the Catalog now copies the snapshot into its file storage (MinIO)" <<< "$out" && grep -q "Import finished." <<< "$out"'
else
  # no /proc/PID/io (WSL, macOS): the bytes sent cannot be seen, upload and storing are one step
  check "CLI import without byte counts: one step, then the import followed" '[ "$rc" -eq 0 ] && ! grep -q "Upload finished" <<< "$out" && grep -q "Import finished." <<< "$out"'
fi
rm -f "$SRV/polls"
out="$(bash "$D/rn1-technology-catalog-installer.sh" import "$D/snapshots/2026-09-28-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "CLI import: a quick answer has no storing step" '[ "$rc" -eq 0 ] && ! grep -q "Upload finished" <<< "$out"'
out="$(SHIM_LOCAL_DOWN=1 bash "$D/rn1-technology-catalog-installer.sh" import "$D/snapshots/2026-09-28-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "CLI import: stack down -> clear message" '[ "$rc" -ne 0 ] && grep -q "not reachable at http://localhost:8080" <<< "$out"'

# 13. Self-sync: needs admin; admin login with special characters; settings merged, sync started
rm -f "$LK" "$SRV/polls" "$SRV/sync-settings.json"; : > "$LOG"
out="$(printf '20\n2\nadmin\np@ss"w0rd\ny\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "admin login with quote in password" 'grep -q "Logged in to the local catalog." <<< "$out" && grep -qF "\"password\":\"p@ss\\\"w0rd\"" "$SRV/login-body.json"'
check "password never on a command line" '! grep "^curl " "$LOG" | grep -q "p@ss"'
check "sync settings: only the online URL and its key are sent, the Catalog keeps its proxy" 'grep -q "\"parentInstanceUrl\": *\"https://rayventorycatalog.raynet.de\"" "$SRV/sync-settings.json" && grep -q "\"parentInstanceKey\": *\"$VALID\"" "$SRV/sync-settings.json" && ! grep -qi "proxy" "$SRV/sync-settings.json" && [ "$(tr -cd , < "$SRV/sync-settings.json")" = "," ]'
check "synchronization started and followed" 'grep -q "now synchronizes from https://rayventorycatalog.raynet.de" <<< "$out" && grep -q "Synchronization finished." <<< "$out"'
out="$(printf "20\n1\n$LOCALSYNC\nn\n\n0\n" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "self-sync refused without admin rights" 'grep -q "needs a local administrator" <<< "$out"'
rm -f "$LK" "$SRV/polls" "$SRV/sync-settings.json"
out="$(printf '20\n2\nadmin\np@ss"w0rd\ny\n\n0\n' | SHIM_NEW_CATALOG=1 bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "self-sync on a new catalog (no settings yet, HTTP 204): the administrator is one, the settings are written" '! grep -q "needs a local administrator" <<< "$out" && grep -q "now synchronizes from https://rayventorycatalog.raynet.de" <<< "$out" && grep -q "\"parentInstanceUrl\": *\"https://rayventorycatalog.raynet.de\"" "$SRV/sync-settings.json" && grep -q "\"parentInstanceKey\": *\"$VALID\"" "$SRV/sync-settings.json"'
out="$(printf '20\n2\nadmin\np@ss"w0rd\n\n0\n' | SHIM_REFUSE_ADMIN=1 bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "self-sync, a login refused (HTTP 403): the role named (no license would be 520)" 'grep -q "refused to change the synchronization settings (HTTP 403)" <<< "$out" && grep -q "The user needs the Admin role" <<< "$out" && ! grep -q -e "no valid" -e "license yet" <<< "$out"'

# 14. Key menu: local key add / test / delete
rm -f "$LK"
out="$(printf "18\n6\n1\n$LOCALADMIN\ny\n7\n8\ny\n0\n\n0\n" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "local key added (admin), tested and deleted" 'grep -q "Local API key saved." <<< "$out" && grep -q "works (administrator)" <<< "$out" && grep -q "Key deleted." <<< "$out" && [ ! -e "$LK" ]'

# 15. v3 chain: the full snapshot and every change up to today, in the order to apply them
CS="$SRV/c"; mkdir -p "$CS"
(cd "$T" && for n in full-2026-10-04 daily-2026-10-05 daily-2026-10-02 c7-2026-10-04 c30-2026-10-01; do echo "$n" > d/x; tar -czf "$CS/$n.tar.gz" d; done)
entry() { printf '"sizeBytes":%s,"checksum":"%s","downloadPath":"c/%s"' "$(size "$CS/$1")" "$(sum "$CS/$1")" "$1"; }
cat > "$T/chain.json" <<EOF
{"generatedAt":"2026-10-05T02:31:00Z","latestFullSnapshot":{"date":"2026-10-04",$(entry full-2026-10-04.tar.gz)},
"dailyDeltas":[{"basedOnDate":"2026-10-04","includesEpochReplace":false,"date":"2026-10-05",$(entry daily-2026-10-05.tar.gz)},
{"basedOnDate":"2026-10-01","includesEpochReplace":false,"date":"2026-10-02",$(entry daily-2026-10-02.tar.gz)}],
"cumulativeDeltas":[{"window":"7d","rangeStart":"2026-09-27","rangeEnd":"2026-10-04",$(entry c7-2026-10-04.tar.gz)},
{"window":"30d","rangeStart":"2026-09-01","rangeEnd":"2026-10-01",$(entry c30-2026-10-01.tar.gz)}]}
EOF
export SHIM_MANIFEST="$T/chain.json"
SN="$D/snapshots"; FULLCHAIN="$SN/chain-2026-10-04-full-to-2026-10-05.tsv"; SINCECHAIN="$SN/chain-2026-10-01-cumulative-30d-to-2026-10-05.tsv"
order() { cut -f1,2 "$1" | tr '\t\n' ' /'; }
: > "$LOG"
out="$(bash "$D/rn1-technology-catalog-installer.sh" snapshot chain </dev/null 2>&1)"; rc=$?
check "chain: full + newest daily downloaded" '[ "$rc" -eq 0 ] && [ -f "$SN/2026-10-04-full.tar.gz" ] && [ -f "$SN/2026-10-05-daily.tar.gz" ]'
check "chain: no weekly or monthly needed" '! grep -q -e "c/c7-" -e "c/c30-" "$LOG"'
check "chain file: full, then daily" '[ "$(order "$FULLCHAIN")" = "full 2026-10-04/daily 2026-10-05/" ]'
check "chain: order shown, no plan file left" 'grep -q "1. 2026-10-04-full.tar.gz" <<< "$out" && grep -q "2. 2026-10-05-daily.tar.gz" <<< "$out" && ! ls "$SN"/plan-*.tsv >/dev/null 2>&1'

: > "$LOG"
out="$(bash "$D/rn1-technology-catalog-installer.sh" snapshot since 2026-09-01 </dev/null 2>&1)"; rc=$?
check "since: monthly, weekly, daily in order" '[ "$rc" -eq 0 ] && [ "$(order "$SINCECHAIN")" = "cumulative-30d 2026-10-01/cumulative-7d 2026-10-04/daily 2026-10-05/" ]'
check "since: the weekly replaces the shorter daily" '! grep -q "c/daily-2026-10-02" "$LOG"'
check "since: present file reused, full chain kept" 'grep -q "Already downloaded: .*2026-10-05-daily.tar.gz" <<< "$out" && [ -f "$FULLCHAIN" ]'
rm -f "$SN/2026-10-04-cumulative-7d.tar.gz"
out="$(SHIM_CORRUPT=1 bash "$D/rn1-technology-catalog-installer.sh" snapshot since 2026-10-03 </dev/null 2>&1)"; rc=$?
check "chain stops at a broken file, rc!=0" '[ "$rc" -ne 0 ] && grep -q "Stopped at weekly 2026-10-04" <<< "$out" && [ ! -e "$SN/chain-2026-10-04-cumulative-7d-to-2026-10-05.tsv" ] && ! ls "$SN"/plan-*.tsv >/dev/null 2>&1'
out="$(bash "$D/rn1-technology-catalog-installer.sh" snapshot since 2026-10-03 </dev/null 2>&1)"; rc=$?
check "since: weekly overlapping the date is used" '[ "$rc" -eq 0 ] && [ "$(order "$SN/chain-2026-10-04-cumulative-7d-to-2026-10-05.tsv")" = "cumulative-7d 2026-10-04/daily 2026-10-05/" ]'
out="$(bash "$D/rn1-technology-catalog-installer.sh" snapshot since 2026-08-01 </dev/null 2>&1)"; rc=$?
check "since: gap before the oldest delta reported" '[ "$rc" -ne 0 ] && grep -q "No snapshot builds on 2026-08-01" <<< "$out"'
out="$(bash "$D/rn1-technology-catalog-installer.sh" snapshot since 2026-10-05 </dev/null 2>&1)"; rc=$?
check "since: nothing newer -> up to date" '[ "$rc" -eq 0 ] && grep -q "is up to date" <<< "$out"'
out="$(bash "$D/rn1-technology-catalog-installer.sh" snapshot since 01.09.2026 </dev/null 2>&1)"; rc=$?
check "since: date format checked" '[ "$rc" -ne 0 ] && grep -q "YYYY-MM-DD" <<< "$out"'

# 16. The chooser: chain is the default; the chain is offered for import
out="$(printf '17\n\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "chooser: chain default with its contents" 'grep -q "Full + all changes up to today" <<< "$out" && grep -q "full 2026-10-04 + 1 delta(s)" <<< "$out"'
check "chooser: manifest summary" 'grep -q "2 daily" <<< "$out" && grep -q "1 weekly" <<< "$out" && grep -q "1 monthly" <<< "$out"'
check "chooser: import of the whole chain offered" 'grep -q "Import them later with option 19 (it offers the whole chain)." <<< "$out"'
out="$(printf '17\n2\n2026-09-01\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "chooser: changes since a date" 'grep -q "3 snapshots downloaded" <<< "$out"'

# 17. Import of a chain: one upload after the other, each after the previous import finished
printf '%s\n' "$LOCALSYNC" > "$LK"; chmod 600 "$LK"
rm -f "$SRV/polls"; : > "$SRV/uploads.log"; : > "$LOG"
touch "$FULLCHAIN"
out="$(printf '19\n1\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "import menu lists the chain first" 'grep -q "Chain up to 2026-10-05" <<< "$out"'
check "chain imported in order" '[ "$(grep -c . "$SRV/uploads.log")" -eq 2 ] && head -n 1 "$SRV/uploads.log" | grep -q "2026-10-04-full.tar.gz" && tail -n 1 "$SRV/uploads.log" | grep -q "2026-10-05-daily.tar.gz" && grep -q "All 2 snapshots imported." <<< "$out"'
check "next upload only after the import finished" '[ "$(grep -E "^local (POST v1/synchronization/snapshot|GET v1/synchronizationHistory/progress)" "$LOG" | awk "{ printf (\$2 == \"POST\") ? \"U\" : \"P\" }")" = "UPPUPP" ]'
rm -f "$SRV/polls"; : > "$SRV/uploads.log"
out="$(SHIM_OP_RESULT=failed bash "$D/rn1-technology-catalog-installer.sh" import-chain "$SINCECHAIN" </dev/null 2>&1)"; rc=$?
check "chain import stops at the first failure" '[ "$rc" -ne 0 ] && grep -q "Import stopped at 2026-10-01-cumulative-30d.tar.gz" <<< "$out" && [ "$(grep -c . "$SRV/uploads.log")" -eq 1 ]'
out="$(bash "$D/rn1-technology-catalog-installer.sh" import-chain "$SN/none.tsv" </dev/null 2>&1)"; rc=$?
check "import-chain without a chain file" '[ "$rc" -ne 0 ] && grep -q "No downloaded chain" <<< "$out"'
rm -f "$SN/2026-10-04-cumulative-7d.tar.gz"
out="$(bash "$D/rn1-technology-catalog-installer.sh" import-chain "$SINCECHAIN" </dev/null 2>&1)"; rc=$?
check "missing chain file found before any upload" '[ "$rc" -ne 0 ] && grep -q "2026-10-04-cumulative-7d.tar.gz of the chain is missing" <<< "$out" && [ "$(grep -c . "$SRV/uploads.log")" -eq 1 ]'

# 18. Upload limit: Catalog 25.x has a fixed 10 GB limit, newer versions use SYNC_MAX_UPLOAD (Catalog 25.4
#     named here: the default is the newest Catalog of the release)
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/' "$D/rn1-technology-catalog-installer.sh"
printf 'SYNC_MAX_UPLOAD=100\n' > "$D/.env"; rm -f "$SRV/polls"
out="$(bash "$D/rn1-technology-catalog-installer.sh" import "$SN/2026-10-04-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "25.x: SYNC_MAX_UPLOAD not used (fixed 10 GB)" '[ "$rc" -eq 0 ] && grep -q "Import finished." <<< "$out"'
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.0.100"/' "$D/rn1-technology-catalog-installer.sh"
out="$(bash "$D/rn1-technology-catalog-installer.sh" import "$SN/2026-10-04-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "26.x: file above SYNC_MAX_UPLOAD refused before the upload" '[ "$rc" -ne 0 ] && grep -q "accepts at most 100 B per upload" <<< "$out" && grep -q "Raise SYNC_MAX_UPLOAD" <<< "$out"'
printf 'SYNC_MAX_UPLOAD=1KB\n' > "$D/.env"
out="$(bash "$D/rn1-technology-catalog-installer.sh" import "$SN/2026-10-04-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "26.x: size units understood" '[ "$rc" -eq 0 ]'
rm -f "$D/.env"; sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/' "$D/rn1-technology-catalog-installer.sh"

# 19. Following an import: the progress of its synchronization history, the operation (administrators
# only), the steps in the log of catalog-web; an expired login is renewed; the job view shows the steps
E="$T/eng"; mkdir -p "$E" "$T/tmp"
export UNH="$T/unhandled.log" ENGLOG="$T/engine.log"; : > "$UNH"; : > "$ENGLOG"
cat > "$E/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$ENGLOG"
bad() { echo "UNHANDLED podman $*" >> "$UNH"; echo "fake podman: not handled: $*" >&2; exit 125; }
case "${1:-}" in
  --version) [ $# -eq 1 ] || bad "$@"; echo "podman version 5.7.0" ;;
  # the memory before an import: 32 GB
  info) [ "$*" = "info --format {{.Host.MemTotal}}" ] || bad "$@"; echo 34359738368 ;;
  compose)
    shift
    [ "${PODMAN_COMPOSE_PROVIDER:-}" = "$RN1_COMPOSE_PROVIDER" ] || bad compose "$@" "(PODMAN_COMPOSE_PROVIDER=${PODMAN_COMPOSE_PROVIDER:-unset})"
    while [ $# -gt 0 ]; do case "$1" in -p|--env-file|-f) shift 2 ;; *) break ;; esac; done
    [ "$*" = "ps -q catalog-web" ] || bad compose "$@"
    echo id-catalog-web ;;
  container)
    [ "$*" = "container inspect --format {{.Config.Image}} id-catalog-web" ] || bad "$@"
    echo "docker.io/raynetgmbh/rayventory-catalog:25.4.4191.133" ;;
  # the menu looks for the containers of the stack
  ps)
    case "$*" in
      "ps -aq --filter label=com.docker.compose.project=inst"|"ps -aq --filter label=com.docker.compose.service=catalog-web") ;;
      *) bad "$@" ;;
    esac ;;
  volume)
    [ "${2:-}" = inspect ] || bad "$@"
    echo "Error: no such volume ${!#}" >&2; exit 125 ;;
  # the log of catalog-web with the time stamps of the engine, whose clock is not the one of this host: the
  # lines before #UPLOAD were there before the upload, SHIM_LOG_LINES more come with every progress poll.
  # --since takes only a time stamp the engine printed and, like Podman on macOS, gives its whole second.
  logs)
    f="$SRV/${SHIM_CATALOG_LOG:-catalog.log}"
    [ "${2:-}" = --timestamps ] || bad "$@"
    since=""; set -- "${@:3}"
    if [ "${1:-}" = --since ]; then since="${2:-}"; shift 2; fi
    { [ $# -eq 3 ] && [ "$1" = --tail ] && [[ "$2" =~ ^(100|5000)$ ]] && [ "$3" = id-catalog-web ]; } || bad logs "$@"
    pre="$(sed -n '/^#UPLOAD$/=' "$f")"
    lines="$(grep -v '^#UPLOAD$' "$f" | head -n $(( pre - 1 + $(cat "$SRV/polls" 2>/dev/null || echo 0) * ${SHIM_LOG_LINES:-8} )) | tail -n "$2")"
    if [ -n "$since" ]; then
      grep -q "^$since " <<< "$lines" || bad logs --since "$since" "(a time stamp the engine never printed)"
      awk -v s="${since:0:19}" 'substr($0, 1, 19) >= s' <<< "$lines"
    elif [ -n "$lines" ]; then
      printf '%s\n' "$lines"
    fi ;;
  *) bad "$@" ;;
esac
EOF
cat > "$E/docker-compose" <<'EOF'
#!/usr/bin/env bash
[ "$*" = version ] || { echo "UNHANDLED docker-compose $*" >> "$UNH"; exit 1; }
echo "Docker Compose version v2.39.4"
EOF
chmod +x "$E/podman" "$E/docker-compose"
# the log of a real import as the engine gives it: its time stamp, then log4net ("%date %5level
# %logger.%method : %message%newline %exception", so the next line starts with a space, the line after an
# exception not); the end of the import before, other operations, requests, an expired login and an
# exception of another logger between the steps, an exception of a step
S="Raynet.RayCatalog.Service.Services.DatabaseSnapshotDataTransferService.MoveNext"
L="Raynet.RayCatalog.Service.LegacyOperationBridge.MoveNext"
PRE="2026-10-11T10:49:58.100512Z  2026-10-11 13:49:58,100  INFO $S : Synchronized CachedVulnerabilities items
2026-10-11T10:49:59.200311Z  2026-10-11 13:49:59,200  INFO $S : Deleted temporary directory /tmp/0d1e/Synchronization/Cache/aaaa
2026-10-11T10:49:59.700Z  2026-10-11 13:49:59,700  INFO $L : Operation completed successfully (operation ID: op-0).
#UPLOAD
2026-10-11T10:49:59.900Z  2026-10-11 13:49:59,900 DEBUG Microsoft.AspNetCore.Hosting.Diagnostics.Log : Request finished HTTP/1.1 POST http://localhost:8080/v1/synchronization/snapshot - 202"
cat > "$SRV/catalog.log" <<EOF
$PRE
2026-10-11T10:50:12.004211Z  2026-10-11 13:50:12,004  INFO $L : Starting the synchronization operation of type 'SnapshotImport' (operation ID: op-1).
2026-10-11T10:50:12.01Z  2026-10-11 13:50:12,010  INFO $L : Starting the vulnerability recache operation (operation ID: op-7).
2026-10-11T10:50:13.1Z  2026-10-11 13:50:13,100 DEBUG Microsoft.AspNetCore.Hosting.Diagnostics.Log : Request starting HTTP/1.1 GET http://localhost:8080/v1/operation/op-1 - - -
2026-10-11T10:50:15.531Z  2026-10-11 13:50:15,531  INFO $S : Extracted archive to /tmp/2b1c9e/Synchronization/Cache/5f0e9a7c
2026-10-11T10:50:18.129Z  2026-10-11 13:50:18,129  INFO $S : Synchronized AppCompat items
2026-10-11T10:52:33.379Z  2026-10-11 13:52:33,379  INFO $S : Synchronized EXT_nist_cpe items
2026-10-11T11:05:01Z  2026-10-11 14:05:01,000  INFO Microsoft.AspNetCore.Authentication.JwtBearer.JwtBearerHandler.Log : Failed to validate the token.
2026-10-11T11:05:01Z  Microsoft.IdentityModel.Tokens.SecurityTokenExpiredException: IDX10223: Lifetime validation failed. The token is expired.
2026-10-11T11:05:01Z     at Microsoft.IdentityModel.Tokens.Validators.ValidateLifetime(Nullable notBefore)
2026-10-11T11:05:01.2Z 2026-10-11 14:05:01,002  INFO Microsoft.AspNetCore.Authorization.DefaultAuthorizationService.Log : Authorization failed. These requirements were not met: DenyAnonymousAuthorizationRequirement
2026-10-11T11:20:04.136Z  2026-10-11 14:20:04,136  INFO $S : Synchronized EXT_nist_cveV2 items
2026-10-11T11:20:05.067Z  2026-10-11 14:20:05,067  INFO $S : Synchronized EXT_nist_cwe items
2026-10-11T11:20:10.024Z  2026-10-11 14:20:10,024  INFO $S : Synchronized UNSPSC items
2026-10-11T11:20:10.027Z  2026-10-11 14:20:10,027  INFO $S : Synchronized EXT_meta items
2026-10-11T11:20:11.5Z  2026-10-11 14:20:11,500  WARN Raynet.RayCatalog.Service.Vulnerabilities.VulnerabilityCachingJob.MoveNext : Caching vulnerabilities failed, retrying in 60 s
2026-10-11T11:20:11.5Z  System.Net.Http.HttpRequestException: Name or service not known (services.nvd.nist.gov:443)
2026-10-11T11:20:11.5Z     at System.Net.Http.HttpConnectionPool.ConnectToTcpHostAsync(String host, Int32 port)
2026-10-11T11:20:12.987Z 2026-10-11 14:20:12,987  INFO $S : Synchronized Manufacturer items
2026-10-11T11:20:13.085Z  2026-10-11 14:20:13,085  INFO $S : Synchronized LicenseClassification items
2026-10-11T11:20:13.229Z  2026-10-11 14:20:13,229  INFO $S : Synchronized Function items
2026-10-11T11:20:13.293Z  2026-10-11 14:20:13,293  INFO $S : Updated metadata of LicenseClassification and Function items
2026-10-11T11:20:13.352Z  2026-10-11 14:20:13,352  INFO $S : Synchronized Relationship items
2026-10-11T11:20:28.275Z  2026-10-11 14:20:28,275  INFO $S : Synchronized Product items
2026-10-11T11:20:28.85Z  2026-10-11 14:20:28,850  INFO $S : Synchronized HardwareProduct items
2026-10-11T11:21:39.601Z  2026-10-11 14:21:39,601  INFO $S : Synchronized Version items
2026-10-11T11:21:43.53Z  2026-10-11 14:21:43,530  INFO $S : Synchronized HardwareModel items
2026-10-11T11:21:50.201Z  2026-10-11 14:21:50,201  WARN Raynet.RayCatalog.Service.Services.SnapshotServiceBase.MoveNext : Error while updating the synchronization progress.
2026-10-11T11:21:50.201Z  System.IO.IOException: No space left on device : '/tmp/minio_cache/dbSnapshot.tar.gz'
2026-10-11T11:21:50.201Z     at Raynet.RayCatalog.Service.Services.SnapshotServiceBase.UpdateProgress(ISynchronizationHistory history, Int32 progress)
2026-10-11T11:21:50.201Z  --- End of stack trace from previous location ---
2026-10-11T11:22:00Z 2026-10-11 14:22:00,000  INFO $S : Deleted temporary directory /tmp/2b1c9e/Synchronization/Cache/5f0e9a7c
2026-10-11T11:22:00.4Z  2026-10-11 14:22:00,400  INFO $L : Operation completed successfully (operation ID: op-1).
EOF
WANT="13:50:12 Starting the synchronization operation of type 'SnapshotImport' (operation ID: op-1).
13:50:15 Extracted archive
13:50:18 Synchronized AppCompat items
13:52:33 Synchronized EXT_nist_cpe items
14:20:04 Synchronized EXT_nist_cveV2 items
14:20:05 Synchronized EXT_nist_cwe items
14:20:10 Synchronized UNSPSC items
14:20:10 Synchronized EXT_meta items
14:20:12 Synchronized Manufacturer items
14:20:13 Synchronized LicenseClassification items
14:20:13 Synchronized Function items
14:20:13 Updated metadata of LicenseClassification and Function items
14:20:13 Synchronized Relationship items
14:20:28 Synchronized Product items
14:20:28 Synchronized HardwareProduct items
14:21:39 Synchronized Version items
14:21:43 Synchronized HardwareModel items
14:21:50 WARN Error while updating the synchronization progress.
14:21:50 System.IO.IOException: No space left on device : '.../dbSnapshot.tar.gz'
14:22:00 Deleted temporary directory .../5f0e9a7c
14:22:00 Operation completed successfully (operation ID: op-1)."
# an import that fails while the Catalog copies the snapshot, before it has a history record
cat > "$SRV/failed.log" <<EOF
$PRE
2026-10-11T10:50:12.004211Z  2026-10-11 13:50:12,004  INFO $L : Starting the synchronization operation of type 'SnapshotImport' (operation ID: op-1).
2026-10-11T11:02:40.5Z  2026-10-11 14:02:40,500 ERROR $L : Operation [op-1] failed: No space left on device : '/tmp/minio_cache/dbSnapshot.tar.gz'.
2026-10-11T11:02:40.5Z  System.IO.IOException: No space left on device : '/tmp/minio_cache/dbSnapshot.tar.gz'
2026-10-11T11:02:40.5Z     at Raynet.RayCatalog.Shared.Business.OperationStorageService.GetOperationFile(Guid operationId, String file)
EOF
# Catalog 26.x cancels an import while another synchronization runs (that line names no operation)
cat > "$SRV/cancelled.log" <<EOF
$PRE
2026-10-11T10:50:12.2Z 2026-10-11 13:50:12,200  INFO $L : The operation was cancelled, because synchronization is currently being processed.
EOF
# ... and one of another import in the second the log was marked in, before the upload
printf '%s\n' "$PRE" | sed "/operation ID: op-0/i 2026-10-11T10:49:59.650Z  2026-10-11 13:49:59,650  INFO $L : The operation was cancelled, because synchronization is currently being processed." > "$SRV/precancel.log"
# the step lines of an output (an exception has the time of the line it belongs to)
steps() { grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2} '; }
# allin TEXT LINES -> the start of every line of LINES is somewhere in TEXT (a job view wraps long lines)
allin() { local l; while IFS= read -r l; do grep -qF -- "${l:0:40}" <<< "$1" || { echo "  missing: $l"; return 1; }; done <<< "$2"; }
FULL="$SN/2026-10-04-full.tar.gz"
withengine() { PATH="$E:$PATH" RN1_COMPOSE_PROVIDER="$E/docker-compose" TMPDIR="$T/tmp" "$@"; }
v26() { sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$D/rn1-technology-catalog-installer.sh"; }
v25() { sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="25.4.4191.133"/' "$D/rn1-technology-catalog-installer.sh"; }

printf '%s\n' "$LOCALADMIN" > "$LK"; chmod 600 "$LK"; : > "$LOG"; echo 0 > "$SRV/polls"
out="$(SHIM_PROGRESS="0 0 2 46 100" withengine bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow (CLI, administrator): every step of the Catalog log once, with its time, paths shortened; nothing from before the upload, of other operations, requests, the expired login or the exception of another logger" '[ "$rc" -eq 0 ] && [ "$(steps <<< "$out")" = "$WANT" ]'
check "follow: preparing named once while the history shows 0" '[ "$(grep -c "^==> Preparing: the Catalog copies the snapshot and unpacks it (it reports no progress for this; a full snapshot can take a long time).$" <<< "$out")" -eq 1 ]'
check "follow: the end from the operation (decimal progress), then the index note with the index operation" 'grep -q "Import finished.$" <<< "$out" && grep -q "The Catalog now rebuilds its search index in a separate operation (started) - searches can be incomplete until it ends.$" <<< "$out" && grep -q "^local GET v1/operation/recent?type=index&maxItems=1 auth=X-Api-Key:" "$LOG"'
check "follow: history progress and operation polled each time" '[ "$(grep -c "^local GET v1/synchronizationHistory/progress/op-1 " "$LOG")" -eq 5 ] && [ "$(grep -c "^local GET v1/operation/op-1 " "$LOG")" -eq 5 ]'
check "follow: the log marked before the upload, then read from the time stamps of the engine (its clock, not this host's)" 'grep -q "^podman logs --timestamps --tail 100 id-catalog-web$" "$ENGLOG" && grep -q "^podman logs --timestamps --since 2026-10-11T10:49:59.700Z --tail 5000 id-catalog-web$" "$ENGLOG" && grep -q "^podman logs --timestamps --since 2026-10-11T11:22:00.4Z --tail 5000 id-catalog-web$" "$ENGLOG" && ! grep -q "^podman logs .*--since [0-9]*$" "$ENGLOG"'
check "follow: no unknown engine call" '[ ! -s "$UNH" ] || { sort "$UNH" | uniq -c; false; }'

echo 0 > "$SRV/polls"
out="$(SHIM_STATUS_CASE=1 withengine bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow: the status read in any case (Finished)" '[ "$rc" -eq 0 ] && grep -q "Import finished.$" <<< "$out"'

: > "$LOG"; echo 0 > "$SRV/polls"
out="$(SHIM_OP_CANCEL=1 SHIM_PROGRESS=0 withengine bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow: a cancelled operation (another synchronization ran) said at once, no waiting" '[ "$rc" -eq 1 ] && grep -q "Import cancelled: The operation was cancelled, because synchronization is currently being processed.$" <<< "$out" && grep -q "start it again when that one has ended" <<< "$out" && [ "$(cat "$SRV/polls")" -eq 1 ]'

printf '%s\n' "$LOCALSYNC" > "$LK"; : > "$LOG"; echo 0 > "$SRV/polls"
out="$(withengine bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow without the right to read the operation (403): the end and the summary from the synchronization history" '[ "$rc" -eq 0 ] && grep -q "Import finished. Synchronized, \"full\" snapshot$" <<< "$out" && [ "$(grep -c "^local GET v1/operation/op-1 " "$LOG")" -eq 1 ] && grep -q "^local GET v1/synchronizationHistory/lastSynchronizationHistory " "$LOG"'
check "follow without administrator rights: the index note without the operation" 'grep -q "searches can be incomplete until it ends.$" <<< "$out" && ! grep -q "operation/recent" "$LOG"'

: > "$LOG"; echo 0 > "$SRV/polls"
out="$(SHIM_PROGRESS=0 SHIM_CATALOG_LOG=failed.log withengine bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow without administrator rights: a failure before the history has a record taken from the log at once, its lines shown" '[ "$rc" -eq 1 ] && grep -q "^ERROR Import failed: No space left on device : .*/tmp/minio_cache/dbSnapshot.tar.gz.$" <<< "$out" && grep -q "^14:02:40 ERROR Operation \[op-1\] failed: No space left on device : .*\.\.\./dbSnapshot.tar.gz.\.$" <<< "$out" && grep -q "^14:02:40 System.IO.IOException: No space left on device" <<< "$out" && [ "$(cat "$SRV/polls")" -eq 1 ]'

v26; : > "$LOG"; echo 0 > "$SRV/polls"
out="$(SHIM_PROGRESS=0 SHIM_OTHER_SYNC=1 SHIM_CATALOG_LOG=cancelled.log withengine bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow without administrator rights, Catalog 26: the log says another synchronization cancelled it - said at the next look" '[ "$rc" -eq 1 ] && grep -q "Import cancelled: another synchronization runs in the Catalog (its log says so)." <<< "$out" && [ "$(cat "$SRV/polls")" -eq 2 ] && ! grep -q lastSynchronizationHistory "$LOG" && [ "$(grep -c "^13:50:12 The operation was cancelled, because synchronization is currently being processed.$" <<< "$out")" -eq 1 ]'
: > "$LOG"; echo 0 > "$SRV/polls"
out="$(SHIM_PROGRESS="0 0 0 100" SHIM_LOG_LINES=0 SHIM_CATALOG_LOG=precancel.log withengine bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow without administrator rights, Catalog 26: a cancel logged before the upload is not taken for this import" '[ "$rc" -eq 0 ] && grep -q "Import finished. Synchronized" <<< "$out" && ! grep -q "cancelled" <<< "$out" && [ "$(cat "$SRV/polls")" -eq 4 ]'
: > "$LOG"; echo 0 > "$SRV/polls"
out="$(SHIM_PROGRESS=0 SHIM_OTHER_SYNC=1 bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow without administrator rights, Catalog 26, no log: another synchronization in the history twice - probably cancelled, without a result (4), not failed" '[ "$rc" -eq 4 ] && grep -q "Another synchronization runs in the Catalog - this import was probably cancelled: check the web interface." <<< "$out" && ! grep -q "ERROR" <<< "$out" && [ "$(grep -c "^local GET v1/synchronizationHistory/lastSynchronizationHistory " "$LOG")" -eq 2 ] && [ "$(cat "$SRV/polls")" -eq 5 ] || { echo "  | rc=$rc polls=$(cat "$SRV/polls") history reads=$(grep -c "^local GET v1/synchronizationHistory/lastSynchronizationHistory " "$LOG")"; printf "%s
" "$out" | tail -n 15 | sed "s/^/  | /"; grep "^local " "$LOG" | sed "s/^/  | /"; false; }'
: > "$LOG"; echo 0 > "$SRV/polls"
out="$(SHIM_PROGRESS="0 0 0 100" SHIM_OTHER_SYNC=1 withengine bash "$D/rn1-technology-catalog-installer.sh" import "$FULL" </dev/null 2>&1)"; rc=$?
check "follow without administrator rights, Catalog 26: a history record left running, but the log says this import started - followed to its end" '[ "$rc" -eq 0 ] && grep -q "Import finished (100%)." <<< "$out" && ! grep -q "cancelled" <<< "$out" && [ "$(grep -c "^local GET v1/synchronizationHistory/lastSynchronizationHistory " "$LOG")" -eq 1 ]'
v25

# a job of the menu with a login: the access token expires after 2 polls and is renewed
rm -f "$LK"; : > "$LOG"; : > "$UNH"; echo 0 > "$SRV/polls"
touch "$FULL"; NCH="$(ls "$SN"/chain-*.tsv | wc -l)"
J=$(( $(cat "$D/.jobs/seq" 2>/dev/null || echo 0) + 1 ))
( for i in $(seq 1 300); do [ -f "$D/.jobs/$J/ended" ] && break; cat "$D/.jobs/$J/progress" 2>/dev/null; sleep 0.2; done ) > "$T/progress.samples" &
sampler=$!
out="$(printf '19\n%s\n2\nadmin\np@ss"w0rd\n\n0\n' "$((NCH + 1))" | SHIM_PROGRESS="0 0 2 46 100" SHIM_EXPIRE_AFTER=2 withengine bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
wait "$sampler"
JL="$D/.jobs/$J/log"
check "job: the access menu says that an API key does not expire" 'grep -q "An API key does not expire - the better choice for long imports." <<< "$out"'
check "job: the import followed to its end with the login" '[ "$(cat "$D/.jobs/$J/state")" = done ] && grep -q "Import finished.$" "$JL"'
check "job: the expired login renewed once (refresh token from the stdin config), the new token used from then on" '[ "$(grep -c "^local refresh known$" "$LOG")" -eq 1 ] && ! grep -q "^local refresh unknown" "$LOG" && [ "$(sed -n "/^local refresh/,\$p" "$LOG" | grep "auth=Authorization:" | grep -vc "token=2$")" -eq 0 ] && [ "$(sed -n "/^local refresh/,\$p" "$LOG" | grep -c "token=2$")" -ge 3 ]'
check "job: every step once in the job log" '[ "$(steps < "$JL")" = "$WANT" ]'
check "job: the progress line - Preparing while the history shows 0, then percent, step and time" 'grep -Eq "^\|Preparing: copying and unpacking the snapshot\|[0-9][0-9ms]*$" "$T/progress.samples" && grep -Eq "^46\|Import 46% [^ ]+ importing versions [^ ]+ [0-9][0-9ms]*\|$" "$T/progress.samples" && grep -Eq "^2\|Import 2% [^ ]+ importing AppCompat [^ ]+ [0-9][0-9ms]*\|$" "$T/progress.samples"'
check "job: no token or refresh token in the job folder, its log, a temporary file or on a command line" '[ ! -e "$D/.jobs/$J/secret" ] && ! grep -rqa -e TOKEN123 -e TOKEN456 -e RTOKEN "$D" "$T/tmp" && ! grep "^curl " "$LOG" | grep -q -e TOKEN -e RTOKEN'
if command -v script >/dev/null 2>&1; then
  # panel ROWS COLS ID [KEYS] -> the job view in a terminal of that size (KEYS after 2 seconds)
  panel() { { sleep 2; printf '%s' "${4:-}"; sleep 1; } | TERM=xterm script -qfec "stty rows $1 cols $2; bash $D/rn1-technology-catalog-installer.sh jobs follow $3" /dev/null 2>&1 | sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g; s/\r$//'; }
  out="$(panel 30 100 "$J")"
  check "job view of an ended import: every step from the first on, the long lines wrapped, not cut" 'allin "$out" "$WANT" && grep -Eq "no progress for this; a +(\||│)$" <<< "$out" && grep -q "full snapshot can take a long time)." <<< "$out" && grep -q "incomplete until it ends." <<< "$out" && ! grep -Eq "~ (\||│)$" <<< "$out"'
  out="$(panel 9 80 "$J")"
  check "job view of an ended import in a small terminal: still every step" 'allin "$out" "$WANT" && grep -q "Import finished." <<< "$out"'
else
  echo "SKIP: script (util-linux) missing - no job view test"
fi

# a login renewed before its access token expires (here after 10 of 12 seconds): no 401 needed; the live
# view meanwhile shows as many rows as the terminal has room for
: > "$LOG"; echo 0 > "$SRV/polls"
J=$(( $(cat "$D/.jobs/seq") + 1 ))
( printf '19\n%s\n2\nadmin\np@ss"w0rd\n\n0\n' "$((NCH + 1))" | SHIM_PROGRESS="0 0 2 46 100" SHIM_TTL=12 withengine bash "$D/rn1-technology-catalog-installer.sh" menu > "$T/menu-ttl.out" 2>&1 ) &
mp=$!
for i in $(seq 1 100); do grep -q "Synchronized EXT_nist_cpe items" "$D/.jobs/$J/log" 2>/dev/null && break; sleep 0.2; done
if command -v script >/dev/null 2>&1; then
  out="$(panel 12 80 "$J" q)"
  check "live job view: 6 rows of the log in a terminal of 12 rows, the newest last" 'awk -v j="Job #'"$J"' " "index(\$0, j) && /Snapshot import/ { t = NR } t && /q back to the menu/ { n = NR - t - 3; t = 0 } END { exit n != 6 }" <<< "$out" && grep -q "keeps running in the background" <<< "$out"'
fi
wait "$mp"
check "login renewed before its access token expires: no 401, the new token used from then on" '[ "$(cat "$D/.jobs/$J/state")" = done ] && [ "$(grep -c "^local refresh known$" "$LOG")" -ge 1 ] && [ "$(sed -n "/^local refresh/,\$p" "$LOG" | grep "auth=Authorization:" | grep -vc "token=2$")" -eq 0 ] && [ "$(sed -n "/^local refresh/,\$p" "$LOG" | grep -c "token=2$")" -ge 2 ]'

# the renewal fails: one clear line, not a failed import, the job without a result
: > "$LOG"; echo 0 > "$SRV/polls"
J=$(( $(cat "$D/.jobs/seq") + 1 ))
out="$(printf '19\n%s\n2\nadmin\np@ss"w0rd\n\n0\n' "$((NCH + 1))" | SHIM_PROGRESS="0 0 2 46 100" SHIM_EXPIRE_AFTER=1 SHIM_REFRESH_FAIL=1 withengine bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
JL="$D/.jobs/$J/log"
check "login not renewable: one clear line, the import not reported as failed, the menu not either" 'grep -q "The login has expired; the import goes on in the Catalog - its progress: option 10 (logs) or the web interface$" "$JL" && ! grep -qi "import failed" "$JL" && ! grep -qi "import failed" <<< "$out" && [ "$(grep -c "The login has expired" "$JL")" -eq 1 ] && ! grep -q "did not finish successfully" <<< "$out"'
check "login not renewable: the job ends without a result, not as failed" '[ "$(cat "$D/.jobs/$J/state")" = unfollowed ] && [ "$(cat "$D/.jobs/$J/exit")" = 4 ] && grep -q "Job #$J ended without a result" <<< "$out" && bash "$D/rn1-technology-catalog-installer.sh" jobs list | grep -Eq "^ +$J +unfollowed "'
check "login not renewable: nothing secret in files or logs" '! grep -rqa -e TOKEN123 -e TOKEN456 -e RTOKEN "$D" "$T/tmp" && ! grep "^curl " "$LOG" | grep -q -e TOKEN -e RTOKEN'
if command -v script >/dev/null 2>&1; then
  out="$(panel 24 80 "$J")"
  check "job view without a result: the whole reason in the panel, wrapped" 'grep -q "result unknown" <<< "$out" && grep -q "WARN The login has expired; the import goes on in the Catalog - its" <<< "$out" && grep -q "progress: option 10 (logs) or the web interface" <<< "$out" && grep -q "Stopped following - it goes on in the Catalog" <<< "$out"'
fi
check "follow: no unknown engine call in the jobs" '[ ! -s "$UNH" ] || { sort "$UNH" | uniq -c; false; }'
check "no podman call the fake does not know" '[ ! -s "$UNH" ] || { cat "$UNH"; false; }'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
