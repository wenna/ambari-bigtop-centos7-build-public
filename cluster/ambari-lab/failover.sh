#!/usr/bin/env bash
# Exercise a planned failover in the disposable three-node cluster through Ambari.
set -euo pipefail
api=http://localhost:8080/api/v1/clusters/lab
client=(curl --globoff -fsS --max-time 20 --netrc-file /root/test.netrc -H 'X-Requested-By: ambari-failover' -H 'Content-Type: application/json')
export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk HADOOP_CONF_DIR=/etc/hadoop/conf
change_state() {
  local host=$1 component=$2 desired=$3 request status
  request=$("${client[@]}" -X PUT -d "{\"HostRoles\":{\"state\":\"$desired\"}}" "$api/hosts/$host/host_components/$component" |
    python3 -c 'import json,sys; print(int(json.load(sys.stdin)["Requests"]["id"]))')
  for attempt in {1..90}; do
    status=$("${client[@]}" "$api/requests/$request" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Requests"]["request_status"])')
    case $status in COMPLETED) return;; IN_PROGRESS|QUEUED|PENDING) sleep 4;; *) echo "Ambari request $request $status" >&2; return 1;; esac
  done
  return 1
}
state() {
  local prefix=$1 number=$2
  if [[ $prefix == nn ]]; then runuser -u hdfs -- hdfs haadmin -getServiceState "nn$number"
  else runuser -u yarn -- yarn rmadmin -getServiceState "rm$number"; fi
}
for component in NAMENODE RESOURCEMANAGER; do
  prefix=nn; [[ $component != RESOURCEMANAGER ]] || prefix=rm
  a=$(state "$prefix" 1); b=$(state "$prefix" 2)
  case "$a/$b" in active/standby) prior=1; peer=2;; standby/active) prior=2; peer=1;; *) exit 1;; esac
  host="bd0$prior.lab.test"
  change_state "$host" "$component" INSTALLED
  for i in {1..60}; do [[ $(state "$prefix" "$peer") == active ]] && break; sleep 2; done
  [[ $(state "$prefix" "$peer") == active ]]
  change_state "$host" "$component" STARTED
  for i in {1..60}; do [[ $(state "$prefix" "$prior") == standby ]] && break; sleep 2; done
  [[ $(state "$prefix" "$prior") == standby && $(state "$prefix" "$peer") == active ]]
  printf 'AMBARI_FAILOVER_PASSED %s %s%d -> %s%d\n' "$component" "$prefix" "$prior" "$prefix" "$peer"
done
