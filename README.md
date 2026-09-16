# Restic server for Appbox

This image provides a private Restic REST backend and an optional restricted
SFTP backend. s6-overlay supervises `rest-server`, `crond`, and `sshd`; SSH is
disabled unless `SSH_ENABLED=1`.

This is Appbox's container packaging, not the upstream Restic client or REST
server project. Upstream projects are [restic](https://github.com/restic/restic)
and [rest-server](https://github.com/restic/rest-server).

## Building and integration

```sh
docker build -t restic-appbox:development .
```

The checked-in `appbox.yml` uses a local development image name. It is an
integration template, not a published catalog release. To deploy your own
build, supply your registry, version, tag, and immutable image digest. The
manifest requires compatible Appbox Custom Table and typed-operation support.
Publishing this source does not publish a container image or change catalog
availability.

For a standalone container, set `USERNAME`, `PASSWORD`, and
`SKIP_APPBOX_CALLBACK=1`, mount your persistent data at `/srv/restic-sftp/data`,
and explicitly initialize repositories using the manager below. SSH is
optional. Appbox-managed callbacks require `APPBOX_API_URL` (the API base URL),
`INSTANCE_ID`, and `CALLBACK_TOKEN`. No deployment URL or token is included.
The callback authentication header and compatibility executable name are kept
for protocol compatibility.

See [TESTING.md](TESTING.md) for local checks and native container testing.

## Persistent layout

The Appbox `data` volume is mounted at `/srv/restic-sftp/data`. The parent
`/srv/restic-sftp` remains root-owned as required by OpenSSH chroot validation,
while UID/GID 1000 owns the data directory. The REST password file lives
under `/srv/restic-sftp/data/.restic-manager/secrets`. Manager state and the
first-boot callback marker also persist under `.restic-manager`. The `restic`
service account has group-read access to `rest-htpasswd`; repository encryption
passwords and manager configuration remain root-only. The manager reconciles
saved repository configuration and schedules when the container starts.

The upstream image declares `VOLUME /data`. Because Dockerfile metadata cannot
unset an inherited volume, this Dockerfile builds the runtime filesystem in an
upstream-based stage and copies it into a final `scratch` stage. The final image
therefore has no declared volumes; `appbox.yml` is the sole local storage
mapping source and declares only `/srv/restic-sftp/data`. Existing instances
that already have a legacy `/data` mount require an explicit mount migration;
rebuilding the image cannot alter an existing container specification.

REST repositories are stored below the authenticated user's private namespace
and addressed below the same URL, for example:

```text
rest:https://USER:PASSWORD@example.test/USER/default
```

The `rest:` prefix is part of Restic's repository syntax. It is not a browser
URL. Use it as the repository argument, for example:

```sh
export RESTIC_REPOSITORY='rest:https://USER:REST_PASSWORD@example.test/USER/default'
export RESTIC_PASSWORD='REPOSITORY_ENCRYPTION_PASSWORD'
restic snapshots
```

`REST_PASSWORD` authenticates to the REST server. The separate
`REPOSITORY_ENCRYPTION_PASSWORD` decrypts the repository. Because embedding
the REST password makes the repository string sensitive, avoid shell history
and prefer Restic's environment or password-file options in scripts.

Managed repositories are not client-exclusive encryption: Appbox stores the
repository password, and the container retains a root-only copy for
initialization and retention. Disabling retention does not remove that copy.
Using managed repositories therefore requires trust in the service operator
and privileged server administrators.

The corresponding container path is
`/srv/restic-sftp/data/USER/default`. On first bootstrap, a verified legacy
repository at `/srv/restic-sftp/data/default` is moved into that namespace.
The move is refused if the supplied encryption password cannot open the legacy
repository or if both layouts exist.

The optional SFTP endpoint always uses user `restic`, port 2222 inside the
container, and repository paths below `/data`. It permits only SFTP, `help`,
and `list-repositories`; shell, forwarding, TTY, tunneling, and X11 are denied.
In key mode password login is explicitly disabled. In password mode, set a
strong generated `SSH_PASSWORD`.

After Appbox assigns the public port, connect using the host and port displayed
in the installed app fields:

```sh
ssh restic@example.test -p10101
sftp -P 10101 restic@example.test
```

The SSH command does not open an interactive shell; it can only run the
restricted `help` and `list-repositories` commands. For Restic's SFTP backend,
the chroot-visible path includes `/data/USER/REPOSITORY`:

```sh
ssh restic@example.test -p10101 list-repositories
restic -r 'sftp:restic@example.test:/data/USER/default' snapshots \
  -o sftp.command='ssh restic@example.test -p 10101 -s sftp'
```

Use the private key matching the configured public key in key mode. In password
mode, use the configured SSH password. The SSH public key is not a secret and
is entered during installation; private keys must never be pasted into Appbox.
Writable SFTP accesses repository files directly and therefore bypasses REST
append-only protection.

## Repository manager

`restic-manager` is a root-only administrative interface with typed operations.
Its install-time bootstrap waits for the required s6 services and returns
success only after the repository can be unlocked, authenticated REST access
works, retention configuration matches the requested row, and cron has been
reconciled:

```text
bootstrap --repo SLUG --password-stdin --enabled 0|1 --schedule HH:MM \
  --timezone IANA --keep-daily N --keep-weekly N --keep-monthly N
init --repo SLUG --password-stdin
configure --repo SLUG --enabled 0|1 --schedule HH:MM --timezone IANA \
  --keep-daily N --keep-weekly N --keep-monthly N
reconcile --all
retention --repo SLUG
detach --repo SLUG
delete-data --repo SLUG
```

Slugs are limited to lowercase letters, numbers, and hyphens. Repository paths
cannot escape the data root. Passwords are accepted only on stdin and stored in
mode-0600 root files. Cron files are generated atomically with a once-per-minute timezone-aware due check; retention uses a per-repository `flock` and always runs
`restic forget --prune`.

`detach` removes manager configuration and its password but leaves repository
data intact. `delete-data` irreversibly removes the selected repository after
the same strict slug/path checks. Avoid retention while append-only clients are
actively writing; locking only coordinates manager jobs, not remote clients.

The repository table can create repositories and edit their scheduled
retention settings. Creation is bound to the reviewed `repository.bootstrap`
operation, and edits are bound to `repository.reconcile`; the table row is
written only after the operation is admitted. Repository names and encryption
passwords are immutable after creation. Normal row deletion remains disabled,
while manual retention and strongly confirmed permanent data deletion remain
available as row actions.

## Initial setup

The seeded repository row is initialized through the manifest's
`initial_rows_operation`; the entrypoint only prepares runtime/authentication
state and reports readiness for dispatch. The manager owns repository
initialization and retention postcondition verification. SMTP is not required.

## License

Appbox packaging and integration code is licensed under [BSD-2-Clause](LICENSE).
See [THIRD_PARTY.md](THIRD_PARTY.md) for upstream components and notices.
