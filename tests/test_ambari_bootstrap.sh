#!/usr/bin/env bash
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
source "$project/ops/ambari-bootstrap.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
rpm() { [[ $1 == -qa ]]; printf '%s\n' "${fixture_pkgs:-bash}"; }
systemctl() { [[ $1 == list-unit-files || $1 == list-units ]]; printf '%s\n' "${fixture_units:-}"; }
ambari_guard "$tmp"
for fixture_pkgs in hadoop_3_3_0-client spark_3_3_0-core hdp-select bigtop-utils hive-metastore; do
    if ambari_guard "$tmp"; then echo "Accepted $fixture_pkgs" >&2; exit 1; fi
done
unset fixture_pkgs
fixture_units='bigtop-journalnode.service disabled'
if ambari_guard "$tmp"; then echo 'Accepted disabled legacy unit' >&2; exit 1; fi
unset fixture_units
mkdir -p "$tmp/var/lib/bigtop-production"
if ambari_guard "$tmp"; then echo 'Accepted legacy deployment state' >&2; exit 1; fi
for role in agent server; do
    ambari_packages "$role"
    [[ " ${pkgs[*]} " == *' ambari-agent '* && " ${pkgs[*]} " == *' java-1.8.0-openjdk-devel '* ]]
    if [[ $role == agent ]]; then [[ " ${pkgs[*]} " != *' ambari-server '* ]]; else [[ " ${pkgs[*]} " == *' ambari-server '* ]]; fi
    for pkg in "${pkgs[@]}"; do [[ ! $pkg =~ ^(bigtop|hadoop|spark|hive|tez|zookeeper) ]]; done
done
mkdir -p "$tmp/etc/yum.repos.d"
ambari_repo /opt/kit inspect "$tmp"
conf=$tmp/etc/yum.repos.d/bigtop-ambari-offline.repo
[[ ! -e $conf ]]
ambari_repo /opt/kit install "$tmp"
ambari_repo /opt/kit install "$tmp"
grep -Fxq 'baseurl=file:///opt/kit/runtime-repo/' "$conf"
grep -Fxq 'baseurl=file:///opt/kit/yum-staging/' "$conf"
if ambari_repo /other/kit install "$tmp"; then echo 'Overwrote conflicting repository' >&2; exit 1; fi
printf '[bigtop-runtime-local]\n' > "$tmp/etc/yum.repos.d/foreign.repo"
if ambari_repo /opt/kit inspect "$tmp"; then echo 'Accepted conflicting repository ID' >&2; exit 1; fi
echo 'Management package boundary and legacy host guards passed'

cat > "$tmp/hosts.csv" <<EOF
slot,fqdn,rack,roles
a,worker.site.test,west,datanode
b,mgmt.site.test,east,ambari-server
EOF
cat > "$tmp/site.env" <<EOF
INVENTORY='$tmp/hosts.csv'
SSH_USER=clusterops
KIT_ROOT=/opt/kit
MANIFEST_SHA256=$(printf 'a%.0s' {1..64})
NTP_SOURCES=clock.site.test
MAX_CLOCK_OFFSET_SECONDS=0.1
PG_HOST=pg.site.test
PG_PORT=5432
PG_DATABASE=ambari
PG_USER=ambari
PG_PASSWORD_FILE=/etc/secret
PG_CA=/etc/cert
API_BASE=http://localhost:8080
API_NETRC=/etc/netrc
EOF
trace=$tmp/ssh.trace
export trace
ssh() {
    echo "$*" >> "$trace"
    if [[ ${!#} == *'bash -s '* ]]; then cat >> "$trace"; fi
    if [[ ${block_ip:-} && "$*" == *"@$block_ip "* ]]; then return 65; fi
    if [[ ${block_host:-} && "$*" == *"@$block_host "* && ${!#} == *ambari-bootstrap.sh* ]]; then return 65; fi
}
export -f ssh
sed 's/^SSH_USER=clusterops$/SSH_USER=root/' "$tmp/site.env" > "$tmp/root.env"
if bash "$project/ops/deploy-cluster.sh" "$tmp/root.env" ambari; then echo "Accepted root SSH login" >&2; exit 1; fi
[[ ! -s $trace ]]
bash "$project/ops/deploy-cluster.sh" "$tmp/site.env" ambari
grep -F 'test "$(id -u)" -gt 0 && sudo -n --' "$trace" >/dev/null
grep -E 'worker.site.test .*provision-node.sh .*--ambari-only agent' "$trace"
grep -E 'mgmt.site.test .*provision-node.sh .*--ambari-only server' "$trace"
grep -E 'mgmt.site.test .*manage-server.sh verify .*worker.site.test mgmt.site.test' "$trace"
[[ $(grep -c 'manage-server.sh agent' "$trace") == 2 ]]
if grep -E 'start-cluster|node-service|provision-node.sh .* (datanode|ambari-server)' "$trace"; then exit 1; fi
export block_host=mgmt.site.test
: > "$trace"
if bash "$project/ops/deploy-cluster.sh" "$tmp/site.env" ambari; then echo 'Accepted a legacy fleet' >&2; exit 1; fi
if grep -E 'provision-node|manage-server' "$trace"; then echo 'Mutated a partially checked fleet' >&2; exit 1; fi
unset block_host
printf 'slot,address\na,192.0.2.11\nb,192.0.2.12\n' > "$tmp/bootstrap.csv"
printf "PREPARE_OS=1\nBOOTSTRAP_INVENTORY='%s/bootstrap.csv'\n" "$tmp" >> "$tmp/site.env"
export block_ip=192.0.2.12
: > "$trace"
if bash "$project/ops/deploy-cluster.sh" "$tmp/site.env" ambari; then echo 'Prepared a legacy fleet' >&2; exit 1; fi
if grep -E 'prepare-host-node|provision-node|manage-server' "$trace"; then echo 'Changed OS before IP guard completed' >&2; exit 1; fi
grep -q 'clusterops@192.0.2.11' "$trace"
unset block_ip
: > "$trace"
bash "$project/ops/deploy-cluster.sh" "$tmp/site.env" ambari
grep -Eq 'clusterops@192.0.2.11 .* inspect worker.site.test' "$trace"
grep -Eq 'clusterops@192.0.2.12 .* apply mgmt.site.test' "$trace"
grep -Eq 'mgmt.site.test .*manage-server.sh verify' "$trace"
echo 'Ambari orchestration and fleet-wide refusal passed'
