#!/usr/bin/env bash
# The release check: the default CATALOG_VERSION of the installer exists on Docker Hub and is not behind the
# newest stable Catalog there, so the versions screen of a new installation selects what the settings already
# say. A newer Catalog without the stable tag is only a warning; Docker Hub not reachable: a warning, no failure.
set -u
I="${1:-rn1-technology-catalog-installer.sh}"
ann() { if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::%s::%s\n' "$1" "$2"; else printf '%s %s\n' "$(tr '[:lower:]' '[:upper:]' <<< "$1")" "$2"; fi; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n' "$1" "$2" | sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr | head -n 1)" = "$1" ]; }
have="$(sed -n 's/^CATALOG_VERSION="\(.*\)"$/\1/p' "$I" | head -n 1)"
if ! [[ "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  ann error "CATALOG_VERSION is \"$have\" - the default must be an exact version, the newest stable Catalog on Docker Hub"
  exit 1
fi
# the installer's own reading of Docker Hub: "NEWEST STABLE LISTED" (STABLE "-" when no version has the stable
# tag; LISTED "missing" when CATALOG_VERSION is not there for the Catalog and its worker)
if ! hub="$(bash "$I" __recommended_catalog 2>/dev/null)" || [ -z "$hub" ]; then
  ann warning "Docker Hub could not be read - CATALOG_VERSION $have was not compared with the newest stable Catalog"
  exit 0
fi
read -r newest stable listed <<< "$hub"
what="newest stable Catalog"
if [ "$stable" = "-" ]; then
  stable="$newest"
  what="newest Catalog (no stable tag)"
fi
if [ "$listed" != "listed" ]; then
  ann error "CATALOG_VERSION $have is not on Docker Hub for the Catalog and its worker - set the $what, $stable, before publishing"
  exit 1
fi
if newer "$stable" "$have"; then
  ann error "CATALOG_VERSION is $have but Docker Hub's $what is $stable - set the default before publishing"
  exit 1
fi
if newer "$newest" "$have"; then
  ann warning "Docker Hub has Catalog $newest, newer than CATALOG_VERSION $have but without the stable tag: the versions screen of a new installation selects it - set it as the default once it is stable"
fi
echo "CATALOG_VERSION $have: Docker Hub's $what is $stable, the versions screen of a new installation selects $newest"
