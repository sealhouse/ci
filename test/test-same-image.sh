#!/usr/bin/env bash
# test-same-image.sh
set -euo pipefail

ci_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ci_root}/hack/lib.sh"
t="$(mktemp -d)"
reg_port=5006 reg=test-same-image-registry
cleanup() {
  docker rm -f "${reg}" >/dev/null 2>&1 || true
  rm -rf "${t}"
}
trap cleanup EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

docker rm -f "${reg}" >/dev/null 2>&1 || true
docker run -d --rm -p "127.0.0.1:${reg_port}:5000" --name "${reg}" "$(lock REGISTRY)" >/dev/null
export REGISTRY_HOST="localhost:${reg_port}"
until crane catalog --insecure "${REGISTRY_HOST}" >/dev/null 2>&1; do sleep 0.2; done

# A ci repo: the scripts under test, then a commit that changes no image input and one that changes the base images.
ci="${t}/ci"
mkdir -p "${ci}/hack"
cp "${ci_root}/hack/same-image.sh" "${ci_root}/hack/last-image.sh" "${ci_root}/hack/lib.sh" "${ci_root}/hack/build-image.sh" "${ci}/hack/"
echo 'HI_CORE_RUNTIME=example.com/runtime@sha256:aaaa' >"${ci}/images.lock"
echo ci >"${ci}/README.md"
git -C "${ci}" init -q -b main
git -C "${ci}" add -A
git -C "${ci}" commit -q -m ci
ci1="$(git -C "${ci}" rev-parse HEAD)"
echo docs >>"${ci}/README.md"
git -C "${ci}" commit -q -am "ci: docs"
ci2="$(git -C "${ci}" rev-parse HEAD)"
echo 'HI_CORE_RUNTIME=example.com/runtime@sha256:bbbb' >"${ci}/images.lock"
git -C "${ci}" commit -q -am "ci: new base image"
ci3="$(git -C "${ci}" rev-parse HEAD)"

# A fork whose rhtas/main moves by ci pin, by workflow and by source.
fork="${t}/fork"
mkdir -p "${fork}/.sealhouse" "${fork}/.github/workflows"
echo 'IMAGE=app' >"${fork}/.sealhouse/build.env"
echo 'package main' >"${fork}/main.go"
caller="${fork}/.github/workflows/sealhouse-merge.yaml"
printf 'jobs:\n  merge:\n    uses: sealhouse/ci/.github/workflows/merge.yaml@%s\n    with:\n      ci-ref: %s\n' "${ci1}" "${ci1}" >"${caller}"
git -C "${fork}" init -q -b rhtas/main
commit() { git -C "${fork}" add -A && git -C "${fork}" commit -q -m "$1" && git -C "${fork}" rev-parse HEAD; }
pin() { "${ci_root}/hack/pin-ci.sh" "$1" "${caller}"; }
push() { # COMMIT: what its merge lane pushes, tagged <branch>-<commit>
  tar -C "${fork}" -cf "${t}/layer.tar" main.go
  crane append --insecure -f "${t}/layer.tar" -t "${REGISTRY_HOST}/sealhouse/app:rhtas-main-${1:0:12}" >/dev/null 2>&1
}
f1="$(commit "source")"
pin "${ci2}"
f2="$(commit "UPSTREAM: <drop>: Pin ci")"
echo 'name: ci' >"${fork}/.github/workflows/ci.yml"
f3="$(commit "upstream workflow")"
pin "${ci3}"
f4="$(commit "UPSTREAM: <drop>: Pin ci to a new base image")"
echo '// change' >>"${fork}/main.go"
f5="$(commit "source change")"

same() { "${ci}/hack/same-image.sh" "${fork}" "$1" "$2" 2>/dev/null; }
same "${f1}" "${f2}" || fail "a pin to a ci commit with the same image inputs changed the image"
same "${f1}" "${f3}" || fail "a new workflow changed the image"
if same "${f1}" "${f4}"; then fail "a pin to new base images kept the image"; fi
if same "${f4}" "${f5}"; then fail "a source change kept the image"; fi
same "${f4}" "${f4}" || fail "a commit builds a different image from itself"
ok "same-image ignores .github/ and ci pins that change no image input, and catches base images and source"

last() { "${ci}/hack/last-image.sh" "${fork}" "$1" rhtas/main; }
[ -z "$(last "${f5}")" ] || fail "found an image where none was pushed"
push "${f1}"
[ "$(last "${f3}" | cut -d' ' -f1)" = "${f1}" ] || fail "the image f1 pushed not found from f3"
[[ "$(last "${f3}" | cut -d' ' -f2)" == sha256:* ]] || fail "no digest for f1's image"
push "${f4}"
[ "$(last "${f5}" | cut -d' ' -f1)" = "${f4}" ] || fail "an older image hid the newest"
[ "$(last "${f4}" | cut -d' ' -f1)" = "${f4}" ] || fail "a commit's own image not found"
ok "last-image finds the newest image at or before a commit"
