#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/s"
rm -rf "$T"; mkdir -p "$T/bin" "$T/srv/daily" "$T/srv/full"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
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
  echo "local $method ${url#http://localhost:*/} auth=${auth%% *}" >> "$LOG"
  [ "${SHIM_LOCAL_DOWN:-}" = 1 ] && { printf '000'; exit 7; }
  path="/${url#http://localhost:*/}"
  case "$auth" in
    "X-Api-Key: $LOCALADMIN"|"Authorization: Bearer TOKEN123") role=admin ;;
    "X-Api-Key: $LOCALSYNC") role=sync ;;
    *) role=none ;;
  esac
  if [ "$path" = /v1/authentication/request ]; then
    body="$(cat "${data#@}")"; echo "$body" > "$SRV/login-body.json"
    if grep -q '"username":"admin"' <<< "$body" && grep -qF '"password":"p@ss\"w0rd"' <<< "$body"; then
      printf '{"access_token":"TOKEN123","refresh_token":"R","expires_in":3600}' > "$out"; reply 200
    fi
    : > "$out"; reply 401
  fi
  [ "$role" = none ] && { : > "$out"; reply 401; }
  case "$method $path" in
    "GET /v1/databaseconfiguration/synchronization")
      [ "$role" = admin ] || { : > "$out"; reply 403; }
      printf '{"parentInstanceUrl":"","parentInstanceKey":"","proxyInfo":{"address":"proxy:3128"}}' > "$out"; reply 200 ;;
    "POST /v1/databaseconfiguration/synchronization")
      cat "${data#@}" > "$SRV/sync-settings.json"; : > "$out"; reply 204 ;;
    "POST /v1/synchronization/snapshot")
      echo "$form" > "$SRV/upload-form.txt"; printf '{"operationId":"op-1","status":"accepted"}' > "$out"; reply 202 ;;
    "POST /v1/synchronization/synchronize")
      printf '{"operationId":"op-2"}' > "$out"; reply 202 ;;
    "GET /v1/operation/"*)
      n="$(cat "$SRV/polls" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$SRV/polls"
      if [ "$n" -lt 2 ]; then printf '{"status":"started","progress":40,"message":"Importing"}' > "$out"
      else printf '{"status":"%s","progress":100,"message":"done"}' "${SHIM_OP_RESULT:-finished}" > "$out"; fi
      reply 200 ;;
  esac
  : > "$out"; reply 404
