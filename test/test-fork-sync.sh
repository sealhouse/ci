#!/usr/bin/env bash
# test-fork-sync.sh
set -euo pipefail

ci_root="$(cd "$(dirname "$0")/.." && pwd)"
sync="${ci_root}/hack/fork-sync.sh"
t="$(mktemp -d)"
trap 'chmod -R u+w "${t}"; rm -rf "${t}"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# semver's dependency, which the scratch proxy does not serve.
GOMODCACHE="${t}/modcache" go -C "${ci_root}/tools/semver" mod download
export GOPROXY="file://${t}/proxy" GONOPROXY=none GOSUMDB=off GOFLAGS= GOWORK=off
export GOMODCACHE="${t}/modcache" GOTOOLCHAIN=local
gover="$(go env GOVERSION | sed -E 's/^go([0-9]+\.[0-9]+).*/\1/')"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The proxy: example.com/dep v1.0.0, v1.1.0, v1.2.0, example.com/other
# v1.0.0, v1.1.0-rc.1, v1.1.0, and the fork release github.com/sealhouse/dep
# v1.2.1-rhtas.1. publish SERVED VERSION [MODULE]: a fork release's go.mod
# keeps its upstream path.
publish() {
  local mod="${3:-$1}" ver="$2" dir="${t}/proxy/$1/@v" src="${t}/src/$1@$2"
  mkdir -p "${dir}" "${src}"
  printf 'module %s\n\ngo %s\n' "${mod}" "${gover}" >"${src}/go.mod"
  printf 'package %s\n\nconst Version = "%s"\n' "${mod##*/}" "${ver}" >"${src}/${mod##*/}.go"
  cp "${src}/go.mod" "${dir}/${ver}.mod"
  printf '{"Version":"%s","Time":"2026-01-01T00:00:00Z"}\n' "${ver}" >"${dir}/${ver}.info"
  (cd "${t}/src" && zip -qr "${dir}/${ver}.zip" "$1@$2")
  echo "${ver}" >>"${dir}/list"
}
publish example.com/dep v1.0.0
publish example.com/dep v1.1.0
publish example.com/dep v1.2.0
publish example.com/other v1.0.0
publish example.com/other v1.1.0-rc.1
publish example.com/other v1.1.0
publish github.com/sealhouse/dep v1.2.1-rhtas.1 example.com/dep

# Upstream: a module using example.com/dep v1.0.0.
up="${t}/upstream"
mkdir -p "${up}"
git -C "${up}" init -q -b main
printf 'module example.com/app\n\ngo %s\n' "${gover}" >"${up}/go.mod"
printf 'package app\n\nimport _ "example.com/dep"\n' >"${up}/app.go"
go -C "${up}" get example.com/dep@v1.0.0 2>/dev/null
git -C "${up}" add -A
git -C "${up}" commit -q -m "upstream: app"

# The fork: a plain carry and a <drop> bump to v1.1.0.
fork="${t}/fork"
git clone -q -o upstream "${up}" "${fork}"
git -C "${fork}" switch -q -c rhtas/main
echo midstream >"${fork}/MIDSTREAM"
git -C "${fork}" add MIDSTREAM
git -C "${fork}" commit -q -m "UPSTREAM: <carry>: midstream file"
go -C "${fork}" get example.com/dep@v1.1.0 2>/dev/null
git -C "${fork}" commit -q -am "UPSTREAM: <drop>: Bump example.com/dep to v1.1.0 for GO-2026-0000

Go-Get: . example.com/dep@v1.1.0"
git -C "${fork}" switch -q main
"${sync}" --check "${fork}" >/dev/null || fail "--check refused a Go-Get <drop> carry"

# version REF MODULE prints the version REF's go.mod requires.
version() { git -C "${fork}" show "$1:go.mod" | awk -v m="$2" '{ for (i = 1; i < NF; i++) if ($i == m) print $(i + 1) }' | tail -1; }
dep_version() { version "$1" example.com/dep; }

