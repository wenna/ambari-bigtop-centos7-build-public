#!/usr/bin/env bash
# Installed root-owned on the target. Each file is approved by the site administrator.
set -euo pipefail
[[ $EUID == 0 && $# == 1 && $1 =~ ^[0-9a-f]{64}$ ]]
[[ ${SUDO_USER:-} =~ ^[a-z_][a-z0-9_-]*$ && $SUDO_USER != root ]]
cd "/etc/bigtop-access/$SUDO_USER/current"
printf '%s  %s\n' "$1" "$1" | /usr/bin/sha256sum --status -c -
exec /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash "$1" </dev/null
