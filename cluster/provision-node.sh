#!/usr/bin/env bash
# Usage: sudo bash provision-node.sh /srv/bigtop-kit namenode zkfc journalnode
# Use --chrony-only for time setup or --ambari-only agent|server for Ambari bootstrap.
# Use the release directory as a read-only local snapshot; site configuration lives elsewhere.
set -euo pipefail
kit=$(realpath "${1:?provide extracted delivery directory}")
shift
(( $# > 0 )) || { echo "Supply inventory roles, --chrony-only or --ambari-only agent|server" >&2; exit 64; }
[[ $EUID == 0 && $kit =~ ^/[-_.a-zA-Z0-9/]+$ ]]
[[ $(uname -m) == x86_64 ]]
grep -Fx 'CentOS Linux release 7.9.2009 (Core)' /etc/centos-release
mountpoint -q /proc
(cd "$kit" && sha256sum --quiet -c SHA256SUMS)
management_only=0
if [[ $1 == --ambari-only ]]; then
  [[ $# == 2 ]] || exit 64
  source "$kit/ops/ambari-bootstrap.sh"
  ambari_packages "$2"
  ambari_guard ''
  ambari_repo "$kit" inspect ''
  management_only=1
else
  pkgs=(ambari-agent bigtop-select bigtop-utils java-1.8.0-openjdk-devel hadoop_3_3_0-client tez_3_3_0 spark_3_3_0-core openssh-clients openssh-server psmisc nmap-ncat chrony)
  for role; do
    case "$role" in
      ambari-server) pkgs+=(ambari-server) ;;
      zookeeper) pkgs+=(zookeeper_3_3_0-server) ;;
      namenode|zkfc|journalnode|datanode) pkgs+=("hadoop_3_3_0-hdfs-$role") ;;
      resourcemanager|nodemanager) pkgs+=("hadoop_3_3_0-yarn-$role") ;;
      jobhistory) pkgs+=(hadoop_3_3_0-mapreduce-historyserver) ;;
      metastore) pkgs+=(hive_3_3_0-metastore hive_3_3_0-jdbc) ;;
      hiveserver2) pkgs+=(hive_3_3_0-server2 hive_3_3_0-jdbc) ;;
      sparkhistory) pkgs+=(spark_3_3_0-history-server) ;;
      gateway|client) pkgs+=(hive_3_3_0 hive_3_3_0-jdbc) ;;
      ambari-agent) ;; # common package
      --chrony-only) [[ $# == 1 ]] || exit 64 ;;
      *) echo "Unknown installation role: $role" >&2; exit 64 ;;
    esac
  done
fi
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
if [[ $1 == --chrony-only ]]; then
  yum -y --setopt="reposdir=$repos" --disablerepo='*' --enablerepo=checked-os install chrony
  exit
fi
options=()
if (( management_only )); then
  allowed=ambari-agent; [[ $2 != server ]] || allowed+=,ambari-server
  options=(--noplugins "--setopt=checked-app.includepkgs=$allowed" --setopt=metadata_expire=0)
fi
yum -y "${options[@]}" --setopt="reposdir=$repos" --disablerepo='*' --enablerepo=checked-app,checked-os install "${pkgs[@]}"
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
rpm -q "${pkgs[@]}"
if (( management_only )); then ambari_repo "$kit" install ''; fi
