#!/usr/bin/env bash
# test-replaces.sh
set -euo pipefail

ci_root="$(cd "$(dirname "$0")/.." && pwd)"
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

# publish SERVED VERSION MODULE [REQUIRE...] puts a module version in the
# proxy at path SERVED.
publish() {
  local served="$1" ver="$2" mod="$3" dir="${t}/proxy/$1/@v" src="${t}/src/$1@$2" pkg="${3##*/}" r
  shift 3
  mkdir -p "${dir}" "${src}"
  {
    printf 'module %s\n\ngo %s\n' "${mod}" "${gover}"
    for r in "$@"; do printf '\nrequire %s\n' "${r}"; done
  } >"${src}/go.mod"
  {
    printf 'package %s\n\n' "${pkg}"
    for r in "$@"; do printf 'import _ "%s"\n' "${r% *}"; done
    printf '\nconst Version = "%s"\n' "${ver}"
  } >"${src}/${pkg}.go"
  cp "${src}/go.mod" "${dir}/${ver}.mod"
  printf '{"Version":"%s","Time":"2026-01-01T00:00:00Z"}\n' "${ver}" >"${dir}/${ver}.info"
  (cd "${t}/src" && zip -qr "${dir}/${ver}.zip" "${served}@${ver}")
  echo "${ver}" >>"${dir}/list"
}
# Upstream: lib, used directly and through mid; extra, used by nothing yet.
publish example.com/lib v1.0.0 example.com/lib
publish example.com/mid v1.0.0 example.com/mid "example.com/lib v1.0.0"
publish example.com/extra v1.0.0 example.com/extra
# Fork releases: lib rhtas.1 and rhtas.2; mid rhtas.1, which uses extra.
publish github.com/sealhouse/lib v1.0.1-rhtas.1 example.com/lib
publish github.com/sealhouse/lib v1.0.1-rhtas.2 example.com/lib
publish github.com/sealhouse/mid v1.0.1-rhtas.1 example.com/mid "example.com/lib v1.0.0" "example.com/extra v1.0.0"
publish github.com/sealhouse/extra v1.0.1-rhtas.1 example.com/extra

# The consumer: a module using lib and mid, with a submodule replacing the
# root by directory.
app="${t}/app"
mkdir -p "${app}/sub"
git -C "${app}" init -q -b main
printf 'module example.com/app\n\ngo %s\n' "${gover}" >"${app}/go.mod"
printf 'package app\n\nimport (\n\t_ "example.com/lib"\n\t_ "example.com/mid"\n)\n' >"${app}/app.go"
go -C "${app}" get example.com/lib@v1.0.0 example.com/mid@v1.0.0 2>/dev/null
printf 'module example.com/app/sub\n\ngo %s\n\nrequire example.com/app v0.0.0\n\nreplace example.com/app => ../\n' "${gover}" >"${app}/sub/go.mod"
printf 'package sub\n\nimport _ "example.com/app"\n' >"${app}/sub/sub.go"
go -C "${app}/sub" mod tidy 2>/dev/null
git -C "${app}" add -A
git -C "${app}" commit -q -m app

inv="${t}/replaces.lock"
apply() { "${ci_root}/hack/apply-replaces.sh" "${app}" "${inv}" 2>/dev/null; }
check() { "${ci_root}/hack/check-replaces.sh" "${app}" "${inv}" 2>"${t}/check.err" >/dev/null; }
replace_of() { go mod edit -json "${app}/${2:-.}/go.mod" | jq -r --arg m "$1" '.Replace // [] | .[] | select(.Old.Path == $m) | .New.Path + "@" + (.New.Version // "")'; }
committed() { git -C "${app}" add -A && git -C "${app}" commit -q -m "$1"; }

# 1. lib's fork release: replaced in both modules, check passes, a second
# apply changes nothing.
echo 'example.com/lib github.com/sealhouse/lib v1.0.1-rhtas.1 GO-2026-0001 upstream>=v1.0.1' >"${inv}"
check && fail "check passed before the replace was applied"
apply
check || fail "check failed after apply: $(cat "${t}/check.err")"
[ "$(replace_of example.com/lib)" = github.com/sealhouse/lib@v1.0.1-rhtas.1 ] || fail "app: lib replaced by '$(replace_of example.com/lib)'"
[ "$(replace_of example.com/lib sub)" = github.com/sealhouse/lib@v1.0.1-rhtas.1 ] || fail "sub: lib replaced by '$(replace_of example.com/lib sub)'"
go -C "${app}" build ./... || fail "app does not build with the replace"
committed "replace lib"
apply
[ -z "$(git -C "${app}" status --porcelain)" ] || fail "a second apply changed: $(git -C "${app}" status --porcelain | tr '\n' ' ')"
echo "ok: apply-replaces.sh applies the inventory, and a second run changes nothing"

