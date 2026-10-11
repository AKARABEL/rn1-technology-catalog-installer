#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/w"
rm -rf "$T"; mkdir -p "$T/bin" "$T/d" "$T/home"
# the runner's own XDG and Colima folders must not leak into the fake home (GitHub sets XDG_CONFIG_HOME)
unset XDG_CONFIG_HOME COLIMA_HOME
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
  volume) [ "$2" = inspect ] && exit 1 ;;
esac
exit 0
EOF
# Docker (Linux: from the packages; macOS: Docker Desktop or the formula of Colima), with its contexts:
# default, desktop-linux ($T/dd.ctx, made by the first start of Docker Desktop) and colima ($T/colima.ctx,
# made by colima start); the current one is DOCKER_CONTEXT, else the one in $T/docker.ctx. The daemon of
# colima answers when $T/colima.running exists, the others when $T/docker.up exists. SHIM_DATA_<context>
# (desktop_linux, colima, default): the project whose containers and volumes that daemon holds.
# $T/docker.plugin: it has its Compose plugin; else "docker compose" runs the Docker Compose the installer
# put at RN1_COMPOSE_PROVIDER or into ~/.docker/cli-plugins. SHIM_VM_KERNEL: the kernel of its Linux VM
# (macOS). Calls it does not know go to $BAD. $T/ctx.log: the context of each call.
cat > "$T/inst/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$LOG"
bad() { echo "UNHANDLED docker $*" >> "$BAD"; echo "docker: the fake does not know: $*" >&2; exit 125; }
known() { case "$1" in default) true ;; colima) [ -f "$T/colima.ctx" ] ;; desktop-linux) [ -f "$T/dd.ctx" ] ;; *) false ;; esac; }
ctx="${DOCKER_CONTEXT:-$(cat "$T/docker.ctx" 2>/dev/null || echo default)}"
if [ "${1:-}" = --context ]; then ctx="$2"; shift 2; fi
echo "$ctx: docker $*" >> "$T/ctx.log"
case "${1:-}" in
  --version) echo "Docker version 29.9.0, build 1a2b3c4"; exit 0 ;;
  context)
    case "${2:-}" in
      show) echo "$ctx" ;;
      inspect) known "${3:-}" || { echo "context \"${3:-}\": context not found" >&2; exit 1; }; echo "[]" ;;
      *) bad "$@" ;;
    esac
    exit 0 ;;
  compose)
    shift
    for c in "${RN1_COMPOSE_PROVIDER:-}" "$HOME/.docker/cli-plugins/docker-compose"; do
      if [ -n "$c" ] && [ -x "$c" ]; then exec "$c" "$@"; fi
    done
    if [ -f "$T/docker.plugin" ]; then [ "${1:-}" = version ] && echo "Docker Compose version v2.40.3"; exit 0; fi
    echo "docker: unknown command: docker compose" >&2; exit 1 ;;
esac
known "$ctx" || { echo "context \"$ctx\": context not found" >&2; exit 1; }
if [ "$ctx" = colima ]; then up="$T/colima.running"; else up="$T/docker.up"; fi
[ -f "$up" ] || { echo "Cannot connect to the Docker daemon. Is the docker daemon running?" >&2; exit 1; }
case "$*" in
  info) echo "Server: Docker Engine - Community" ;;
  "info --format {{range .SecurityOptions}}{{.}} {{end}}") echo "name=seccomp,profile=builtin name=cgroupns " ;;
  "info --format {{.KernelVersion}}") echo "${SHIM_VM_KERNEL:-6.12.5-linuxkit}" ;;
  "ps -aq --filter label=com.docker.compose.project="*|"volume ls -q --filter label=com.docker.compose.project="*)
    v="SHIM_DATA_${ctx//-/_}"
    a="$*"; if [ -n "${!v:-}" ] && [ "${a##*=}" = "${!v}" ]; then echo 0123456789ab; fi ;;
  *) bad "$@" ;;
esac
exit 0
EOF
# Colima: its folder as Colima finds it (COLIMA_HOME, ~/.colima, $XDG_CONFIG_HOME/colima, ~/.config/colima).
# SHIM_NO_ROSETTA, SHIM_MAPCOUNT (vm.max_map_count in its VM before the installer sets it)
cat > "$T/inst/colima" <<'EOF'
#!/usr/bin/env bash
echo "colima $*" >> "$LOG"
if [ -n "${COLIMA_HOME:-}" ] && [ -d "$COLIMA_HOME" ]; then d="$COLIMA_HOME"
elif [ -d "$HOME/.colima" ]; then d="$HOME/.colima"
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then d="$XDG_CONFIG_HOME/colima"
elif [ -d "$HOME/.config/colima" ]; then d="$HOME/.config/colima"
else d="$HOME/.colima"; fi
y="$d/default/colima.yaml"
case "$*" in
  status) [ -f "$T/colima.running" ] ;;
  start|"start "*)
    if [ ! -f "$y" ]; then mkdir -p "${y%/*}"; printf '%s\n' 'cpu: 6' 'vmType: vz' '# Default: []' 'provision: []' > "$y"; fi
    touch "$T/colima.running" "$T/colima.ctx"; echo colima > "$T/docker.ctx" ;;
  "ssh -- cat /proc/sys/fs/binfmt_misc/rosetta") [ -n "${SHIM_NO_ROSETTA:-}" ] && exit 1; echo enabled ;;
  "ssh -- sysctl -n vm.max_map_count") cat "$T/colima.mapcount" 2>/dev/null || echo "${SHIM_MAPCOUNT:-65530}" ;;
  "ssh -- sudo sysctl -w vm.max_map_count=262144") echo 262144 > "$T/colima.mapcount" ;;
  *) echo "UNHANDLED colima $*" >> "$BAD"; echo "colima: the fake does not know: $*" >&2; exit 125 ;;
