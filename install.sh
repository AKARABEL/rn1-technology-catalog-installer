#!/usr/bin/env bash
# Puts the RN1 Technology Catalog Installer into this folder (RN1_DIR: another one) and starts it; an installer already there is kept.

rn1_say() { printf '%s\n' "$*"; }
rn1_err() { printf 'ERROR %s\n' "$*" >&2; }

# FILE is a whole installer: bash in the first line, the settings section, main in the last line (blank lines after
# it do not count), no syntax error
rn1_complete() {
  [ -s "$1" ] && [ "$(head -n 1 "$1" 2>/dev/null)" = "#!/usr/bin/env bash" ] || return 1
  grep -q '^# CONFIGURE ONLY THIS SECTION' "$1" 2>/dev/null && grep -q '^# DO NOT CHANGE ANYTHING BELOW' "$1" 2>/dev/null || return 1
  [ "$(sed -n -e '/[^[:space:]]/h' -e '${x;p;}' "$1" 2>/dev/null)" = 'main "$@"; exit $?' ] || return 1
  # the bash 3.2 of macOS cannot read all of it; the installer moves on to a newer bash by itself
  if bash -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then
    bash -n "$1" 2>/dev/null || return 1
  fi
  return 0
}

# The permissions of FILE (a link is followed) as ls writes them, like -rw-r--r--; empty when ls cannot tell
rn1_mode() {
  ls -ldL -- "$1" 2>/dev/null | { read -r m _; printf '%s' "$m"; }
}

# The owner of FILE as a user number; a link is not followed unless the second argument is "follow"
rn1_uid() {
  local opt="-ldn"
  if [ "${2:-}" = follow ]; then opt="-ldnL"; fi
  ls "$opt" -- "$1" 2>/dev/null | { read -r _ _ u _; printf '%s' "$u"; }
}

# UID is this user - or, when this runs as root through sudo, the user who started sudo (SUDO_UID): an installer
# saved by an earlier run without sudo is that user's, and it is theirs to start through sudo
rn1_isme() {
  local me
  [ -n "$1" ] || return 1
  me="$(id -u 2>/dev/null)"
  if [ "$1" = "$me" ]; then return 0; fi
  [ "$me" = 0 ] && [ -n "${SUDO_UID:-}" ] && [ "$1" = "$SUDO_UID" ]
}

# Says why FILE must not be started by this run (and returns 0), or returns 1: a file of another user or one that
# everybody can write to may be planted (/tmp), and this line may run as root. Not the group: a umask 002 makes it.
# What cannot be checked counts as not safe.
rn1_unsafe() {
  if [ -L "$1" ] && ! rn1_isme "$(rn1_uid "$1")"; then
    # (the owner of a link can point it somewhere else at any moment)
    echo "the link belongs to another user"
  elif [ ! -O "$1" ] && ! rn1_isme "$(rn1_uid "$1" follow)"; then
    echo "it belongs to another user"
  else
    case "$(rn1_mode "$1")" in
      '') echo "its permissions could not be read" ;;
      ????????w*) echo "everybody can write to it" ;;
      *) return 1 ;;
    esac
  fi
}

# True when anybody can create, rename and delete files in this folder: world-writable, no sticky bit
rn1_shared() {
  case "$(rn1_mode .)" in
    ????????w[!tT]*) return 0 ;;
  esac
  return 1
}

# FILE was changed more than a minute ago (a find without -mmin, or none, takes it to be old)
rn1_old() {
  local r
  r="$(find "$1" -prune -mmin +1 2>/dev/null)" || return 0
  [ -n "$r" ]
}

# What this run leaves behind when it stops before the installer is in place: its temporary file and the folder it
# made (rmdir takes an empty folder only, whatever else is in it stays)
rn1_cleanup() {
  if [ -n "${RN1_TMP:-}" ]; then rm -f "$RN1_TMP"; fi
  if [ -n "${RN1_MADE:-}" ]; then rmdir -- "$RN1_MADE" 2>/dev/null; fi
}

