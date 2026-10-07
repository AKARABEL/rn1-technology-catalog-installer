#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/w"
rm -rf "$T"; mkdir -p "$T/bin" "$T/state"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
export LOG="$T/calls.log" ST="$T/state"
: > "$LOG"

cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; fmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -D|-H|--connect-timeout|--max-time|--retry|--retry-delay|--proto|-K) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $url" >> "$LOG"
emit() { if [ -n "$out" ] && [ "$out" != "-" ]; then cat > "$out"; else cat; fi; }
code=200
case "$url" in
  http://localhost:*/) printf '' | emit ;;
  https://raw.githubusercontent.com/*)
    if [ -f "$ST/new-installer.sh" ]; then emit < "$ST/new-installer.sh"; else code=404; printf '404' | emit; fi ;;
  https://hub.docker.com/v2/repositories/raynetgmbh/rayventory-catalog*/tags*)
    printf '%s' '{"count":2,"next":null,"results":[{"name":"stable","digest":"sha256:aaaa"},{"name":"26.3.4789.148","digest":"sha256:aaaa"},{"name":"25.4.4191.133","digest":"sha256:cccc"}]}' | emit ;;
  https://*/tags/list*) printf '%s' '{"name":"x","tags":[]}' | emit ;;
  *) code=404; printf '' | emit ;;
esac
[ -n "$fmt" ] && printf '%s' "${fmt//%\{http_code\}/$code}"
[ "$code" -ge 400 ] && exit 22
exit 0
EOF

# Fake docker: $ST/up = containers exist, $ST/vols = data volumes exist, $ST/images = local images.
# SHIM_FOREIGN_DIR: the containers of the project were started from that folder (SHIM_FOREIGN_IMAGE: their image).
# SHIM_DOCKER_DOWN: the daemon is not reachable. SHIM_VOL_BUSY: data volumes cannot be removed.
# SHIM_CONFIG_FAIL: docker compose config fails (broken files).
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
running() { [ -f "$ST/up" ]; }
# containers of another existing folder (a folder that is gone is this installation, moved)
foreign() { [ -n "${SHIM_FOREIGN_DIR:-}" ] && [ -d "$SHIM_FOREIGN_DIR" ]; }
[ -n "${SHIM_DOCKER_DOWN:-}" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1" in
  info) exit 0 ;;
  inspect)
    case "$3" in
      *working_dir*service*) echo "${SHIM_FOREIGN_DIR:-$PWD}|catalog-web|${SHIM_FOREIGN_IMAGE:-raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag" 2>/dev/null)}" ;;
      *working_dir*) echo "${SHIM_FOREIGN_DIR:-$PWD}" ;;
      *.Name*) echo "/other-$4" ;;
      *Config.Image*) echo "raynetgmbh/rayventory-catalog:$(cat "$ST/catalog_tag" 2>/dev/null)" ;;
      *State.Status*) echo "running none 0" ;;
    esac
    exit 0 ;;
  ps)
    running || exit 0
    case "$*" in
      *working_dir=*) [ -z "${SHIM_FOREIGN_DIR:-}" ] && printf '%s\n' c1 c2 c3 ;;
      *working_dir*Image*) echo "${SHIM_FOREIGN_DIR:-$PWD}|${SHIM_FOREIGN_IMAGE:-raynetgmbh/rayventory-catalog:25.4.4191.133}" ;;
      *working_dir*) echo "${SHIM_FOREIGN_DIR:-$PWD}" ;;
      *-aq*) printf '%s\n' c1 c2 c3 ;;
    esac
    exit 0 ;;
  rm) foreign || rm -f "$ST/up"; exit 0 ;;
  volume)
    case "$2" in
      ls) [ -f "$ST/vols" ] && printf '%s\n' inst_db_data inst_minio_storage ;;
      inspect) [ -f "$ST/vols" ] && [[ " inst_db_data inst_minio_storage " == *" $3 "* ]] || exit 1 ;;
      rm) [ -n "${SHIM_VOL_BUSY:-}" ] && exit 1; rm -f "$ST/vols" ;;
    esac
    exit 0 ;;
  network) [ "$2" = ls ] && running && echo net1; exit 0 ;;
  image)
    case "$2" in
      inspect) grep -qxF -- "$3" "$ST/images" 2>/dev/null || exit 1 ;;
      rm) grep -vxF -- "$3" "$ST/images" > "$ST/images.new"; mv "$ST/images.new" "$ST/images" ;;
    esac
    exit 0 ;;
  compose)
    shift
    while [ $# -gt 0 ]; do case "$1" in --env-file|-f|-p) shift 2 ;; *) break ;; esac; done
    sub="$1"; shift
    case "$sub" in
      version) echo "Docker Compose version v2.29.0" ;;
      config)
        [ -n "${SHIM_CONFIG_FAIL:-}" ] && exit 1
        case "${1:-}" in
          --services) printf '%s\n' mongo catalog-web ;;
          --volumes) printf '%s\n' db_data minio_storage ;;
        esac ;;
      ps)
        case " $* " in
          *" -a -q "*) running && printf '%s\n' c1 c2 c3 ;;
          *" -q "*) running && echo "id-${*: -1}" ;;
          *" --services "*) running && printf '%s\n' mongo catalog-web ;;
          *) echo "NAME STATUS" ;;
        esac ;;
      pull) ;;
      down)
        [ -n "${SHIM_CONFIG_FAIL:-}" ] && exit 1
        rm -f "$ST/up"
        if [[ " $* " == *" -v "* ]] && [ -z "${SHIM_VOL_BUSY:-}" ]; then rm -f "$ST/vols"; fi ;;
      up)
        touch "$ST/up" "$ST/vols"
        printf '%s\n' mongo:8 "raynetgmbh/rayventory-catalog:$(sed -n 's/^CATALOG_IMAGE=.*://p' .env)" > "$ST/images"
        sed -n 's/^CATALOG_IMAGE=.*://p' .env > "$ST/catalog_tag" ;;
      exec) [ "$3" = sh ] && printf 'MONGODUMP-ARCHIVE' ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
