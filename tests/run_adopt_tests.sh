#!/usr/bin/env bash
set -u
NEW="$1"
SP="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)/ad"
rm -rf "$T"; mkdir -p "$T/bin" "$T/oldroot" "$T/rn1-technology-catalog"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
export LOG="$T/podman.log" UNHANDLED="$T/unhandled.log" OLD="$T/oldroot"
: > "$LOG"; : > "$UNHANDLED"

sed -e 's/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="8181"/' -e 's/^INSTALL_NGINX_PROXY_MANAGER=.*/INSTALL_NGINX_PROXY_MANAGER="false"/' \
    -e 's/^MONGO_TAG=.*/MONGO_TAG="7.0"/' -e 's/^AUTOSYNC_CRON=.*/AUTOSYNC_CRON="15 3 * * 1-5"/' "$SP/original.sh" > "$OLD/catalog.sh"
(cd "$OLD" && bash catalog.sh >/dev/null 2>&1)
old_env="$(cksum < "$OLD/.env")"; old_compose="$(cksum < "$OLD/docker-compose.yml")"

# Fake rootful Podman 5.7 with one container: catalog-web of compose project "root", started in $OLD
# (SHIM_NO_LABELS=1: the container carries no compose labels). Calls it does not know are logged in
# $UNHANDLED and fail like Podman does (exit 125).
cat > "$T/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$LOG"
unhandled() { echo "UNHANDLED podman $ARGS" >> "$UNHANDLED"; echo "Error: fake podman: unhandled: $ARGS" >&2; exit 125; }
ARGS="$*"
CID=c0ffee000001
labels() {
  if [ "${SHIM_NO_LABELS:-}" != 1 ]; then
    printf '%s\n' "com.docker.compose.project=root" "com.docker.compose.service=catalog-web" \
      "com.docker.compose.project.working_dir=$OLD" "com.docker.compose.project.config_files=$OLD/docker-compose.yml"
  fi
}
label() { labels | sed -n "s#^$1=##p" | head -n 1; }
# render TEMPLATE -> the template filled with the fields of the container (podman container inspect)
render() {
  local t="$1" k
  sub() { t=${t//"$1"/"$2"}; }
  for k in com.docker.compose.project.working_dir com.docker.compose.project.config_files \
    com.docker.compose.project.environment_file com.docker.compose.project com.docker.compose.service; do
    sub "{{index .Config.Labels \"$k\"}}" "$(label "$k")"
  done
  sub '{{.Config.Image}}' docker.io/raynetgmbh/rayventory-catalog:25.4.4191.133
  sub '{{.State.Status}}' running
  sub '{{with .State.Health}}{{or .Status "none"}}{{else}}none{{end}}' none
  sub '{{.RestartCount}}' 0
  sub '{{.Name}}' catalog-web
  case "$t" in *'{{'*) unhandled ;; esac
  printf '%s\n' "$t"
}
case "${1:-}" in
  --version) echo "podman version 5.7.0" ;;
  info)
    if [ $# -eq 1 ]; then exit 0; fi
    [ "$2" = --format ] && [ $# -eq 3 ] || unhandled
    case "$3" in
      '{{.Host.Security.Rootless}}') echo false ;;
      *) unhandled ;;
    esac ;;
  ps)
    shift; match=1
    while [ $# -gt 0 ]; do
      case "$1" in
        -aq|-qa) ;;
        --filter)
          case "${2:-}" in
            label=*=*) f="${2#label=}"; [ "$(label "${f%%=*}")" = "${f#*=}" ] || match=0 ;;
            volume=*|ancestor=*) match=0 ;;
            *) unhandled ;;
          esac
          shift ;;
        *) unhandled ;;
      esac
      shift
    done
    if [ "$match" = 1 ]; then echo "$CID"; fi ;;
  container)
    [ "${2:-}" = inspect ] && [ "${3:-}" = --format ] && [ $# -ge 5 ] || unhandled
    tmpl="$4"; shift 4
    for id in "$@"; do
      if [ "$id" != "$CID" ]; then echo "Error: no such container $id" >&2; exit 125; fi
      render "$tmpl"
    done ;;
  volume)
    case "${2:-} ${3:-} ${4:-}" in
      "ls -q --filter") ;;
      exists\ *) exit 1 ;;
      *) unhandled ;;
    esac ;;
  compose)
    # like Podman: run the provider the installer exported
    if [ -z "${PODMAN_COMPOSE_PROVIDER:-}" ]; then
      echo "Error: looking up compose provider failed" >&2; unhandled
    fi
    shift; exec "$PODMAN_COMPOSE_PROVIDER" "$@" ;;
  *) unhandled ;;
