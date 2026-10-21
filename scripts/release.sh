#!/usr/bin/env bash
# Cuts a chart release: sets Chart.yaml's version, commits it, and tags that commit.
# It never pushes -- it prints the push commands so you review first.
#
#   scripts/release.sh 0.1.1
#
# Run it on an up-to-date `main` with a clean working tree.
set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 MAJOR.MINOR.PATCH   (for example $0 0.1.1)" >&2
  exit 2
fi
TAG="v${VERSION}"

cd "$(git rev-parse --show-toplevel)"

if [ "$(git branch --show-current)" != "main" ]; then
  echo "refusing: not on main (on '$(git branch --show-current)')" >&2; exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "refusing: working tree has uncommitted changes" >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "refusing: tag ${TAG} already exists (released tags are never reused or moved)" >&2; exit 1
fi

sed -i -E "s/^version:.*/version: ${VERSION}/" Chart.yaml
git add Chart.yaml
git commit -m "Release ${VERSION}"
git tag -a "${TAG}" -m "helm-chart-bridge ${VERSION}"

echo
echo "Created commit and tag ${TAG} locally. Nothing has been pushed."
echo "Check it, then push the branch and the tag to each remote that tenants read from:"
echo "  git push <remote> main ${TAG}"
echo "Then give the operator the new default for NEW tenants (HELM_CHART_VERSION=${TAG})."
