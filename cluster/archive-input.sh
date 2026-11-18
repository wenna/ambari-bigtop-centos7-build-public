#!/usr/bin/env bash
set -euo pipefail
gh release download el7-yum-44247482610 -p el7-x86_64-yum.tar
echo 'd69a4b61d3ff26971d9705bbfe6d648093496872361bf6f6a7bc047e2e2c91db  el7-x86_64-yum.tar' | sha256sum -c -
tar xf el7-x86_64-yum.tar
(cd yum-staging && sha256sum -c SHA256SUMS)
rm el7-x86_64-yum.tar
