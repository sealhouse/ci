#!/usr/bin/env bash
# report-collect.sh DATE OUT writes OUT, the report for the UTC day DATE, reading with GH_TOKEN.
# REPORT_GIT is where the sealhouse repos are cloned from, REPORT_FORKS the forks.lock to read,
# REPORT_RUN_ID, REPORT_RUN_URL and REPORT_CI describe the run. Nothing is written on any failure.
# A report is partial, and may still change, until the day has ended and every run it holds has completed.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"
# shellcheck disable=SC1091
source "${root}/hack/replace-lib.sh"

# gh_api_pages PATH FILTER prints FILTER over every page of a GET, following the Link headers.
gh_api_pages() {
  local url="${gh_api_url}$1" filter="$2" hdr body
  hdr="$(mktemp)" body="$(mktemp)"
  while [ -n "${url}" ]; do
    curl -fsS --retry 3 -D "${hdr}" -o "${body}" \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN}") \
      -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "${url}" &&
      jq -c "${filter}" "${body}" || { rm -f "${hdr}" "${body}"; return 1; }
    url="$(tr -d '\r' <"${hdr}" | sed -n 's/^[Ll]ink:.*<\([^>]*\)>; rel="next".*/\1/p')"
  done
  rm -f "${hdr}" "${body}"
}

[ $# -eq 2 ] || { echo "usage: $0 DATE OUT" >&2; exit 2; }
day="$1" out="$2"
[[ "${day}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad date '${day}'" >&2; exit 2; }
from="${day}T00:00:00Z"
to="$(date -u -d "${day} + 1 day" +%F)T00:00:00Z"
git_base="${REPORT_GIT:-https://github.com}/${gh_org}"
registry="${REPORT_REGISTRY:-ghcr.io}"
forks_lock="${REPORT_FORKS:-${root}/forks.lock}"
operator=secure-sign-pqc-operator
crane_args=()
case "${registry}" in localhost:*) crane_args=(--insecure) ;; esac

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
j="${work}/json"
mkdir -p "${j}"

in_day='def in_day: . != null and . >= $from and . < $to;'
nz='def nz: if . == "" then null else . end;'
kind='def kind: if . == "rhtas/sync" then "sync" elif startswith("bump/") then "bump" elif startswith("ci-pin/") then "ci-pin"
  elif startswith("replaces/") then "replaces" elif startswith("vulns/") then "vulns" else "other" end;'
utc() { jq -rn --argjson s "$1" '$s | todate'; }
# upstream_of DIR COMMIT prints the newest upstream commit COMMIT contains.
upstream_of() { git -C "$1" merge-base "$2" refs/upstream/head 2>/dev/null || true; }
# range DIR NEW OLD prints {count, newest_at, oldest_at} for the commits in NEW but not OLD, or null without both.
range() {
  local dir="$1" new="$2" old="$3" times
  [ -n "${new}" ] && [ -n "${old}" ] || { echo null; return; }
  times="$(git -C "${dir}" log --format=%ct "${new}" "^${old}")"
  jq -n --arg t "${times}" '($t | split("\n") | map(select(. != "") | tonumber)) as $s |
    {count: ($s | length), newest_at: ($s | max | if . then todate else null end), oldest_at: ($s | min | if . then todate else null end)}'
}

mapfile -t forks < <(awk '!/^#/ && NF { print $1 }' "${forks_lock}")
repos=("${forks[@]}" "${operator}" ci pqc-catalog)

for f in "${forks[@]}"; do
  read -r _ url branch < <(awk -v f="${f}" '$1 == f' "${forks_lock}")
  git clone -q --filter=tree:0 --no-checkout -b rhtas/main "${git_base}/${f}.git" "${work}/${f}"
  git -C "${work}/${f}" fetch -q origin '+refs/heads/release-*:refs/remotes/origin/release-*'
  git -C "${work}/${f}" fetch -q --filter=tree:0 "${url}" "+refs/heads/${branch}:refs/upstream/head"
done
git clone -q --filter=blob:none --no-checkout -b main "${git_base}/${operator}.git" "${work}/${operator}"
git clone -q --filter=blob:none --no-checkout -b main "${git_base}/pqc-catalog.git" "${work}/pqc-catalog"
git clone -q --filter=blob:none --no-checkout -b main "${git_base}/ci.git" "${work}/ci"
for b in soak-trend vuln-trend; do
  rc=0
  git -C "${work}/ci" ls-remote -q --exit-code origin "refs/heads/${b}" >/dev/null || rc=$?
  case "${rc}" in
    0) git -C "${work}/ci" fetch -q origin "+refs/heads/${b}:refs/remotes/origin/${b}" ;;
    2) ;;
    *) echo "cannot list ci's ${b} branch" >&2; exit 1 ;;
  esac