# 2. The inventory moves on to rhtas.2.
echo 'example.com/lib github.com/sealhouse/lib v1.0.1-rhtas.2 GO-2026-0001 upstream>=v1.0.1' >"${inv}"
check && fail "check passed with the replace one release behind"
grep -q 'replaces.lock has example.com/lib => github.com/sealhouse/lib v1.0.1-rhtas.2' "${t}/check.err" || fail "unexpected check error: $(cat "${t}/check.err")"
apply
check || fail "check failed after apply: $(cat "${t}/check.err")"
[ "$(replace_of example.com/lib)" = github.com/sealhouse/lib@v1.0.1-rhtas.2 ] || fail "lib replaced by '$(replace_of example.com/lib)'"
committed "lib rhtas.2"
echo "ok: an inventory moved to a newer release fails the check until applied"

# 2b. Upstream moves the consumer to a lib newer than the fork release: the replace would downgrade it.
publish example.com/lib v1.1.0 example.com/lib
go mod edit -require=example.com/lib@v1.1.0 "${app}/go.mod"
go -C "${app}" mod tidy 2>/dev/null
"${ci_root}/hack/apply-replaces.sh" "${app}" "${inv}" 2>"${t}/apply.err" >/dev/null &&
  fail "apply replaced lib v1.1.0 with the older v1.0.1-rhtas.2"
grep -q "^go.mod: example.com/lib v1.1.0 is newer than replaces.lock's github.com/sealhouse/lib v1.0.1-rhtas.2" "${t}/apply.err" ||
  fail "unexpected apply error: $(cat "${t}/apply.err")"
check && fail "check passed with lib replaced below the version the build selects"
grep -q "^\./go.mod: example.com/lib v1.1.0 is newer than" "${t}/check.err" || fail "unexpected check error: $(cat "${t}/check.err")"
publish github.com/sealhouse/lib v1.1.1-rhtas.1 example.com/lib
echo 'example.com/lib github.com/sealhouse/lib v1.1.1-rhtas.1 GO-2026-0001 upstream>=v1.1.1' >"${inv}"
apply || fail "apply failed with a fork release newer than the build needs"
check || fail "check failed after apply: $(cat "${t}/check.err")"
git -C "${app}" checkout -q -- .
echo 'example.com/lib github.com/sealhouse/lib v1.0.1-rhtas.2 GO-2026-0001 upstream>=v1.0.1' >"${inv}"
echo "ok: a fork release older than the version the build selects fails apply and check until the fork catches up"

# 3. mid's fork release brings in extra, which the inventory also holds.
{
  echo 'example.com/lib github.com/sealhouse/lib v1.0.1-rhtas.2 GO-2026-0001 upstream>=v1.0.1'
  echo 'example.com/mid github.com/sealhouse/mid v1.0.1-rhtas.1 GO-2026-0002 upstream>=v1.0.1'
  echo 'example.com/extra github.com/sealhouse/extra v1.0.1-rhtas.1 GO-2026-0003 upstream>=v1.0.1'
} >"${inv}"
apply
check || fail "check failed after apply: $(cat "${t}/check.err")"
[ "$(replace_of example.com/extra)" = github.com/sealhouse/extra@v1.0.1-rhtas.1 ] || fail "extra replaced by '$(replace_of example.com/extra)'"
go -C "${app}" build ./... || fail "app does not build with the replaces"
committed "mid and extra"
echo "ok: an inventory module a fork release brings in is replaced too"

# 4. sub's directory replace of the root survives every apply, even with the
# inventory holding example.com/app itself, which the root must not replace.
echo 'example.com/app github.com/sealhouse/app v1.0.1-rhtas.1 GO-2026-0004 upstream>=v1.0.1' >>"${inv}"
apply
check || fail "check failed with the consumer's own module in the inventory: $(cat "${t}/check.err")"
[ -z "$(replace_of example.com/app)" ] || fail "app replaces itself with $(replace_of example.com/app)"
[ "$(replace_of example.com/app sub)" = "../@" ] || fail "sub's directory replace is now '$(replace_of example.com/app sub)'"
[ -z "$(git -C "${app}" status --porcelain)" ] || fail "the consumer's own module changed: $(git -C "${app}" status --porcelain | tr '\n' ' ')"
echo "ok: a replace to a directory inside the repo is left alone, and a module never replaces itself"

# 5. The inventory drops lib, then everything.
grep -v '^example.com/lib ' "${inv}" >"${inv}.new" && mv "${inv}.new" "${inv}"
check && fail "check passed with a replace the inventory no longer holds"
apply
check || fail "check failed after apply: $(cat "${t}/check.err")"
[ -z "$(replace_of example.com/lib)" ] || fail "lib still replaced by $(replace_of example.com/lib)"
: >"${inv}"
apply
check || fail "check failed after apply: $(cat "${t}/check.err")"
go mod edit -json "${app}/go.mod" | jq -e '[.Replace // [] | .[] | select(.New.Path | startswith("github.com/sealhouse/"))] | length == 0' >/dev/null ||
  fail "fork replaces left with an empty inventory"
go -C "${app}" build ./... || fail "app does not build with the replaces removed"
echo "ok: an inventory line removed takes its replace with it"
