# Sourced into the bootstrap administrator's remote script.
install_policy() {
  [[ $EUID == 0 && $account =~ ^[a-z_][a-z0-9_-]*$ && $account != root ]]
  [[ $kit == "$(realpath "$kit")" && $kit != / && $digest =~ ^[a-fA-F0-9]{64}$ ]]
  local path=$kit
  while [[ $path != / ]]; do
    [[ $(stat -c %u "$path") == 0 && -z $(find "$path" -maxdepth 0 -perm /022 -print) ]] || {
      echo "Untrusted path: $path" >&2; return 1;
    }
    path=$(dirname "$path")
  done
  if [[ ,$(findmnt -nr -o OPTIONS -T "$kit"), != *,ro,* ]]; then
    local unsafe
    unsafe=$(find "$kit" \( ! -user root -o -perm /022 -o -type l \) -print -quit)
    [[ -z $unsafe ]] || {
      echo "Unprotected entry: $unsafe. Use a trusted read-only kit or a root-owned protected release tree" >&2; return 1;
    }
  fi
  (cd "$kit"; printf '%s  SHA256SUMS\n' "$digest" | sha256sum --status -c -; sha256sum --quiet -c SHA256SUMS)
  /usr/sbin/sshd -T | grep -Fx 'permitrootlogin no' >/dev/null || {
    echo "Site SSH policy must already disable root login" >&2; return 1;
  }
  install -d -m 0700 /etc/bigtop-access
  exec 9>/etc/bigtop-access/lock
  flock -x 9
  local state=/etc/bigtop-access/$account policy=/etc/sudoers.d/bigtop-ambari-$account
  local dispatcher=/usr/local/sbin/bigtop-ambari-action
  if [[ -e $dispatcher ]] && ! cmp -s "$kit/ops/ambari-action.sh" "$dispatcher"; then
    echo "Existing dispatcher differs; review it before updating" >&2; return 1
  fi
  if getent passwd "$account" >/dev/null; then
    [[ -f $state/uid && $(id -u "$account") == "$(cat "$state/uid")" && $(id -u "$account") -gt 0 ]] || {
      echo "Existing unmanaged account: $account. Choose a new dedicated account or retain the existing site policy." >&2; return 1;
    }
  fi
  install -d -m 0700 "$state"
  local work
  work=$(mktemp -d "$state/stage.XXXXXXXX")
  trap 'rm -rf -- "$work"' RETURN
  mkdir "$work/actions"
  base64 -d | tar -xzf - -C "$work/actions"
  local f
  for f in "$work/actions/"*; do
    [[ -f $f && ! -L $f && ${f##*/} =~ ^[0-9a-f]{64}$ ]]
    (cd "$work/actions"; printf '%s  %s\n' "${f##*/}" "${f##*/}" | sha256sum --status -c -)
  done
  printf 'Defaults:%s !requiretty\n%s ALL=(root) NOPASSWD: %s\n' "$account" "$account" "$dispatcher" > "$work/sudoers"
  chmod 0440 "$work/sudoers"
  visudo -cf "$work/sudoers"
  if [[ -e $policy ]] && ! cmp -s "$work/sudoers" "$policy"; then
    echo "Conflicting sudoers entry: $policy" >&2; return 1
  fi
  if ! id "$account" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --password '*' "$account"
    id -u "$account" > "$state/uid"
  fi
  # All writes under the user's home run under that UID.
  runuser -u "$account" -- /bin/bash -c '
    set -eu
    umask 077
    cd "$(getent passwd "$(id -un)" | cut -d: -f6)"
    mkdir -p .ssh
    [[ ! -L .ssh && ! -L .ssh/authorized_keys ]]
    chmod 0700 .ssh
    touch .ssh/authorized_keys
    chmod 0600 .ssh/authorized_keys
    grep -Fxq "$1" .ssh/authorized_keys || printf "\n%s\n" "$1" >> .ssh/authorized_keys
  ' _ "$key"
  local version
  version=$(cd "$work/actions"; printf '%s\n' * | sha256sum)
  version=${version%% *}
  [[ -d $state/$version ]] || mv "$work/actions" "$state/$version"
  ln -s "$version" "$work/current"
  mv -Tf "$work/current" "$state/current"
  if [[ ! -e $dispatcher ]]; then install -m 0755 "$kit/ops/ambari-action.sh" "$dispatcher"; fi
  if [[ ! -e $policy ]]; then install -m 0440 "$work/sudoers" "$policy"; fi
  if command -v restorecon >/dev/null; then restorecon "$policy" "$dispatcher"; fi
  visudo -c >/dev/null
  rm -rf -- "$work"
  trap - RETURN
}
