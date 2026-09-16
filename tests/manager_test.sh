#!/bin/bash
set -Eeuo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${ROOT}/bin" "${ROOT}/data" "${ROOT}/config" "${ROOT}/locks"

cat >"${ROOT}/bin/restic" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${RESTIC_TEST_LOG}"
if [ "${RESTIC_TEST_FAIL_BOOTSTRAP:-0}" = 1 ] && \
    [ -f "${RESTIC_CONFIG_ROOT}/repositories/rollback-new.conf" ]; then
    exit 1
fi
[ "$1" = init ] && touch "${RESTIC_REPOSITORY}/config"
[ "$1" = "cat" ] && [ "$2" = "config" ] && {
    expected="${RESTIC_REPOSITORY}/.expected-password"
    [ ! -f "${expected}" ] || cmp -s "${RESTIC_PASSWORD_FILE}" "${expected}" ||
        exit 1
}
exit 0
EOF
cat >"${ROOT}/bin/flock" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${ROOT}/bin/restic" "${ROOT}/bin/flock"
export PATH="${ROOT}/bin:${PATH}"
export RESTIC_TEST_LOG="${ROOT}/restic.log"
export RESTIC_DATA_ROOT="${ROOT}/data"
export RESTIC_CONFIG_ROOT="${ROOT}/data/.restic-manager"
export RESTIC_CRON_FILE="${ROOT}/crontab"
export RESTIC_LOCK_ROOT="${ROOT}/locks"
export RESTIC_AUTHORIZED_KEYS_FILE="${ROOT}/authorized_keys"
export RESTIC_ALLOW_NON_ROOT_TESTS=1
export RESTIC_TEST_USERNAME=admin

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        echo "expected failure: $*" >&2
        exit 1
    fi
}

python3 - <<'PY'
from pathlib import Path
import yaml