REAL_UNAME="$(command -v uname)"
cat > "$T/bin/uname" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-r" ]; then echo "\${SHIM_KERNEL:-6.8.0-generic}"; else exec "$REAL_UNAME" "\$@"; fi
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${SHIM_TZ:-Europe/Berlin}"\n' > "$T/bin/timedatectl"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

D="$T/inst"
I="$D/rn1-technology-catalog-installer.sh"
fresh() {
  rm -rf "$D" "$ST"/*; mkdir -p "$D"; cp "$NEW" "$I"
  sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/; s/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="10"/' "$I"
  : > "$LOG"
}
installed() {
  fresh
  (cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1)
  touch "$ST/up" "$ST/vols"; echo "25.4.4191.133" > "$ST/catalog_tag"
  printf '%s\n' mongo:8 raynetgmbh/rayventory-catalog:25.4.4191.133 > "$ST/images"
  : > "$LOG"
}

# 1. The plain menu starts with the guided tasks and names them again above the prompt
fresh
out="$(printf '0\n' | bash "$I" menu 2>&1)"
check "menu: START HERE with I, U and R first" 'grep -q "START HERE" <<< "$out" && grep -q "I) INSTALL" <<< "$out" && grep -q "U) UPDATE" <<< "$out" && grep -q "R) REMOVE" <<< "$out" && [ "$(grep -n "START HERE" <<< "$out" | cut -d: -f1)" -lt "$(grep -n " SETUP" <<< "$out" | cut -d: -f1)" ]'
check "menu: the tasks named above the prompt" 'tail -n 2 <<< "$out" | grep -q "I install . U update . R remove"'
check "help: guided tasks explained, 7 no longer the start" 'out2="$(printf "h\n\n0\n" | bash "$I" menu 2>&1)"; grep -q "START HERE - GUIDED TASKS" <<< "$out2" && ! grep -q "Start here on a new server" <<< "$out2"'

# 2. Install: check, settings, files, start with health check, data later, summary
fresh
out="$(printf 'i\ny\ny\n9090\ny\ny\ny\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install: all six steps shown" '( for s in 1 2 3 4 5 6; do grep -q "Install . step $s of 6" <<< "$out" || exit 1; done )'
check "install: setting from the questions written" 'grep -q "^CATALOG_WEB_PORT=\"9090\"$" "$I" && grep -q "CATALOG_WEB_PORT = \"9090\"" <<< "$out"'
check "install: files generated, stack started" '[ -f "$D/.env" ] && [ -f "$D/docker-compose.yml" ] && grep -q "compose.* up -d --remove-orphans" "$LOG"'
check "install: health check, addresses once, summary" 'grep -q "Health check" <<< "$out" && grep -q "The Catalog is installed" <<< "$out" && [ "$(grep -c "Catalog Web (direct)" <<< "$out")" -eq 1 ] && grep -q "http://.*:9090" <<< "$out"'
check "install: no data yet named in the summary" 'grep -q "The Catalog has no data yet" <<< "$out"'

# 3. Install on a folder that is already installed: repair, data, update or remove
out="$(printf 'i\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: existing installation found, cancel changes nothing" 'grep -q "This folder already has an installation" <<< "$out" && grep -q "Continue with the catalog data" <<< "$out" && grep -q "Cancelled" <<< "$out"'
out="$(printf 'i\n2\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "install again: continues with the catalog data (step 5)" 'grep -q "Install . step 5 of 6" <<< "$out" && ! grep -q "Install . step 3 of 6" <<< "$out"'

# 4. Repair keeps the installed version (an upgrade belongs to U with backup and rollback)
sed -i 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/' "$I"
out="$(printf 'i\n1\ny\ny\n\ny\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "repair: version of the installation kept" 'grep -q "the repair keeps 25.4.4191.133" <<< "$out" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$I" && grep -q "^CATALOG_IMAGE=.*:25.4.4191.133$" "$D/.env"'

# 5. Install stops when a step is declined or the input ends; nothing is half written
fresh
out="$(printf 'i\ny\ny\n\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "install: declined before the files - nothing written" '[ ! -f "$D/.env" ] && grep -q "Stopped. I starts it again" <<< "$out"'
fresh
printf 'i\ny\n' | bash "$I" menu >/dev/null 2>&1
check "install: end of input at a question changes no setting" 'grep -q "^INSTALL_NGINX_PROXY_MANAGER=\"true\"$" "$I"'

# 6. A port that another setting uses is refused at once
fresh
out="$(printf 'i\ny\ny\n80\n\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "install: port taken by another setting refused" 'grep -q "Port 80 is already set for NPM_HTTP_PORT" <<< "$out" && grep -q "^CATALOG_WEB_PORT=\"8080\"$" "$I"'

# 7. A step that fails stops the task (no start with broken files)
fresh
sed -i 's/^HEALTH_TIMEOUT=.*/HEALTH_TIMEOUT="0900"/' "$I"
out="$(printf 'i\ny\ny\n\ny\n\n0\n' | bash "$I" menu 2>&1)"
check "install: failed files step stops before the start" 'grep -q "The files could not be written" <<< "$out" && ! grep -q "compose.* up" "$LOG" && ! grep -q "Install . step 4 of 6" <<< "$out"'

# 7b. Step 5: a cancelled self-sync is not reported as set up
installed
out="$(printf 'i\n2\n1\n\n\n0\n' | bash "$I" menu 2>&1)"
check "install: cancelled data step - summary says there is no data yet" 'grep -q "The Catalog has no data yet" <<< "$out" && ! grep -q "synchronizes itself every day" <<< "$out"'

# 7c. A folder the installer cannot write to
fresh
chmod 555 "$D"
if ! touch "$D/probe" 2>/dev/null; then
  out="$(printf 'i\n\n0\n' | bash "$I" menu 2>&1)"
  check "install: folder not writable - stops at once" 'grep -q "is not writable - the installation writes its files there" <<< "$out" && [ ! -e "$D/.jobs" ]'
fi
chmod 755 "$D"

# 8. MongoDB 8 on a kernel that cannot run it: 7.0 offered before the check (new installation only)
fresh
out="$(printf 'i\ny\ny\ny\n\nn\n\n0\n' | SHIM_KERNEL=7.0.0-15-generic bash "$I" menu 2>&1)"
check "install: MongoDB 7.0 offered on kernel 7.0.0, check passes" 'grep -q "does not start on this Linux kernel" <<< "$out" && grep -q "^MONGO_TAG=\"7.0\"$" "$I" && grep -q "All required checks passed" <<< "$out"'
installed
out="$(printf 'i\n1\nn\n\n0\n' | SHIM_KERNEL=7.0.0-15-generic bash "$I" menu 2>&1)"
check "repair: no switch of existing MongoDB 8 data to 7.0" 'grep -q "A switch to 7.0 cannot read it" <<< "$out" && ! grep -q "^MONGO_TAG=\"7.0\"$" "$I" && ! grep -q "Set MONGO_TAG=\"7.0\"" <<< "$out"'

# 9. Another folder's installation with the same project name is not taken for this one
fresh
touch "$ST/up" "$ST/vols"
OTHER="$T/other/inst"; mkdir -p "$OTHER"
out="$(printf 'i\n0\n\n0\n' | SHIM_FOREIGN_DIR="$OTHER" bash "$I" menu 2>&1)"
check "install: installation of another folder found, take over offered" 'grep -q "A Catalog installation already exists on this server: $OTHER" <<< "$out" && grep -q "Take it over" <<< "$out" && ! grep -q "This folder already has an installation" <<< "$out"'
(cd "$D" && bash rn1-technology-catalog-installer.sh generate </dev/null >/dev/null 2>&1); : > "$LOG"
out="$(printf 'r\ny\n\nDELETE\n\n0\n' | SHIM_FOREIGN_DIR="$OTHER" bash "$I" menu 2>&1)"
check "remove: other installation's containers and volumes untouched" 'grep -q "Another Catalog installation uses the project name" <<< "$out" && ! grep -q "compose.* down\|^docker rm\|docker volume rm" "$LOG" && [ -f "$ST/up" ] && [ -f "$ST/vols" ]'

# 10. Update: installer first (not reachable here), then the Catalog
installed
out="$(printf 'u\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "update: installer step, then the Catalog" 'grep -q "Update . step 1 of 3" <<< "$out" && grep -q "The installer was not updated" <<< "$out" && grep -q "Newest Catalog:    26.3.4789.148" <<< "$out"'
check "update: declined upgrade is not reported as done" 'grep -q "Not upgraded: Catalog 25.4.4191.133 is installed, 26.3.4789.148 is available" <<< "$out" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$I" && ! grep -q "compose.* down" "$LOG"'

# 11. Update with a new installer: replaced, menu restarted, the update goes on with the Catalog
installed
sed 's/^HEALTH_TIMEOUT="600"$/HEALTH_TIMEOUT="600"\nNEW_SETTING="x"/' "$NEW" > "$ST/new-installer.sh"
out="$(printf 'u\ny\nn\n\n0\n' | bash "$I" menu 2>&1)"
check "update: new installer installed, settings kept" 'grep -q "^NEW_SETTING=\"x\"$" "$I" && grep -q "^CHECK_FOR_UPDATES=\"false\"$" "$I" && grep -q "Installer updated" <<< "$out"'
check "update: goes on with step 2 after the restart, notice shown" 'grep -q "Update . step 2 of 3" <<< "$out" && grep -q "Installer updated - your settings were kept" <<< "$out" && grep -q "Newest Catalog:" <<< "$out"'
rm -f "$ST/new-installer.sh"
out="$(printf '22\n0\n' | bash "$I" menu 2>&1)"
check "update: the resume does not leak into later runs" '! grep -q "Update . step" <<< "$out"'

# 12. Update on an empty folder
fresh
out="$(printf 'u\n\n0\n' | bash "$I" menu 2>&1)"
check "update: nothing installed - points to I" 'grep -q "Nothing is installed in this folder yet" <<< "$out"'

# 13. Remove: wrong word changes nothing
installed
mkdir -p "$D/snapshots"; echo x > "$D/snapshots/a.tar.gz"
out="$(printf 'r\nn\ny\n\nnope\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: overview lists containers, the volumes by name and images" 'grep -q "Containers  *3" <<< "$out" && grep -q "Data volumes  *2" <<< "$out" && grep -q "inst_db_data inst_minio_storage" <<< "$out" && grep -q "Docker images of the stack  *2" <<< "$out"'
check "remove: without DELETE nothing is removed" 'grep -q "Cancelled - nothing was removed" <<< "$out" && [ -f "$D/.env" ] && ! grep -q "compose.* down" "$LOG"'

# 14. Remove with the defaults: containers, volumes, images, files; snapshots and installer kept
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: compose down, then the data volumes one by one" 'grep -q "compose.* down --remove-orphans" "$LOG" && grep -q "^docker volume rm inst_db_data$" "$LOG" && [ ! -f "$ST/vols" ]'
check "remove: images of the stack removed once each" '[ "$(grep -c "^docker image rm mongo:8$" "$LOG")" -eq 1 ] && grep -q "^docker image rm raynetgmbh/rayventory-catalog:25.4.4191.133$" "$LOG" && [ ! -s "$ST/images" ]'
check "remove: generated files gone, snapshots and installer kept" '[ ! -f "$D/.env" ] && [ ! -f "$D/docker-compose.yml" ] && [ ! -e "$D/.jobs" ] && [ -f "$D/snapshots/a.tar.gz" ] && [ -f "$I" ]'
check "remove: done, I installs again" 'grep -q "The Catalog was removed from this server" <<< "$out" && grep -q "I installs it again" <<< "$out"'

# 15. Data volumes that cannot be removed: the files with the passwords stay
installed
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | SHIM_VOL_BUSY=1 bash "$I" menu 2>&1)"
check "remove: volume left - .env kept, not reported as removed" 'grep -q "Still there:.*volume inst_db_data" <<< "$out" && grep -q "the files with the passwords were kept" <<< "$out" && [ -f "$D/.env" ] && ! grep -q "The Catalog was removed" <<< "$out"'

