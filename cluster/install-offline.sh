#!/usr/bin/env bash
set -euo pipefail
rpm --import /runtime/keys/*
printf '[bundle-app]\nname=SHA256 verified Bigtop and Ambari\nbaseurl=file:///repo\ngpgcheck=0\n[bundle-runtime]\nname=Signed CentOS and EPEL deps\nbaseurl=file:///runtime\ngpgcheck=1\ngpgkey=file:///runtime/keys/RPM-GPG-KEY-CentOS-7 file:///runtime/keys/RPM-GPG-KEY-EPEL-7\n' > /etc/yum.repos.d/bundle.repo
mapfile -t pkgs < /project/cluster/packages.txt
yum -y --disablerepo='*' --enablerepo='bundle-*' install "${pkgs[@]}"
rpm -q "${pkgs[@]}"
yum clean all
