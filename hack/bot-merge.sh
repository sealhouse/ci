#!/usr/bin/env bash
# bot-merge.sh [REPO BASE] merges green ci-pin and replaces PRs that only sealhouse-bot wrote, on every caller or on REPO.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

# Each caller is its own process, so set -e holds inside it.
if [ $# -eq 0 ]; then
  failed=0
  while read -r fork _; do
    "$0" "${fork}" rhtas/main || failed=1
  done < <(grep -v '^#' "${FORKS_LOCK:-${root}/forks.lock}")
  "$0" secure-sign-pqc-operator main || failed=1
  exit "${failed}"
fi

repo="$1" base="$2"
full="${gh_org}/${repo}"
bot="sealhouse-bot[bot]"
GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write","pull_requests":"write","checks":"read","workflows":"write"}' "${repo}" ci)"
export GH_TOKEN

pulls="$(gh_api GET "/repos/${full}/pulls?state=open&base=${base}&per_page=100")"
# A merge would move rhtas/main under the sync PR, which only fast-forwards.
if [ "$(jq '[.[] | select(.head.ref == "rhtas/sync")] | length' <<<"${pulls}")" -gt 0 ]; then
  echo "${repo}: waiting for the sync PR"
  exit 0
fi

# pin_only PIN reads a PR's files and passes when each one only moves sealhouse-*.yaml pins to PIN.
pin_only() {
  jq -e --arg p "$1" '
    def pins: sub("(?<a>sealhouse/ci/\\.github/workflows/[a-z-]+\\.yaml@)[0-9a-f]{40}"; "\(.a)PIN") | sub("^(?<a> *ci-ref: )[0-9a-f]{40}"; "\(.a)PIN");
    def moves_pins:
      ((.patch // "") | split("\n") | map(select(test("^[-+]")))) as $l |
      ($l | map(select(startswith("-")) | .[1:])) as $old | ($l | map(select(startswith("+")) | .[1:])) as $new |
      ($new | length) > 0 and ($old | map(pins)) == ($new | map(pins)) and all($new[]; (pins != .) and contains($p));
    length > 0 and all(.[];
      (.filename | test("^\\.github/workflows/sealhouse-[a-z-]+\\.yaml$")) and .status == "modified" and moves_pins)' >/dev/null
}

while read -r number ref sha author; do
  [ -n "${number}" ] || continue
  if [ "${author}" != "${bot}" ]; then
    echo "${repo}: PR ${number} (${ref}) is not from ${bot}: it needs a maintainer"
    continue
  fi
  commits="$(gh_api GET "/repos/${full}/pulls/${number}/commits?per_page=100")"
  if ! jq -e --arg b "${bot}" 'length > 0 and all(.[]; .author.login == $b and (.committer.login == "web-flow" or .committer.login == $b) and .commit.verification.verified)' <<<"${commits}" >/dev/null; then
    echo "${repo}: PR ${number} (${ref}) has a commit ${bot} did not sign: it needs a maintainer"
    continue
  fi
  checks="$(gh_api GET "/repos/${full}/commits/${sha}/check-runs?per_page=100" | jq '[.check_runs[] | select(.name | contains("hand-off") | not)]')"
  if [ "$(jq length <<<"${checks}")" -eq 0 ] || [ "$(jq '[.[] | select(.status != "completed")] | length' <<<"${checks}")" -gt 0 ]; then
    echo "${repo}: PR ${number} (${ref}) is waiting for its checks"
    continue
  fi
  bad="$(jq -r '[.[] | select(.conclusion != "success" and .conclusion != "skipped") | .name] | join(", ")' <<<"${checks}")"
  if [ -n "${bad}" ]; then
    echo "${repo}: PR ${number} (${ref}) needs a maintainer: ${bad}"
    continue
  fi
  files="$(gh_api GET "/repos/${full}/pulls/${number}/files?per_page=100")"
  case "${ref}" in
    ci-pin/*)
      pin="$(jq -r '[.[].patch // "" | split("\n")[] | select(startswith("+")) | capture("(?<s>[0-9a-f]{40})").s] | first // ""' <<<"${files}")"
      if [[ ! "${pin}" == "${ref#ci-pin/}"* ]] || ! pin_only "${pin}" <<<"${files}" ||
        ! gh_api GET "/repos/${gh_org}/ci/compare/${pin}...main" | jq -e '.status == "ahead" or .status == "identical"' >/dev/null; then
        echo "${repo}: PR ${number} (${ref}) changes more than the pin to a ci main commit: it needs a maintainer"
        continue
      fi
      ;;
    replaces/*)
      if ! jq -e 'length > 0 and all(.[]; .filename | test("(^|/)go\\.(mod|sum)$"))' <<<"${files}" >/dev/null; then
        echo "${repo}: PR ${number} (${ref}) changes more than go.mod and go.sum: it needs a maintainer"
        continue
      fi
      ;;
  esac
  # The squash keeps the first commit's trailers, which a sync needs to regenerate the carry.
  message="$(jq -r '.[0].commit.message' <<<"${commits}")"
  if ! jq -n --arg s "${sha}" --arg t "${message%%$'\n'*}" --arg m "$(sed '1,/^$/d' <<<"${message}")" \
    '{merge_method: "squash", sha: $s, commit_title: $t, commit_message: $m}' |
    gh_api PUT "/repos/${full}/pulls/${number}/merge" - >/dev/null; then
    echo "${repo}: PR ${number} (${ref}) could not merge yet"
    continue
  fi
  echo "${repo}: merged PR ${number} (${ref})"
done < <(jq -r '[.[] | select(.head.ref | test("^(ci-pin|replaces)/"))] | sort_by(.number) | .[] | "\(.number) \(.head.ref) \(.head.sha) \(.user.login)"' <<<"${pulls}")
