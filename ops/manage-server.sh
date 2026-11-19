#!/usr/bin/env bash
# Invoked by deploy-cluster.sh as root on the management host or any agent.
set -euo pipefail
umask 077
[[ $EUID == 0 ]]
private_file() {
    [[ -f $1 && ! -L $1 && $(stat -c '%u' "$1") == 0 && $(stat -c '%a' "$1") =~ ^(400|600)$ ]]
}
case ${1:-} in
setup)
    shift
    kit=$1 host=$2 port=$3 db=$4 user=$5 password_file=$6 ca=$7
    [[ $host =~ ^[A-Za-z0-9.-]+$ && $port =~ ^[0-9]{1,5}$ && $db =~ ^[a-z][a-z0-9_]*$ && $user =~ ^[a-z][a-z0-9_]*$ ]]
    [[ -s $ca && $ca =~ ^/[a-zA-Z0-9_./-]+$ ]]
    private_file "$password_file"
    password=$(cat "$password_file")
    [[ -n $password && $password != *$'\n'* && $password != *$'\r'* && ! $password =~ ^[0-9a-fA-F]+$ ]] || {
        echo "Supply a nonempty single-line password with a non-hexadecimal character" >&2; exit 65;
    }
    state=/var/lib/bigtop-deploy/ambari
    mkdir -p "$state"
    exec 9>"$state/setup.lock"; flock -n 9
    identity=$(printf '%s\n' "$host" "$port" "$db" "$user" "$ca" | sha256sum | cut -d' ' -f1)
    for mark in "$state"/{schema,configured}.id; do
        [[ ! -e $mark || $(cat "$mark") == "$identity" ]] || { echo "Database target differs: $mark" >&2; exit 65; }
    done
    props=/etc/ambari-server/conf/ambari.properties
    if [[ ! -e $state/configured.id ]] && { ambari-server status >/dev/null 2>&1 || grep -Eq '^server\.jdbc\.url=' "$props"; }; then
        echo "Existing Ambari configuration: verify ownership and recover explicitly" >&2; exit 65
    fi
    url="jdbc:postgresql://$host:$port/$db?sslmode=verify-full&sslrootcert=$ca"
    sql=(/opt/jdk17/bin/java --class-path /opt/cluster/postgresql.jar "$kit/ops/AmbariSchema.java" "$url" "$user" "$password_file")
    if [[ ! -e $state/schema.id ]]; then
        "${sql[@]}" init /var/lib/ambari-server/resources/Ambari-DDL-Postgres-CREATE.sql
        echo "$identity" > "$state/schema.id"
    else
        "${sql[@]}" verify
    fi
    if [[ ! -e $state/configured.id ]]; then
        ambari-server setup --jdbc-db=postgres --jdbc-driver=/opt/cluster/postgresql.jar
        ambari-server setup -s --java-home=/opt/jdk17 --ambari-java-home=/opt/jdk17 \
          --stack-java-home=/usr/lib/jvm/java-1.8.0-openjdk --database=postgres \
          --databasehost="$host" --databaseport="$port" --databasename="$db" \
          --databaseusername="$user" --databasepassword="$password" --postgresschema=public
        # Retain ownership, SELinux context and mode on the RPM-managed file.
        python3 - "$props" "$url" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines()
for key in ("server.jdbc.url", "server.jdbc.rca.url"):
    indexes = [i for i, s in enumerate(lines) if s.partition("=")[0].strip() == key]
    if len(indexes) != 1:
        raise ValueError("Ambari JDBC property missing or duplicated: " + key)
    lines[indexes[0]] = key + "=" + sys.argv[2]
p.write_text("\n".join(lines) + "\n")
PY
        echo "$identity" > "$state/configured.id"
    fi
    grep -Fxq "server.jdbc.url=$url" "$props"
    grep -Fxq "server.jdbc.rca.url=$url" "$props"
    if ! ambari-server status >/dev/null 2>&1; then (umask 022; ambari-server start); fi
    ;;
agent)
    target=$2
    ini=/etc/ambari-agent/conf/ambari-agent.ini
    current=$(python3 - "$ini" <<'PY'
import configparser, sys
c = configparser.RawConfigParser()
c.read(sys.argv[1])
print(c.get("server", "hostname"))
PY
)
    if [[ $current != "$target" ]]; then
        [[ $current == localhost || $current == localhost.localdomain ]] || {
            echo "Agent is already bound to $current" >&2; exit 65;
        }
        ambari-agent reset "$target"
    fi
    if ! ambari-agent status >/dev/null 2>&1; then (umask 022; ambari-agent start); fi
    ;;
verify)
    base=$2 netrc=$3; shift 3
    (( $# > 0 ))
    [[ $base == http://localhost:8080 || $base == https://* ]]
    private_file "$netrc"
    response=$(mktemp); trap 'rm -f "$response"' EXIT
    for attempt in {1..80}; do
        if curl -fsS --max-time 10 --netrc-file "$netrc" "$base/api/v1/hosts?fields=Hosts/host_state" > "$response" &&
           python3 - "$response" "$@" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    entries = [x["Hosts"] for x in json.load(f)["items"]]
sys.exit(0 if {h["host_name"] for h in entries if h["host_state"] == "HEALTHY"} == set(sys.argv[2:])
         and len(entries) == len(sys.argv[2:]) else 1)
PY
        then echo "All $# inventory hosts HEALTHY"; exit 0; fi
        sleep 3
    done
    cat "$response" >&2; exit 1
    ;;
*) exit 64 ;;
esac
