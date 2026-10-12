#!/usr/bin/env bash
set -u
NEW="$1"
if ! command -v setsid >/dev/null 2>&1; then
  echo "SKIP: setsid is missing - the background job tests need Linux (util-linux)."
  exit 0
fi
T="$(mktemp -d)/j"
rm -rf "$T"; mkdir -p "$T/bin" "$T/srv/daily" "$T/srv/full"
# these tests run Podman: CONTAINER_ENGINE names it (on a CI runner, detection would see its real Docker)
sed 's/^CONTAINER_ENGINE=""$/CONTAINER_ENGINE="podman"/' "$1" > "${T%/*}/podman-installer.sh"; NEW="${T%/*}/podman-installer.sh"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
# the internet check (menu start, new installation, option 16, engine setup) has its own suite (run_network_tests)
export RN1_NET_CHECK=off
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
# the kernel of the test machine must not change the generated files (MongoDB workaround on 6.19 to 7.0.x)
REAL_UNAME="$(command -v uname)"
printf '#!/usr/bin/env bash
if [ "${1:-}" = "-r" ]; then echo "${SHIM_KERNEL:-6.8.0-generic}"; else exec "%s" "$@"; fi
' "$REAL_UNAME" > "$T/bin/uname"
chmod +x "$T/bin/uname"
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

# 6. A job that stopped following a task that goes on elsewhere (an import in the Catalog) ends without a
# result - only with the mark of job_unfollowed: any other exit code 4 is a failure
for id in 60 61; do
  mkdir -p "$D/.jobs/$id"; echo "Snapshot import (x-$id.tar.gz)" > "$D/.jobs/$id/title"; echo running > "$D/.jobs/$id/state"
  date '+%Y-%m-%d %H:%M:%S' > "$D/.jobs/$id/started"
done
: > "$D/.jobs/61/unfollowed"
bash "$D/rn1-technology-catalog-installer.sh" __job 60 bash -c 'exit 4' > "$D/.jobs/60/log" 2>&1
bash "$D/rn1-technology-catalog-installer.sh" __job 61 bash -c 'exit 4' > "$D/.jobs/61/log" 2>&1
check "exit code 4 alone is a failure; with the mark of job_unfollowed the job ends without a result" '[ "$(state 60)" = failed ] && [ "$(state 61)" = unfollowed ]'
out="$(bash "$D/rn1-technology-catalog-installer.sh" jobs list 2>&1)"
check "jobs list shows the job without a result" 'grep -Eq "^ +61 +unfollowed " <<< "$out" && grep -Eq "^ +60 +failed " <<< "$out"'
rm -f "$D/.jobs/61/seen"
if command -v script >/dev/null 2>&1; then
  # no job runs now: without the mark of a put off first start the menu would begin with the new installation
  : > "$D/.setup-later"
  out="$( { sleep 3; printf q; } | TERM=xterm LANG=C.UTF-8 timeout 60 script -qfec "stty cols 120 rows 40; bash $D/rn1-technology-catalog-installer.sh menu" /dev/null 2>&1 | sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g')"
  check "menu box: the job without a result as such, not as failed" 'grep -q "#61 Snapshot import (x-61.tar.gz)" <<< "$out" && grep -q "result unknown" <<< "$out" && ! grep -q "unfollowed" <<< "$out"'
fi

