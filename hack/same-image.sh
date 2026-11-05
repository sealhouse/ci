#!/usr/bin/env bash
# same-image.sh REPO BASE COMMIT passes when COMMIT builds the image BASE built, but for the commit it records:
# nothing outside .github/ differs, and the two ci pins agree on what goes into an image.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

repo="$1" base="$2" commit="$3"
git -C "${repo}" diff --quiet "${base}" "${commit}" -- . ':(exclude).github' || exit 1
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
for c in base commit; do
  git -C "${repo}" show "${!c}:.github/workflows/sealhouse-merge.yaml" >"${work}/${c}.yaml"
done
old="$(ci_pin "${work}/base.yaml" merge.yaml)"
new="$(ci_pin "${work}/commit.yaml" merge.yaml)"
[ "${old}" = "${new}" ] || git -C "${ci_root}" diff --quiet "${old}" "${new}" -- images.lock hack/build-image.sh hack/lib.sh
