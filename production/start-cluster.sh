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
source "$tmp/topology.sh"
primary=${NODES_namenode[0]}
standby=${NODES_namenode[1]}
rm_client=${NODES_resourcemanager[0]}
schema_host=${NODES_metastore[0]}
source "$tmp/$primary.env"
helper=/usr/local/libexec/bigtop-production/node-service.sh
HIVE_HOME=/usr/bigtop/3.3.0/usr/lib/hive
for slot in "${ALL_SLOTS[@]}"; do
  (source "$tmp/$slot.env"; echo "$slot $FQDN: ${ROLES[*]-}")
done
[[ $action == apply ]] || exit 0
: "${SSH_USER:?Set SSH_USER to the approved deployment account}"
[[ $SSH_USER =~ ^[a-z_][a-z0-9_-]*$ ]]
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=3)
if [[ -n ${SSH_PORT:-} ]]; then
  [[ $SSH_PORT =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || exit 64
  ssh_opts+=(-p "$SSH_PORT")
fi
if [[ -n ${SSH_IDENTITY_FILE:-} ]]; then [[ -r $SSH_IDENTITY_FILE ]]; ssh_opts+=(-o IdentitiesOnly=yes -i "$SSH_IDENTITY_FILE"); fi
if [[ -n ${SSH_KNOWN_HOSTS:-} ]]; then [[ -r $SSH_KNOWN_HOSTS ]]; ssh_opts+=(-o "UserKnownHostsFile=$SSH_KNOWN_HOSTS"); fi
remote() {
  local target=$1 command; shift
  printf -v command '%q ' "$@"
  ssh "${ssh_opts[@]}" "$SSH_USER@${HOST[$target]}" "sudo -n -- $command"
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

# Acquire the lock on the first NameNode for all control hosts.
coproc CLUSTER_LOCK { remote "$primary" flock -n /run/lock/bigtop-production.lock bash -c 'echo LOCKED; cat >/dev/null'; }
lock_pid=$CLUSTER_LOCK_PID
read -r -t 20 acquired <&"${CLUSTER_LOCK[0]}" && [[ $acquired == LOCKED ]] ||
  { echo "Cannot acquire deployment lock on $primary" >&2; exit 1; }
identifier=$({ sha256sum <"$site"; sha256sum <"$snapshot/plan.json"; } | sha256sum | cut -d' ' -f1)
stage=/var/lib/bigtop-production/stage/"$identifier"
marker=/var/lib/bigtop-production/cluster-id
cid=$(remote "$primary" bash -c 'if test -f "$1"; then cat "$1"; else echo FRESH; fi' _ "$marker")
if [[ $cid == FRESH ]]; then mode=fresh; else
  [[ $cid =~ ^CID-[a-zA-Z0-9-]+$ ]] || { echo "Invalid cluster ID marker on $primary" >&2; exit 1; }
  mode=managed
fi
for slot in "${ALL_SLOTS[@]}"; do
  mkdir -p "$tmp/transfer"
  cp "$tmp/$slot.env" "$tmp/transfer/node.env"
  remote "$slot" install -d -m 0700 "$stage" "$stage/tree"
  tar -C "$snapshot/$slot" -cf - . | remote "$slot" tar -C "$stage/tree" -xf -
  tar -C "$here" -cf - node-service.sh CatalogState.java -C "$tmp/transfer" node.env |
    remote "$slot" tar -C "$stage" -xf -
  remote "$slot" bash "$stage/node-service.sh" inspect "$stage" "$identifier" "$mode" "$cid"
done
for slot in "${ALL_SLOTS[@]}"; do remote "$slot" bash "$stage/node-service.sh" install "$stage" "$identifier"; done
port() { node "$primary" command timeout 3 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$1" "$2"; }
hostnames() { local s; for s in "$@"; do printf '%s\n' "${HOST[$s]}"; done; }
mapfile -t zk_hosts < <(hostnames "${NODES_zookeeper[@]}")
quorate() {
  node "$primary" command python3 -c 'import socket,sys
roles=[]
for h in sys.argv[1:]:
    with socket.create_connection((h,2181),3) as s:
        s.settimeout(3); s.sendall(b"srvr")
        roles.extend(x.strip() for x in s.makefile() if x.startswith("Mode:"))
print(roles)
sys.exit(sorted(roles)!=["Mode: follower"]*(len(sys.argv)-2)+["Mode: leader"])' "${zk_hosts[@]}"
}
for slot in "${NODES_zookeeper[@]}"; do node "$slot" start zookeeper; done
for slot in "${NODES_journalnode[@]}"; do node "$slot" start journalnode; done
wait_for 'ZooKeeper quorum' quorate
for slot in "${NODES_journalnode[@]}"; do wait_for "JournalNode $slot" port "${HOST[$slot]}" 8485; done
if [[ $mode == fresh ]]; then
  client "$primary" "$HDFS_USER" hdfs namenode -format -nonInteractive
  client "$primary" "$HDFS_USER" hdfs zkfc -formatZK -nonInteractive
fi
node "$primary" start namenode
if [[ $mode == fresh ]]; then
  wait_for 'first NameNode RPC' port "${HOST[$primary]}" 8020
  client "$standby" "$HDFS_USER" hdfs namenode -bootstrapStandby -nonInteractive
fi
node "$standby" start namenode
for slot in "${NODES_zkfc[@]}"; do node "$slot" start zkfc; done
for slot in "${NODES_datanode[@]}"; do node "$slot" start datanode; done
ha_pair() {
  local user=$1 tool=$2 admin=$3 prefix=$4 slot=$primary first second
  if [[ $tool == yarn ]]; then slot=$rm_client; fi
  first=$(client "$slot" "$user" "$tool" "$admin" -getServiceState "${prefix}1") || return 1
  second=$(client "$slot" "$user" "$tool" "$admin" -getServiceState "${prefix}2") || return 1
  [[ "$first $second" == 'active standby' || "$first $second" == 'standby active' ]]
}
wait_for 'NameNode active/standby' ha_pair "$HDFS_USER" hdfs haadmin nn
registered_dns() {
  client "$primary" "$HDFS_USER" hdfs dfsadmin -report -live |
    awk '$1=="Hostname:"{print $2}' | LC_ALL=C sort >"$tmp/live-datanodes" || return 1
  diff -u <(hostnames "${NODES_datanode[@]}" | LC_ALL=C sort) "$tmp/live-datanodes"
}
wait_for 'inventory DataNodes registered' registered_dns
client "$primary" "$HDFS_USER" hdfs dfsadmin -safemode wait
if [[ $mode == fresh ]]; then
  remote "$primary" bash -ec 'id=$(sed -n "s/^clusterID=//p" "$1/current/VERSION"); [[ $id =~ ^CID-[a-zA-Z0-9-]+$ ]]; echo "$id" >"$2.new"; mv -T "$2.new" "$2"' _ "$STATE_DIR/namenode" "$marker"
fi
client "$primary" "$HDFS_USER" "$helper" storage
for slot in "${NODES_resourcemanager[@]}"; do node "$slot" start resourcemanager; done
for slot in "${NODES_nodemanager[@]}"; do node "$slot" start nodemanager; done
wait_for 'ResourceManager active/standby' ha_pair "$YARN_USER" yarn rmadmin rm
registered_nms() {
  client "$rm_client" "$YARN_USER" yarn node -list -states RUNNING |
    awk '$2=="RUNNING"{sub(/:[0-9]+$/,"",$1); print $1}' | LC_ALL=C sort >"$tmp/live-nodemanagers" || return 1
  diff -u <(hostnames "${NODES_nodemanager[@]}" | LC_ALL=C sort) "$tmp/live-nodemanagers"
}
wait_for 'inventory NodeManagers running' registered_nms
for slot in "${NODES_jobhistory[@]}"; do node "$slot" start jobhistory; wait_for "JobHistory $slot" port "${HOST[$slot]}" 10020; done
node "$schema_host" schema
for slot in "${NODES_metastore[@]}"; do node "$slot" start metastore; done
for slot in "${NODES_metastore[@]}"; do
  host=${HOST[$slot]}
  wait_for "Hive Metastore $host" client "$schema_host" "$HIVE_USER" timeout 45s "$HIVE_HOME/bin/hive" -S \
    --hiveconf hive.execution.engine=mr --hiveconf "hive.metastore.uris=thrift://$host:9083" -e 'SHOW DATABASES'
done
for slot in "${NODES_hiveserver2[@]}"; do node "$slot" start hiveserver2; done
for slot in "${NODES_hiveserver2[@]}"; do
  host=${HOST[$slot]}
  wait_for "HiveServer2 JDBC $host" client "${NODES_hiveserver2[0]}" "$HIVE_USER" timeout 45s "$HIVE_HOME/bin/beeline" \
    -u "jdbc:hive2://$host:10000/default" -n "$HIVE_USER" -p '' --silent=true -e 'SHOW DATABASES'
done
for slot in "${NODES_sparkhistory[@]}"; do
  node "$slot" start sparkhistory
  wait_for "Spark History API $slot" node "$slot" command curl -fsS --max-time 5 "http://${HOST[$slot]}:18080/api/v1/applications"
done
echo "DATA_SERVICES_READY nameservice=$NAMESERVICE nodes=${#ALL_SLOTS[@]} units=systemd"
