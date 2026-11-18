#!/usr/bin/env bash
# Host entry point after cluster/compute/run.sh. The server stays available in the lab.
set -euo pipefail
script=/project/cluster/compute/check-hs2.sh
evidence=/evidence/compute

case "${1:-run}" in
  run)
    # Start from the same client configuration that passed the Hive-on-Tez workload.
    docker exec -d master1 bash "$script" serve
    if docker exec master2 timeout --kill-after=10s 240s bash "$script" ready &&
        docker exec master2 timeout --kill-after=15s 900s bash "$script" query; then
      exit 0
    fi
    docker exec master1 bash -c 'for f in "$1"/hs2*.log; do
      test -s "$f" || continue
      echo "=== $f"; tail -n 45 "$f"
    done' _ "$evidence"
    exit 1
    ;;
  serve)
    source /project/cluster/ha/env.sh
    [[ $(hostname -s) == master1 ]]
    export HIVE_CONF_DIR=/run/compute/client
    export TEZ_CONF_DIR=/run/compute/tez
    export HADOOP_CLASSPATH="$TEZ_CONF_DIR:$HIVE_CONF_DIR:$TEZ_HOME/*:$TEZ_HOME/lib/*:${HADOOP_CLASSPATH:-}"
    export HADOOP_CLIENT_OPTS="${HADOOP_CLIENT_OPTS:-} -Dhive.log.dir=$evidence"
    test -s "$HIVE_CONF_DIR/hive-site.xml"
    test -s "$TEZ_CONF_DIR/tez-site.xml"
    exec >>"$evidence/hs2-server.log" 2>&1
    # A retry can reuse the same healthy server.
    if [[ -s /run/compute/hs2.pid ]] && kill -0 "$(cat /run/compute/hs2.pid)" 2>/dev/null; then exit 0; fi
    echo "$$" >/run/compute/hs2.pid
    exec "$HIVE_HOME/bin/hiveserver2" \
      --hiveconf hive.server2.thrift.bind.host=master1 \
      --hiveconf hive.server2.thrift.port=10000 \
      --hiveconf hive.server2.transport.mode=binary \
      --hiveconf hive.server2.authentication=NONE \
      --hiveconf hive.server2.enable.doAs=false \
      --hiveconf hive.server2.tez.initialize.default.sessions=false \
      --hiveconf tez.lib.uris=hdfs://cluster/ci-compute/lib/tez.tar.gz
    ;;
  ready|query)
    source /project/cluster/ha/env.sh
    [[ $(hostname -s) == master2 ]]
    # Select only the catalog row checked by the preceding PostgreSQL acceptance step.
    catalog=$(cat "$evidence/catalog-check.log")
    pattern='^PostgreSQL metastore has 1 matching table after restart \((ci_[0-9]+_[0-9]+)\.readings\)$'
    [[ $catalog =~ $pattern ]]
    database=${BASH_REMATCH[1]}
    url="jdbc:hive2://master1:10000/$database"
    beeline=("$HIVE_HOME/bin/beeline" -u "$url" -n root -p '' --silent=true --showHeader=false --outputformat=tsv2)
    if [[ $1 == ready ]]; then
      for attempt in {1..60}; do
        if timeout 2s bash -c 'exec 3<>/dev/tcp/master1/10000' 2>/dev/null &&
            timeout 40s "${beeline[@]}" -e "SHOW TABLES LIKE 'readings'" \
              >"$evidence/hs2-ready.log" 2>"$evidence/hs2-connect.log" &&
            grep -Fxq readings "$evidence/hs2-ready.log"; then exit 0; fi
        sleep 2
      done
      exit 1
    fi
    "${beeline[@]}" -e 'SELECT label, sum(amount) FROM readings GROUP BY label' \
      >"$evidence/hs2-result.tsv" 2>"$evidence/hs2-query.log"
    diff -u <(printf 'alpha\t5\nbeta\t7\n') <(LC_ALL=C sort "$evidence/hs2-result.tsv")
    printf 'HIVESERVER2_JDBC_PASSED client=%s url=%s table=readings rows=2\n' "$(hostname -s)" "$url" |
      tee "$evidence/hs2-status.log"
    ;;
  *) exit 64 ;;
esac
