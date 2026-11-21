#!/usr/bin/env bash
# Add the signed x86_64 Ambari hook dependencies to an already verified runtime volume.
set -euo pipefail
gh release download el7-native-extras-44492197486 -p native-el7-extras.tar.gz
printf '%s  native-el7-extras.tar.gz\n' 304c535669e4423eb5b282a589116841f4758fca29c4ca4e0690168aa82fbb7c | sha256sum -c -
tar xf native-el7-extras.tar.gz
while read -r digest rpm; do
  gh release download c7-hbase-44847222340 -p "$rpm" -D yum-staging
done < manifests/ats-hbase.sha256
(cd yum-staging && sha256sum -c ../manifests/ats-hbase.sha256)
centos=centos@sha256:be65f488b7764ad3638f236b7b515b3678369a5124c47b8d32916d6487418ea4
docker run --rm -i --network none -v "$PWD:/project" -v "$PWD/yum-staging:/repo:ro" -v "$PWD/runtime-repo:/runtime" "$centos" bash -se <<'SH'
set -o pipefail
bash /project/cluster/install-offline.sh createrepo >/dev/null
for f in /project/native-extras/*.x86_64.rpm; do rpmkeys -Kv "$f" | grep -Ei 'RSA/.*Signature.*: OK$'; cp -n "$f" /runtime/Packages/; done
createrepo -q --update /runtime
cd /project
createrepo -q --update yum-staging
(cd yum-staging && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
for p in yum-staging/*.rpm; do
  printf '[%s]\n' "${p##*/}"
  rpm -qpR "$p"
done > manifests/application-rpm-requires.txt
rpm -qp --qf '%{NAME}\t%{EPOCH}:%{VERSION}-%{RELEASE}\t%{ARCH}\n' runtime-repo/Packages/*.rpm | sort > manifests/runtime-versions.tsv
find runtime-repo -type f -print0 | sort -z | xargs -0 sha256sum > manifests/runtime-SHA256SUMS
SH
