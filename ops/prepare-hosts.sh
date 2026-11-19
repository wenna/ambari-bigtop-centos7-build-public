#!/usr/bin/env bash
# Standalone entry and the implementation sourced by deploy-cluster.sh.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    exec bash "$(dirname "$0")/deploy-cluster.sh" "${1:?provide trusted site.env}" prepare
fi

prepare_hosts() {
    local mapping host ip mode
    local -a records ntp
    local -A addresses
    : "${BOOTSTRAP_INVENTORY:?provide slot,address CSV}"
    : "${NTP_SOURCES:?provide approved NTP sources}"
    : "${MAX_CLOCK_OFFSET_SECONDS:?provide clock correction threshold}"
    [[ ${SET_HOSTNAME:-0} =~ ^[01]$ && ${MANAGE_ETC_HOSTS:-0} =~ ^[01]$ ]] || return 64
    mapping=$(python3 - "$SNAPSHOT/plan.json" "$BOOTSTRAP_INVENTORY" <<'PY'
import csv, ipaddress, json, sys
with open(sys.argv[1]) as f:
    plan = json.load(f)
with open(sys.argv[2], newline="", encoding="utf-8-sig") as f:
    rows = csv.DictReader(f)
    if rows.fieldnames != ["slot", "address"]:
        sys.exit("Bootstrap inventory must have columns slot,address")
    found = {}
    for row in rows:
        slot = row["slot"]
        if None in row or slot in found or slot not in plan:
            sys.exit("Unknown, duplicate or malformed bootstrap slot: " + str(slot))
        ip = ipaddress.ip_address(row["address"])
        if ip.is_unspecified or ip.is_multicast or ip.is_loopback or ip.is_link_local or "%" in str(ip):
            sys.exit("Bootstrap address must be a routable unicast address")
        found[slot] = str(ip)
    if set(found) != set(plan) or len(set(found.values())) != len(found):
        sys.exit("Bootstrap addresses must cover every slot exactly once with distinct IPs")
for slot in sorted(found):
    sys.stdout.buffer.write(("%s %s\n" % (plan[slot]["fqdn"], found[slot])).encode("ascii"))
PY
)
    records=()
    while read -r host ip; do addresses[$host]=$ip; records+=("$ip $host"); done <<< "$mapping"
    read -r -a ntp <<< "$NTP_SOURCES"
    # Inspect every peer before the first change; repeat checks just before applying.
    for mode in inspect apply; do
        for host in "${hosts[@]}"; do
            ip=${addresses[$host]}
            remote "$ip" bash -s -- "$KIT_ROOT" "$MANIFEST_SHA256" "$mode" "$host" "$ip" \
                "${SET_HOSTNAME:-0}" "${MANAGE_ETC_HOSTS:-0}" "$MAX_CLOCK_OFFSET_SECONDS" \
                "${#ntp[@]}" "${ntp[@]}" "${records[@]}" <<'BOOTSTRAP'
set -euo pipefail
cd "$1"
printf '%s  SHA256SUMS\n' "$2" | sha256sum -c -
sha256sum --quiet -c SHA256SUMS
grep -Fxq 'CentOS Linux release 7.9.2009 (Core)' /etc/centos-release
[[ $(uname -m) == x86_64 ]]
kit=$1; shift 2
exec bash "$kit/ops/prepare-host-node.sh" "$kit" "$@"
BOOTSTRAP
        done
    done
}
