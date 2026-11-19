#!/usr/bin/env bash
set -euo pipefail
umask 077
kit=$1 mode=$2 target=$3 address=$4 set_name=$5 manage_hosts=$6 offset=$7 count=$8
shift 8
[[ $EUID == 0 && ( $mode == inspect || $mode == apply ) ]]
[[ $set_name =~ ^[01]$ && $manage_hosts =~ ^[01]$ && $count =~ ^[1-9][0-9]*$ && $# -gt $count ]]
[[ $offset =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v x="$offset" 'BEGIN{exit !(x>0)}' || exit 64
ntp=("${@:1:count}")
shift "$count"
records=("$@")
for source in "${ntp[@]}"; do
    [[ $source =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] || { echo "Invalid chrony source: $source" >&2; exit 64; }
done
[[ $(ps -p 1 -o comm=) == systemd ]]
if [[ $mode == apply ]]; then
    exec 8>/run/lock/bigtop-host-prepare.lock
    flock -n 8 || { echo "Another preparation is running" >&2; exit 1; }
fi
ip -o addr show | awk -v ip="$address" '{split($4,a,"/"); if (a[1]==ip) seen=1} END{exit !seen}' ||
    { echo "Bootstrap IP does not belong to this host: $address" >&2; exit 1; }
if systemctl is-active --quiet ntpd || systemctl is-enabled --quiet ntpd || pgrep -x ntpd >/dev/null; then
    echo "ntpd is active or enabled. Resolve time service ownership before preparation." >&2; exit 1
fi
if [[ $set_name == 0 && $(hostname -f) != "$target" && $(hostname) != "$target" ]]; then
    echo "Existing hostname differs from $target and SET_HOSTNAME=0" >&2; exit 1
fi
state=/var/lib/bigtop-deploy/host-preparation
fingerprint=$(printf '%s\n' "$target" "$address" "$set_name" "$manage_hosts" "${ntp[@]}" "${records[@]}" | sha256sum | cut -d' ' -f1)
reject() { echo "$*" >&2; exit 1; }
if [[ -f $state/identity && $(cat "$state/identity") != "$fingerprint" ]]; then
    reject "Site settings differ from the installed OS preparation marker. Review changes explicitly."
fi
pkgs=$(rpm -qa --qf '%{NAME}\n')
if grep -Eq '^(ambari-(server|agent)|hdp-select|cloudera-manager-agent|hadoop($|-|_))' <<< "$pkgs" ||
   [[ -d /var/lib/bigtop-deploy/ambari || -d /etc/hadoop/conf ]] ||
   systemctl list-units --all --no-legend 'bigtop-*.service' | grep -q 'bigtop-'; then
    [[ -f $state/identity ]] || reject "Existing cluster detected; OS preparation only accepts new hosts"
    # An established cluster can be rechecked without changing its identity or restarting time.
    [[ $(hostname -f) == "$target" ]] || reject "Established cluster hostname drift"
    for pair in "${records[@]}"; do
        read -r addr name <<< "$pair"
        getent ahosts "$name" | awk -v ip="$addr" '$1==ip{found=1} END{exit !found}' ||
            reject "Established cluster name resolution differs: $name"
    done
    bash "$kit/ops/check-node.sh" --time "$offset" "${ntp[@]}"
    exit
fi
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
# All reviewed edits require regular files. An absent hostname file may be created.
for path in /etc/hostname /etc/hosts /etc/chrony.conf; do
    [[ ! -L $path && ( ! -e $path || -f $path ) ]] || reject "Unexpected file type: $path"
done
render() { /usr/bin/python "$kit/ops/prepare-config.py" "$@"; }
if [[ $manage_hosts == 1 ]]; then
    render hosts /etc/hosts "$tmp/hosts" "${records[@]}"
else
    for pair in "${records[@]}"; do
        read -r addr name <<< "$pair"
        getent ahosts "$name" | awk -v ip="$addr" '$1==ip{found=1} END{exit !found}' ||
            reject "Site DNS must resolve $name to $addr"
    done
fi
if [[ -f /etc/chrony.conf ]]; then render chrony /etc/chrony.conf "$tmp/chrony" "${ntp[@]}"; fi
if [[ $mode == inspect ]]; then echo "New host preparation checks passed: $address -> $target"; exit 0; fi
mkdir -p "$state"
backup=$(mktemp -d "$state/backup.XXXXXXXX")
replace_config() {
    local dest=$1 input=$2 staged
    if [[ -f $dest ]] && cmp -s "$dest" "$input"; then return 0; fi
    staged=$(mktemp "${dest}.bigtop.XXXXXXXX")
    if [[ -f $dest ]]; then
        cp --preserve=all -- "$dest" "$backup/${dest##*/}"
        cp --preserve=all -- "$dest" "$staged"
        if command -v selinuxenabled >/dev/null && selinuxenabled; then chcon --reference="$dest" "$staged"; fi
    else
        chmod 0644 "$staged"
    fi
    cat "$input" > "$staged"
    mv -fT -- "$staged" "$dest"
    if [[ ! -e $backup/${dest##*/} ]] && command -v restorecon >/dev/null; then restorecon "$dest"; fi
    echo "Updated $dest; originals retained in $backup"
}
if ! rpm -q chrony >/dev/null; then bash "$kit/cluster/provision-node.sh" "$kit" --chrony-only; fi
render chrony /etc/chrony.conf "$tmp/chrony" "${ntp[@]}"
if [[ $manage_hosts == 1 ]]; then replace_config /etc/hosts "$tmp/hosts"; fi
if [[ $set_name == 1 ]]; then
    printf '%s\n' "$target" > "$tmp/hostname"
    replace_config /etc/hostname "$tmp/hostname"
    if [[ $(hostname) != "$target" ]]; then hostname "$target"; fi
fi
[[ $(hostname -f) == "$target" ]] || reject "Final FQDN mismatch for $target"
if cmp -s "$tmp/chrony" /etc/chrony.conf; then
    systemctl enable chronyd
    systemctl start chronyd
else
    replace_config /etc/chrony.conf "$tmp/chrony"
    systemctl enable chronyd
    systemctl restart chronyd
fi
chronyc waitsync 30 "$offset" 0 2
bash "$kit/ops/check-node.sh" --time "$offset" "${ntp[@]}"
printf '%s\n' "$fingerprint" > "$tmp/identity"
install -m 0600 "$tmp/identity" "$state/identity"
rmdir "$backup" 2>/dev/null || true
echo "Prepared $target ($address)"
