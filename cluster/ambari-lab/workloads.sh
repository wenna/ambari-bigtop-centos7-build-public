#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
tag=${1:?unique test identifier}
[[ $tag =~ ^[0-9]+_[0-9]+$ ]]
base=/usr/bigtop/3.3.0/usr/lib
export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk
export HADOOP_CONF_DIR=/etc/hadoop/conf YARN_CONF_DIR=/etc/hadoop/conf
export HADOOP_HOME=$base/hadoop HADOOP_COMMON_HOME=$base/hadoop HADOOP_LIBEXEC_DIR=$base/hadoop/libexec
export HADOOP_HDFS_HOME=$base/hadoop-hdfs HADOOP_YARN_HOME=$base/hadoop-yarn HADOOP_MAPRED_HOME=$base/hadoop-mapreduce
export SPARK_HOME=$base/spark HIVE_HOME=$base/hive TEZ_HOME=$base/tez
export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HDFS_HOME/bin:$HADOOP_YARN_HOME/bin:$PATH"
export HDFS_TEST_PARENT=/user/ambari-qa
if [[ ${2:-} == prepare ]]; then
  [[ $(id -un) == hdfs ]]
  hdfs dfs -mkdir -p "$HDFS_TEST_PARENT"
  hdfs dfs -chown ambari-qa:hadoop "$HDFS_TEST_PARENT"
  exit
fi
[[ $(id -un) == ambari-qa ]]
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fs=$(hdfs getconf -confKey fs.defaultFS)
[[ $fs == hdfs://lab ]]
[[ $(printf '%s\n' "$(hdfs haadmin -getServiceState nn1)" "$(hdfs haadmin -getServiceState nn2)" | sort | paste -sd,) == active,standby ]]
[[ $(printf '%s\n' "$(yarn rmadmin -getServiceState rm1)" "$(yarn rmadmin -getServiceState rm2)" | sort | paste -sd,) == active,standby ]]
bash /tmp/ambari-workload/smoke-yarn.sh
data=$HDFS_TEST_PARENT/lab_$tag
hdfs dfs -mkdir -p "$data/input"
printf 'alpha,2\nbeta,7\nalpha,3\n' | hdfs dfs -put - "$data/input/readings.csv"
db=lab_$tag
beeline=("$HIVE_HOME/bin/beeline" -u 'jdbc:hive2://bd03.lab.test:10000/default' -n ambari-qa --silent=true --showHeader=false --outputformat=tsv2)
list_tez() { yarn application -list -appTypes TEZ -appStates ALL | awk '$1 ~ /^application_[0-9]+_[0-9]+$/{print $1}' | sort -u; }
list_tez > "$work/before"
"${beeline[@]}" -e "CREATE DATABASE $db;
  CREATE EXTERNAL TABLE $db.readings (label STRING, amount INT) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$data/input';
  SET hive.execution.engine=tez; SET hive.fetch.task.conversion=none; SET hive.exec.mode.local.auto=false;
  SELECT label,sum(amount) FROM $db.readings GROUP BY label;" > "$work/sql-result"
diff -u <(printf 'alpha\t5\nbeta\t7\n') <(sort "$work/sql-result")
list_tez > "$work/after"
tez_app=$(comm -13 "$work/before" "$work/after")
[[ $tez_app =~ ^application_[0-9]+_[0-9]+$ ]] || { echo 'Expected exactly one new Tez application for the JDBC aggregation' >&2; exit 1; }
yarn application -status "$tez_app" > "$work/tez-status"
grep -Eq 'Application-Type[[:space:]]*:[[:space:]]*TEZ[[:space:]]*$' "$work/tez-status"
printf 'HIVE_JDBC_TEZ_PASSED %s %s rows=alpha:5,beta:7\n' "$db" "$tez_app"
export SPARK_DIST_CLASSPATH
SPARK_DIST_CLASSPATH=$(hadoop classpath --glob)
javac -cp "$SPARK_HOME/jars/*:$SPARK_DIST_CLASSPATH" -d "$work" /tmp/ambari-workload/ComputeCheck.java
jar cf "$work/compute.jar" -C "$work" ComputeCheck.class
"$SPARK_HOME/bin/spark-submit" --master yarn --deploy-mode cluster --class ComputeCheck --name "ambari_$tag" \
  --driver-memory 512m --executor-memory 512m --num-executors 1 --executor-cores 1 \
  --conf spark.dynamicAllocation.enabled=false --conf spark.yarn.populateHadoopClasspath=true \
  --conf spark.yarn.submit.waitAppCompletion=true "$work/compute.jar" "$fs$data/input" "$fs$data/output"
hdfs dfs -test -e "$data/output/_SUCCESS"
hdfs dfs -cat "$data/output/part-*" | sort > "$work/spark-result"
spark_app=$(cut -f1 "$work/spark-result" | uniq)
[[ $spark_app =~ ^application_[0-9]+_[0-9]+$ ]]
diff -u <(printf '%s\talpha\t5\n%s\tbeta\t7\n' "$spark_app" "$spark_app") "$work/spark-result"
yarn application -status "$spark_app" > "$work/spark-status"
grep -Eq 'Application-Type[[:space:]]*:[[:space:]]*SPARK[[:space:]]*$' "$work/spark-status"
grep -Eq 'Final-State[[:space:]]*:[[:space:]]*SUCCEEDED[[:space:]]*$' "$work/spark-status"
printf 'SPARK_YARN_PASSED %s rows=alpha:5,beta:7\n' "$spark_app"
