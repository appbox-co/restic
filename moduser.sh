#!/bin/bash
set -Eeuo pipefail
umask 077

if [[ "${1:-}" != "--password-stdin" ]]; then
    printf '%s\n' "Usage: printf '%s\\n' '<new_password>' | /moduser.sh --password-stdin"
    exit 1
fi
IFS= read -r NEW_PASSWORD
[[ -n "${NEW_PASSWORD}" ]] || {
    echo "Error: password must not be empty"
    exit 1
}

MANAGER_ROOT="${RESTIC_CONFIG_ROOT:-/srv/restic-sftp/data/.restic-manager}"
HTPASSWD_FILE="${MANAGER_ROOT}/secrets/rest-htpasswd"
PASSWORD_FILE="${MANAGER_ROOT}/secrets/rest-password"

if [[ ! -f "${HTPASSWD_FILE}" ]]; then
    echo "Error: htpasswd file not found at ${HTPASSWD_FILE}"
    exit 1
fi

IFS=: read -r ADMIN_USER _ <"${HTPASSWD_FILE}"

if [[ -z "${ADMIN_USER}" ]]; then
    echo "Error: no user found in ${HTPASSWD_FILE}"
    exit 1
fi

HTPASSWD_TMP=$(mktemp "${HTPASSWD_FILE}.XXXXXX")
PASSWORD_TMP=$(mktemp "${PASSWORD_FILE}.XXXXXX")
trap 'rm -f "${HTPASSWD_TMP:-}" "${PASSWORD_TMP:-}"' EXIT
cp "${HTPASSWD_FILE}" "${HTPASSWD_TMP}"
printf '%s\n' "${NEW_PASSWORD}" |
    htpasswd -Bi "${HTPASSWD_TMP}" "${ADMIN_USER}"
sed -i 's/^\([^:]*:\)\$2y\$/\1$2a$/' "${HTPASSWD_TMP}"
printf '%s\n' "${NEW_PASSWORD}" >"${PASSWORD_TMP}"
chown root:restic "${HTPASSWD_TMP}"
chmod 0640 "${HTPASSWD_TMP}"
chown root:root "${PASSWORD_TMP}"
chmod 0600 "${PASSWORD_TMP}"
mv -f "${HTPASSWD_TMP}" "${HTPASSWD_FILE}"
mv -f "${PASSWORD_TMP}" "${PASSWORD_FILE}"
trap - EXIT
echo "Password updated for user: ${ADMIN_USER}"