done

# Every PR, run and sync PR the day can need, one API listing per repo.
# A run is named by its workflow file: a timer-started run's name is its run-name.
for r in "${repos[@]}"; do
  gh_api_pages "/repos/${gh_org}/${r}/pulls?state=all&per_page=100" \
    ".[] | {repo: \"${r}\", number, title, head: .head.ref, head_sha: .head.sha, base: .base.ref, author: .user.login,
      created_at, closed_at, merged_at, merge_sha: .merge_commit_sha}" >"${j}/pulls-${r}"
  gh_api_pages "/repos/${gh_org}/${r}/actions/runs?created=${day}&per_page=100" \
    ".workflow_runs[] | (.path | ltrimstr(\".github/workflows/\") | rtrimstr(\".yaml\")) as \$w | select(\$w | startswith(\"sealhouse-\")) |
      {repo: \"${r}\", workflow: \$w, id, event,
      branch: .head_branch, sha: .head_sha, status, conclusion, created_at, updated_at, url: .html_url}" >"${j}/runs-${r}"
done
cat "${j}"/pulls-* | jq -s . >"${j}/pulls"
# The timer's and the report's own runs are bookkeeping, not delivery.
cat "${j}"/runs-* | jq -s 'map(select(.event != "pull_request" and .workflow != "sealhouse-timer" and .workflow != "sealhouse-report")) |
  sort_by(.created_at, .repo, .id)' >"${j}/runs.all"

# The steps each completed run ran, so a failure counts as fixed only when the step that failed passes again.
: >"${j}/steps"
while read -r r id; do
  gh_api_pages "/repos/${gh_org}/${r}/actions/runs/${id}/jobs?per_page=100" \
    '[.jobs[] | .name as $job | (.steps // [])[] | select(.conclusion == "success" or .conclusion == "failure") |
      {key: ($job + " / " + .name), value: .conclusion}]' |
    jq -sc --argjson id "${id}" '{id: $id, steps: (add // [] | from_entries)}' >>"${j}/steps"
done < <(jq -r '.[] | select(.status == "completed") | "\(.repo) \(.id)"' "${j}/runs.all")
jq --slurpfile steps "${j}/steps" '($steps | map({key: (.id | tostring), value: .steps}) | from_entries) as $s |
  map(. + (if $s[.id | tostring] then {steps: $s[.id | tostring]} else {} end))' "${j}/runs.all" >"${j}/runs"

# Syncs: sync PRs closed in the day, and the upstream commits each brought in.
: >"${j}/syncs"
while read -r pr; do
  r="$(jq -r .repo <<<"${pr}")" head="$(jq -r .head_sha <<<"${pr}")"
  up=null
  if [ "$(jq -r '.merged_at != null' <<<"${pr}")" = true ]; then
    dir="${work}/${r}"
    merge="$(git -C "${dir}" rev-list --first-parent --merges -1 "${head}")"
    new="$(upstream_of "${dir}" "${head}")"
    old=""
    [ -z "${merge}" ] || old="$(upstream_of "${dir}" "${merge}^1")"
    up="$(range "${dir}" "${new}" "${old}" | jq --arg f "${old}" --arg t "${new}" 'if . then . + {from: $f, to: $t} else . end')"
  fi
  jq -c --argjson up "${up}" '{repo, pr: .number, opened_at: .created_at, closed_at, merged: (.merged_at != null), upstream: $up}' <<<"${pr}" >>"${j}/syncs"
done < <(jq -c --arg from "${from}" --arg to "${to}" "${in_day}"' .[] | select(.head == "rhtas/sync" and .base == "rhtas/main" and (.closed_at | in_day))' "${j}/pulls")

