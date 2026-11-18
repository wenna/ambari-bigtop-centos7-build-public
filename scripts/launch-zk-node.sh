#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in 1|2|3) node_id="$1" ;; *) exit 64 ;; esac
bash /scripts/verify-foundation.sh
mkdir -p /var/lib/zookeeper-probe
printf '%s\n' "$node_id" > /var/lib/zookeeper-probe/myid
cat > /tmp/zoo-probe.cfg <<'CONFIG'
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/var/lib/zookeeper-probe
clientPort=2181
4lw.commands.whitelist=ruok,srvr
server.1=zk1:2888:3888
server.2=zk2:2888:3888
server.3=zk3:2888:3888
CONFIG
chown -R zookeeper:zookeeper /var/lib/zookeeper-probe
exec runuser -u zookeeper -- java -Xms64m -Xmx128m -Dzookeeper.admin.enableServer=false \
  -cp '/usr/bigtop/3.3.0/usr/lib/zookeeper/*:/usr/bigtop/3.3.0/usr/lib/zookeeper/lib/*' \
  org.apache.zookeeper.server.quorum.QuorumPeerMain /tmp/zoo-probe.cfg
