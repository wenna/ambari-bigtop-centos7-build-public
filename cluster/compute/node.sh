#!/usr/bin/env bash
set -euo pipefail
source /project/cluster/ha/env.sh
work=/run/compute
evidence=/evidence/compute
mkdir -p "$evidence"
hive="$HIVE_HOME/bin/hive"
export HIVE_CONF_DIR="$work/client"
# Hive's launcher puts TEZ_CONF_DIR before HIVE_CONF_DIR on its JVM classpath.
# Keep this directory separate so metastore JVMs still load the server hive-site.xml.
export TEZ_CONF_DIR="$work/tez"
export TEZ_ARCHIVE_URI=hdfs://cluster/ci-compute/lib/tez.tar.gz
export HADOOP_CLASSPATH="$TEZ_CONF_DIR:$HIVE_CONF_DIR:$TEZ_HOME/*:$TEZ_HOME/lib/*:${HADOOP_CLASSPATH:-}"
export HADOOP_CLIENT_OPTS="${HADOOP_CLIENT_OPTS:-} -Dhive.log.dir=$evidence"

check_application() {
  local id=$1 type=$2 report="$evidence/$2-status.log"
  [[ $id =~ ^application_[0-9]+_[0-9]+$ ]]
  for attempt in {1..30}; do
    timeout 20s yarn application -status "$id" >"$report" 2>&1
    if grep -Eq '^[[:space:]]*State[[:space:]]*:[[:space:]]*FINISHED[[:space:]]*$' "$report"; then
      break
    fi
    if grep -Eq '^[[:space:]]*State[[:space:]]*:[[:space:]]*(FAILED|KILLED)' "$report"; then
      cat "$report"; return 1
    fi
    sleep 2
  done
  cat "$report"
  grep -Eq "^[[:space:]]*Application-Type[[:space:]]*:[[:space:]]*$type[[:space:]]*$" "$report"
  grep -Eq '^[[:space:]]*State[[:space:]]*:[[:space:]]*FINISHED[[:space:]]*$' "$report"
  grep -Eq '^[[:space:]]*Final-State[[:space:]]*:[[:space:]]*SUCCEEDED[[:space:]]*$' "$report"
}
case "$1" in
  configure)
    umask 077
    mkdir -p "$work"/{server,client,tez}
    python3 /project/cluster/compute/configure.py
    umask 022
    export HIVE_CONF_DIR="$work/server"
    jdbc=/opt/cluster/postgresql.jar
    test -s "$jdbc"
    # schematool and the metastore run in separate Hadoop RunJar processes.
    ln -sfn "$jdbc" "$HIVE_HOME/lib/ci-postgresql.jar"
    export HADOOP_CLASSPATH="$HIVE_CONF_DIR:$jdbc:$TEZ_HOME/*:$TEZ_HOME/lib/*"
    if [[ $2 == init ]]; then
      "$HIVE_HOME/bin/schematool" -dbType postgres -initSchema >"$evidence/schema-init.log" 2>&1
    fi
    "$HIVE_HOME/bin/schematool" -dbType postgres -info >"$evidence/schema-info.log" 2>&1
    test -s "$TEZ_HOME/lib/tez.tar.gz"
    tar -tzf "$TEZ_HOME/lib/tez.tar.gz" >"$work/archive-files"
    grep -Eq '(^|/)tez-dag-[^/]+\.jar$' "$work/archive-files"
    grep -Eq '(^|/)tez-api-[^/]+\.jar$' "$work/archive-files"
    hdfs dfs -mkdir -p /ci-compute/lib /user/hive/warehouse /tmp
    hdfs dfs -chmod 1777 /tmp
    hdfs dfs -put -f "$TEZ_HOME/lib/tez.tar.gz" "$TEZ_ARCHIVE_URI"
    hdfs dfs -chmod 755 /ci-compute /ci-compute/lib
    hdfs dfs -chmod 644 "$TEZ_ARCHIVE_URI"
    [[ $(hdfs dfs -stat '%b' "$TEZ_ARCHIVE_URI") == "$(stat -c %s "$TEZ_HOME/lib/tez.tar.gz")" ]]
    ;;
  metastore)
    export HIVE_CONF_DIR="$work/server"
    export HADOOP_CLASSPATH="$HIVE_CONF_DIR:/opt/cluster/postgresql.jar:$TEZ_HOME/*:$TEZ_HOME/lib/*"
    exec setsid bash -c 'echo $$ > "$1"; exec "$2" --service metastore -p 9083' _ \
      "$work/metastore.pid" "$hive" >>"$evidence/metastore.log" 2>&1
    ;;
  stop)
    pid=$(cat "$work/metastore.pid")
    kill -TERM -- "-$pid"
    for attempt in {1..30}; do
      if ! timeout 1 bash -c 'exec 3<>/dev/tcp/master1/9083' 2>/dev/null; then exit 0; fi
      sleep 1
    done
    exit 1 ;;
  ready)
    for attempt in {1..60}; do
      if timeout 2 bash -c 'exec 3<>/dev/tcp/master1/9083' 2>/dev/null; then
        if timeout 45 "$hive" -S --hiveconf hive.execution.engine=mr -e 'SHOW DATABASES' >"$evidence/metastore-ready.log" 2>&1 &&
            grep -Fxq default "$evidence/metastore-ready.log"; then exit 0; fi
      fi
      sleep 2
    done
    exit 1 ;;
  prepare)
    data="/ci-compute/$2/input"
    hdfs dfs -mkdir -p "$data"
    printf 'alpha,2\nbeta,7\nalpha,3\n' | hdfs dfs -put - "$data/readings.csv"
    "$hive" -S --hiveconf hive.execution.engine=mr -e "CREATE DATABASE ci_$2;
      CREATE EXTERNAL TABLE ci_$2.readings (label STRING, amount INT)
      ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$data';" \
      >"$evidence/prepare.log" 2>&1
    ;;
  tez)
    query_name="ci_group_readings_$2"
    history_dir="/evidence/.tez-history-$2"
    mkdir -p "$history_dir"
    "$hive" -S --hiveconf "tez.lib.uris=$TEZ_ARCHIVE_URI" \
      --hiveconf "hive.query.name=$query_name" \
      --hiveconf "tez.simple.history.logging.dir=file://$history_dir" \
      -e "SET tez.lib.uris; SELECT label, sum(amount) FROM ci_$2.readings GROUP BY label;" \
      >"$work/hive-stdout" 2>"$evidence/hive-query.log"
    grep -Fx "tez.lib.uris=$TEZ_ARCHIVE_URI" "$work/hive-stdout"
    grep -Fvx "tez.lib.uris=$TEZ_ARCHIVE_URI" "$work/hive-stdout" >"$evidence/hive-result.log"
    LC_ALL=C sort "$evidence/hive-result.log" >"$work/hive-sorted"
    diff -u <(printf 'alpha\t5\nbeta\t7\n') "$work/hive-sorted"
    python3 /project/cluster/compute/tez-history.py "$history_dir" "$query_name" |
      tee "$evidence/tez-dag-status.log"
    read -r dag_id tez_id _ <"$evidence/tez-dag-status.log"
    check_application "$tez_id" TEZ
    echo "HIVE_TEZ_PASSED $tez_id $dag_id"
    ;;
  spark)
    unset HADOOP_CLASSPATH
    export SPARK_CONF_DIR="$work/spark"
    mkdir -p "$work"/{spark,classes}
    export SPARK_DIST_CLASSPATH
    SPARK_DIST_CLASSPATH=$(hadoop classpath --glob)
    javac -cp "$SPARK_HOME/jars/*:$SPARK_DIST_CLASSPATH" -d "$work/classes" /project/cluster/compute/ComputeCheck.java
    jar cf "$work/compute.jar" -C "$work/classes" .
    path="hdfs://cluster/ci-compute/$2"
    hdfs dfs -mkdir -p "$path/spark-input"
    printf 'alpha,2\nbeta,7\nalpha,3\n' | hdfs dfs -put - "$path/spark-input/readings.csv"
    "$SPARK_HOME/bin/spark-submit" --master yarn --deploy-mode cluster --class ComputeCheck \
      --name "ci-spark-$2" --driver-memory 512m --executor-memory 512m --executor-cores 1 \
      --num-executors 1 --conf spark.yarn.populateHadoopClasspath=true \
      --conf spark.yarn.submit.waitAppCompletion=true --conf spark.dynamicAllocation.enabled=false \
      "$work/compute.jar" "$path/spark-input" "$path/spark-output" >"$evidence/spark-submit.log" 2>&1
    hdfs dfs -test -e "$path/spark-output/_SUCCESS"
    hdfs dfs -cat "$path/spark-output/part-*" | LC_ALL=C sort >"$evidence/spark-result.tsv"
    spark_id=$(cut -f1 "$evidence/spark-result.tsv" | uniq)
    check_application "$spark_id" SPARK
    diff -u <(printf '%s\talpha\t5\n%s\tbeta\t7\n' "$spark_id" "$spark_id") "$evidence/spark-result.tsv"
    echo "SPARK_YARN_PASSED $spark_id"
    ;;
  diagnose)
    type=$2
    mkdir -p "$work"
    report="$evidence/$type-diagnostic.log"
    exec >"$report" 2>&1
    if [[ $type == TEZ ]]; then
      logs=("$evidence/hive-query.log" "$work/hive-stdout" "$evidence/prepare.log")
    else
      logs=("$evidence/spark-submit.log")
    fi
    for log in "${logs[@]}"; do
      if [[ -f $log ]]; then
        echo "=== $log"
        grep -Ei 'caused by:|exception|error|fail|diagnostics' "$log" | tail -n 60 || true
        tail -n 20 "$log"
      fi
    done
    timeout 20s yarn application -list -appTypes "$type" -appStates ALL >"$work/$type-apps"
    cat "$work/$type-apps"
    # The isolated cluster runs one acceptance workload for each application type.
    awk '$1 ~ /^application_[0-9]+_[0-9]+$/ {print $1}' "$work/$type-apps" |
      sort -rV | head -n 3 >"$work/$type-ids"
    while read -r id; do
      timeout 20s yarn application -status "$id" || true
      timeout 30s yarn logs -applicationId "$id" -size -8192 2>&1 | tail -c 65536 || true
    done <"$work/$type-ids"
    ;;
  worker-logs)
    type=$2
    shopt -s nullglob
    report="$evidence/$(hostname -s)-$type-diagnostic.log"
    exec >"$report" 2>&1
    while read -r id; do
      [[ $id =~ ^application_[0-9]+_[0-9]+$ ]] || continue
      for log in /var/lib/ha/nm/logs/"$id"/container_*/{prelaunch.err,stderr,stdout,syslog}; do
        [[ -s $log ]] || continue
        echo "=== $log"
        tail -c 8192 "$log"
      done
    done
    ;;
  *) exit 64 ;;
esac