# 15b. Folder moved after the installation (its containers name the old folder): still this stack
installed
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | SHIM_FOREIGN_DIR=/srv/gone/inst bash "$I" menu 2>&1)"
check "remove: moved folder - its stack is found and removed" 'grep -q "Containers  *3" <<< "$out" && grep -q "compose.* down --remove-orphans" "$LOG" && [ ! -f "$D/.env" ] && [ ! -f "$ST/vols" ]'

# 15d. A folder this user cannot look into is not "gone": its installation is left alone
installed
mkdir -p "$T/locked/inst"; chmod 000 "$T/locked"
if ! ls "$T/locked" >/dev/null 2>&1; then
  out="$(printf 'r\ny\n\nDELETE\n\n0\n' | SHIM_FOREIGN_DIR="$T/locked/inst" bash "$I" menu 2>&1)"
  check "remove: unreadable folder's installation untouched" 'grep -q "Another Catalog installation uses the project name" <<< "$out" && ! grep -q "compose.* down\|^docker rm\|docker volume rm" "$LOG" && [ -f "$ST/vols" ]'
fi
chmod 755 "$T/locked"

# 15e. backups/ and snapshots/: only the installer's own files go
installed
mkdir -p "$D/backups/laptop" "$D/snapshots"
echo x > "$D/backups/laptop/home.tar"; echo x > "$D/backups/mongo-20261001-1200.archive.gz"
echo x > "$D/snapshots/2026-10-05-daily.tar.gz"; echo x > "$D/snapshots/notes.txt"
out="$(printf 'r\nn\ny\na\n\nDELETE\n' | bash "$I" menu 2>&1)"
check "remove: user files in backups/ and snapshots/ kept" '[ -f "$D/backups/laptop/home.tar" ] && [ ! -e "$D/backups/mongo-20261001-1200.archive.gz" ] && [ -f "$D/snapshots/notes.txt" ] && [ ! -e "$D/snapshots/2026-10-05-daily.tar.gz" ]'

