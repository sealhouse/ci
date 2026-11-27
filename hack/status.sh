#!/usr/bin/env bash
# status.sh prints what waits on a maintainer, the active workflow runs, the timer chain and the open PRs across the org,
# with your gh login.
set -euo pipefail

org="${SEALHOUSE_ORG:-sealhouse}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# shellcheck disable=SC2016 # GraphQL variables
gh api graphql -f q="org:${org} is:pr is:open" -f query='
  query($q: String!) { search(query: $q, type: ISSUE, first: 100) { nodes { ... on PullRequest {
    repository { name } number title url isDraft createdAt reviewDecision headRefName author { login }
    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
      ... on CheckRun { name status conclusion } ... on StatusContext { name: context state } } } } } } } } } } }' \
  --jq '[.data.search.nodes[] | {repo: .repository.name, number, title, url, draft: .isDraft, created: .createdAt,
    review: (.reviewDecision // "NONE"), ref: .headRefName, author: .author.login,
    checks: ([.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [] | .[]
      | select(.name | test("sync-merge-guard|hand-off") | not)] as $c   # the guard fails on a sync PR by design
      | if ($c | length) == 0 then "NONE"
        elif any($c[]; (.status // "COMPLETED") != "COMPLETED" or .state == "PENDING") then "PENDING"
        elif any($c[]; (.conclusion // .state) | IN("SUCCESS", "SKIPPED", "NEUTRAL") | not) then "FAILURE"
        else "SUCCESS" end)}] | sort_by(.repo, .number)' >"${work}/prs.json"

gh api --paginate "/orgs/${org}/repos?per_page=100" --jq '.[] | select(.archived | not) | .name' | sort >"${work}/repos"
while read -r repo; do
  gh api "/repos/${org}/${repo}/actions/runs?per_page=50" \
    --jq "[.workflow_runs[] | {repo: \"${repo}\", workflow: (.path | split(\"/\") | last), name, event, branch: .head_branch,
      status, conclusion, created: .created_at, url: .html_url}
      | select(.status != \"completed\" or .workflow == \"sealhouse-timer.yaml\")]" \
    >"${work}/runs-${repo}.json" &
done <"${work}/repos"
wait
# A timer link is always running, and waits in the timer environment, so it is shown apart.
jq -s 'add // [] | sort_by(.created)' "${work}"/runs-*.json >"${work}/all-runs.json"
jq '[.[] | select(.workflow == "sealhouse-timer.yaml" and .repo == "ci")]' "${work}/all-runs.json" >"${work}/timer.json"
jq '[.[] | select((.workflow == "sealhouse-timer.yaml" and .repo == "ci") | not)]' "${work}/all-runs.json" >"${work}/runs.json"

# bot-merge.sh merges these once they are green, so they wait on no one.
age='def selfmerge: .author == "sealhouse-bot" and (.ref | test("^(ci-pin|replaces|vulns|bump)/"));
  def age: (now - (fromdateiso8601)) | if . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;'
table() { local rows; rows="$(cat)"; if [ -n "${rows}" ]; then column -t -s $'\t' <<<"${rows}" | sed 's/^/  /'; else echo "  none"; fi; }

echo "Needs a maintainer"
{
  jq -r "${age}"' .[] | select((.draft | not) and (((.review == "REVIEW_REQUIRED" or .review == "CHANGES_REQUESTED") and (selfmerge | not)) or .checks == "FAILURE" or .checks == "ERROR"))
    | [ "\(.repo)#\(.number)", (if .review == "REVIEW_REQUIRED" then "review" elif .review == "CHANGES_REQUESTED" then "changes" else "checks " + (.checks | ascii_downcase) end),
        .author, (.created | age), .title, .url ] | @tsv' "${work}/prs.json"
  jq -r "${age}"' .[] | select(.status == "waiting") | [.repo, "run waiting", .name, (.created | age), .branch, .url] | @tsv' "${work}/runs.json"
} | table

echo
echo "Active runs"
jq -r "${age}"' .[] | [.repo, .name, .event, .branch, .status, (.created | age), .url] | @tsv' "${work}/runs.json" | table

echo
echo "Timer"
jq -r "${age}"' (map(select(.status != "completed")) | if length == 0 then [["no link running", "", "", ""]] else map([.name, .status, (.created | age), .url]) end),
    (map(select(.status == "completed")) | last // empty | [["last link", .conclusion, (.created | age), .url]])
    | .[] | @tsv' "${work}/timer.json" | table

echo
echo "Open PRs"
jq -r "${age}"' .[] | [ "\(.repo)#\(.number)", (if .draft then "draft" elif selfmerge then "bot merges" else "ready" end), .author,
    "review " + (.review | ascii_downcase), "checks " + (.checks | ascii_downcase), (.created | age), .title ] | @tsv' "${work}/prs.json" | table