esac
EOF
# Docker Desktop starts with "open -a Docker" and makes its context the current one (SHIM_DD_NEVER: it does not start)
cat > "$T/bin/open" <<'EOF'
#!/usr/bin/env bash
echo "open $*" >> "$LOG"
[ "$*" = "-a Docker" ] || { echo "UNHANDLED open $*" >> "$BAD"; exit 1; }
[ -n "${SHIM_DD_NEVER:-}" ] || { touch "$T/docker.up" "$T/dd.ctx"; echo desktop-linux > "$T/docker.ctx"; }
EOF
cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$SUDO_LOG"
case "$*" in
  *"install -y podman"*|*"zypper -n install podman"*) touch "$T/podman.installed"; cp "$T/inst/podman" "$T/bin/podman" ;;
  *"install -y docker-ce"*) cp "$T/inst/docker" "$T/bin/docker"; touch "$T/docker.up" "$T/docker.plugin" ;;
  *"zypper -n install docker"*) cp "$T/inst/docker" "$T/bin/docker"; touch "$T/docker.up" ;;
  *apt-get*|*dnf\ *|*zypper*|*systemctl*|*containers.conf.d*) ;;
  "sh -c "*) ;;
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
case "$*" in
  --prefix) echo "$T/brew" ;;
  "install "*)
    shift
    for t in "$@"; do
      case "$t" in
        --cask) continue ;;
        podman) cp "$T/inst/podman" "$T/bin/podman" ;;
        colima) cp "$T/inst/colima" "$T/bin/colima" ;;
        docker) cp "$T/inst/docker" "$T/bin/docker" ;;
        docker-desktop) cp "$T/inst/docker" "$T/bin/docker"; touch "$T/docker.plugin"; mkdir -p "$HOME/Applications/Docker.app" ;;
        bash|coreutils|gnu-sed|grep|findutils) ;;
        *) echo "UNHANDLED brew $*" >> "$BAD"; exit 1 ;;
      esac
      mkdir -p "$T/brew/opt/$t"
    done ;;
  "services list") [ -f "$T/colima.service" ] && echo "colima started $USER ~/Library/LaunchAgents/homebrew.mxcl.colima.plist" ;;
  "services start colima") touch "$T/colima.service" ;;
  *) echo "UNHANDLED brew $*" >> "$BAD"; exit 1 ;;
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
  https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
    # the official Homebrew script: here it only puts the fake brew where Homebrew installs it
    printf 'echo "homebrew install.sh" >> "%s"; mkdir -p "%s/hb/bin" && cp "%s/inst/brew" "%s/hb/bin/brew"\n' "$LOG" "$T" "$T" "$T" ;;
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
export LOG="$T/log" SUDO_LOG="$T/sudo.log" MSTATE="$T/machine" BAD="$T/bad.log" T
# the macOS start check (Homebrew, bash, GNU tools) has its own tests below; the other macOS cases skip it
export RN1_MAC_BOOTSTRAPPED=1
: > "$BAD"
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
# --- Linux: Docker (CONTAINER_ENGINE=docker) for this distribution ----------------------------------------
DI="$T/dd/rn1-technology-catalog-installer.sh"; mkdir -p "$T/dd"
sed 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE="docker"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$NEW" > "$DI"
reset_docker() { rm -f "$T/bin/docker" "$T/bin/colima" "$T/bin/brew" "$T/docker.up" "$T/docker.plugin" "$T/colima.running" "$T/colima.service" "$T/colima.mapcount" "$T/dd.ctx" "$T/colima.ctx" "$T/docker.ctx" "$T/ctx.log"; rm -rf "$T/dcli" "$T/brew" "$T/home"; mkdir -p "$T/home"; : > "$LOG"; : > "$SUDO_LOG"; }
drun() { (cd "${DI%/*}" && HOME="$T/home" RN1_SYSTEMD_DIR="$T" RN1_COMPOSE_PROVIDER="${PROVIDER-$T/dcli/docker-compose}" RN1_DOCKER_WAIT=0 PATH="${XPATH:-$T/bin}:$SYSPATH" bash "$DI" "$@" </dev/null 2>&1); }
DPKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
DREPO=""; DPLAN1=""; DPLAN2=""; DREFUSED=""
case "$ID $LIKE" in
  debian*|*" debian "*|ubuntu*|*" ubuntu "*)
    DREPO=debian; case "$ID $LIKE" in ubuntu*|*" ubuntu "*) DREPO=ubuntu ;; esac
    DPLAN1="curl -fsSL https://download.docker.com/linux/$DREPO/gpg -o /etc/apt/keyrings/docker.asc"
    DPLAN2="apt-get install -y $DPKGS" ;;
  *suse*) DPLAN1="zypper -n install docker"; DPLAN2="$DPLAN1" ;;
  *)
    if [ "$PM" = dnf ]; then
      case "$ID" in fedora) DREPO=fedora ;; rhel) DREPO=rhel ;; *) DREPO=centos ;; esac
      [ "${VER%%.*}" = 8 ] && DREPO=rhel
      DPLAN1="curl -fsSL https://download.docker.com/linux/$DREPO/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo"
      DPLAN2="dnf install -y $DPKGS"
    fi ;;
