#!/usr/bin/env bash
# Orchestration host: bash ops/deploy-cluster.sh /etc/bigtop-deploy/site.env STAGE
set -euo pipefail
config=$(realpath "${1:?provide trusted site.env}")
stage=${2:?choose preflight, packages, management, data or all}
source "$config"
here=$(cd "$(dirname "$0")/.." && pwd)
case $stage in preflight|packages|management|data|all) ;; *) exit 64 ;; esac
[[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*$ && $KIT_ROOT =~ ^/[-a-zA-Z0-9_./]+$ ]]
[[ $MANIFEST_SHA256 =~ ^[[:xdigit:]]{64}$ ]]
python3 "$here/production/render.py" --inventory "$INVENTORY" --site "$DATA_SITE" --out "$SNAPSHOT"
mapfile -t hosts < <(python3 - "$SNAPSHOT/plan.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    plan = json.load(f)
for slot in sorted(plan):
    print(plan[slot]["fqdn"])
PY
)
[[ ${#hosts[@]} == 10 && ${hosts[8]} == "$AMBARI_FQDN" ]]
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)
remote() {
    local host=$1 command
    shift
    printf -v command '%q ' "$@"
    ssh "${ssh_opts[@]}" "$SSH_USER@$host" "sudo -n -- $command"
}
for i in "${!hosts[@]}"; do
    host=${hosts[i]}
    printf -v slot 'bd%02d' "$((i+1))"
    remote "$host" bash -s -- "$KIT_ROOT" "$MANIFEST_SHA256" "$host" "${hosts[@]}" <<'CHECK'
set -euo pipefail
cd "$1"
[[ $(hostname -f) == "$3" && $(uname -m) == x86_64 ]]
grep -Fq 'CentOS Linux release 7.9.2009' /etc/centos-release
printf '%s  SHA256SUMS\n' "$2" | sha256sum -c -
sha256sum --quiet -c SHA256SUMS
shift 3
for fqdn; do getent ahostsv4 "$fqdn" >/dev/null; done
CHECK
done
if [[ $stage == packages || $stage == all ]]; then
    for i in "${!hosts[@]}"; do
        printf -v slot 'bd%02d' "$((i+1))"
        remote "${hosts[i]}" bash "$KIT_ROOT/cluster/provision-node.sh" "$KIT_ROOT" "$slot"
    done
fi
if [[ $stage == management || $stage == all ]]; then
    remote "$AMBARI_FQDN" bash "$KIT_ROOT/ops/manage-server.sh" setup "$KIT_ROOT" "$PG_HOST" "$PG_PORT" "$PG_DATABASE" "$PG_USER" "$PG_PASSWORD_FILE" "$PG_CA"
    for host in "${hosts[@]}"; do
        remote "$host" bash "$KIT_ROOT/ops/manage-server.sh" agent "$AMBARI_FQDN"
    done
    remote "$AMBARI_FQDN" bash "$KIT_ROOT/ops/manage-server.sh" verify "$API_BASE" "$API_NETRC" "${hosts[@]}"
fi
if [[ $stage == data || $stage == all ]]; then
    export SSH_USER KIT_ROOT
    bash "$here/production/start-cluster.sh" --inventory "$INVENTORY" --site "$DATA_SITE" --snapshot "$SNAPSHOT" --action apply
fi
