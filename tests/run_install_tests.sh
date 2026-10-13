#!/usr/bin/env bash
# The one-line install (install.sh) against a fake curl and wget; runs in the bash 3.2 of macOS too
set -u
REAL="$1"
INSTALL="$(cd "$(dirname "$1")" && pwd)/install.sh"
# the bash that runs these tests runs install.sh too (/bin/bash 3.2 on macOS); the sections run again under
# dash (curl ... | sh on Debian and Ubuntu), where it exists
BASHSH="${BASH:-bash}"
SH="$BASHSH"
TAG=""
# (the folder as install.sh names it: the TMPDIR of macOS ends with a slash)
T="$(cd "$(mktemp -d)" && pwd)"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
SRV="$T/srv"
mkdir -p "$SRV" "$T/bin" "$T/minbin" "$T/oldbash"
export SRV
unset https_proxy HTTPS_PROXY http_proxy HTTP_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY RN1_DIR RN1_INSTALLER_URL FAKE_READ SHIM_SERVE CDPATH
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $TAG$1"; else FAIL=$((FAIL+1)); echo "FAIL: $TAG$1"; fi; }
URL="https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh"
LINE="curl -fsSL https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/install.sh"
NAME="rn1-technology-catalog-installer.sh"

# A fake installer: what the real one has at its start and end, and what it was started with
cat > "$SRV/fake.sh" <<'EOF'
#!/usr/bin/env bash
###############################################################################
# CONFIGURE ONLY THIS SECTION
###############################################################################
SETTING="fake-default"
###############################################################################
# DO NOT CHANGE ANYTHING BELOW
###############################################################################
main() {
  local t=no line=""
  if [ -t 0 ]; then t=yes; fi
  echo "FAKE-INSTALLER name=${0##*/} args=[$*] tty=$t dir=$PWD setting=$SETTING"
  echo "${0##*/} [$*] tty=$t" >> "$SRV/started"
  printf 'ARG<%s>\n' "$@" > "$SRV/args"
  if [ "$t" = yes ] && [ -n "${FAKE_READ:-}" ]; then
    read -r line
    echo "READ=[$line]"
  fi
  # in a terminal: time to read the output before the terminal closes
  if [ "$t" = yes ]; then sleep 0.5; fi
}
main "$@"; exit $?
EOF
cp "$REAL" "$SRV/real.sh"
size=$(( $(wc -c < "$REAL") ))
head -c $((size / 2)) "$REAL" > "$SRV/cut.sh"
# whole, but one thing missing: the bash shebang, one of the two markers of the settings section, the last line
sed '1s|.*|#!/bin/sh|' "$SRV/fake.sh" > "$SRV/noshebang.sh"
grep -v '^# CONFIGURE ONLY THIS SECTION' "$SRV/fake.sh" > "$SRV/nomarker1.sh"
grep -v '^# DO NOT CHANGE ANYTHING BELOW' "$SRV/fake.sh" > "$SRV/nomarker2.sh"
sed '$d' "$SRV/fake.sh" > "$SRV/nolast.sh"
# the real generator script of before the installer: bash, both markers, and not an installer
cp "$(dirname "$INSTALL")/tests/original.sh" "$SRV/original.sh"
# whole, and blank lines after the last one (an editor, a copy through a mail)
{ cat "$SRV/fake.sh"; printf '\n\n  \n\t\n\n'; } > "$SRV/blank.sh"
# whole at both ends, but a syntax error in the middle
{ head -n 9 "$SRV/fake.sh"; echo 'if then fi ('; tail -n 10 "$SRV/fake.sh"; } > "$SRV/syntax.sh"
# the original generator script: settings section, but no installer (it writes .env at once)
cat > "$SRV/generator.sh" <<'EOF'
#!/usr/bin/env bash
###############################################################################
# CONFIGURE ONLY THIS SECTION
###############################################################################
ENV_FILE=".env"
###############################################################################
# DO NOT CHANGE ANYTHING BELOW
###############################################################################
echo "GENERATOR-RAN" >> "$SRV/started"
echo "MONGO_INITDB_ROOT_PASSWORD=new" > "$ENV_FILE"
EOF

# curl and wget: install.sh from the checkout, the installer as SHIM_SERVE says
cat > "$SRV/serve" <<'EOF'
# serve OUT URL TOOL
out="$1"; url="$2"
printf '%s\n' "$url" >> "$SRV/urls"
printf '%s https_proxy=%s\n' "$3" "${https_proxy:-}" >> "$SRV/env"
case "$url" in
  */install.sh) cat "$INSTALL"; exit 0 ;;
esac
mode="${SHIM_SERVE:-fake}"
case "$mode" in
  html) printf '<!doctype html><html><body>Blocked by the proxy</body></html>\n' > "$out" ;;
  fail)
    if [ "$3" = curl ]; then echo "curl: (6) Could not resolve host: raw.githubusercontent.com" >&2; exit 6; fi
    echo "wget: unable to resolve host address 'raw.githubusercontent.com'" >&2; exit 4
    ;;
  # fails after something else (not the temporary file) was put into the folder
  stray) : > stray; echo "curl: (6) Could not resolve host: raw.githubusercontent.com" >&2; exit 6 ;;
  # a folder appears at the name (ln would link the file into it)
  dirrace) cat "$SRV/fake.sh" > "$out"; mkdir rn1-technology-catalog-installer.sh ;;
  # an empty installer appears at the name (another run truncates it before it writes)
  emptyrace) cat "$SRV/fake.sh" > "$out"; : > rn1-technology-catalog-installer.sh ;;
  # a link to an empty file appears at the name, and looks old (an empty file is replaced when it is old; a link never)
  oldlinkrace) cat "$SRV/fake.sh" > "$out"; : > empty-target; touch -t 202001010000 empty-target; ln -s empty-target rn1-technology-catalog-installer.sh; touch -h -t 202001010000 rn1-technology-catalog-installer.sh 2>/dev/null ;;
  # a link to nowhere appears at the name (somebody else, another run)
  linkrace) cat "$SRV/fake.sh" > "$out"; ln -s /nowhere/at/all rn1-technology-catalog-installer.sh ;;
  # another run of the one-line install was faster: its installer is there, with a setting the user saved
  race) cat "$SRV/fake.sh" > "$out"; sed 's/^SETTING=.*/SETTING="users-own-value"/' "$SRV/fake.sh" > rn1-technology-catalog-installer.sh; chmod 755 rn1-technology-catalog-installer.sh ;;
  # the file stays open, as curl and wget keep it
  slow) exec 3> "$out"; head -c 100 "$SRV/fake.sh" >&3; : > "$SRV/slow-started"; sleep 3; cat "$SRV/fake.sh" >&3 ;;
  # any other mode is the file of that name in $SRV
  *) if [ -f "$SRV/$mode.sh" ]; then cat "$SRV/$mode.sh" > "$out"; else echo "UNKNOWN SHIM_SERVE=$mode" >&2; exit 99; fi ;;
esac
EOF
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
out=/dev/stdout; url=""
printf '%s\n' "$*" >> "$SRV/curl.args"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --proto|--proto-redir|--connect-timeout|--max-time|--speed-limit|--speed-time|--retry|--retry-max-time) shift 2 ;;
    -fsSL) shift ;;
    -*) echo "curl: option $1: is unknown" >&2; exit 2 ;;
    *) url="$1"; shift ;;
  esac
done
set -- "$out" "$url" curl; . "$SRV/serve"
EOF
cat > "$T/bin/wget" <<'EOF'
#!/bin/sh
out=""; url=""
printf '%s\n' "$*" >> "$SRV/wget.args"
while [ $# -gt 0 ]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    -T|-t) shift 2 ;;
    -nv) shift ;;
    -*) echo "wget: unrecognized option '$1'" >&2; exit 2 ;;
    *) url="$1"; shift ;;
  esac
