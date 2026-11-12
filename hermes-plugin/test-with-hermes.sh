#!/usr/bin/env bash
# Skill reviews against Hermes itself, in a container: builds an image that holds Hermes at one
# commit with the dependencies its uv.lock pins (tests/hermes/Dockerfile), then runs
# tests/test_reviews_hermes.py in it with this directory mounted read-only. Needs Docker and git.
#
#   ./test-with-hermes.sh                  the six tests
#   ./test-with-hermes.sh <command...>     something else in the container, e.g. `python -m pytest -q`
#
#   HERMES_REF=<commit>          another Hermes than the one pinned below
#   HERMES_TEST_CA=<file.pem>    a CA to trust while building (a proxy that re-signs TLS)
#   HERMES_TEST_NETWORK=host     the network to build on (a proxy listening on the host's loopback)
set -euo pipefail

# NousResearch/hermes-agent as shion/reviews.py (HermesLedger) was last read against. Move it on when
# the server's Hermes moves on: a ledger the plugin no longer reads right fails the tests.
HERMES_REF="${HERMES_REF:-611bf53e5b31a4ea084594a643fbeae8cb1827de}"
HERMES_REPO="${HERMES_REPO:-https://github.com/NousResearch/hermes-agent}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
image="shion-hermes-test"

# Hermes's tree at that commit, fetched here and handed to the build as a context of its own
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git init --quiet "$work/git"
git -C "$work/git" fetch --quiet --depth 1 "$HERMES_REPO" "$HERMES_REF"
mkdir "$work/hermes"
git -C "$work/git" archive FETCH_HEAD | tar -x -C "$work/hermes"
echo "Hermes at $(git -C "$work/git" rev-parse FETCH_HEAD)"

build=(docker build --file "$here/tests/hermes/Dockerfile" --tag "$image" --build-context "hermes=$work/hermes")
[ -n "${HERMES_TEST_CA:-}" ] && build+=(--secret "id=ca,src=$HERMES_TEST_CA")
[ -n "${HERMES_TEST_NETWORK:-}" ] && build+=(--network "$HERMES_TEST_NETWORK")
for name in HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
    [ -n "${!name:-}" ] && build+=(--build-arg "$name=${!name}")
done
# the main context is the Dockerfile's own directory: nothing of the plugin goes into the image
DOCKER_BUILDKIT=1 "${build[@]}" "$here/tests/hermes"

# no network: these tests write skills into a home of their own and call nothing
docker run --rm --network none --volume "$here:/plugin:ro" "$image" "$@"