# 7. The live view of a job takes the whole width of the terminal, also beyond 100 columns: the frame, the
# progress bar (the width less 30) and the log lines, wrapped at the width less 6 (ASCII frame: LC_ALL=C)
if command -v script >/dev/null 2>&1; then
  mkdir -p "$D/.jobs/62"; echo "Snapshot import (wide.tar.gz)" > "$D/.jobs/62/title"; echo done > "$D/.jobs/62/state"
  date '+%Y-%m-%d %H:%M:%S' > "$D/.jobs/62/started"; echo "40.0|Importing|" > "$D/.jobs/62/progress"
  long="$(printf 'word%03d ' $(seq 1 40))"
  printf '%s\n' "10:00:00 Import started" "${long% }" > "$D/.jobs/62/log"
  for cols in 160 220; do
    out="$( { sleep 3; } | TERM=xterm LC_ALL=C timeout 60 script -qfec "stty cols $cols rows 40; bash $D/rn1-technology-catalog-installer.sh jobs follow 62" /dev/null 2>&1 | sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g' | tr -d '\r')"
    box="$(sed -n '/^+- Job #62 /,/^+-*+$/p' <<< "$out")"
    # words of 8 characters per row: the width less 6, plus the space a row does not end with
    per=$(((cols - 6 + 1) / 8)); fill=$((40 * (cols - 30) / 100))
    check "job view at $cols columns: every line of the frame $cols wide" '{ [ "$(grep -c . <<< "$box")" -ge 6 ] && [ -z "$(awk -v w="$cols" "length(\$0) != w" <<< "$box")" ] && grep -q "^+-*+$" <<< "$box"; } || { printf "%s\n" "$out" | head -n 12 | sed "s/^/  | /"; false; }'
    check "job view at $cols columns: the progress bar $((cols - 30)) wide" 'grep -Eq "^\| ok done   #{$fill}-{$((cols - 30 - fill))}  40\.0% +\|$" <<< "$box"'
    check "job view at $cols columns: the log wrapped at $((cols - 6)) - $per words on its first row" 'grep -Eq "^\| > word001( word[0-9]{3}){$((per - 1))} +\|$" <<< "$box" && grep -q "^|   word$(printf %03d $((per + 1))) " <<< "$box"'
  done
  # the terminal made narrower while the job runs (160 -> 120): it wraps the old lines again, so the view clears
  # the screen once and draws itself at the new width from the top, then in place again
  mkdir -p "$D/.jobs/63"; echo "Snapshot import (resize.tar.gz)" > "$D/.jobs/63/title"; echo running > "$D/.jobs/63/state"
  date '+%Y-%m-%d %H:%M:%S' > "$D/.jobs/63/started"; echo "40.0|Importing|" > "$D/.jobs/63/progress"
  printf '%s\n' "10:00:00 Import started" "${long% }" > "$D/.jobs/63/log"
  sleep 30 & jp=$!
  echo "$jp" > "$D/.jobs/63/pid"
  ( sleep 8; echo done > "$D/.jobs/63/state" ) & dp=$!
  raw="$( { sleep 10; } | TERM=xterm LC_ALL=C timeout 60 script -qfec "stty cols 160 rows 40; (sleep 4; stty cols 120 < /dev/tty) & bash $D/rn1-technology-catalog-installer.sh jobs follow 63" /dev/null 2>&1 | tr -d '\r')"
  wait "$dp"; kill "$jp" 2>/dev/null; wait "$jp" 2>/dev/null
  clr=$'\033[H\033[2J'
  frames() { sed 's/\x1b[[(][0-9;?]*[A-Za-z]//g; s/\x1b[78]//g' | grep -E '^[+|]'; }
  pre="$(frames <<< "${raw%%"$clr"*}")"; post="$(frames <<< "${raw#*"$clr"}")"
  check "job view made narrower: the screen cleared once, the frames 160 wide before and 120 wide after" '{ [ "$(grep -oF "$clr" <<< "$raw" | wc -l)" -eq 1 ] && grep -q "^+- Job #63 " <<< "$pre" && grep -q "^+- Job #63 " <<< "$post" && [ -z "$(awk "length(\$0) != 160" <<< "$pre")" ] && [ -z "$(awk "length(\$0) != 120" <<< "$post")" ]; } || { sed "s/\x1b/^[/g" <<< "$raw" | tail -n 20 | sed "s/^/  | /"; false; }'
else
  echo "SKIP: script (util-linux) missing - no test of the width of the job view"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