done
[ "$out" = "-" ] && out=/dev/stdout
set -- "$out" "$url" wget; . "$SRV/serve"
EOF
chmod +x "$T/bin/curl" "$T/bin/wget"
export INSTALL

# PATH without curl and wget: only the tools install.sh and the fakes use
MINTOOLS="bash sh env mkdir mktemp head tail grep sed chmod mv ln rm rmdir cat cksum sleep ls find id setsid python3"
# mkbin DIR [TOOL...]: DIR with a link to each tool of the list above except the TOOLs named
mkbin() {
  local d="$1" t p
  shift
  mkdir -p "$d"
  for t in $MINTOOLS; do
    case " $* " in *" $t "*) continue ;; esac
    p="$(command -v "$t")" && ln -s "$p" "$d/$t"
  done
}
mkbin "$T/minbin"
# an id that says the user number FAKE_UID (else the real answer): to be root, or not, whoever runs the tests
mkdir -p "$T/idbin"
printf '#!/bin/sh\nif [ "$#" -eq 1 ] && [ "$1" = -u ] && [ -n "${FAKE_UID:-}" ]; then echo "$FAKE_UID"; else exec %s "$@"; fi\n' "$(command -v id)" > "$T/idbin/id"
chmod +x "$T/idbin/id"
# a bash older than 4 (the bash 3.2 of macOS): it cannot check the whole installer
REALBASH="$(command -v bash)"
cat > "$T/oldbash/bash" <<EOF
#!/bin/sh
case "\$1" in
  -c) case "\$2" in *BASH_VERSINFO*) exit 1 ;; esac ;;
  -n) echo "syntax error near unexpected token (bash 3.2)" >&2; exit 2 ;;
esac
exec "$REALBASH" "\$@"
EOF
chmod +x "$T/oldbash/bash"
FAKEPATH="$T/bin:$PATH"

N=0
fresh() {
  N=$((N + 1)); D="$T/d$N"; mkdir -p "$D"
  rm -f "$SRV/urls" "$SRV/started" "$SRV/args" "$SRV/curl.args" "$SRV/wget.args" "$SRV/env" "$SRV/slow-started"
}
empty() { [ -z "$(ls -A "$1")" ]; }
same() { [ "$(cksum < "$1")" = "$(cksum < "$2")" ]; }
# without a controlling terminal, also when these tests run in one
notty() {
  if ! (: < /dev/tty) 2>/dev/null; then
    "$@"
  elif command -v setsid >/dev/null 2>&1; then
    setsid "$@"
  else
    python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"
  fi
}
# give_away FILE: the file belongs to another user afterwards (root: nobody; otherwise sudo, if it needs no password)
give_away() {
  if [ "$(id -u)" = 0 ]; then
    chown nobody "$1" 2>/dev/null
  else
    sudo -n chown root "$1" 2>/dev/null
  fi && [ ! -O "$1" ]
}
# Lines a shell prints when something is wrong in the script (bash and dash): none may be in the output of a run
SHELLERR='line [0-9]+: |^[^ ]*sh: [0-9]+: |^[^ ]*install[.]sh: [0-9]+: |[Ss]yntax error|command not found|: not found$|[Uu]nterminated|[Bb]ad substitution|unexpected EOF|unexpected token'
CLEAN=0
scan() {
  shellerr="$(grep -E "$SHELLERR" <<< "$out")"
  if [ -n "$shellerr" ]; then
    FAIL=$((FAIL+1)); echo "FAIL: ${TAG}shell error text in the output of a run: $shellerr"
  else
    CLEAN=$((CLEAN+1))
  fi
}
# give_away_link LINK: the link itself (not its target) belongs to another user afterwards, as give_away does
give_away_link() {
  if [ "$(id -u)" = 0 ]; then
    chown -h nobody "$1" 2>/dev/null
  else
    sudo -n chown -h root "$1" 2>/dev/null
  fi && [ "$(ls -ldn "$1" | { read -r _ _ u _; echo "$u"; })" != "$(id -u)" ]
}
# run [VAR=VALUE...] -- ARGS: bash install.sh ARGS in $D, no terminal, PATH with the fakes
run() {
  out="$(
    cd "$D" || exit 99
    while [ "$1" != "--" ]; do export "$1"; shift; done
    shift
    export PATH="$FAKEPATH"
    notty "$SH" "$INSTALL" "$@" < /dev/null 2>&1
  )"; rc=$?
  scan
}

# 0. The script itself
check "install.sh: bash -n" '"$SH" -n "$INSTALL"'
if command -v dash >/dev/null 2>&1; then
  check "install.sh: dash -n (curl ... | sh works too)" 'dash -n "$INSTALL"'
fi
bash4="$(grep -nE 'mapfile|readarray|declare -A|local -n|[|]&|[$][{][^}]*(,,|\^\^)' "$INSTALL")"
check "install.sh: no bash 4 features (case changes, mapfile, associative arrays, |&, namerefs)" '[ -z "$bash4" ]'
outside="$(grep -vE '^(#|$|[a-z0-9_]+[(][)] [{]|  |[}]|[{] rn1_install)' "$INSTALL")"
check "install.sh: everything in functions, called in braces in the last line" '[ -z "$outside" ] && [ "$(tail -n 1 "$INSTALL")" = "{ rn1_install \"\$@\"; }" ]'