esac
exit 0
EOF
chmod +x "$T/bin/podman"
# The provider behind "podman compose" (the official Docker Compose)
cat > "$T/bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
ARGS="$*"
unhandled() { echo "UNHANDLED docker-compose $ARGS" >> "$UNHANDLED"; echo "fake docker-compose: unhandled: $ARGS" >&2; exit 1; }
while [ $# -gt 0 ]; do case "$1" in -p|--env-file|-f) shift 2 ;; *) break ;; esac; done
case "${1:-}" in
  version) if [ "${2:-}" = --short ]; then echo "5.6.0"; else echo "Docker Compose version v5.6.0"; fi ;;
  ps)
    case "${2:-}" in
      "") ;;
      --services) echo catalog-web ;;
      *) unhandled ;;
    esac ;;
  config)
    case "${2:-}" in
      --services) echo catalog-web ;;
      --quiet|--volumes|--images) ;;
      *) unhandled ;;
    esac ;;
  *) unhandled ;;
esac
exit 0
EOF
chmod +x "$T/bin/docker-compose"
export RN1_COMPOSE_PROVIDER="$T/bin/docker-compose"
# systemd: podman.socket active, podman-restart.service enabled
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
case "$*" in
  "is-active --quiet podman.socket"|"is-active podman.socket") exit 0 ;;
  "is-enabled podman-restart.service") echo enabled ;;
  *) echo "UNHANDLED systemctl $*" >> "$UNHANDLED"; exit 1 ;;
esac
EOF
chmod +x "$T/bin/systemctl"
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
D="$T/rn1-technology-catalog"; cp "$NEW" "$D/rn1-technology-catalog-installer.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D/rn1-technology-catalog-installer.sh"

# 1. The menu notices the existing installation
out="$(printf '0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "menu points to the existing installation" 'grep -q "A Catalog installation already exists in $OLD - option 23" <<< "$out"'

# 2. Take over via option 23
out="$(printf '23\ny\n0\n' | bash "$D/rn1-technology-catalog-installer.sh" menu 2>&1)"
check "shows what was found, passwords hidden" 'grep -q "Compose project  *root" <<< "$out" && grep -q "Catalog version  *25.4.4191.133" <<< "$out" && grep -q "MONGO_INITDB_ROOT_PASSWORD  *found (not shown)" <<< "$out" && ! grep -q "$(sed -n "s/^MONGO_INITDB_ROOT_PASSWORD=//p" "$OLD/.env")" <<< "$out"'
check "listing: version of the docker.io image, state from podman" 'grep -q "project root  *Catalog 25.4.4191.133  *running$" <<< "$out"'
same_pw() { local k; for k in MONGO_INITDB_ROOT_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS; do [ "$(grep "^$k=" "$D/.env")" = "$(grep "^$k=" "$OLD/.env")" ] || return 1; done; }
check ".env copied with the same passwords (+ project name)" 'same_pw && grep -q "^COMPOSE_PROJECT_NAME=root$" "$D/.env"'
check "compose file copied unchanged" 'cmp -s "$D/docker-compose.yml" "$OLD/docker-compose.yml"'
check "settings imported into the script" 'grep -q "^CATALOG_WEB_PORT=\"8181\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^INSTALL_NGINX_PROXY_MANAGER=\"false\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^MONGO_TAG=\"7.0\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^AUTOSYNC_CRON=\"15 3 \* \* 1-5\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^CATALOG_VERSION=\"25.4.4191.133\"$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^COMPOSE_PROJECT_NAME=\"root\"$" "$D/rn1-technology-catalog-installer.sh"'
check "template lines untouched" 'grep -q "^CATALOG_WEB_PORT=\${CATALOG_WEB_PORT}$" "$D/rn1-technology-catalog-installer.sh" && grep -q "^MONGO_TAG=\${MONGO_TAG}$" "$D/rn1-technology-catalog-installer.sh"'
check "difference to the template shown (MinIO image)" 'grep -q "differs from the one this installer generates" <<< "$out" && grep -q "image: minio/minio" <<< "$out" && grep -q "image: ghcr.io/golithus/minio" <<< "$out"'
check "reloaded with notice" 'grep -q "Installation in $OLD taken over." <<< "$out" && grep -q "Files  : .env present" <<< "$out"'
check "old installation untouched" '[ "$(cksum < "$OLD/.env")" = "$old_env" ] && [ "$(cksum < "$OLD/docker-compose.yml")" = "$old_compose" ]'
check "installer backup kept" 'ls "$D"/rn1-technology-catalog-installer.sh.bak-* >/dev/null 2>&1'

