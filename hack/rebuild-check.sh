#!/usr/bin/env bash
# rebuild-check.sh TREE PUBLISHED_REGISTRY rebuilds a fork's rhtas/main commit and compares its digest.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

tree="$(cd "$1" && pwd)" published="$2"
sha="$(git -C "${tree}" rev-parse HEAD)"
tag="rhtas-main-${sha:0:12}"
name="$(basename "${tree}")"
ci_wt="$(ci_worktree "$(ci_pin "${tree}/.github/workflows/sealhouse-merge.yaml" merge.yaml)")"
image="$(sed -n 's/^IMAGE=//p' "${tree}/.sealhouse/build.env")"
crane_args=()
case "${published}" in localhost:*) crane_args=(--insecure) ;; esac
if ! pushed="$(crane digest "${crane_args[@]}" "${published}/sealhouse/${image}:${tag}" 2>/dev/null)"; then
  echo "${name}: no ${image}:${tag} in ${published} (its merge lane pushed none); skipped"
  exit 0
fi
rebuilt="$(REGISTRY_HOST="${REBUILD_REGISTRY:?}" BUILD_NO_CACHE=1 "${ci_wt}/hack/build-image.sh" "${tree}" "${tag}" | tail -1)"
if [ "${rebuilt#*@}" != "${pushed}" ]; then
  echo "${name}: the rebuild is ${rebuilt#*@}, the merge lane pushed ${pushed}" >&2
  exit 1
fi
echo "${name}: reproducible, ${pushed}"