# 15c. Broken compose file: the volumes of the project are still found
installed
out="$(printf 'r\nn\ny\n\nDELETE\n\n0\n' | SHIM_CONFIG_FAIL=1 bash "$I" menu 2>&1)"
check "remove: compose config fails - volumes still offered and removed" 'grep -q "Data volumes  *2" <<< "$out" && grep -q "^docker volume rm inst_db_data$" "$LOG" && [ ! -f "$D/.env" ]'

# 16. Docker not reachable: nothing removed
installed
out="$(printf 'r\n\n0\n' | SHIM_DOCKER_DOWN=1 bash "$I" menu 2>&1)"
check "remove: Docker not reachable - stops, files kept" 'grep -q "Docker daemon is not reachable" <<< "$out" && [ -f "$D/.env" ]'

# 17. After "Stop the stack" (no containers) the images are still found and removed
installed
rm -f "$ST/up"
out="$(printf 'r\ny\n\nDELETE\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: images found without containers" 'grep -q "Docker images of the stack  *2" <<< "$out" && grep -q "^docker image rm mongo:8$" "$LOG"'
check "remove: volumes with no proof they are this folder's - not selected, .env kept" 'grep -q "not selected: they may be another installation" <<< "$out" && [ -f "$ST/vols" ] && [ -f "$D/.env" ]'

