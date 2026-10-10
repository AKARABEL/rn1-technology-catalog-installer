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
      echo "$form" > "$SRV/upload-form.txt"; echo "$form" >> "$SRV/uploads.log"; printf '{"operationId":"op-1","status":"accepted"}' > "$out"; reply 202 ;;
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
check "CLI import: failed operation -> rc!=0" '[ "$rc" -ne 0 ] && grep -q "Import failed: done" <<< "$out"'
out="$(bash "$D/rn1-technology-catalog-installer.sh" import /nonexistent.tar.gz </dev/null 2>&1)"; rc=$?
check "CLI import: missing file" '[ "$rc" -ne 0 ] && grep -q "File not found" <<< "$out"'
out="$(SHIM_LOCAL_DOWN=1 bash "$D/rn1-technology-catalog-installer.sh" import "$D/snapshots/2026-09-28-full.tar.gz" </dev/null 2>&1)"; rc=$?
check "CLI import: stack down -> clear message" '[ "$rc" -ne 0 ] && grep -q "not reachable at http://localhost:8080" <<< "$out"'

# 13. Self-sync: needs admin; admin login with special characters; settings merged, sync started
rm -f "$LK" "$SRV/polls" "$SRV/sync-settings.json"; : > "$LOG"
out="$(printf '20\n2\nadmin\np@ss"w0rd\ny\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "admin login with quote in password" 'grep -q "Logged in to the local catalog." <<< "$out" && grep -qF "\"password\":\"p@ss\\\"w0rd\"" "$SRV/login-body.json"'
check "password never on a command line" '! grep "^curl " "$LOG" | grep -q "p@ss"'
check "sync settings: online URL + key set, proxy kept" 'grep -q "\"parentInstanceUrl\": *\"https://rayventorycatalog.raynet.de\"" "$SRV/sync-settings.json" && grep -q "\"parentInstanceKey\": *\"$VALID\"" "$SRV/sync-settings.json" && grep -q "proxy:3128" "$SRV/sync-settings.json"'
check "synchronization started and followed" 'grep -q "now synchronizes from https://rayventorycatalog.raynet.de" <<< "$out" && grep -q "Import finished." <<< "$out"'
out="$(printf "20\n1\n$LOCALSYNC\nn\n\n0\n" | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "self-sync refused without admin rights" 'grep -q "needs a local administrator" <<< "$out"'

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
check "next upload only after the import finished" '[ "$(grep -E "^local (POST v1/synchronization/snapshot|GET v1/operation)" "$LOG" | awk "{ printf (\$2 == \"POST\") ? \"U\" : \"P\" }")" = "UPPUP" ]'
rm -f "$SRV/polls"; : > "$SRV/uploads.log"
out="$(SHIM_OP_RESULT=failed bash "$D/rn1-technology-catalog-installer.sh" import-chain "$SINCECHAIN" </dev/null 2>&1)"; rc=$?
check "chain import stops at the first failure" '[ "$rc" -ne 0 ] && grep -q "Import stopped at 2026-10-01-cumulative-30d.tar.gz" <<< "$out" && [ "$(grep -c . "$SRV/uploads.log")" -eq 1 ]'
out="$(bash "$D/rn1-technology-catalog-installer.sh" import-chain "$SN/none.tsv" </dev/null 2>&1)"; rc=$?
check "import-chain without a chain file" '[ "$rc" -ne 0 ] && grep -q "No downloaded chain" <<< "$out"'
rm -f "$SN/2026-10-04-cumulative-7d.tar.gz"
out="$(bash "$D/rn1-technology-catalog-installer.sh" import-chain "$SINCECHAIN" </dev/null 2>&1)"; rc=$?
check "missing chain file found before any upload" '[ "$rc" -ne 0 ] && grep -q "2026-10-04-cumulative-7d.tar.gz of the chain is missing" <<< "$out" && [ "$(grep -c . "$SRV/uploads.log")" -eq 1 ]'

# 18. Upload limit: Catalog 25.x has a fixed 10 GB limit, newer versions use SYNC_MAX_UPLOAD
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

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
