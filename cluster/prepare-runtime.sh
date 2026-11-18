#!/usr/bin/env bash
# Runs in a disposable CentOS 7 build container. /out is a writable host bind.
set -euo pipefail
mkdir -p /out/runtime-repo/{Packages,keys} /out/manifests /tmp/closure
for area in os updates extras; do
  printf '[c7-%s]\nname=CentOS 7 %s\nbaseurl=https://vault.centos.org/7.9.2009/%s/$basearch/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7\n' "$area" "$area" "$area" > "/etc/yum.repos.d/c7-$area.repo"
done
yum --disablerepo='*' --enablerepo=c7-os,c7-updates,c7-extras -y install epel-release yum-utils yum-plugin-downloadonly createrepo
printf '[c7-epel]\nname=EPEL 7\nbaseurl=https://archives.fedoraproject.org/pub/archive/epel/7/$basearch/\ngpgcheck=1\ngpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-7\n' > /etc/yum.repos.d/c7-epel.repo
printf '[c7-local]\nname=Verified local RPMs\nbaseurl=file:///repo\ngpgcheck=0\n' > /etc/yum.repos.d/c7-local.repo
cp /etc/pki/rpm-gpg/RPM-GPG-KEY-{CentOS-7,EPEL-7} /out/runtime-repo/keys/
rpm --import /out/runtime-repo/keys/*
# A fresh installroot also resolves dependencies already present in the builder image.
mapfile -t roles < /project/cluster/packages.txt
mkdir -p /tmp/closure/etc/yum.repos.d
cp /etc/yum.repos.d/c7-*.repo /tmp/closure/etc/yum.repos.d/
yum -y --installroot=/tmp/closure --releasever=7 --disablerepo='*' --enablerepo=c7-os,c7-updates,c7-extras,c7-epel,c7-local \
  --downloadonly --downloaddir=/out/runtime-repo/Packages install "${roles[@]}"
shopt -s nullglob
for f in /out/runtime-repo/Packages/*.rpm; do
  base=${f##*/}
  if find /repo -name "$base" -print -quit | grep -q .; then rm -- "$f"; continue; fi
  rpmkeys -Kv "$f" | grep -Ei 'RSA/.*Signature.*: OK$' >/dev/null
done
createrepo -q /out/runtime-repo
rpm -qp --qf '%{NAME}\t%{EPOCH}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' /out/runtime-repo/Packages/*.rpm | sort > /out/manifests/runtime-versions.tsv
find /repo -name '*.rpm' -exec sh -c 'for p do echo "[$(basename "$p")]"; rpm -qpR "$p"; done' sh {} + > /out/manifests/application-rpm-requires.txt
(cd /out && find runtime-repo -type f -print0 | sort -z | xargs -0 sha256sum > manifests/runtime-SHA256SUMS)
