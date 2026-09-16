#!/bin/bash
# Native AMD64 release gate. Only disposable, uniquely labelled resources are removed.
set -Eeuo pipefail
image=${1:?image reference required}
previous=${2:?previous image reference with immutable sha256 digest required}
[[ $# == 2 && $image != -* && $image != *[[:space:]]* && $image != *@* ]]
[[ $previous =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ && $previous != -* ]]
[[ $(uname -m) == x86_64 ]]
cd "$(dirname "$0")/.."
docker image inspect "$image" | jq -e '
    .[0] | .Architecture == "amd64" and .Os == "linux" and
    .Config.Volumes == null and .Config.Entrypoint == ["/init"] and
    (.Config.ExposedPorts | keys) == ["2222/tcp", "8000/tcp"] and
    .Config.Labels["org.opencontainers.image.licenses"] == "BSD-2-Clause" and
    .Config.Labels["org.opencontainers.image.source"] == "https://github.com/restic/rest-server" and
    .Config.Labels["org.opencontainers.image.version"] == "0.14.0"' >/dev/null
release_tmp=$(mktemp -d /tmp/restic-release-gate.XXXXXX)
release_id="restic-release-$(basename "$release_tmp")"
containers=()
volumes=()
cleanup() {
    local name
    for name in "${containers[@]}"; do
        if [[ $(docker inspect --format '{{index .Config.Labels "restic-release-test"}}' "$name" 2>/dev/null) == "$release_id" ]]; then
            docker rm -f "$name" >/dev/null
        fi
    done
    for name in "${volumes[@]}"; do
        if [[ $(docker volume inspect --format '{{index .Labels "restic-release-test"}}' "$name" 2>/dev/null) == "$release_id" ]]; then
            docker volume rm "$name" >/dev/null
        fi
    done
    case "$release_tmp" in /tmp/restic-release-gate.??????) rm -rf -- "$release_tmp" ;; esac
}
trap cleanup EXIT
# Generated, disposable credentials never appear in diagnostics or command arguments.
export PASSWORD RESTIC_PASSWORD
PASSWORD=$(openssl rand -hex 24)
RESTIC_PASSWORD=$(openssl rand -hex 24)
run_container() {
    local name=$1 image_ref=$2 volume=$3
    containers+=("$name")
    docker run -d --name "$name" --label "restic-release-test=$release_id" \
        --platform linux/amd64 -e USERNAME=admin -e PASSWORD -e RESTIC_PASSWORD \
        -e INITIAL_REPOSITORY=default -e SSH_ENABLED=0 -e SKIP_APPBOX_CALLBACK=1 \
        -v "$volume:/srv/restic-sftp/data" "$image_ref" >/dev/null
}
for scenario in fresh upgrade; do
    volume="$release_id-$scenario"
    volumes+=("$volume")
    docker volume create --label "restic-release-test=$release_id" "$volume" >/dev/null
    name="$release_id-$scenario"
    if [[ $scenario == upgrade ]]; then
        docker pull --platform linux/amd64 "$previous" >/dev/null
        run_container "$name-old" "$previous" "$volume"
        docker exec -i "$name-old" bash -s -- bootstrap <tests/container_release_test.sh
        docker stop "$name-old" >/dev/null
        docker rm "$name-old" >/dev/null
    fi
    run_container "$name" "$image" "$volume"
    mode=bootstrap
    [[ $scenario == upgrade ]] && mode=verify
    docker exec -i "$name" bash -s -- "$mode" <tests/container_release_test.sh
    docker exec -i "$name" bash -s <tests/container_ssh_listing_test.sh
    docker exec -i "$name" bash -s -- rollback <tests/container_release_test.sh
    docker restart "$name" >/dev/null
    docker exec -i "$name" bash -s -- verify <tests/container_release_test.sh
    docker exec -i "$name" bash -s <tests/container_ssh_listing_test.sh
done
# Prove registry access first. Only the explicit manifest-not-found diagnostic
# is accepted for the new tag; authentication/transport/other errors fail closed.
docker manifest inspect "$previous" >/dev/null
if docker manifest inspect "$image" >"$release_tmp/manifest" 2>"$release_tmp/error"; then
    echo 'Refusing to overwrite an existing image tag' >&2; exit 1
fi
if [[ $(<"$release_tmp/error") != "no such manifest: $image" ]]; then
    echo 'Registry state is indeterminate; publication denied' >&2; exit 1
fi
printf 'Release gate passed for %s; new registry tag is absent.\n' "$image"