# The sections 1 to 13 run once per shell (SH): the traps, the /dev/tty probe and the exec behave differently
# in dash than in bash. (The body of the function is not indented, to keep the sections readable.)
suite() {

# 1. Empty folder: downloaded, checked, executable; without a terminal not started, the start line printed
fresh
run -- self-update --no-menu
check "empty folder: downloaded from main, executable, the same bytes" '[ -x "$D/$NAME" ] && same "$D/$NAME" "$SRV/fake.sh" && [ "$(cat "$SRV/urls")" = "$URL" ]'
check "empty folder: the folder named, what was done said" 'grep -qx "Folder: $D" <<< "$out" && grep -qx "Downloading $URL" <<< "$out" && grep -qx "Downloaded and checked: $D/$NAME" <<< "$out"'
check "no terminal, arguments given: not started, the start line with the arguments printed, exit code not 0" '[ "$rc" -ne 0 ] && [ ! -e "$SRV/started" ] && grep -qx "ERROR There is no terminal here, so the installer was not started with these arguments. It is in place." <<< "$out" && grep -qx "  cd $D && ./$NAME self-update --no-menu" <<< "$out" && [ -x "$D/$NAME" ]'
fresh
run --
check "no terminal, no arguments: downloaded, not started, the start line printed, exit code 0" '[ "$rc" -eq 0 ] && [ ! -e "$SRV/started" ] && grep -q "^There is no terminal for the menu here, so the installer was not started. Start it with:$" <<< "$out" && grep -qx "  cd $D && ./$NAME" <<< "$out" && ! grep -q "^ERROR" <<< "$out"'
check "curl: https only (--proto =https, also after a redirect), errors shown (-fsSL)" 'grep -q -- "-fsSL --proto =https --proto-redir =https " "$SRV/curl.args"'
# (curl's speed clock includes the wait for the first byte: a proxy that scans the file first holds it for a
# while - the limit may only end a download that does not move for a long time)
speedtime="$(sed -n 's/.* --speed-time \([0-9][0-9]*\) .*/\1/p' "$SRV/curl.args" | head -n 1)"
check "curl: a stalled download ends (--speed-limit 1024), a late one - held by a scanning proxy - does not (--speed-time at least 60, now $speedtime), retries bounded" '[ "${speedtime:-0}" -ge 60 ] && grep -q -- " --speed-limit 1024 " "$SRV/curl.args" && grep -q -- " --retry 2 --retry-max-time 120 " "$SRV/curl.args"'
check "no temporary file left" '[ "$(ls -A "$D")" = "$NAME" ]'

# 2. An installer is already there: nothing downloaded, not touched
fresh
sed 's/^SETTING=.*/SETTING="mine"/' "$SRV/fake.sh" > "$D/$NAME"; chmod +x "$D/$NAME"
before="$(cksum < "$D/$NAME")"
run --
check "existing installer: not downloaded, untouched (cksum), said so" '[ "$rc" -eq 0 ] && [ ! -e "$SRV/urls" ] && [ "$(cksum < "$D/$NAME")" = "$before" ] && grep -qx "The installer is already here: $D/$NAME (its settings are kept). Updates: option 22." <<< "$out"'
check "existing installer: no terminal - the start line" 'grep -qx "  cd $D && ./$NAME" <<< "$out" && [ ! -e "$SRV/started" ]'
run -- setup 'a b'
check "existing installer, no terminal, arguments given: exit code not 0, the line with the arguments quoted, nothing started" '[ "$rc" -ne 0 ] && [ ! -e "$SRV/started" ] && grep -qx "  cd $D && ./$NAME setup '\''a b'\''" <<< "$out" && grep -q "^ERROR There is no terminal here" <<< "$out" && [ "$(cksum < "$D/$NAME")" = "$before" ]'
chmod -x "$D/$NAME"
run --
check "existing installer without the x bit: started with bash" 'grep -qx "  cd $D && bash $NAME" <<< "$out" && [ "$(cksum < "$D/$NAME")" = "$before" ]'

# 2b. An installer that is not the user's own, or that everybody can write to, is not started (a file planted in
# /tmp); one that the group can write to is (Debian and Ubuntu create files with the mode 664)
fresh
cp "$SRV/fake.sh" "$D/$NAME"; chmod 775 "$D/$NAME"; chmod g+w "$D/$NAME"
run --
check "group-writable installer: used as usual" '[ "$rc" -eq 0 ] && grep -qx "The installer is already here: $D/$NAME (its settings are kept). Updates: option 22." <<< "$out" && grep -qx "  cd $D && ./$NAME" <<< "$out"'
for mode in 666 777 757 646; do
  fresh
  cp "$SRV/fake.sh" "$D/$NAME"; chmod "$mode" "$D/$NAME"
  before="$(cksum < "$D/$NAME")"
  run -- setup
  case "$mode" in 777|757) lead="./" ;; *) lead="bash " ;; esac
  check "installer with the mode $mode: not started, why, the line to start it after a look, exit code" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME was not started: everybody can write to it" <<< "$out" && grep -qx "  cd $D && $lead$NAME setup" <<< "$out" && ! grep -q "The installer is already here" <<< "$out" && [ ! -e "$SRV/started" ] && [ ! -e "$SRV/urls" ] && [ "$(cksum < "$D/$NAME")" = "$before" ]'
done
# A folder everybody can write to and without the sticky bit lets anybody swap files in it between the check and
# the start: root is refused there, another user is warned (WSL and VirtualBox folders look like that, and work)
keep="$FAKEPATH"; FAKEPATH="$T/idbin:$FAKEPATH"
fresh
chmod 777 "$D"
run FAKE_UID=0 --
check "root in a folder everybody can write to (no sticky bit): refused, a private folder through RN1_DIR advised, nothing downloaded" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D can be written by everybody and has no sticky bit" <<< "$out" && grep -q "RN1_DIR=/opt/rn1-technology-catalog" <<< "$out" && [ ! -e "$SRV/urls" ] && empty "$D"'
fresh
chmod 777 "$D"; cp "$SRV/fake.sh" "$D/$NAME"; chmod 755 "$D/$NAME"
run FAKE_UID=0 --
check "root in such a folder, installer already there: refused too, not started" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D can be written by everybody" <<< "$out" && ! grep -q "The installer is already here" <<< "$out"'
fresh
chmod 777 "$D"
run FAKE_UID=1000 --
check "not root in such a folder: one warning, goes on" '[ "$rc" -eq 0 ] && [ "$(grep -c "^WARNING $D can be written by everybody" <<< "$out")" -eq 1 ] && same "$D/$NAME" "$SRV/fake.sh"'
fresh
chmod 1777 "$D"
run FAKE_UID=0 --
check "root in a folder with the sticky bit (like /tmp): no refusal, no warning" '[ "$rc" -eq 0 ] && ! grep -q "can be written by everybody" <<< "$out" && same "$D/$NAME" "$SRV/fake.sh"'
fresh
chmod 755 "$D"
run FAKE_UID=0 --
check "root in a folder of its own: as usual" '[ "$rc" -eq 0 ] && ! grep -q "can be written by everybody" <<< "$out"'
FAKEPATH="$keep"
# a link at the name must belong to the user too: its target can be changed by its owner at any moment
fresh
mkdir "$D/real"; cp "$SRV/fake.sh" "$D/real/inst.sh"; chmod 755 "$D/real/inst.sh"; ln -s real/inst.sh "$D/$NAME"
if give_away_link "$D/$NAME"; then
  run --
  check "installer that is a link of another user (its target is the user's): not started, said so" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME was not started: the link belongs to another user" <<< "$out" && ! grep -q "The installer is already here" <<< "$out"'
else
  echo "SKIP: a link of another user (this user cannot give a file away: neither root nor sudo without a password)"
fi

# An installer saved by an earlier run without sudo is used by a run with sudo (root, SUDO_UID is the user who
# started sudo) - and only then. Needs a real root: the file must belong to another user.
fresh
cp "$SRV/fake.sh" "$D/$NAME"; chmod 755 "$D/$NAME"
if [ "$(id -u)" = 0 ] && give_away "$D/$NAME"; then
  owner="$(ls -ldn "$D/$NAME" | { read -r _ _ u _; echo "$u"; })"
  run SUDO_UID="$owner" --
  check "root through sudo, installer of the user who started sudo (SUDO_UID): used" '[ "$rc" -eq 0 ] && grep -qx "The installer is already here: $D/$NAME (its settings are kept). Updates: option 22." <<< "$out"'
  run SUDO_UID=4242 --
  check "root, SUDO_UID is not the owner: not started" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME was not started: it belongs to another user" <<< "$out"'
  keep="$FAKEPATH"; FAKEPATH="$T/idbin:$FAKEPATH"
  run FAKE_UID=1000 SUDO_UID="$owner" --
  FAKEPATH="$keep"
  check "not root, SUDO_UID is the owner: not started (SUDO_UID counts for root only)" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME was not started: it belongs to another user" <<< "$out"'
else
  echo "SKIP: SUDO_UID (needs root: the installer must belong to another user)"
fi

