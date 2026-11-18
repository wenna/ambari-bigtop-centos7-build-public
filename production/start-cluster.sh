#!/usr/bin/env bash
# Called after offline RPM installation. Storage initialization never uses -force.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
inventory= site= snapshot= action=
while (( $# )); do
  case "$1" in
    --inventory) inventory=$2;; --site) site=$2;; --snapshot) snapshot=$2;; --action) action=$2;;
    *) echo "Unknown argument: $1" >&2; exit 64;;
  esac
  shift 2
done
[[ -n $inventory && -n $site && -n $snapshot && ($action == plan || $action == apply) ]] ||
  { echo "Usage: $0 --inventory hosts.csv --site site.json --snapshot directory --action plan|apply" >&2; exit 64; }
python3 "$here/render.py" --inventory "$inventory" --site "$site" --out "$snapshot"
tmp=$(mktemp -d)
cleanup() { [[ -z ${lock_pid:-} ]] || kill "$lock_pid" 2>/dev/null || true; rm -rf -- "$tmp"; }
trap cleanup EXIT
python3 "$here/service-plan.py" "$site" "$snapshot/plan.json" "$tmp"
source "$tmp/bd01.env"
helper=/usr/local/libexec/bigtop-production/node-service.sh
HIVE_HOME=/usr/bigtop/3.3.0/usr/lib/hive
all=(bd{01..10}); quorum=(bd01 bd02 bd03); workers=(bd{04..08})
for slot in "${all[@]}"; do
  (source "$tmp/$slot.env"; echo "$slot $FQDN: ${ROLES[*]}")
