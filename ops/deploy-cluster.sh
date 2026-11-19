#!/usr/bin/env bash
# Orchestration host: bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env STAGE
set -euo pipefail
config=$(realpath "${1:?provide trusted site.env}")
stage=${2:?choose ambari, prepare, time-packages, preflight, packages, management, data or all}
source "$config"
here=$(cd "$(dirname "$0")/.." && pwd)
case $stage in ambari|prepare|time-packages|preflight|packages|management|data|all) ;; *) exit 64 ;; esac
[[ ${PREPARE_OS:-0} =~ ^[01]$ ]] || { echo "PREPARE_OS must be 0 or 1" >&2; exit 64; }
[[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*$ && $KIT_ROOT =~ ^/[-a-zA-Z0-9_./]+$ ]]
[[ $MANIFEST_SHA256 =~ ^[[:xdigit:]]{64}$ ]]
if [[ $stage == ambari ]]; then
    SNAPSHOT=$(mktemp -d)
    trap 'rm -rf -- "$SNAPSHOT"' EXIT
    address_file=()
    if [[ ${PREPARE_OS:-0} == 1 ]]; then address_file+=("${BOOTSTRAP_INVENTORY:?provide slot,address CSV}"); fi
    python3 "$here/ops/ambari-inventory.py" "$INVENTORY" "$SNAPSHOT" "${address_file[@]}"
else
    python3 "$here/production/render.py" --inventory "$INVENTORY" --site "$DATA_SITE" --out "$SNAPSHOT"
fi
targets=$(python3 - "$SNAPSHOT/plan.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    plan = json.load(f)
if sum("ambari-server" in node["roles"] for node in plan.values()) != 1:
    sys.exit("Inventory must contain exactly one ambari-server host")
for slot in sorted(plan):
    node = plan[slot]
    record = " ".join([node["fqdn"]] + node["roles"])
    sys.stdout.buffer.write((record + "\n").encode("ascii"))
PY
)
hosts=()
declare -A host_roles
while read -r host roles; do
    hosts+=("$host")
    host_roles[$host]=$roles
    if [[ " $roles " == *" ambari-server "* ]]; then
        [[ -z ${AMBARI_FQDN:-} || $AMBARI_FQDN == "$host" ]] || {
            echo "AMBARI_FQDN differs from the ambari-server inventory role" >&2; exit 64;
        }
        AMBARI_FQDN=$host
    fi
