#!/usr/bin/env bash
set -euo pipefail
centos=centos@sha256:be65f488b7764ad3638f236b7b515b3678369a5124c47b8d32916d6487418ea4
secret=$(mktemp -d); chmod 0700 "$secret"
mkdir -p certs lab-jdk17 management-evidence
tar xzf runtimes/jdk17.tar.gz -C lab-jdk17 --strip-components=1
docker load -i runtimes/postgres15-image.tar.gz
docker network create --internal mgmt-net
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=EL7 test root' -keyout "$secret/ca.key" -out certs/ca.crt 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=pg.lab.test' -keyout "$secret/server.key" -out "$secret/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:pg.lab.test\nextendedKeyUsage=serverAuth\n' > "$secret/server.ext"
openssl x509 -req -days 1 -in "$secret/server.csr" -CA certs/ca.crt -CAkey "$secret/ca.key" -set_serial 23 -extfile "$secret/server.ext" -out "$secret/server.crt"
uid=$(docker run --rm offline/postgres:15 id -u postgres)
sudo chown "$uid" "$secret/server.key"
password="Db!$(openssl rand -hex 24)"
echo "::add-mask::$password"
docker run -d --name mgmt-db --hostname pg.lab.test --network mgmt-net --network-alias pg.lab.test \
  -v "$secret/server.key:/var/tmp/tls.key:ro" -v "$secret/server.crt:/var/tmp/tls.crt:ro" \
  -e POSTGRES_DB=ambari -e POSTGRES_USER=ambari -e POSTGRES_PASSWORD="$password" \
  offline/postgres:15 -c ssl=on -c ssl_key_file=/var/tmp/tls.key -c ssl_cert_file=/var/tmp/tls.crt
docker create --name mgmt-install --network none -v "$PWD:/project:ro" -v "$PWD/yum-staging:/repo:ro" -v "$PWD/runtime-repo:/runtime:ro" "$centos" bash /project/cluster/install-offline.sh ambari-server ambari-agent java-1.8.0-openjdk-devel
docker start -a mgmt-install
[[ $(docker inspect -f '{{.State.ExitCode}}' mgmt-install) == 0 ]]
docker commit mgmt-install el7-ambari:installer >/dev/null
hosts=()
count=${AGENT_COUNT:-10}
[[ $count =~ ^[1-9][0-9]*$ ]]
for ((n=1; n<=count; n++)); do
  printf -v host 'bd%02d.lab.test' "$n"
  hosts+=("$host")
  docker run -d --init --ulimit nofile=131072:131072 --ulimit nproc=131072:131072 --ulimit core=-1:-1 --name "$host" --hostname "$host" --network mgmt-net -v "$PWD/ops:/kit/ops:ro" -v "$PWD/runtimes:/kit/runtimes:ro" \
    -v "$PWD/lab-jdk17:/opt/jdk17:ro" -v "$PWD/runtimes/postgresql.jar:/opt/cluster/postgresql.jar:ro" -v "$PWD/certs:/etc/pki/bigtop:ro" el7-ambari:installer sleep infinity
done
server=${hosts[0]}
printf '%s\n' "$password" | docker exec -i "$server" bash -c 'umask 077; cat > /root/pg.pass'
docker exec "$server" bash -c 'umask 077; echo "machine localhost login admin password admin" > /root/test.netrc'
if [[ ${NATIVE_STACK:-0} == 1 ]]; then docker exec "$server" python3 /kit/ops/ambari-stack-el7.py; fi
for pass in 1 2; do
  docker exec "$server" bash /kit/ops/manage-server.sh setup /kit pg.lab.test 5432 ambari ambari /root/pg.pass /etc/pki/bigtop/ca.crt
  for host in "${hosts[@]}"; do docker exec "$host" bash /kit/ops/manage-server.sh agent "$server"; done
  docker exec "$server" bash /kit/ops/manage-server.sh verify http://localhost:8080 /root/test.netrc "${hosts[@]}"
done
docker exec "$server" curl -fsS --netrc-file /root/test.netrc 'http://localhost:8080/api/v1/hosts?fields=Hosts/host_state' > management-evidence/hosts.json
jq -e --argjson count "$count" '(.items|length)==$count and all(.items[]; .Hosts.host_state=="HEALTHY")' management-evidence/hosts.json
