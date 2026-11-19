#!/usr/bin/env bash
# Check local mounts/peer resolution or the running chrony configuration.
set -euo pipefail
if [[ ${1:-} == --os ]]; then
    shift
    kit=${1:?provide verified delivery root}
    minimum=${2:?provide minimum free MiB per required mount}
    shift 2
    export LC_ALL=C
    fail() { echo "OS preflight: $*" >&2; exit 1; }
    [[ $minimum =~ ^[0-9]+$ && $# -gt 0 ]] || fail "Specify minimum free MiB and at least one mount"
    [[ $(uname -m) == x86_64 ]] || fail "Requires x86_64"
    grep -Fxq 'CentOS Linux release 7.9.2009 (Core)' /etc/centos-release || fail "Requires CentOS 7.9.2009"
    manager=$(ps -p 1 -o comm=)
    [[ $manager == systemd ]] || fail "PID 1 is $manager; systemd must manage cluster units"
    systemctl show --property=Version | grep -E '^Version=.+' || fail "Cannot query systemd manager"
    for path; do
        [[ $path == /* && -d $path && -w $path ]] || fail "Expected a writable absolute directory: $path"
        mountpoint -q -- "$path" || fail "Missing filesystem mount: $path"
        opts=$(findmnt -nr -o OPTIONS --target "$path") || fail "Cannot inspect mount options: $path"
        [[ ,$opts, == *,rw,* && ,$opts, != *,ro,* ]] || fail "Read-only filesystem: $path ($opts)"
        free=$(df -Pm -- "$path" | awk 'NR == 2 {print $4}')
        [[ $free =~ ^[0-9]+$ ]] || fail "Cannot read free space on $path"
        awk -v f="$free" -v n="$minimum" 'BEGIN {exit !(f >= n)}' ||
            fail "$path has ${free} MiB available; requires ${minimum} MiB"
        echo "mount=$path available_mib=$free required_mib=$minimum"
    done
    if command -v getenforce >/dev/null; then
        echo "SELinux: $(getenforce)"
    elif [[ -r /sys/fs/selinux/enforce ]]; then
        echo "SELinux kernel enforce flag: $(cat /sys/fs/selinux/enforce)"
    else
        echo "SELinux kernel interface not mounted"
    fi
    for unit in firewalld iptables ip6tables; do
        # Inactive service units can still leave firewall rules loaded in the kernel.
        status=$(systemctl is-active "$unit" 2>/dev/null) || true
        echo "$unit.service: ${status:-unknown}"
    done
    if [[ -r /var/run/yum.pid ]]; then
        read -r pid < /var/run/yum.pid || true
        if [[ ${pid:-} =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            fail "Active yum PID $pid; wait for the transaction to finish"
        fi
    fi
    for repo in yum-staging runtime-repo; do
        [[ -s $kit/$repo/repodata/repomd.xml ]] || fail "Missing local metadata: $kit/$repo"
    done
    if grep -Eq '^[[:space:]]*\[(checked-app|checked-os)\][[:space:]]*$' /etc/yum.conf; then
        fail "Reserved deployment repository ID in /etc/yum.conf"
    fi
    if grep -Eiq '^[[:space:]]*(exclude|includepkgs)[[:space:]]*=' /etc/yum.conf; then
        echo "Review package filters in /etc/yum.conf before installation" >&2
    fi
    echo "Package transactions use private reposdir; no host repositories enabled"
    shopt -s nullglob
    packages=("$kit"/yum-staging/*.rpm)
    (( ${#packages[@]} > 0 )) || fail "No application RPMs"
    query='%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n'
    expected=$(rpm -qp --qf "$query" "${packages[@]}") || fail "Cannot inspect release RPM headers"
    installed=$(rpm -qa --qf "$query") || fail "Cannot inspect installed RPM database"
    awk -F '\t' '
        NR==FNR { names[$1]=1; expected[$0]=1; next }
        $1 in names && !($0 in expected) {print "Conflicting installed RPM: " $0 > "/dev/stderr"; bad=1; next}
        !($1 in names) && ($1 ~ /^(hdp-select|hadoop|hadoop-hdfs|hadoop-yarn|hadoop-mapreduce|cloudera-manager-agent)($|-)/ ||
                           $1 ~ /^(hadoop|hive|tez|spark|zookeeper)_[0-9]/) {
            print "Existing distribution package requires a migration plan: " $0 > "/dev/stderr"; bad=1
        }
        END {exit bad}
    ' <(printf '%s\n' "$expected") <(printf '%s\n' "$installed") || exit 1
    echo "OS preflight passed on $(hostname -f)"
    exit 0
fi
if [[ ${1:-} == --time ]]; then
    shift
    limit=${1:?provide maximum clock correction in seconds}
    shift
    [[ $limit =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v x="$limit" 'BEGIN {exit !(x > 0)}' || exit 64
    (( $# > 0 )) || { echo "Supply site-approved NTP source addresses or DNS names" >&2; exit 64; }
    export LC_ALL=C
    command -v chronyc >/dev/null || { echo "Install chrony using the time-packages stage" >&2; exit 1; }
    systemctl is-active --quiet chronyd || { echo "chronyd is inactive on $(hostname -f)" >&2; exit 1; }
    chronyc waitsync 6 "$limit" 0 2 || { chronyc tracking >&2; exit 1; }
    selected=$(chronyc -n sources | awk '$1 == "^*" || $1 == "=*" {print $2}')
    [[ -n $selected ]] || { echo "chronyd has no selected network time source" >&2; exit 1; }
    for source; do
        if [[ $selected == "$source" ]] || getent ahosts "$source" | awk -v s="$selected" '$1==s {ok=1} END{exit !ok}'; then
            echo "$(hostname -f): synchronized to $selected, maximum remaining correction $limit s"
            exit 0
        fi
    done
    echo "Selected NTP source $selected is outside the configured source list" >&2
    exit 1
fi
: "${1:?usage: bash check-node.sh hosts.csv [required_mount_point ...]}"
inventory=$1
shift
test "$(uname -m)" = x86_64
grep -F 'CentOS Linux release 7.9.2009' /etc/centos-release
fqdn=$(hostname -f)
awk -F, -v h="$fqdn" 'NR > 1 && tolower($2) == tolower(h) {n++} END {exit n != 1}' "$inventory" || {
    echo "Local hostname does not match one inventory row: $fqdn" >&2
    exit 1
}
while IFS=, read -r slot host rack roles || [[ -n $slot ]]; do
    if [[ "$slot" == slot ]]; then continue; fi
    getent ahosts "$host" >/dev/null || { echo "Name resolution failed: $host" >&2; exit 1; }
done < "$inventory"
for mount_dir in "$@"; do
    mountpoint -q -- "$mount_dir" || { echo "Missing mount: $mount_dir" >&2; exit 1; }
    df -hP -- "$mount_dir"
done
echo "Node identity, peer address lookup and specified mount points checked: $fqdn"