# Images: what each fork merge lane run of the day pushed, by the tag merge.yaml gives it.
: >"${j}/images"
while read -r run; do
  r="$(jq -r .repo <<<"${run}")" sha="$(jq -r .sha <<<"${run}")" branch="$(jq -r .branch <<<"${run}")"
  image="$(git -C "${work}/${r}" show "${sha}:.sealhouse/build.env" 2>/dev/null | sed -n 's/^IMAGE=//p' || true)"
  [ -n "${image}" ] || continue
  ref="${registry}/${gh_org}/${image}:${branch//\//-}-${sha:0:12}"
  if ! digest="$(crane digest "${crane_args[@]}" "${ref}" 2>"${work}/crane.err")"; then
    grep -qE 'MANIFEST_UNKNOWN|NAME_UNKNOWN' "${work}/crane.err" || { cat "${work}/crane.err" >&2; echo "cannot look up ${ref}" >&2; exit 1; }
    digest=""
  fi
  jq -c --arg i "${image}" --arg d "${digest}" "${nz}"' {repo, commit: .sha, branch, image: $i, pushed: ($d != ""),
    digest: ($d | nz), at: .updated_at, run: .url}' <<<"${run}" >>"${j}/images"
done < <(jq -c '.[] | select(.workflow == "sealhouse-merge" and .repo != "'"${operator}"'" and .conclusion == "success")' "${j}/runs")

# PRs closed in the day, with who approved them: hands-off means a bot opened it and no person approved it.
: >"${j}/prs"
while read -r pr; do
  r="$(jq -r .repo <<<"${pr}")" n="$(jq -r .number <<<"${pr}")"
  approvers="$(gh_api_pages "/repos/${gh_org}/${r}/pulls/${n}/reviews?per_page=100" \
    '[.[] | select(.state == "APPROVED" and (.user.login | endswith("[bot]") | not)) | .user.login]' | jq -s 'add | unique')"
  jq -c --argjson a "${approvers}" "${kind}"' {repo, pr: .number, title, kind: (.head | kind), author, opened_at: .created_at, closed_at, merged: (.merged_at != null), approved_by: $a,
    hands_off: ((.author | endswith("[bot]")) and ($a | length) == 0)}' <<<"${pr}" >>"${j}/prs"
done < <(jq -c --arg from "${from}" --arg to "${to}" "${in_day}"' .[] | select(.closed_at | in_day)' "${j}/pulls")

