#!/usr/bin/env bash
# Disposable private network on a dedicated GitHub-hosted runner.
set -euo pipefail
umask 077
s=$(mktemp -d)
workspace=$PWD
cd "$s"
sudo apt-get -qq update
sudo apt-get -qy install --no-install-recommends qemu-system-x86 qemu-utils dnsmasq-base chrony cloud-image-utils genisoimage
curl -fLsS --retry 3 https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-2211.qcow2c -o base
echo '8540fcfb73b41d2322644b7c4301b52cb1753c6daf9539866214d725870db673  base' | sha256sum -c -
genisoimage -quiet -r -V BIGTOPKIT -o kit.iso "$workspace/kit"
sudo ip link add btlab type bridge
sudo ip addr add 192.168.199.1/24 dev btlab
sudo ip link set btlab up
for i in 1 2 3; do printf '192.168.199.1%d bd00%d.field.test\n' "$i" "$i"; done > names
echo '192.168.199.1 pg.field.test' >> names
sudo tee -a /etc/hosts < names >/dev/null
sudo dnsmasq --interface=btlab --bind-interfaces --except-interface=lo --no-resolv \
  --dhcp-range=192.168.199.11,192.168.199.13,12h \
  --dhcp-host=52:54:00:00:00:01,192.168.199.11 --dhcp-host=52:54:00:00:00:02,192.168.199.12 --dhcp-host=52:54:00:00:00:03,192.168.199.13
sudo systemctl stop chrony
printf 'bindaddress 192.168.199.1\nlocal stratum 8\nallow 192.168.199.0/24\n' > ntp.conf
sudo install -m 0644 ntp.conf /etc/chrony/chrony.conf
sudo chronyd -x -f /etc/chrony/chrony.conf
docker load -i "$workspace/kit/runtimes/postgres15-image.tar.gz"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=pg.field.test' -addext 'subjectAltName=DNS:pg.field.test' -keyout pg.key -out pg.crt 2>/dev/null
password="PG!$(openssl rand -hex 16)"
echo "::add-mask::$password"
sudo chown "$(docker run --rm offline/postgres:15 id -u postgres)" pg.key
chmod 644 pg.crt
docker run -d --name field-db --network host -v "$PWD/pg.key:/var/tmp/pg.key:ro" -v "$PWD/pg.crt:/var/tmp/pg.crt:ro" \
  -e POSTGRES_DB=ambari -e POSTGRES_USER=ambari -e POSTGRES_PASSWORD="$password" offline/postgres:15 \
  -c listen_addresses=192.168.199.1 -c ssl=on -c ssl_key_file=/var/tmp/pg.key -c ssl_cert_file=/var/tmp/pg.crt
