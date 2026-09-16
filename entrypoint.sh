#!/bin/bash
set -Eeuo pipefail
umask 077

readonly ROOT=/srv/restic-sftp
readonly DATA="${ROOT}/data"
readonly STATE="${DATA}/.restic-manager"
readonly HTPASSWD="${STATE}/secrets/rest-htpasswd"
readonly REST_USERNAME_FILE="${STATE}/rest-username"
readonly SSH_DIR="${STATE}/ssh"

die() { echo "restic setup: $*" >&2; exit 1; }
require_env() { [[ -n "${!1:-}" ]] || die "$1 is required"; }

write_secret() {
    local path=$1 value=$2 tmp
    tmp=$(mktemp "${path}.XXXXXX")
    printf '%s\n' "${value}" >"${tmp}"
    chmod 0600 "${tmp}"
    mv -f "${tmp}" "${path}"
}

secure_manager_directories() {
    mkdir -p "${STATE}/secrets" "${STATE}/repositories"
    chown root:restic /etc/restic-manager "${STATE}" "${STATE}/secrets"
    chmod 0710 /etc/restic-manager "${STATE}" "${STATE}/secrets"
    chown root:root "${STATE}/repositories"
    chmod 0700 "${STATE}/repositories"
}

configure_ssh() {
    case "${SSH_ENABLED:-0}" in 0|1) ;; *) die "SSH_ENABLED must be 0 or 1" ;; esac
    case "${SSH_AUTH_MODE:-key}" in password|key) ;; *) die "SSH_AUTH_MODE must be password or key" ;; esac

    mkdir -p "${SSH_DIR}" /home/restic/.ssh /run/sshd
    chmod 0700 "${SSH_DIR}" /home/restic/.ssh
    ssh-keygen -A

    if [[ "${SSH_AUTH_MODE:-key}" == key ]]; then
        [[ -n "${SSH_PUBLIC_KEY:-}" ]] || {
            [[ "${SSH_ENABLED:-0}" == 0 ]] && return 0
            die "SSH_PUBLIC_KEY is required for key authentication"
        }
        printf '%s\n' "${SSH_PUBLIC_KEY}" > /home/restic/.ssh/authorized_keys
        chmod 0600 /home/restic/.ssh/authorized_keys
        chown -R restic:restic /home/restic
        # OpenSSH rejects a fully locked account before public-key auth.
        # Set an impossible random hash; password authentication remains off.
        usermod -p "\$6\$appbox\$not-a-valid-password-hash" restic
    else
        require_env SSH_PASSWORD
        printf 'restic:%s\n' "${SSH_PASSWORD}" | chpasswd
        rm -f /home/restic/.ssh/authorized_keys
    fi
}

require_env USERNAME
require_env PASSWORD
[[ "${USERNAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{2,31}$ ]] || die "invalid REST username"
secure_manager_directories

# The chroot itself must remain root-owned. Only its data child is writable.
mkdir -p "${DATA}" "${STATE}"
chown root:root "${ROOT}"
chmod 0755 "${ROOT}"
chown restic:restic "${DATA}"
chmod 0750 "${DATA}"
chown root:restic "${STATE}"
chmod 0750 "${STATE}"

[[ ! -e "${HTPASSWD}" || -f "${HTPASSWD}" && ! -L "${HTPASSWD}" ]] ||
    die "REST password file must be a regular file"
if [[ ! -f "${HTPASSWD}" ]]; then
    printf '%s\n' "${PASSWORD}" |
        htpasswd -Bci "${HTPASSWD}" "${USERNAME}" >/dev/null
fi
# Alpine's htpasswd emits the equivalent $2y$ marker, while rest-server's
# parser accepts the standard bcrypt $2a$ marker.
sed -i 's/^\([^:]*:\)\$2y\$/\1$2a$/' "${HTPASSWD}"
chmod 0640 "${HTPASSWD}"
chown root:restic "${HTPASSWD}"

if [[ ! -f "${STATE}/secrets/rest-password" ]]; then
    write_secret "${STATE}/secrets/rest-password" "${PASSWORD}"
fi
write_secret "${REST_USERNAME_FILE}" "${USERNAME}"
write_secret "${ROOT}/etc/rest-username" "${USERNAME}"
chown root:root "${STATE}/secrets/rest-password"
chown root:root "${REST_USERNAME_FILE}"
# The restricted SSH command reads this non-secret username inside the chroot.
chown root:restic "${ROOT}/etc/rest-username"
chmod 0640 "${ROOT}/etc/rest-username"

configure_ssh

# Recreate generated state on every start; this reconciles changed fields.
restic-manager reconcile --all
