#!/usr/bin/env bash
# Exercise the real SSH and sudo boundary on a disposable EL7 node.
set -euo pipefail
umask 077
tmp=$(mktemp -d)
node=access-test
fqdn=bd001.access.test
trap 'docker rm -f "$node" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
docker run -d --name "$node" --hostname "$fqdn" centos@sha256:be65f488b7764ad3638f236b7b515b3678369a5124c47b8d32916d6487418ea4 sleep infinity
docker exec -i "$node" bash -se <<'SH'
for r in os updates; do
  printf '[el7-%s]\nname=EL7\nbaseurl=https://vault.centos.org/7.9.2009/%s/$basearch/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7\n' "$r" "$r" > "/etc/yum.repos.d/el7-$r.repo"
done
yum -y --disablerepo='*' --enablerepo='el7-*' install sudo openssh-server
useradd --create-home --password '*' siteadmin
install -d -o siteadmin -g siteadmin -m 0700 /home/siteadmin/.ssh
printf 'Defaults:siteadmin !requiretty\nsiteadmin ALL=(root) NOPASSWD: /bin/bash -s\n' > /etc/sudoers.d/siteadmin
chmod 0440 /etc/sudoers.d/siteadmin
install -d -m 0755 /srv/kit/ops
printf 'PermitRootLogin no\nPasswordAuthentication no\nChallengeResponseAuthentication no\nUsePAM no\n' > /etc/ssh/sshd_config
ssh-keygen -A
/usr/sbin/sshd
SH
ssh-keygen -q -t ed25519 -N '' -f "$tmp/admin"
docker cp "$tmp/admin.pub" "$node:/home/siteadmin/.ssh/authorized_keys"
docker exec "$node" chown siteadmin:siteadmin /home/siteadmin/.ssh/authorized_keys
docker cp ops/ambari-action.sh "$node:/srv/kit/ops/ambari-action.sh"
docker exec "$node" bash -ec 'umask 022; cd /srv/kit; chown -R root:root .; chmod 0755 ops/ambari-action.sh; sha256sum ./ops/ambari-action.sh > SHA256SUMS; chmod -R go-w .'
read -r digest _ < <(docker exec "$node" sha256sum /srv/kit/SHA256SUMS)
address=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$node")
printf '%s %s\n' "$address" "$fqdn" | sudo -n tee -a /etc/hosts >/dev/null
printf '%s,%s %s\n' "$address" "$fqdn" "$(docker exec "$node" cat /etc/ssh/ssh_host_ed25519_key.pub)" > "$tmp/known_hosts"
printf 'slot,fqdn,rack,roles\nbd001,%s,rack1,ambari-server\n' "$fqdn" > "$tmp/hosts.csv"
cat > "$tmp/site.env" <<EOF
source "$PWD/ops/site.env.example"
SSH_IDENTITY_FILE="$tmp/deploy"
SSH_KNOWN_HOSTS="$tmp/known_hosts"
KIT_ROOT=/srv/kit
MANIFEST_SHA256=$digest
INVENTORY="$tmp/hosts.csv"
EOF
printf 'BOOTSTRAP_USER=siteadmin\nBOOTSTRAP_IDENTITY_FILE=%q\nGENERATE_DEPLOY_KEY=1\n' "$tmp/admin" > "$tmp/access.env"
bash ops/bootstrap-access.sh "$tmp/site.env" "$tmp/access.env" plan
test ! -e "$tmp/deploy"
for pass in 1 2; do bash ops/bootstrap-access.sh "$tmp/site.env" "$tmp/access.env" apply; done
[[ $(docker exec "$node" grep -c '^ssh-' /home/clusterops/.ssh/authorized_keys) == 1 ]]
mkdir "$tmp/review"
bash ops/deploy-cluster.sh "$tmp/site.env" ambari --export-actions "$tmp/review"
action=$(basename "$(grep -l 'getent ahosts' "$tmp/review/$fqdn/"*)")
remote=(ssh -n -i "$tmp/deploy" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$tmp/known_hosts" "clusterops@$fqdn")
"${remote[@]}" "sudo -n -- /usr/local/sbin/bigtop-ambari-action $action"
if "${remote[@]}" 'sudo -n /usr/bin/id'; then exit 1; fi
if "${remote[@]}" "sudo -n -- /usr/local/sbin/bigtop-ambari-action $(printf '%064d' 0)"; then exit 1; fi
python3 ops/generate-inventory.py --nodes 100 --domain site.test > "$tmp/web.csv"
python3 ops/web-install-values.py --inventory "$tmp/web.csv" --site production/site.example.json --web ops/web-install.example.json > "$tmp/web.txt"
grep -Fx 'bd100.site.test' "$tmp/web.txt"
grep -Fx 'NameNode — bd001.site.test' "$tmp/web.txt"
echo 'EL7 trusted bootstrap, repeat login, approved action, denied escalation and 100-host worksheet passed'
