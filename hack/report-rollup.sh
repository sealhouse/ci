#!/usr/bin/env bash
# report-rollup.sh DAILY_DIR OUT writes OUT, the series the site charts, from DAILY_DIR's YYYY-MM-DD.json files.
# A day with no file between the first and the last is "missing".
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: $0 DAILY_DIR OUT" >&2; exit 2; }
dir="$1" out="$2"
shopt -s nullglob
files=("${dir}"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json)
[ "${#files[@]}" -gt 0 ] || { echo "no daily reports in ${dir}" >&2; exit 1; }
for f in "${files[@]}"; do
  jq -e --arg d "$(basename "${f}" .json)" '.schema == 1 and .date == $d and (.status == "ok" or .status == "failed")' "${f}" >/dev/null ||
    { echo "${f}: not a schema 1 report for its date" >&2; exit 1; }
done

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
jq -s '
  def hours(a; b): if a == null or b == null then null else (((b | fromdate) - (a | fromdate)) / 3600 * 100 | round / 100) end;
  def dates(a; b): [range((a + "T00:00:00Z" | fromdate); (b + "T00:00:00Z" | fromdate) + 1; 86400) | todate[:10]];
  (sort_by(.date)) as $all |
  (map({key: .date, value: .}) | from_entries) as $by |
  [$all[] | select(.status == "ok")] as $ok |
  {
    schema: 1,
    first: $all[0].date, last: $all[-1].date,
    last_collected_at: ([$ok[].run.collected_at | select(. != null and . != "")] | max),
    last_attempt_at: ([$all[].run.collected_at | select(. != null and . != "")] | max),
    days: [dates($all[0].date; $all[-1].date)[] as $d | $by[$d] as $r |
      if $r == null then {date: $d, status: "missing"}
      elif $r.status == "failed" then {date: $d, status: "failed", run: $r.run.url}
      else {date: $d, status: "ok", partial: ($r.partial // false), run: $r.run.url,
        syncs: ([$r.syncs[] | select(.merged)] | length),
        syncs_closed: ([$r.syncs[] | select(.merged | not)] | length),
        upstream_commits: ([$r.syncs[].upstream.count // 0] | add // 0),
        images: ([$r.images[] | select(.pushed)] | length),
        alphas: ($r.alphas | length),
        prs: ([$r.prs[] | select(.merged)] | length),
        hands_off: ([$r.prs[] | select(.merged and .hands_off)] | length),
        runs: ($r.runs | length),
        runs_failed: ([$r.runs[] | select(.conclusion == "failure")] | length)}
      end],
    alphas: [$ok[].alphas[] | . as $a | $a + {components: [$a.components[] | . + {hours: {
      newest_to_alpha: hours(.upstream.newest_at; $a.at),
      oldest_to_alpha: hours(.upstream.oldest_at; $a.at),
      upstream_to_sync: hours(.upstream.newest_at; .synced_at),
      sync_to_image: hours(.synced_at; .image_at),
      image_to_bump: hours(.image_at; .bump_at),
      bump_to_alpha: hours(.bump_at; $a.at)}}]}],
    # A failed step stays failed until the same step passes, so a run that skips it fixes nothing. A run that
    # failed without a failed step (or was collected without steps) recovers at the next green run.
    incidents: ([$ok[].runs[] | select(.status == "completed" and (.conclusion == "success" or .conclusion == "failure")) |
      (.steps // {}) as $s |
      ([$s | to_entries[] | {step: .key, failed: (.value == "failure")}] +
        if .conclusion == "success" then [{step: null, failed: false}]
        elif ([$s[] | select(. == "failure")] | length) == 0 then [{step: null, failed: true}]
        else [] end)[] as $e | . + $e] |
      group_by([.repo, .workflow, .branch, .step]) | map(sort_by(.created_at) |
        reduce .[] as $r ({open: null, done: []};
          if $r.failed then (if .open == null then .open = $r else . end)
          elif .open != null then .done += [{repo: $r.repo, workflow: $r.workflow, branch: $r.branch, step: $r.step,
            from: .open.created_at, to: $r.updated_at, hours: hours(.open.created_at; $r.updated_at), run: .open.url}] | .open = null
          else . end) |
        .done + (if .open then [{repo: .open.repo, workflow: .open.workflow, branch: .open.branch, step: .open.step,
          from: .open.created_at, to: null, hours: null, run: .open.url}] else [] end)) | add // [] | sort_by(.from, .step // "")),
    # A day counts its last nightly, as a catch-up or rerun replaces the one before it.
    nightly: [$ok[] | .date as $d | select(.nightly | length > 0) | .nightly | max_by(.created_at) | {date: $d, conclusion, url,
      jobs: (.jobs | map({key: .name, value: .conclusion}) | from_entries)}],
    soak: [$ok[].soak[]],
    # A day counts its last scan. A fix bakes until its due day; rows from before due was recorded count as taken.
    vulns: [$ok[] | select(.vulns | length > 0) | (.vulns | map(.date) | max) as $last | .vulns |= map(select(.date == $last)) | {date,
      fix: ([.vulns[] | select(.osv != "" and .fixed != "" and (.due // "") <= .date[:10])] | unique_by([.repo, .osv]) | length),
      baking: ([.vulns[] | select(.osv != "" and .fixed != "" and (.due // "") > .date[:10])] | unique_by([.repo, .osv]) | length),
      nofix: ([.vulns[] | select(.osv != "" and .fixed == "")] | unique_by([.repo, .osv]) | length),
      repos: ([.vulns[].repo] | unique | length)}],
    behind: [[$ok[].snapshot] | group_by(.at[:10])[] | max_by(.at) as $s | $s.behind[] | {date: $s.at[:10], repo, behind,
      age_hours: hours(.oldest_at; $s.at)}],
    open_prs: ($ok[-1].snapshot.open_prs // []),
    carries: ($ok[-1].snapshot.carries // []),
    alpha: ($ok[-1].snapshot.alpha // null)
  }' "${files[@]}" >"${tmp}"
mv "${tmp}" "${out}"
trap - EXIT
