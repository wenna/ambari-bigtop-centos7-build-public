#!/usr/bin/env bash
set -euo pipefail
mkdir -p artifacts runtimes/jdk17
exec > >(tee artifacts/ambari-build.log) 2>&1
test "$(git -C upstream/ambari rev-parse HEAD)" = '15feafb7dfa2f4964a01edac47c0956ab29ad99e'
patch_file="$PWD/patches/ambari/0001-agent-reset-python3.patch"
if ! git -C upstream/ambari apply --reverse --check "$patch_file" 2>/dev/null; then
  git -C upstream/ambari apply "$patch_file"
fi
jdk_url='https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.21%2B9/OpenJDK17U-jdk_x64_linux_hotspot_17.0.21_9.tar.gz'
curl --fail --location --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
  "$jdk_url" -o runtimes/jdk17.tar.gz
printf '%s  %s\n' '8b9b611d917e3dfd8419d3566b5949226f69b052fed7e109c1368add1dfe8711' \
  runtimes/jdk17.tar.gz | sha256sum -c -
tar -xzf runtimes/jdk17.tar.gz -C runtimes/jdk17 --strip-components=1
image='bigtop/slaves@sha256:f3a7a76cd5bdbbd8ed9cf5bbbde055b09e6f54d8f7581928175f91e773715235'
docker pull --platform linux/amd64 "$image"
free_bytes=$(df -B1 --output=avail . | tail -1 | tr -d ' ')
printf 'Available bytes before Ambari compilation: %s\n' "$free_bytes"
if (( free_bytes < 5 * 1024 * 1024 * 1024 )); then
  printf 'RESOURCE_LIMIT: less than 5 GiB remains\n'
  exit 78
fi
docker run --rm --platform linux/amd64 --memory 5g --cpus 2 \
  -v "$PWD/upstream/ambari:/ws" -w /ws \
  -v "$PWD/runtimes/jdk17:/opt/jdk17:ro" \
  -v "$PWD/scripts/ambari-build-inside.sh:/ambari-build.sh:ro" \
  -v "$PWD/manifests/ambari-build-python.txt:/build-python.txt:ro" \
  "$image" bash /ambari-build.sh
printf 'Stage: RPM metadata\n'
docker run --rm --platform linux/amd64 -v "$PWD/upstream/ambari:/ws:ro" "$image" \
  bash -lc 'find /ws/ambari-server/target/rpm /ws/ambari-agent/target/rpm -type f -name "*.rpm" -exec rpm -qp --qf "%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n" {} +' \
  | tee artifacts/ambari-rpm-metadata.txt
