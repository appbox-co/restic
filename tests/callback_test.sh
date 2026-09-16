#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."
callback_test_dir=$(mktemp -d)
cleanup() {
    rm -f -- "$callback_test_dir/configured" "$callback_test_dir/called"
    rmdir -- "$callback_test_dir"
}
trap cleanup EXIT

export CONFIG_FLAG="$callback_test_dir/configured"
export TEST_CURL_CALLED="$callback_test_dir/called"
export INSTANCE_ID=local-test CALLBACK_TOKEN=fixture-token SKIP_APPBOX_CALLBACK=0
export TEST_EXPECTED_URL

# Exported Bash functions intercept subprocess calls; no real HTTP requests.
curl() {
    [[ "${!#}" == "$TEST_EXPECTED_URL" ]] || return 1
    touch "$TEST_CURL_CALLED"
    printf '200'
}
sleep() { :; }
export -f curl sleep

check_callback() {
    rm -f -- "$CONFIG_FLAG" "$TEST_CURL_CALLED"
    "$@" bash restic-callback
    test -f "$CONFIG_FLAG"
    test -f "$TEST_CURL_CALLED"
}

TEST_EXPECTED_URL=https://api.cylo.net/v1/apps/installed/local-test
check_callback env -u APPBOX_API_URL
check_callback env APPBOX_API_URL=

TEST_EXPECTED_URL=https://api.example.test/v1/apps/installed/local-test
check_callback env APPBOX_API_URL=https://api.example.test/v1

rm -f -- "$CONFIG_FLAG" "$TEST_CURL_CALLED"
env -u APPBOX_API_URL -u INSTANCE_ID -u CALLBACK_TOKEN \
    SKIP_APPBOX_CALLBACK=1 bash restic-callback
test ! -e "$CONFIG_FLAG"
test ! -e "$TEST_CURL_CALLED"

status=0
env -u CALLBACK_TOKEN bash restic-callback >/dev/null 2>&1 || status=$?
test "$status" -eq 64
test ! -e "$CONFIG_FLAG"
test ! -e "$TEST_CURL_CALLED"

printf '%s\n' 'callback tests passed (mock HTTP; no network requests)'
