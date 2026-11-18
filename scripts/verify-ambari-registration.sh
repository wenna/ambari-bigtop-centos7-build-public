#!/usr/bin/env bash
# Invoked on a dedicated GitHub runner with the checked pair of RPMs in artifacts/ambari.
set -euo pipefail
root=$(pwd)
mkdir -p runtimes/jdk17
curl -fsSL --retry 3 'https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.21%2B9/OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz' -o runtimes/jdk17.tar.gz
echo '8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711  runtimes/jdk17.tar.gz' | sha256sum -c -
tar xzf runtimes/jdk17.tar.gz -C runtimes/jdk17 --strip-components=1
centos=centos@sha256:be65f488b7764ad3638f236b7b515b3678369a5124c47b8d32916d6487418ea4
dbimage=postgres@sha256:e924003122c1459b25ebe2af0f5b8becc8b50ccee1354b304e5ba7ec1e0bb42c
network="ambari-$(cat /proc/sys/kernel/random/uuid)"
db="$network-db"; server="$network-server"; agent="$network-agent"
cleanup() {
  docker exec "$server" tail -n 60 /var/log/ambari-server/ambari-server.log || true
  docker exec "$agent" tail -n 50 /var/log/ambari-agent/ambari-agent.log || true
  docker rm -fv "$db" "$server" "$agent" >/dev/null || true
  docker network rm "$network" >/dev/null || true
}
docker network create "$network" >/dev/null
trap cleanup EXIT
pw="test!$(openssl rand -hex 18)"
echo "::add-mask::$pw"
docker run -d --name "$db" --network "$network" --network-alias db.test.internal -e POSTGRES_DB=ambari -e POSTGRES_USER=ambari -e POSTGRES_PASSWORD="$pw" "$dbimage" >/dev/null
for role in server agent; do
  node="$network-$role"
  docker run -d --name "$node" --network "$network" --network-alias "$role.test.internal" --hostname "$role.test.internal" -v "$root/artifacts/ambari:/rpms:ro" -v "$root/scripts/verify-ambari-install.sh:/verify.sh:ro" -v "$root/runtimes/jdk17:/opt/jdk17:ro" "$centos" sleep infinity >/dev/null
  docker exec -e AMBARI_INSTALL_ONLY=1 "$node" bash /verify.sh
  docker exec "$node" yum -q --disablerepo='*' --enablerepo=test-os,test-updates -y install java-1.8.0-openjdk-devel
done
docker exec "$server" /opt/jdk17/bin/java -version
docker exec "$server" cat /var/lib/ambari-server/resources/Ambari-DDL-Postgres-CREATE.sql | docker exec -i "$db" psql -X -v ON_ERROR_STOP=1 -U ambari -d ambari > artifacts/ambari-schema.log
docker exec "$server" ambari-server setup -s --java-home=/opt/jdk17 --ambari-java-home=/opt/jdk17 --stack-java-home=/usr/lib/jvm/java-1.8.0-openjdk --database=postgres --databasehost=db.test.internal --databaseport=5432 --databasename=ambari --databaseusername=ambari --databasepassword="$pw" --postgresschema=public
docker exec "$server" ambari-server start
docker exec "$agent" ambari-agent reset server.test.internal
docker exec "$agent" ambari-agent start
for attempt in {1..60}; do
  if docker exec "$server" curl -fsS -u admin:admin 'http://localhost:8080/api/v1/hosts/agent.test.internal?fields=Hosts/host_state' > artifacts/ambari-registration.json &&
     jq -e '.Hosts.host_name == "agent.test.internal" and .Hosts.host_state == "HEALTHY"' artifacts/ambari-registration.json; then
    docker exec "$server" curl -sS -u admin:admin 'http://localhost:8080/api/v1/stacks/BIGTOP/versions/3.3.0?fields=Versions/stack_name,Versions/stack_version' > artifacts/ambari-stack.json
    cat artifacts/ambari-stack.json
    jq -e '.Versions.stack_version == "3.3.0"' artifacts/ambari-stack.json
    exit 0
  fi
  sleep 5
done
echo 'Agent did not register as healthy' >&2
exit 1
