#!/usr/bin/env bash
# report-run.sh [DATE] collects and publishes DATE's report. Without DATE it reports today, after yesterday
# while reports holds no final report for yesterday. A failed collection is recorded, never over a good report.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

[ $# -le 1 ] || { echo "usage: $0 [DATE]" >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

if [ -n "${1:-}" ]; then
  days=("$1")
else
  today="$(date -u -d "${REPORT_NOW:-now}" +%F)"
  yesterday="$(date -u -d "${today} - 1 day" +%F)"
  git clone -q --depth 1 -b main "${REPORT_GIT:-https://github.com}/${gh_org}/reports.git" "${work}/reports"
  days=("${today}")
  jq -e '.status == "ok" and (.partial | not)' "${work}/reports/data/daily/${yesterday}.json" >/dev/null 2>&1 || days=("${yesterday}" "${today}")
fi

failed=0
for day in "${days[@]}"; do
  if "${root}/hack/report-collect.sh" "${day}" "${work}/${day}.json"; then
    "${root}/hack/report-publish.sh" "${day}" "${work}/${day}.json" || failed=1
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || jq -r '"Report \(.date)\(if .partial then " so far" else "" end): \(.syncs | length) syncs,
      \(.images | length) images, \(.alphas | length) alphas, \(.prs | length) PRs closed"' "${work}/${day}.json" >>"${GITHUB_STEP_SUMMARY}"
  else
    echo "collecting ${day} failed" >&2
    failed=1
    "${root}/hack/report-publish.sh" "${day}" --failed || true
  fi
done
exit "${failed}"
