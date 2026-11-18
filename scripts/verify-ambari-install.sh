#!/usr/bin/env bash
set -euo pipefail
for repo in os updates extras; do
  cat > "/etc/yum.repos.d/test-$repo.repo" <<REPO
[test-$repo]
name=CentOS 7.9 archived $repo
baseurl=https://vault.centos.org/7.9.2009/$repo/\$basearch/
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
REPO
done
yum --disablerepo='*' --enablerepo='test-*' -y install epel-release
cat > /etc/yum.repos.d/test-epel.repo <<'REPO'
[test-epel]
name=Archived EPEL 7
baseurl=https://archives.fedoraproject.org/pub/archive/epel/7/$basearch/
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7
REPO
rpm -qp --qf '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' /rpms/*.rpm
rpm -qpR /rpms/*.rpm | sort -u
yum --disablerepo='*' --enablerepo='test-*' -y install /rpms/*.rpm
rpm -q ambari-server ambari-agent
python3 -c 'import distro, rpm; print(distro.id(), distro.version(), rpm.__file__)'
if [[ "${AMBARI_INSTALL_ONLY:-0}" == 1 ]]; then exit 0; fi
ambari-server setup --help
ambari-agent reset ambari.test.internal
grep -E '^hostname[[:space:]]*=[[:space:]]*ambari\.test\.internal$' /etc/ambari-agent/conf/ambari-agent.ini