# 1. Upstream changes go.mod and go.sum under the carry: regenerated.
printf 'package app\n\nimport _ "example.com/other"\n' >"${up}/other.go"
go -C "${up}" get example.com/other@v1.0.0 2>/dev/null
git -C "${up}" add -A
git -C "${up}" commit -q -m "upstream: use other"
out="$("${sync}" "${fork}")"
grep -q '^regenerated .*Bump example.com/dep' <<<"${out}" || fail "carry not regenerated: ${out}"
[ "$(dep_version rhtas/sync)" = v1.1.0 ] || fail "rhtas/sync has example.com/dep $(dep_version rhtas/sync), want v1.1.0"
git -C "${fork}" show rhtas/sync:go.mod | grep -q 'example.com/other v1.0.0' || fail "rhtas/sync lost upstream's example.com/other"
git -C "${fork}" show rhtas/sync:MIDSTREAM >/dev/null || fail "rhtas/sync lost the plain carry"
git -C "${fork}" log --format=%B rhtas/main..rhtas/sync | grep -q '^Go-Get: . example.com/dep@v1.1.0$' ||
  fail "regenerated carry lost its Go-Get trailer"
"${sync}" --merge "${fork}" >/dev/null
echo "ok: a Go-Get carry is regenerated over upstream go.mod/go.sum changes"

# 2. Upstream takes v1.2.0: the carry is dropped, nothing downgraded.
go -C "${up}" get example.com/dep@v1.2.0 2>/dev/null
git -C "${up}" commit -q -am "upstream: dep v1.2.0"
out="$("${sync}" "${fork}")"
grep -q '^dropped .*Bump example.com/dep.*upstream contains every bump' <<<"${out}" || fail "carry not dropped: ${out}"
grep -q 'upstream has example.com/dep v1.2.0 (carry wants v1.1.0)' <<<"${out}" || fail "no upstream version reported: ${out}"
[ "$(dep_version rhtas/sync)" = v1.2.0 ] || fail "rhtas/sync has example.com/dep $(dep_version rhtas/sync), want v1.2.0"
"${sync}" --merge "${fork}" >/dev/null
echo "ok: a Go-Get carry upstream has caught up with is dropped"

# 3. A carry for example.com/other v1.1.0, with upstream on v1.1.0-rc.1.
git -C "${fork}" switch -q rhtas/main
go -C "${fork}" get example.com/other@v1.1.0 2>/dev/null
git -C "${fork}" commit -q -am "UPSTREAM: <drop>: Bump example.com/other to v1.1.0 for GO-2026-0001

Go-Get: . example.com/other@v1.1.0"
git -C "${fork}" switch -q main
go -C "${up}" get example.com/other@v1.1.0-rc.1 2>/dev/null
git -C "${up}" commit -q -am "upstream: other v1.1.0-rc.1"
# The build list cannot load: no proxy, and nothing cached.
if GOPROXY=off GOMODCACHE="${t}/empty-modcache" "${sync}" "${fork}" >"${t}/out" 2>&1; then
  fail "the sync passed with no module proxy: $(cat "${t}/out")"
fi
grep -q 'go list -m all in . failed' "${t}/out" || fail "unexpected sync failure: $(cat "${t}/out")"
if git -C "${fork}" rev-parse -q --verify refs/heads/rhtas/sync >/dev/null; then fail "a failed sync wrote rhtas/sync"; fi
out="$("${sync}" "${fork}")"
grep -q '^regenerated .*Bump example.com/other' <<<"${out}" || fail "carry not regenerated over v1.1.0-rc.1: ${out}"
[ "$(version rhtas/sync example.com/other)" = v1.1.0 ] ||
  fail "rhtas/sync has example.com/other $(version rhtas/sync example.com/other), want v1.1.0"
"${sync}" --merge "${fork}" >/dev/null
echo "ok: a Go-Get carry stops a sync that cannot load the build list, and applies over a pre-release"

# 4. A Go-Replaces carry, with the inventory replacing example.com/dep.
export SEALHOUSE_REPLACES="${t}/replaces.lock"
echo 'example.com/dep github.com/sealhouse/dep v1.2.1-rhtas.1 GO-2026-0002 upstream>=v1.2.1' >"${SEALHOUSE_REPLACES}"
git -C "${fork}" switch -q rhtas/main
"${ci_root}/hack/apply-replaces.sh" "${fork}" 2>/dev/null
git -C "${fork}" commit -q -am "UPSTREAM: <drop>: Replace modules as ci's replaces.lock asks