ssh-keygen -q -t ed25519 -N '' -f admin
opts=(-i "$s/admin" -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$s/known_hosts" -o ConnectTimeout=3)
for i in 1 2 3; do
  host=bd00$i.field.test
  sudo ip tuntap add dev "bttap$i" mode tap user "$(id -un)"
  sudo ip link set "bttap$i" master btlab
  sudo ip link set "bttap$i" up
  qemu-img create -q -f qcow2 -F qcow2 -b "$PWD/base" "disk$i" 20G
  cat > userdata <<EOF
#cloud-config
fqdn: $host
users:
  - name: siteadmin
    shell: /bin/bash
    sudo: 'ALL=(root) NOPASSWD: /bin/bash -s'
    ssh_authorized_keys:
      - $(cat admin.pub)
runcmd:
  - mkdir -p /srv/bigtop-kit /etc/bigtop-deploy /etc/pki/bigtop
  - mount -o ro LABEL=BIGTOPKIT /srv/bigtop-kit
  - sed -i '/^PermitRootLogin /d; 1iPermitRootLogin no' /etc/ssh/sshd_config
  - echo 'Defaults:siteadmin !requiretty' > /etc/sudoers.d/90-field-siteadmin
  - chmod 440 /etc/sudoers.d/90-field-siteadmin
  - systemctl reload sshd
  - cat /etc/ssh/ssh_host_ed25519_key.pub > /dev/ttyS0
EOF
  printf 'instance-id: field-%s\nlocal-hostname: %s\n' "$i" "$host" > metadata
  cloud-localds "seed$i" userdata metadata
  accel=tcg
  if [[ -c /dev/kvm ]]; then sudo setfacl -m "u:$(id -un):rw" /dev/kvm; accel=kvm; fi
  mem=1536; [[ $i != 1 ]] || mem=6144
  qemu-system-x86_64 -accel "$accel" -m "$mem" -smp 2 -display none -daemonize -serial "file:$s/serial$i" \
    -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
    -drive "file=disk$i,if=virtio,format=qcow2" -drive "file=seed$i,media=cdrom,readonly=on,format=raw" \
    -drive file=kit.iso,media=cdrom,readonly=on,format=raw -nic "tap,ifname=bttap$i,script=no,downscript=no,model=virtio-net-pci,mac=52:54:00:00:00:0$i"
done
for i in 1 2 3; do
  host=bd00$i.field.test
  for attempt in {1..120}; do grep -q '^ssh-ed25519 ' "serial$i" && break; sleep 4; done
  key=$(grep -m1 '^ssh-ed25519 ' "serial$i" | tr -d '\r') || { tail -40 "serial$i"; exit 1; }
  printf '%s,192.168.199.1%d %s\n' "$host" "$i" "$key" >> known_hosts
  ssh "${opts[@]}" "siteadmin@$host" 'hostname -f; ps -p 1 -o comm=; test -r /srv/bigtop-kit/SHA256SUMS'
done
{
  echo 'set -eu; umask 077'
  printf '%s\n' "echo '$password' > /etc/bigtop-deploy/ambari-db.password"
  echo 'echo "machine localhost login admin password admin" > /etc/bigtop-deploy/ambari.netrc'
  echo "cat > /etc/pki/bigtop/postgres-ca.crt <<'CERT'"
  cat pg.crt; echo CERT
  echo 'chmod 644 /etc/pki/bigtop/postgres-ca.crt'
} | ssh "${opts[@]}" siteadmin@bd001.field.test 'sudo -n /bin/bash -s'
cd "$workspace/kit"
python3 ops/generate-inventory.py --nodes 3 --domain field.test --web-out "$s/web.json" > "$s/hosts.csv"
printf 'slot,address\nbd001,192.168.199.11\nbd002,192.168.199.12\nbd003,192.168.199.13\n' > "$s/bootstrap.csv"
cp ops/site.env.example "$s/site.env"
cat >> "$s/site.env" <<EOF
INVENTORY=$s/hosts.csv
BOOTSTRAP_INVENTORY=$s/bootstrap.csv
PREPARE_OS=1
SSH_USER=fielddeploy
SSH_KNOWN_HOSTS=$s/known_hosts
SSH_IDENTITY_FILE=$s/deploy
PG_HOST=pg.field.test
NTP_SOURCES=192.168.199.1
REQUIRED_MOUNTS=/
WORKER_MOUNTS=''
MIN_FREE_MIB=1024
MANIFEST_SHA256=$(cut -d' ' -f1 ../kit-manifest.sha256)
EOF
printf 'BOOTSTRAP_USER=siteadmin\nBOOTSTRAP_IDENTITY_FILE=%q\nGENERATE_DEPLOY_KEY=1\n' "$s/admin" > "$s/access.env"
bash ops/bootstrap-access.sh "$s/site.env" "$s/access.env" plan
bash ops/bootstrap-access.sh "$s/site.env" "$s/access.env" apply
ssh "${opts[@]}" siteadmin@bd001.field.test 'sudo -n /bin/bash -s' <<'SAMPLE' > "$s/start-sample" 2>&1 &
for step in {1..600}; do
  pid=$(pgrep -f '^/opt/jdk17/bin/java .*org.apache.ambari.server.controller.AmbariServer' | head -1)
  if [[ -n $pid ]]; then
    sleep 30
    cat /proc/sys/kernel/random/entropy_avail
    /opt/jdk17/bin/jcmd "$pid" Thread.print | sed -n '/^"main"/,/^$/p'
    break
  fi
  sleep 2
done
SAMPLE
if ! bash ops/deploy-cluster.sh "$s/site.env" ambari; then
  cat "$s/start-sample"
  for host in bd001.field.test bd002.field.test bd003.field.test; do
    ssh "${opts[@]}" "siteadmin@$host" 'sudo -n /bin/bash -s' <<'DIAGNOSTICS' || true
hostname -f
free -m
ss -ltn
systemctl --failed --no-pager
ps -C java -o pid,stat,%cpu,rss
for log in /var/log/ambari-server/ambari-server.{log,out} /var/log/ambari-server/ambari-server-check-database.log /var/log/ambari-agent/ambari-agent.log; do
  test -f "$log" && tail -75 "$log" | grep -Eiv 'password|secret|token'
done
journalctl -k --no-pager | grep -Ei 'out of memory|killed process|avc:.*denied' | tail -15
DIAGNOSTICS
  done
  exit 1
fi
