#!/usr/bin/env bash
# vuln-trend.sh TIME REPO SUMMARY prints vuln-trend.tsv rows for vulncheck.sh's SUMMARY of REPO:
# one per finding, or one with an empty osv when REPO has none.
set -euo pipefail

[ $# -eq 3 ] || { echo "usage: $0 TIME REPO SUMMARY" >&2; exit 2; }
time="$1" repo="$2" summary="$3"
rows="$(sed -nE \
  -e 's/^fix available: ([^ ]+) in (.+)@([^,]+), fixed in ([^ ]+) \(.*\)$/\1\t\2\t\3\t\4/p' \
  -e 's/^no fix yet: ([^ ]+) in (.+)@([^ ]+) \(.*\)$/\1\t\2\t\3\t/p' "${summary}")"
if [ -z "${rows}" ]; then
  grep -qx 'govulncheck: no reachable vulnerabilities' "${summary}" || { echo "${summary}: no findings and no clean line" >&2; exit 1; }
  printf '%s\t%s\t\t\t\t\n' "${time}" "${repo}"
else
  while IFS= read -r r; do printf '%s\t%s\t%s\n' "${time}" "${repo}" "${r}"; done <<<"${rows}"
fi
