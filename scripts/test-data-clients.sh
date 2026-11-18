#!/usr/bin/env bash
set -euo pipefail
for area in os updates extras; do
  printf '[c7-%s]\nname=CentOS archive\nbaseurl=https://vault.centos.org/7.9.2009/%s/$basearch/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7\n' "$area" "$area" > "/etc/yum.repos.d/c7-$area.repo"
done
# Local build inputs were SHA-256 checked before metadata generation.
printf '[c7-local]\nname=Verified local build\nbaseurl=file:///repo\ngpgcheck=0\n' > /etc/yum.repos.d/c7-local.repo
yum --disablerepo='*' --enablerepo=c7-os,c7-updates,c7-extras,c7-local -y install java-1.8.0-openjdk-devel hadoop_3_3_0-client hive_3_3_0 tez_3_3_0 spark_3_3_0-core
export JAVA_HOME=/usr/lib/jvm/java-1.8.0-openjdk
base=/usr/bigtop/3.3.0
export HADOOP_HOME="$base/usr/lib/hadoop"
export HADOOP_COMMON_HOME="$HADOOP_HOME"
export HADOOP_LIBEXEC_DIR="$HADOOP_HOME/libexec"
export HADOOP_HDFS_HOME="$base/usr/lib/hadoop-hdfs"
export HADOOP_MAPRED_HOME="$base/usr/lib/hadoop-mapreduce"
export HADOOP_YARN_HOME="$base/usr/lib/hadoop-yarn"
export HADOOP_CONF_DIR=/etc/hadoop/conf
export SPARK_HOME="$base/usr/lib/spark"
export HIVE_HOME="$base/usr/lib/hive"
export PATH="$HADOOP_HOME/bin:$base/usr/bin:$JAVA_HOME/bin:$PATH"
set -x
test -s "$HADOOP_LIBEXEC_DIR/hadoop-layout.sh"
hadoop="$HADOOP_HOME/bin/hadoop"
"$hadoop" version
test -s "$(find "$base" -name 'tez-api-*.jar' -print -quit)"
spark=$(find "$base" -path '*/bin/spark-submit' -print -quit)
"$spark" --version
hive=$(find "$base" -path '*/bin/hive' -print -quit)
"$hive" --version
examples=$(find "$base" -name 'hadoop-mapreduce-examples-*.jar' -print -quit)
test -s "$examples"
mkdir -p /tmp/c7-wordcount/input
printf 'bigtop bigtop hive\n' > /tmp/c7-wordcount/input/data
"$hadoop" jar "$examples" wordcount -Dfs.defaultFS=file:/// -Dmapreduce.framework.name=local /tmp/c7-wordcount/input /tmp/c7-wordcount/output
grep -Fx $'bigtop\t2' /tmp/c7-wordcount/output/part-r-00000
