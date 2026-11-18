#!/usr/bin/env bash
set -euo pipefail
source /project/cluster/ha/env.sh
work=/run/compute
evidence=/evidence/compute
mkdir -p "$evidence"
hive="$HIVE_HOME/bin/hive"
export HIVE_CONF_DIR="$work/client"
export HADOOP_CLASSPATH="$HIVE_CONF_DIR:$TEZ_HOME/*:$TEZ_HOME/lib/*:${HADOOP_CLASSPATH:-}"
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
tez_apps() {
  yarn application -list -appTypes TEZ -appStates ALL |
    awk '$1 ~ /^application_[0-9]+_[0-9]+$/ {print $1}' | LC_ALL=C sort -u
}
case "$1" in
  configure)
    umask 077
    mkdir -p "$work"/{server,client,spark,classes}
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
    hdfs dfs -mkdir -p /ci-compute/lib /user/hive/warehouse /tmp
    hdfs dfs -chmod 1777 /tmp
    hdfs dfs -put -f "$TEZ_HOME/lib/tez.tar.gz" /ci-compute/lib/tez.tar.gz
    hdfs dfs -chmod 755 /ci-compute /ci-compute/lib
    hdfs dfs -chmod 644 /ci-compute/lib/tez.tar.gz
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
        if timeout 45 "$hive" -S -e 'SHOW DATABASES' >"$evidence/metastore-ready.log" 2>&1 &&
            grep -Fxq default "$evidence/metastore-ready.log"; then exit 0; fi
      fi
      sleep 2
    done
    exit 1 ;;
  prepare)
    data="/ci-compute/$2/input"
    hdfs dfs -mkdir -p "$data"
    printf 'alpha,2\nbeta,7\nalpha,3\n' | hdfs dfs -put - "$data/readings.csv"
    "$hive" -S -e "CREATE DATABASE ci_$2;
      CREATE EXTERNAL TABLE ci_$2.readings (label STRING, amount INT)
      ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$data';" \
      >"$evidence/prepare.log" 2>&1
    ;;
  tez)
    tez_apps >"$work/tez-before"
    "$hive" -S -e "SELECT label, sum(amount) FROM ci_$2.readings GROUP BY label;" \
      >"$evidence/hive-result.log" 2>"$evidence/hive-query.log"
    LC_ALL=C sort "$evidence/hive-result.log" >"$work/hive-sorted"
    diff -u <(printf 'alpha\t5\nbeta\t7\n') "$work/hive-sorted"
    tez_apps >"$work/tez-after"
    # This isolated test runs exactly one query between snapshots.
    tez_id=$(LC_ALL=C comm -13 "$work/tez-before" "$work/tez-after")
    check_application "$tez_id" TEZ
    echo "HIVE_TEZ_PASSED $tez_id"
    ;;
  spark)
    unset HADOOP_CLASSPATH
    export SPARK_CONF_DIR="$work/spark"
    export SPARK_DIST_CLASSPATH
    SPARK_DIST_CLASSPATH=$(hadoop classpath --glob)
    javac -cp "$SPARK_HOME/jars/*:$SPARK_DIST_CLASSPATH" -d "$work/classes" /project/cluster/compute/ComputeCheck.java
    jar cf "$work/compute.jar" -C "$work/classes" .
    path="hdfs://cluster/ci-compute/$2"
    "$SPARK_HOME/bin/spark-submit" --master yarn --deploy-mode cluster --class ComputeCheck \
      --name "ci-spark-$2" --driver-memory 512m --executor-memory 512m --executor-cores 1 \
      --num-executors 1 --conf spark.yarn.populateHadoopClasspath=true \
      --conf spark.yarn.submit.waitAppCompletion=true --conf spark.dynamicAllocation.enabled=false \
      "$work/compute.jar" "$path/input" "$path/spark-output" >"$evidence/spark-submit.log" 2>&1
    hdfs dfs -test -e "$path/spark-output/_SUCCESS"
    hdfs dfs -cat "$path/spark-output/part-*" | LC_ALL=C sort >"$evidence/spark-result.tsv"
    spark_id=$(cut -f1 "$evidence/spark-result.tsv" | uniq)
    check_application "$spark_id" SPARK
    diff -u <(printf '%s\talpha\t5\n%s\tbeta\t7\n' "$spark_id" "$spark_id") "$evidence/spark-result.tsv"
    echo "SPARK_YARN_PASSED $spark_id"
    ;;
  *) exit 64 ;;
esac