# Downloads URL into a temporary file in this folder and moves it to NAME only when it is a whole installer
rn1_download() {
  local url="$1" name="$2" tool out rc fetch
  case "$url" in
    https://*) ;;
    *) rn1_err "Not an https address: $url"; return 1 ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    tool=curl
  elif command -v wget >/dev/null 2>&1; then
    tool=wget
  else
    rn1_err "Neither curl nor wget is installed - install one of them first."
    return 1
  fi
  # wget reads only the lower-case name
  if [ -z "${https_proxy:-}" ] && [ -n "${HTTPS_PROXY:-}" ]; then
    https_proxy="$HTTPS_PROXY"
    export https_proxy
  fi
  if ! RN1_TMP="$(mktemp "./.$name.XXXXXX" 2>/dev/null)"; then
    rn1_err "Cannot write into $PWD."
    return 1
  fi
  rn1_say "Downloading $url"
  if [ "$tool" = curl ]; then
    out="$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 --speed-limit 1024 --speed-time 90 --retry 2 --retry-max-time 120 -o "$RN1_TMP" "$url" 2>&1)"
  else
    out="$(wget -nv -T 60 -t 3 -O "$RN1_TMP" "$url" 2>&1)"
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rn1_err "The installer could not be downloaded:"
    printf '%s\n' "$out" | sed 's/^/  /' >&2
  elif ! rn1_complete "$RN1_TMP"; then
    rn1_err "The download is not a complete installer (a page of a proxy, or a download that broke off)."
    rc=1
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$RN1_TMP"
    if [ "$tool" = curl ]; then fetch="curl -fsSL"; else fetch="wget -nv -O-"; fi
    rn1_say "  Check the network, DNS and the proxy. Behind a proxy, give it to $tool and to bash:" >&2
    rn1_say "  https_proxy=http://PROXY:PORT $fetch https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/install.sh | https_proxy=http://PROXY:PORT bash" >&2
    return 1
  fi
  if ! chmod 755 "$RN1_TMP"; then
    rm -f "$RN1_TMP"
    rn1_err "Cannot write $PWD/$name."
    return 1
  fi
  # Only what a failed download leaves (an empty file) makes room for the new file; a link never does. The new
  # file is then linked to its name: that fails when the name exists, where mv -f would replace the installer
  # a second run saved its settings in while this one was downloading.
  if [ -f "$name" ] && [ ! -L "$name" ] && [ ! -s "$name" ] && rn1_old "$name"; then
    rm -f "$name"
  fi
  if ln "$RN1_TMP" "$name" 2>/dev/null; then
    # (ln into a folder that appeared at the name links inside it and succeeds: the name must be the new file)
    if [ ! "$name" -ef "$RN1_TMP" ]; then
      if [ -d "$name" ] && [ "$name/${RN1_TMP##*/}" -ef "$RN1_TMP" ]; then rm -f "$name/${RN1_TMP##*/}"; fi
      rm -f "$RN1_TMP"
      rn1_err "$PWD/$name appeared as something else during the download (another run?) - it was left as it is."
      return 1
    fi
    rm -f "$RN1_TMP"
  elif [ -e "$name" ] || [ -L "$name" ]; then
    rm -f "$RN1_TMP"
    rn1_err "$PWD/$name appeared during the download (another run?) - it was left as it is."
    rn1_say "  Run this line again to start it." >&2
    return 1
  elif ! mv -f "$RN1_TMP" "$name"; then
    # (a file system without hard links: this is check, then move - the gap of mv -f is back there)
    rm -f "$RN1_TMP"
    rn1_err "Cannot write $PWD/$name."
    return 1
  fi
}

# WORD as one word for a shell: as it is when it has only plain characters, else in single quotes (a quote in it as '\'')
rn1_quote() {
  local rest="$1" out="" sq="'"
  case "$rest" in
    ''|*[!A-Za-z0-9_./+=:@%,-]*) ;;
    *) printf '%s' "$rest"; return 0 ;;
  esac
  while :; do
    case "$rest" in
      *"$sq"*) out="$out${rest%%"$sq"*}'\\''"; rest="${rest#*"$sq"}" ;;
      *) break ;;
    esac
  done
  printf "'%s%s'" "$out" "$rest"
}

# The command that starts FILE (in this folder) with the arguments, ready to be copied
rn1_start_line() {
  local f="$1" line a
  shift
  if [ -x "$f" ]; then line="./$f"; else line="bash $f"; fi
  line="cd $(rn1_quote "$PWD") && $line"
  for a in "$@"; do
    line="$line $(rn1_quote "$a")"
  done
  printf '%s\n' "$line"
}