esac
case "$ID" in
  ubuntu) case "$VER" in 1*|20.*) DREFUSED="has no packages in Docker's repository any more" ;; esac ;;
esac
[ "$PM" = "yum" ] && DREFUSED="is too old for Docker's packages - use version 8 or newer."
[ -z "$ID" ] && DREFUSED="This Linux is not covered"
[ -z "$DPLAN1" ] && [ -z "$DREFUSED" ] && DREFUSED="This Linux is not covered"

reset_docker
# the engines the first-run wizard offers here: a reason where one cannot be installed
out="$(drun __engine_choices)"
if [ -n "$REFUSED" ]; then
  check "choices: Podman not selectable here, with the reason ($ID $VER)" 'grep "^podman|Podman|" <<< "$out" | grep -qF -- "$REFUSED"'
else
  check "choices: Podman selectable here ($ID $VER)" 'grep -q "^podman|Podman|[a-z]*|$" <<< "$out"'
fi
if [ -n "$DREFUSED" ]; then
  check "choices: Docker not selectable here, with the reason ($ID $VER)" 'grep "^docker|Docker Engine|missing|" <<< "$out" | grep -qF -- "$DREFUSED"'
else
  check "choices: Docker selectable here, to be installed ($ID $VER)" 'grep -q "^docker|Docker Engine|missing|$" <<< "$out"'
fi
out="$(drun check)"
if [ -n "$DREFUSED" ]; then
  check "no Docker: this system is refused with the reason ($ID $VER)" 'grep -q "Docker is not installed" <<< "$out" && grep -qF -- "$DREFUSED" <<< "$out"'
else
  check "no Docker: the commands of Docker's repository for this distribution ($ID $VER)" 'grep -q "Docker is not installed" <<< "$out" && grep -qF -- "$DPLAN1" <<< "$out" && grep -qF -- "$DPLAN2" <<< "$out" && grep -q "systemctl enable --now docker" <<< "$out"'
  check "no Docker: never a fixed Docker or Compose version" '! grep -Eq "docker-(ce|ce-cli|compose-plugin|buildx-plugin)[=_-][0-9]" <<< "$out"'
  if [ -n "$DREPO" ] && [ "$PM" = dnf ]; then
    check "dnf family ($ID $VER): Docker's $DREPO repository (RHEL rhel; a rebuild rhel for 8, centos newer; Fedora fedora)" 'grep -qF "https://download.docker.com/linux/$DREPO/docker-ce.repo" <<< "$out" && [ "$(grep -o "download.docker.com/linux/[a-z]*/docker-ce.repo" <<< "$out" | sort -u | wc -l)" -eq 1 ]'
  fi
  mkdir -p "$T/pk"
  if [ "$PM" = apt-get ]; then
    printf '#!/usr/bin/env bash\np="${@: -1}"\ncase " ${SHIM_OLD_PKGS:-} " in *" $p "*) printf "install ok installed"; exit 0 ;; esac\nexec %s "$@"\n' "$(command -v dpkg-query)" > "$T/pk/dpkg-query"
    OLDRM="apt-get remove -y .*podman-docker.*runc"
  elif [ "$PM" = dnf ] && command -v rpm >/dev/null 2>&1; then
    printf '#!/usr/bin/env bash\np="${@: -1}"\ncase " ${SHIM_OLD_PKGS:-} " in *" $p "*) exit 0 ;; esac\nexec %s "$@"\n' "$(command -v rpm)" > "$T/pk/rpm"
    # Docker's page for RHEL takes out Podman and runc too, its pages for CentOS and Fedora do not
    if [ "$DREPO" = rhel ]; then OLDRM="dnf remove -y .*podman-docker podman runc"; else OLDRM="dnf remove -y .*podman-docker$"; fi
  else
    OLDRM=""
  fi
  chmod +x "$T/pk/"* 2>/dev/null
  if [ -n "$OLDRM" ]; then
    out="$(XPATH="$T/pk:$T/bin" SHIM_OLD_PKGS="podman-docker podman runc" drun check)"
    check "packages that conflict are removed first, without a question (-y)" 'grep -q -- "$OLDRM" <<< "$out" && [ "$(grep -n -- "$OLDRM" <<< "$out" | head -n 1 | cut -d: -f1)" -lt "$(grep -nF -- "$DPLAN2" <<< "$out" | head -n 1 | cut -d: -f1)" ]'
    if [ "$PM" = dnf ] && [ "$DREPO" != rhel ]; then
      check "$DREPO repository: Podman and runc stay (only Docker's page for RHEL removes them)" '! grep -Eq "remove -y .* (podman|runc)( |$)" <<< "$out"'
    fi
  fi
  out="$(SHIM_UID=1000 drun install-docker)"; rc=$?
  check "install-docker: every step with sudo, in order, then the daemon; Docker ready" '[ "$rc" -eq 0 ] && grep -qF -- "$DPLAN1" "$SUDO_LOG" && grep -qF -- "$DPLAN2" "$SUDO_LOG" && [ "$(grep -nF -- "$DPLAN2" "$SUDO_LOG" | head -n 1 | cut -d: -f1)" -lt "$(grep -n "systemctl enable --now docker" "$SUDO_LOG" | head -n 1 | cut -d: -f1)" ] && grep -q "Docker 29.9.0 is ready" <<< "$out"'
  if [ "$DPLAN1" = "zypper -n install docker" ]; then
    check "openSUSE: its Docker, and the newest Docker Compose as its plugin" 'grep -q "Docker Compose 5.6.0 installed ($T/dcli/docker-compose); .docker compose. runs it" <<< "$out" && [ -x "$T/dcli/docker-compose" ]'
  else
    check "Docker's Compose plugin is used, no extra Docker Compose" '[ ! -e "$T/dcli/docker-compose" ] && ! grep -q "releases/download" "$LOG"'
  fi
  out="$(drun check)"
  check "check after install-docker: Docker, its daemon and Compose OK" 'grep -q "OK Docker 29.9.0" <<< "$out" && grep -q "The Docker daemon answers and runs rootful" <<< "$out" && grep -q "Compose: docker compose with Docker Compose version" <<< "$out"'
