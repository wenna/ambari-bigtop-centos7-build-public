#!/usr/bin/env bash
set -euo pipefail
mkdir -p evidence
docker create --name install --network none -v "$PWD:/project:ro" -v "$PWD/yum-staging:/repo:ro" -v "$PWD/runtime-repo:/runtime:ro" "$CENTOS" bash /project/cluster/install-offline.sh
docker start -a install
[[ $(docker inspect -f '{{.State.ExitCode}}' install) == 0 ]]
docker commit install el7-bigtop:lab >/dev/null
docker rm install >/dev/null
docker network create --internal bdnet
docker load -i runtimes/postgres15-image.tar.gz
export HIVE_DB_PASSWORD=$(openssl rand -hex 24)
echo "::add-mask::$HIVE_DB_PASSWORD"
docker run -d --name db --network bdnet -e HIVE_DB_PASSWORD -e POSTGRES_PASSWORD="$HIVE_DB_PASSWORD" -e POSTGRES_DB=hive -e POSTGRES_USER=hive offline/postgres:15
for host in master1 master2 worker1 worker2 worker3; do
  extra=()
  if [[ $host == master1 ]]; then extra=(-e HIVE_DB_PASSWORD); fi
  docker run -d --init --hostname "$host" --name "$host" --network bdnet \
    -v "$PWD/cluster:/project/cluster:ro" -v "$PWD/evidence:/evidence" \
    -v "$PWD/runtimes/postgresql.jar:/opt/cluster/postgresql.jar:ro" \
    "${extra[@]}" el7-bigtop:lab sleep infinity
done
