#!/usr/bin/env bash
# timer.sh starts each schedule.lock workflow whose latest time has passed with no run the timer started for it,
# so a missed time runs once, late. A run it starts is named "timer <time>" through the workflow's timer input;
# one that was cancelled, as GitHub does to a run waiting behind another, is started again.
# ci's workflows start with GH_TOKEN, other repos' with the sealhouse-dispatch App. TIMER_NOW sets the time.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

[ $# -eq 0 ] || { echo "usage: $0" >&2; exit 2; }
lockfile="${SEALHOUSE_SCHEDULE:-${root}/schedule.lock}"
now="$(date -u -d "${TIMER_NOW:-now}" +%s)"
today=$((now - now % 86400))
ci_token="${GH_TOKEN:-}"

# latest TIMES prints the latest of TIMES at or before now, in seconds.
latest() {
  local best=0 t h m at day hours
  for t in ${1//,/ }; do
    [[ "${t}" =~ ^(\*|[01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { echo "${lockfile}: bad time ${t}" >&2; return 1; }
    h="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}"
    hours="$([ "${h}" = '*' ] && seq 0 23 || echo "${h}")"
    for day in "${today}" $((today - 86400)); do
      for h in ${hours}; do
        at=$((day + 10#${h} * 3600 + 10#${m} * 60))
        [ "${at}" -gt "${now}" ] || [ "${at}" -le "${best}" ] || best="${at}"
      done
    done
  done
  echo "${best}"
}

declare -A tokens
failed=0
while read -r repo workflow times args; do
  [ -n "${repo}" ] && [[ "${repo}" != '#'* ]] || continue
  at="$(latest "${times}")" || { failed=1; continue; }
  slot="$(date -u -d "@${at}" +%Y-%m-%dT%H:%MZ)"
  title="timer ${slot}"
  if [ -z "${tokens[${repo}]:-}" ]; then
    if [ "${repo}" = ci ]; then
      tokens[${repo}]="${ci_token:?GH_TOKEN starts the workflows in ci}"
    else
      tokens[${repo}]="$(gh_app_token "${DISPATCH_APP_ID:?}" "${DISPATCH_APP_KEY:?}" '{"actions":"write"}' "${repo}")" || { failed=1; continue; }
    fi
  fi
  export GH_TOKEN="${tokens[${repo}]}"
  path="/repos/${gh_org}/${repo}/actions/workflows/${workflow}"
  if ! runs="$(gh_api GET "${path}/runs?event=workflow_dispatch&created=%3E%3D$(date -u -d "@${at}" +%Y-%m-%dT%H:%M:%SZ)&per_page=100")"; then
    echo "${repo} ${workflow}: cannot list its runs" >&2
    failed=1
    continue
  fi
  if jq -e --arg t "${title}" 'any(.workflow_runs[]; .display_title == $t and .conclusion != "cancelled")' <<<"${runs}" >/dev/null; then
    echo "${repo} ${workflow}: ran for ${slot}"
    continue
  fi
  inputs="$(jq -n --arg t "${title}" '{timer: $t}')"
  for kv in ${args}; do
    inputs="$(jq --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<<"${inputs}")"
  done
  if jq -n --argjson i "${inputs}" '{ref: "main", inputs: $i}' | gh_api POST "${path}/dispatches" - >/dev/null; then
    echo "${repo} ${workflow}: started for ${slot}"
  else
    echo "${repo} ${workflow}: cannot start it for ${slot}" >&2
    failed=1
  fi
done <"${lockfile}"
exit "${failed}"
