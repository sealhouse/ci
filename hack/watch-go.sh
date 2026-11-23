#!/usr/bin/env bash
# watch-go.sh FINDINGS fails when a newer Go fixes a vulnerability the scans reach, or when the images
# build with another Go than the scans use. FINDINGS holds "<repo>: <vulncheck.sh summary line>" lines.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

[ $# -eq 1 ] || { echo "usage: $0 FINDINGS" >&2; exit 2; }
read -r scan _ < <(sed -n 's/^GO=//p' "${root}/tools.lock")
builder="${GO_BUILDER:-$(lock HI_GO_BUILDER)}"
build="$(crane config "${builder}" | jq -r '.config.Env[]' | sed -n 's/^GOLANG_VERSION=//p')"
echo "Go: the scans use ${scan}, the images build with ${build:-an unknown Go}"
failed=0
if [ "${build}" != "${scan}" ]; then
  echo "HI_GO_BUILDER in images.lock builds with Go ${build:-unknown}, tools.lock scans with Go ${scan}: pin both to one Go" >&2
  failed=1
fi

# "<fixed> <osv> <repo>" for each finding a Go vulns.lock lets ci take fixes.
fixes="$("${root}/hack/vuln-due.sh" "$1" |
  sed -nE 's/^([^:]+): fix available: ([^ ]+) in (stdlib|toolchain)@[^,]+, fixed in v?([^ ]+) .*$/\4 \2 \1/p' | sort -u)"
if [ -n "${fixes}" ]; then
  want="$(awk '{ print $1 }' <<<"${fixes}" | sort -V | tail -1)"
  echo "Go ${want} fixes vulnerabilities the scans reach: update GO in tools.lock and HI_GO_BUILDER in images.lock" >&2
  awk '{ repos[$2 " (Go " $1 ")"] = repos[$2 " (Go " $1 ")"] " " $3 } END { for (k in repos) printf "  %s:%s\n", k, repos[k] }' <<<"${fixes}" | sort >&2
  repo="${builder%@*}"
  tag="${repo##*:}" repo="${repo%:*}"
  latest="$(crane config "${repo}:${tag}" | jq -r '.config.Env[]' | sed -n 's/^GOLANG_VERSION=//p')"
  if [ "$(printf '%s\n' "${want}" "${latest}" | sort -V | tail -1)" = "${latest}" ]; then
    echo "${repo}:${tag} has Go ${latest}: pin it as $(crane digest "${repo}:${tag}")" >&2
  else
    echo "${repo}:${tag} still has Go ${latest:-unknown}" >&2
  fi
  failed=1
fi
exit "${failed}"