# Alphas recorded in the day. Each component image the alpha moved carries its chain:
# upstream commit, sync merged, image pushed, bump merged; the alpha's own time ends it.
catalog="${work}/pqc-catalog" op="${work}/${operator}"
head_env() { git -C "${catalog}" show "$1:alpha/head.env" | sed -n "s/^$2=//p"; }
bump_re='^Bump the .* image to ([^ ]+) [^ ]+ ([0-9a-f]{12})'
: >"${j}/alphas"
mapfile -t alpha_commits < <(git -C "${catalog}" log --format='%H %ct' main -- alpha/head.env)
for i in "${!alpha_commits[@]}"; do
  read -r c t <<<"${alpha_commits[i]}"
  at="$(utc "${t}")"
  [[ "${at}" < "${from}" || ! "${at}" < "${to}" ]] && continue
  op_new="$(head_env "${c}" OPERATOR_COMMIT)"
  op_old=""
  [ $((i + 1)) -ge "${#alpha_commits[@]}" ] || op_old="$(head_env "${alpha_commits[i + 1]%% *}" OPERATOR_COMMIT)"
  components='[]' seen=" "
  # Newest first: the first bump of each repo is the image the alpha ships.
  while read -r _ bt subject; do
    [[ "${subject}" =~ ${bump_re} ]] || continue
    r="${BASH_REMATCH[1]}" short="${BASH_REMATCH[2]}"
    [[ "${seen}" != *" ${r} "* ]] || continue
    seen+="${r} "
    dir="${work}/${r}"
    [ -d "${dir}" ] || continue
    fc="$(git -C "${dir}" rev-parse --verify -q "${short}^{commit}")" || continue
    prev=""
    if [ -n "${op_old}" ]; then
      prev_short="$(git -C "${op}" log --format=%s "${op_old}" -- versions | sed -nE "s/${bump_re}/\1 \2/p" | awk -v r="${r}" '$1 == r && !done { print $2; done = 1 }')"
      [ -z "${prev_short}" ] || prev="$(git -C "${dir}" rev-parse --verify -q "${prev_short}^{commit}" || true)"
    fi
    new_up="$(upstream_of "${dir}" "${fc}")"
    old_up=""
    [ -z "${prev}" ] || old_up="$(upstream_of "${dir}" "${prev}")"
    up=null
    [ -z "${new_up}" ] || [ "${new_up}" = "${old_up}" ] || up="$(range "${dir}" "${new_up}" "${old_up}")"
    synced="$(jq -r --arg r "${r}" '[.[] | select(.repo == $r and .head == "rhtas/sync" and .merged_at != null)] | .[] | "\(.merge_sha) \(.merged_at)"' "${j}/pulls" |
      while read -r ms ma; do
        git -C "${dir}" merge-base --is-ancestor "${ms}" "${fc}" 2>/dev/null || continue
        [ -z "${prev}" ] || ! git -C "${dir}" merge-base --is-ancestor "${ms}" "${prev}" 2>/dev/null || continue
        echo "${ma}"
      done | sort | tail -1)"
    image_at="$(gh_api_pages "/repos/${gh_org}/${r}/actions/workflows/sealhouse-merge.yaml/runs?head_sha=${fc}&status=success&per_page=100" \
      '.workflow_runs[] | .updated_at' | jq -rs 'sort | first // empty')"
    components="$(jq -c --arg r "${r}" --arg c "${fc}" --argjson up "${up}" --arg s "${synced}" --arg i "${image_at}" --arg b "$(utc "${bt}")" \
      "${nz}"' . + [{repo: $r, commit: $c, upstream: $up, synced_at: ($s | nz), image_at: ($i | nz), bump_at: $b}]' <<<"${components}")"
  done < <(git -C "${op}" log --format='%H %ct %s' "${op_new}" ${op_old:+"^${op_old}"} -- versions)
  jq -nc --arg csv "$(head_env "${c}" CSV)" --arg at "${at}" --arg op "${op_new}" --argjson comp "${components}" \
    '{csv: $csv, at: $at, operator_commit: $op, components: ($comp | sort_by(.repo))}' >>"${j}/alphas"
done

# Nightly stages, by job.
: >"${j}/nightly"
while read -r id; do
  gh_api_pages "/repos/${gh_org}/ci/actions/runs/${id}/jobs?per_page=100" '[.jobs[] | {name, conclusion}]' |
    jq -sc --argjson run "$(jq -c --argjson id "${id}" '.[] | select(.id == $id) | {id, conclusion, created_at, url}' "${j}/runs")" \
      'add | sort_by(.name) as $jobs | $run + {jobs: $jobs}' >>"${j}/nightly"
done < <(jq -r '.[] | select(.repo == "ci" and .workflow == "sealhouse-nightly") | .id' "${j}/runs")

trend() {
  git -C "${work}/ci" rev-parse -q --verify "refs/remotes/origin/$1" >/dev/null || { echo '[]'; return; }
  git -C "${work}/ci" show "refs/remotes/origin/$1:$2" |
    jq -Rsc --arg from "${from}" --arg to "${to}" "${in_day}"' split("\n") | map(select(. != "") | split("\t")) |
      .[0] as $h | .[1:] | map([$h, .] | transpose | map({(.[0]): .[1]}) | add) | map(select(.date | in_day))'
}
soak="$(trend soak-trend soak-trend.tsv)"
vulns="$(trend vuln-trend vuln-trend.tsv)"