manifest = yaml.safe_load(Path("appbox.yml").read_text())
operations = manifest["typed_operations"]
assert manifest["volumes"] == [{
    "source": "data",
    "destination": "/srv/restic-sftp/data",
    "permissions": "rw",
    "uid": 1000,
}]
assert manifest["image"] == {
    "name": "restic-appbox",
    "version": "development",
    "tag": "development",
}
assert manifest["custom_fields"]["RESTIC_PASSWORD"]["sensitive"] is True
assert manifest["custom_fields"]["RESTIC_PASSWORD"]["revealable"] is True
assert manifest["custom_fields"]["PASSWORD"]["sensitive"] is True
assert manifest["custom_fields"]["PASSWORD"]["revealable"] is True
assert manifest["custom_fields"]["SSH_PASSWORD"]["sensitive"] is True
assert manifest["custom_fields"]["SSH_PASSWORD"]["revealable"] is True
fields = manifest["custom_fields"]
assert fields["USERNAME"]["params"]["showOnInstalled"] is False
assert fields["PASSWORD"]["label"] == "REST login password"
assert fields["INITIAL_REPOSITORY"]["params"]["showOnInstalled"] is False
assert fields["SSH_ENABLED"]["params"]["showOnInstalled"] is False
assert fields["SSH_PUBLIC_KEY"]["params"]["showOnInstalled"] is False
assert fields["SSH_USERNAME"]["params"]["showOnInstalled"] is False
assert fields["SSH_HOST"]["params"]["showOnInstalled"] is False
assert fields["SSH_PORT"]["params"]["showOnInstalled"] is False
assert fields["SSH_AUTH_MODE"]["default_value"] == ""
assert fields["SSH_AUTH_MODE"]["validate"] == ["required"]
assert fields["SSH_PASSWORD"]["validate"] == ["required"]
assert fields["SSH_PASSWORD"]["params"] == {
    "generatePassword": True,
    "generatedPasswordLength": 32,
}
assert fields["SSH_PUBLIC_KEY"]["validate"] == ["required"]
assert fields["CONNECT_URL"] == {
    "label": "Restic REST repository",
    "type": "staticText",
    "width": 12,
    "default_value": (
        "rest:https://%USERNAME%@%DOMAIN.DOMAIN%/"
        "%USERNAME%/%INITIAL_REPOSITORY%"
    ),
    "template_type": "instance",
    "validate": [{"maxLength": 4096}],
    "params": {},
}
ssh_enabled_condition = {
    "field": "SSH_ENABLED",
    "operator": "equals",
    "value": "1",
    "clear_when_hidden": True,
}
assert fields["SSH_CONNECTION"]["default_value"] == (
    "ssh %SSH_USERNAME%@%DOMAIN.DOMAIN% -p%PORTS|0.EXTERNAL%"
)
assert fields["SSH_CONNECTION"]["condition"] == {
    "field": "SSH_ENABLED",
    "operator": "equals",
    "value": "1",
}
assert "SFTP_CONNECTION" not in fields
assert fields["SSH_AUTH_MODE"]["condition"] == ssh_enabled_condition
assert fields["SSH_PUBLIC_KEY"]["condition"] == {
    "field": "SSH_AUTH_MODE",
    "operator": "equals",
    "value": "key",
    "clear_when_hidden": True,
}
assert "sftp -P PORT USERNAME@HOST" in manifest["install"]["post_description"]
assert "REST login password" in manifest["install"]["post_description"]
assert "`help` and `list-repositories`" in manifest["install"]["post_description"]
expected = {
    "repository-init-manager": "repository.bootstrap",
    "repository-reconcile-manager": "repository.reconcile",
    "repository-retention-manager": "repository.retention.run",
    "repository-detach-manager": "repository.detach",
    "repository-delete-data-manager": "repository.delete-data",
}
expected_row_actions = {
    "repository-retention-manager": "run-retention",
    "repository-delete-data-manager": "delete-data",
}
internal_lifecycle_operations = {
    "repository-init-manager",
    "repository-reconcile-manager",
    "repository-detach-manager",
}
row_actions = [
    action
    for table in manifest["custom_tables"]
    for action in table.get("row_actions", [])
]
repositories_table = next(
    table for table in manifest["custom_tables"]
    if table["id"] == "repositories"
)
assert repositories_table["admin_only"] is False
assert repositories_table["enable_adding"] is True
assert repositories_table["enable_editing"] is True
assert repositories_table["enable_deleting"] is False
assert repositories_table["fields"]["name"]["unique"] is True
assert repositories_table["fields"]["password"]["editable"] is False
assert repositories_table["initial_rows_operation"] == {
    "operation": "repository-init-manager",
    "input": {
        "name": "row.name",
        "password": "row.password",
        "enabled": "row.enabled",
        "schedule": "row.schedule",
        "timezone": "row.timezone",
        "keep_daily": "row.keep_daily",
        "keep_weekly": "row.keep_weekly",
        "keep_monthly": "row.keep_monthly",
    },
}
assert repositories_table["create_operation"] == {
    "operation": "repository-init-manager",
    "input": {
        "name": "row.name",
        "password": "row.password",
        "enabled": "row.enabled",
        "schedule": "row.schedule",
        "timezone": "row.timezone",
        "keep_daily": "row.keep_daily",
        "keep_weekly": "row.keep_weekly",
        "keep_monthly": "row.keep_monthly",
    },
}
assert repositories_table["update_operation"] == {
    "operation": "repository-reconcile-manager",
    "input": {
        "name": "row.name",
        "enabled": "row.enabled",
        "schedule": "row.schedule",
        "timezone": "row.timezone",
        "keep_daily": "row.keep_daily",
        "keep_weekly": "row.keep_weekly",
        "keep_monthly": "row.keep_monthly",
    },
}
ssh_button = next(
    button for button in manifest["custom_buttons"]
    if button["id"] == "reconcile-ssh"
)
assert ssh_button["label"] == "Apply SSH public key"
assert ssh_button["admin_only"] is True
assert ssh_button["visibility_conditions"] == [
    {"field": "SSH_ENABLED", "operator": "equals", "value": "1"},
    {"field": "SSH_AUTH_MODE", "operator": "equals", "value": "key"},
]
assert len(row_actions) == len(expected_row_actions)
assert {action["operation"] for action in row_actions} == set(expected_row_actions)

for operation_id, manager_operation in expected.items():
    definition = operations[operation_id]
    assert definition["manager_operation"] == manager_operation
    assert definition["executable"] == "/usr/local/bin/cylo-restic-manager"
    assert definition["arguments"] == ["typed-json"]
    assert definition["stdin_mode"] == "json"
    assert definition["redact_output"] is True
    assert definition["input_schema"]["additionalProperties"] is False
    assert definition["image_policy"] == {
        "mode": "installed_app_version",
        "require_digest": True,
    }
    assert "operation" not in definition["input_schema"]["properties"]
    assert "operation" not in definition["input_schema"]["required"]

for operation_id, action_id in expected_row_actions.items():
    actions = [
        action for action in row_actions
        if action["operation"] == operation_id
    ]
    assert len(actions) == 1
    assert actions[0]["id"] == action_id
    assert "payload_operation" not in actions[0]

assert not (
    internal_lifecycle_operations
    & {action["operation"] for action in row_actions}
)

