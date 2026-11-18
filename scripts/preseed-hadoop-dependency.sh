#!/usr/bin/env bash
set -euo pipefail
target='.build-cache/m2/com/github/stephenc/findbugs/findbugs-annotations/1.3.9-1'
base='https://repo.maven.apache.org/maven2/com/github/stephenc/findbugs/findbugs-annotations/1.3.9-1'
mkdir -p "$target"
curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 120 \
  "$base/findbugs-annotations-1.3.9-1.jar" -o "$target/findbugs-annotations-1.3.9-1.jar"
curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 120 \
  "$base/findbugs-annotations-1.3.9-1.pom" -o "$target/findbugs-annotations-1.3.9-1.pom"
printf '%s  %s\n' \
  '1e651066ed9ae35d7e3001d635d1dbba1c2965db0e4e33e2c14ad610543f225c' "$target/findbugs-annotations-1.3.9-1.jar" \
  'ad37b9f110af24e6f346cbec55463ee2d96480be7f639a690739ef3638b4cc45' "$target/findbugs-annotations-1.3.9-1.pom" \
  | sha256sum -c -
printf 'findbugs-annotations-1.3.9-1.jar>central=\nfindbugs-annotations-1.3.9-1.pom>central=\n' > "$target/_remote.repositories"
