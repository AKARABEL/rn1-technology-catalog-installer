#!/usr/bin/env bash
set -euo pipefail
if command -v dnf >/dev/null 2>&1; then
  dnf -y -q --setopt=strict=0 install findutils procps-ng util-linux tar gzip diffutils tzdata python3 jq \
    hostname iproute which ncurses sed gawk grep shadow-utils openssh-clients >/dev/null
elif command -v yum >/dev/null 2>&1; then
  # CentOS 7 is end of life: its packages are only in the vault
  sed -i -e 's/^mirrorlist=/#mirrorlist=/' -e 's|^#\{0,1\}baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|' /etc/yum.repos.d/CentOS-*.repo
  yum -y -q install findutils procps-ng util-linux tar gzip diffutils tzdata python3 hostname iproute which ncurses openssh-clients >/dev/null
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq procps tzdata python3 jq iproute2 ncurses-bin bsdutils util-linux openssh-client curl ca-certificates >/dev/null
elif command -v zypper >/dev/null 2>&1; then
  zypper -q -n install procps util-linux timezone python3 jq iproute2 tar gzip diffutils which hostname ncurses-utils \
    findutils shadow gawk openssh-clients >/dev/null
fi
id t >/dev/null 2>&1 || useradd -m t
rm -rf /home/t/r
cp -a /src /home/t/r
chown -R t: /home/t/r
echo "$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"'), bash $BASH_VERSION"
rc=0
for s in run_tests run_bundle_tests run_snapshot_tests run_upgrade_tests run_selfupdate_tests run_adopt_tests \
  run_jobs_tests run_timezone_tests run_wizard_tests run_distro_tests; do
  echo "::group::$s"
  if su -s /bin/bash t -c "cd /home/t/r && bash tests/$s.sh /home/t/r/rn1-technology-catalog-installer.sh" > "/tmp/$s.log" 2>&1; then
    cat "/tmp/$s.log"
    echo "::endgroup::"
    echo "$s: $(tail -n 1 "/tmp/$s.log")"
  else
    cat "/tmp/$s.log"
    echo "::endgroup::"
    echo "::error::$s failed: $(grep -c '^FAIL' "/tmp/$s.log") test(s)"
    grep '^FAIL' "/tmp/$s.log" || tail -n 20 "/tmp/$s.log"
    rc=1
  fi
done
exit "$rc"