fi
reset_docker
out="$(SHIM_ARCH=aarch64 drun check)"
if [ -n "$ID" ]; then
  check "ARM Linux and Docker: refused, the Catalog images are amd64 only" 'grep -q "exist only for amd64" <<< "$out"'
fi

out="$(SHIM_ARCH=aarch64 run check)"
if [ -z "$ID" ]; then :; else
  reset_podman; out="$(SHIM_ARCH=aarch64 run check)"
  check "ARM Linux: refused, the Catalog images are amd64 only" 'grep -q "exist only for amd64" <<< "$out"'
fi
check "the installer pins no Podman, Compose or Docker version" '! grep -qE "compose/releases/download/v[0-9]|docker-compose-v?[0-9]\.[0-9]|podman-[0-9]\.[0-9]|docker-ce[=-][0-9]|colima@|docker-desktop@" "$NEW"'

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

# --- macOS with Docker Desktop (CONTAINER_ENGINE=docker) -------------------------------------------------
DD_SETTINGS="$T/home/Library/Group Containers/group.com.docker/settings-store.json"
reset_docker
out="$(SHIM_OS=Darwin PROVIDER= drun install-docker)"; rc=$?
check "macOS Docker Desktop without Homebrew: says where to get it" '[ "$rc" -ne 0 ] && grep -q "Homebrew is needed" <<< "$out"'
cp "$T/inst/brew" "$T/bin/brew"
out="$(SHIM_OS=Darwin PROVIDER= drun install-docker)"; rc=$?
check "macOS: the GNU tools with Homebrew" 'grep -q "^brew install coreutils gnu-sed grep findutils$" "$LOG"'
if [ ! -d /Applications/Docker.app ]; then
  check "macOS: Docker Desktop missing - its license and the brew command, never installed without a question" '[ "$rc" -ne 0 ] && grep -q "fewer than 250 employees AND less than 10 million" <<< "$out" && grep -q "      brew install --cask docker-desktop" <<< "$out" && grep -q "not installed without a question" <<< "$out" && ! grep -q "^brew install --cask" "$LOG" && ! grep -q "^open " "$LOG"'
