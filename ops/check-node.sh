#!/usr/bin/env bash
# Run locally on each EL7 node with the site inventory as the first argument.
set -euo pipefail
: "${1:?usage: bash check-node.sh hosts.csv [required_mount_point ...]}"
inventory=$1
shift
test "$(uname -m)" = x86_64
grep -F 'CentOS Linux release 7.9.2009' /etc/centos-release
fqdn=$(hostname -f)
awk -F, -v h="$fqdn" 'NR > 1 && tolower($2) == tolower(h) {n++} END {exit n != 1}' "$inventory" || {
    echo "Local hostname does not match one inventory row: $fqdn" >&2
    exit 1
}
while IFS=, read -r slot host rack; do
    if [[ "$slot" == slot ]]; then continue; fi
    getent ahostsv4 "$host" >/dev/null || { echo "Name resolution failed: $host" >&2; exit 1; }
done < "$inventory"
for mount_dir in "$@"; do
    mountpoint -q -- "$mount_dir" || { echo "Missing mount: $mount_dir" >&2; exit 1; }
    df -hP -- "$mount_dir"
done
echo "Node identity, peer IPv4 lookup and specified mount points checked: $fqdn"
