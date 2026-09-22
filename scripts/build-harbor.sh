#!/usr/bin/env bash
# Rebuild + push the fleet hermes-agent image from this checkout.
#
# Two-stage build, zero local divergence on the upstream Dockerfile:
#   :base — built from the pristine upstream Dockerfile (full app image)
#   :main — built from Dockerfile.local (fleet overlay: gh/glab, future deltas)
#
# The upstream Dockerfile must be clean: fleet deltas live in Dockerfile.local
# only, so `git merge origin/main` never conflicts on the Dockerfile and no
# stash/pop is ever needed.
#
# Usage:
#   scripts/build-harbor.sh           # build + verify + push
#   scripts/build-harbor.sh --no-push # build + verify only (local test)
set -euo pipefail
cd "$(dirname "$0")/.."

REG=harbor.home.xomar.com/hermes-agent/hermes-agent
SHA=$(git rev-parse HEAD)
PUSH=1
[ "${1:-}" = "--no-push" ] && PUSH=0

if ! git diff --quiet -- Dockerfile && ! git diff --cached --quiet -- Dockerfile; then
    echo "ERROR: Dockerfile has uncommitted local edits." >&2
    echo "       Fleet deltas belong in Dockerfile.local — commit them there" >&2
    echo "       (or revert: git checkout -- Dockerfile) and re-run." >&2
    exit 1
fi

echo "==> building :base from pristine Dockerfile (sha $SHA)"
docker build --build-arg HERMES_GIT_SHA="$SHA" -t "$REG:base" .

echo "==> building :main from Dockerfile.local overlay"
docker build --build-arg HERMES_GIT_SHA="$SHA" -t "$REG:main" -f Dockerfile.local .

echo "==> verifying :main contents before push"
CID=$(docker create "$REG:main")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
docker cp "$CID":/usr/local/bin/glab /tmp/glab.verify && /tmp/glab.verify --version
docker cp "$CID":/usr/bin/gh /tmp/gh.verify && /tmp/gh.verify --version | head -1
docker cp "$CID":/opt/hermes/.hermes_build_sha /tmp/sha.verify
[ "$(cat /tmp/sha.verify)" = "$SHA" ] || { echo "build sha mismatch" >&2; exit 1; }
rm -f /tmp/glab.verify /tmp/gh.verify /tmp/sha.verify

if [ "$PUSH" = 1 ]; then
    docker push "$REG:base"
    docker push "$REG:main"
    echo "==> pushed $REG:base and $REG:main (source sha $SHA)"
    echo "    remember: rollout restart the hermes-agent deployments on xomar"
else
    echo "==> --no-push: image local only"
fi
