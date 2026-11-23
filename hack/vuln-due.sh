#!/usr/bin/env bash
# vuln-due.sh SUMMARY prints SUMMARY's "fix available" lines whose fix ci takes now: the fixed version
# was released vulns.lock's DAYS ago or more, or vulns.lock names the vulnerability. A line may
# start "<repo>: ". The rest go to stderr with the day ci takes them.
# vuln-due.sh --rows TIME REPO SUMMARY prints REPO's vuln-trend.tsv rows instead: one per finding,
# with the day ci takes its fix, or one with an empty osv when REPO has none.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
rows=
if [ "${1:-}" = --rows ] && [ $# -eq 4 ]; then
  rows=1 time="$2" repo="$3"
  shift 3
fi
[ $# -eq 1 ] || { echo "usage: $0 SUMMARY | $0 --rows TIME REPO SUMMARY" >&2; exit 2; }
lockfile="${SEALHOUSE_VULNS:-${root}/vulns.lock}"
days="$(sed -n 's/^DAYS=//p' "${lockfile}")"
[[ "${days}" =~ ^[0-9]+$ ]] || { echo "${lockfile}: DAYS must be a number of days" >&2; exit 1; }
now="$(date -u +%s)"

# released_at MODULE VERSION prints when the proxy first served MODULE@VERSION, in seconds.
released_at() {
  local time
  time="$(cd / && go list -m -json "$1@$2" | jq -r '.Time // empty')"
  [ -n "${time}" ] || { echo "no release time for $1@$2" >&2; return 1; }
  date -u -d "${time}" +%s
}

found=
while IFS= read -r line; do
  if [ -n "${rows}" ] && [[ "${line}" =~ ^no\ fix\ yet:\ ([^ ]+)\ in\ ([^@ ]+)@([^ ]+)\ \( ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t\t\n' "${time}" "${repo}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    found=1
    continue
  fi
  [[ "${line}" =~ fix\ available:\ ([^ ]+)\ in\ ([^@ ]+)@([^,]+),\ fixed\ in\ ([^ ]+)\ \( ]] || continue
  osv="${BASH_REMATCH[1]}" module="${BASH_REMATCH[2]}" version="${BASH_REMATCH[3]}" fixed="${BASH_REMATCH[4]}"
  case "${module}" in
    stdlib | toolchain) at="$(released_at golang.org/toolchain "v0.0.1-go${fixed#v}.linux-amd64")" ;;
    *) at="$(released_at "${module}" "${fixed}")" ;;
  esac
  due=$((at + days * 86400))
  if grep -qE "^${osv}( |$)" "${lockfile}"; then
    [ "${now}" -lt "${due}" ] || echo "${osv}: its fix is over ${days} days old, so its line in vulns.lock can go" >&2
    due="${at}"
  fi
  if [ -n "${rows}" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${time}" "${repo}" "${osv}" "${module}" "${version}" "${fixed}" "$(date -u -d "@${due}" +%F)"
    found=1
  elif [ "${now}" -ge "${due}" ]; then
    echo "${line}"
  else
    echo "${osv}: ${module} ${fixed} was released $(date -u -d "@${at}" +%F), ci takes it from $(date -u -d "@${due}" +%F)" >&2
  fi
done <"$1"

if [ -n "${rows}" ] && [ -z "${found}" ]; then
  grep -qx 'govulncheck: no reachable vulnerabilities' "$1" || { echo "$1: no findings and no clean line" >&2; exit 1; }
  printf '%s\t%s\t\t\t\t\t\n' "${time}" "${repo}"
fi