# 3. Compose commands now use the old project (same containers, same volumes)
: > "$LOG"; bash "$D/rn1-technology-catalog-installer.sh" status </dev/null >/dev/null 2>&1
check "podman compose runs with -p root" 'grep -q "^podman compose -p root --env-file .env -f docker-compose.yml ps$" "$LOG"'
check "status checks rootful Podman and its API socket first" 'grep -qxF "podman info --format {{.Host.Security.Rootless}}" "$LOG" && grep -qxF "systemctl is-active --quiet podman.socket" "$LOG"'

# 4. Generating keeps the passwords and the project name
bash "$D/rn1-technology-catalog-installer.sh" generate </dev/null >/dev/null 2>&1
check "generate keeps passwords and project" '[ "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$D/.env")" = "$(grep "^MONGO_INITDB_ROOT_PASSWORD=" "$OLD/.env")" ] && grep -q "^COMPOSE_PROJECT_NAME=root$" "$D/.env" && grep -q "^CATALOG_WEB_PORT=8181$" "$D/.env"'

# 5. CLI with a folder when the containers carry no compose labels
D2="$T/second"; mkdir -p "$D2"; cp "$NEW" "$D2/rn1-technology-catalog-installer.sh"; sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$D2/rn1-technology-catalog-installer.sh"
out="$(SHIM_NO_LABELS=1 bash "$D2/rn1-technology-catalog-installer.sh" adopt "$OLD" </dev/null 2>&1)"; rc=$?
check "CLI adopt FOLDER without labels" '[ "$rc" -eq 0 ] && grep -q "^CATALOG_WEB_PORT=\"8181\"$" "$D2/rn1-technology-catalog-installer.sh" && grep -q "^COMPOSE_PROJECT_NAME=\"oldroot\"$" "$D2/rn1-technology-catalog-installer.sh"'

# 6. Nothing found
D3="$T/third"; mkdir -p "$D3"; cp "$NEW" "$D3/rn1-technology-catalog-installer.sh"
out="$(SHIM_NO_LABELS=1 bash "$D3/rn1-technology-catalog-installer.sh" adopt "$T/does-not-exist" </dev/null 2>&1)"
check "nothing found message" 'grep -q "No other Catalog installation found" <<< "$out"'

N="rn1-technology-catalog-installer.sh"
# installer DIR NAME [sed program] -> copy of the new installer, CHECK_FOR_UPDATES off, more edits
installer() {
  mkdir -p "$1"; cp "$NEW" "$1/$2"
  sed -i "s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES=\"false\"/; ${3:-}" "$1/$2"
}
gen() { (cd "$1" && SHIM_NO_LABELS=1 bash "$2" generate </dev/null >/dev/null 2>&1); }
menu() { local d="$1" in="$2"; printf "$in" | SHIM_NO_LABELS=1 bash "$d/$N" menu 2>&1; }
PORT9393='0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="9393"/'

