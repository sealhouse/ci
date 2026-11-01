#!/usr/bin/env bash
# request-lane.sh WORKFLOW KEY=VALUE... asks ci to run WORKFLOW, with the sealhouse-dispatch App.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

workflow="$1"
shift
: "${DISPATCH_APP_ID:?}" "${DISPATCH_APP_KEY:?}"
GH_TOKEN="$(gh_app_token "${DISPATCH_APP_ID}" "${DISPATCH_APP_KEY}" '{"actions":"write"}' ci)"
export GH_TOKEN
inputs='{}'
for kv in "$@"; do
  inputs="$(jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<<"${inputs}")"
done
jq -n --argjson i "${inputs}" '{ref: "main", inputs: $i}' |
  gh_api POST "/repos/${gh_org}/ci/actions/workflows/${workflow}/dispatches" - >/dev/null
echo "requested ${workflow}"
