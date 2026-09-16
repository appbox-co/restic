#!/bin/bash
# Runs only inside a disposable release-test container, with generated credentials.
set -Eeuo pipefail
mode=${1:?bootstrap, verify, or rollback}
for attempt in $(seq 1 45); do
    if [[ -d /run/service/rest-server && -d /run/service/crond ]] &&
        [[ $(s6-svstat -o up /run/service/rest-server) == true ]] &&
        [[ $(s6-svstat -o up /run/service/crond) == true ]]; then break; fi
    sleep 1
done
[[ $(s6-svstat -o up /run/service/rest-server) == true ]]
[[ $(s6-svstat -o up /run/service/crond) == true ]]
manager=/usr/local/bin/cylo-restic-manager
state=/srv/restic-sftp/data/.restic-manager
export RESTIC_REPOSITORY=rest:http://127.0.0.1:8000/admin/default
export RESTIC_REST_USERNAME=admin RESTIC_REST_PASSWORD="$PASSWORD"
bootstrap() {
    jq -n --arg password "$RESTIC_PASSWORD" --arg name "$1" \
        '{version:1,definition:{manager_operation:"repository.bootstrap"},input:{name:$name,password:$password,enabled:"1",schedule:"03:00",timezone:"UTC",keep_daily:7,keep_weekly:4,keep_monthly:6}}' |
        "$manager" typed-json >/dev/null
}
configure() {
    "$manager" configure --repo default --enabled "$1" --schedule 03:00 \
        --timezone UTC --keep-daily "$2" --keep-weekly 4 --keep-monthly 6
}
if [[ $mode == bootstrap ]]; then
    bootstrap default
    bootstrap default
    restic --no-cache backup /etc/hostname >/dev/null
fi
restic --no-cache snapshots --json | jq -e 'length >= 1' >/dev/null
restic --no-cache check >/dev/null
[[ $(stat -c '%U:%G %a' "$state/secrets/rest-htpasswd") == 'root:restic 640' ]]
! s6-setuidgid restic test -r "$state/secrets/default.password"
! s6-setuidgid restic test -r "$state/secrets/rest-password"
[[ $(stat -c %u /srv/restic-sftp/data/admin/default/config) == 1000 ]]
if [[ $mode == rollback ]]; then
    configure 1 7
    original_config=$(sha256sum "$state/repositories/default.conf")
    original_cron=$(sha256sum /etc/crontabs/root)
    # Fail only cron publication; restoring the previous config must still work.
    mv() {
        if [[ ${FAIL_CRON_PUBLICATION:-0} == 1 && ${!#} == /etc/crontabs/root ]]; then
            return 1
        fi
        command mv "$@"
    }
    export -f mv
    if FAIL_CRON_PUBLICATION=1 configure 1 1; then
        echo 'cron publication fault was not detected' >&2; exit 1
    fi
    [[ $(sha256sum "$state/repositories/default.conf") == "$original_config" ]]
    [[ $(sha256sum /etc/crontabs/root) == "$original_cron" ]]
    unset -f mv
    # A failed post-publication HTTP check must restore cron and keep repository data.
    curl() { return 1; }
    export -f curl
    if RESTIC_READINESS_TIMEOUT=2 bootstrap rollback-new; then
        echo 'bootstrap verification fault was not detected' >&2; exit 1
    fi
    unset -f curl
    [[ ! -e "$state/repositories/rollback-new.conf" ]]
    [[ -f /srv/restic-sftp/data/admin/rollback-new/config ]]
    [[ $(sha256sum /etc/crontabs/root) == "$original_cron" ]]
    configure 0 7
    ! grep -Fq 'retention --repo default --scheduled' /etc/crontabs/root
    "$manager" retention --repo default --scheduled
    configure 1 7
    # Exercise the real kernel lock, not the non-root unit-test flock stub.
    (flock -x 9; touch /run/release-lock-ready; sleep 3) \
        9>/run/lock/restic-manager/repo-default.lock &
    lock_pid=$!
    for attempt in $(seq 1 30); do
        [[ -f /run/release-lock-ready ]] && break
        sleep 0.1
    done
    [[ -f /run/release-lock-ready ]]
    if configure 1 1; then echo 'repository lock was bypassed' >&2; exit 1; fi
    wait "$lock_pid"
    [[ $(sha256sum "$state/repositories/default.conf") == "$original_config" ]]
    "$manager" retention --repo default >/dev/null
    restic --no-cache snapshots --json | jq -e 'length >= 1' >/dev/null
fi
printf 'Container checks passed: %s\n' "$mode"
