#!/usr/bin/env bash
# Exercise management from the same offline archives with an isolated database.
set -euo pipefail
centos=centos@sha256:be65f488b7764ad3638f236b7b515b3678369a5124c47b8d32916d6487418ea4
mkdir -p lab-jdk17 management-evidence
tar xzf runtimes/jdk17.tar.gz -C lab-jdk17 --strip-components=1
docker load -i runtimes/postgres15-image.tar.gz
docker network create --internal management
password="Db!$(openssl rand -hex 24)"
echo "::add-mask::$password"
docker run -d --name management-db --network management --network-alias db.test.internal -e POSTGRES_PASSWORD="$password" -e POSTGRES_USER=ambari -e POSTGRES_DB=ambari offline/postgres:15
for host in server agent; do
  docker run -d --name "$host" --hostname "$host.test.internal" --network management --network-alias "$host.test.internal" \
    -v "$PWD/cluster:/project/cluster:ro" -v "$PWD/lab-jdk17:/opt/jdk17:ro" \
    -v "$PWD/runtimes/postgresql.jar:/opt/cluster/postgresql.jar:ro" -v "$PWD/yum-staging:/repo:ro" -v "$PWD/runtime-repo:/runtime:ro" "$centos" sleep infinity
  docker exec "$host" bash /project/cluster/install-offline.sh "ambari-$host" java-1.8.0-openjdk-devel
done
docker exec server cat /var/lib/ambari-server/resources/Ambari-DDL-Postgres-CREATE.sql | docker exec -i management-db psql -U ambari -d ambari -X -v ON_ERROR_STOP=1 >/dev/null
docker exec server ambari-server setup --jdbc-db=postgres --jdbc-driver=/opt/cluster/postgresql.jar
docker exec server ambari-server setup -s --java-home=/opt/jdk17 --ambari-java-home=/opt/jdk17 --stack-java-home=/usr/lib/jvm/java-1.8.0-openjdk --database=postgres --databasehost=db.test.internal --databaseport=5432 --databasename=ambari --databaseusername=ambari --databasepassword="$password" --postgresschema=public
docker exec server ambari-server start
docker exec agent ambari-agent reset server.test.internal
docker exec agent ambari-agent start
for i in {1..80}; do
  if docker exec server curl -fsS -u admin:admin 'http://localhost:8080/api/v1/hosts/agent.test.internal?fields=Hosts/host_state' > management-evidence/host.json &&
    jq -e '.Hosts.host_state=="HEALTHY"' management-evidence/host.json; then break; fi
  sleep 3
done
jq -e '.Hosts.host_state=="HEALTHY"' management-evidence/host.json
docker exec server curl -fsS -u admin:admin 'http://localhost:8080/api/v1/stacks/BIGTOP/versions/3.3.0?fields=Versions/stack_name,Versions/stack_version' > management-evidence/stack.json
jq -e '.Versions.stack_name=="BIGTOP" and .Versions.stack_version=="3.3.0"' management-evidence/stack.json