fi
# Docker Desktop installed by the user (the app and its docker command), not started yet
mkdir -p "$T/home/Applications/Docker.app"; cp "$T/inst/docker" "$T/bin/docker"; touch "$T/docker.plugin"; : > "$LOG"
out="$(SHIM_OS=Darwin PROVIDER= drun install-docker)"; rc=$?
check "macOS: Docker Desktop started and waited for; the agreement and Rosetta named" '[ "$rc" -eq 0 ] && grep -q "^open -a Docker$" "$LOG" && grep -q "Docker answers: Docker version 29.9.0" <<< "$out" && grep -q "Use Rosetta for x86_64/amd64 emulation" <<< "$out" && grep -q "accept its agreement" <<< "$out"'
check "macOS: the docker command talks to Docker Desktop (context desktop-linux)" 'grep -q "^desktop-linux: docker info$" "$T/ctx.log"'
check "macOS Docker Desktop: its own Compose, nothing downloaded" '[ ! -e "$T/home/.docker/cli-plugins/docker-compose" ] && ! grep -q "releases/download" "$LOG"'
: > "$LOG"
out="$(SHIM_OS=Darwin PROVIDER= drun install-docker)"; rc=$?
check "macOS: a Docker that answers is taken as it is" '[ "$rc" -eq 0 ] && ! grep -q "^brew install --cask" "$LOG" && ! grep -q "^open " "$LOG"'
mkdir -p "${DD_SETTINGS%/*}"; printf '{\n  "UseVirtualizationFrameworkRosetta": false,\n  "MemoryMiB": 8092\n}\n' > "$DD_SETTINGS"
out="$(SHIM_OS=Darwin PROVIDER= drun install-docker)"
check "macOS: Rosetta off in the settings of Docker Desktop - warned" 'grep -q "Rosetta is off in Docker Desktop" <<< "$out"'
out="$(SHIM_OS=Darwin PROVIDER= drun check)"
check "macOS check: Rosetta off in Docker Desktop named" 'grep -q "Rosetta is off in Docker Desktop" <<< "$out"'
rm -f "$DD_SETTINGS"
out="$(SHIM_OS=Darwin SHIM_MACOS=15.6 SHIM_VM_KERNEL=6.14.2-linuxkit PROVIDER= drun install-docker)"; rc=$?
check "macOS 15 with VM kernel 6.14: refused (Rosetta fails with 6.13 and newer before macOS 26)" '[ "$rc" -ne 0 ] && grep -q "Rosetta, which runs the amd64" <<< "$out" && grep -q "6.13 and newer before macOS 26" <<< "$out"'
out="$(SHIM_OS=Darwin SHIM_MACOS=15.6 SHIM_VM_KERNEL=6.10.14-linuxkit PROVIDER= drun install-docker)"; rc=$?
check "macOS 15 with VM kernel 6.10: allowed" '[ "$rc" -eq 0 ]'
out="$(SHIM_OS=Darwin SHIM_MACOS=26.1 SHIM_VM_KERNEL=6.14.2-linuxkit PROVIDER= drun install-docker)"; rc=$?
check "macOS 26 with VM kernel 6.14: allowed" '[ "$rc" -eq 0 ]'
out="$(SHIM_OS=Darwin SHIM_MACOS=15.6 SHIM_VM_KERNEL=6.14.2-linuxkit PROVIDER= drun check)"
check "macOS check: the kernel rule of the VM" 'grep -q "6.13 and newer before macOS 26" <<< "$out"'
out="$(SHIM_OS=Darwin SHIM_ARM=0 SHIM_MACOS=15.6 SHIM_VM_KERNEL=6.14.2-linuxkit PROVIDER= drun install-docker)"; rc=$?
check "Intel Mac with Docker Desktop: allowed, no Rosetta needed" '[ "$rc" -eq 0 ] && ! grep -q "Rosetta" <<< "$out"'
rm -f "$T/docker.up"; : > "$LOG"
out="$(SHIM_OS=Darwin SHIM_DD_NEVER=1 PROVIDER= drun install-docker)"; rc=$?
check "macOS: Docker Desktop that does not answer - a clear error" '[ "$rc" -ne 0 ] && grep -q "Docker Desktop does not answer (docker info)" <<< "$out" && grep -q "^open -a Docker$" "$LOG"'

