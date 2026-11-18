#!/usr/bin/env bash
# Run on the Docker host against five fresh containers with fixed hostnames.
set -euo pipefail
masters=(master1 master2)
workers=(worker1 worker2 worker3)
nodes=("${masters[@]}" "${workers[@]}")
entry=/project/cluster/ha/node.sh
node() {
  local host=$1
  shift
  timeout 150 docker exec "$host" bash "$entry" "$@"
}
client() { node master1 exec "$@"; }
start() { docker exec -d "$1" bash "$entry" start "$2"; }
wait_for() {
  local label=$1 deadline=$((SECONDS + 180))
  shift
  until "$@"; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for $label" >&2
      return 1
    fi
    sleep 2
  done
}
state() {
  local role=$1 id=$2
  if [[ $role == nn ]]; then
    client timeout 15 hdfs haadmin -getServiceState "nn$id"
  else
    client timeout 15 yarn rmadmin -getServiceState "rm$id"
  fi
}
is_state() {
  local reported
  reported=$(state "$1" "$2") && [[ $reported == "$3" ]]
}
active_id() {
  local role=$1 first second
  first=$(state "$role" 1) && second=$(state "$role" 2) || return 1
  case "$first/$second" in
    active/standby) echo 1 ;;
    standby/active) echo 2 ;;
    *) echo "Unexpected $role states $first/$second" >&2; return 1 ;;
  esac
}
registered() {
  local report host
  report=$(client timeout 35 hdfs dfsadmin -report -live) || return 1
  for host in "${workers[@]}"; do
    grep -Fxq "Hostname: $host" <<<"$report" || return 1
  done
  report=$(client timeout 35 yarn node -list -states RUNNING) || return 1
  for host in "${workers[@]}"; do
    grep -Eq "^[[:space:]]*$host:[0-9]+[[:space:]]+RUNNING" <<<"$report" || return 1
  done
}
epoch() { node "$1" exec cat /var/lib/ha/journal/cluster/current/last-writer-epoch; }
dead() {
  # A zombie holds no sockets or locks. Docker's PID 1 may reap it later.
  docker exec "$1" bash -c '[[ ! -d /proc/$1 ]] || [[ $(cut -d" " -f3 /proc/"$1"/stat) == Z ]]' _ "$2"
}
for host in "${nodes[@]}"; do
  [[ $(docker exec "$host" hostname -s) == "$host" ]]
  node "$host" configure
done
for i in 1 2; do
  other=$((3 - i))
  docker exec "master$i" cat /run/ha/fence-key.pub |
    docker exec -i "master$other" bash -c 'umask 077; cat >> /root/.ssh/authorized_keys'
  node "master$i" exec ssh -i /run/ha/fence-key -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 "root@master$other" 'command -v fuser && command -v nc'
done
for host in "${workers[@]}"; do
  start "$host" zookeeper
  start "$host" journalnode
done
wait_for "ZooKeeper election" node master1 quorum
for host in "${workers[@]}"; do wait_for "JournalNode $host" node master1 port "$host" 8485; done
client hdfs namenode -format -nonInteractive
client hdfs zkfc -formatZK -nonInteractive
start master1 namenode
wait_for "first NameNode RPC" is_state nn 1 standby
node master2 exec hdfs namenode -bootstrapStandby -nonInteractive
start master2 namenode
for host in "${masters[@]}"; do
  start "$host" zkfc
  start "$host" resourcemanager
done
for host in "${workers[@]}"; do
  start "$host" datanode
  start "$host" nodemanager
done
wait_for "NameNode active/standby election" active_id nn
wait_for "ResourceManager active/standby election" active_id rm
wait_for "three DataNodes and three NodeManagers" registered
client timeout 120 hdfs dfsadmin -safemode wait
node master1 exec bash -c 'mkdir -p /tmp/ha-check; head -c 1048576 /dev/urandom > /tmp/ha-check/data'
client hdfs dfs -mkdir -p /ha-check
client hdfs dfs -put /tmp/ha-check/data /ha-check/before
client timeout 120 hdfs dfs -setrep -w 3 /ha-check/before
client hdfs fsck /ha-check/before -files -blocks -locations
old=$(active_id nn)
new=$((3 - old))
nn_pid=$(node "master$old" pid namenode)
declare -A epochs
for host in "${workers[@]}"; do epochs[$host]=$(epoch "$host"); done
echo "Stopping progress of active nn$old PID $nn_pid with SIGSTOP; ZKFC must fence it."
docker exec "master$old" kill -STOP "$nn_pid"
wait_for "automatic nn$new promotion" is_state nn "$new" active
wait_for "stopped NameNode killed by sshfence" dead "master$old" "$nn_pid"
client hdfs dfs -put /tmp/ha-check/data /ha-check/after
for name in before after; do
  node master1 exec bash -euo pipefail -c 'hdfs dfs -cat "/ha-check/$1" | cmp /tmp/ha-check/data -' _ "$name"
done
advanced=0
for host in "${workers[@]}"; do
  current=$(epoch "$host")
  echo "$host writer epoch ${epochs[$host]} -> $current"
  if (( current > epochs[$host] )); then advanced=$((advanced + 1)); fi
done
(( advanced >= 2 ))
start "master$old" namenode
wait_for "former NameNode rejoins standby" is_state nn "$old" standby
[[ $(active_id nn) == "$new" ]]
echo "HDFS_HA_PASSED nn$old -> nn$new; old writer fenced and both files matched"

old=$(active_id rm)
new=$((3 - old))
app=$(node master1 submit-rm-job | grep -Ex 'application_[0-9]+_[0-9]+')
[[ $app =~ ^application_[0-9]+_[0-9]+$ ]]
wait_for "a live map container for $app" client hdfs dfs -test -s /ha-check/rm-ready
container=$(client hdfs dfs -cat /ha-check/rm-ready)
[[ $container =~ ^container_[a-zA-Z0-9_]+$ ]]
node "master$old" rm-job-state "$app" RUNNING
echo "RM_FAILOVER_APPLICATION_RUNNING application=$app container=$container active=rm$old"
rm_pid=$(node "master$old" pid resourcemanager)
echo "Killing active rm$old PID $rm_pid"
docker exec "master$old" kill -KILL "$rm_pid"
wait_for "old RM exited" dead "master$old" "$rm_pid"
wait_for "automatic rm$new promotion" is_state rm "$new" active
start "master$old" resourcemanager
wait_for "former ResourceManager rejoins standby" is_state rm "$old" standby
[[ $(active_id rm) == "$new" ]]
wait_for "$app to re-register with rm$new" node "master$new" rm-job-state "$app" RUNNING
client hdfs dfs -touchz /ha-check/rm-release
wait_for "$app to finish on rm$new" node "master$new" rm-job-state "$app" FINISHED
[[ $(client hdfs dfs -cat /ha-check/rm-output/part-m-00000) == "$container" ]]
echo "YARN_WORK_PRESERVING_FAILOVER_PASSED application=$app container=$container old=rm$old new=rm$new final=SUCCEEDED"
wait_for "all workers after failover" registered
client hdfs dfsadmin -report -live
client yarn node -list -states RUNNING
echo "YARN_HA_PASSED rm$old -> rm$new; three workers reconnected"
