#!/usr/bin/env bash
set -euo pipefail
cat > /etc/yum.repos.d/build-vault.repo <<'REPO'
[build-vault]
name=CentOS 7.9.2009 archived base
baseurl=https://vault.centos.org/7.9.2009/os/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
REPO
mapfile -t packages < <(find /rpms -type f -name '*.rpm' ! -name '*.src.rpm')
if (( ${#packages[@]} < 2 )); then
  printf 'Missing foundation RPMs\n'
  exit 1
fi
yum --disablerepo='*' --enablerepo=build-vault -y install "${packages[@]}"
if [[ "${VERIFY_EXTRA:-}" == 'zookeeper' ]]; then
  yum --disablerepo='*' --enablerepo=build-vault -y install java-1.8.0-openjdk-headless
  java -version
fi
rpm -q bigtop-select bigtop-utils
rpm -V bigtop-select bigtop-utils
test -d /usr/bigtop/3.3.0
python3 --version
test "$(python3 /usr/lib/bigtop-select/distro-select --version)" = '3.3.0'
python3 /usr/lib/bigtop-select/distro-select packages
python3 /usr/lib/bigtop-select/distro-select status
python3 /usr/lib/bigtop-select/distro-select versions
python3 /usr/lib/bigtop-select/distro-select supports hadoop-client
if python3 /usr/lib/bigtop-select/distro-select supports invalid-probe-package; then
  printf 'Invalid package unexpectedly accepted\n'
  exit 1
fi
python3 /usr/lib/bigtop-select/conf-select --help
test "$(head -n 1 /usr/lib/bigtop-select/distro-select)" = '#!/usr/bin/env python3'
printf 'PYTHON3_SELECTOR_INSTALL_PASSED: selector CLI only; Ambari service integration remains unverified.\n'
if [[ "${VERIFY_EXTRA:-}" == 'zookeeper' ]]; then
  rpm -q zookeeper_3_3_0
  java -cp '/usr/bigtop/3.3.0/usr/lib/zookeeper/*:/usr/bigtop/3.3.0/usr/lib/zookeeper/lib/*' org.apache.zookeeper.Version
  printf 'ZOOKEEPER_INSTALL_PASSED: Java version entry point only; quorum test follows separately.\n'
fi
