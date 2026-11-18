#!/usr/bin/env bash
# Invoked by start-cluster.sh as root, or as a role's Unix identity from systemd.
set -euo pipefail
here=/usr/local/libexec/bigtop-production
state=/var/lib/bigtop-production
die() { echo "$*" >&2; exit 1; }
if [[ $1 == install || $1 == inspect ]]; then
  stage=$2
  source "$stage/node.env"
else
  source "$here/node.env"
fi
[[ $(hostname -f) == "$FQDN" ]] || die "Host identity differs from inventory: $FQDN"
owner() { local key=OWNER_$1; [[ -v $key ]] || die "Role $1 absent from $SLOT"; printf '%s\n' "${!key}"; }
as_user() { local user=$1; shift; runuser -u "$user" -- "$@"; }
role_dirs() {
  case "$1" in
    namenode) echo "$STATE_DIR/namenode";;
    journalnode) echo "$STATE_DIR/journalnode";;
    datanode) printf '%s\n' "${DATANODE_DIRS[@]}";;
    nodemanager) printf '%s\n' "${NM_LOCAL_DIRS[@]}" "$LOG_DIR/yarn/containers";;
    zookeeper) echo "$STATE_DIR/zookeeper";;
  esac
}
active_env() {
  source /etc/hadoop/conf/bigtop-env.sh
  export HADOOP_LOG_DIR="$LOG_DIR/$(id -un)" HADOOP_PID_DIR="$RUN_DIR/$(id -un)"
}
case "$1" in
  inspect)
    # Test all hosts before writing any service state. Refuse a different managed snapshot.
    [[ ! -e $state/snapshot || $(cat "$state/snapshot") == "$3" ]] || die "Changed snapshot on $FQDN; plan an explicit configuration migration"
    for role in "${ROLES[@]}"; do
      user=$(owner "$role"); id "$user" >/dev/null
      [[ $(id -u "$user") != 0 ]] || die "Root service identities are disallowed"
      if [[ $4 == fresh ]]; then
        case "$role" in
          zookeeper) port=2181;; journalnode) port=8485;; namenode) port=8020;;
          datanode) port=9866;; nodemanager) port=8042;; resourcemanager) port=8088;;
          jobhistory) port=10020;; metastore) port=9083;; hiveserver2) port=10000;;
          sparkhistory) port=18080;; *) port=0;;
        esac
        if [[ $port != 0 ]] && ss -lnt | awk -v p=":$port" '$4 ~ (p "$"){found=1} END{exit !found}'; then
          die "Port $port in use at $FQDN; inspect existing service ownership"
        fi
        while IFS= read -r dir; do
          [[ ! -e $dir ]] && continue
          [[ -d $dir && ! -L $dir ]] || die "Invalid data path $dir"
          entry=$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)
          if [[ $role == zookeeper && -f $dir/myid ]] && cmp -s "$dir/myid" "$stage/tree$dir/myid"; then
            entry=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name myid -print -quit)
          fi
          [[ -z $entry ]] || die "Unmanaged or partial state at $dir; inspect and recover before deployment"
        done < <(role_dirs "$role")
      elif [[ $4 == managed ]]; then
        case "$role" in
          namenode|journalnode|datanode)
            while IFS= read -r dir; do
              if [[ $role == journalnode ]]; then dir="$dir/$NAMESERVICE"; fi
              grep -Fxq "clusterID=$5" "$dir/current/VERSION" || die "Missing or mismatched cluster ID in $dir"
            done < <(role_dirs "$role");;
          zookeeper) [[ -d $STATE_DIR/zookeeper/version-2 ]] || die "Missing managed ZooKeeper database";;
        esac
      fi
    done
    if [[ $SLOT == bd0[12] ]]; then
      as_user "$HDFS_USER" test -r "$FENCE_KEY" || die "Fence key unavailable"
      peer=${HOSTS[0]}; [[ $SLOT == bd02 ]] || peer=${HOSTS[1]}
      as_user "$HDFS_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 \
        -i "$FENCE_KEY" "$FENCE_USER@$peer" 'command -v fuser && command -v nc' >/dev/null
    fi
    if [[ $SLOT == bd09 || $SLOT == bd10 ]]; then
      for path in "$PG_CA" "$HMS_KEYSTORE" /opt/cluster/postgresql.jar; do as_user "$HIVE_USER" test -r "$path"; done
      [[ -f $HMS_KEYSTORE && $(stat -Lc %u "$HMS_KEYSTORE") == "$(id -u "$HIVE_USER")" ]] || die "Check Hive keystore ownership"
      (( (8#$(stat -Lc %a "$HMS_KEYSTORE") & 077) == 0 )) || die "Hive keystore must be private"
    fi
    ;;
  install)
    mkdir -p "$here" "$state"
    # Guard initial config installation, including the ensemble member ID.
    while IFS= read -r -d '' src; do
      target=${src#"$stage/tree"}
      if [[ -e $target ]]; then
        if cmp -s "$src" "$target"; then continue; fi
        [[ $target != "$STATE_DIR/zookeeper/myid" && ! -e "$state/snapshot" ]] || die "Unexpected configuration change $target"
        mkdir -p "$state/original$(dirname "$target")"
        cp -pL --no-clobber "$target" "$state/original$target"
      fi
      # RPM conf directories may be alternatives symlinks. Update the resolved file.
      dest=$(readlink -m "$target")
      install -D -m "$(stat -c %a "$src")" "$src" "$dest"
    done < <(find "$stage/tree" -type f -print0)
    install -m 0755 "$stage/node-service.sh" "$here/node-service.sh"
    install -m 0644 "$stage/node.env" "$here/node.env"
    source /etc/hadoop/conf/bigtop-env.sh
    if [[ $SLOT == bd09 || $SLOT == bd10 ]]; then
      "$JAVA_HOME/bin/javac" -cp "$HADOOP_HOME/*:$HADOOP_HOME/lib/*" -d "$here" "$stage/CatalogState.java"
    fi
    tmpfiles=/etc/tmpfiles.d/bigtop-production.conf
    : >"$tmpfiles"
    for role in "${ROLES[@]}"; do
      user=$(owner "$role")
      install -d -o "$user" -m 0750 "$LOG_DIR/$user" "$RUN_DIR/$user"
      echo "d $RUN_DIR/$user 0750 $user - -" >>"$tmpfiles"
      while IFS= read -r dir; do install -d -o "$user" -m 0750 "$dir"; done < <(role_dirs "$role")
      unit=/etc/systemd/system/bigtop-"$role".service
      cat >"$unit" <<UNIT
[Unit]
Description=Apache Bigtop $role ($NAMESERVICE)
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$STATE_DIR $LOG_DIR $(role_dirs "$role" | xargs)
[Service]
Type=simple
User=$user
ExecStart=$here/node-service.sh daemon $role
Restart=on-failure
RestartSec=10s
TimeoutStopSec=120
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT
    done
    sort -u -o "$tmpfiles" "$tmpfiles"
    systemctl daemon-reload
    printf '%s\n' "$3" >"$state/snapshot"
    ;;
  daemon)
    [[ $(id -un) == "$(owner "$2")" ]] || die "Wrong service identity"
    active_env
    case "$2" in
      zookeeper)
        zk=/usr/bigtop/3.3.0/usr/lib/zookeeper
        exec "$JAVA_HOME/bin/java" -Dzookeeper.log.dir="$HADOOP_LOG_DIR" -cp "$zk/*:$zk/lib/*:/etc/zookeeper/conf" org.apache.zookeeper.server.quorum.QuorumPeerMain /etc/zookeeper/conf/zoo.cfg;;
      namenode|datanode|journalnode|zkfc) exec hdfs "$2";;
      resourcemanager|nodemanager) exec yarn "$2";;
      jobhistory) exec mapred historyserver;;
      metastore) export HIVE_CONF_DIR=/etc/hive/metastore; exec "$HIVE_HOME/bin/hive" --service metastore -p 9083;;
      hiveserver2) export HIVE_CONF_DIR=/etc/hive/conf; exec "$HIVE_HOME/bin/hiveserver2";;
      sparkhistory) exec "$SPARK_HOME/bin/spark-class" org.apache.spark.deploy.history.HistoryServer;;
    esac;;
  start) owner "$2" >/dev/null; systemctl enable "bigtop-$2.service"; systemctl start "bigtop-$2.service";;
  client)
    # Every storage mutation runs as the designated service account.
    user=$2; shift 2
    case "$user" in "$HDFS_USER"|"$YARN_USER"|"$MAPRED_USER"|"$HIVE_USER"|"$SPARK_USER") ;; *) exit 64;; esac
    exec runuser -u "$user" -- "$here/node-service.sh" command "$@";;
  command) shift; active_env; exec "$@";;
  schema)
    exec 9>"$state/schema.lock"; flock -n 9 || die "Concurrent schema operation"
    as_user "$HIVE_USER" "$here/node-service.sh" catalog;;
  catalog)
    active_env
    export HIVE_CONF_DIR=/etc/hive/metastore
    source "$HIVE_CONF_DIR/hive-env.sh"
    db=$("$JAVA_HOME/bin/java" -cp "$here:$HADOOP_CONF_DIR:/opt/cluster/postgresql.jar:$HADOOP_HOME/*:$HADOOP_HOME/lib/*" CatalogState)
    case "$db" in
      empty) "$HIVE_HOME/bin/schematool" -dbType postgres -initSchema;;
      existing) ;;
      *) die "PostgreSQL database contains a partial or unrelated schema";;
    esac
    "$HIVE_HOME/bin/schematool" -dbType postgres -info
    "$HIVE_HOME/bin/schematool" -dbType postgres -validate;;
  storage)
    active_env
    dfs() { hdfs dfs "$@"; }
    directory() { dfs -mkdir -p "$1"; dfs -chown "$2" "$1"; dfs -chmod "$3" "$1"; }
    directory /tmp "$HDFS_USER" 1777
    directory /tmp/logs "$YARN_USER" 1777
    directory /tmp/hadoop-yarn/staging "$MAPRED_USER" 1777
    directory /tmp/hadoop-yarn/staging/history/done_intermediate "$MAPRED_USER" 1777
    directory /tmp/hadoop-yarn/staging/history/done "$MAPRED_USER" 0750
    directory /user/hive/warehouse "$HIVE_USER" 0770
    directory /spark-history "$SPARK_USER" 1777
    for user in "$HIVE_USER" "$SPARK_USER" "$MAPRED_USER" "$YARN_USER"; do directory "/user/$user" "$user" 0750; done
    archive="$TEZ_HOME/lib/tez.tar.gz"
    test -s "$archive"
    dfs -mkdir -p "$(dirname "$TEZ_ARCHIVE")"
    if ! dfs -test -e "$TEZ_ARCHIVE"; then dfs -put "$archive" "$TEZ_ARCHIVE"; fi
    expected=$(sha256sum "$archive" | awk '{print $1}')
    actual=$(dfs -cat "$TEZ_ARCHIVE" | sha256sum | awk '{print $1}')
    [[ $expected == "$actual" ]] || die "Existing Tez archive differs; review explicitly"
    dfs -chmod 0644 "$TEZ_ARCHIVE";;
  *) exit 64;;
esac
