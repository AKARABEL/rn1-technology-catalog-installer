#!/usr/bin/env bash
set -u
NEW="$1"
T="$(mktemp -d)/w"
rm -rf "$T"; mkdir -p "$T/bin" "$T/d"
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

# what this machine is: the package manager and the distribution family
PM=""
for p in apt-get dnf yum zypper apk; do
  if command -v "$p" >/dev/null 2>&1; then PM="$p"; break; fi
done
ID=""; LIKE=""
if [ -r /etc/os-release ]; then
  ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
  LIKE=" $(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"') "
fi
case "$ID" in
  rhel) FAMILY="rhel" ;;
  centos|rocky|almalinux|ol) FAMILY="centos" ;;
  fedora) FAMILY="fedora" ;;
  ubuntu|debian) FAMILY="$ID" ;;
  *)
    case "$LIKE" in
      *" rhel "*|*" centos "*) FAMILY="centos" ;;
      *" ubuntu "*) FAMILY="ubuntu" ;;
      *" debian "*) FAMILY="debian" ;;
      *suse*) FAMILY="suse" ;;
      *) FAMILY="$ID" ;;
    esac
    ;;
esac
case "$ID" in opensuse*|sles*|sled*) FAMILY="suse" ;; esac
echo "== $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | tr -d '"'), bash $BASH_VERSION, package manager ${PM:-none}, family ${FAMILY:-unknown}"

# Fake docker: SHIM_PODMAN = it is podman-docker, SHIM_NO_COMPOSE = no compose plugin
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) if [ -n "${SHIM_PODMAN:-}" ]; then echo "podman version 5.2.2"; else echo "Docker version 28.0.1, build 068a01e"; fi ;;
  info) exit 0 ;;
  compose) [ -n "${SHIM_NO_COMPOSE:-}" ] && exit 1; echo "Docker Compose version v2.33.1" ;;
  *) exit 0 ;;
esac
EOF
# an old docker-compose, so that a real one on this machine is not used
cat > "$T/bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "version" ] && echo "1.25.0"
exit 0
EOF
printf '#!/usr/bin/env bash\necho Linux\n' > "$T/bin/uname"
sed -i 's/^printf/[ "$1" = "-r" ] \&\& { echo 6.8.0; exit 0; }\nprintf/' "$T/bin/uname"
chmod +x "$T/bin/"*
I="$T/d/rn1-technology-catalog-installer.sh"
cp "$NEW" "$I"
sed -i 's/^CHECK_FOR_UPDATES=.*/CHECK_FOR_UPDATES="false"/' "$I"
run() { (cd "$T/d" && PATH="$T/bin:$PATH" bash "$I" "$@" </dev/null 2>&1); }

# the commands that install Docker Engine on this distribution
case "$FAMILY" in
  rhel|centos)
    if [ "$PM" = "yum" ]; then CFG="sudo yum-config-manager --add-repo https://download.docker.com/linux/$FAMILY/docker-ce.repo"
    else CFG="sudo dnf config-manager --add-repo https://download.docker.com/linux/$FAMILY/docker-ce.repo"; fi
    WANT="$CFG"
    WANT2="sudo $PM -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin"
    ;;
  ubuntu|debian|fedora) WANT="https://docs.docker.com/engine/install/$FAMILY/"; WANT2="docker-compose-plugin" ;;
  suse) WANT="sudo zypper install docker docker-compose"; WANT2="sudo systemctl enable --now docker" ;;
  *) WANT="https://docs.docker.com/engine/install/"; WANT2="$WANT" ;;
esac

out="$(SHIM_PODMAN=1 run check)"
check "podman-docker is named as the problem" 'grep -q "is Podman (podman-docker), which this installer does not support" <<< "$out"'
check "Docker Engine install steps for this distribution ($FAMILY)" 'grep -qF -- "$WANT" <<< "$out" && grep -qF -- "$WANT2" <<< "$out"'
check "no apt-get hint on a distribution without apt-get" '[ "$PM" = "apt-get" ] || ! grep -q "apt-get" <<< "$out"'

run generate >/dev/null
out="$(SHIM_PODMAN=1 run up)"; rc=$?
check "start refuses podman-docker" '[ "$rc" -ne 0 ] && grep -q "is Podman (podman-docker)" <<< "$out"'

case "$PM" in
  "") HINT="install docker-compose-plugin" ;;
  zypper) HINT="sudo zypper install docker-compose" ;;
  apk) HINT="sudo apk add docker-compose-plugin" ;;
  *) HINT="sudo $PM install docker-compose" ;;
esac
out="$(SHIM_NO_COMPOSE=1 run check)"
check "missing Compose plugin: install command of this machine ($PM)" 'grep -q "docker-compose 1.25.0 is too old" <<< "$out" && grep -qF -- "install the Compose plugin: $HINT" <<< "$out"'

out="$(run check)"
check "a working Docker passes the Docker checks" 'grep -q "Docker CLI: Docker version 28.0.1" <<< "$out" && grep -q "Compose: Docker Compose version v2.33.1" <<< "$out" && ! grep -q "Podman" <<< "$out"'

# a UTF-8 locale that is not installed (C.UTF-8 on CentOS 7): plain characters, else the boxes break
# (only with glibc: Git Bash accepts every locale name)
if [ -r /etc/os-release ] && command -v locale >/dev/null 2>&1; then
  out="$(cd "$T/d" && printf '0\n' | LC_ALL= LC_CTYPE= LANG=xx_YY.UTF-8 PATH="$T/bin:$PATH" bash "$I" menu 2>&1)"
  check "UTF-8 locale that is not installed: plain characters" 'grep -q "I install - U update - R remove" <<< "$out"'
  UTF="$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -n 1)"
  if [ -n "$UTF" ]; then
    out="$(cd "$T/d" && printf '0\n' | LC_ALL= LC_CTYPE= LANG="$UTF" PATH="$T/bin:$PATH" bash "$I" menu 2>&1)"
    check "installed UTF-8 locale ($UTF): line characters" 'grep -q "I install · U update · R remove" <<< "$out"'
  fi
fi

if ! command -v docker >/dev/null 2>&1; then
  out="$(cd "$T/d" && bash "$I" check </dev/null 2>&1)"
  check "no Docker at all: install steps for this distribution" 'grep -q "Docker is not installed" <<< "$out" && grep -qF -- "$WANT" <<< "$out"'
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