# the check does not depend on find (a PATH without it) and does not pass what it cannot read (a PATH without ls)
fresh
mkbin "$T/nofind" find; cp "$T/bin/curl" "$T/bin/wget" "$T/nofind/"
cp "$SRV/fake.sh" "$D/$NAME"; chmod 666 "$D/$NAME"
keep="$FAKEPATH"; FAKEPATH="$T/nofind"
run --
check "no find on the PATH, installer everybody can write to: not started" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME was not started: everybody can write to it" <<< "$out" && [ ! -e "$SRV/urls" ]'
chmod 755 "$D/$NAME"
run --
FAKEPATH="$keep"
check "no find on the PATH, installer of the user: used as usual" '[ "$rc" -eq 0 ] && grep -qx "The installer is already here: $D/$NAME (its settings are kept). Updates: option 22." <<< "$out"'
fresh
mkbin "$T/nols" ls; cp "$T/bin/curl" "$T/bin/wget" "$T/nols/"
cp "$SRV/fake.sh" "$D/$NAME"; chmod 755 "$D/$NAME"
keep="$FAKEPATH"; FAKEPATH="$T/nols"
run --
FAKEPATH="$keep"
check "no ls on the PATH (the permissions cannot be read): not started, said so" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME was not started: its permissions could not be read" <<< "$out" && grep -qx "  cd $D && ./$NAME" <<< "$out"'
# (a link is judged by the file it leads to: a link itself always has the mode 777)
fresh
mkdir "$D/real"; cp "$SRV/fake.sh" "$D/real/inst.sh"; chmod 755 "$D/real/inst.sh"; ln -s real/inst.sh "$D/$NAME"
run --
check "installer that is a link to a file of the user: used as usual" '[ "$rc" -eq 0 ] && grep -qx "The installer is already here: $D/$NAME (its settings are kept). Updates: option 22." <<< "$out"'
chmod 666 "$D/real/inst.sh"
run --
check "installer that is a link to a file everybody can write to: not started" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME was not started: everybody can write to it" <<< "$out"'
fresh
cp "$SRV/fake.sh" "$D/catalog.sh"; chmod 777 "$D/catalog.sh"
run --
check "catalog.sh that everybody can write to: not started either" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/catalog.sh was not started: everybody can write to it" <<< "$out" && [ ! -e "$SRV/urls" ]'
fresh
cp "$SRV/fake.sh" "$D/$NAME"; chmod 755 "$D/$NAME"
if give_away "$D/$NAME"; then
  run --
  check "installer of another user: not started, why, the line to start it after a look" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME was not started: it belongs to another user" <<< "$out" && grep -qx "  cd $D && ./$NAME" <<< "$out" && ! grep -q "The installer is already here" <<< "$out" && [ ! -e "$SRV/urls" ]'
else
  echo "SKIP: an installer of another user (this user cannot give a file away: neither root nor sudo without a password)"
fi

# 3. catalog.sh (the name before the rename) is used; next to the new name the new name wins
fresh
cp "$SRV/fake.sh" "$D/catalog.sh"; chmod +x "$D/catalog.sh"
run --
check "catalog.sh: used, nothing downloaded" '[ "$rc" -eq 0 ] && [ ! -e "$SRV/urls" ] && [ ! -e "$D/$NAME" ] && grep -qx "The installer is already here: $D/catalog.sh (its settings are kept). Updates: option 22." <<< "$out" && grep -qx "  cd $D && ./catalog.sh" <<< "$out"'
cp "$SRV/fake.sh" "$D/$NAME"; chmod +x "$D/$NAME"
run --
check "catalog.sh and $NAME: $NAME is used" 'grep -qx "The installer is already here: $D/$NAME (its settings are kept). Updates: option 22." <<< "$out"'

# 4. catalog.sh that is the original generator script: never started, the installer is downloaded next to it
fresh
cp "$SRV/generator.sh" "$D/catalog.sh"; echo "MONGO_INITDB_ROOT_PASSWORD=kept" > "$D/.env"
run --
check "generator catalog.sh: not run, .env kept, the installer downloaded next to it" '[ "$rc" -eq 0 ] && [ ! -e "$SRV/started" ] && same "$D/catalog.sh" "$SRV/generator.sh" && grep -qx "MONGO_INITDB_ROOT_PASSWORD=kept" "$D/.env" && same "$D/$NAME" "$SRV/fake.sh"'

# 4b. The same with the real generator script (bash, both markers; only its end is not an installer's)
fresh
cp "$SRV/original.sh" "$D/catalog.sh"; chmod +x "$D/catalog.sh"; echo "MONGO_INITDB_ROOT_PASSWORD=kept" > "$D/.env"
run --
check "original.sh as catalog.sh: not run, .env and the script kept, the installer downloaded next to it" '[ "$rc" -eq 0 ] && same "$D/catalog.sh" "$SRV/original.sh" && grep -qx "MONGO_INITDB_ROOT_PASSWORD=kept" "$D/.env" && same "$D/$NAME" "$SRV/fake.sh" && [ ! -e "$D/docker-compose.yml" ]'

# 5. An empty installer (a wget -O that failed) is replaced; a broken one is left alone
fresh
: > "$D/$NAME"; touch -t 202001010000 "$D/$NAME"
run --
check "empty $NAME, older than a minute: replaced by the download" '[ "$rc" -eq 0 ] && same "$D/$NAME" "$SRV/fake.sh" && grep -q "The empty $NAME here (a download that failed) is replaced." <<< "$out"'
# an empty file that was changed a moment ago may be written by another run right now (the installer saves its
# settings with a truncate and a write): it is not touched
fresh
: > "$D/$NAME"
run --
check "empty $NAME, changed a moment ago: not replaced, nothing downloaded, said so" '[ "$rc" -ne 0 ] && [ ! -s "$D/$NAME" ] && [ ! -e "$SRV/urls" ] && grep -q "^ERROR $D/$NAME is empty and was changed a moment ago" <<< "$out" && grep -q "Run this line again in a minute" <<< "$out"'
fresh
run SHIM_SERVE=emptyrace --
check "an empty file appeared at the name during the download (another run is writing it): kept, said so" '[ "$rc" -ne 0 ] && [ ! -s "$D/$NAME" ] && [ "$(ls -A "$D")" = "$NAME" ] && grep -q "^ERROR $D/$NAME appeared during the download" <<< "$out"'
fresh
cp "$SRV/cut.sh" "$D/$NAME"
run --
check "cut $NAME there: left as it is, nothing downloaded, error" '[ "$rc" -ne 0 ] && [ ! -e "$SRV/urls" ] && same "$D/$NAME" "$SRV/cut.sh" && grep -q "ERROR $D/$NAME is not a complete installer" <<< "$out" && [ ! -e "$SRV/started" ]'

# 5a. What the advice for an installer that is not whole says, and what still counts as whole
# (an interrupted update leaves the file cut and a .bak-<timestamp> next to it with the settings)
fresh
cp "$SRV/cut.sh" "$D/$NAME"
run --
check "cut $NAME and no backup: no advice to throw it away - keep it, then a new one, then the settings" '[ "$rc" -ne 0 ] && grep -qx "  If you changed settings in it, keep it: mv $NAME $NAME.cut" <<< "$out" && grep -q "copy your settings" <<< "$out" && ! grep -q "Move it away" <<< "$out"'
cp "$SRV/fake.sh" "$D/$NAME.bak-20261012-101010"
sed 's/^SETTING=.*/SETTING="old-newest"/' "$SRV/fake.sh" > "$D/$NAME.bak-20261012-110000"
cp "$SRV/cut.sh" "$D/$NAME.bak-20261012-120000"
run --
check "cut $NAME and backups: the newest whole backup is named, with the command to put it back" 'grep -qx "  cp -p $D/$NAME.bak-20261012-110000 $D/$NAME" <<< "$out" && grep -q "update that broke off" <<< "$out" && ! grep -q "bak-20261012-120000\|bak-20261012-101010" <<< "$out"'
cp "$D/$NAME.bak-20261012-110000" "$D/$NAME"
run --
check "the backup put back: the line starts it with its settings" '[ "$rc" -eq 0 ] && grep -qx "The installer is already here: $D/$NAME (its settings are kept). Updates: option 22." <<< "$out" && grep -q "^SETTING=\"old-newest\"" "$D/$NAME"'
fresh
{ cat "$SRV/fake.sh"; printf '\n\n  \n\t\n'; } > "$D/$NAME"; chmod +x "$D/$NAME"
run --
check "installer with blank lines at the end: whole, used" '[ "$rc" -eq 0 ] && [ ! -e "$SRV/urls" ] && grep -qx "The installer is already here: $D/$NAME (its settings are kept). Updates: option 22." <<< "$out"'
fresh
{ sed '$d' "$SRV/fake.sh"; printf '\n\n'; } > "$D/$NAME"
run --
check "installer without its last line, blank lines at the end: still not whole" '[ "$rc" -ne 0 ] && grep -q "ERROR $D/$NAME is not a complete installer" <<< "$out" && [ ! -e "$SRV/urls" ]'
fresh
{ cat "$SRV/cut.sh"; printf '\n\n'; } > "$D/$NAME"
run --
check "cut installer with blank lines at the end: still not whole" '[ "$rc" -ne 0 ] && grep -q "ERROR $D/$NAME is not a complete installer" <<< "$out"'
fresh
run SHIM_SERVE=blank --
check "download with blank lines at the end: whole, kept as it is" '[ "$rc" -eq 0 ] && [ "$(cksum < "$D/$NAME")" = "$(cksum < "$SRV/blank.sh")" ]'
fresh
cp "$SRV/fake.sh" "$D/$NAME"; chmod 600 "$D/$NAME"; chmod u-r "$D/$NAME"
if [ ! -r "$D/$NAME" ]; then
  run --
  check "installer this user cannot read: said so, not called incomplete, no error text of head or grep" '[ "$rc" -ne 0 ] && grep -q "^ERROR $D/$NAME cannot be read by this user" <<< "$out" && ! grep -qi "not a complete\|permission denied\|head:\|grep:" <<< "$out" && [ ! -e "$SRV/urls" ]'