done <<< "$targets"
SSH_PORT=${SSH_PORT:-22}
SSH_IDENTITY_FILE=${SSH_IDENTITY_FILE:-}
SSH_KNOWN_HOSTS=${SSH_KNOWN_HOSTS:-}
[[ $SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || exit 64
ssh_opts=(-p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
if [[ -n $SSH_IDENTITY_FILE ]]; then
    test -r "$SSH_IDENTITY_FILE"
    ssh_opts+=(-o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE")
fi
if [[ -n $SSH_KNOWN_HOSTS ]]; then
    test -r "$SSH_KNOWN_HOSTS"
    ssh_opts+=(-o "UserKnownHostsFile=$SSH_KNOWN_HOSTS")
fi
remote() {
    local host=$1 command
    shift
    printf -v command '%q ' "$@"
    ssh "${ssh_opts[@]}" "$SSH_USER@$host" "sudo -n -- $command"
}
if [[ $stage == ambari && ${PREPARE_OS:-0} == 1 ]]; then
    while read -r ip; do
        remote "$ip" bash -s -- "$KIT_ROOT" "$MANIFEST_SHA256" <<'GUARD'
set -euo pipefail
cd "$1"
printf '%s  SHA256SUMS\n' "$2" | sha256sum -c -
awk '$2 == "./ops/ambari-bootstrap.sh" || $2 == "ops/ambari-bootstrap.sh"' SHA256SUMS | sha256sum -c -
exec bash "$1/ops/ambari-bootstrap.sh" inspect "$1"
GUARD
    done < "$SNAPSHOT/guard-addresses"
fi
if [[ $stage == prepare || ( ( $stage == all || $stage == ambari ) && ${PREPARE_OS:-0} == 1 ) ]]; then
    source "$here/ops/prepare-hosts.sh"
    prepare_hosts
fi
for host in "${hosts[@]}"; do
    remote "$host" bash -s -- "$KIT_ROOT" "$MANIFEST_SHA256" "$host" "${hosts[@]}" <<'CHECK'
set -euo pipefail
cd "$1"
[[ $(hostname -f) == "$3" && $(uname -m) == x86_64 ]]
grep -Fq 'CentOS Linux release 7.9.2009' /etc/centos-release
printf '%s  SHA256SUMS\n' "$2" | sha256sum -c -
sha256sum --quiet -c SHA256SUMS
shift 3
for fqdn; do getent ahosts "$fqdn" >/dev/null; done
CHECK
    if [[ $stage == ambari ]]; then remote "$host" bash "$KIT_ROOT/ops/ambari-bootstrap.sh" inspect "$KIT_ROOT"; fi
done
if [[ $stage == time-packages ]]; then
    for host in "${hosts[@]}"; do
        remote "$host" bash "$KIT_ROOT/cluster/provision-node.sh" "$KIT_ROOT" --chrony-only
    done
    exit 0
fi
read -r -a sources <<< "${NTP_SOURCES:?provide approved NTP addresses or names, separated by spaces}"
for host in "${hosts[@]}"; do
    mounts=${REQUIRED_MOUNTS:-/}
    roles=" ${host_roles[$host]} "
    if [[ $roles == *" datanode "* || $roles == *" nodemanager "* ]]; then
        mounts+=" ${WORKER_MOUNTS:-}"
    fi
    read -r -a paths <<< "$mounts"
    remote "$host" bash "$KIT_ROOT/ops/check-node.sh" --os "$KIT_ROOT" "${MIN_FREE_MIB:-0}" "${paths[@]}"
    remote "$host" bash "$KIT_ROOT/ops/check-node.sh" --time "${MAX_CLOCK_OFFSET_SECONDS:?provide the clock correction threshold}" "${sources[@]}"
done
if [[ $stage == packages || $stage == all ]]; then
    for host in "${hosts[@]}"; do
        # An inventory row with no daemons is a client/gateway.
        read -r -a roles <<< "${host_roles[$host]:-client}"
        remote "$host" bash "$KIT_ROOT/cluster/provision-node.sh" "$KIT_ROOT" "${roles[@]}"
    done
fi
if [[ $stage == ambari ]]; then
    for host in "${hosts[@]}"; do
        role=agent
        if [[ $host == "$AMBARI_FQDN" ]]; then role=server; fi
        remote "$host" bash "$KIT_ROOT/cluster/provision-node.sh" "$KIT_ROOT" --ambari-only "$role"
    done
fi
if [[ $stage == ambari ]]; then
    remote "$AMBARI_FQDN" python3 "$KIT_ROOT/ops/ambari-stack-el7.py"
fi
if [[ $stage == management || $stage == ambari || $stage == all ]]; then
    remote "$AMBARI_FQDN" bash "$KIT_ROOT/ops/manage-server.sh" setup "$KIT_ROOT" "$PG_HOST" "$PG_PORT" "$PG_DATABASE" "$PG_USER" "$PG_PASSWORD_FILE" "$PG_CA"
    for host in "${hosts[@]}"; do
        remote "$host" bash "$KIT_ROOT/ops/manage-server.sh" agent "$AMBARI_FQDN"
    done
    remote "$AMBARI_FQDN" bash "$KIT_ROOT/ops/manage-server.sh" verify "$API_BASE" "$API_NETRC" "${hosts[@]}"
fi
if [[ $stage == data || $stage == all ]]; then
    export SSH_USER SSH_PORT SSH_IDENTITY_FILE SSH_KNOWN_HOSTS KIT_ROOT
    bash "$here/production/start-cluster.sh" --inventory "$INVENTORY" --site "$DATA_SITE" --snapshot "$SNAPSHOT" --action apply
fi
