#!/usr/bin/env bash
set -u
NEW="$1"
if ! command -v setsid >/dev/null 2>&1; then
  echo "SKIP: setsid is missing - the background job tests need Linux (util-linux)."
  exit 0
fi
T="$(mktemp -d)/j"
rm -rf "$T"; mkdir -p "$T/bin" "$T/srv/daily" "$T/srv/full"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
wait_for() { local i; for i in $(seq 1 "${2:-150}"); do eval "$1" && return 0; sleep 0.2; done; return 1; }
export LOG="$T/curl.log" SRV="$T/srv"
: > "$LOG"
VALID="ABCDEF0-1234567-89ABCDE-F012345"
export VALID

head -c 3000000 /dev/urandom | gzip -1 > "$SRV/daily/2026-10-02.tar.gz"
cp "$SRV/daily/2026-10-02.tar.gz" "$SRV/full/2026-09-28.tar.gz"
size="$(stat -c %s "$SRV/daily/2026-10-02.tar.gz")"
sum="sha256:$(sha256sum "$SRV/daily/2026-10-02.tar.gz" | cut -d' ' -f1)"
cat > "$SRV/manifest.json" <<EOF
{"generatedAt":"2026-10-03T02:31:00Z","latestFullSnapshot":{"date":"2026-09-28","sizeBytes":$size,"checksum":"$sum","downloadPath":"full/2026-09-28.tar.gz"},
"dailyDeltas":[{"basedOnDate":"2026-10-01","date":"2026-10-02","sizeBytes":$size,"checksum":"$sum","downloadPath":"daily/2026-10-02.tar.gz"}],"cumulativeDeltas":[]}
EOF

# The snapshot is served slowly: 100 KB every 0.2 s (about 6 s for the whole file).
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$LOG"
out=/dev/stdout; fmt=""; url=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -K) [ "$2" = "-" ] && cfg="$(cat)"; shift 2 ;;
    -H|--connect-timeout|--retry|--retry-delay|--max-time|--proto|-X) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
key="$(printf '%s' "$cfg" | sed -n 's/^header = "X-Api-Key: \(.*\)"$/\1/p')"
path="${url#https://rayventorycatalog.raynet.de}"
code=200
if [ "$key" != "$VALID" ]; then
  code=401; : > "$out"
