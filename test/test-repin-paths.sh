#!/usr/bin/env bash
# test-repin-paths.sh: a script repin ignores must stay out of reach of the callers' lanes.
# The operator's lanes reach ci through CI_DIR; their scripts are listed here by hand.
set -euo pipefail

ci_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ci_root}"
fail() { echo "FAIL: $*" >&2; exit 1; }

mapfile -t ignored < <(sed -n '/paths-ignore:/,/^  [a-z]/p' .github/workflows/sealhouse-repin.yaml | sed -n 's/^ *- \(hack\/[^ ]*\)$/\1/p')
[ "${#ignored[@]}" -gt 0 ] || fail "no hack/ paths in repin's paths-ignore"
operator=(build-image.sh scc-namespace.sh test-arbitrary-uid.sh verify-base-images.sh)

# What the callers run: the reusable workflows and every hack/ file repin does not ignore.
reach=(.github/workflows/pr.yaml .github/workflows/merge.yaml .github/workflows/sync-merge-guard.yaml)
for f in hack/*; do
  [[ " ${ignored[*]} " == *" ${f} "* ]] || reach+=("${f}")
done
for path in "${ignored[@]}"; do
  [ -f "${path}" ] || fail "repin ignores ${path}, which does not exist"
  name="$(basename "${path}")"
  [[ " ${operator[*]} " != *" ${name} "* ]] || fail "repin ignores ${path}, which the operator's lanes run"
  for f in "${reach[@]}"; do
    if grep -qF "${name}" "${f}"; then fail "repin ignores ${path}, but ${f} uses it"; fi
  done
done
echo "ok: repin ignores ${#ignored[@]} hack scripts, none of them reachable from a caller's lane"
