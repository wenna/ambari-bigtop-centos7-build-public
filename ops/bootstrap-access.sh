#!/usr/bin/env bash
set -euo pipefail
umask 077
(( EUID > 0 )) || { echo "Use the non-root bootstrap operator" >&2; exit 64; }
site=$(realpath "${1:?site.env}")
source "$site"
source "${2:?access.env}"
mode=${3:-plan}
[[ $mode == plan || $mode == apply ]] || exit 64
[[ $BOOTSTRAP_USER =~ ^[a-z_][a-z0-9_-]*$ && $BOOTSTRAP_USER != root ]]
[[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*$ && $SSH_USER != root && $SSH_USER != "$BOOTSTRAP_USER" ]]
[[ ${AMBARI_ACCESS_MODE:-} == managed && ${SSH_PORT:-22} =~ ^[1-9][0-9]{0,4}$ ]]
: "${SSH_IDENTITY_FILE:?dedicated deployment private key path}" "${SSH_KNOWN_HOSTS:?verified host keys}"
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/actions"
bash "$here/deploy-cluster.sh" "$site" ambari --export-actions "$tmp/actions"
args=()
[[ ${PREPARE_OS:-0} == 0 ]] || args+=("$BOOTSTRAP_INVENTORY")
python3 "$here/ambari-inventory.py" "$INVENTORY" "$tmp" "${args[@]}"
python3 - "$tmp" <<'PY' > "$tmp/targets"
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
plan = json.loads((root / 'plan.json').read_text())
addresses = root / 'guard-addresses'
hosts = [plan[k]['fqdn'] for k in sorted(plan)]
for host, peer in zip(hosts, addresses.read_text().splitlines() if addresses.exists() else hosts):
    print(host, peer)
PY
if [[ $mode == plan ]]; then
  cat "$tmp/targets"
  echo "Inspect the approved actions with: bash ops/deploy-cluster.sh SITE ambari --export-actions EXISTING_DIRECTORY"
  exit
fi
[[ -r $BOOTSTRAP_IDENTITY_FILE && -s $SSH_KNOWN_HOSTS ]]
if [[ ! -e $SSH_IDENTITY_FILE ]]; then
  [[ ${GENERATE_DEPLOY_KEY:-0} == 1 && ! -e $SSH_IDENTITY_FILE.pub ]]
  mkdir -p "$(dirname "$SSH_IDENTITY_FILE")"
  ssh-keygen -q -t ed25519 -N '' -f "$SSH_IDENTITY_FILE"
fi
[[ -f $SSH_IDENTITY_FILE && -f $SSH_IDENTITY_FILE.pub ]]
ssh-keygen -lf "$SSH_IDENTITY_FILE.pub" >/dev/null
read -r keytype keyblob _ < "$SSH_IDENTITY_FILE.pub"
[[ $keytype =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$ && $keyblob =~ ^[A-Za-z0-9+/]+=*$ ]]
opts=(-p "${SSH_PORT:-22}" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
      -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" -o ConnectTimeout=10)
while read -r host peer; do
  dir="$tmp/actions/$host"
  if [[ $host != "$peer" ]]; then cp "$tmp/actions/$peer/"* "$dir/"; fi
  {
    printf 'set -euo pipefail\numask 077\n'
    printf 'account=%q\nkit=%q\ndigest=%q\nkey=%q\n' "$SSH_USER" "$KIT_ROOT" "$MANIFEST_SHA256" "$keytype $keyblob"
    cat "$here/bootstrap-access-node.sh"
    printf '\ninstall_policy <<\x27ACTIONS\x27\n'
    tar -czf - -C "$dir" . | base64
    printf 'ACTIONS\n'
  } > "$tmp/request"
  ssh "${opts[@]}" -i "$BOOTSTRAP_IDENTITY_FILE" "$BOOTSTRAP_USER@$peer" \
    'test "$(id -u)" -gt 0 && sudo -n -- /bin/bash -s' < "$tmp/request"
  ssh -n "${opts[@]}" -i "$SSH_IDENTITY_FILE" "$SSH_USER@$peer" \
    'test "$(id -u)" -gt 0 && sudo -n -l /usr/local/sbin/bigtop-ambari-action >/dev/null'
  echo "$host: deployment login and sudo policy verified"
done < "$tmp/targets"
