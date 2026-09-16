#!/bin/bash
# Run in a disposable, bootstrapped release-test container; never skip UID checks.
set -Eeuo pipefail
[[ $(id -u) == 0 ]] || { echo 'SSH listing regression requires container root' >&2; exit 1; }

as_restic() {
    chroot /srv/restic-sftp /bin/busybox su -s /bin/ash -c "$1" restic
}

[[ $(as_restic '/bin/busybox id -u') == 1000 ]]
[[ $(as_restic '/bin/busybox id -g') == 1000 ]]
listing=$(as_restic 'SSH_ORIGINAL_COMMAND=list-repositories /bin/restic-ssh-command') || {
    echo 'SSH repository listing failed as restricted UID 1000' >&2
    exit 1
}
grep -Fxq default <<<"$listing"
while IFS= read -r name; do
    [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]]
done <<<"$listing"

[[ $(stat -c '%U:%G %a' /srv/restic-sftp/etc/rest-username) == 'root:restic 640' ]]
as_restic 'test -r /etc/rest-username && ! test -w /etc/rest-username'
for name in rest-password default.password; do
    secret="/srv/restic-sftp/data/.restic-manager/secrets/$name"
    [[ -f $secret && $(stat -c '%U:%G %a' "$secret") == 'root:root 600' ]]
    ! s6-setuidgid restic test -r "$secret"
done
printf '%s\n' 'SSH listing checks passed (real chroot, UID/GID 1000, metadata read-only, secrets unreadable)'