Go-Replaces: replaces.lock"
git -C "${fork}" switch -q main
"${sync}" --check "${fork}" >/dev/null || fail "--check refused a Go-Replaces <drop> carry"
replace_of() { git -C "${fork}" show "$1:go.mod" | awk '$1 == "replace" && $2 == "example.com/dep" { print $4 "@" $5 }'; }
go -C "${up}" get example.com/other@v1.1.0 2>/dev/null
git -C "${up}" commit -q -am "upstream: other v1.1.0"
out="$("${sync}" "${fork}")"
grep -q '^regenerated .*Replace modules' <<<"${out}" || fail "Go-Replaces carry not regenerated: ${out}"
[ "$(replace_of rhtas/sync)" = github.com/sealhouse/dep@v1.2.1-rhtas.1 ] || fail "rhtas/sync replaces example.com/dep with '$(replace_of rhtas/sync)'"
[ "$(version rhtas/sync example.com/other)" = v1.1.0 ] || fail "rhtas/sync lost upstream's example.com/other v1.1.0"
"${sync}" --merge "${fork}" >/dev/null
: >"${SEALHOUSE_REPLACES}"
echo more >>"${up}/UP2"
git -C "${up}" add UP2
git -C "${up}" commit -q -m "upstream: more"
out="$("${sync}" "${fork}")"
grep -q '^dropped .*Replace modules' <<<"${out}" || fail "Go-Replaces carry not dropped with an empty inventory: ${out}"
[ -z "$(replace_of rhtas/sync)" ] || fail "rhtas/sync still replaces example.com/dep with $(replace_of rhtas/sync)"
"${sync}" --merge "${fork}" >/dev/null
unset SEALHOUSE_REPLACES
echo "ok: a Go-Replaces carry follows the inventory, and drops with its last line"

# 5. A <drop> carry with no Go-Get or Go-Replaces trailer is refused.
git -C "${fork}" switch -q rhtas/main
echo generated >"${fork}/GENERATED"
git -C "${fork}" add GENERATED
git -C "${fork}" commit -q -m "UPSTREAM: <drop>: generated file"
git -C "${fork}" switch -q main
if "${sync}" --check "${fork}" 2>"${t}/err"; then fail "--check passed a <drop> carry with no Go-Get trailer"; fi
grep -q 'needs Go-Get' "${t}/err" || fail "unexpected --check error: $(cat "${t}/err")"
echo upstream >"${up}/UP"
git -C "${up}" add UP
git -C "${up}" commit -q -m "upstream: more"
if "${sync}" "${fork}" 2>"${t}/err" >/dev/null; then fail "the sync replayed a <drop> carry with no Go-Get trailer"; fi
echo "ok: a <drop> carry without Go-Get or Go-Replaces trailers is refused"

# 6. --check --since, as the PR lane runs it: only the PR's commits.
git -C "${fork}" branch -f rhtas/main rhtas/main~1
pr_check() { FORK_BRANCH="$1" "${sync}" --check --since rhtas/main "${fork}" 2>"${t}/err" >/dev/null; }
git -C "${fork}" switch -q -c pr rhtas/main
echo bad >"${fork}/PR"
git -C "${fork}" add PR
git -C "${fork}" commit -q -m "UPSTREAM: <drop>: Bump example.com/dep to v1.2.0

Go-Get: . example.com/dep@v1.2.0

Signed-off-by: test <test@example.com>"
if pr_check pr; then fail "--check --since passed a Go-Get line outside the trailer paragraph"; fi
grep -q 'outside its message.s last paragraph' "${t}/err" || fail "unexpected --check error: $(cat "${t}/err")"
git -C "${fork}" commit -q --amend -m "UPSTREAM: <drop>: Bump example.com/dep to v1.2.0

Go-Get: . example.com/dep@v1.2.0
Signed-off-by: test <test@example.com>"
pr_check pr || fail "--check --since refused Go-Get above Signed-off-by: $(cat "${t}/err")"
git -C "${fork}" commit -q --allow-empty -m "unlabelled"
if pr_check pr; then fail "--check --since passed an unlabelled commit"; fi
grep -q '^unlabelled carry' "${t}/err" || fail "unexpected --check error: $(cat "${t}/err")"
git -C "${fork}" switch -q main
git -C "${fork}" branch -q -D pr
"${sync}" "${fork}" >/dev/null
pr_check rhtas/sync || fail "--check --since refused a sync PR: $(cat "${t}/err")"
echo "ok: the PR lane's check refuses a Go-Get line outside the trailers, and passes a sync PR"

