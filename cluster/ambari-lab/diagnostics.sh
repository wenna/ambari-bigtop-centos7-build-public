#!/usr/bin/env bash
set -eu
mkdir -p provision-evidence
docker ps -a --format '{{.Names}}\t{{.Status}}' > provision-evidence/containers.tsv
docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.PIDs}}' > provision-evidence/resources.tsv || true
df -h "$PWD" > provision-evidence/disk.txt
server=bd01.lab.test
api() { docker exec "$server" curl --globoff -fsS --max-time 20 --netrc-file /root/test.netrc "http://localhost:8080/api/v1/$1"; }
redact() {
  sed -E -e 's/(Hive!|Db!)[0-9a-f]{48}/[REDACTED]/g' -e '/password|credential|passphrase|authorization|private key|token/I d' |
    cut -c 1-600 | tail -n 45
}
if api 'clusters/lab/requests?fields=Requests/id,Requests/request_status' > provision-evidence/requests.json; then
  while read -r rid; do
    api "clusters/lab/requests/$rid/tasks?fields=Tasks/id,Tasks/role,Tasks/status,Tasks/command,Tasks/host_name" | jq '[.items[].Tasks | {id,role,status,command,host_name}]' > "provision-evidence/request-$rid-tasks.json" || true
    while read -r host task; do
      [[ $host =~ ^bd0[1-3]\.lab\.test$ && $task =~ ^[0-9]+$ ]] || continue
      docker exec "$host" tail -n 75 "/var/lib/ambari-agent/data/errors-$task.txt" "/var/lib/ambari-agent/data/output-$task.txt" 2>/dev/null |
        redact > "provision-evidence/request-$rid-task-$task-error.txt" || true
    done < <(jq -r '[.[] | select(.status=="FAILED" or .status=="TIMEDOUT" or .status=="HOLDING_FAILED")] | .[:4][] | "\(.host_name) \(.id)"' "provision-evidence/request-$rid-tasks.json")
  done < <(jq -r '.items[].Requests.id' provision-evidence/requests.json)
fi
api 'clusters/lab/host_components?fields=HostRoles/component_name,HostRoles/host_name,HostRoles/state' > provision-evidence/host-components.json || true
docker exec "$server" tail -n 160 /var/log/ambari-server/ambari-server.log 2>/dev/null |
  grep -Ei 'WARN|ERROR|Exception' | redact > provision-evidence/server-errors.txt || true