rn1_install() {
  local name="rn1-technology-catalog-installer.sh" dir="${RN1_DIR:-.}" new="" file="" why bak=""
  local url="${RN1_INSTALLER_URL:-https://raw.githubusercontent.com/AKARABEL/rn1-technology-catalog-installer/main/rn1-technology-catalog-installer.sh}"
  if ! command -v bash >/dev/null 2>&1; then
    rn1_err "The installer needs bash - install it first."
    return 1
  fi
  [ -d "$dir" ] || new=" (new)"
  if ! mkdir -p -- "$dir" || ! CDPATH='' cd -- "$dir"; then
    rn1_err "Cannot use the folder $dir."
    return 1
  fi
  rn1_say "Folder: $PWD$new"
  if [ -n "$new" ]; then RN1_MADE="$PWD"; fi
  trap rn1_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  # Everything below checks a file and then uses it: where anybody can swap files in between, root is not safe
  # (a private folder is: RN1_DIR). Somebody else is warned only: WSL and VirtualBox folders look like this.
  if rn1_shared; then
    if [ "$(id -u 2>/dev/null)" = 0 ]; then
      rn1_err "$PWD can be written by everybody and has no sticky bit: another user could swap files in it while this runs as root."
      rn1_say "  Use a folder of its own: put RN1_DIR=/opt/rn1-technology-catalog in front of bash (after sudo, when you use it)." >&2
      return 1
    fi
    rn1_say "WARNING $PWD can be written by everybody and has no sticky bit: other users could swap files in it. A folder of its own is safer (RN1_DIR)." >&2
  fi
  if [ -d "$name" ]; then
    rn1_err "$PWD/$name is a folder - it was left as it is."
    return 1
  fi

  # catalog.sh: the name before the rename; the original generator script may have it too
  if [ -s "$name" ]; then
    file="$name"
  elif rn1_complete catalog.sh; then
    file="catalog.sh"
  fi
  if [ "$file" = "$name" ] && [ ! -r "$name" ]; then
    rn1_err "$PWD/$name cannot be read by this user - it was left as it is."
    rn1_say "  Run this line as the user it belongs to (for example with sudo)." >&2
    return 1
  fi
  if [ "$file" = "$name" ] && ! rn1_complete "$name"; then
    rn1_err "$PWD/$name is not a complete installer (an update or a download that broke off?) - it was left as it is."
    # (an update that broke off leaves the file cut and the version before it, with the settings, next to it)
    for why in "$name".bak-*; do
      if [ -f "$why" ] && rn1_complete "$why"; then
        bak="$why"
      fi
    done
    if [ -n "$bak" ]; then
      rn1_say "  An update that broke off leaves the file cut. The version before it, with your settings, is kept:" >&2
      rn1_say "  cp -p $(rn1_quote "$PWD/$bak") $(rn1_quote "$PWD/$name")" >&2
      rn1_say "  Run that, then run this line again." >&2
    else
      rn1_say "  If you changed settings in it, keep it: mv $name $name.cut" >&2
      rn1_say "  Run this line again for a new installer, then copy your settings over from the .cut file." >&2
    fi
    return 1
  fi
  if [ -n "$file" ]; then
    if why="$(rn1_unsafe "$file")"; then
      rn1_err "$PWD/$file was not started: $why."
      rn1_say "  Look at it first. If it is yours, start it with:" >&2
      rn1_say "  $(rn1_start_line "$file" "$@")" >&2
      return 1
    fi
    rn1_say "The installer is already here: $PWD/$file (its settings are kept). Updates: option 22."
  else
    if [ -L "$name" ]; then
      rn1_err "$PWD/$name is a link that leads to no installer (nowhere, an empty file, or a place this user cannot read) - it was left as it is."
      rn1_say "  Remove it, then run this line again." >&2
      return 1
    fi
    if [ -f "$name" ]; then
      # (the installer saves its settings by truncating its file and writing it again: an empty file that is
      # new may be that, in another run)
      if ! rn1_old "$name"; then
        rn1_err "$PWD/$name is empty and was changed a moment ago - another run may be writing it."
        rn1_say "  Run this line again in a minute." >&2
        return 1
      fi
      rn1_say "The empty $name here (a download that failed) is replaced."
    fi
    rn1_download "$url" "$name" || return 1
    file="$name"
    rn1_say "Downloaded and checked: $PWD/$name"
  fi

  if [ -t 0 ]; then
    exec bash "./$file" "$@"
  fi
  # curl | bash: this script came through stdin, the keyboard is the terminal
  if (: < /dev/tty) 2>/dev/null; then
    exec bash "./$file" "$@" < /dev/tty
  fi
  # arguments are commands somebody wants run (cloud-init, a script): ending with 0 would look like they were
  if [ $# -gt 0 ]; then
    rn1_err "There is no terminal here, so the installer was not started with these arguments. It is in place."
    rn1_say "  Start it from a terminal:" >&2
    rn1_say "  $(rn1_start_line "$file" "$@")" >&2
    return 1
  fi
  rn1_say "There is no terminal for the menu here, so the installer was not started. Start it with:"
  rn1_say "  $(rn1_start_line "$file")"
}

# in braces: a download of this script that breaks off anywhere runs nothing
{ rn1_install "$@"; }