done
[[ $action == apply ]] || exit 0
: "${SSH_USER:?Set SSH_USER to the approved deployment account}"
[[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*$ ]]
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
remote() {
  local number=${1#bd} command; shift
  printf -v command '%q ' "$@"
  ssh "${ssh_opts[@]}" "$SSH_USER@${HOSTS[10#$number-1]}" "sudo -n -- $command"
}
node() { local slot=$1; shift; remote "$slot" timeout -k 15s 360s "$helper" "$@"; }
client() { local slot=$1 user=$2; shift 2; node "$slot" client "$user" "$@"; }
wait_for() {
  local label=$1 end=$((SECONDS+300)); shift
  until "$@"; do
    (( SECONDS < end )) || { echo "Timed out: $label" >&2; return 1; }
    sleep 3
  done
}

# Hold the coordinator lock on bd01, including across runs from different control hosts.
coproc CLUSTER_LOCK { remote bd01 flock -n /run/lock/bigtop-production.lock bash -c 'echo LOCKED; cat >/dev/null'; }
lock_pid=$CLUSTER_LOCK_PID
read -r -t 20 acquired <&"${CLUSTER_LOCK[0]}" && [[ $acquired == LOCKED ]] ||
  { echo 'Cannot acquire cluster deployment lock on bd01' >&2; exit 1; }
identifier=$({ sha256sum <"$site"; sha256sum <"$snapshot/plan.json"; } | sha256sum | cut -d' ' -f1)
stage=/var/lib/bigtop-production/stage/"$identifier"
marker=/var/lib/bigtop-production/cluster-id
cid=$(remote bd01 bash -c 'if test -f "$1"; then cat "$1"; else echo FRESH; fi' _ "$marker")
if [[ $cid == FRESH ]]; then mode=fresh; else
  [[ $cid =~ ^CID-[a-zA-Z0-9-]+$ ]] || { echo "Invalid cluster ID marker on bd01" >&2; exit 1; }
  mode=managed
fi
for slot in "${all[@]}"; do
  mkdir -p "$tmp/transfer"
  cp "$tmp/$slot.env" "$tmp/transfer/node.env"
  remote "$slot" install -d -m 0700 "$stage" "$stage/tree"
  tar -C "$snapshot/$slot" -cf - . | remote "$slot" tar -C "$stage/tree" -xf -
  tar -C "$here" -cf - node-service.sh CatalogState.java -C "$tmp/transfer" node.env |
    remote "$slot" tar -C "$stage" -xf -
  remote "$slot" bash "$stage/node-service.sh" inspect "$stage" "$identifier" "$mode" "$cid"
done
for slot in "${all[@]}"; do remote "$slot" bash "$stage/node-service.sh" install "$stage" "$identifier"; done
port() { node bd01 command timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$1" "$2"; }
quorate() {
  node bd01 command python3 -c 'import socket,sys
roles=[]
for h in sys.argv[1:]:
    with socket.create_connection((h,2181),3) as s:
        s.settimeout(3); s.sendall(b"srvr")
        roles.extend(x.strip() for x in s.makefile() if x.startswith("Mode:"))
print(roles)
sys.exit(sorted(roles)!=["Mode: follower","Mode: follower","Mode: leader"])' "${HOSTS[@]:0:3}"
}
for slot in "${quorum[@]}"; do node "$slot" start zookeeper; node "$slot" start journalnode; done
wait_for 'ZooKeeper quorum' quorate
for host in "${HOSTS[@]:0:3}"; do wait_for "JournalNode $host" port "$host" 8485; done
if [[ $mode == fresh ]]; then
  client bd01 "$HDFS_USER" hdfs namenode -format -nonInteractive
  client bd01 "$HDFS_USER" hdfs zkfc -formatZK -nonInteractive
fi
node bd01 start namenode
if [[ $mode == fresh ]]; then
  wait_for 'first NameNode RPC' port "${HOSTS[0]}" 8020
  client bd02 "$HDFS_USER" hdfs namenode -bootstrapStandby -nonInteractive
fi
node bd02 start namenode
for slot in bd01 bd02; do node "$slot" start zkfc; done
for slot in "${workers[@]}"; do node "$slot" start datanode; done
ha_pair() {
  local user=$1 tool=$2 admin=$3 prefix=$4 slot=bd01 first second
  if [[ $tool == yarn ]]; then slot=bd03; fi
  first=$(client "$slot" "$user" "$tool" "$admin" -getServiceState "${prefix}1") || return 1
  second=$(client "$slot" "$user" "$tool" "$admin" -getServiceState "${prefix}2") || return 1
  [[ "$first $second" == 'active standby' || "$first $second" == 'standby active' ]]
}
wait_for 'NameNode active/standby' ha_pair "$HDFS_USER" hdfs haadmin nn
five_dns() { client bd01 "$HDFS_USER" hdfs dfsadmin -report -live | grep -E '^Live datanodes \(5\):'; }
wait_for 'five live DataNodes' five_dns
client bd01 "$HDFS_USER" hdfs dfsadmin -safemode wait
if [[ $mode == fresh ]]; then
  remote bd01 bash -ec 'id=$(sed -n "s/^clusterID=//p" "$1/current/VERSION"); [[ $id =~ ^CID-[a-zA-Z0-9-]+$ ]]; echo "$id" >"$2.new"; mv -T "$2.new" "$2"' _ "$STATE_DIR/namenode" "$marker"
fi
client bd01 "$HDFS_USER" "$helper" storage
for slot in bd02 bd03; do node "$slot" start resourcemanager; done
for slot in "${workers[@]}"; do node "$slot" start nodemanager; done
wait_for 'ResourceManager active/standby' ha_pair "$YARN_USER" yarn rmadmin rm
five_nms() { client bd03 "$YARN_USER" yarn node -list -states RUNNING | grep -E 'Total Nodes:[[:space:]]*5$'; }
wait_for 'five running NodeManagers' five_nms
node bd03 start jobhistory
wait_for 'JobHistory RPC' port "${HOSTS[2]}" 10020
node bd09 schema
for slot in bd09 bd10; do node "$slot" start metastore; done
for host in "${HOSTS[@]:8}"; do
  wait_for "Hive Metastore $host" client bd09 "$HIVE_USER" timeout 45s "$HIVE_HOME/bin/hive" -S \
    --hiveconf hive.execution.engine=mr --hiveconf "hive.metastore.uris=thrift://$host:9083" -e 'SHOW DATABASES'
done
for slot in bd09 bd10; do node "$slot" start hiveserver2; done
for host in "${HOSTS[@]:8}"; do
  wait_for "HiveServer2 JDBC $host" client bd10 "$HIVE_USER" timeout 45s "$HIVE_HOME/bin/beeline" \
    -u "jdbc:hive2://$host:10000/default" -n "$HIVE_USER" -p '' --silent=true -e 'SHOW DATABASES'
done
node bd10 start sparkhistory
wait_for 'Spark History API' node bd10 command curl -fsS --max-time 5 "http://${HOSTS[9]}:18080/api/v1/applications"
echo "DATA_SERVICES_READY nameservice=$NAMESERVICE nodes=10 units=systemd"
