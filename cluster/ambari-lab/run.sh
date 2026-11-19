#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
lab=cluster/ambari-lab
server=bd01.lab.test
repo=http://repo.lab.test:8081
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p provision-evidence
mapfile -t hosts < <(awk -F, 'NR>1 {print $2}' "$lab/hosts.csv")
[[ ${#hosts[@]} == 3 ]]
docker run -d --name lab-repo --hostname repo.lab.test --network mgmt-net --network-alias repo.lab.test \
  -v "$PWD/yum-staging:/www/app:ro" -v "$PWD/runtime-repo:/www/os:ro" -w /www \
  el7-ambari:installer python3 -m http.server 8081
query='%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n'
docker exec lab-repo bash -ec 'rpm -qp --qf "$1" /www/app/*.rpm' _ "$query" | sort > provision-evidence/release-rpms.tsv
ssh-keygen -q -t rsa -b 2048 -m PEM -N '' -f "$work/fencing"
for host in "${hosts[@]}"; do
  docker exec "$host" rpm -qa --qf "$query" | sort > "provision-evidence/$host-before.tsv"
  if grep -Eq '^(bigtop|hadoop|zookeeper|hive|tez|spark)([-_]|\s)' "provision-evidence/$host-before.tsv"; then
    echo "Unexpected preinstalled ecosystem RPM on $host" >&2; exit 1
  fi
  docker exec -i "$host" bash -se -- "$repo" <<'NODE'
set -uo pipefail
repo=$1
install -d -m 700 /root/stock-yum-repos
mv /etc/yum.repos.d/*.repo /root/stock-yum-repos/
cat > /etc/yum.repos.d/lab-os.repo <<EOF
[lab-os]
name=Frozen EL7 dependency repository
baseurl=$repo/os/
enabled=1
gpgcheck=1
EOF
curl --retry 5 -fsS "$repo/app/repodata/repomd.xml" -o /dev/null
rpm --import "$repo/os/keys/RPM-GPG-KEY-CentOS-7" "$repo/os/keys/RPM-GPG-KEY-EPEL-7"
yum -q -y install openssh-server openssh-clients psmisc nmap-ncat procps-ng util-linux rsync which hostname
ssh-keygen -A
/usr/sbin/sshd
mkdir -p /disk1/hdfs/data /disk1/yarn/local /data/bigtop
NODE
done
for host in bd01.lab.test bd02.lab.test; do
  docker cp "$work/fencing" "$host:/root/lab-fencing"
  docker cp "$work/fencing.pub" "$host:/root/lab-fencing.pub"
  docker exec -i "$host" bash -se <<'FENCE'
getent group hadoop >/dev/null || groupadd -r hadoop
id hdfs >/dev/null 2>&1 || useradd -m -r -g hadoop -s /bin/bash hdfs
home=$(getent passwd hdfs | cut -d: -f6)
install -d -o hdfs -g hadoop -m 0700 "$home/.ssh" /etc/security/hadoop/fencing
install -o hdfs -g hadoop -m 0600 /root/lab-fencing /etc/security/hadoop/fencing/id_rsa
install -o hdfs -g hadoop -m 0600 /root/lab-fencing.pub "$home/.ssh/authorized_keys"
rm -f /root/lab-fencing /root/lab-fencing.pub
FENCE
done
hive_pass="Hive!$(openssl rand -hex 24)"
echo "::add-mask::$hive_pass"
printf "CREATE ROLE hive_catalog LOGIN PASSWORD '%s';\nCREATE DATABASE hive OWNER hive_catalog;\n" "$hive_pass" |
  docker exec -i mgmt-db psql -X -v ON_ERROR_STOP=1 -U ambari -d ambari
printf '%s\n' "$hive_pass" | docker exec -i "$server" bash -ec 'umask 077; cat > /root/hive.pass'
unset hive_pass
jq '.tez_archive="/bigtop/apps/3.3.0/tez/tez.tar.gz" | .nameservice="lab" | .datanode_dirs=["/disk1/hdfs/data"] | .nm_local_dirs=["/disk1/yarn/local"] |
    .pg_url="jdbc:postgresql://pg.lab.test:5432/hive?sslmode=verify-full&sslrootcert=/etc/pki/bigtop/ca.crt" |
    .proxy_groups=["hadoop"] | .nm_memory_mb=1536 | .nm_vcores=2 | .task_memory_mb=512' production/site.example.json > "$work/site.json"
docker exec "$server" install -d -m 700 /root/lab
docker cp "$work/site.json" "$server:/root/lab/site.json"
docker cp "$lab/hosts.csv" "$server:/root/lab/hosts.csv"
docker cp production "$server:/root/lab/production"
docker cp ops "$server:/root/lab/ops"
docker exec "$server" python3 /root/lab/ops/ambari-blueprint.py --inventory /root/lab/hosts.csv --site /root/lab/site.json \
  --blueprint labbp --hive-password-file /root/hive.pass --out /root/lab/generated
docker exec -i "$server" python3 - /root/lab/generated/cluster.json <<'HEAPS'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
template = json.loads(path.read_text())
heaps = {
    'hadoop-env': {'hadoop_heapsize': '384', 'namenode_heapsize': '384', 'dtnode_heapsize': '256',
                   'namenode_opt_newsize': '64', 'namenode_opt_maxnewsize': '64'},
    'yarn-env': {'yarn_heapsize': '384', 'resourcemanager_heapsize': '384', 'nodemanager_heapsize': '384'},
    'mapred-env': {'jobhistory_heapsize': '384'},
    'zookeeper-env': {'zk_server_heapsize': '192'},
    'hive-env': {'hive.metastore.heapsize': '512', 'hive.heapsize': '512'},
}
template['configurations'].extend({kind: {'properties': values}} for kind, values in heaps.items())
path.write_text(json.dumps(template))
HEAPS
args=(http://localhost:8080 /root/test.netrc lab labbp /root/lab/generated/blueprint.json /root/lab/generated/cluster.json "$repo/app/")
docker exec "$server" bash /root/lab/ops/ambari-provision.sh "${args[@]}" --timeout 4200
docker exec -u hive bd03.lab.test bash -c '
  set -o pipefail
  export HADOOP_OPTS="${HADOOP_OPTS:-} -verbose:class"
  /usr/bigtop/3.3.0/usr/lib/hive/bin/schematool -dbType postgres -info 2>&1 |
    awk "/Loaded org.postgresql.Driver from/ { print; seen=1 } END { exit !seen }"
' | tee provision-evidence/hive-jdbc-class-source.txt
docker exec "$server" bash /root/lab/ops/ambari-provision.sh "${args[@]}" --check
docker cp "$lab/service-checks.sh" "$server:/root/lab/service-checks.sh"
docker exec "$server" bash /root/lab/service-checks.sh
for host in "${hosts[@]}"; do
  docker exec "$host" rpm -qa --qf "$query" | sort > "provision-evidence/$host-after.tsv"
done
bash "$lab/diagnostics.sh"
python3 "$lab/verify.py" "$lab/hosts.csv" provision-evidence
gateway=bd03.lab.test
docker exec "$gateway" install -d -m 0755 /tmp/ambari-workload
for source in ops/smoke-yarn.sh cluster/compute/ComputeCheck.java "$lab/workloads.sh"; do
  docker cp "$source" "$gateway:/tmp/ambari-workload/"
done
tag="${GITHUB_RUN_ID}_${GITHUB_RUN_ATTEMPT}"
[[ $tag =~ ^[0-9]+_[0-9]+$ ]]
docker exec -u hdfs "$gateway" bash /tmp/ambari-workload/workloads.sh "$tag" prepare
docker exec -u ambari-qa "$gateway" timeout 25m bash /tmp/ambari-workload/workloads.sh "$tag" |
  tee provision-evidence/workloads.log
count=$(docker exec -i mgmt-db psql -XAt -v ON_ERROR_STOP=1 -U ambari -d hive <<SQL
SELECT count(*) FROM "DBS" d JOIN "TBLS" t ON t."DB_ID"=d."DB_ID" WHERE d."NAME"='lab_$tag' AND t."TBL_NAME"='readings';
SQL
)
[[ $count == 1 ]]
printf 'POSTGRES_METASTORE_PASSED lab_%s.readings\n' "$tag" | tee -a provision-evidence/workloads.log
