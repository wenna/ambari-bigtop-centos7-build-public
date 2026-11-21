#!/usr/bin/env bash
# Supply the access prerequisites that production hosts receive from site IT.
set -eu
cat > /etc/yum.repos.d/operator-bootstrap.repo <<'EOF'
[operator-bootstrap]
name=CentOS 7.9 signed updates
baseurl=https://vault.centos.org/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF
yum -y --disablerepo='*' --enablerepo=operator-bootstrap install sudo
rm -f /etc/yum.repos.d/operator-bootstrap.repo
yum clean all
useradd -m clusterops
cat > /etc/sudoers.d/clusterops <<'EOF'
Defaults:clusterops !requiretty
clusterops ALL=(root) NOPASSWD: /bin/bash /project/cluster/install-offline.sh *, /bin/bash /kit/ops/manage-server.sh *, /usr/bin/python3 /kit/ops/ambari-stack-el7.py
EOF
chmod 0440 /etc/sudoers.d/clusterops
visudo -cf /etc/sudoers
