#!/usr/bin/env bash
set -euo pipefail
api=http://localhost:8080/api/v1/clusters/lab/requests
client=(curl -fsS --max-time 30 --globoff --netrc-file /root/test.netrc -H 'X-Requested-By: ambari-lab' -H 'Content-Type: application/json')
check_service() {
  local service=$1 command payload rid deadline status
  command="${service}_SERVICE_CHECK"
  if [[ $service == ZOOKEEPER ]]; then command=ZOOKEEPER_QUORUM_SERVICE_CHECK; fi
  payload=$(printf '{"RequestInfo":{"context":"Acceptance check: %s","command":"%s"},"Requests/resource_filters":[{"service_name":"%s"}]}' "$service" "$command" "$service")
  rid=$("${client[@]}" -d "$payload" "$api" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["Requests"]["id"]))')
  deadline=$((SECONDS + 600))
  while ((SECONDS < deadline)); do
    status=$("${client[@]}" "$api/$rid?fields=Requests/request_status" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Requests"]["request_status"])')
    case $status in
      COMPLETED) break;;
      PENDING|QUEUED|IN_PROGRESS) sleep 5;;
      *) echo "$service service check $rid: $status" >&2; exit 1;;
    esac
  done
  [[ $status == COMPLETED ]] || { echo "$service service check $rid exceeded 10 minutes" >&2; exit 1; }
  echo "$service service check $rid: $status"
}
failed=0
for service in ZOOKEEPER HDFS YARN MAPREDUCE2 TEZ HIVE SPARK; do
  echo "Running Ambari service check: $service"
  set +e
  (set -e; check_service "$service")
  status=$?
  set -e
  if (( status != 0 )); then failed=1; fi
done
exit "$failed"
