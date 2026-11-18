#!/usr/bin/env bash
# trend-record.sh BRANCH FILE commits FILE, under its own name, to ci's BRANCH, making the branch if needed, with GH_TOKEN.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

[ $# -eq 2 ] || { echo "usage: $0 BRANCH FILE" >&2; exit 2; }
branch="$1" file="$2"
repo="${gh_org}/ci"
if ! gh_api GET "/repos/${repo}/git/ref/heads/${branch}" >/dev/null 2>&1; then
  main="$(gh_api GET "/repos/${repo}/git/ref/heads/main" | jq -r .object.sha)"
  jq -n --arg b "refs/heads/${branch}" --arg s "${main}" '{ref: $b, sha: $s}' | gh_api POST "/repos/${repo}/git/refs" - >/dev/null
fi
new="$(gh_commit "${repo}" "${branch}" "Record $(basename "${file}")" "$(basename "${file}")=${file}")"
jq -n --arg s "${new}" '{sha: $s, force: false}' | gh_api PATCH "/repos/${repo}/git/refs/heads/${branch}" - >/dev/null