fi
key="$(printf '%s' "$cfg" | sed -n 's/^header = "X-Api-Key: \(.*\)"$/\1/p')"
echo "cfg-key-present=$([ -n "$key" ] && echo yes || echo no)" >> "$LOG"
path="${url#https://rayventorycatalog.raynet.de}"
code=200
if [ "${SHIM_OFFLINE:-}" = 1 ]; then printf '000'; exit 7; fi
if [ "$key" = "$NOSYNC" ]; then code=403; : > "$out"
elif [ "$key" != "$VALID" ]; then code=401; printf '{"title":"Authentication Error","status":401,"detail":"Api key is not registered in the database."}' > "$out"
else
  case "$path" in
    /v3/synchronization/manifest) if [ "${SHIM_NO_MANIFEST:-}" = 1 ]; then code=404; : > "$out"; else cat "$SRV/manifest.json" > "$out"; fi ;;
    /v3/synchronization/snapshot/*) f="$SRV/${path#/v3/synchronization/snapshot/}"; if [ -f "$f" ]; then cat "$f" > "$out"; [ "${SHIM_CORRUPT:-}" = 1 ] && echo x >> "$out"; else code=404; : > "$out"; fi ;;
    *) code=404; : > "$out" ;;
  esac
fi
[ -n "$fmt" ] && printf '%s' "${fmt//%\{http_code\}/$code}"
exit 0
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"
D="$T/inst"; mkdir -p "$D"; cp "$NEW" "$D/catalog.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/catalog.sh"
K="$D/.catalog_api_key"
probe="$T/p"; : > "$probe"; chmod 600 "$probe"; if [ "$(stat -c %a "$probe")" = 600 ]; then CHMOD_WORKS=yes; else CHMOD_WORKS=no; fi

# 1. Option 17 without a stored key: wrong key, then valid key, save, download daily (default)
out="$(printf "17\nWRONGKEY\n$VALID\ny\n\n\n0\n" | bash "$D/catalog.sh" menu 2>&1)"
check "wrong key rejected with server detail" 'grep -q "not valid: Api key is not registered in the database." <<< "$out"'
check "valid key accepted after retry" 'grep -q "The API key is valid." <<< "$out"'
check "key saved with mode 600" '[ -f "$K" ] && [ "$(tr -d "\r\n" < "$K")" = "$VALID" ] && { [ "$(stat -c %a "$K")" = 600 ] || [ "$CHMOD_WORKS" = no ]; }'
check "daily snapshot listed with based-on date" 'grep -q "Latest daily snapshot   2026-10-02" <<< "$out" && grep -q "applies on top of 2026-10-01" <<< "$out"'
check "newest daily downloaded and verified" '[ -f "$D/snapshots/2026-10-02-daily.tar.gz" ] && grep -q "sha256 verified" <<< "$out" && [ ! -e "$D/snapshots/2026-10-02-daily.tar.gz.part" ]'
check "key never on a command line" '! grep "^curl " "$LOG" | grep -q -e "$VALID" -e WRONGKEY'
check "key passed via curl config on stdin" 'grep -q "cfg-key-present=yes" "$LOG" && grep -q -- "-K -" "$LOG"'
check "https only, no redirects followed" 'grep "^curl " "$LOG" | grep -q -- "--proto =https" && ! grep "^curl " "$LOG" | grep -q -e " -L" -e "--location"'

# 2. Stored key: full snapshot via the menu
out="$(printf '17\n2\n\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "stored key tested and used" 'grep -q "Testing the stored API key ABCDEF0...2345" <<< "$out"'
check "full snapshot downloaded" '[ -f "$D/snapshots/2026-09-28-full.tar.gz" ]'

# 3. Same file again -> already downloaded
out="$(printf '17\n1\n\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "already downloaded detected" 'grep -q "Already downloaded" <<< "$out"'

# 4. Corrupt download -> removed, error
rm -f "$D/snapshots/2026-10-02-daily.tar.gz"
out="$(printf '17\n1\n\n0\n' | SHIM_CORRUPT=1 bash "$D/catalog.sh" menu 2>&1)"
check "checksum mismatch rejected and cleaned" 'grep -q "Checksum mismatch" <<< "$out" && [ ! -e "$D/snapshots/2026-10-02-daily.tar.gz" ] && [ ! -e "$D/snapshots/2026-10-02-daily.tar.gz.part" ]'

# 5. CLI snapshot (stored key, non-interactive)
out="$(bash "$D/catalog.sh" snapshot daily </dev/null 2>&1)"; rc=$?
check "CLI snapshot daily" '[ "$rc" -eq 0 ] && [ -f "$D/snapshots/2026-10-02-daily.tar.gz" ]'

# 6. API key menu: masked display, show full, test, delete
out="$(printf '18\n1\ny\n3\n0\n\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "menu shows masked key" 'grep -q "Online catalog (https://rayventorycatalog.raynet.de): ABCDEF0...2345" <<< "$out"'
check "show full key after confirmation" 'grep -q "   $VALID" <<< "$out"'
check "test stored key" 'grep -q "The API key is valid." <<< "$out"'
out="$(printf '18\n4\ny\n0\n\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "delete key" '[ ! -e "$K" ] && grep -q "Key deleted." <<< "$out"'

# 7. Add key via menu: forbidden key not saved; valid key saved after immediate test
out="$(printf "18\n2\n$NOSYNC\n\n0\n\n0\n" | bash "$D/catalog.sh" menu 2>&1)"
check "key without sync role rejected, not saved" 'grep -q "no synchronization permission" <<< "$out" && [ ! -e "$K" ]'
out="$(printf "18\n2\n$(printf '%s' "$VALID" | tr 'A-F' 'a-f')\ny\n0\n\n0\n" | bash "$D/catalog.sh" menu 2>&1)"
check "lower-case key normalized, tested and saved" '[ "$(tr -d "\r\n" < "$K")" = "$VALID" ] && grep -q "API key saved." <<< "$out"'

# 8. Do not save when declined
rm -f "$K"
out="$(printf "17\n$VALID\nn\n0\n\n0\n" | bash "$D/catalog.sh" menu 2>&1)"
check "declined save leaves no key file" '[ ! -e "$K" ]'

# 9. CLI without key; offline; no manifest yet
out="$(bash "$D/catalog.sh" snapshot </dev/null 2>&1)"; rc=$?
check "CLI without stored key fails" '[ "$rc" -ne 0 ] && grep -q "No API key stored" <<< "$out"'
api_key_save_file() { printf '%s\n' "$VALID" > "$K"; chmod 600 "$K"; }
api_key_save_file
out="$(SHIM_OFFLINE=1 bash "$D/catalog.sh" snapshot </dev/null 2>&1)"; rc=$?
check "offline: clear message, no 'invalid'" '[ "$rc" -ne 0 ] && grep -q "could not be checked" <<< "$out" && ! grep -q "not valid" <<< "$out"'
out="$(SHIM_NO_MANIFEST=1 bash "$D/catalog.sh" snapshot </dev/null 2>&1)"; rc=$?
check "no manifest yet: valid key, nothing to download" '[ "$rc" -eq 0 ] && grep -q "has no snapshot yet" <<< "$out"'

# 10. Key file is not part of an offline bundle copy and not in help as plain text
check "help lists snapshot command" 'bash "$D/catalog.sh" help | grep -q "snapshot \[daily|full\]"'

# 11. Import a downloaded snapshot: local key asked, tested, saved; upload; progress followed
LK="$D/.catalog_local_api_key"; rm -f "$LK" "$SRV/polls"; : > "$LOG"
out="$(printf "19\n1\ny\n1\n$LOCALSYNC\ny\n\n0\n" | bash "$D/catalog.sh" menu 2>&1)"
check "local key tested (non-admin) and saved" 'grep -q "Access to the local catalog works (no administrator rights)." <<< "$out" && [ "$(tr -d "\r\n" < "$LK")" = "$LOCALSYNC" ]'
check "snapshot uploaded as gzip file part" 'grep -q "^file=@.*2026-10-02-daily.tar.gz;type=application/gzip$" "$SRV/upload-form.txt"'
check "operation followed until finished" 'grep -q "Import finished." <<< "$out" && [ "$(cat "$SRV/polls")" -ge 2 ]'
check "local key never on a command line" '! grep "^curl " "$LOG" | grep -q "$LOCALSYNC"'

# 12. CLI import with the stored local key; failed operation reported
rm -f "$SRV/polls"
out="$(SHIM_OP_RESULT=failed bash "$D/catalog.sh" import "$D/snapshots/2026-09-28-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "CLI import: failed operation -> rc!=0" '[ "$rc" -ne 0 ] && grep -q "Import failed: done" <<< "$out"'
out="$(bash "$D/catalog.sh" import /nonexistent.tar.gz </dev/null 2>&1)"; rc=$?
check "CLI import: missing file" '[ "$rc" -ne 0 ] && grep -q "File not found" <<< "$out"'
out="$(SHIM_LOCAL_DOWN=1 bash "$D/catalog.sh" import "$D/snapshots/2026-09-28-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "CLI import: stack down -> clear message" '[ "$rc" -ne 0 ] && grep -q "not reachable at http://localhost:8080" <<< "$out"'

# 13. Self-sync: needs admin; admin login with special characters; settings merged, sync started
rm -f "$LK" "$SRV/polls" "$SRV/sync-settings.json"; : > "$LOG"
out="$(printf '20\n2\nadmin\np@ss"w0rd\ny\n\n0\n' | bash "$D/catalog.sh" menu 2>&1)"
check "admin login with quote in password" 'grep -q "Logged in to the local catalog." <<< "$out" && grep -qF "\"password\":\"p@ss\\\"w0rd\"" "$SRV/login-body.json"'
check "password never on a command line" '! grep "^curl " "$LOG" | grep -q "p@ss"'
check "sync settings: online URL + key set, proxy kept" 'grep -q "\"parentInstanceUrl\": *\"https://rayventorycatalog.raynet.de\"" "$SRV/sync-settings.json" && grep -q "\"parentInstanceKey\": *\"$VALID\"" "$SRV/sync-settings.json" && grep -q "proxy:3128" "$SRV/sync-settings.json"'
check "synchronization started and followed" 'grep -q "now synchronizes from https://rayventorycatalog.raynet.de" <<< "$out" && grep -q "Import finished." <<< "$out"'
out="$(printf "20\n1\n$LOCALSYNC\nn\n\n0\n" | bash "$D/catalog.sh" menu 2>&1)"
check "self-sync refused without admin rights" 'grep -q "needs a local administrator" <<< "$out"'

# 14. Key menu: local key add / test / delete
rm -f "$LK"
out="$(printf "18\n6\n1\n$LOCALADMIN\ny\n7\n8\ny\n0\n\n0\n" | bash "$D/catalog.sh" menu 2>&1)"
check "local key added (admin), tested and deleted" 'grep -q "Local API key saved." <<< "$out" && grep -q "works (administrator)" <<< "$out" && grep -q "Key deleted." <<< "$out" && [ ! -e "$LK" ]'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
