#!/usr/bin/env bash
# test-nightly-state.sh
set -euo pipefail

ci_root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "${t}"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

# A ci whose nightly inputs are a script, the pins and the workflow, and a file the nightly does not use.
ci="${t}/ci"
mkdir -p "${ci}/hack" "${ci}/.github/workflows"
echo 'echo e2e' >"${ci}/hack/e2e-alpha.sh"
echo 'KIND=kindest/node@sha256:aaaa' >"${ci}/images.lock"
echo 'KIND_BIN=kind' >"${ci}/tools.lock"
echo 'name: sealhouse-nightly' >"${ci}/.github/workflows/sealhouse-nightly.yaml"
echo ci >"${ci}/README.md"
git -C "${ci}" init -q -b main
git -C "${ci}" add -A
git -C "${ci}" commit -q -m ci

alpha="${t}/head.env" images="${t}/images" state="${t}/state" next="${t}/next"
echo 'CSV=secure-sign-pqc-operator.v0.1.0-alpha.11' >"${alpha}"
printf '%s\n' 'cosign c1 sha256:c1' 'fulcio f1 sha256:f1' >"${images}"
: >"${state}"
plan() { TODAY="$1" "${ci_root}/hack/nightly-state.sh" plan "${ci}" "${state}" "${alpha}" "${images}" "${next}" 2>"${t}/why"; }
expect() { # TODAY E2E REBUILD
  local out
  out="$(plan "$1")"
  [ "${out}" = "e2e=$2"$'\n'"rebuild=$3" ] || fail "on $1 expected e2e=$2 rebuild=$3, planned: ${out//$'\n'/ } ($(tr '\n' ' ' <"${t}/why"))"
}
pass() { "${ci_root}/hack/nightly-state.sh" merge "${state}" "${next}" "$@" >"${t}/merged" && mv "${t}/merged" "${state}"; }

expect 2026-11-06 true '["cosign","fulcio"]'
grep -q '^e2e: runs, no green run on record' "${t}/why" || fail "no reason given: $(cat "${t}/why")"
pass e2e rebuild/cosign rebuild/fulcio
expect 2026-11-07 false '[]'
grep -q '^rebuild/fulcio: unchanged since the green run on 2026-11-06; skipped' "${t}/why" || fail "no skip given: $(cat "${t}/why")"
ok "the first night runs everything, and a night with the same inputs runs nothing"

echo 'CSV=secure-sign-pqc-operator.v0.1.0-alpha.12' >"${alpha}"
expect 2026-11-07 true '[]'
printf '%s\n' 'cosign c1 sha256:c1' 'fulcio f2 sha256:f2' >"${images}"
expect 2026-11-07 true '["fulcio"]'
ok "a new alpha runs the e2e only, and a new fork image rebuilds that fork only"

# The e2e fails and fulcio's rebuild passes: the e2e stays due, fulcio does not.
pass rebuild/fulcio
expect 2026-11-08 true '[]'
grep -q '^e2e: runs, its inputs changed since the green run on 2026-11-06' "${t}/why" || fail "unexpected reason: $(cat "${t}/why")"
pass e2e
expect 2026-11-08 false '[]'
ok "a failed job stays due until it passes, and a passed one is recorded alone"

echo docs >>"${ci}/README.md"
git -C "${ci}" commit -q -am docs
expect 2026-11-08 false '[]'
echo 'KIND=kindest/node@sha256:bbbb' >"${ci}/images.lock"
git -C "${ci}" commit -q -am "new kind image"
expect 2026-11-08 true '["cosign","fulcio"]'
pass e2e rebuild/cosign rebuild/fulcio
ok "a ci change the nightly does not run skips, and one it runs reruns everything"

expect 2026-11-14 false '[]'
expect 2026-11-15 true '["cosign","fulcio"]'
grep -q '^e2e: runs, the last green run, on 2026-11-08, is a week old' "${t}/why" || fail "unexpected reason: $(cat "${t}/why")"
out="$(FULL=1 plan 2026-11-09)"
[ "${out}" = $'e2e=true\nrebuild=["cosign","fulcio"]' ] || fail "a dispatch planned: ${out//$'\n'/ }"
ok "a week-old green run and a dispatch run everything"
