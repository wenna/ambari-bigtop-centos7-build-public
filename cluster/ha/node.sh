#!/usr/bin/env bash
set -euo pipefail
source /project/cluster/ha/env.sh
action=$1
shift
case "$action" in
  configure)
    mkdir -p "$HADOOP_LOG_DIR" /run/ha /var/lib/ha
    python3 /project/cluster/ha/configure.py
    if [[ $(hostname -s) == master* ]]; then
      mkdir -p -m 0700 /root/.ssh
      ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -f /run/ha/fence-key
      ssh-keygen -A
      mkdir -p /run/sshd
      /usr/sbin/sshd -o PasswordAuthentication=no -o ChallengeResponseAuthentication=no -o PermitRootLogin=without-password -o UsePAM=yes
    fi
    ;;
  start)
    daemon=$1
    exec >>"$HADOOP_LOG_DIR/$daemon.log" 2>&1
    date -u
    case "$daemon" in
      zookeeper)
        zk_lib="$base/usr/lib/zookeeper"
        exec java -Xms32m -Xmx128m -XX:ActiveProcessorCount=2 -Dzookeeper.admin.enableServer=false \
          -cp "$zk_lib/*:$zk_lib/lib/*" org.apache.zookeeper.server.quorum.QuorumPeerMain /run/ha/zoo.cfg ;;
      namenode|datanode|journalnode|zkfc) exec hdfs "$daemon" ;;
      resourcemanager|nodemanager) exec yarn "$daemon" ;;
      *) exit 64 ;;
    esac
    ;;
  quorum)
    python3 - <<'PY'
import socket
roles = []
for host in ("worker1", "worker2", "worker3"):
    with socket.create_connection((host, 2181), 3) as sock:
        sock.settimeout(3)
        sock.sendall(b"srvr")
        lines = sock.makefile("r").read().splitlines()
        role = next(line[6:] for line in lines if line.startswith("Mode: "))
        print(host, role)
        roles.append(role)
assert sorted(roles) == ["follower", "follower", "leader"], roles
PY
    ;;
  pid)
    case "$1" in
      namenode) class=org.apache.hadoop.hdfs.server.namenode.NameNode ;;
      resourcemanager) class=org.apache.hadoop.yarn.server.resourcemanager.ResourceManager ;;
      *) exit 64 ;;
    esac
    # Match the exact Java main class, excluding JPS itself and unrelated roles.
    jps -l | awk -v class="$class" '$2 == class {print $1; count++} END {exit(count != 1)}'
    ;;
  port)
    timeout 2 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$1" "$2" ;;
  submit-rm-job)
    mkdir -p /run/ha/classes
    javac -cp "$(hadoop classpath --glob):$HADOOP_MAPRED_HOME/*" -d /run/ha/classes /project/cluster/ha/RmFailoverJob.java
    jar cf /run/ha/rm-job.jar -C /run/ha/classes .
    printf 'wait for promotion\n' | hdfs dfs -put - /ha-check/rm-input
    hadoop jar /run/ha/rm-job.jar RmFailoverJob
    ;;
  rm-job-state)
    id=$1
    report="$HADOOP_LOG_DIR/$id-$2.log"
    timeout 20 yarn application -status "$id" >"$report" || exit 1
    grep -Eq "^[[:space:]]*Application-Id[[:space:]]*:[[:space:]]*$id[[:space:]]*$" "$report"
    grep -Eq "^[[:space:]]*State[[:space:]]*:[[:space:]]*$2[[:space:]]*$" "$report"
    if [[ $2 == FINISHED ]]; then
      grep -Eq '^[[:space:]]*Final-State[[:space:]]*:[[:space:]]*SUCCEEDED[[:space:]]*$' "$report"
    fi
    cat "$report"
    ;;
  exec) exec "$@" ;;
  *) exit 64 ;;
esac