# --- macOS with Colima (CONTAINER_ENGINE=colima) ------------------------------------------------------------
CI_="$T/cc/rn1-technology-catalog-installer.sh"; mkdir -p "$T/cc"
sed 's/^CONTAINER_ENGINE=.*/CONTAINER_ENGINE="colima"/; s/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$NEW" > "$CI_"
crun() { (cd "$T/cc" && HOME="$T/home" SHIM_OS=Darwin PATH="$T/bin:$SYSPATH" bash "$CI_" "$@" </dev/null 2>&1); }
reset_docker; cp "$T/inst/brew" "$T/bin/brew"
out="$(crun install-engine)"; rc=$?
check "Colima: Homebrew installs colima, docker and the GNU tools" '[ "$rc" -eq 0 ] && grep -q "^brew install colima docker coreutils gnu-sed grep findutils$" "$LOG"'
check "Colima: a VM with Apple's virtualization, Rosetta, 6 CPUs, 12 GB, 100 GB" 'grep -q "^colima start --vm-type=vz --vz-rosetta --cpu 6 --memory 12 --disk 100$" "$LOG"'
check "Colima: the newest Docker Compose for darwin-aarch64 in ~/.docker/cli-plugins" '[ -x "$T/home/.docker/cli-plugins/docker-compose" ] && grep -q "download/v5.6.0/docker-compose-darwin-aarch64$" "$LOG" && grep -q "runs it" <<< "$out"'
check "Colima: vm.max_map_count set in the VM and kept by a provision script" 'grep -q "^colima ssh -- sudo sysctl -w vm.max_map_count=262144$" "$LOG" && grep -q "^provision:$" "$T/home/.colima/default/colima.yaml" && grep -q "^  - mode: system$" "$T/home/.colima/default/colima.yaml" && grep -q "^    script: sysctl -w vm.max_map_count=262144$" "$T/home/.colima/default/colima.yaml" && ! grep -q "provision: \[\]" "$T/home/.colima/default/colima.yaml"'
check "Colima: Rosetta checked in the VM, started at login with brew services" 'grep -q "^colima ssh -- cat /proc/sys/fs/binfmt_misc/rosetta$" "$LOG" && grep -q "^brew services start colima$" "$LOG"'
check "Colima: the docker command talks to the Colima VM (context colima)" 'grep -q "^colima: docker info$" "$T/ctx.log" && ! grep -q "^desktop-linux: docker info" "$T/ctx.log"'
out="$(crun check)"
check "Colima check: Docker in the Colima VM, Rosetta, vm.max_map_count" 'grep -q "The Docker daemon answers (Colima VM) and runs rootful" <<< "$out" && grep -q "Rosetta runs the amd64 Catalog images in the Colima VM" <<< "$out" && grep -q "vm.max_map_count = 262144 (Colima VM)" <<< "$out" && grep -q "Compose: docker compose with Docker Compose version v5.6.0" <<< "$out"'
: > "$LOG"
out="$(crun install-engine)"; rc=$?
check "Colima again: nothing created twice, provision kept once" '[ "$rc" -eq 0 ] && ! grep -q "^colima start" "$LOG" && ! grep -q "^brew services start" "$LOG" && [ "$(grep -c "vm.max_map_count" "$T/home/.colima/default/colima.yaml")" -eq 1 ]'
crun generate >/dev/null; rm -f "$T/colima.running"
out="$(crun up)"; rc=$?
check "Colima stopped: up refused with how to start it" '[ "$rc" -ne 0 ] && grep -q "Colima does not run - start Colima: colima start" <<< "$out"'
out="$(SHIM_MACOS=15.6 SHIM_VM_KERNEL=6.14.0-33-generic crun install-engine)"; rc=$?
check "Colima on macOS 15 with VM kernel 6.14: refused" '[ "$rc" -ne 0 ] && grep -q "6.13 and newer before macOS 26" <<< "$out" && grep -q "^colima start$" "$LOG"'
rm -f "$T/colima.running"; sed -i 's/^vmType: .*/vmType: qemu/' "$T/home/.colima/default/colima.yaml"
out="$(crun install-engine)"; rc=$?
check "Colima: a qemu VM is refused (it has no Rosetta)" '[ "$rc" -ne 0 ] && grep -q "runs with qemu, which cannot use Rosetta" <<< "$out"'
out="$(cd "$T/cc" && HOME="$T/home" PATH="$T/bin:$SYSPATH" bash "$CI_" check-settings 2>&1)"; rc=$?
check "Colima on Linux: CONTAINER_ENGINE refused" '[ "$rc" -ne 0 ] && grep -q "\"colima\" (only on macOS)" <<< "$out"'
out="$(crun __engine_choices)"
check "macOS choices: podman, Docker Desktop and Colima" 'grep -q "^podman|Podman|" <<< "$out" && grep -q "^docker|Docker Desktop|" <<< "$out" && grep -q "^colima|Colima|installed|$" <<< "$out"'
out="$(SHIM_ARM=0 crun __engine_choices)"
check "macOS choices on an Intel Mac: Podman refused with the reason" 'grep -q "^podman|Podman|[a-z]*|Intel Macs are not supported" <<< "$out" && grep -q "^colima|Colima|[a-z]*|$" <<< "$out"'
# Colima keeps its settings where Colima looks: XDG_CONFIG_HOME when ~/.colima does not exist
reset_docker; cp "$T/inst/brew" "$T/bin/brew"
XY="$T/home/xdg/colima/default/colima.yaml"
out="$(XDG_CONFIG_HOME="$T/home/xdg" crun install-engine)"; rc=$?
check "Colima with XDG_CONFIG_HOME: the provision script in its colima.yaml there" '[ "$rc" -eq 0 ] && grep -q "^    script: sysctl -w vm.max_map_count=262144$" "$XY" && [ ! -e "$T/home/.colima" ]'
rm -f "$T/colima.running"; sed -i 's/^vmType: .*/vmType: qemu/' "$XY"
out="$(XDG_CONFIG_HOME="$T/home/xdg" crun install-engine)"; rc=$?
check "Colima with XDG_CONFIG_HOME: a qemu VM there is refused" '[ "$rc" -ne 0 ] && grep -q "runs with qemu, which cannot use Rosetta" <<< "$out"'

