#!/usr/bin/env bash
# Exercise the production OS preflight in a mock EL7 environment. No root required.
set -euo pipefail
project=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d)
export fixture
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture"/{yum-staging,runtime-repo}/repodata "$fixture/mount"
printf '<repomd/>\n' | tee "$fixture/yum-staging/repodata/repomd.xml" > "$fixture/runtime-repo/repodata/repomd.xml"
touch "$fixture/yum-staging/ambari-server.rpm" "$fixture/yum.conf"
printf 'CentOS Linux release 7.9.2009 (Core)\n' > "$fixture/centos-release"
export scenario=ok
uname() { echo x86_64; }
hostname() { echo master.site.test; }
ps() { if [[ $scenario == bad-pid1 ]]; then echo init; else echo systemd; fi; }
systemctl() { case $1 in show) echo 'Version=219';; is-active) echo inactive; return 3;; esac; }
getenforce() { echo Enforcing; }
mountpoint() { [[ $scenario != unmounted ]]; }
findmnt() { if [[ $scenario == readonly ]]; then echo ro,relatime; else echo rw,relatime; fi; }
df() {
    local free=6000
    [[ $scenario != diskfull ]] || free=4000
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nmock 10000 4000 %s 40%% /disk\n' "$free"
}
rpm() {
    printf 'ambari-server\t0:3.0.0.0-2.compat2.el7.x86_64\n'
    if [[ $1 == -qa && $scenario == foreign ]]; then printf 'hdp-select\t0:2.6.5-1.x86_64\n'; fi
    if [[ $1 == -qa && $scenario == mismatch ]]; then printf 'ambari-server\t0:2.7.0-1.x86_64\n'; fi
}
grep() {
    local args=() arg
    for arg; do
        case $arg in /etc/yum.conf) arg=$fixture/yum.conf;; /etc/centos-release) arg=$fixture/centos-release;; esac
        args+=("$arg")
    done
    command grep "${args[@]}"
}
export -f uname hostname ps systemctl getenforce mountpoint findmnt df rpm grep
run_check() { bash "$project/ops/check-node.sh" --os "$fixture" 4096 "$fixture/mount"; }
expect_reject() {
    scenario=$1
    if run_check > "$fixture/output" 2>&1; then echo "Expected refusal: $scenario" >&2; exit 1; fi
    command grep -Fq "$2" "$fixture/output" || { cat "$fixture/output" >&2; exit 1; }
}
run_check > "$fixture/output"
command grep -Fq 'SELinux: Enforcing' "$fixture/output"
command grep -Fq 'firewalld.service: inactive' "$fixture/output"
expect_reject bad-pid1 'PID 1'
expect_reject unmounted 'Missing filesystem mount'
expect_reject readonly 'Read-only filesystem'
expect_reject diskfull 'requires 4096 MiB'
expect_reject foreign 'Existing distribution package'
expect_reject mismatch 'Conflicting installed RPM'
echo '[checked-app]' >> "$fixture/yum.conf"
expect_reject repo 'Reserved deployment repository ID'
echo 'OS preflight scenarios passed'
