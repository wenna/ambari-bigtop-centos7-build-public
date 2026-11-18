#!/usr/bin/env bash
set -euo pipefail
test -n "${GITHUB_REPOSITORY:-}"
test -n "${GITHUB_RUN_ID:-}"
test -n "${GITHUB_SHA:-}"
mapfile -d '' -t rpms < <(find upstream/bigtop/output -type f -name '*.rpm' -print0)
if (( ${#rpms[@]} < 1 )); then
  printf 'No RPMs were produced\n' >&2
  exit 1
fi
names=()
for package in "${rpms[@]}"; do
  names+=("$(basename "$package")")
done
test -z "$(printf '%s\n' "${names[@]}" | sort | uniq -d)"
printf '%s\n' "${names[@]}" | grep -q '^hadoop_3_3_0-.*\.rpm$'
: > artifacts/HADOOP-SHA256SUMS
for package in "${rpms[@]}"; do
  digest=$(sha256sum "$package")
  printf '%s  %s\n' "${digest%% *}" "$(basename "$package")" >> artifacts/HADOOP-SHA256SUMS
done
git -C upstream/bigtop rev-parse HEAD > artifacts/bigtop-commit.txt
tag="hadoop-3.3.6-c7-run-${GITHUB_RUN_ID}"
gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
  --draft --prerelease --title 'Hadoop 3.3.6 CentOS 7 build - verification pending' \
  --notes-file docs/releases/hadoop-draft.md \
  "${rpms[@]}" artifacts/HADOOP-SHA256SUMS artifacts/bigtop-commit.txt artifacts/applied.patch \
  | tee artifacts/draft-release-url.txt