# --- macOS: Docker Desktop and Colima are two VMs, each with its own containers and volumes ---------------
reset_docker; cp "$T/inst/brew" "$T/bin/brew"; cp "$T/inst/docker" "$T/bin/docker"; cp "$T/inst/colima" "$T/bin/colima"
mkdir -p "$T/home/Applications/Docker.app"; touch "$T/docker.plugin" "$T/docker.up" "$T/dd.ctx" "$T/colima.running" "$T/colima.ctx"
echo colima > "$T/docker.ctx"
out="$(SHIM_DATA_desktop_linux=cc crun install-engine)"; rc=$?
check "Colima folder, data in Docker Desktop: refused, nothing set up" '[ "$rc" -ne 0 ] && grep -q "project \"cc\" are in Docker Desktop, but this folder uses Colima" <<< "$out" && ! grep -q "^colima start" "$LOG" && ! grep -q "^brew services start" "$LOG"'
out="$(SHIM_DATA_desktop_linux=cc crun __engine_choices)"
check "choices: Docker Desktop holds the data - Colima is not selectable" 'grep -q "^docker|Docker Desktop|data|$" <<< "$out" && grep -q "^colima|Colima|[a-z]*|The containers or data volumes of this installation are in Docker Desktop - one engine per server.$" <<< "$out"'
out="$(SHIM_DATA_desktop_linux=cc crun check)"
check "check: the data in Docker Desktop named for a Colima folder" 'grep -q "are in Docker Desktop, but this folder uses Colima" <<< "$out"'
out="$(SHIM_DATA_desktop_linux=dd SHIM_OS=Darwin PROVIDER= drun install-docker)"; rc=$?
check "Docker Desktop folder with its data, current context Colima's: allowed" '[ "$rc" -eq 0 ]'
out="$(SHIM_DATA_colima=dd SHIM_OS=Darwin PROVIDER= drun install-docker)"; rc=$?
check "Docker Desktop folder, data in Colima: refused" '[ "$rc" -ne 0 ] && grep -q "project \"dd\" are in Colima, but this folder uses Docker Desktop" <<< "$out"'
echo desktop-linux > "$T/docker.ctx"; : > "$T/ctx.log"
out="$(SHIM_DATA_colima=cc crun install-engine)"; rc=$?
check "Colima folder with its data, current context Docker Desktop's: allowed, the docker command talks to Colima" '[ "$rc" -eq 0 ] && grep -q "^colima: docker info$" "$T/ctx.log" && ! grep -q "^desktop-linux: docker info" "$T/ctx.log"'
EI="$T/ee/rn1-technology-catalog-installer.sh"; mkdir -p "$T/ee"
sed 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$NEW" > "$EI"
erun() { (cd "$T/ee" && HOME="$T/home" SHIM_OS=Darwin PATH="$T/bin:$SYSPATH" bash "$EI" "$@" </dev/null 2>/dev/null); }
check "CONTAINER_ENGINE empty, data only in Colima: Colima" '[ "$(SHIM_DATA_colima=ee erun __engine)" = "docker colima Colima" ]'
check "CONTAINER_ENGINE empty, data only in Docker Desktop: Docker" '[ "$(SHIM_DATA_desktop_linux=ee erun __engine)" = "docker docker Docker" ]'
out="$(cd "$T/ee" && HOME="$T/home" SHIM_OS=Darwin SHIM_DATA_colima=ee SHIM_DATA_desktop_linux=ee PATH="$T/bin:$SYSPATH" bash "$EI" install-engine </dev/null 2>&1)"; rc=$?
check "CONTAINER_ENGINE empty, data in both VMs: a choice is asked for" '[ "$rc" -ne 0 ] && grep -q "are in Docker Desktop and in Colima" <<< "$out" && grep -q "choose the one to go on with" <<< "$out"'
# the engine the new installation (I) takes on Enter
check "new installation, data in Colima: Enter takes Colima" '[ "$(SHIM_DATA_colima=ee erun __wiz_engine_pick)" = colima ]'
reset_podman; reset_docker
check "new installation on a Mac without an engine: Enter takes Podman" '[ "$(erun __wiz_engine_pick)" = podman ]'
check "new installation on an Intel Mac without an engine: Colima, not Docker Desktop (its license comes first)" '[ "$(SHIM_ARM=0 erun __wiz_engine_pick)" = colima ]'
check "new installation on macOS 15 without an engine: Colima (Podman needs macOS 26)" '[ "$(SHIM_MACOS=15.6 erun __wiz_engine_pick)" = colima ]'
mkdir -p "$T/home/Applications/Docker.app"; cp "$T/inst/docker" "$T/bin/docker"; touch "$T/docker.plugin" "$T/docker.up" "$T/dd.ctx"
check "new installation on a Mac with Docker Desktop: Enter takes it" '[ "$(erun __wiz_engine_pick)" = docker ]'

