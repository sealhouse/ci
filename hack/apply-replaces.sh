#!/usr/bin/env bash
# apply-replaces.sh REPO_DIR [INVENTORY]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=hack/lib.sh
source "${root}/hack/lib.sh"
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 REPO_DIR [INVENTORY]" >&2; exit 2; }
repo="$(cd "$1" && pwd)"

inventory="$(mktemp)"
trap 'rm -f "${inventory}"' EXIT
replaces_inventory "${@:2}" >"${inventory}"

# in_repo_dirs DIR prints the modules DIR's go.mod replaces with an in-repo directory.
in_repo_dirs() {
  local dir="$1" old new
  while IFS=$'\x1f' read -r old new; do
    case "$(cd "${dir}" && realpath -m "${new}")/" in
      "${repo}"/*) echo "${old}" ;;
    esac
  done < <(go mod edit -json "${dir}/go.mod" |
    jq -r '.Replace // [] | .[] | select((.New.Version // "") == "" and (.New.Path | test("^\\.\\.?/"))) |
      [.Old.Path, .New.Path] | join("\u001f")')
}

while read -r gomod; do
  dir="$(dirname "${repo}/${gomod}")"
  local_dirs="$(in_repo_dirs "${dir}")"
  before="$(cat "${dir}/go.mod")"
  # 1. Drop the fork replaces and every other replace of an inventory module,
  # but for those that already are the inventory's line.
  while IFS=$'\x1f' read -r old old_version new new_version; do
    grep -Fqx "${old}" <<<"${local_dirs}" && continue
    want="$(awk -v m="${old}" '$1 == m { print $2 "@" $3 }' "${inventory}")"
    [ -z "${old_version}" ] && [ -n "${want}" ] && [ "${new}@${new_version}" = "${want}" ] && continue
    if [[ "${new}" == github.com/sealhouse/* ]] || [ -n "${want}" ]; then
      go mod edit -dropreplace="${old}${old_version:+@${old_version}}" "${dir}/go.mod"
    fi
  done < <(go mod edit -json "${dir}/go.mod" |
    jq -r '.Replace // [] | .[] | [.Old.Path, (.Old.Version // ""), .New.Path, (.New.Version // "")] | join("\u001f")')
  # 2. Replace every inventory module in the build list, until it holds.
  added=0
  for _ in 1 2 3 4 5 6 7 8; do
    [ -s "${inventory}" ] || break
    # A new replace needs go.sum entries for the fork's go.mod first.
    mod=readonly
    [ "$(cat "${dir}/go.mod")" = "${before}" ] || mod=mod
    in_build="$(GOFLAGS="-mod=${mod}" go -C "${dir}" list -m -f '{{if not .Main}}{{.Path}}{{end}}' all)"
    replaced="$(go mod edit -json "${dir}/go.mod" | jq -r '.Replace // [] | .[].Old.Path')"
    added=0
    while read -r module fork version _; do
      grep -Fqx "${module}" <<<"${in_build}" || continue
      grep -Fqx "${module}" <<<"${replaced}" && continue
      go mod edit -replace="${module}=${fork}@${version}" "${dir}/go.mod"
      added=1
    done <"${inventory}"
    [ "${added}" -eq 1 ] || break
  done
  [ "${added}" -eq 0 ] || { echo "${gomod}: the build list did not settle after 8 rounds of replaces" >&2; exit 1; }
  # 3. Tidy what changed.
  [ "$(cat "${dir}/go.mod")" = "${before}" ] || go -C "${dir}" mod tidy
  # 4. Never a fork release older than what the build needs.
  if ! downgrades="$("${root}/hack/replace-downgrades.sh" "${dir}" "${inventory}")"; then
    sed "s#^#${gomod}: #" <<<"${downgrades}" >&2
    exit 1
  fi
done < <(git -C "${repo}" ls-files '*go.mod' 'go.mod' | grep -v '/testdata/' | sort -u)
