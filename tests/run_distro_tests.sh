#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/w"
rm -rf "$T"; mkdir -p "$T/bin" "$T/d" "$T/home"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

# what this machine is: the package manager and the distribution family
PM=""
for p in apt-get dnf yum zypper apk; do
  if command -v "$p" >/dev/null 2>&1; then PM="$p"; break; fi
done
ID=""; LIKE=""; VER=""
if [ -r /etc/os-release ]; then
  ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
  LIKE=" $(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"') "
  VER="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')"
fi
echo "== $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'), bash $BASH_VERSION, package manager ${PM:-none}"

# A PATH without any real podman, docker, compose or Homebrew of this machine (CI runners have them):
# every folder of the PATH in its order, one link per command
mkdir -p "$T/sys"
if command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 || command -v brew >/dev/null 2>&1; then
  IFS=: read -r -a dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for f in "$d"/*; do
      b="${f##*/}"
      case "$b" in podman|docker|docker-compose|podman-compose|dockerd|brew) continue ;; esac
      [ -e "$T/sys/$b" ] || ln -s "$f" "$T/sys/$b" 2>/dev/null
    done
  done
  SYSPATH="$T/sys"
  # the GNU tools of Homebrew stay named on the PATH: the installer then leaves the PATH order alone
  for d in "${dirs[@]}"; do
    case "$d" in */libexec/gnubin) SYSPATH="$SYSPATH:$d" ;; esac
  done
else
  SYSPATH="$PATH"
fi

# Fakes. podman: SHIM_PODMAN_VERSION, SHIM_ROOTLESS, SHIM_API_FAIL (compose ls fails), SHIM_VM_KERNEL,
# the machine state in $T/machine. The fake podman is only "installed" when $T/podman.installed exists.
mkdir -p "$T/inst"
cat > "$T/inst/podman" <<'EOF'
#!/usr/bin/env bash
echo "podman $*" >> "$LOG"
case "$1" in
  --version) echo "podman version ${SHIM_PODMAN_VERSION:-5.7.0}" ;;
  info)
    case "$*" in
      *Rootless*) echo "${SHIM_ROOTLESS:-false}" ;;
      *Kernel*) echo "${SHIM_VM_KERNEL:-6.12.5-200.fc41.aarch64}" ;;
    esac ;;
  compose)
    shift
    while [ $# -gt 0 ]; do case "$1" in --env-file|-f|-p) shift 2 ;; *) break ;; esac; done
    case "$1" in
      ls) [ -n "${SHIM_API_FAIL:-}" ] && { echo "Error response from daemon: client version 1.52 is too new" >&2; exit 1; } ;;
      config) case "${2:-}" in --services) printf 'mongo\ncatalog-web\n' ;; --volumes) printf 'db_data\n' ;; esac ;;
    esac ;;
  machine)
    case "$2" in
      list)
        if [ -f "$MSTATE" ]; then
          case "$*" in
            *Running*) if grep -q running "$MSTATE"; then echo "podman-machine-default*|true"; else echo "podman-machine-default*|false"; fi ;;
            *VMType*) echo "podman-machine-default*|${SHIM_VMTYPE:-applehv}" ;;
            *) echo "podman-machine-default*" ;;
          esac
        fi ;;
      init) echo "running" > "$MSTATE" ;;
      start) echo "running" > "$MSTATE" ;;
      stop) echo "stopped" > "$MSTATE" ;;
      set) ;;
      inspect)
        case "$*" in
          *State*) cat "$MSTATE" 2>/dev/null || echo "" ;;
          *Rootful*) echo true ;;
          *Memory*) echo 8192 ;;
        esac ;;
      ssh)
        case "$*" in
          *"sysctl -n vm.max_map_count"*) echo 1048576 ;;
          *binfmt_misc/rosetta*) if [ -n "${SHIM_NO_ROSETTA:-}" ]; then exit 1; else echo enabled; fi ;;
        esac ;;
    esac ;;
  volume) [ "$2" = exists ] && exit 1 ;;
esac
exit 0
EOF
cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$SUDO_LOG"
case "$*" in
  *"install -y podman"*|*"zypper -n install podman"*) touch "$T/podman.installed"; cp "$T/inst/podman" "$T/bin/podman" ;;
  *apt-get*|*dnf\ *|*zypper*|*systemctl*|*containers.conf.d*) ;;
  *) exec "$@" ;;
