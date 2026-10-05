#!/usr/bin/env bash
set -u
NEW="$1"
if [ ! -f /usr/share/zoneinfo/Asia/Singapore ] || [ "$(TZ=Asia/Singapore date -d @0 +%z 2>/dev/null)" != "+0730" ]; then
  echo "SKIP: no time zone data (/usr/share/zoneinfo) - the time zone tests need Linux with tzdata."
  exit 0
fi
T="$(mktemp -d)/tz"
rm -rf "$T"; mkdir -p "$T/bin"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

cat > "$T/bin/timedatectl" <<'EOF'
#!/usr/bin/env bash
[ "${SHIM_TZ:-}" = none ] && exit 1
printf '%s\n' "${SHIM_TZ:-Europe/Berlin}"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/docker"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

N="rn1-technology-catalog-installer.sh"
fresh() { rm -rf "$T/inst"; mkdir -p "$T/inst"; cp "$NEW" "$T/inst/$N"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$T/inst/$N"; }
fresh
D="$T/inst"; I="$D/$N"
cc() { bash "$I" __cron_convert "$@"; }

# 1. Conversion of cron expressions between time zones
check "Berlin 07:30 in July = Singapore 13:30" '[ "$(cc "30 7 * * *" Europe/Berlin Asia/Singapore 2026-07-15)" = "30 13 * * *" ]'
check "Berlin 07:30 in January = Singapore 14:30" '[ "$(cc "30 7 * * *" Europe/Berlin Asia/Singapore 2026-01-15)" = "30 14 * * *" ]'
check "to UTC" '[ "$(cc "30 7 * * *" Europe/Berlin Etc/UTC 2026-07-15)" = "30 5 * * *" ]'
check "half-hour zone (Kolkata)" '[ "$(cc "30 7 * * *" Europe/Berlin Asia/Kolkata 2026-07-15)" = "0 11 * * *" ]'
check "45-minute zone (Kathmandu)" '[ "$(cc "30 7 * * *" Europe/Berlin Asia/Kathmandu 2026-07-15)" = "15 11 * * *" ]'
check "same offsets: unchanged" '[ "$(cc "30 7 * * *" Europe/Berlin Europe/Paris 2026-07-15)" = "30 7 * * *" ]'
check "disabled stays disabled" '[ "$(cc "-" Europe/Berlin Asia/Singapore 2026-07-15)" = "-" ]'
check "weekdays move to the next day" '[ "$(cc "30 23 * * 1-5" Europe/Berlin Asia/Singapore 2026-07-15)" = "30 5 * * 2-6" ]'
check "weekday names move to the day before" '[ "$(cc "30 1 * * MON-FRI" Europe/Berlin America/New_York 2026-07-15)" = "30 19 * * 0-4" ]'
check "Sunday as 7 moves to Monday" '[ "$(cc "0 23 * * 7" Europe/Berlin Asia/Singapore 2026-07-15)" = "0 5 * * 1" ]'
check "Saturday moves to Sunday" '[ "$(cc "0 23 * * 6" Europe/Berlin Asia/Singapore 2026-07-15)" = "0 5 * * 0" ]'
check "several hours" '[ "$(cc "0 */8 * * *" Europe/Berlin Asia/Singapore 2026-07-15)" = "0 6,14,22 * * *" ]'
check "every 10 minutes, whole-hour shift: unchanged" '[ "$(cc "*/10 * * * *" Europe/Berlin Asia/Singapore 2026-07-15)" = "*/10 * * * *" ]'
check "every hour at :15, half-hour shift" '[ "$(cc "15 * * * *" Europe/Berlin Asia/Kolkata 2026-07-15)" = "45 * * * *" ]'
check "minute list, whole-hour shift" '[ "$(cc "0,30 7 * * *" Europe/Berlin Asia/Singapore 2026-07-15)" = "0,30 13 * * *" ]'
check "day of the month on the same day" '[ "$(cc "0 4 1 * *" Europe/Berlin Asia/Singapore 2026-07-15)" = "0 10 1 * *" ]'
check "day of the month that moves: refused" '! cc "0 22 1 * *" Europe/Berlin Asia/Singapore 2026-07-15 >/dev/null'
check "minute list with half-hour shift: refused" '! cc "0,30 7 * * *" Europe/Berlin Asia/Kolkata 2026-07-15 >/dev/null'
check "hours split over two days with weekdays: refused" '! cc "0 16-20 * * 1" Europe/Berlin Asia/Singapore 2026-07-15 >/dev/null'
check "six fields: refused" '! cc "0 30 7 * * *" Europe/Berlin Asia/Singapore 2026-07-15 >/dev/null'
check "more than 24 h apart: back to Saturday 23:00" '[ "$(cc "0 0 * * *" Pacific/Kiritimati Pacific/Pago_Pago 2026-07-15)" = "0 23 * * *" ] && [ "$(cc "0 0 * * 1" Pacific/Kiritimati Pacific/Pago_Pago 2026-07-15)" = "0 23 * * 6" ]'
check "more than 24 h apart: two days later" '[ "$(cc "30 23 * * 1" Pacific/Pago_Pago Pacific/Kiritimati 2026-07-15)" = "30 0 * * 3" ] && [ "$(cc "59 23 * * 5-7" Etc/GMT+12 Pacific/Tongatapu 2026-04-15)" = "59 0 * * 0-2" ]'
check "more than 24 h apart: mixed day shifts refused" '! cc "0,30 * * * 6" Pacific/Auckland Etc/GMT+12 2026-10-10 >/dev/null && ! cc "8 22,23 * * 1,3,5" Etc/GMT+12 Pacific/Chatham 2026-12-20 >/dev/null'
check "zone without data on this server: refused" '! cc "30 7 * * *" Europe/Berlin Mars/Olympus 2026-07-15 >/dev/null'


if [ "$(TZ=Europe/Berlin date +%z)" = "+0200" ]; then EXP="30 13 * * *"; EXPT="13:30"; else EXP="30 14 * * *"; EXPT="14:30"; fi

# 2. Menu option 2 on a server in Singapore: question, settings, .env
out="$(printf '2\ny\n\n0\n' | SHIM_TZ=Asia/Singapore bash "$I" menu 2>&1)"
check "menu note before the change" 'grep -q "The server runs in Asia/Singapore, the Catalog in Europe/Berlin (TZ) - option 2 offers to align it" <<< "$out"'
check "question names both zones and times" 'grep -q "This server runs in the time zone Asia/Singapore, the Catalog is set to Europe/Berlin (TZ)." <<< "$out" && grep -q "runs at 07:30 Europe/Berlin, that is $EXPT Asia/Singapore." <<< "$out"'
check "note about clock changes on different dates" 'grep -q "change their clocks on different dates" <<< "$out"'
check "TZ and AUTOSYNC_CRON changed in the settings" 'grep -qxF "TZ=\"Asia/Singapore\"" "$I" && grep -qxF "AUTOSYNC_CRON=\"$EXP\"" "$I"'
check ".env written with the new values" 'grep -qxF "TZ=Asia/Singapore" "$D/.env" && grep -qxF "AUTOSYNC_CRON=$EXP" "$D/.env"'
check "disabled job stays disabled" 'grep -q "^VULNERABILITIES_CACHING_CRON=\"-\"$" "$I"'
check "compose file keeps the variables" 'grep -q "Synchronization__AutoSyncJobCronExpression: \"\${AUTOSYNC_CRON}\"" "$D/docker-compose.yml" && grep -q "TZ: \"\${TZ}\"" "$D/docker-compose.yml"'
out="$(printf '2\n1\n\n0\n' | SHIM_TZ=Asia/Singapore bash "$I" menu 2>&1)"
check "no question once aligned" '! grep -q "This server runs in the time zone" <<< "$out" && ! grep -q "The server runs in" <<< "$out"'

# 3. Answer no: asked once, the menu note disappears; 'timezone' asks again
fresh
out="$(printf '2\nn\n\n0\n' | SHIM_TZ=America/New_York bash "$I" menu 2>&1)"
check "no: TZ and cron unchanged" 'grep -q "^TZ=\"Europe/Berlin\"$" "$I" && grep -q "^AUTOSYNC_CRON=\"30 7 \* \* \*\"$" "$I" && grep -q "^TZ=Europe/Berlin$" "$D/.env"'
out="$(printf '2\n1\n\n0\n' | SHIM_TZ=America/New_York bash "$I" menu 2>&1)"
check "no: not asked again, no menu note" '! grep -q "This server runs in the time zone" <<< "$out" && ! grep -q "The server runs in" <<< "$out"'
out="$(printf 'y\n' | SHIM_TZ=America/New_York bash "$I" timezone 2>&1)"
check "timezone command asks again and converts" 'grep -q "^TZ=\"America/New_York\"$" "$I" && grep -Eq "^AUTOSYNC_CRON=\"30 [01] \* \* \*\"$" "$I" && grep -q "Apply it with option 2 and 6" <<< "$out"'

# 4. A new server zone after an earlier no is asked again
fresh
printf '2\nn\n\n0\n' | SHIM_TZ=America/New_York bash "$I" menu >/dev/null 2>&1
out="$(printf '2\n1\nn\n\n0\n' | SHIM_TZ=Asia/Tokyo bash "$I" menu 2>&1)"
check "other server zone: asked again" 'grep -q "This server runs in the time zone Asia/Tokyo" <<< "$out"'

# 5. UTC names, unreadable zone, CLI without questions
fresh
sed -i 's#^TZ=.*#TZ="UTC"#' "$I"
out="$(SHIM_TZ=Etc/UTC bash "$I" timezone </dev/null 2>&1)"
check "UTC and Etc/UTC are the same zone" 'grep -q "TZ (UTC) is the time zone of this server." <<< "$out"'
fresh
out="$(SHIM_TZ=Asia/Singapore bash "$I" generate </dev/null 2>&1)"
check "CLI generate does not ask" '! grep -q "This server runs in the time zone" <<< "$out" && grep -q "^TZ=Europe/Berlin$" "$D/.env"'
out="$(SHIM_TZ=Asia/Singapore bash "$I" check </dev/null 2>&1)"
check "check reports the different zones" 'grep -q "Time zone: the Catalog uses Europe/Berlin, this server Asia/Singapore" <<< "$out"'
out="$(SHIM_TZ=Not/AZone bash "$I" check </dev/null 2>&1)"
check "server zone without data is named" 'grep -q "there is no time zone data for Not/AZone here" <<< "$out"'

# 5b. posix/ and right/ names from timedatectl, zones without data, single-quoted settings
fresh
out="$(SHIM_TZ=posix/Europe/Berlin bash "$I" timezone </dev/null 2>&1)"
check "posix/ prefix of the server zone ignored" 'grep -q "TZ (Europe/Berlin) is the time zone of this server." <<< "$out"'
fresh
sed -i 's#^TZ=.*#TZ="Mars/Olympus"#' "$I"
out="$(printf 'y\n' | SHIM_TZ=Asia/Singapore bash "$I" timezone 2>&1)"
check "zone without data: explained, nothing changed" 'grep -q "Mars/Olympus is not a time zone this server knows" <<< "$out" && grep -qxF "TZ=\"Mars/Olympus\"" "$I" && grep -qxF "AUTOSYNC_CRON=\"30 7 * * *\"" "$I"'
fresh
sed -i "0,/^TZ=/s#^TZ=.*#TZ='Europe/Berlin'#" "$I"
out="$(printf 'y\n' | SHIM_TZ=Asia/Singapore bash "$I" timezone 2>&1)"
check "single-quoted TZ setting is changed as well" 'grep -qxF "TZ=\"Asia/Singapore\"" "$I" && grep -qxF "AUTOSYNC_CRON=\"$EXP\"" "$I" && ! grep -q "^TZ='"'"'" "$I"'

# 5c. posix/ in TZ, links, empty TZ, read-only installer, duplicate lines
fresh
sed -i 's#^TZ=.*#TZ="posix/Europe/Berlin"#' "$I"
out="$(SHIM_TZ=Europe/Berlin bash "$I" timezone </dev/null 2>&1)"
check "posix/ prefix in TZ: same zone" 'grep -q "is the time zone of this server." <<< "$out"'
if [ -e /usr/share/zoneinfo/Europe/Bratislava ] && cmp -s /usr/share/zoneinfo/Europe/Bratislava /usr/share/zoneinfo/Europe/Prague; then
  fresh
  sed -i 's#^TZ=.*#TZ="Europe/Bratislava"#' "$I"
  out="$(SHIM_TZ=Europe/Prague bash "$I" timezone </dev/null 2>&1)"
  check "link names of one zone are the same zone" 'grep -q "TZ (Europe/Bratislava) is the time zone of this server." <<< "$out"'
fi
fresh
sed -i '0,/^TZ=/s#^TZ=.*#TZ=""#' "$I"
out="$(printf 'y\n' | SHIM_TZ=Asia/Singapore bash "$I" timezone 2>&1)"
check "empty TZ counts as UTC" 'grep -q "the Catalog is set to UTC (TZ)" <<< "$out" && grep -qxF "TZ=\"Asia/Singapore\"" "$I" && grep -qxF "AUTOSYNC_CRON=\"30 15 * * *\"" "$I"'
fresh
chmod 555 "$I"; tmpd="$(mktemp -d)"
out="$(printf 'y\n' | TMPDIR="$tmpd" SHIM_TZ=Asia/Singapore bash "$I" timezone 2>&1)"
check "read-only installer: explained, no OK, no temp copy left" 'grep -q "cannot be changed (not a writable file)" <<< "$out" && ! grep -q "TZ is now" <<< "$out" && [ -z "$(ls -A "$tmpd")" ]'
chmod 755 "$I"; rm -rf "$tmpd"
fresh
sed -i '0,/^LOG_LEVEL_DEFAULT=/s#^LOG_LEVEL_DEFAULT=.*#&\nTZ="America/New_York"#' "$I"
out="$(printf 'y\n' | SHIM_TZ=Asia/Singapore bash "$I" timezone 2>&1)"
check "duplicate TZ line: the line bash uses counts, both are changed" 'grep -q "the Catalog is set to America/New_York" <<< "$out" && [ "$(grep -c "^TZ=\"Asia/Singapore\"$" "$I")" -eq 2 ] && ! grep -q "^TZ=\"America/New_York\"$" "$I"'

# 5d. No answer is no decision; an empty TZ remembers a no; read-only installer has no note
fresh
out="$(SHIM_TZ=Asia/Singapore bash "$I" timezone </dev/null 2>&1)"
check "no answer: nothing remembered" 'grep -q "No answer - nothing was changed." <<< "$out" && [ ! -e "$D/.timezone-kept" ]'
fresh
sed -i '0,/^TZ=/s#^TZ=.*#TZ=""#' "$I"
printf '2\nn\n\n0\n' | SHIM_TZ=Asia/Singapore bash "$I" menu >/dev/null 2>&1
out="$(printf '2\n1\n\n0\n' | SHIM_TZ=Asia/Singapore bash "$I" menu 2>&1)"
check "empty TZ: a no is remembered" '! grep -q "This server runs in the time zone" <<< "$out" && ! grep -q "The server runs in" <<< "$out"'
fresh
chmod 555 "$I"
out="$(printf '0\n' | SHIM_TZ=Asia/Singapore bash "$I" menu 2>&1)"
chmod 755 "$I"
check "read-only installer: no alignment note" '! grep -q "option 2 offers to align it" <<< "$out"'
fresh
sed -i '0,/^AUTOSYNC_CRON=/s#^AUTOSYNC_CRON=.*#AUTOSYNC_CRON="30 7 * * *"  \# 07:30 Berlin#' "$I"
out="$(printf '2\ny\n\n0\n' | SHIM_TZ=America/New_York bash "$I" menu 2>&1)"
check "cron with a comment is converted in the menu" 'grep -qxF "AUTOSYNC_CRON=\"30 1 * * *\"" "$I" && grep -qxF "TZ=\"America/New_York\"" "$I"'

# 5e. Existing installation: Enter alone keeps TZ; a second Apply in Updates does not ask with old values
fresh
SHIM_TZ=Asia/Singapore bash "$I" generate </dev/null >/dev/null 2>&1
out="$(printf '2\n1\n\n\n0\n' | SHIM_TZ=Asia/Singapore bash "$I" menu 2>&1)"
check "existing installation: Enter keeps TZ" 'grep -q "This server runs in the time zone Asia/Singapore" <<< "$out" && grep -qxF "TZ=\"Europe/Berlin\"" "$I" && grep -qxF "TZ=Europe/Berlin" "$D/.env"'
fresh
SHIM_TZ=Asia/Singapore bash "$I" generate </dev/null >/dev/null 2>&1
printf '#!/usr/bin/env bash\nexit 22\n' > "$T/bin/curl"; chmod +x "$T/bin/curl"
out="$(printf '8\ns\ny\ny\ns\ny\n0\n\n0\n' | SHIM_TZ=Asia/Singapore bash "$I" menu 2>&1)"
rm -f "$T/bin/curl"
check "Updates: asked once, settings and .env agree" '[ "$(grep -c "This server runs in the time zone" <<< "$out")" -eq 1 ] && grep -qxF "TZ=\"Asia/Singapore\"" "$I" && grep -qxF "TZ=Asia/Singapore" "$D/.env" && grep -qxF "AUTOSYNC_CRON=$EXP" "$D/.env"'

# 6. Expression that cannot be converted: TZ changes, the expression stays and is named
fresh
sed -i 's#^AUTOSYNC_CRON=.*#AUTOSYNC_CRON="0 22 1 * *"#' "$I"
out="$(printf 'y\n' | SHIM_TZ=Asia/Singapore bash "$I" timezone 2>&1)"
check "not convertible: warned, TZ changed, expression kept" 'grep -q "AUTOSYNC_CRON \"0 22 1 \* \*\" cannot be converted automatically" <<< "$out" && grep -q "^TZ=\"Asia/Singapore\"$" "$I" && grep -q "^AUTOSYNC_CRON=\"0 22 1 \* \*\"$" "$I"'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