# 7. New installer downloaded next to the installation of an older catalog.sh
S="$T/same"; installer "$S" catalog.sh "$PORT9393; 0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG=\"7.0\"/"; gen "$S" catalog.sh
env_before="$(cksum < "$S/.env")"; compose_before="$(cksum < "$S/docker-compose.yml")"
installer "$S" "$N"
out="$(menu "$S" '0\n')"
check "same folder: menu names the older installer" 'grep -q "catalog.sh in this folder has other settings - option 23 takes them over" <<< "$out" && ! grep -q "option 2 regenerates them" <<< "$out"'
out="$(menu "$S" '2\n1\nn\n\n0\n')"
check "same folder: option 2 warns first, no changes nothing" 'grep -q "catalog.sh in this folder has other settings than $N, and generating would change the installation." <<< "$out" && grep -q "Cancelled - nothing was changed." <<< "$out" && [ "$(cksum < "$S/.env")" = "$env_before" ] && [ "$(cksum < "$S/docker-compose.yml")" = "$compose_before" ]'
out="$(SHIM_NO_LABELS=1 bash "$S/$N" generate </dev/null 2>&1)"; rc=$?
check "same folder: CLI generate refuses with both ways out" '[ "$rc" -ne 0 ] && grep -q "adopt ./catalog.sh" <<< "$out" && grep -q "rename or remove it" <<< "$out" && [ "$(cksum < "$S/.env")" = "$env_before" ]'
out="$(SHIM_NO_LABELS=1 bash "$S/$N" adopt </dev/null 2>&1)"; rc=$?
check "same folder: CLI adopt without a file name does not guess" '[ "$rc" -ne 0 ] && grep -q "Name the one that manages this installation" <<< "$out" && [ -f "$S/catalog.sh" ]'
out="$(menu "$S" '23\ny\ny\n0\n')"
check "same folder: differences listed" 'grep -q "CATALOG_WEB_PORT *8080 -> 9393" <<< "$out" && grep -q "MONGO_TAG *8 -> 7.0" <<< "$out"'
check "same folder: settings taken over, new update address kept" 'grep -qxF "CATALOG_WEB_PORT=\"9393\"" "$S/$N" && grep -qxF "MONGO_TAG=\"7.0\"" "$S/$N" && grep -q "^INSTALLER_URL=\".*/$N\"$" "$S/$N"'
check "same folder: old installer renamed, files untouched" '[ ! -e "$S/catalog.sh" ] && ls "$S"/catalog.sh.replaced-* >/dev/null 2>&1 && [ "$(cksum < "$S/.env")" = "$env_before" ] && [ "$(cksum < "$S/docker-compose.yml")" = "$compose_before" ]'
out="$(menu "$S" '0\n')"
check "same folder: afterwards the files match the settings" '! grep -q "other settings" <<< "$out" && ! grep -q "option 2 regenerates them" <<< "$out"'

# 8. Next to the original generator script: CLI takeover of the named file
G="$T/gen"; mkdir -p "$G"
sed -e 's/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="8282"/' "$SP/original.sh" > "$G/generate_catalog_stack.sh"
(cd "$G" && bash generate_catalog_stack.sh >/dev/null 2>&1)
installer "$G" "$N"
out="$(SHIM_NO_LABELS=1 bash "$G/$N" adopt ./generate_catalog_stack.sh </dev/null 2>&1)"; rc=$?
check "original generator: CLI takes over the named file" '[ "$rc" -eq 0 ] && grep -qxF "CATALOG_WEB_PORT=\"8282\"" "$G/$N" && ls "$G"/generate_catalog_stack.sh.replaced-* >/dev/null 2>&1'

