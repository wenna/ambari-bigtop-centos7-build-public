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
      for stream in errors output; do
        docker exec "$host" tail -n 100 "/var/lib/ambari-agent/data/$stream-$task.txt" 2>/dev/null |
          redact > "provision-evidence/request-$rid-task-$task-$stream.txt" || true
      done
      api "clusters/lab/requests/$rid/tasks/$task?fields=Tasks/stderr,Tasks/exit_code" |
        jq -r '.Tasks | "exit_code=\(.exit_code)\n\(.stderr)"' | redact > "provision-evidence/request-$rid-task-$task-api-error.txt" || true
    done < <(jq -r '[.[] | select(.status=="FAILED" or .status=="TIMEDOUT" or .status=="HOLDING_FAILED")] | .[:4][] | "\(.host_name) \(.id)"' "provision-evidence/request-$rid-tasks.json")
  done < <(jq -r '.items[].Requests.id' provision-evidence/requests.json)
fi
api 'clusters/lab/host_components?fields=HostRoles/component_name,HostRoles/host_name,HostRoles/state' > provision-evidence/host-components.json || true
for host in bd01.lab.test bd02.lab.test bd03.lab.test; do
  docker exec "$host" rpm -qa --qf '%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "provision-evidence/$host-after.tsv" || true
  docker exec "$host" bash -c 'printf "Container init limits:\n"; grep -E "Max (open files|processes|core file size)" /proc/1/limits; if test -f /etc/security/limits.d/hdfs.conf; then grep -E "^[^#].*(nofile|nproc)" /etc/security/limits.d/hdfs.conf; su hdfs -l -s /bin/bash -c '\''grep -E "Max (open files|processes|core file size)" /proc/self/limits'\''; fi' > "provision-evidence/$host-limits.txt" 2>&1 || true
done
docker exec "$server" tail -n 160 /var/log/ambari-server/ambari-server.log 2>/dev/null |
  grep -Ei 'WARN|ERROR|Exception' | redact > provision-evidence/server-errors.txt || true
