#!/usr/bin/env bash
# report-fresh.sh SITE_URL fails when the published report's last good collection is over REPORT_MAX_AGE hours old
# (default 36), or when the site does not serve the rollup on reports' main.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 SITE_URL" >&2; exit 2; }
site="${1%/}"
max="${REPORT_MAX_AGE:-36}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

curl -fsS --retry 3 -o "${work}/served.json" "${site}/data/rollup.json"
last="$(jq -r '.last_collected_at // empty' "${work}/served.json")"
[ -n "${last}" ] || { echo "${site} has never had a good report" >&2; exit 1; }
now="$(date -u -d "${REPORT_FRESH_NOW:-now}" +%s)"
age=$(( (now - $(date -u -d "${last}" +%s)) / 3600 ))
[ "${age}" -le "${max}" ] || { echo "the last good report was collected ${last}, ${age} hours ago" >&2; exit 1; }

git clone -q --depth 1 -b main "${REPORT_GIT:-https://github.com}/${SEALHOUSE_ORG:-sealhouse}/reports.git" "${work}/reports"
cmp -s "${work}/served.json" "${work}/reports/data/rollup.json" ||
  { echo "${site} serves a rollup that differs from reports' main: the Pages deploy is behind" >&2; exit 1; }
echo "the report was collected ${last}, ${age} hours ago, and the site serves it"
