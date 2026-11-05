#!/usr/bin/env bash
# build-image.sh REPO_DIR TAG
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

repo="$(cd "$1" && pwd)"
tag="$2"
registry="${REGISTRY_HOST:-localhost:5001}"

# shellcheck disable=SC1091
source "${repo}/.sealhouse/build.env"

"${root}/hack/verify-base-images.sh" >&2

version="$(git -C "${repo}" describe --tags --always --dirty)"
commit="$(git -C "${repo}" rev-parse HEAD)"
epoch="$(git -C "${repo}" log -1 --format=%ct HEAD)"
ldflags=""
if [ -n "${LDFLAGS_PKG:-}" ]; then
  ldflags="-X ${LDFLAGS_PKG}.gitVersion=${version} -X ${LDFLAGS_PKG}.gitCommit=${commit} -X ${LDFLAGS_PKG}.gitTreeState=clean"
fi

ref="${registry}/sealhouse/${IMAGE}:${tag}"
cache=()
if [ "${BUILD_NO_CACHE:-}" = 1 ]; then cache=(--no-cache); fi
docker build "${cache[@]}" -f "${repo}/${CONTAINERFILE}" \
  --build-arg BUILDER="$(lock HI_GO_BUILDER)" \
  --build-arg RUNTIME="$(lock HI_CORE_RUNTIME)" \
  --build-arg LDFLAGS="${ldflags}" \
  --build-arg SOURCE_DATE_EPOCH="${epoch}" \
  --provenance=false \
  --label org.opencontainers.image.revision="${commit}" \
  --label org.opencontainers.image.version="${version}" \
  --output "type=image,name=${ref},rewrite-timestamp=true,unpack=false,oci-mediatypes=true" "${repo}" >&2

"${root}/hack/test-image.sh" "${repo}" "${ref}" >&2

start_registry
docker push "${ref}" >&2
insecure=()
case "${registry}" in localhost:*) insecure=(--insecure) ;; esac
digest="$(crane digest "${insecure[@]}" "${ref}")"
echo "${IMAGE}@${digest}"