else
  echo "SKIP: an installer this user cannot read (root reads everything)"
fi
chmod u+r "$D/$NAME"

# 5b. A link at the name that leads to no installer is reported, never removed (a failed wget -O leaves an empty
# file, not a link); a folder with that name is an error; a file that appears during the download (another run,
# whose installer the user already saved settings in) is never replaced
fresh
ln -s "$T/does-not-exist" "$D/$NAME"
run --
check "dangling link $NAME: reported, left as it is, nothing downloaded" '[ "$rc" -ne 0 ] && [ -L "$D/$NAME" ] && [ ! -e "$D/$NAME" ] && [ ! -e "$SRV/urls" ] && grep -q "^ERROR $D/$NAME is a link that leads to no installer" <<< "$out" && grep -q "Remove it, then run this line again" <<< "$out"'
fresh
: > "$D/empty-target"; ln -s empty-target "$D/$NAME"
run --
check "link to an empty file: reported, left as it is" '[ "$rc" -ne 0 ] && [ -L "$D/$NAME" ] && [ ! -s "$D/empty-target" ] && [ ! -e "$SRV/urls" ] && grep -q "^ERROR $D/$NAME is a link that leads to no installer" <<< "$out"'
fresh
mkdir "$D/locked"; : > "$D/locked/inst.sh"; ln -s locked/inst.sh "$D/$NAME"; chmod 000 "$D/locked"
if [ ! -e "$D/locked/inst.sh" ]; then
  run --
  check "link to a place this user cannot search: reported, left as it is" '[ "$rc" -ne 0 ] && [ -L "$D/$NAME" ] && [ ! -e "$SRV/urls" ] && grep -q "^ERROR $D/$NAME is a link that leads to no installer" <<< "$out"'
else
  echo "SKIP: a link to a place this user cannot search (root can search everywhere)"
fi
chmod 755 "$D/locked"
fresh
run SHIM_SERVE=oldlinkrace --
check "an old looking link to an empty file appeared at the name during the download: kept, not replaced" '[ "$rc" -ne 0 ] && [ -L "$D/$NAME" ] && [ ! -s "$D/$NAME" ] && grep -q "^ERROR $D/$NAME appeared during the download" <<< "$out"'
fresh
run SHIM_SERVE=linkrace --
check "a link appeared at the name during the download: kept, not replaced, said so" '[ "$rc" -ne 0 ] && [ -L "$D/$NAME" ] && [ "$(ls -A "$D")" = "$NAME" ] && grep -q "^ERROR $D/$NAME appeared during the download" <<< "$out"'
fresh
mkdir "$D/$NAME"
run --
check "a folder named $NAME: error, nothing downloaded, nothing changed" '[ "$rc" -ne 0 ] && [ ! -e "$SRV/urls" ] && empty "$D/$NAME" && grep -q "ERROR $D/$NAME is a folder" <<< "$out"'
fresh
run SHIM_SERVE=race --
check "another run saved its installer during the download: kept with its settings, not replaced" '[ "$rc" -ne 0 ] && grep -q "^SETTING=\"users-own-value\"" "$D/$NAME" && [ -x "$D/$NAME" ] && [ "$(ls -A "$D")" = "$NAME" ]'
check "another run was faster: said so, no success message" 'grep -q "ERROR $D/$NAME appeared during the download (another run?)" <<< "$out" && ! grep -q "Downloaded and checked" <<< "$out" && [ ! -e "$SRV/started" ]'
fresh
run SHIM_SERVE=dirrace --
check "a folder appeared at the name during the download: nothing linked into it, no success message, exit code" '[ "$rc" -ne 0 ] && [ -d "$D/$NAME" ] && empty "$D/$NAME" && [ "$(ls -A "$D")" = "$NAME" ] && ! grep -q "Downloaded and checked" <<< "$out" && grep -q "^ERROR $D/$NAME appeared as something else during the download" <<< "$out" && [ ! -e "$SRV/started" ]'
fresh
mkdir -p "$T/noln"; printf '#!/bin/sh\nexit 1\n' > "$T/noln/ln"; chmod +x "$T/noln/ln"
keep="$FAKEPATH"; FAKEPATH="$T/noln:$FAKEPATH"
run --
FAKEPATH="$keep"
check "a file system without hard links (ln fails): the installer is still put in place" '[ "$rc" -eq 0 ] && same "$D/$NAME" "$SRV/fake.sh" && [ -x "$D/$NAME" ] && [ "$(ls -A "$D")" = "$NAME" ]'

# 6. Broken downloads: nothing written, a clear error, exit code not 0
for mode in html cut syntax noshebang nomarker1 nomarker2 nolast original fail; do
  if [ "$mode" = syntax ] && ! bash -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]'; then
    echo "SKIP: a syntax error in the download (the bash on PATH is older than 4 and does not check it)"
    continue
  fi
  fresh
  run SHIM_SERVE=$mode --
  check "download $mode: nothing written, error, exit code" '[ "$rc" -ne 0 ] && empty "$D" && [ ! -e "$SRV/started" ] && grep -q "^ERROR " <<< "$out" && grep -q "Check the network, DNS and the proxy" <<< "$out" && grep -qF "https_proxy=http://PROXY:PORT $LINE | https_proxy=http://PROXY:PORT bash" <<< "$out"'
done
check "failed curl: its message is shown, the proxy hint with curl" 'grep -qx "  curl: (6) Could not resolve host: raw.githubusercontent.com" <<< "$out" && grep -qx "  Check the network, DNS and the proxy. Behind a proxy, give it to curl and to bash:" <<< "$out"'
fresh
run SHIM_SERVE=html --
check "HTML page: named as not a complete installer" 'grep -q "ERROR The download is not a complete installer" <<< "$out"'

# 6b. wget alone fails: the hint is the wget line, not a curl line the host does not have
fresh
cp "$T/bin/wget" "$T/minbin/wget"
out="$(cd "$D" && notty env PATH="$T/minbin" SHIM_SERVE=fail "$SH" "$INSTALL" < /dev/null 2>&1)"; rc=$?
scan
rm -f "$T/minbin/wget"
check "wget fails: its message shown, the hint with wget (and no curl) for the proxy" '[ "$rc" -ne 0 ] && empty "$D" && grep -qx "  wget: unable to resolve host address .raw.githubusercontent.com." <<< "$out" && grep -qx "  Check the network, DNS and the proxy. Behind a proxy, give it to wget and to bash:" <<< "$out" && grep -qxF "  https_proxy=http://PROXY:PORT wget -nv -O- https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/install.sh | https_proxy=http://PROXY:PORT bash" <<< "$out" && ! grep -qi curl <<< "$out"'