# 18. Remove everything including the installer; a toggle with a leading zero works
# (the download line uses curl where wget is missing, as on RHEL minimal)
if command -v wget >/dev/null 2>&1; then DL="wget -nv -O rn1-technology-catalog-installer.sh"; else DL="curl -fsSL -o rn1-technology-catalog-installer.sh"; fi
installed
out="$(printf 'r\nn\ny\na\n\nDELETE\n' | bash "$I" menu 2>&1)"; rc=$?
check "remove all: installer gone, exits with the download line" '[ "$rc" -eq 0 ] && [ ! -e "$I" ] && grep -q "The installer was removed too" <<< "$out" && grep -q "$DL" <<< "$out"'
installed
out="$(printf 'r\nn\ny\n04\n0\n\n0\n' | bash "$I" menu 2>&1)"; rc=$?
check "remove: toggle 04 understood (no octal error)" '[ "$rc" -eq 0 ] && grep -q "Cancelled - nothing was removed" <<< "$out" && ! grep -q "value too great" <<< "$out"'

# 19. Remove on an empty folder; leftover bundles are still offered
fresh
out="$(printf 'r\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: nothing to remove" 'grep -q "There is nothing to remove in this folder" <<< "$out"'
mkdir -p "$D/RN1-Technology-Catalog-26.3-20261001"
out="$(printf 'r\ny\n0\n\n0\n' | bash "$I" menu 2>&1)"
check "remove: leftover offline bundle offered" '! grep -q "There is nothing to remove" <<< "$out" && grep -q "Offline bundles (" <<< "$out" && ! grep -q "(passwords)" <<< "$out"'

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
