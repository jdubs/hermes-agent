#!/usr/bin/env bash
# Fleet image build for hermes-agent — pinned-base model.
#
# Harbor layout (harbor.home.xomar.com/hermes-agent/hermes-agent):
#   :base-<sha7>  immutable, built from the PRISTINE upstream Dockerfile at
#                 exactly the pinned upstream sha — in a detached git worktree,
#                 so no branch ever moves and no merge is ever needed
#   :base         mutable alias, re-pointed at the newest :base-<sha7>
#   :main         fleet overlay (Dockerfile.local: CLIs + honcho plugin)
#                 built on top of the pinned base
#
# Upstream pushes change nothing. The fleet only moves when you run one of:
#   scripts/fleet-image.sh base [UPSTREAM_SHA]    # re-pin: default origin/main
#   scripts/fleet-image.sh overlay                # overlay-only change (no git)
#   scripts/fleet-image.sh update [UPSTREAM_SHA]  # base + overlay, one command
#   scripts/fleet-image.sh status                 # pin vs upstream vs harbor
# Add --no-push to build + verify locally only.
#
# Rollback: `base <old-sha>` re-points the pin; the immutable :base-<sha7> is
# reused (Harbor GC only deletes untagged artifacts), then `overlay`.
set -euo pipefail
cd "$(dirname "$0")/.."

REG=harbor.home.xomar.com/hermes-agent/hermes-agent
UP_REMOTE=origin              # upstream (NousResearch) — fetched, never merged
PIN_FILE=fleet/base.sha
FLEET_BRANCH=fleet

PUSH=1
cmd=""
arg=""
for a in "$@"; do
    case "$a" in
        --no-push) PUSH=0 ;;
        base|overlay|update|status) cmd="$a" ;;
        *) arg="$a" ;;
    esac
done
[ -n "$cmd" ] || { grep '^#   scripts/' "$0" | sed 's/^#   //'; exit 2; }

short() { printf '%s' "${1:0:7}"; }

# --- status -----------------------------------------------------------------
if [ "$cmd" = status ]; then
    git fetch "$UP_REMOTE" --quiet
    upstream_head=$(git rev-parse "$UP_REMOTE/main^{commit}")
    if [ -f "$PIN_FILE" ]; then
        pin=$(tr -d '[:space:]' < "$PIN_FILE")
        echo "pin:          ${pin}  ($(short "$pin"))"
        if [ "$pin" = "$upstream_head" ]; then
            echo "upstream:     $upstream_head  (pin is current)"
        else
            echo "upstream:     $upstream_head  (pin is BEHIND — run 'update' when ready)"
        fi
        if docker manifest inspect "$REG:base-$(short "$pin")" >/dev/null 2>&1; then
            echo "harbor:       :base-$(short "$pin") present"
        else
            echo "harbor:       :base-$(short "$pin") MISSING — run 'base' to build it"
        fi
    else
        echo "pin:          none ($PIN_FILE missing)"
        echo "upstream:     $upstream_head"
    fi
    exit 0
fi

# --- base / update require the fleet branch (they rewrite + commit the pin) --
need_fleet() {
    local br
    br=$(git branch --show-current)
    [ "$br" = "$FLEET_BRANCH" ] || {
        echo "ERROR: '$cmd' must run on the $FLEET_BRANCH branch (currently: ${br:-detached})." >&2
        echo "       cd ~/personal/hermes-agent && git checkout $FLEET_BRANCH" >&2
        exit 1
    }
}