# 7. The real installer passes the checks; with the bash 3.2 of macOS without the syntax check
fresh
run SHIM_SERVE=real --
check "real installer: accepted, the same bytes" '[ "$rc" -eq 0 ] && same "$D/$NAME" "$REAL"'
fresh
out="$(cd "$D" && notty env PATH="$T/oldbash:$FAKEPATH" SHIM_SERVE=real "$SH" "$INSTALL" < /dev/null 2>&1)"; rc=$?
scan
check "bash older than 4 on PATH: real installer accepted without bash -n" '[ "$rc" -eq 0 ] && same "$D/$NAME" "$REAL"'
fresh
out="$(cd "$D" && notty env PATH="$T/oldbash:$FAKEPATH" SHIM_SERVE=cut "$SH" "$INSTALL" < /dev/null 2>&1)"; rc=$?
scan
check "bash older than 4 on PATH: a cut download is still refused" '[ "$rc" -ne 0 ] && empty "$D"'

# 8. RN1_DIR: created when missing, relative to the current folder
fresh
run RN1_DIR="$D/a/b c" -- x
check "RN1_DIR: created, the installer there, the folder named" 'same "$D/a/b c/$NAME" "$SRV/fake.sh" && grep -qx "Folder: $D/a/b c (new)" <<< "$out" && grep -qx "  cd '\''$D/a/b c'\'' && ./$NAME x" <<< "$out"'
fresh
run RN1_DIR=rel --
check "RN1_DIR relative: under the current folder" '[ "$rc" -eq 0 ] && [ -f "$D/rel/$NAME" ] && grep -qx "Folder: $D/rel (new)" <<< "$out"'
fresh
mkdir -p "$D/cdp/rel"
run CDPATH="$D/cdp" RN1_DIR=rel --
check "CDPATH set: RN1_DIR=rel is below the current folder, not the one CDPATH leads to" 'grep -qx "Folder: $D/rel (new)" <<< "$out" && [ -f "$D/rel/$NAME" ] && [ ! -e "$D/cdp/rel/$NAME" ]'
fresh
: > "$D/file"
run RN1_DIR="$D/file/x" --
check "RN1_DIR not usable: error, nothing written" '[ "$rc" -ne 0 ] && grep -q "ERROR Cannot use the folder $D/file/x" <<< "$out" && [ ! -e "$SRV/urls" ]'

# 8a. A folder this run created is removed again when nothing was installed into it (an empty one only)
fresh
run SHIM_SERVE=fail RN1_DIR="$D/new" --
check "failed download, RN1_DIR created by this run: removed again" '[ "$rc" -ne 0 ] && [ ! -e "$D/new" ] && empty "$D" && ! grep -qi "rmdir" <<< "$out"'
fresh
run SHIM_SERVE=fail RN1_DIR="$D/p/q" --
check "failed download, RN1_DIR below a missing folder: the folder it made is removed, the one above stays" '[ "$rc" -ne 0 ] && [ ! -e "$D/p/q" ] && [ -d "$D/p" ]'
fresh
mkdir "$D/mine"
run SHIM_SERVE=fail RN1_DIR="$D/mine" --
check "failed download, RN1_DIR was there before: stays" '[ "$rc" -ne 0 ] && [ -d "$D/mine" ] && empty "$D/mine"'
fresh
run SHIM_SERVE=stray RN1_DIR="$D/new" --
check "failed download, something in the new folder: the folder stays with it, no error text" '[ "$rc" -ne 0 ] && [ -e "$D/new/stray" ] && ! grep -qi "rmdir\|not empty" <<< "$out"'
fresh
out="$(cd "$D" && notty env PATH="$T/minbin" RN1_DIR="$D/new" "$SH" "$INSTALL" < /dev/null 2>&1)"; rc=$?
scan
check "neither curl nor wget, RN1_DIR created by this run: removed again" '[ "$rc" -ne 0 ] && [ ! -e "$D/new" ] && grep -q "Neither curl nor wget is installed" <<< "$out"'
fresh
run RN1_DIR="$D/new" RN1_INSTALLER_URL=http://example.invalid/$NAME --
check "http address, RN1_DIR created by this run: removed again" '[ "$rc" -ne 0 ] && [ ! -e "$D/new" ]'
fresh
: > "$D/blocker"
run RN1_DIR="$D/blocker/x" --
check "RN1_DIR that cannot be made: nothing created, nothing removed" '[ "$rc" -ne 0 ] && [ -f "$D/blocker" ] && [ "$(ls -A "$D")" = "blocker" ]'

# 8b. The start line is safe to copy and paste: a quote, a space, $(...) in the folder name or an argument
fresh
weird="$D/it's a \$(touch PWNED) \"dir\""
run RN1_DIR="$weird" -- 'a b' "it's" '$(touch PWNED2)' ';' '`id`' '*' '' x
line="$(sed -n 's/^  \(cd .*\)$/\1/p' <<< "$out")"
mkdir "$T/elsewhere"
( cd "$T/elsewhere" && "$SH" -c "$line" > "$T/elsewhere.out" 2>&1 )
printf 'ARG<%s>\n' 'a b' "it's" '$(touch PWNED2)' ';' '`id`' '*' '' x > "$T/args.want"
check "start line with a quote, spaces and \$(...) in the folder and the arguments: run as printed, it starts the installer with the same arguments" '[ -d "$weird" ] && [ -n "$line" ] && [ "$(wc -l <<< "$line")" -eq 1 ] && cmp -s "$SRV/args" "$T/args.want" && [ -z "$(find "$T" -name "PWNED*" 2>/dev/null)" ] && ! grep -qi "unterminated\|syntax error\|not found" "$T/elsewhere.out"'

# 9. wget where curl is missing; HTTPS_PROXY reaches wget as https_proxy; https only; neither tool
fresh
cp "$T/bin/wget" "$T/minbin/wget"
out="$(cd "$D" && notty env PATH="$T/minbin" HTTPS_PROXY=http://proxy.invalid:3128 "$SH" "$INSTALL" < /dev/null 2>&1)"; rc=$?
scan
check "wget without curl: downloaded, HTTPS_PROXY given to wget as https_proxy" '[ "$rc" -eq 0 ] && same "$D/$NAME" "$SRV/fake.sh" && grep -qx "wget https_proxy=http://proxy.invalid:3128" "$SRV/env"'
rm -f "$T/minbin/wget"
fresh
out="$(cd "$D" && notty env PATH="$T/minbin" "$SH" "$INSTALL" < /dev/null 2>&1)"; rc=$?
scan
check "neither curl nor wget: error, nothing written" '[ "$rc" -ne 0 ] && empty "$D" && grep -q "Neither curl nor wget is installed" <<< "$out"'
fresh
run RN1_INSTALLER_URL=http://example.invalid/$NAME --
check "http address: refused, nothing downloaded" '[ "$rc" -ne 0 ] && empty "$D" && [ ! -e "$SRV/urls" ] && grep -q "ERROR Not an https address" <<< "$out"'
fresh
run RN1_INSTALLER_URL=https://example.invalid/branch/$NAME --
check "RN1_INSTALLER_URL: that address is downloaded" '[ "$rc" -eq 0 ] && [ "$(cat "$SRV/urls")" = "https://example.invalid/branch/$NAME" ]'

# 10. The real curl and wget take the options (an address nobody answers: an error, nothing written)
for tool in curl wget; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: the real $tool (not installed)"
    continue
  fi
  fresh
  rm -f "$T/minbin/curl" "$T/minbin/wget"; ln -s "$(command -v "$tool")" "$T/minbin/$tool"
  out="$(cd "$D" && notty env PATH="$T/minbin" RN1_INSTALLER_URL="https://localhost:9/$NAME" "$SH" "$INSTALL" < /dev/null 2>&1)"; rc=$?