esac
EOF
printf '#!/usr/bin/env bash\ncase "$1" in is-active) exit 0 ;; is-enabled) echo enabled ;; esac\nexit 0\n' > "$T/bin/systemctl"
cat > "$T/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -r) echo "${SHIM_KERNEL:-6.8.0-generic}" ;;
  -m) echo "${SHIM_ARCH:-x86_64}" ;;
  *) echo "${SHIM_OS:-Linux}" ;;
esac
EOF
printf '#!/usr/bin/env bash\n[ "$1" = "-u" ] && { echo "${SHIM_UID:-1000}"; exit 0; }\nexec /usr/bin/id "$@"\n' > "$T/bin/id"
# macOS tools: sysctl (SHIM_ARM), brew (installs podman and the GNU tools), launchctl, ipconfig
cat > "$T/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *hw.optional.arm64*) echo "${SHIM_ARM:-1}" ;;
  *hw.memsize*) echo 34359738368 ;;
  *hw.ncpu*) echo 10 ;;
  *) exec /sbin/sysctl "$@" ;;
esac
EOF
cat > "$T/inst/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >> "$LOG"
case "$1" in
  --prefix) echo "$T/brew" ;;
  install) shift; for t in "$@"; do mkdir -p "$T/brew/opt/$t"; [ "$t" = podman ] && cp "$T/inst/podman" "$T/bin/podman"; done ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho "launchctl $*" >> "$LOG"\n' > "$T/bin/launchctl"
printf '#!/usr/bin/env bash\necho "${SHIM_MACOS:-26.1}"\n' > "$T/bin/sw_vers"
printf '#!/usr/bin/env bash\necho 192.168.1.20\n' > "$T/bin/ipconfig"
# Docker Compose releases on GitHub: SHIM_TAG (newest), SHIM_BAD_SHA, SHIM_GITHUB_DOWN
mkdir -p "$T/gh"
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""; head=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --max-time|--proto|--connect-timeout|-H|-w) shift 2 ;;
    -fsSI|-I) head=1; shift ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $url" >> "$LOG"
[ -n "${SHIM_GITHUB_DOWN:-}" ] && exit 6
tag="${SHIM_TAG:-v5.6.0}"
case "$url" in
  https://github.com/docker/compose/releases/latest)
    printf 'HTTP/2 302\r\nlocation: https://github.com/docker/compose/releases/tag/%s\r\n\r\n' "$tag" ;;
  https://github.com/docker/compose/releases/download/*.sha256)
    f="$T/gh/$(basename "${url%.sha256}")"
    if [ -n "${SHIM_BAD_SHA:-}" ]; then echo "0000  *x"; else printf '%s *%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"; fi ;;
  https://github.com/docker/compose/releases/download/*)
    f="$T/gh/$(basename "$url")"
    printf '#!/usr/bin/env bash\ncase "$1" in version) [ "${2:-}" = "--short" ] && echo %s || echo "Docker Compose version %s" ;; esac\n' "${tag#v}" "$tag" > "$f"
    cat "$f" > "$out" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$T/bin/"* "$T/inst/"*
export LOG="$T/log" SUDO_LOG="$T/sudo.log" MSTATE="$T/machine" T
I="$T/d/rn1-technology-catalog-installer.sh"
cp "$NEW" "$I"
sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$I"
reset_podman() { rm -f "$T/bin/podman" "$T/bin/brew" "$T/podman.installed" "$MSTATE"; rm -rf "$T/cli" "$T/brew" "$T/home"; mkdir -p "$T/home"; : > "$LOG"; : > "$SUDO_LOG"; }
run() { (cd "$T/d" && HOME="$T/home" RN1_SYSTEMD_DIR="$T" RN1_COMPOSE_PROVIDER="${PROVIDER-$T/cli/docker-compose}" PATH="$T/bin:$SYSPATH" bash "$I" "$@" </dev/null 2>&1); }

# --- Linux: what the installer shows and does for this distribution ------------------------------------
case "$ID $LIKE" in
  debian*|*" debian "*|ubuntu*|*" ubuntu "*) PLAN="apt-get install -y podman netavark aardvark-dns" ;;
  *) case "$PM" in dnf) PLAN="dnf install -y podman netavark aardvark-dns" ;; zypper) PLAN="zypper -n install podman" ;; *) PLAN="" ;; esac ;;
