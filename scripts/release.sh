#!/usr/bin/env bash
# release.sh — cut or patch a stable release of the demo rig.
#
#   scripts/release.sh vX.Y.0            cut a new release from CURRENT main
#   scripts/release.sh --patch vX.Y.Z    release the CURRENT stable branch as-is
#                                        (hotfix flow: commit e.g. an images.env pin
#                                        bump on `stable`, then --patch)
#
# What a release is: the `stable` branch moves to a commit whose only deltas vs the
# released code are channel defaults (bootstrap/kit default REF=stable, KIT_REF_PIN
# = exact starter-kit commit); tag vX.Y.Z marks it immutably. The launcher image
# digest is retagged :stable + :vX.Y.Z (no rebuild); the extension is rebuilt with
# CHANNEL=stable and published as :stable + :vX.Y.Z.
# Needs: git push rights, gh (repo + workflow), AWS creds able to tag in ECR.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

MODE=cut; [[ "${1:-}" == "--patch" ]] && { MODE=patch; shift; }
VER="${1:?usage: release.sh [--patch] vX.Y.Z}"
[[ "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like v1.2.3"
git diff --quiet && git diff --cached --quiet || die "working tree not clean"
git fetch -q origin main stable --tags 2>/dev/null || git fetch -q origin main --tags

ECR=123517950721.dkr.ecr.us-east-1.amazonaws.com
LAUNCHER=$ECR/io.corewaf.ghcr/rig/launcher

if [[ "$MODE" == cut ]]; then
    KIT_SHA=$(git ls-remote https://github.com/ext-corero/corewaf-starter-kit.git refs/heads/main | cut -f1)
    [[ -n "$KIT_SHA" ]] || die "cannot resolve starter-kit main"
    git checkout -q -B stable origin/main
    sed -i "s/COREWAF_RIG_REF:-main/COREWAF_RIG_REF:-stable/" bootstrap.sh kit.sh
    sed -i "s/^KIT_REF_PIN=.*/KIT_REF_PIN=$KIT_SHA/" images.env
    git add -A; git commit -qm "release $VER: stable channel defaults (REF=stable, starter-kit @${KIT_SHA:0:7})"
else
    git checkout -q stable; git pull -q --ff-only origin stable
fi
git tag -a "$VER" -m "demo rig $VER"
git push -q origin stable "$VER"
echo "git: stable -> $(git rev-parse --short HEAD), tag $VER"

# launcher: retag the digest currently behind :latest
docker buildx imagetools create -t "$LAUNCHER:stable" -t "$LAUNCHER:$VER" "$LAUNCHER:latest"
echo "launcher: :stable and :$VER now point at the :latest digest"

# extension: stable-channel build via workflow dispatch
gh workflow run extension-image.yml -f channel=stable -f version="$VER"
echo "extension: dispatched stable build (gh run watch to follow)"

gh release create "$VER" --target stable --title "demo rig $VER" \
  --notes "Stable channel release. Entry points: bootstrap (stable branch URL), launcher :stable / :$VER, extension :stable / :$VER. All rig images pinned by images.env at tag $VER." \
  2>/dev/null || echo "note: gh release create skipped/failed (may exist)"
git checkout -q main
echo "done — back on main"
