#!/usr/bin/env bash
# Isolated acceptance environment. Restore into different names; retain the source.
set -euo pipefail
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fs=(docker exec -i -u hdfs bd01.lab.test hdfs dfs)
path=/tmp/dr-test-$GITHUB_RUN_ID
openssl rand 65536 > "$tmp/input"
"${fs[@]}" -mkdir "$path"
"${fs[@]}" -put - "$path/original" < "$tmp/input"
"${fs[@]}" -cat "$path/original" > "$tmp/backup"
"${fs[@]}" -put - "$path/recovered" < "$tmp/backup"
"${fs[@]}" -cat "$path/recovered" | cmp "$tmp/input" -
docker exec mgmt-db pg_dump -U ambari -Fc hive > "$tmp/catalog.dump"
docker exec mgmt-db createdb -U ambari -O hive_catalog hive_restore
docker exec -i mgmt-db pg_restore --exit-on-error -U ambari -d hive_restore < "$tmp/catalog.dump"
for db in hive hive_restore; do
  docker exec mgmt-db psql -XAt -v ON_ERROR_STOP=1 -U ambari -d "$db" -c 'SELECT "SCHEMA_VERSION" FROM "VERSION"; SELECT "NAME" FROM "DBS" ORDER BY 1' > "$tmp/$db.txt"
done
test -s "$tmp/hive.txt"
cmp "$tmp/hive.txt" "$tmp/hive_restore.txt"
echo 'HDFS byte comparison and Hive catalog restore passed' | tee web-evidence/recovery.txt