scan
  check "real $tool: no answer - error, nothing written, no unknown option" '[ "$rc" -ne 0 ] && empty "$D" && grep -q "ERROR The installer could not be downloaded" <<< "$out" && ! grep -qiE "unknown option|unrecognized option|invalid option|is unknown" <<< "$out"'
  if [ "$tool" = curl ]; then
    check "real curl: connection refused (curl: (7)), not an option error" 'grep -q "curl: (7)" <<< "$out"'
  fi
  rm -f "$T/minbin/$tool"
done

# 11. Stopped while downloading: no temporary file left
fresh
( cd "$D" && SHIM_SERVE=slow PATH="$FAKEPATH" exec "$SH" "$INSTALL" < /dev/null > "$T/slow.out" 2>&1 ) &
pid=$!
i=0
while [ ! -e "$SRV/slow-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$pid" 2>/dev/null
wait "$pid"; rc=$?
check "TERM during the download: no temporary file, no installer, exit code" '[ -e "$SRV/slow-started" ] && [ "$rc" -ne 0 ] && empty "$D"'
fresh
( cd "$D" && SHIM_SERVE=slow RN1_DIR="$D/new" PATH="$FAKEPATH" exec "$SH" "$INSTALL" < /dev/null > "$T/slow.out" 2>&1 ) &
pid=$!
i=0
while [ ! -e "$SRV/slow-started" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
kill -TERM "$pid" 2>/dev/null
wait "$pid"; rc=$?
check "TERM during the download into a new RN1_DIR: the folder is removed too" '[ -e "$SRV/slow-started" ] && [ "$rc" -ne 0 ] && empty "$D"'

# 12. A cut install.sh runs nothing: every whole line, every byte of the last two lines, the first half
fresh
lines=$(( $(wc -l < "$INSTALL") ))
bytes=$(( $(wc -c < "$INSTALL") ))
tail2=$(( $(tail -n 2 "$INSTALL" | wc -c) ))
ran=""
n=1
while [ "$n" -lt "$lines" ]; do
  o="$(cd "$D" && head -n "$n" "$INSTALL" | PATH="$FAKEPATH" "$SH" -s -- x 2>&1)"
  if grep -q "Folder:" <<< "$o"; then ran="$ran lines:$n"; fi
  n=$((n + 1))
done
# (without only its last newline the script is whole)
n=$((bytes - tail2))
while [ "$n" -lt $((bytes - 1)) ]; do
  o="$(cd "$D" && head -c "$n" "$INSTALL" | PATH="$FAKEPATH" "$SH" -s -- x 2>&1)"
  if grep -q "Folder:" <<< "$o"; then ran="$ran bytes:$n"; fi
  n=$((n + 1))
done
o="$(cd "$D" && head -c $((bytes / 2)) "$INSTALL" | PATH="$FAKEPATH" "$SH" 2>&1)"
check "cut install.sh: nothing ran, nothing downloaded, nothing written ($((lines - 1)) line and $((tail2 - 1)) byte cuts, the first half)" '[ -z "$ran" ] && ! grep -q "Folder:" <<< "$o" && [ ! -e "$SRV/urls" ] && empty "$D"'
o="$(cd "$D" && PATH="$FAKEPATH" "$SH" -s -- x < "$INSTALL" 2>&1)"
check "the whole install.sh through stdin runs (the cuts above are not refused for another reason)" 'grep -qx "Folder: $D" <<< "$o"'

# 13. In a terminal: started with the keyboard; curl | bash gets the keyboard from /dev/tty
PTY=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import os; os.forkpty' 2>/dev/null; then
  PTY=python3
elif script --version 2>/dev/null | grep -q util-linux; then
  PTY=script
fi
case "${RN1_TEST_PTY:-}" in script|python3|none) PTY="${RN1_TEST_PTY#none}" ;; esac
cat > "$T/pty.py" <<'EOF'
import os, select, signal, sys, time
pid, fd = os.forkpty()
if pid == 0:
    os.execv("/bin/sh", ["/bin/sh", "-c", sys.argv[1]])
os.write(fd, sys.argv[2].encode() + b"\n")
out, status, deadline = b"", None, time.time() + 60
while time.time() < deadline:
    if select.select([fd], [], [], 0.2)[0]:
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if data:
            out += data
            continue
        break
    if status is not None:
        break
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
else:
    os.kill(pid, signal.SIGKILL)
    out += b"\n[pty: timeout]\n"
if status is None:
    status = os.waitpid(pid, 0)[1]
sys.stdout.write(out.decode("utf-8", "replace").replace("\r", ""))
sys.exit(os.WEXITSTATUS(status) if os.WIFEXITED(status) else 1)
EOF
# in_pty COMMAND TYPED: COMMAND in a new terminal, the line TYPED typed into it
in_pty() {
  if [ "$PTY" = python3 ]; then
    python3 "$T/pty.py" "$1" "$2"
  else
    { printf '%s\n' "$2"; sleep 4; } | TERM=dumb script -qfec "$1" /dev/null 2>&1 | tr -d '\r'
  fi
}
if [ -z "$PTY" ]; then
  echo "SKIP: the tests in a terminal (neither python3 nor script(1) of util-linux)"
else
  echo "terminal tests with $PTY"
  fresh
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH' FAKE_READ=1 '$SH' '$INSTALL' a 'b c'" "typed-1")"
  check "install.sh in a terminal: started with the arguments and the keyboard" 'grep -q "FAKE-INSTALLER name=$NAME args=\[a b c\] tty=yes dir=$D setting=fake-default" <<< "$out" && grep -q "READ=\[typed-1\]" <<< "$out"'
  fresh
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH' FAKE_READ=1; export PATH FAKE_READ; $LINE | '$SH'" "typed-2")"
  check "curl | shell: downloaded and started with the keyboard of the terminal (/dev/tty)" 'same "$D/$NAME" "$SRV/fake.sh" && grep -q "FAKE-INSTALLER name=$NAME args=\[\] tty=yes" <<< "$out" && grep -q "READ=\[typed-2\]" <<< "$out" && [ "$(grep -c "install.sh$" "$SRV/urls")" -eq 1 ]'
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH' FAKE_READ=1; export PATH FAKE_READ; $LINE | '$SH' -s -- self-update --no-menu" "typed-3")"
  check "curl | shell -s -- ARGS again: the installer kept, started with the arguments" 'same "$D/$NAME" "$SRV/fake.sh" && grep -q "The installer is already here: $D/$NAME" <<< "$out" && grep -q "args=\[self-update --no-menu\] tty=yes" <<< "$out" && grep -q "READ=\[typed-3\]" <<< "$out" && [ "$(grep -c "$NAME$" "$SRV/urls")" -eq 1 ]'
  fresh
  cp "$SRV/fake.sh" "$D/catalog.sh"; chmod +x "$D/catalog.sh"
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH'; export PATH; $LINE | '$SH'" "")"
  check "curl | shell with catalog.sh: catalog.sh started, nothing else downloaded" 'grep -q "FAKE-INSTALLER name=catalog.sh args=\[\] tty=yes" <<< "$out" && [ ! -e "$D/$NAME" ] && [ "$(grep -c "$NAME$" "$SRV/urls")" -eq 0 ]'
  fresh
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH'; export PATH; https_proxy=http://proxy.invalid:3128 $LINE | https_proxy=http://proxy.invalid:3128 RN1_DIR=sub '$SH'" "")"
  check "the proxy line of the README: both curl calls have the proxy; RN1_DIR in front of bash" 'grep -q "FAKE-INSTALLER name=$NAME args=\[\] tty=yes dir=$D/sub " <<< "$out" && [ "$(grep -c "^curl https_proxy=http://proxy.invalid:3128$" "$SRV/env")" -eq 2 ]'
  fresh
  cp "$SRV/fake.sh" "$D/$NAME"; chmod 775 "$D/$NAME"; chmod g+w "$D/$NAME"
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH'; export PATH; $LINE | '$SH'" "")"
  check "curl | shell with a group-writable installer: started" 'grep -q "FAKE-INSTALLER name=$NAME args=\[\] tty=yes" <<< "$out"'
  fresh
  cp "$SRV/fake.sh" "$D/$NAME"; chmod 777 "$D/$NAME"
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH'; export PATH; $LINE | '$SH'" "")"
  check "curl | shell with an installer everybody can write to: in a terminal too not started, the reason shown" '! grep -q "FAKE-INSTALLER" <<< "$out" && [ ! -e "$SRV/started" ] && grep -q "ERROR $D/$NAME was not started: everybody can write to it" <<< "$out"'
  fresh
  cp "$SRV/fake.sh" "$D/$NAME"; chmod 644 "$D/$NAME"
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH'; export PATH; $LINE | '$SH' -s -- a" "")"
  check "curl | shell with an installer without the x bit: started with bash and its arguments" 'grep -q "FAKE-INSTALLER name=$NAME args=\[a\] tty=yes" <<< "$out"'
  out="$(cd "$D" && in_pty "PATH='$FAKEPATH' '$SH' '$INSTALL' b" "")"
  check "install.sh in a terminal with an installer without the x bit: started with bash" 'grep -q "FAKE-INSTALLER name=$NAME args=\[b\] tty=yes" <<< "$out"'
  # The sudo lines of the README, with a sudo that resets the environment (env_reset, secure_path): of everything
  # the caller set, only the VAR=VALUE words after sudo reach the command (and the plumbing of these tests)
  mkdir -p "$T/sudobin" "$T/securebin"
  cp "$T/bin/curl" "$T/bin/wget" "$T/securebin/"
  # (secure_path of sudoers: the PATH of the caller is gone; the fakes of these tests are on the one that is left)
  cat > "$T/sudobin/sudo" <<EOF
#!/bin/sh
vars=""
while [ \$# -gt 0 ]; do
  case "\$1" in *=*) vars="\$vars \$1"; shift ;; *) break ;; esac