# 9. Many differences are all taken over and counted
M="$T/many"; installer "$M" catalog.sh '0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="7001"/; 0,/^MONGO_PORT_HOST=/s/^MONGO_PORT_HOST=.*/MONGO_PORT_HOST="7002"/; 0,/^MINIO_API_PORT_HOST=/s/^MINIO_API_PORT_HOST=.*/MINIO_API_PORT_HOST="7003"/; 0,/^MINIO_CONSOLE_PORT_HOST=/s/^MINIO_CONSOLE_PORT_HOST=.*/MINIO_CONSOLE_PORT_HOST="7004"/; 0,/^RABBITMQ_AMQP_PORT=/s/^RABBITMQ_AMQP_PORT=.*/RABBITMQ_AMQP_PORT="7005"/; 0,/^RABBITMQ_UI_PORT=/s/^RABBITMQ_UI_PORT=.*/RABBITMQ_UI_PORT="7006"/; 0,/^OPENSEARCH_DASHBOARDS_PORT=/s/^OPENSEARCH_DASHBOARDS_PORT=.*/OPENSEARCH_DASHBOARDS_PORT="7007"/; 0,/^NPM_HTTP_PORT=/s/^NPM_HTTP_PORT=.*/NPM_HTTP_PORT="7008"/; 0,/^NPM_HTTPS_PORT=/s/^NPM_HTTPS_PORT=.*/NPM_HTTPS_PORT="7009"/; 0,/^NPM_ADMIN_PORT=/s/^NPM_ADMIN_PORT=.*/NPM_ADMIN_PORT="7010"/; 0,/^MONGO_TAG=/s/^MONGO_TAG=.*/MONGO_TAG="7.0"/; 0,/^QUEUE_PREFIX=/s/^QUEUE_PREFIX=.*/QUEUE_PREFIX="q7"/; 0,/^AUTOSYNC_CRON=/s/^AUTOSYNC_CRON=.*/AUTOSYNC_CRON="15 4 * * *"/; 0,/^COMPOSE_PROJECT_NAME=/s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME="root"/'
gen "$M" catalog.sh; installer "$M" "$N"
out="$(SHIM_NO_LABELS=1 bash "$M/$N" adopt "$M/catalog.sh" </dev/null 2>&1)"; rc=$?
missing=""; for kv in CATALOG_WEB_PORT=7001 MONGO_PORT_HOST=7002 MINIO_API_PORT_HOST=7003 MINIO_CONSOLE_PORT_HOST=7004 RABBITMQ_AMQP_PORT=7005 RABBITMQ_UI_PORT=7006 OPENSEARCH_DASHBOARDS_PORT=7007 NPM_HTTP_PORT=7008 NPM_HTTPS_PORT=7009 NPM_ADMIN_PORT=7010 MONGO_TAG=7.0 QUEUE_PREFIX=q7 "AUTOSYNC_CRON=15 4 * * *" COMPOSE_PROJECT_NAME=root; do grep -qxF "${kv%%=*}=\"${kv#*=}\"" "$M/$N" || missing="$missing ${kv%%=*}"; done
check "14 differences: all taken over and counted" '[ "$rc" -eq 0 ] && [ -z "$missing" ] && grep -q "Took over 14 setting(s)" <<< "$out"' || echo "  missing:$missing"

# 10. The installer whose settings made the files is not blocked by a fresh download next to it
W="$T/owner"; installer "$W" catalog.sh "$PORT9393"; gen "$W" catalog.sh; installer "$W" "$N"
out="$(printf '0\n' | SHIM_NO_LABELS=1 bash "$W/catalog.sh" menu 2>&1)"
check "owner: no note in the installer that made the files" '! grep -q "other settings" <<< "$out" && ! grep -q "option 2 regenerates them" <<< "$out"'
out="$(SHIM_NO_LABELS=1 bash "$W/catalog.sh" generate </dev/null 2>&1)"; rc=$?
check "owner: its generate still works" '[ "$rc" -eq 0 ] && grep -q "^CATALOG_WEB_PORT=9393$" "$W/.env"'
cp "$W/catalog.sh" "$W/old-copy.sh"; sed -i '0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT="9494"/' "$W/catalog.sh"
out="$(SHIM_NO_LABELS=1 bash "$W/catalog.sh" generate </dev/null 2>&1)"; rc=$?
check "owner with a pending edit and other installers here: CLI refuses" '[ "$rc" -ne 0 ] && grep -q "has other settings than catalog.sh" <<< "$out"'
rm -f "$W/old-copy.sh" "$W/$N"
out="$(SHIM_NO_LABELS=1 bash "$W/catalog.sh" generate </dev/null 2>&1)"; rc=$?
check "owner alone again: the edit is generated" '[ "$rc" -eq 0 ] && grep -q "^CATALOG_WEB_PORT=9494$" "$W/.env"'