ssh = operations["ssh-reconcile-manager"]
assert ssh["manager_operation"] == "ssh.reconcile"
assert ssh["sensitive_input_paths"] == ["authorized_keys"]
assert "operation" not in ssh["input_schema"]["properties"]
assert ssh["image_policy"] == {
    "mode": "installed_app_version",
    "require_digest": True,
}
button = manifest["custom_buttons"][0]
assert button["operation"] == "ssh-reconcile-manager"
assert "payload_operation" not in button

dockerfile = Path("Dockerfile").read_text()
assert "FROM scratch" in dockerfile
assert "COPY --from=runtime-rootfs / /" in dockerfile
assert not any(
    line.lstrip().upper().startswith("VOLUME ")
    for line in dockerfile.splitlines()
)
PY

expect_failure ./restic-manager init --repo ../escape --password-stdin <<<secret
expect_failure ./restic-manager init --repo Uppercase --password-stdin <<<secret

printf '%s\n' secret | ./restic-manager init --repo daily --password-stdin
test -f "${ROOT}/data/admin/daily/config"
mode=$(stat -c '%a' "${RESTIC_CONFIG_ROOT}/secrets/daily.password" 2>/dev/null || stat -f '%Lp' "${RESTIC_CONFIG_ROOT}/secrets/daily.password")
test "${mode}" = 600

typed_payload() {
    local manager_operation=$1 input=$2
    jq -cn \
        --arg manager_operation "${manager_operation}" \
        --argjson input "${input}" \
        '{
            version: 1,
            definition: {manager_operation: $manager_operation},
            input: $input
        }'
}

typed_payload repository.bootstrap \
    '{"name":"typed","password":"typed-secret","enabled":"1","schedule":"04:20","timezone":"UTC","keep_daily":5,"keep_weekly":3,"keep_monthly":2}' |
    ./restic-manager typed-json
test -f "${ROOT}/data/admin/typed/config"
test ! -e "${ROOT}/data/.appbox"
grep -q '^\* \* \* \* \* .* retention --repo typed --scheduled$' "${ROOT}/crontab"

# Exact retries converge without duplicate schedules or reinitialization.
cp "${RESTIC_CONFIG_ROOT}/secrets/typed.password" \
    "${ROOT}/data/admin/typed/.expected-password"
typed_payload repository.bootstrap \
    '{"name":"typed","password":"typed-secret","enabled":"1","schedule":"04:20","timezone":"UTC","keep_daily":5,"keep_weekly":3,"keep_monthly":2}' |
    ./restic-manager typed-json
test "$(grep -Fc 'retention --repo typed' "${ROOT}/crontab")" = 1
test "$(grep -c '^init$' "${ROOT}/restic.log")" = 2

# A wrong password cannot replace the last verified manager credential.
cp "${RESTIC_CONFIG_ROOT}/secrets/typed.password" "${ROOT}/typed.password.before"
expect_failure sh -c \
    'payload=$(jq -cn '\''{version:1,definition:{manager_operation:"repository.bootstrap"},input:{name:"typed",password:"wrong",enabled:"1",schedule:"04:20",timezone:"UTC",keep_daily:5,keep_weekly:3,keep_monthly:2}}'\''); printf "%s\n" "$payload" | ./restic-manager typed-json'
cmp -s "${ROOT}/typed.password.before" \
    "${RESTIC_CONFIG_ROOT}/secrets/typed.password"

# A verified legacy repository is moved into the private REST namespace.
mkdir -p "${ROOT}/data/legacy"
touch "${ROOT}/data/legacy/config"
printf '%s\n' legacy-secret >"${ROOT}/data/legacy/.expected-password"
typed_payload repository.bootstrap \
    '{"name":"legacy","password":"legacy-secret","enabled":"0","schedule":"05:30","timezone":"UTC","keep_daily":1,"keep_weekly":0,"keep_monthly":0}' |
    ./restic-manager typed-json
test ! -e "${ROOT}/data/legacy"
test -f "${ROOT}/data/admin/legacy/config"
if grep -q 'retention --repo legacy' "${ROOT}/crontab"; then
    echo "disabled legacy retention was scheduled" >&2
    exit 1
fi

typed_payload repository.retention.run '{"name":"typed"}' |
    ./restic-manager typed-json
grep -q '^forget --prune --keep-daily 5 --keep-weekly 3 --keep-monthly 2$' "${ROOT}/restic.log"
grep -q 'su-exec restic:restic' restic-manager
grep -q 'mktemp /run/restic-manager/password' restic-manager
grep -q 'chown root:root "${secret}"' restic-manager
grep -q 'chmod 0600 "${secret}"' restic-manager

typed_payload repository.detach '{"name":"typed"}' |
    ./restic-manager typed-json