# --- macOS start: Homebrew, a current bash and the GNU tools, each checked, installed only after a yes ------
B="$T/boot"; rm -rf "$B"; mkdir -p "$B"; cp "$NEW" "$B/i.sh"
brun() { (cd "$B" && HOME="$T/home" SHIM_OS=Darwin RN1_MAC_BOOTSTRAPPED= RN1_BREW_DIRS="$T/hb/bin" PATH="$T/bin:$SYSPATH" bash i.sh "$@" 2>&1); }
rm -rf "$T/hb" "$T/brew" "$T/bin/brew"; : > "$LOG"
out="$(SHIM_UID=0 brun help </dev/null)"; rc=$?
check "macOS start as root: refused before anything" '[ "$rc" -ne 0 ] && grep -q "On macOS run i.sh as your normal user, not as root" <<< "$out" && ! grep -q . "$LOG"'
out="$(brun help </dev/null)"; rc=$?
check "macOS start without Homebrew and without a terminal: says why and how, installs nothing" '[ "$rc" -ne 0 ] && grep -q "Homebrew is not installed. The installer needs it" <<< "$out" && grep -qF "/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"" <<< "$out" && grep -q "Homebrew.s installer needs a terminal" <<< "$out" && ! grep -q "Install Homebrew now?" <<< "$out" && ! grep -q "homebrew install.sh" "$LOG"'
# Homebrew's own installer needs a terminal: these cases run in one (script from util-linux)
if script --version 2>/dev/null | grep -q util-linux; then
  trun() { # ANSWERS... -> the start check in a terminal, one answer after each question
    local keys="" a
    for a in "$@"; do keys="$keys sleep 2; printf '%s\\n' '$a';"; done
    (cd "$B" && { eval "$keys"; sleep 3; } | HOME="$T/home" SHIM_OS=Darwin RN1_MAC_BOOTSTRAPPED= RN1_BREW_DIRS="$T/hb/bin" PATH="$T/bin:$SYSPATH" \
      TERM=xterm timeout 60 script -qfec "stty sane; bash i.sh help" /dev/null 2>&1) | tr -d '\r'
  }
  out="$(trun n)"
  check "macOS start without Homebrew, answered no: nothing installed" 'grep -q "Install Homebrew now?" <<< "$out" && grep -q "Nothing was installed. Install Homebrew from https://brew.sh" <<< "$out" && [ ! -e "$T/hb/bin/brew" ]'
  out="$(SHIM_GITHUB_DOWN=1 trun y)"
  check "macOS start, Homebrew script not downloadable: named, not called installed" 'grep -q "The Homebrew install script could not be downloaded" <<< "$out" && ! grep -q "Homebrew is installed" <<< "$out" && [ ! -e "$T/hb/bin/brew" ]'
  : > "$LOG"
  out="$(trun y y)"
  check "macOS start, yes and yes: Homebrew from brew.sh, then bash and the GNU tools, then the installer runs" 'grep -q "homebrew install.sh" "$LOG" && grep -q "Homebrew is installed" <<< "$out" && grep -q "Homebrew installs what the installer needs here: bash coreutils gnu-sed grep findutils" <<< "$out" && grep -q "^brew install bash coreutils gnu-sed grep findutils$" "$LOG" && grep -q "^Usage:" <<< "$out" || { tail -n 12 <<< "$out" | sed "s/^/  > /"; false; }'
fi
# Homebrew there (as after its installer): the formulas are checked and installed without a terminal too
mkdir -p "$T/hb/bin"; cp "$T/inst/brew" "$T/hb/bin/brew"; rm -rf "$T/brew"; : > "$LOG"
out="$(printf 'n\n' | brun help)"; rc=$?
check "macOS start, the formulas missing, answered no: named, nothing installed" '[ "$rc" -ne 0 ] && grep -q "Homebrew installs what the installer needs here: bash coreutils gnu-sed grep findutils$" <<< "$out" && grep -q "Nothing was installed. The installer needs them: brew install bash coreutils gnu-sed grep findutils" <<< "$out" && ! grep -q "^brew install" "$LOG"'
out="$(printf 'y\n' | brun help)"; rc=$?
check "macOS start, the formulas missing, answered yes: installed, then the installer runs" '[ "$rc" -eq 0 ] && grep -q "^brew install bash coreutils gnu-sed grep findutils$" "$LOG" && grep -q "^Usage:" <<< "$out"'
: > "$LOG"
out="$(brun help </dev/null)"; rc=$?
check "macOS start with everything there: no question, no install" '[ "$rc" -eq 0 ] && ! grep -q "Homebrew installs\|Install Homebrew" <<< "$out" && ! grep -q "^brew install" "$LOG" && grep -q "^Usage:" <<< "$out"'
rm -rf "$T/brew/opt/gnu-sed" "$T/brew/opt/grep"; : > "$LOG"
out="$(printf 'n\n' | brun help)"; rc=$?
check "macOS start, two tools missing, answered no: named, nothing installed" '[ "$rc" -ne 0 ] && grep -q "Homebrew installs what the installer needs here: gnu-sed grep$" <<< "$out" && grep -q "Nothing was installed. The installer needs them: brew install gnu-sed grep" <<< "$out" && ! grep -q "^brew install" "$LOG"'
rm -rf "$T/hb" "$T/brew"

check "fakes: no unknown docker, colima, brew or open call" '[ ! -s "$BAD" ] || { sort "$BAD" | uniq -c | head -20; false; }'

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
