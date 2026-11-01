#!/usr/bin/env bash
# vulncheck.sh REPO_DIR [OUT_DIR]
set -euo pipefail

[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 REPO_DIR [OUT_DIR]" >&2; exit 2; }
repo="$(cd "$1" && pwd)"
out="${2:-}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
[ -z "${out}" ] || mkdir -p "${out}"

findings="${work}/findings"
: >"${findings}"
while read -r gomod; do
  rel="$(dirname "${gomod}")"
  name="$(go mod edit -json "${repo}/${gomod}" | jq -r .Module.Path)"
  json="${work}/$(tr / _ <<<"${name}").json"
  # Upstream trees hold packages that do not load.
  pkgs="$(cd "${repo}/${rel}" && go list -e -f '{{if not .Error}}{{.ImportPath}}{{end}}' ./... 2>/dev/null)"
  broken="$(cd "${repo}/${rel}" && go list -e -f '{{if .Error}}{{.ImportPath}}{{end}}' ./... 2>/dev/null)"
  [ -z "${broken}" ] || echo "${name}: not scanned, does not load: $(tr '\n' ' ' <<<"${broken}")" >&2
  [ -n "${pkgs}" ] || continue
  # shellcheck disable=SC2086
  if ! (cd "${repo}/${rel}" && govulncheck -format json ${pkgs} >"${json}"); then
    echo "govulncheck failed in ${name}" >&2
    exit 1
  fi
  [ -z "${out}" ] || cp "${json}" "${out}/"
  # Reached symbols only: a finding whose trace starts at a function.
  jq -r --arg m "${name}" 'select(.finding) | .finding | select(.trace[0].function) |
    [.osv, .trace[0].module, .trace[0].version, (.fixed_version // ""), $m] | @tsv' "${json}" >>"${findings}"
done < <(git -C "${repo}" ls-files '*go.mod' 'go.mod' | grep -v '/testdata/' | sort -u)

summary="${work}/summary"
{
  if [ ! -s "${findings}" ]; then
    echo "govulncheck: no reachable vulnerabilities"
  else
    sort -u "${findings}" | awk -F '\t' '$4 != "" { printf "fix available: %s in %s@%s, fixed in %s (%s)\n", $1, $2, $3, $4, $5 }'
    sort -u "${findings}" | awk -F '\t' '$4 == "" { printf "no fix yet: %s in %s@%s (%s)\n", $1, $2, $3, $5 }'
  fi
} >"${summary}"
cat "${summary}"
[ -z "${out}" ] || cp "${summary}" "${out}/summary"