else
  case "$path" in
    /v3/synchronization/manifest) cat "$SRV/manifest.json" > "$out" ;;
    /v3/synchronization/snapshot/*)
      f="$SRV/${path#/v3/synchronization/snapshot/}"
      : > "$out"
      n=$(( ($(stat -c %s "$f") + 99999) / 100000 ))
      for ((i = 0; i < n; i++)); do
        dd if="$f" bs=100000 skip="$i" count=1 2>/dev/null >> "$out"
        sleep "${SHIM_DELAY:-0.2}"
      done
      ;;
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
export PATH="$T/bin:$PATH"
D="$T/inst"; mkdir -p "$D"; cp "$NEW" "$D/rn1-technology-catalog-installer.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/rn1-technology-catalog-installer.sh"
printf '%s\n' "$VALID" > "$D/.catalog_api_key"; chmod 600 "$D/.catalog_api_key"
PART="$D/snapshots/2026-10-02-daily.tar.gz.part"
FILE="$D/snapshots/2026-10-02-daily.tar.gz"
state() { cat "$D/.jobs/$1/state" 2>/dev/null; }

# 1. The SSH session ends while the download runs: the job carries on and finishes
setsid bash -c 'printf "17\n3\n\n\n0\n" | bash "$0/rn1-technology-catalog-installer.sh" menu > "$0/menu1.out" 2>&1' "$D" &
sp=$!
disown "$sp" 2>/dev/null || true
wait_for '[ -s "$PART" ]'
check "download runs as job #1" '[ "$(state 1)" = running ] && grep -q "Started as job #1" "$D/menu1.out"'
kill -HUP -- "-$sp" 2>/dev/null
sleep 1
check "menu session gone after the hangup" '! kill -0 "$sp" 2>/dev/null'
check "job still running after the hangup" '[ "$(state 1)" = running ]'
check "progress with percent, size and speed" 'IFS="|" read -r pct text detail < "$D/.jobs/1/progress"; [[ "$pct" =~ ^[0-9]+.[0-9]$ ]] && [ "$text" = Downloading ] && [[ "$detail" == *" / "*"/s"* ]]'
wait_for '[ "$(state 1)" != running ]' 200
check "job finished on its own" '[ "$(state 1)" = done ] && [ -f "$FILE" ] && [ ! -e "$PART" ]'
check "checksum verified in the job log" 'grep -q "sha256 verified" "$D/.jobs/1/log"'
check "API key not left in the job folder" '[ ! -e "$D/.jobs/1/secret" ] && ! grep -rq "$VALID" "$D/.jobs"'
check "key never on a command line" '! grep "^curl " "$LOG" | grep -q "$VALID"'

# 2. Cancel from another session: curl stops and the partial file is removed
rm -f "$FILE"
( printf '17\n3\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu > "$T/menu2.out" 2>&1 ) &
mp=$!
wait_for '[ -s "$PART" ]'
out="$(bash "$D/rn1-technology-catalog-installer.sh" jobs cancel 2 2>&1)"
wait "$mp"
sleep 1
check "cancel reported" 'grep -q "Job #2 cancelled" <<< "$out"'
check "job state cancelled" '[ "$(state 2)" = cancelled ]'
check "partial download removed and not written again" '[ ! -e "$PART" ] && [ ! -e "$FILE" ] && grep -q "Partial download removed" "$D/.jobs/2/log"'
check "following view reports the cancel" 'grep -q "Job #2 was cancelled" "$T/menu2.out"'

# 3. jobs CLI
out="$(bash "$D/rn1-technology-catalog-installer.sh" jobs list 2>&1)"
check "jobs list shows done and cancelled" 'grep -Eq "^ +1 +done " <<< "$out" && grep -Eq "^ +2 +cancelled " <<< "$out"'
out="$(bash "$D/rn1-technology-catalog-installer.sh" jobs log 1 2>&1)"
check "jobs log prints the log" 'grep -q "Snapshot saved" <<< "$out"'
out="$(bash "$D/rn1-technology-catalog-installer.sh" jobs cancel 1 2>&1)"; rc=$?
check "finished job cannot be cancelled" '[ "$rc" -ne 0 ] && grep -q "is not running" <<< "$out"'

# 4. Only one snapshot download at a time (slower server from here on)
export SHIM_DELAY=0.7
( printf '17\n3\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu > "$T/menu3.out" 2>&1 ) &
mp=$!
wait_for '[ -s "$PART" ]'
out="$(printf '17\n3\n\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "second download refused while one runs" 'grep -q "Job #3 (Snapshot download" <<< "$out" && grep -q "is still running" <<< "$out" && [ ! -d "$D/.jobs/4" ]'

# 5. Full screen menu: Current processes box, hold X cancels the selected process
if command -v script >/dev/null 2>&1; then
  out="$( { sleep 3; for i in $(seq 1 35); do printf x; sleep 0.08; done; sleep 3; printf q; } \
    | TERM=xterm LANG=C.UTF-8 script -qfec "stty cols 120 rows 40; bash $D/rn1-technology-catalog-installer.sh menu" /dev/null 2>&1 | sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g')"
  wait "$mp"
  check "menu shows the Current processes box with the job" 'grep -q "Current processes" <<< "$out" && grep -q "#3 Snapshot download" <<< "$out"'
  check "holding X cancelled the job" '[ "$(state 3)" = cancelled ] && [ ! -e "$PART" ]'
  check "cancel animation shown" 'grep -q "keep holding X" <<< "$out"'
else
  bash "$D/rn1-technology-catalog-installer.sh" jobs cancel 3 >/dev/null 2>&1; wait "$mp"
  echo "SKIP: script (util-linux) missing - no full screen test"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