done
exec env -i PATH="$T/securebin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" HOME="\${HOME:-/}" TERM="\${TERM:-dumb}" SRV="\$SRV" INSTALL="\$INSTALL" \$vars "\$@"
EOF
  chmod +x "$T/sudobin/sudo"
  README="$(dirname "$INSTALL")/README.md"
  fresh
  cmd="$(grep -m1 '^curl .* | sudo RN1_DIR=[^ ]* bash$' "$README" | sed "s|RN1_DIR=/opt/rn1-technology-catalog|RN1_DIR=$D/viasudo|; s| bash\$| '$SH'|")"
  out="$(cd "$D" && in_pty "PATH='$T/sudobin:$FAKEPATH'; export PATH; $cmd" "")"
  check "README, sudo line: RN1_DIR after sudo reaches the installer through a sudo that resets the environment" '[ -n "$cmd" ] && grep -q "FAKE-INSTALLER name=$NAME args=\[\] tty=yes dir=$D/viasudo " <<< "$out"'
  fresh
  cmd="$(grep -m1 '^https_proxy=[^ ]* curl .* | sudo https_proxy=[^ ]* RN1_DIR=[^ ]* bash$' "$README" | sed "s|http://proxy.example.com:8080|http://proxy.invalid:3128|g; s|RN1_DIR=/opt/rn1-technology-catalog|RN1_DIR=$D/viasudo|; s| bash\$| '$SH'|")"
  out="$(cd "$D" && in_pty "PATH='$T/sudobin:$FAKEPATH'; export PATH; $cmd" "")"
  check "README, sudo line with a proxy: both curl calls (the user's and the one under sudo) have the proxy, RN1_DIR arrives" '[ -n "$cmd" ] && grep -q "dir=$D/viasudo " <<< "$out" && [ "$(grep -c "^curl https_proxy=http://proxy.invalid:3128$" "$SRV/env")" -eq 2 ]'
  fresh
  out="$(cd "$D" && in_pty "PATH='$T/sudobin:$FAKEPATH'; export PATH; RN1_DIR='$D/lost' https_proxy=http://proxy.invalid:3128 $LINE | RN1_DIR='$D/lost' https_proxy=http://proxy.invalid:3128 sudo '$SH'" "")"
  # (the sudo above starts with an empty environment, so the folder is found without PWD: on macOS /var is a link to /private/var)
  check "variables in front of sudo are lost (what the README warns about): the folder is the current one, no proxy" '{ grep -qF "dir=$D " <<< "$out" || grep -qF "dir=$(cd "$D" && pwd -P) " <<< "$out"; } && [ ! -e "$D/lost" ] && [ "$(grep -c "^curl https_proxy=http://proxy.invalid:3128$" "$SRV/env")" -eq 1 ]'
  # the real installer (on Linux: on macOS its start check may ask for Homebrew first; it needs bash 4.2 or newer)
  if [ "$(uname -s)" != Linux ]; then
    :
  elif ! bash -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }'; then
    echo "SKIP: the real installer in a terminal (the bash on PATH is older than 4.2)"
  else
    fresh
    out="$(cd "$D" && in_pty "PATH='$FAKEPATH' SHIM_SERVE=real; export PATH SHIM_SERVE; $LINE | '$SH' -s -- help" "")"
    check "curl | shell -s -- help with the real installer: downloaded, it runs" 'same "$D/$NAME" "$REAL" && grep -q "^Usage: ./$NAME \[command\]" <<< "$out"'
  fi
fi

}

# the shells install.sh runs under: bash, and dash (what "sh" is on Debian and Ubuntu: curl ... | sh)
echo "bash $("$BASHSH" -c 'echo $BASH_VERSION') runs install.sh"
TAG=""; SH="$BASHSH"
suite
if command -v dash >/dev/null 2>&1; then
  echo "dash runs install.sh"
  TAG="[dash] "; SH="$(command -v dash)"
  suite
else
  echo "SKIP: install.sh under dash (not installed)"
fi

# Every installer the history ever had (all branches: catalog.sh and rn1-technology-catalog-installer.sh) is whole for
# the check of install.sh, the original generator script is not (where the history is there: a CI checkout is shallow)
TAG=""; SH="$BASHSH"
ROOT="$(dirname "$INSTALL")"
gitq() { git -c 'safe.directory=*' -C "$ROOT" "$@"; }
if [ "$(gitq rev-list --all 2>/dev/null | wc -l)" -lt 2 ]; then
  echo "SKIP: the installers of the history (no git history here)"
else
  blobs="$(gitq log --all --format=%H -- catalog.sh rn1-technology-catalog-installer.sh 2>/dev/null | while read -r c; do
    for f in catalog.sh rn1-technology-catalog-installer.sh; do gitq rev-parse -q --verify "$c:$f" 2>/dev/null; done
  done | sort -u)"
  sed -n '/^rn1_complete()/,/^}/p' "$INSTALL" > "$T/complete.sh"
  bad=""; n=0
  for b in $blobs; do
    gitq cat-file blob "$b" > "$T/blob.sh"
    if ! "$SH" -c '. "$1"; rn1_complete "$2"' sh "$T/complete.sh" "$T/blob.sh"; then bad="$bad $b"; fi
    n=$((n + 1))
  done
  check "the $n installers of the history: all whole for the check of install.sh" '[ "$n" -ge 2 ] && [ -z "$bad" ]'
  check "the original generator script (tests/original.sh): not an installer" '! "$SH" -c '"'"'. "$1"; rn1_complete "$2"'"'"' sh "$T/complete.sh" "$ROOT/tests/original.sh"'
fi

echo "$CLEAN runs without shell error text in the output"
echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
