#!/usr/bin/env bash
# replace-downgrades.sh GOMOD_DIR INVENTORY prints, and fails on, the inventory modules
# whose fork release is older than the version GOMOD_DIR's build list selects.
# A replace ignores the required version, so such a release would downgrade the module.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 2 ] || { echo "usage: $0 GOMOD_DIR INVENTORY" >&2; exit 2; }
dir="$1" inventory="$2"
[ -s "${inventory}" ] || exit 0

# A failed go list or comparison must fail the check, never pass it.
build="$(go -C "${dir}" list -m -f '{{if not .Main}}{{.Path}} {{.Version}}{{end}}' all)" || exit 2
found=0
while read -r module version fork fork_version; do
  cmp="$(go -C "${root}/tools/semver" run . "${fork_version}" "${version}")" || exit 2
  if [ "${cmp}" -lt 0 ]; then
    echo "${module} ${version} is newer than replaces.lock's ${fork} ${fork_version}; release the fork from a rhtas/main that holds ${version}"
    found=1
  fi
done < <(awk 'NR == FNR { fork[$1] = $2 " " $3; next } $2 != "" && ($1 in fork) { print $1, $2, fork[$1] }' "${inventory}" - <<<"${build}")
exit "${found}"
