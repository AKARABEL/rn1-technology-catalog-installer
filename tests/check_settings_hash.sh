#!/usr/bin/env bash
# The settings check of a release: SETTINGS_PUBLISHED_SUM is the cksum of the settings section as published
# (the lines from '# CONFIGURE ONLY THIS SECTION' to '# DO NOT CHANGE ANYTHING BELOW'). By it a new download
# knows that its settings are the defaults and takes the values of an installation in its folder over by itself;
# a section changed without it would never count as a new download. Fails with the value to set.
set -u
I="${1:-rn1-technology-catalog-installer.sh}"
ann() { if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::%s::%s\n' "$1" "$2"; else printf '%s %s\n' "$(tr '[:lower:]' '[:upper:]' <<< "$1")" "$2"; fi; }
want="$(sed -n 's/^SETTINGS_PUBLISHED_SUM="\(.*\)"$/\1/p' "$I" | head -n 1)"
# (stderr apart: a warning of bash itself - a locale the server does not have, forwarded by ssh - is no part of the sum)
errs="$(mktemp)" || exit 1
if ! have="$(bash "$I" __settings_hash 2>"$errs")" || ! [[ "$have" =~ ^[0-9]+\ [0-9]+$ ]]; then
  ann error "The settings section of $I cannot be read: $have $(cat -- "$errs")"
  rm -f -- "$errs"
  exit 1
fi
rm -f -- "$errs"
if [ "$have" != "$want" ]; then
  n="$(basename -- "$I")"
  ann error "SETTINGS_PUBLISHED_SUM is \"$want\", the settings section has \"$have\" - set SETTINGS_PUBLISHED_SUM=\"$have\": sed -i \"s/^SETTINGS_PUBLISHED_SUM=.*/SETTINGS_PUBLISHED_SUM=\\\"\$(bash $n __settings_hash)\\\"/\" $n && cp $n catalog.sh"
  exit 1
fi
echo "SETTINGS_PUBLISHED_SUM \"$have\" is the cksum of the published settings section"
