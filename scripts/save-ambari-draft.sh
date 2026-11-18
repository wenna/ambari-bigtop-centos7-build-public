#!/usr/bin/env bash
set -euo pipefail
mapfile -d '' -t rpms < <(find upstream/ambari/ambari-server/target/rpm upstream/ambari/ambari-agent/target/rpm \
  -type f -name '*.rpm' -print0)
test "${#rpms[@]}" -ge 2
names=()
for package in "${rpms[@]}"; do names+=("$(basename "$package")"); done
test -z "$(printf '%s\n' "${names[@]}" | sort | uniq -d)"
image='bigtop/slaves@sha256:f3a7a76cd5bdbbd8ed9cf5bbbde055b09e6f54d8f7581928175f91e773715235'
docker run --rm --platform linux/amd64 -v "$PWD/upstream/ambari:/ws:ro" "$image" \
  bash -lc 'find /ws/ambari-server/target/rpm /ws/ambari-agent/target/rpm -type f -name "*.rpm" -exec rpm -qp --qf "%{NAME} %{SOURCEPACKAGE}\n" {} +' \
  > artifacts/ambari-package-types.txt
awk '$1 == "ambari-server" && $2 != "1" { server=1 }
     $1 == "ambari-agent" && $2 != "1" { agent=1 }
     END { exit !(server && agent) }' artifacts/ambari-package-types.txt
git -C upstream/ambari rev-parse HEAD > artifacts/ambari-source-commit.txt
git -C upstream/ambari archive --format=tar.gz HEAD > artifacts/ambari-3.0.0-input-source.tar.gz
: > artifacts/AMBARI-SHA256SUMS
for package in "${rpms[@]}" artifacts/ambari-3.0.0-input-source.tar.gz patches/ambari/0001-agent-reset-python3.patch; do
  digest=$(sha256sum "$package")
  printf '%s  %s\n' "${digest%% *}" "$(basename "$package")" >> artifacts/AMBARI-SHA256SUMS
done
gh release create "ambari-3.0.0-c7-run-${GITHUB_RUN_ID}" --repo "$GITHUB_REPOSITORY" \
  --target "$GITHUB_SHA" --draft --prerelease \
  --title 'Ambari 3.0.0 CentOS 7 build - verification pending' \
  --notes-file docs/releases/ambari-draft.md \
  "${rpms[@]}" artifacts/AMBARI-SHA256SUMS artifacts/ambari-source-commit.txt artifacts/ambari-3.0.0-input-source.tar.gz patches/ambari/0001-agent-reset-python3.patch \
  | tee artifacts/ambari-draft-url.txt