# 11. Only CATALOG_VERSION differs: the guided upgrade refuses too; adopt of this folder lists, a named file is taken over
V="$T/version"; installer "$V" catalog.sh 's/^CATALOG_VERSION=.*/CATALOG_VERSION="26.3.4789.148"/'; gen "$V" catalog.sh; installer "$V" "$N"
envv="$(cksum < "$V/.env")"
out="$(SHIM_NO_LABELS=1 bash "$V/$N" upgrade </dev/null 2>&1)"; rc=$?
check "version only: upgrade refuses" '[ "$rc" -ne 0 ] && grep -q "has other settings than $N" <<< "$out" && [ "$(cksum < "$V/.env")" = "$envv" ]'
out="$(SHIM_NO_LABELS=1 bash "$V/$N" adopt "$V" </dev/null 2>&1)"; rc=$?
check "adopt with this folder: lists the installers" '[ "$rc" -ne 0 ] && grep -q "Installers with other settings in this folder: catalog.sh" <<< "$out"'
out="$(SHIM_NO_LABELS=1 bash "$V/$N" adopt "$V/catalog.sh" </dev/null 2>&1)"; rc=$?
check "adopt with the file: version taken over" '[ "$rc" -eq 0 ] && grep -q "CATALOG_VERSION *25.4.4191.133 -> 26.3.4789.148" <<< "$out" && grep -qxF "CATALOG_VERSION=\"26.3.4789.148\"" "$V/$N"'
out="$(SHIM_NO_LABELS=1 bash "$V/$N" adopt "$V" </dev/null 2>&1)"; rc=$?
check "adopt with this folder afterwards: nothing to take over" '[ "$rc" -eq 0 ] && grep -q "there is nothing to take over here" <<< "$out"'

# 12. Older installer with its own ENV_FILE name
E="$T/envname"; installer "$E" catalog.sh "$PORT9393; 0,/^ENV_FILE=/s/^ENV_FILE=.*/ENV_FILE=\".env.catalog\"/"; gen "$E" catalog.sh; installer "$E" "$N"
out="$(menu "$E" '0\n')"
check "own ENV_FILE name: note shown" '[ -f "$E/.env.catalog" ] && grep -q "catalog.sh in this folder has other settings" <<< "$out"'

# 13. Differences only in CHECK_FOR_UPDATES or INSTALLER_URL do not count
C="$T/flags"; installer "$C" catalog.sh; gen "$C" catalog.sh
installer "$C" "$N" 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="true"/; s#^INSTALLER_URL=.*#INSTALLER_URL="https://mirror.example/installer.sh"#'
out="$(menu "$C" '0\n')"
check "update settings only: no note" '! grep -q "other settings" <<< "$out"'

# 14. No takeover while a job runs
J="$T/jobrun"; installer "$J" catalog.sh "$PORT9393"; gen "$J" catalog.sh; installer "$J" "$N"
sleep 60 & sp=$!
mkdir -p "$J/.jobs/1"; echo "Upgrade" > "$J/.jobs/1/title"; echo running > "$J/.jobs/1/state"; echo "$sp" > "$J/.jobs/1/pid"
out="$(SHIM_NO_LABELS=1 bash "$J/$N" adopt ./catalog.sh </dev/null 2>&1)"; rc=$?
kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
check "job running: takeover refused, nothing changed" '[ "$rc" -ne 0 ] && grep -q "Jobs are running" <<< "$out" && grep -qxF "CATALOG_WEB_PORT=\"8080\"" "$J/$N" && [ -f "$J/catalog.sh" ]'

# 15. Settings with comments and quotes are taken over with the values bash reads
K="$T/comments"; installer "$K" catalog.sh "0,/^CATALOG_WEB_PORT=/s/^CATALOG_WEB_PORT=.*/CATALOG_WEB_PORT=\"9090\"   # 8080 is taken/; 0,/^QUEUE_PREFIX=/s/^QUEUE_PREFIX=.*/QUEUE_PREFIX='rvc\$x'/"
gen "$K" catalog.sh; installer "$K" "$N"
out="$(SHIM_NO_LABELS=1 bash "$K/$N" adopt ./catalog.sh </dev/null 2>&1)"; rc=$?
check "comments and quotes: values as bash reads them" '[ "$rc" -eq 0 ] && grep -qxF "CATALOG_WEB_PORT=\"9090\"" "$K/$N" && grep -qxF "QUEUE_PREFIX=\"rvc\\\$x\"" "$K/$N" && bash "$K/$N" check-settings >/dev/null 2>&1'

check "no unhandled podman, compose or systemctl calls" '[ ! -s "$UNHANDLED" ]'
if [ -s "$UNHANDLED" ]; then sort -u "$UNHANDLED" | sed 's/^/  /'; fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