# 7. Ci-Pin carries: only the last survives a sync, and it follows its trailer.
git -C "${fork}" branch -q -D rhtas/sync
git -C "${fork}" switch -q rhtas/main
caller=.github/workflows/sealhouse-pr.yaml
a="$(printf 'a%.0s' {1..40})" b="$(printf 'b%.0s' {1..40})" c="$(printf 'c%.0s' {1..40})"
mkdir -p "${fork}/.github/workflows"
printf 'uses: sealhouse/ci/.github/workflows/pr.yaml@%s\nwith:\n  ci-ref: %s\n' "${a}" "${a}" >"${fork}/${caller}"
git -C "${fork}" add -A
git -C "${fork}" commit -q -m "UPSTREAM: <carry>: callers"
for pin in "${b}" "${c}"; do
  "${ci_root}/hack/pin-ci.sh" "${pin}" "${fork}/${caller}"
  git -C "${fork}" commit -q -am "UPSTREAM: <drop>: Pin ci ${pin:0:12}

Ci-Pin: ${pin}"
done
"${sync}" --check "${fork}" >/dev/null || fail "--check refused a Ci-Pin carry"
git -C "${fork}" switch -q main
git -C "${up}" commit -q --allow-empty -m "upstream: for the pins"
out="$("${sync}" "${fork}")"
grep -q "^dropped .*Pin ci ${b:0:12} (a later pin replaces it)" <<<"${out}" || fail "the earlier pin not dropped: ${out}"
grep -q "^regenerated .*Pin ci ${c:0:12}" <<<"${out}" || fail "the last pin not regenerated: ${out}"
[ "$(git -C "${fork}" show "rhtas/sync:${caller}" | grep -c "${c}")" -eq 2 ] || fail "the sync lost the pin"
[ -z "$(git -C "${fork}" show "rhtas/sync:${caller}" | grep -E "${a}|${b}")" ] || fail "an old pin survived"
pins="$(git -C "${fork}" log --format='%(trailers:key=Ci-Pin,valueonly)' rhtas/main..rhtas/sync | grep -v '^$')"
[ "${pins}" = "${c}" ] || fail "expected one Ci-Pin trailer, got: ${pins}"
git -C "${fork}" switch -q rhtas/main
echo x >"${fork}/PIN"
git -C "${fork}" add PIN
git -C "${fork}" commit -q -m "UPSTREAM: <drop>: Pin ci

Ci-Pin: nothex"
if "${sync}" --check "${fork}" 2>"${t}/err"; then fail "--check passed a bad Ci-Pin"; fi
git -C "${fork}" reset -q --hard HEAD~1
git -C "${fork}" switch -q main
echo "ok: only the last Ci-Pin carry survives a sync"

# 8. A carry that deletes a file keeps it deleted when upstream changes it; other conflicts stop the sync.
git -C "${fork}" branch -q -D rhtas/sync
echo v1 >"${up}/dependabot.yml"
echo v1 >"${up}/README"
git -C "${up}" add -A
git -C "${up}" commit -q -m "upstream: dependabot and readme"
"${sync}" "${fork}" >/dev/null
"${sync}" --merge "${fork}" >/dev/null
git -C "${fork}" switch -q rhtas/main
git -C "${fork}" rm -q dependabot.yml
git -C "${fork}" commit -q -m "UPSTREAM: <carry>: Remove the Dependabot config"
git -C "${fork}" switch -q main
echo v2 >"${up}/dependabot.yml"
git -C "${up}" commit -q -am "upstream: bump dependabot"
out="$("${sync}" "${fork}")" || fail "a delete carry stopped the sync: ${out}"
grep -q "^replayed .*Remove the Dependabot config (kept its deletes" <<<"${out}" || fail "delete carry not reported: ${out}"
if git -C "${fork}" cat-file -e rhtas/sync:dependabot.yml 2>/dev/null; then fail "the sync brought dependabot.yml back"; fi
git -C "${fork}" branch -q -D rhtas/sync
git -C "${fork}" switch -q rhtas/main
echo carried >"${fork}/README"
git -C "${fork}" commit -q -am "UPSTREAM: <carry>: readme"
git -C "${fork}" switch -q main
echo v2 >"${up}/README"
git -C "${up}" commit -q -am "upstream: readme"
if "${sync}" "${fork}" >/dev/null 2>"${t}/err"; then fail "a content conflict did not stop the sync"; fi
grep -q 'conflict replaying .*readme' "${t}/err" || fail "content conflict not reported: $(cat "${t}/err")"
echo "ok: a delete carry survives upstream changes, and a content conflict still stops the sync"
