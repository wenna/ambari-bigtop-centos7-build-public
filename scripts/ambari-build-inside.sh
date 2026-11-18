#!/usr/bin/env bash
set -euo pipefail
cat > /etc/yum.repos.d/ambari-build-vault.repo <<'REPOS'
[ambari-build-base]
name=CentOS 7.9 archived base
baseurl=https://vault.centos.org/7.9.2009/os/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[ambari-build-updates]
name=CentOS 7.9 archived updates
baseurl=https://vault.centos.org/7.9.2009/updates/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
REPOS
yum --disablerepo='*' --enablerepo=ambari-build-base,ambari-build-updates -y install \
  python3 python3-devel python3-pip python3-setuptools rpm-build redhat-rpm-config
python3 -m pip install --no-cache-dir --no-deps --require-hashes -r /build-python.txt
mkdir -p /opt/ambari-build-bin
ln -s /usr/bin/python3 /opt/ambari-build-bin/python
printf '%%__python /usr/bin/python3\n' > /root/.rpmmacros
set +u
source /etc/profile.d/bigtop.sh
set -u
export JAVA_HOME=/opt/jdk17
export PATH="$JAVA_HOME/bin:/opt/ambari-build-bin:$PATH"
export MAVEN_OPTS='-Xmx3g'
export npm_config_python=/usr/bin/python2
git config --global url.https://github.com/.insteadOf git://github.com/
printf 'Stage: fixed runtime versions\n'
java -version
mvn -version
python --version
python3 -c 'import distro; print(distro.id(), distro.version())'
printf 'Stage: compile full Ambari reactor and RPMs\n'
mvn -B -T1 clean install rpm:rpm \
  -Drat.skip=true -DskipTests -Dmaven.test.skip=true \
  -Dfindbugs.skip=true -Dcheckstyle.skip=true \
  '-Dpython.ver=python3 >= 3.6' -Dpackage-release=2.compat2.el7
