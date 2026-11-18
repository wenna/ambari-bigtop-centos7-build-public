#!/usr/bin/env bash
# Run as a test user on the gateway. HDFS outputs are retained for inspection.
set -euo pipefail
: "${HDFS_TEST_PARENT:?set an existing absolute HDFS directory writable by the test user}"
[[ "$HDFS_TEST_PARENT" == /* && "$HDFS_TEST_PARENT" != "/" ]]
base=/usr/bigtop/3.3.0/usr/lib
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-1.8.0-openjdk}
export HADOOP_CONF_DIR=${HADOOP_CONF_DIR:-/etc/hadoop/conf}
export YARN_CONF_DIR=${YARN_CONF_DIR:-$HADOOP_CONF_DIR}
export HADOOP_HOME=$base/hadoop HADOOP_COMMON_HOME=$base/hadoop
export HADOOP_LIBEXEC_DIR=$base/hadoop/libexec HADOOP_HDFS_HOME=$base/hadoop-hdfs
export HADOOP_YARN_HOME=$base/hadoop-yarn HADOOP_MAPRED_HOME=$base/hadoop-mapreduce
export PATH="$JAVA_HOME/bin:$HADOOP_HOME/bin:$HADOOP_HDFS_HOME/bin:$HADOOP_YARN_HOME/bin:$PATH"
fs=$(hdfs getconf -confKey fs.defaultFS)
[[ "$fs" == hdfs://* ]] || { echo "Expected HDFS, found $fs" >&2; exit 1; }
examples=$(find "$HADOOP_MAPRED_HOME" -type f -name 'hadoop-mapreduce-examples-*.jar' -print -quit)
test -s "$examples"
run="${HDFS_TEST_PARENT%/}/smoke-$(cat /proc/sys/kernel/random/uuid)"
echo "Evidence will remain at $fs$run"
hdfs dfs -mkdir "$run"
hdfs dfs -mkdir "$run/input"
printf 'bigtop bigtop hive\n' | hdfs dfs -put - "$run/input/data"
expected=$(printf 'bigtop bigtop hive\n' | sha256sum)
actual=$(hdfs dfs -cat "$run/input/data" | sha256sum)
test "$actual" = "$expected"
hadoop jar "$examples" wordcount -Dmapreduce.framework.name=yarn -Dmapreduce.job.reduces=1 "$run/input" "$run/output"
result=$(hdfs dfs -cat "$run/output/part-r-00000")
test "$result" = $'bigtop\t2\nhive\t1'
printf 'Verified HDFS round-trip and YARN WordCount:\n%s\n' "$result"
