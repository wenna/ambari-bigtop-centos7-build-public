#!/usr/bin/env bash
set -euo pipefail
(( EUID != 0 )) || { echo "Run this check as the deployment account" >&2; exit 64; }
sudo -n -u hive -- env HADOOP_OPTS=-verbose:class /usr/bigtop/3.3.0/usr/lib/hive/bin/schematool \
    -dbType postgres -info 2>&1 | grep -E 'Loaded org.postgresql.Driver from|schema version'