esac
REFUSED=""
case "$ID" in
  debian) [[ "$VER" =~ ^[0-9]+$ ]] && [ "$VER" -lt 13 ] && REFUSED="Debian $VER has Podman 4.3, without 'podman compose' - use Debian 13 or newer." ;;
  ubuntu) case "$VER" in 1*|20.*|22.*) REFUSED="Ubuntu $VER has no Podman 4.9 or newer" ;; esac ;;
esac
[ "$PM" = "yum" ] && REFUSED="is too old - use version 8 or newer."
[ -z "$ID" ] && REFUSED="This Linux is not covered"

reset_podman
out="$(run check)"
if [ -n "$REFUSED" ]; then
  check "no Podman: this system is refused with the reason ($ID $VER)" 'grep -q "Podman is not installed" <<< "$out" && grep -qF -- "$REFUSED" <<< "$out"'
else
  check "no Podman: the install commands of this distribution ($ID $VER)" 'grep -q "Podman is not installed" <<< "$out" && grep -qF -- "$PLAN" <<< "$out" && grep -q "systemctl enable --now podman.socket" <<< "$out"'
  check "no Podman: never Docker or podman-docker in the hints" '! grep -qiE "docker-ce|docker engine|podman-docker|docker\.io " <<< "$out"'

  out="$(SHIM_UID=1000 run install-podman)"; rc=$?
  check "install-podman: Podman from the packages, socket and restart service, newest Compose" '[ "$rc" -eq 0 ] && grep -qF -- "$PLAN" "$SUDO_LOG" && grep -q "systemctl enable --now podman.socket" "$SUDO_LOG" && grep -q "systemctl enable podman-restart.service" "$SUDO_LOG" && [ "$("$T/cli/docker-compose" version --short)" = "5.6.0" ] && grep -q "Docker Compose 5.6.0 installed" <<< "$out"'
  check "install-podman: the Compose download comes from GitHub's newest release, no fixed version" 'grep -q "^curl https://github.com/docker/compose/releases/latest$" "$LOG" && grep -q "releases/download/v5.6.0/docker-compose-linux-x86_64$" "$LOG"'
  check "install-podman: the notice of podman compose turned off for Podman before 5.3 (containers.conf)" 'grep -q "compose_warning_logs = false.*/etc/containers/containers.conf.d/50-rn1-compose.conf" "$SUDO_LOG"'
  check "install-podman: the download waits next to its target, not in /tmp" 'grep -q "^sudo mktemp $T/cli/.docker-compose.XXXXXX$" "$SUDO_LOG" && [ -z "$(ls -A "$T/cli" | grep -v "^docker-compose$")" ]'
  out="$(SHIM_UID=1000 run install-podman)"
  check "install-podman again: the newest Compose is there, nothing downloaded" 'grep -q "Docker Compose 5.6.0 (the newest) runs" <<< "$out"'
  out="$(SHIM_UID=1000 SHIM_TAG=v5.7.0 SHIM_API_FAIL=1 run install-podman)"
  check "a newest Compose that does not work with this Podman: the working one stays" 'grep -q "Docker Compose 5.7.0 does not work with Podman" <<< "$out" && [ "$("$T/cli/docker-compose" version --short)" = "5.6.0" ]'
  out="$(SHIM_UID=1000 SHIM_TAG=v5.7.0 SHIM_BAD_SHA=1 run install-podman)"
  check "a download with a wrong checksum: nothing installed, the old one stays" 'grep -q "checksum of .* does not match - nothing was installed" <<< "$out" && [ "$("$T/cli/docker-compose" version --short)" = "5.6.0" ]'
  out="$(SHIM_UID=1000 SHIM_GITHUB_DOWN=1 run install-podman)"
  check "GitHub not reachable: the installed Compose stays" 'grep -q "GitHub cannot be reached - Docker Compose 5.6.0 stays" <<< "$out"'
  out="$(SHIM_UID=1000 SHIM_TAG=v5.7.0 run install-podman)"
  check "a newer Compose that works: updated, the previous one kept aside" '[ "$("$T/cli/docker-compose" version --short)" = "5.7.0" ] && [ -x "$T/cli/docker-compose.previous" ]'
  run generate >/dev/null
  out="$(run check)"
  check "check after install-podman: Podman, socket, restart service and Compose OK" 'grep -q "OK Podman 5.7.0" <<< "$out" && grep -q "Podman API socket (podman.socket) is active" <<< "$out" && grep -q "Compose: podman compose with Docker Compose version v5.7.0" <<< "$out" && ! grep -q "podman-restart.service is not enabled" <<< "$out"'
  out="$(SHIM_ROOTLESS=true run up)"; rc=$?
  check "rootless Podman: start refused, run as root" '[ "$rc" -ne 0 ] && grep -q "Run .* as root (sudo): the Catalog runs with rootful Podman" <<< "$out"'
  out="$(SHIM_PODMAN_VERSION=4.3.1 run up)"; rc=$?
  check "Podman 4.3 (Debian 12): refused, 4.9 or newer needed" '[ "$rc" -ne 0 ] && grep -q "Podman 4.3.1 is too old: 4.9.0 or newer is needed" <<< "$out"'
