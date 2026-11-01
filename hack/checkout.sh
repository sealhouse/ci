#!/usr/bin/env bash
# checkout.sh <sha>
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <sha>" >&2; exit 2; }
sha="$1"
git init -q .
if [ -n "${SOURCE:-}" ]; then
  echo "$(git -C "${SOURCE}" rev-parse --path-format=absolute --git-common-dir)/objects" >.git/objects/info/alternates
  git -C "${SOURCE}" for-each-ref --format='create %(refname) %(objectname)' refs/tags | git update-ref --stdin
else
  : "${HEAD_REPO:?HEAD_REPO or SOURCE must be set}"
  git fetch -q --tags "${HEAD_REPO}" "${sha}"
fi
git checkout -q -f --detach "${sha}"
git clean -qfdx
[ "$(git rev-parse HEAD)" = "$(git rev-parse "${sha}^{commit}")" ] || { echo "checked out $(git rev-parse HEAD), not ${sha}" >&2; exit 1; }
echo "$(git log -1 --format='%h %s') ($(git rev-list --count HEAD) commits)"