build_base() {
    local sha wt
    sha=$(git rev-parse "${arg:-$UP_REMOTE/main}^{commit}")
    echo "==> base: upstream sha $sha ($(short "$sha"))"
    git fetch "$UP_REMOTE" --quiet
    wt=$(mktemp -d "${TMPDIR:-/tmp}/ha-base-XXXXXX")
    trap 'git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"' RETURN
    git worktree add --detach --quiet "$wt" "$sha"
    # Pristine by construction: the worktree IS upstream at $sha — the fleet
    # branch's working tree (and its dirty state) is never the build context.
    docker build -f "$wt/Dockerfile" \
        --build-arg HERMES_GIT_SHA="$sha" \
        -t "$REG:base-$(short "$sha")" -t "$REG:base" "$wt"
    if [ "$PUSH" = 1 ]; then
        docker push "$REG:base-$(short "$sha")"
        docker push "$REG:base"
    fi
    # Repoint the pin and record it in git history (audit trail).
    if [ "$PUSH" = 1 ] && [ "$(tr -d '[:space:]' < "$PIN_FILE" 2>/dev/null || true)" != "$sha" ]; then
        echo "$sha" > "$PIN_FILE"
        git add "$PIN_FILE"
        git commit --quiet -m "chore(fleet): pin base to $(short "$sha")
$(git log --oneline -1 "$sha" | sed 's/^/    upstream: /')"
        echo "==> pin committed to $FLEET_BRANCH — push with: git push $FLEET_REMOTE $FLEET_BRANCH"
    elif [ "$PUSH" = 1 ]; then
        echo "==> pin already at $sha"
    fi
    if [ "$PUSH" = 1 ]; then
        echo "==> base done: $REG:base-$(short "$sha") pushed"
    else
        echo "==> --no-push: $REG:base-$(short "$sha") local only (pin not updated)"
    fi
}

build_overlay() {
    local pin tag base_tag ctx cid
    [ -f "$PIN_FILE" ] || { echo "ERROR: $PIN_FILE missing — run 'base' first." >&2; exit 1; }
    pin=$(tr -d '[:space:]' < "$PIN_FILE")
    tag=$(short "$pin")
    base_tag="${BASE_TAG:-$REG:base-$tag}"
    if ! docker manifest inspect "$base_tag" >/dev/null 2>&1; then
        echo "ERROR: $base_tag not in harbor — run 'base' first." >&2
        exit 1
    fi
    echo "==> overlay: :main on $base_tag (upstream $tag)"
    # No COPY in Dockerfile.local (the base's 'COPY . .' already ships the full
    # tree at the pinned sha), so an empty context is correct and fast — and a
    # stale checkout can never leak app code into the image.
    ctx=$(mktemp -d "${TMPDIR:-/tmp}/ha-overlay-XXXXXX")
    trap 'rm -rf "$ctx"' RETURN
    docker build -f Dockerfile.local \
        --build-arg "BASE=$base_tag" \
        --build-arg HERMES_GIT_SHA="$pin" \
        -t "$REG:main" "$ctx"
    # Verify before push: tools survived and the recorded base sha matches.
    cid=$(docker create "$REG:main")
    trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -rf "$ctx"' RETURN
    docker cp "$cid":/usr/local/bin/glab /tmp/glab.verify && /tmp/glab.verify --version
    docker cp "$cid":/usr/bin/gh /tmp/gh.verify && /tmp/gh.verify --version | head -1
    docker cp "$cid":/opt/hermes/.hermes_build_sha /tmp/sha.verify
    [ "$(cat /tmp/sha.verify)" = "$pin" ] || { echo "ERROR: build sha mismatch (expected $pin)" >&2; exit 1; }
    rm -f /tmp/glab.verify /tmp/gh.verify /tmp/sha.verify
    if [ "$PUSH" = 1 ]; then
        docker push "$REG:main"
        echo "==> overlay done: $REG:main (base $tag) pushed"
        echo "    remember: rollout restart the hermes-agent deployments on xomar"
    else
        echo "==> --no-push: $REG:main local only"
    fi
}

FLEET_REMOTE=jdubs
case "$cmd" in
    base)   need_fleet; build_base ;;
    overlay) build_overlay ;;
    update) need_fleet; build_base; build_overlay ;;
esac
