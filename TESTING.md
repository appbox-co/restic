# Testing

Run commands from the repository root. Use disposable data and generated test
credentials; these checks are not intended for existing backup repositories.

## Local manager checks

Requirements: Bash, Python 3 with PyYAML, and jq.

```sh
bash -n entrypoint.sh moduser.sh restic-manager restic-callback \
  tests/manager_test.sh tests/release_gate.sh tests/container_release_test.sh \
  tests/container_ssh_listing_test.sh
sh -n restic-ssh-command
bash tests/manager_test.sh
```

The manager suite covers repository creation, typed operation input,
idempotent retries, credential preservation, verified legacy-layout migration,
retention configuration, schedule rollback, and deletion boundaries. It uses
mock `restic` and `flock` commands and allows non-root execution. A pass does
not verify real encryption, Linux permissions, container startup, or locking.

## Container build and runtime checks

Use a native Linux AMD64 Docker host for the full container checks. ARM-host
emulation may fail on process-group operations used by supervised services;
an emulated build or unit-test pass is not a substitute for native testing.

```sh
docker build --platform linux/amd64 -t restic-appbox:development .
docker image inspect restic-appbox:development \
  --format '{{json .Config}}'
```

Verify that the final image has no declared `VOLUME`, uses `/init` as its
entrypoint, and exposes container ports 8000 and 2222. Mount persistent storage
at `/srv/restic-sftp/data` when starting a container. Local runs must set
`SKIP_APPBOX_CALLBACK=1`; creating repositories is an explicit manager step,
not an automatic consequence of starting the container.

The scripts below are meant to run **inside a disposable container as root**:

- `tests/container_release_test.sh bootstrap`: create the test repository,
  write a small backup, and verify repository integrity and file permissions.
- `tests/container_release_test.sh verify`: verify an existing test backup
  after restart or upgrade.
- `tests/container_release_test.sh rollback`: exercise configuration rollback,
  real repository locking, disabled schedules, and retention.
- `tests/container_ssh_listing_test.sh`: run the restricted SSH command in the
  real chroot as UID/GID 1000 and check that sensitive files remain unreadable.

The container scripts expect `USERNAME=admin`, generated `PASSWORD` and
`RESTIC_PASSWORD` values, `INITIAL_REPOSITORY=default`, `SSH_ENABLED=0`, and
`SKIP_APPBOX_CALLBACK=1`. Pass credentials through environment variables, not
literal command-line values. These scripts intentionally fail when required
privileged checks cannot run.

## Full release gate

`tests/release_gate.sh` accepts two arguments: a locally built candidate tag
that is not yet published, and a previously published image pinned by digest.
Both images must implement the manager protocol exercised by the tests.

```sh
bash tests/release_gate.sh \
  registry.example.test/restic:candidate \
  registry.example.test/restic@sha256:REPLACE_WITH_PREVIOUS_IMAGE_DIGEST
```

Replace both example references with your own registry and image identities.
The previous digest must contain 64 lowercase hexadecimal characters. Registry
authentication and the candidate build must already be available on the test
host. The gate requires Bash, Docker, jq, and OpenSSL on native Linux AMD64.

The gate exercises fresh installation, upgrade, restart, real locking, SSH
listing, and rollback. It creates uniquely labelled disposable containers and
volumes and removes only those resources. It also verifies registry access
and refuses an existing candidate tag or an indeterminate registry response.
It does not publish an image or modify an app catalog.

## Client-level acceptance

With a disposable repository, use a real Restic client to back up a small
folder, inspect snapshots, run `restic check --read-data`, restore into a new
directory, and compare filenames and hashes. Test the REST and optional SFTP
transports separately. Writable SFTP bypasses REST append-only protection.

When validating the Appbox integration, check repository creation, retention
editing, operation completion feedback, and hidden/revealed credential fields.
Appbox integration requires a compatible control plane; this repository does
not contain its deployment configuration or credentials.