test -d "${ROOT}/data/admin/typed"
test ! -e "${RESTIC_CONFIG_ROOT}/repositories/typed.conf"

typed_payload repository.bootstrap \
    '{"name":"typed-delete","password":"typed-secret","enabled":"0","schedule":"04:20","timezone":"UTC","keep_daily":5,"keep_weekly":3,"keep_monthly":2}' |
    ./restic-manager typed-json
typed_payload repository.delete-data '{"name":"typed-delete"}' |
    ./restic-manager typed-json
test ! -e "${ROOT}/data/admin/typed-delete"

typed_payload ssh.reconcile '{"authorized_keys":"ssh-ed25519 AAAATEST appbox"}' |
    ./restic-manager typed-json
grep -q '^ssh-ed25519 AAAATEST appbox$' "${ROOT}/authorized_keys"

expect_failure ./restic-manager typed-json <<'JSON'
{"version":1,"definition":{"manager_operation":"repository.bootstrap"},"input":{"operation":"repository.delete-data","name":"typed","password":"typed-secret"}}
JSON

expect_failure ./restic-manager configure --repo daily --enabled 1 --schedule 25:00 \
    --timezone Europe/London --keep-daily 7 --keep-weekly 4 --keep-monthly 6
expect_failure ./restic-manager configure --repo daily --enabled 1 --schedule 03:15 \
    --timezone Etc/Not_A_Zone --keep-daily 7 --keep-weekly 4 --keep-monthly 6

./restic-manager configure --repo daily --enabled 1 --schedule 03:15 \
    --timezone Europe/London --keep-daily 7 --keep-weekly 4 --keep-monthly 6
grep -q '^\* \* \* \* \* .* retention --repo daily --scheduled$' "${ROOT}/crontab"

./restic-manager retention --repo daily
grep -q '^forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6$' "${ROOT}/restic.log"

# A cron publication error must not leave a different retention policy active.
cp "${RESTIC_CONFIG_ROOT}/repositories/daily.conf" "${ROOT}/before.conf"
cp "${ROOT}/crontab" "${ROOT}/before.cron"
cat >"${ROOT}/bin/mv" <<'EOF'
#!/bin/sh
for arg in "$@"; do target=$arg; done
if [ "${RESTIC_TEST_FAIL_CRON_PUBLISH:-0}" = 1 ] && [ "$target" = "$RESTIC_CRON_FILE" ]; then
    exit 1
fi
exec /bin/mv "$@"
EOF
chmod +x "${ROOT}/bin/mv"
expect_failure env RESTIC_TEST_FAIL_CRON_PUBLISH=1 ./restic-manager configure \
    --repo daily --enabled 1 --schedule 03:15 --timezone Europe/London \
    --keep-daily 1 --keep-weekly 0 --keep-monthly 0
cmp "${ROOT}/before.conf" "${RESTIC_CONFIG_ROOT}/repositories/daily.conf"
cmp "${ROOT}/before.cron" "${ROOT}/crontab"
./restic-manager retention --repo daily
tail -n 1 "${ROOT}/restic.log" | grep -q '^forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6$'

# If bootstrap verification fails after cron publication, restore cron and
# remove only the new scheduling config; never delete repository data.
typed_payload repository.bootstrap \
    '{"name":"rollback-new","password":"fixture-secret","enabled":"1","schedule":"04:20","timezone":"UTC","keep_daily":1,"keep_weekly":0,"keep_monthly":0}' |
    expect_failure env RESTIC_TEST_FAIL_BOOTSTRAP=1 ./restic-manager typed-json
test ! -e "${RESTIC_CONFIG_ROOT}/repositories/rollback-new.conf"
test -d "${RESTIC_DATA_ROOT}/admin/rollback-new"
cmp "${ROOT}/before.cron" "${ROOT}/crontab"

# Disabled retention must be honoured even if an old cron entry still fires.
./restic-manager configure --repo daily --enabled 0 --schedule 03:15 \
    --timezone Europe/London --keep-daily 7 --keep-weekly 4 --keep-monthly 6
cp "${ROOT}/restic.log" "${ROOT}/before.log"
./restic-manager retention --repo daily --scheduled
cmp "${ROOT}/before.log" "${ROOT}/restic.log"

./restic-manager detach --repo daily
test -d "${ROOT}/data/admin/daily"
test ! -e "${RESTIC_CONFIG_ROOT}/repositories/daily.conf"

printf '%s\n' secret | ./restic-manager init --repo disposable --password-stdin
./restic-manager delete-data --repo disposable
test ! -e "${ROOT}/data/admin/disposable"

echo "manager tests passed (non-root: mocked restic/flock; Docker and real locking not exercised)"
