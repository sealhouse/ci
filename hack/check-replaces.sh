#!/usr/bin/env bash
# check-replaces.sh REPO_DIR [INVENTORY]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=hack/lib.sh
source "${root}/hack/lib.sh"
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 REPO_DIR [INVENTORY]" >&2; exit 2; }
repo="$(cd "$1" && pwd)"

inventory="$(mktemp)"
trap 'rm -f "${inventory}"' EXIT
replaces_inventory "${@:2}" >"${inventory}"

failed=0
while read -r gomod; do
  dir="$(dirname "${repo}/${gomod}")"
  rel="$(dirname "${gomod}")"
  # 1. Every replace.
  while IFS=$'\x1f' read -r old old_version new new_version; do
    if [ -z "${new_version}" ] && [[ "${new}" == ./* || "${new}" == ../* ]]; then
      target="$(cd "${dir}" && realpath -m "${new}")"
      case "${target}/" in
        "${repo}"/*) continue ;;
      esac
      echo "${rel}/go.mod: replace ${old} => ${new} leaves the repo" >&2
      failed=1
      continue
    fi
    want="$(awk -v m="${old}" '$1 == m { print $2 " " $3 }' "${inventory}")"
    if [ -z "${want}" ]; then
      echo "${rel}/go.mod: replace ${old} => ${new} ${new_version} has no replaces.lock line" >&2
      failed=1
    elif [ -n "${old_version}" ] || [ "${new} ${new_version}" != "${want}" ]; then
      echo "${rel}/go.mod: replace ${old}${old_version:+ ${old_version}} => ${new} ${new_version}; replaces.lock has ${old} => ${want}" >&2
      failed=1
    fi
  done < <(go mod edit -json "${dir}/go.mod" |
    jq -r '.Replace // [] | .[] | [.Old.Path, (.Old.Version // ""), .New.Path, (.New.Version // "")] | join("\u001f")')
  # 2. Every inventory module the build list holds.
  [ -s "${inventory}" ] || continue
  replaced="$(go mod edit -json "${dir}/go.mod" | jq -r '.Replace // [] | .[].Old.Path')"
  in_build="$(cd "${dir}" && go list -m -f '{{if not .Main}}{{.Path}}{{end}}' all)"
  while read -r module _; do
    if grep -qx "${module}" <<<"${in_build}" && ! grep -qx "${module}" <<<"${replaced}"; then
      echo "${rel}/go.mod: uses ${module} but does not replace it; replaces.lock has $(awk -v m="${module}" '$1 == m { print $2 " " $3 }' "${inventory}")" >&2
      failed=1
    fi
  done <"${inventory}"
done < <(git -C "${repo}" ls-files '*go.mod' 'go.mod' | grep -v '/testdata/' | sort -u)

if [ "${failed}" -eq 0 ]; then
  echo "replaces match replaces.lock ($(wc -l <"${inventory}") entries)"
fi
exit "${failed}"
