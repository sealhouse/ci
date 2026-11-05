#!/usr/bin/env bash
# last-image.sh REPO COMMIT BRANCH prints "COMMIT DIGEST" for the newest first-parent commit, COMMIT or before it,
# whose merge lane pushed an image to REGISTRY_HOST, and nothing if none of the last 50 did.
set -euo pipefail

repo="$1" commit="$2" branch="$3"
registry="${REGISTRY_HOST:-localhost:5001}"
crane_args=()
case "${registry}" in localhost:*) crane_args=(--insecure) ;; esac
image="$(git -C "${repo}" show "${commit}:.sealhouse/build.env" | sed -n 's/^IMAGE=//p')"
[ -n "${image}" ] || { echo "${commit} has no IMAGE in .sealhouse/build.env" >&2; exit 1; }
for c in $(git -C "${repo}" rev-list --first-parent --max-count=50 "${commit}"); do
  # merge.yaml tags the image <branch>-<commit>.
  if digest="$(crane digest "${crane_args[@]}" "${registry}/sealhouse/${image}:${branch//\//-}-${c:0:12}" 2>/dev/null)"; then
    echo "${c} ${digest}"
    exit 0
  fi
done
