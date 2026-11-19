#!/usr/bin/env bash
set -euo pipefail
server=bd01.lab.test
api() { docker exec "$server" curl -gsS --netrc-file /root/test.netrc "http://localhost:8080/api/v1$1"; }
diagnostics() {
  api '/clusters/zk/requests?fields=Requests/request_context,Requests/request_status' | jq -c '.items[]?.Requests'
  for id in $(api '/clusters/zk/requests' | jq -r '.items[]?.Requests.id'); do
    api "/clusters/zk/requests/$id/tasks?fields=Tasks/status,Tasks/role,Tasks/command,Tasks/stderr" | jq -r '.items[]?.Tasks | select(.status=="FAILED" or .status=="HOLDING_FAILED") | [.role,.command,(.stderr[-2500:])] | @tsv' | tail -6
  done
  docker exec "$server" bash -c 'tail -120 /var/log/ambari-server/ambari-server.log' | tail -60
}
trap 'if [[ $? != 0 ]]; then diagnostics; fi' EXIT
docker run -d --name yum-cache --network mgmt-net -v "$PWD/yum-staging:/srv/app:ro" -v "$PWD/runtime-repo:/srv/os:ro" -w /srv el7-ambari:installer python3 -m http.server 8000
for h in bd0{1,2,3}.lab.test; do
  docker exec "$h" bash -c 'mkdir -p /root/original-yum; mv /etc/yum.repos.d/*.repo /root/original-yum/; sed -e s,file:///repo,http://yum-cache:8000/app, -e s,file:///runtime,http://yum-cache:8000/os,g /root/original-yum/bundle.repo >/etc/yum.repos.d/checked.repo; ! rpm -q zookeeper_3_3_0'
done
printf '%s' '{"Blueprints":{"stack_name":"BIGTOP","stack_version":"3.3.0"},"host_groups":[{"name":"quorum","components":[{"name":"ZOOKEEPER_SERVER"},{"name":"ZOOKEEPER_CLIENT"}],"cardinality":"3"}]}' | docker exec -i "$server" bash -c 'umask 077; cat >/root/bp.json'
printf '%s' '{"blueprint":"zk-bp","host_groups":[{"name":"quorum","hosts":[{"fqdn":"bd01.lab.test"},{"fqdn":"bd02.lab.test"},{"fqdn":"bd03.lab.test"}]}]}' | docker exec -i "$server" bash -c 'umask 077; cat >/root/template.json'
docker exec "$server" bash /kit/ops/ambari-provision.sh http://localhost:8080 /root/test.netrc zk zk-bp /root/bp.json /root/template.json http://yum-cache:8000/app --timeout 750
for h in bd0{1,2,3}.lab.test; do docker exec "$h" rpm -q zookeeper_3_3_0; done
