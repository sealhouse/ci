#!/usr/bin/env bash
# soak-record.sh TREND commits TREND to ci's soak-trend branch, with GH_TOKEN.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

repo="${gh_org}/ci"
if ! gh_api GET "/repos/${repo}/git/ref/heads/soak-trend" >/dev/null 2>&1; then
  main="$(gh_api GET "/repos/${repo}/git/ref/heads/main" | jq -r .object.sha)"
  jq -n --arg s "${main}" '{ref: "refs/heads/soak-trend", sha: $s}' | gh_api POST "/repos/${repo}/git/refs" - >/dev/null
fi
new="$(gh_commit "${repo}" soak-trend "Soak trend" "soak-trend.tsv=$1")"
jq -n --arg s "${new}" '{sha: $s, force: false}' | gh_api PATCH "/repos/${repo}/git/refs/heads/soak-trend" - >/dev/null
