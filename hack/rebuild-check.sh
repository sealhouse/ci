#!/usr/bin/env bash
# rebuild-check.sh TREE PUBLISHED_REGISTRY rebuilds a fork's rhtas/main commit and compares its digest.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

tree="$(cd "$1" && pwd)" published="$2"
name="$(basename "${tree}")"
# A merge that changes nothing an image is built from pushes none, so check the commit that pushed the one in use.
last="$(REGISTRY_HOST="${published}" "${root}/hack/last-image.sh" "${tree}" HEAD rhtas/main)"
if [ -z "${last}" ]; then
  echo "${name}: no image in ${published} for the last 50 commits of rhtas/main; skipped"
  exit 0
fi
sha="${last%% *}" pushed="${last#* }"
if [ "${sha}" != "$(git -C "${tree}" rev-parse HEAD)" ]; then
  echo "${name}: rhtas/main $(git -C "${tree}" rev-parse --short=12 HEAD) builds the image ${sha:0:12} pushed; rebuilding ${sha:0:12}"
  git -C "${tree}" checkout -q --detach "${sha}"
fi
tag="rhtas-main-${sha:0:12}"
ci_wt="$(ci_worktree "$(ci_pin "${tree}/.github/workflows/sealhouse-merge.yaml" merge.yaml)")"
image="$(sed -n 's/^IMAGE=//p' "${tree}/.sealhouse/build.env")"
crane_args=()
case "${published}" in localhost:*) crane_args=(--insecure) ;; esac
# The merge lane's describe, which tags the sync has pushed since would change. It must still describe HEAD.
version="$(crane config "${crane_args[@]}" "${published}/sealhouse/${image}@${pushed}" | jq -r '.config.Labels["org.opencontainers.image.version"] // ""')"
describes_head() {
  if [[ "$1" =~ ^(.+)-([0-9]+)-g([0-9a-f]+)$ ]]; then
    [[ "${sha}" == "${BASH_REMATCH[3]}"* ]] &&
      git -C "${tree}" rev-parse -q --verify "refs/tags/${BASH_REMATCH[1]}^{commit}" >/dev/null &&
      [ "$(git -C "${tree}" rev-list --count "refs/tags/${BASH_REMATCH[1]}..HEAD")" = "${BASH_REMATCH[2]}" ]
  elif [[ "$1" =~ ^[0-9a-f]{7,}$ ]]; then
    [[ "${sha}" == "$1"* ]]
  else
    [ -n "$1" ] && [ "$(git -C "${tree}" rev-parse -q --verify "refs/tags/$1^{commit}")" = "${sha}" ]
  fi
}
if ! describes_head "${version}"; then
  echo "${name}: ${image}:${tag} records version '${version}', which does not describe ${sha:0:12}" >&2
  exit 1
fi
rebuilt="$(BUILD_VERSION="${version}" REGISTRY_HOST="${REBUILD_REGISTRY:?}" BUILD_NO_CACHE=1 "${ci_wt}/hack/build-image.sh" "${tree}" "${tag}" | tail -1)"
if [ "${rebuilt#*@}" != "${pushed}" ]; then
  echo "${name}: the rebuild is ${rebuilt#*@}, the merge lane pushed ${pushed}" >&2
  exit 1
fi
echo "${name}: reproducible, ${pushed}"