# pull_state SLUG N FORK prints upstream PR N's state, beside the head carries.lock says FORK carries.
carry_lock="$(git -C "${work}/ci" show HEAD:carries.lock 2>/dev/null | grep -vE '^\s*(#|$)' || true)"
pull_state() {
  local slug="$1" n="$2" carried action target got pr
  read -r carried action target < <(awk -v f="$3" -v p="${n}" '$1 == f && $2 == p { print $3, $4, $5 }' <<<"${carry_lock}"; echo)
  if got="$(gh_api GET "/repos/${slug}/pulls/${n}" 2>/dev/null)"; then
    pr="$(jq -c '{state: (if .merged then "merged" elif .state == "closed" then "closed" elif .draft then "draft" else "open" end),
      head: .head.sha, url: .html_url}' <<<"${got}")"
  else
    pr='{"state": "unknown", "head": null, "url": null}'
  fi
  jq -nc --argjson pr "${pr}" --arg n "${n}" --arg slug "${slug}" --arg carried "${carried:-}" --arg action "${action:-}" --arg target "${target:-}" "${nz}"'
    $pr + {number: ($n | tonumber), url: ($pr.url // "https://github.com/\($slug)/pull/\($n)"), carried: ($carried | nz),
      action: ($action | nz), replaced_by: ($target | nz | if . then tonumber else null end),
      changed: ($carried != "" and $pr.head != null and $pr.head != $carried)}'
}

# A snapshot of now, which a rerun cannot reproduce.
: >"${j}/behind"
: >"${j}/carries"
for f in "${forks[@]}"; do
  dir="${work}/${f}"
  # The carries the next sync replays, as fork-sync lists them, with the upstream PR each one carries.
  read -r _ url branch < <(awk -v f="${f}" '$1 == f' "${forks_lock}")
  url="${url%/}"
  slug="$(awk -F'[/:]' '{ print $(NF - 1) "/" $NF }' <<<"${url%.git}")"
  git -C "${dir}" update-ref "refs/remotes/upstream/${branch}" refs/upstream/head
  list="$(FORK_UPSTREAM_BRANCH="${branch}" "${root}/hack/fork-sync.sh" --list "${dir}")"
  while read -r short _; do
    [ -n "${short}" ] || continue
    git -C "${dir}" log -1 --format='%H%x09%at%x09%s' "${short}"
  done <<<"${list}" | jq -Rsc --arg r "${f}" '{repo: $r, commits: [split("\n")[] | select(. != "") | split("\t") |
    (.[2] | capture("^UPSTREAM: (?<label><carry>|<drop>|[0-9]+): (?<title>.*)$") // {label: null, title: .}) as $s |
    {sha: .[0], at: (.[1] | tonumber | todate), label: ($s.label | if . then ltrimstr("<") | rtrimstr(">") else null end), title: $s.title}]}' >"${j}/fork-carries"
  pulls='{}'
  for n in $(jq -r '[.commits[].label | select(. != null and test("^[0-9]+$"))] | unique[]' "${j}/fork-carries"); do
    pulls="$(jq -c --arg n "${n}" --argjson pr "$(pull_state "${slug}" "${n}" "${f}")" '. + {($n): $pr}' <<<"${pulls}")"
  done
  jq -c --argjson pulls "${pulls}" '.commits |= map(. + {pr: (if .label then $pulls[.label] else null end)})' "${j}/fork-carries" >>"${j}/carries"
  have="$(upstream_of "${dir}" rhtas/main)"
  times="$(git -C "${dir}" log --format=%ct refs/upstream/head ${have:+"^${have}"})"
  jq -nc --arg r "${f}" --arg t "${times}" '($t | split("\n") | map(select(. != "") | tonumber)) as $s |
    {repo: $r, behind: ($s | length), oldest_at: ($s | min | if . then todate else null end)}' >>"${j}/behind"
done
# replaces.lock: each line's drop condition, and whether each fork that uses the module replaces it at the line's release.
git -C "${work}/ci" show HEAD:replaces.lock >"${work}/replaces.lock" 2>/dev/null || : >"${work}/replaces.lock"
replaces_inventory "${work}/replaces.lock" >"${work}/replaces.lines"
: >"${j}/gomods"
if [ -s "${work}/replaces.lines" ]; then
  for f in "${forks[@]}"; do
    d="${work}/mods/${f}"
    git clone -q --depth 1 --filter=blob:none --no-checkout -b rhtas/main "${git_base}/${f}.git" "${d}"
    while read -r path; do
      git -C "${d}" show "HEAD:${path}" >"${work}/go.mod"
      go mod edit -json "${work}/go.mod" | jq -c --arg r "${f}" --arg p "${path}" \
        '{repo: $r, path: $p, requires: [.Require // [] | .[].Path], replaces: [.Replace // [] | .[] | {old: .Old.Path, new: .New.Path, version: .New.Version}]}' >>"${j}/gomods"
    done < <(git -C "${d}" ls-tree -r --name-only HEAD | grep -E '(^|/)go\.mod$')
  done
