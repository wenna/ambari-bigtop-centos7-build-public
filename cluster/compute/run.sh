#!/usr/bin/env bash
# Run on the Docker host after cluster/ha/run.sh has established HDFS and YARN.
set -euo pipefail
token="$(date +%s)_${RANDOM}"
node() { docker exec master1 timeout --kill-after=15s "$1" bash /project/cluster/compute/node.sh "${@:2}"; }
sql() {
  timeout 15s docker exec db sh -ec 'export PGPASSWORD="$HIVE_DB_PASSWORD"; exec psql -w -h 127.0.0.1 -U hive -d hive -XAt -v ON_ERROR_STOP=1 -c "$1"' _ "$1"
}
start_metastore() {
  docker exec -d master1 bash /project/cluster/compute/node.sh metastore
  node 180s ready
}
hive_workload() {
  for attempt in {1..30}; do
    if [[ $(sql 'SELECT 1') == 1 ]]; then break; fi
    sleep 2
  done
  [[ $(sql 'SELECT 1') == 1 ]]
  schema=$(sql "SELECT CASE WHEN to_regclass('public.\"VERSION\"') IS NULL THEN 'init' ELSE 'existing' END")
  node 300s configure "$schema"
  start_metastore
  node 240s prepare "$token"
  # Use a new metastore JVM and a new CLI session against the same PostgreSQL DB.
  node 45s stop
  start_metastore
  node 900s tez "$token"
  table_count=$(sql "SELECT count(*) FROM \"TBLS\" t JOIN \"DBS\" d ON d.\"DB_ID\" = t.\"DB_ID\" WHERE d.\"NAME\" = 'ci_$token' AND t.\"TBL_NAME\" = 'readings'")
  [[ $table_count == 1 ]]
  printf 'PostgreSQL metastore has %s matching table after restart (ci_%s.readings)\n' "$table_count" "$token" |
    docker exec -i master1 tee /evidence/compute/catalog-check.log
}
diagnostics() {
  local type=$1 worker
  node 200s diagnose "$type" || true
  for worker in worker1 worker2 worker3; do
    docker exec master1 cat "/run/compute/$type-ids" |
      docker exec -i "$worker" timeout 30s bash /project/cluster/compute/node.sh worker-logs "$type" || true
  done
  docker exec master1 bash -c 'for f in /evidence/compute/*"$1"-diagnostic.log; do
    test -f "$f" || continue
    echo "=== $f"
    grep -Ei "caused by:|exception|error|fail|diagnostics" "$f" | tail -n 22
  done' _ "$type" || true
}
# Wait separately so a failed Hive stage still allows Spark verification, while
# the Hive and Spark processes each retain their own fail-fast shell semantics.
hive_workload &
hive_pid=$!
hive_status=0
wait "$hive_pid" || hive_status=$?
if (( hive_status )); then diagnostics TEZ; fi
spark_status=0
node 900s spark "$token" || spark_status=$?
if (( spark_status )); then diagnostics SPARK; fi
printf 'Compute validation exit codes: Hive=%s Spark=%s\n' "$hive_status" "$spark_status"
(( hive_status == 0 && spark_status == 0 ))
