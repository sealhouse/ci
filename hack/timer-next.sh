#!/usr/bin/env bash
# timer-next.sh starts the timer's next link: a sealhouse-timer run that waits in the timer environment for most of a
# quarter hour, then starts what is due and the link after it. A link already waiting or queued is left to carry on instead.
# timer-next.sh --start, from reports' sealhouse-tick, starts a timer run at once with the sealhouse-dispatch App when
# no link is waiting, so a broken chain starts again. A link that comes less than 10 minutes after it was started
# fails rather than start another, as the timer environment's wait is missing. TIMER_NOW sets the time.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

start=false
case "$*" in
  '') ;;
  --start) start=true ;;
  *) echo "usage: $0 [--start]" >&2; exit 2 ;;
esac
now="$(date -u -d "${TIMER_NOW:-now}" +%s)"
if "${start}"; then
  GH_TOKEN="$(gh_app_token "${DISPATCH_APP_ID:?}" "${DISPATCH_APP_KEY:?}" '{"actions":"write"}' ci)"
  export GH_TOKEN
  me=0
else
  : "${GH_TOKEN:?}"
  me="${GITHUB_RUN_ID:?}"
fi
path="/repos/${gh_org}/ci/actions/workflows/sealhouse-timer.yaml"
runs="$(gh_api GET "${path}/runs?created=%3E%3D$(date -u -d "@$((now - 86400))" +%Y-%m-%dT%H:%M:%SZ)&per_page=100")"
if [ "${TIMER_CHAINED:-false}" = true ]; then
  created="$(jq -r --argjson me "${me}" '.workflow_runs[] | select(.id == $me) | .created_at' <<<"${runs}")"
  [ -n "${created}" ] || { echo "timer: cannot find run ${me}" >&2; exit 1; }
  if [ $((now - $(date -u -d "${created}" +%s))) -lt 600 ]; then
    echo "timer: this link started less than 10 minutes after it was asked for; the timer environment needs its wait" >&2
    exit 1
  fi
fi
waiting="$(jq -r --argjson me "${me}" '[.workflow_runs[] | select(.id != $me and .display_title == "timer link"
  and (.status | IN("requested", "queued", "pending", "waiting")))] | first | .id // empty' <<<"${runs}")"
if [ -n "${waiting}" ]; then
  echo "timer: link ${waiting} is waiting"
  exit 0
fi
inputs="$("${start}" && echo '{}' || echo '{"chained": "true"}')"
jq -n --argjson i "${inputs}" '{ref: "main", inputs: $i}' | gh_api POST "${path}/dispatches" - >/dev/null
"${start}" && echo "timer: started" || echo "timer: next link started"
