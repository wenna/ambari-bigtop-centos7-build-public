#!/usr/bin/env bash
set -euo pipefail

ambari_packages() {
    pkgs=(ambari-agent java-1.8.0-openjdk-devel python3 curl chrony openssh-clients openssh-server
          procps-ng util-linux psmisc nmap-ncat tar gzip which hostname rsync)
    case $1 in server) pkgs+=(ambari-server);; agent) :;; *) return 64;; esac
}

ambari_guard() {
    local root=$1 path installed units loaded
    for path in /var/lib/bigtop-production /etc/hadoop/conf /etc/tmpfiles.d/bigtop-production.conf; do
        if [[ -e $root$path || -L $root$path ]]; then
            echo "Existing data deployment: $path. Use fresh hosts for the Ambari bootstrap." >&2; return 1
        fi
    done
    installed=$(rpm -qa --qf '%{NAME}\n') || return 1
    if grep -E '^(bigtop|hdp|cloudera-manager|hadoop|hdfs|yarn|mapreduce|hive|tez|spark[0-9]*|zookeeper)([-_]|$)' <<< "$installed" >&2; then
        echo 'Existing distribution RPMs; this bootstrap cannot adopt a data deployment.' >&2; return 1
    fi
    units=$(systemctl list-unit-files --no-legend --no-pager 'bigtop-*.service') || return 1
    loaded=$(systemctl list-units --all --no-legend --no-pager 'bigtop-*.service') || return 1
    if grep -E 'bigtop-[^[:space:]]+\.service' <<< "$units"$'\n'"$loaded" >&2; then
        echo 'Existing legacy data service unit; migration is not supported.' >&2; return 1
    fi
}

ambari_repo() {
    local kit=$1 action=$2 root=$3 conf staged other
    conf=$root/etc/yum.repos.d/bigtop-ambari-offline.repo
    for other in "$root"/etc/yum.conf "$root"/etc/yum.repos.d/*.repo; do
        [[ -f $other && $other != "$conf" ]] || continue
        if grep -Eq '^[[:space:]]*\[(bigtop-ambari-local|bigtop-runtime-local)\][[:space:]]*$' "$other"; then
            echo "Reserved offline repository ID already present: $other" >&2; return 1
        fi
    done
    if [[ -L $conf || ( -e $conf && ! -f $conf ) ]]; then echo "Unexpected repository file type: $conf" >&2; return 1; fi
    ambari_repo_text() {
        cat <<EOF
[bigtop-ambari-local]
name=Verified offline BIGTOP application RPMs
baseurl=file://$kit/yum-staging/
enabled=1
gpgcheck=0
metadata_expire=0

[bigtop-runtime-local]
name=Verified offline EL7 runtime RPMs
baseurl=file://$kit/runtime-repo/
enabled=1
gpgcheck=1
gpgkey=file://$kit/runtime-repo/keys/RPM-GPG-KEY-CentOS-7 file://$kit/runtime-repo/keys/RPM-GPG-KEY-EPEL-7
metadata_expire=0
EOF
    }
    if [[ -e $conf ]]; then
        cmp "$conf" <(ambari_repo_text) || { echo "Review conflicting repository: $conf" >&2; return 1; }
    elif [[ $action == install ]]; then
        staged=$(mktemp "${conf}.XXXXXXXX") || return 1
        (set -e; trap 'rm -f -- "$staged"' EXIT; ambari_repo_text > "$staged"; chmod 0644 "$staged"; ln -- "$staged" "$conf") || return 1
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    [[ $# == 2 && $1 == inspect && $2 =~ ^/[-_.a-zA-Z0-9/]+$ ]] || exit 64
    ambari_guard ''
    ambari_repo "$2" inspect ''
fi
