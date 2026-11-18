#!/usr/bin/env bash
# report-publish.sh DATE DAILY commits DAILY as DATE's report, and the rollup, to sealhouse/reports as the bot App.
# report-publish.sh DATE --failed records that collecting DATE failed, unless DATE already has a good report.
# REPORT_GIT is where reports is cloned from; REPORT_RUN_ID, REPORT_RUN_URL and REPORT_CI describe the run.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

[ $# -eq 2 ] || { echo "usage: $0 DATE DAILY | DATE --failed" >&2; exit 2; }
day="$1" daily="$2"
[[ "${day}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad date '${day}'" >&2; exit 2; }
repo="${gh_org}/reports"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git clone -q --depth 1 -b main "${REPORT_GIT:-https://github.com}/${repo}.git" "${work}/reports"
data="${work}/reports/data"
mkdir -p "${data}/daily"
file="${data}/daily/${day}.json"
if [ "${daily}" = --failed ]; then
  if [ -f "${file}" ] && jq -e '.status == "ok"' "${file}" >/dev/null; then
    echo "${day} already has a good report; leaving it"
    exit 0
  fi
  jq -n --arg day "${day}" --arg id "${REPORT_RUN_ID:-}" --arg url "${REPORT_RUN_URL:-}" --arg ci "${REPORT_CI:-}" \
    --arg now "${REPORT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    '{schema: 1, date: $day, status: "failed", run: {id: $id, url: $url, ci: $ci, collected_at: $now}}' >"${file}"
else
  jq -e --arg d "${day}" '.schema == 1 and .date == $d and .status == "ok"' "${daily}" >/dev/null ||
    { echo "${daily} is not a good schema 1 report for ${day}" >&2; exit 1; }
  cp "${daily}" "${file}"
fi
"${root}/hack/report-rollup.sh" "${data}/daily" "${data}/rollup.json"

status="$(jq -r .status "${file}")"
GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write"}' reports)"
new="$(gh_commit "${repo}" main "Report ${day} (${status})" "data/daily/${day}.json=${file}" "data/rollup.json=${data}/rollup.json")"
jq -n --arg s "${new}" '{sha: $s, force: false}' | gh_api PATCH "/repos/${repo}/git/refs/heads/main" - >/dev/null
echo "reports: ${day} ${status} at ${new}"