fi
out="$(SHIM_ARCH=aarch64 run check)"
if [ -z "$ID" ]; then :; else
  reset_podman; out="$(SHIM_ARCH=aarch64 run check)"
  check "ARM Linux: refused, the Catalog images are amd64 only" 'grep -q "exist only for amd64" <<< "$out"'
fi
check "the installer pins no Podman, Compose or Docker version" '! grep -qE "compose/releases/download/v[0-9]|docker-compose-v?[0-9]\.[0-9]|podman-[0-9]\.[0-9]" "$NEW"'

# --- macOS (uname -s Darwin; fake Homebrew and Podman machine) -----------------------------------------
reset_podman
out="$(SHIM_OS=Darwin SHIM_ARM=0 PROVIDER= run install-podman)"; rc=$?
check "macOS on Intel: not supported" '[ "$rc" -ne 0 ] && grep -q "Intel Macs are not supported" <<< "$out"'
out="$(SHIM_OS=Darwin SHIM_UID=0 PROVIDER= run install-podman)"; rc=$?
check "macOS as root: refused, the machine belongs to the user" '[ "$rc" -ne 0 ] && grep -q "not as root" <<< "$out"'
out="$(SHIM_OS=Darwin PROVIDER= run install-podman)"; rc=$?
check "macOS without Homebrew: says where to get it" '[ "$rc" -ne 0 ] && grep -q "Homebrew is needed" <<< "$out"'
cp "$T/inst/brew" "$T/bin/brew"
out="$(SHIM_OS=Darwin PROVIDER= run install-podman)"; rc=$?
check "macOS: Homebrew installs podman and the GNU tools" '[ "$rc" -eq 0 ] && grep -q "^brew install podman coreutils gnu-sed grep findutils$" "$LOG"'
check "macOS: a rootful machine with Rosetta and enough memory" 'grep -q "^podman machine init --rootful --cpus 6 --memory 12288 --disk-size 100 --now$" "$LOG" && grep -q "rosetta = true" "$T/home/.config/containers/containers.conf.d/50-rn1-machine.conf" && grep -q "provider = \"applehv\"" "$T/home/.config/containers/containers.conf.d/50-rn1-machine.conf"'
check "macOS: restart service in the machine, LaunchAgent starts the machine at login" 'grep -q "podman machine ssh podman-machine-default sudo systemctl enable podman-restart.service" "$LOG" && grep -q "<string>machine</string><string>start</string><string>podman-machine-default</string>" "$T/home/Library/LaunchAgents/de.raynet.rn1-podman-machine.plist" && grep -q "<key>AbandonProcessGroup</key><true/>" "$T/home/Library/LaunchAgents/de.raynet.rn1-podman-machine.plist" && grep -q "^launchctl load -w" "$LOG"'
check "macOS: Rosetta checked in the machine, no restart when it runs" 'grep -q "podman machine ssh podman-machine-default cat /proc/sys/fs/binfmt_misc/rosetta" "$LOG" && ! grep -q "^podman machine stop" "$LOG"'
check "macOS: the newest Compose for darwin-aarch64 in ~/.docker/cli-plugins, without sudo" '[ -x "$T/home/.docker/cli-plugins/docker-compose" ] && grep -q "download/v5.6.0/docker-compose-darwin-aarch64$" "$LOG" && ! grep -q . "$SUDO_LOG"'
check "macOS: no download left behind next to Docker Compose" '[ -z "$(ls -A "$T/home/.docker/cli-plugins" | grep -v "^docker-compose$")" ]'
printf '<plist>old</plist>\n' > "$T/home/Library/LaunchAgents/de.raynet.rn1-podman-machine.plist"; : > "$LOG"
out="$(SHIM_OS=Darwin PROVIDER= run install-podman)"
check "macOS: an older LaunchAgent is brought up to date" 'grep -q "LaunchAgent updated" <<< "$out" && grep -q "<key>AbandonProcessGroup</key><true/>" "$T/home/Library/LaunchAgents/de.raynet.rn1-podman-machine.plist" && grep -q "^launchctl unload" "$LOG"'
: > "$LOG"
out="$(SHIM_OS=Darwin SHIM_NO_ROSETTA=1 PROVIDER= run install-podman)"; rc=$?
check "macOS: Rosetta off - turned on with a restart, a clear error when it stays off" '[ "$rc" -ne 0 ] && grep -q "^podman machine ssh podman-machine-default sudo touch /etc/containers/enable-rosetta$" "$LOG" && grep -q "^podman machine stop podman-machine-default$" "$LOG" && grep -q "Rosetta does not run in the Podman machine podman-machine-default" <<< "$out"'
out="$(SHIM_OS=Darwin SHIM_VMTYPE=libkrun PROVIDER= run install-podman)"; rc=$?
check "macOS: a libkrun machine is refused (it has no Rosetta)" '[ "$rc" -ne 0 ] && grep -q "runs with libkrun, which cannot use Rosetta" <<< "$out"'
out="$(SHIM_OS=Darwin SHIM_MACOS=15.6 PROVIDER= run install-podman)"; rc=$?
check "macOS 15: refused, Rosetta in the machine needs macOS 26" '[ "$rc" -ne 0 ] && grep -q "macOS 15.6 is too old for the Catalog" <<< "$out"'
echo running > "$MSTATE"
(cd "$T/d" && HOME="$T/home" PATH="$T/bin:$SYSPATH" SHIM_OS=Darwin SHIM_VM_KERNEL=7.0.0-12-generic bash "$I" generate </dev/null >/dev/null 2>&1)
check "macOS on Apple Silicon: the amd64 Catalog images run with platform linux/amd64" '[ "$(grep -c "^    platform: linux/amd64$" "$T/d/docker-compose.yml")" -eq 5 ] && [ "$(sed -n "/^  catalog-web:/,/^  worker/p" "$T/d/docker-compose.yml" | grep -c "platform: linux/amd64")" -eq 1 ]'
check "macOS: the MongoDB kernel check uses the kernel of the Podman machine" 'grep -q "GLIBC_TUNABLES" "$T/d/docker-compose.yml"'
(cd "$T/d" && HOME="$T/home" PATH="$T/bin:$SYSPATH" SHIM_OS=Darwin SHIM_VM_KERNEL=6.12.5 bash "$I" generate </dev/null >/dev/null 2>&1)
check "macOS: a machine kernel outside 6.19-7.0.13 needs no MongoDB workaround" '! grep -q "GLIBC_TUNABLES" "$T/d/docker-compose.yml"'
out="$(cd "$T/d" && HOME="$T/home" PATH="$T/bin:$SYSPATH" SHIM_OS=Darwin bash "$I" check </dev/null 2>&1)"
check "macOS check: machine rootful, vm.max_map_count read in the machine" 'grep -q "Podman runs rootful (Podman machine)" <<< "$out" && grep -q "vm.max_map_count = 1048576 (Podman machine)" <<< "$out"'
rm -f "$T/d/docker-compose.yml" "$T/d/.env"
(cd "$T/d" && PATH="$T/bin:$SYSPATH" bash "$I" generate </dev/null >/dev/null 2>&1)
check "Linux: no platform line (the files as before)" '! grep -q "platform:" "$T/d/docker-compose.yml"'

# a UTF-8 locale that is not installed (C.UTF-8 on CentOS 7): plain characters, else the boxes break
# (only with glibc: Git Bash accepts every locale name)
if [ -r /etc/os-release ] && command -v locale >/dev/null 2>&1; then
  out="$(cd "$T/d" && printf '0\n' | LC_ALL= LC_CTYPE= LANG=xx_YY.UTF-8 PATH="$T/bin:$SYSPATH" bash "$I" menu 2>&1)"
  check "UTF-8 locale that is not installed: plain characters" 'grep -q "I install - U update - R remove" <<< "$out"'
  UTF="$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -n 1)"
  if [ -n "$UTF" ]; then
    out="$(cd "$T/d" && printf '0\n' | LC_ALL= LC_CTYPE= LANG="$UTF" PATH="$T/bin:$SYSPATH" bash "$I" menu 2>&1)"
    check "installed UTF-8 locale ($UTF): line characters" 'grep -q "I install · U update · R remove" <<< "$out"'
  fi
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
