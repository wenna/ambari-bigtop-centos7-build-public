#!/usr/bin/env bash
# Usage: sudo bash provision-node.sh /srv/bigtop-kit bd01
# Use the release directory as a read-only local snapshot; site configuration lives elsewhere.
set -euo pipefail
kit=$(realpath "${1:?provide extracted delivery directory}")
slot=${2:?provide inventory slot bd01 through bd10}
[[ $EUID == 0 && $kit =~ ^/[-_.a-zA-Z0-9/]+$ ]]
[[ $(uname -m) == x86_64 ]]
grep -Fx 'CentOS Linux release 7.9.2009 (Core)' /etc/centos-release
mountpoint -q /proc
case "$slot" in
  bd01) services=(zookeeper_3_3_0-server hadoop_3_3_0-hdfs-journalnode hadoop_3_3_0-hdfs-namenode hadoop_3_3_0-hdfs-zkfc) ;;
  bd02) services=(zookeeper_3_3_0-server hadoop_3_3_0-hdfs-journalnode hadoop_3_3_0-hdfs-namenode hadoop_3_3_0-hdfs-zkfc hadoop_3_3_0-yarn-resourcemanager) ;;
  bd03) services=(zookeeper_3_3_0-server hadoop_3_3_0-hdfs-journalnode hadoop_3_3_0-yarn-resourcemanager hadoop_3_3_0-mapreduce-historyserver) ;;
  bd0[4-8]) services=(hadoop_3_3_0-hdfs-datanode hadoop_3_3_0-yarn-nodemanager) ;;
  bd09) services=(ambari-server hive_3_3_0-metastore hive_3_3_0-server2 hive_3_3_0-jdbc) ;;
  bd10) services=(hive_3_3_0-metastore hive_3_3_0-server2 hive_3_3_0-jdbc spark_3_3_0-history-server) ;;
  *) echo "Invalid slot $slot" >&2; exit 64 ;;
esac
(cd "$kit" && sha256sum --quiet -c SHA256SUMS)
rpm --import "$kit/runtime-repo/keys/RPM-GPG-KEY-CentOS-7" "$kit/runtime-repo/keys/RPM-GPG-KEY-EPEL-7"
repos=$(mktemp -d)
trap 'rm -f "$repos/cluster.repo"; rmdir "$repos"' EXIT
cat > "$repos/cluster.repo" <<EOF
[checked-app]
name=Checked local application snapshot
baseurl=file://$kit/yum-staging/
gpgcheck=0
[checked-os]
name=Signed local OS snapshot
baseurl=file://$kit/runtime-repo/
gpgcheck=1
EOF
pkgs=(ambari-agent bigtop-select bigtop-utils java-1.8.0-openjdk-devel hadoop_3_3_0-client tez_3_3_0 spark_3_3_0-core openssh-clients openssh-server psmisc nmap-ncat chrony)
yum -y --setopt="reposdir=$repos" --disablerepo='*' --enablerepo=checked-app,checked-os install "${pkgs[@]}" "${services[@]}"
mkdir -p /opt/cluster
if [[ ! -e /opt/jdk17 ]]; then
  jdk_stage=$(mktemp -d /opt/cluster/jdk17-install.XXXXXX)
  tar xzf "$kit/runtimes/jdk17.tar.gz" --strip-components=1 -C "$jdk_stage"
  "$jdk_stage/bin/java" -version
  chmod 0755 "$jdk_stage"
  mv -Tn "$jdk_stage" /opt/jdk17
fi
/opt/jdk17/bin/java -version 2>&1 | grep '17.0.21'
if [[ -e /opt/cluster/postgresql.jar ]]; then
  cmp "$kit/runtimes/postgresql.jar" /opt/cluster/postgresql.jar
else
  install -m 0644 "$kit/runtimes/postgresql.jar" /opt/cluster/postgresql.jar
fi
rpm -q "${pkgs[@]}" "${services[@]}"