fi
: >"${j}/replaces"
while read -r module fork_module version drop reason; do
  f="$(cut -d/ -f3 <<<"${fork_module}")"
  read -r _ url _ < <(awk -v f="${f}" '$1 == f' "${forks_lock}"; echo)
  if [ -n "${url}" ]; then
    url="${url%/}"
    cond="$(drop_state "${work}/${f}" "$(fork_subdir "${fork_module}")" "${drop}" "$(awk -F'[/:]' '{ print $(NF - 1) "/" $NF }' <<<"${url%.git}")")"
  else
    cond="$(jq -nc --arg d "${drop}" '{kind: (if $d | startswith("upstream-pr=") then "pr" else "version" end), state: "unknown", released: null}')"
  fi
  jq -sc --arg m "${module}" --arg fm "${fork_module}" --arg v "${version}" --arg d "${drop}" --arg why "${reason}" --argjson c "${cond}" '
    [.[] | select(any(.requires[]; . == $m) or any(.replaces[]; .old == $m)) |
      (first(.replaces[] | select(.old == $m)) // null) as $rep |
      {repo, path, replaced: (if $rep then "\($rep.new) \($rep.version // "")" | rtrimstr(" ") else null end),
        state: (if $rep == null then "missing" elif $rep.new == $fm and $rep.version == $v then "applied" else "other" end)}] |
    group_by(.repo) | map({repo: .[0].repo,
      state: (map(.state) | if all(. == "applied") then "applied" elif any(. == "missing") then "missing" else "other" end),
      files: map(del(.repo))}) as $consumers |
    {module: $m, fork_module: $fm, version: $v, drop: $d, reason: $why, condition: $c, consumers: $consumers}' "${j}/gomods" >>"${j}/replaces"
done <"${work}/replaces.lines"

open_prs="$(jq -c "${kind}"' [.[] | select(.closed_at == null) | {repo, pr: .number, title, author, opened_at: .created_at,
  kind: (.head | kind)}] | sort_by(.repo, .pr)' "${j}/pulls")"
alpha_now="$(git -C "${catalog}" show main:alpha/head.env 2>/dev/null | sed -n 's/^CSV=//p')"

jq -n --arg day "${day}" --arg from "${from}" --arg to "${to}" \
  --arg run_id "${REPORT_RUN_ID:-}" --arg run_url "${REPORT_RUN_URL:-}" --arg ci "${REPORT_CI:-}" \
  --arg now "${REPORT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
  --slurpfile syncs "${j}/syncs" --slurpfile images "${j}/images" --slurpfile prs "${j}/prs" \
  --slurpfile alphas "${j}/alphas" --slurpfile nightly "${j}/nightly" --slurpfile runs "${j}/runs" \
  --slurpfile behind "${j}/behind" --slurpfile carries "${j}/carries" --slurpfile replaces "${j}/replaces" --argjson soak "${soak:-[]}" --argjson vulns "${vulns:-[]}" \
  --argjson open "${open_prs}" --arg alpha "${alpha_now}" '{
    schema: 1, date: $day, status: "ok", partial: ($now < $to or any($runs[0][]; .status != "completed")), window: {from: $from, to: $to},
    run: {id: $run_id, url: $run_url, ci: $ci, collected_at: $now},
    syncs: ($syncs | sort_by(.repo, .pr)), images: ($images | sort_by(.at, .repo)),
    prs: ($prs | sort_by(.repo, .pr)), alphas: ($alphas | sort_by(.at)),
    runs: $runs[0], nightly: ($nightly | sort_by(.created_at)),
    soak: $soak, vulns: $vulns,
    snapshot: {at: $now, alpha: $alpha, behind: ($behind | sort_by(.repo)), carries: ($carries | sort_by(.repo)),
      replaces: ($replaces | sort_by(.module)), open_prs: $open}
  }' >"${work}/report.json"
mv "${work}/report.json" "${out}"
