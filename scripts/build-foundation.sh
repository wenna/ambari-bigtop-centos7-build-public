#!/usr/bin/env bash
set -euo pipefail
build_extra="${BUILD_EXTRA:-foundation}"
case "$build_extra" in
  foundation) build_extra='' ;;
  zookeeper|hadoop|tez|hive|spark) ;;
  *) printf 'Unsupported component\n' >&2; exit 64 ;;
esac
mkdir -p artifacts
exec > >(tee artifacts/build.log) 2>&1
expected_commit='d44a5845eeffe6bab7037a3ca816cf3c9df44029'
test "$(git -C upstream/bigtop rev-parse HEAD)" = "$expected_commit"
selector_patch="$PWD/patches/bigtop/0001-selector-python3.patch"
if git -C upstream/bigtop apply --reverse --check "$selector_patch" 2>/dev/null; then
  printf 'Selector Python 3 patch is already applied.\n'
else
  git -C upstream/bigtop apply --check "$selector_patch"
  git -C upstream/bigtop apply "$selector_patch"
fi
if [[ "$build_extra" == hadoop ]]; then
  python3 scripts/apply-hadoop-catalog-lock.py
fi
if [[ "$build_extra" == tez ]]; then
  tez_patch="$PWD/patches/bigtop/0002-tez-el7-build.patch"
  if ! git -C upstream/bigtop apply --reverse --check "$tez_patch" 2>/dev/null; then
    git -C upstream/bigtop apply "$tez_patch"
  fi
fi
sha256sum "$selector_patch" > artifacts/patch-SHA256SUMS
git -C upstream/bigtop diff > artifacts/applied.patch
mkdir -p .build-cache/m2
if [[ "$build_extra" == hadoop ]]; then
  printf 'Stage: prefetch verified dependency after recorded Maven connection reset\n'
  bash scripts/preseed-hadoop-dependency.sh
fi
build_image='bigtop/slaves@sha256:f3a7a76cd5bdbbd8ed9cf5bbbde055b09e6f54d8f7581928175f91e773715235'
printf 'Stage: pull fixed build image\n'
docker pull --platform linux/amd64 "$build_image"
docker image inspect "$build_image" --format '{{json .}}' > artifacts/build-image.json
free_bytes=$(df -B1 --output=avail . | tail -1 | tr -d ' ')
printf 'Available bytes after pulling image: %s\n' "$free_bytes"
if (( free_bytes < 5 * 1024 * 1024 * 1024 )); then
  printf 'RESOURCE_LIMIT: less than 5 GiB remains; stopping before compilation.\n'
  exit 78
fi
printf 'Stage: build Bigtop 3.3.0 foundation packages\n'
docker run --rm --platform linux/amd64 --memory 5g --cpus 2 -e BUILD_EXTRA="$build_extra" \
  -v "$PWD/upstream/bigtop:/ws" \
  -v "$PWD/.build-cache/m2:/root/.m2/repository" -w /ws "$build_image" \
  bash -lc 'source /etc/profile.d/bigtop.sh; tasks=(bigtop-select-pkg bigtop-utils-pkg); options=(); if [[ -n "$BUILD_EXTRA" ]]; then tasks+=("${BUILD_EXTRA}-pkg"); fi; if [[ "$BUILD_EXTRA" == hadoop ]]; then options+=(-Dbuildwithdeps=true); fi; ./gradlew --no-daemon "${tasks[@]}" "${options[@]}" -PparentDir=/usr/bigtop -PpkgSuffix -PbuildThreads=2 repo'
printf 'Stage: RPM metadata\n'
docker run --rm --platform linux/amd64 -v "$PWD/upstream/bigtop/output:/rpms:ro" \
  "$build_image" bash -lc 'find /rpms -type f -name "*.rpm" -exec rpm -qp --qf "%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n" {} +' \
  | tee artifacts/rpm-metadata.txt
