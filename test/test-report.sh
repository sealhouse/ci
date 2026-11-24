#!/usr/bin/env bash
# Runs the report scripts against real git repos with set commit times, a real registry and a fake API.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"
hack="${root}/hack"
t="$(mktemp -d)"
api_port=5007 reg_port=5008 reg=test-report-registry
cleanup() {
  [ -z "${api_pid:-}" ] || kill "${api_pid}" 2>/dev/null || true
  [ -z "${http_pid:-}" ] || kill "${http_pid}" 2>/dev/null || true
  docker rm -f "${reg}" >/dev/null 2>&1 || true
  rm -rf "${t}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

log="${t}/api.log"
touch "${log}"
python3 "${root}/test/fake-github.py" "${api_port}" "${log}" &
api_pid=$!
export GITHUB_API_URL="http://127.0.0.1:${api_port}" GH_TOKEN=read-token
for _ in $(seq 100); do curl -fs -X POST -d '{}' "${GITHUB_API_URL}/__state" >/dev/null && break; sleep 0.1; done
state() { curl -fs -X POST -d "$1" "${GITHUB_API_URL}/__state" >/dev/null; }
calls() { jq -c --arg m "$1" --arg p "$2" 'select(.method == $m and (.path | test($p)))' "${log}"; }

docker rm -f "${reg}" >/dev/null 2>&1 || true
docker run -d --rm -p "127.0.0.1:${reg_port}:5000" --name "${reg}" "$(lock REGISTRY)" >/dev/null
export REPORT_REGISTRY="localhost:${reg_port}"
until crane catalog --insecure "${REPORT_REGISTRY}" >/dev/null 2>&1; do sleep 0.2; done

# The day under test, and times relative to it.
day=2026-03-10
at() { date -u -d "${day} $1" +%s; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
commit() {
  local dir="$1" when="$2" msg="$3"
  GIT_AUTHOR_DATE="@${when} +0000" GIT_COMMITTER_DATE="@${when} +0000" git -C "${dir}" commit -q --allow-empty -m "${msg}"
  git -C "${dir}" rev-parse HEAD
}
bare() {
  git init -q --bare "$2"
  git -C "$2" config uploadpack.allowFilter true
  git -C "$2" config uploadpack.allowAnySHA1InWant true
  git -C "$2" symbolic-ref HEAD "refs/heads/$3"
  git -C "$1" push -q "$2" "${@:3}"
}
gitroot="${t}/git"
mkdir -p "${gitroot}/sealhouse" "${t}/up"
export REPORT_GIT="file://${gitroot}"

# Upstream: U0 is the fork base; U1 and U2 arrive for the day's sync; U3 is still waiting.
up="${t}/w/up"
git init -q -b main "${up}"
u0="$(commit "${up}" "$(at '-10 days')" "upstream base")"
u1="$(commit "${up}" "$(at '-2 hours')" "upstream one")"
u2="$(commit "${up}" "$(at '01:00')" "upstream two")"
u3="$(commit "${up}" "$(at '+1 day 06:00')" "upstream three")"

# The fork: U0 plus the image carry, pinned by the first alpha; then the day's sync of U2 and the replayed carry.
fork="${t}/w/timestamp-authority"
git init -q -b rhtas/main "${fork}"
git -C "${fork}" fetch -q "${up}" "${u0}"
git -C "${fork}" reset -q --hard "${u0}"
mkdir -p "${fork}/.sealhouse"
echo IMAGE=tsa >"${fork}/.sealhouse/build.env"
git -C "${fork}" add .sealhouse/build.env
c0="$(commit "${fork}" "$(at '-3 days')" "UPSTREAM: <carry>: image build")"
git -C "${fork}" fetch -q "${up}" "${u2}"
GIT_COMMITTER_DATE="@$(at '02:00') +0000" git -C "${fork}" merge -q --no-ff -m "Merge upstream main ${u2:0:7} into rhtas/main" "${u2}"
merge="$(git -C "${fork}" rev-parse HEAD)"
k="$(commit "${fork}" "$(at '02:00')" "UPSTREAM: <drop>: Pin ci")"
bare "${fork}" "${gitroot}/sealhouse/timestamp-authority.git" rhtas/main
bare "${up}" "${t}/up/tsa.git" main
# A library fork with nothing going on.
lib="${t}/w/sigstore-go"
git init -q -b rhtas/main "${lib}"
git -C "${lib}" fetch -q "${up}" "${u3}"
git -C "${lib}" reset -q --hard "${u3}"
bare "${lib}" "${gitroot}/sealhouse/sigstore-go.git" rhtas/main
printf 'timestamp-authority file://%s main\nsigstore-go file://%s main\n' "${t}/up/tsa.git" "${t}/up/tsa.git" >"${t}/forks.lock"
export REPORT_FORKS="${t}/forks.lock"

# The operator: the first pin of C0, then the day's bump to K.
op="${t}/w/operator"
git init -q -b main "${op}"
mkdir -p "${op}/versions/2.0"
echo "TSA_IMAGE=x@sha256:0" >"${op}/versions/2.0/images.env"
git -C "${op}" add versions
o1="$(commit "${op}" "$(at '-3 days')" "Bump the 2.0 tsa image to timestamp-authority rhtas/main ${c0:0:12} (#2)")"
o2="$(commit "${op}" "$(at '-2 days')" "Pin ci 0123456789ab")"
echo "TSA_IMAGE=x@sha256:1" >"${op}/versions/2.0/images.env"
git -C "${op}" add versions
o3="$(commit "${op}" "$(at '04:00')" "Bump the 2.0 tsa image to timestamp-authority rhtas/main ${k:0:12} (#5)")"
bare "${op}" "${gitroot}/sealhouse/secure-sign-pqc-operator.git" main

# The catalog: the first alpha two days before, the second in the day.
cat_dir="${t}/w/pqc-catalog"
git init -q -b main "${cat_dir}"
mkdir -p "${cat_dir}/alpha"
printf 'CSV=op.v0.1.0-alpha.1\nOPERATOR_COMMIT=%s\n' "${o2}" >"${cat_dir}/alpha/head.env"
git -C "${cat_dir}" add alpha
commit "${cat_dir}" "$(at '-2 days')" "alpha: op.v0.1.0-alpha.1" >/dev/null
printf 'CSV=op.v0.1.0-alpha.2\nOPERATOR_COMMIT=%s\n' "${o3}" >"${cat_dir}/alpha/head.env"
git -C "${cat_dir}" add alpha
commit "${cat_dir}" "$(at '05:00')" "alpha: op.v0.1.0-alpha.2" >/dev/null
bare "${cat_dir}" "${gitroot}/sealhouse/pqc-catalog.git" main

# ci, with the soak and vulnerability trend branches.
ci_dir="${t}/w/ci"
git init -q -b main "${ci_dir}"
commit "${ci_dir}" "$(at '-30 days')" "ci" >/dev/null
git -C "${ci_dir}" switch -q -c soak-trend
printf 'date\tcommit\tcsv\tgoroutines\theap_mib\tsys_mib\tkills\tresult\n%s\tabc\top.v0.1.0-alpha.1\t139\t12.5\t30.1\t14\tpass\n%s\tdef\top.v0.1.0-alpha.2\t141\t12.9\t30.0\t15\tpass\n' \
  "$(iso "$(at '-1 day 10:00')")" "$(iso "$(at '10:00')")" >"${ci_dir}/soak-trend.tsv"
git -C "${ci_dir}" add soak-trend.tsv
commit "${ci_dir}" "$(at '10:00')" "Record soak-trend.tsv" >/dev/null
git -C "${ci_dir}" switch -q -c vuln-trend main
printf 'date\trepo\tosv\tmodule\tversion\tfixed\tdue\n%s\ttimestamp-authority\tGO-2026-1\texample.com/m\tv1.0.0\tv1.1.0\t2026-03-10\n%s\ttimestamp-authority\tGO-2026-2\texample.com/n\tv2.0.0\t\t\n%s\ttimestamp-authority\tGO-2026-3\texample.com/o\tv1.0.0\tv1.0.1\t2026-03-15\n%s\tsecure-sign-pqc-operator\tGO-2026-4\texample.com/p\tv1.0.0\tv1.0.1\n%s\tsecure-sign-pqc-operator\t\t\t\t\t\n' \
  "$(iso "$(at '09:00')")" "$(iso "$(at '09:00')")" "$(iso "$(at '09:00')")" "$(iso "$(at '09:00')")" "$(iso "$(at '09:00')")" >"${ci_dir}/vuln-trend.tsv"
git -C "${ci_dir}" add vuln-trend.tsv
commit "${ci_dir}" "$(at '09:00')" "Record vuln-trend.tsv" >/dev/null
bare "${ci_dir}" "${gitroot}/sealhouse/ci.git" main soak-trend vuln-trend

# The image the day's merge lane pushed for K.
crane append --insecure -f <(tar -cf - -T /dev/null) -t "${REPORT_REGISTRY}/sealhouse/tsa:rhtas-main-${k:0:12}" >/dev/null 2>&1

pr() { jq -nc --arg h "$1" --arg sha "$2" --arg a "$3" --arg c "$4" --arg x "$5" --arg m "$6" --arg ms "$7" --argjson n "$8" --arg title "$9" \
  '{number: $n, title: $title, head: {ref: $h, sha: $sha}, base: {ref: (if $h == "rhtas/sync" then "rhtas/main" else "main" end)},
    user: {login: $a}, created_at: $c, closed_at: ($x | if . == "" then null else . end),
    merged_at: ($m | if . == "" then null else . end), merge_commit_sha: ($ms | if . == "" then null else . end)}'; }
run() { jq -nc --argjson id "$1" --arg n "$2" --arg e "$3" --arg b "$4" --arg sha "$5" --arg c "$6" --arg u "$7" --arg conc "$8" \
  '{id: $id, name: $n, path: (".github/workflows/" + $n + ".yaml"), event: $e, head_branch: $b, head_sha: $sha, status: "completed",
    conclusion: $conc, created_at: $c, updated_at: $u, html_url: ("https://github.example/runs/" + ($id | tostring))}'; }
state "$(jq -n \
  --argjson tsa "[$(pr rhtas/sync "${k}" 'sealhouse-sync[bot]' "$(iso "$(at '02:30')")" "$(iso "$(at '03:00')")" "$(iso "$(at '03:00')")" "${k}" 7 'Sync'),
    $(pr rhtas/sync 0000 'sealhouse-sync[bot]' "$(iso "$(at '01:00')")" "$(iso "$(at '01:30')")" '' '' 6 'Sync')]" \
  --argjson op "[$(pr bump/2.0-tsa-image-x "${o3}" 'sealhouse-bot[bot]' "$(iso "$(at '03:30')")" "$(iso "$(at '04:00')")" "$(iso "$(at '04:00')")" "${o3}" 5 'Bump'),
    $(pr bump/2.0-tsa-image-y 1111 'sealhouse-bot[bot]' "$(iso "$(at '06:00')")" '' '' '' 6 'Bump open')]" \
  --argjson ci "[$(pr feature-a 2222 dev "$(iso "$(at '-1 day')")" "$(iso "$(at '00:00')")" "$(iso "$(at '00:00')")" 2222 3 'At midnight'),
    $(pr feature-b 3333 dev "$(iso "$(at '-1 day')")" "$(iso "$(at '+1 day 00:00')")" "$(iso "$(at '+1 day 00:00')")" 3333 4 'Next midnight'),
    $(pr feature-c 4444 dev "$(iso "$(at '-1 day')")" "$(iso "$(at '-1 day')")" "$(iso "$(at '-1 day')")" 4444 2 'Day before')]" \
  --argjson tsaruns "[$(run 101 sealhouse-merge push rhtas/main "${merge}" "$(iso "$(at '02:10')")" "$(iso "$(at '02:20')")" failure),
    $(run 102 sealhouse-merge push rhtas/main "${k}" "$(iso "$(at '03:05')")" "$(iso "$(at '03:20')")" success),
    $(run 103 sealhouse-pr pull_request rhtas/sync "${k}" "$(iso "$(at '02:31')")" "$(iso "$(at '02:50')")" success),
    $(run 104 sealhouse-merge push rhtas/main "${c0}" "$(iso "$(at '-3 days')")" "$(iso "$(at '-3 days')")" success)]" \
  --argjson ciruns "[$(run 900 sealhouse-nightly schedule main aaaa "$(iso "$(at '08:40')")" "$(iso "$(at '09:30')")" success),
    $(run 910 sealhouse-sync schedule main aaaa "$(iso "$(at '10:00')")" "$(iso "$(at '10:05')")" failure),
    $(run 911 sealhouse-sync schedule main aaaa "$(iso "$(at '10:41')")" "$(iso "$(at '10:42')")" success),
    $(run 912 sealhouse-sync workflow_dispatch main aaaa "$(iso "$(at '14:00')")" "$(iso "$(at '14:06')")" success),
    $(run 920 sealhouse-repin push main aaaa "$(iso "$(at '15:00')")" "$(iso "$(at '15:00')")" failure),
    $(run 921 sealhouse-repin push main aaaa "$(iso "$(at '16:00')")" "$(iso "$(at '16:30')")" success),
    $(run 930 sealhouse-nightly workflow_dispatch main aaaa 2026-03-02T23:00:00Z 2026-03-02T23:30:00Z '' | jq -c '.status = "in_progress"'),
    $(run 940 sealhouse-timer workflow_dispatch main aaaa 2026-03-02T10:00:00Z 2026-03-02T10:01:00Z failure),
    $(run 941 sealhouse-report workflow_dispatch main aaaa 2026-03-02T10:05:00Z 2026-03-02T10:07:00Z failure)]" \
  '{page_size: 2, fail_paths: [],
    pulls_by_repo: {"timestamp-authority": $tsa, "secure-sign-pqc-operator": $op, ci: $ci},
    reviews: {"secure-sign-pqc-operator#5": [{user: {login: "maint"}, state: "APPROVED"}, {user: {login: "sealhouse-bot[bot]"}, state: "APPROVED"}],
      "ci#3": [{user: {login: "dev2"}, state: "COMMENTED"}]},
    runs_by_repo: {"timestamp-authority": $tsaruns, ci: $ciruns},
    jobs: {"900": [{name: "vulns", conclusion: "success"}, {name: "kind (1.33)", conclusion: "success"}, {name: "soak", conclusion: "skipped"}],
      "101": [{name: "merge", conclusion: "failure", steps: [{name: "Build", conclusion: "failure"}, {name: "Push", conclusion: "skipped"}]}],
      "102": [{name: "merge", conclusion: "success", steps: [{name: "Build", conclusion: "success"}, {name: "Push", conclusion: "success"}]}],
      "910": [{name: "sync", conclusion: "failure", steps: [{name: "Finish green syncs", conclusion: "success"}, {name: "Start syncs", conclusion: "failure"}]}],
      "911": [{name: "sync", conclusion: "success", steps: [{name: "Finish green syncs", conclusion: "success"}, {name: "Start syncs", conclusion: "skipped"}]}],
      "912": [{name: "sync", conclusion: "success", steps: [{name: "Finish green syncs", conclusion: "success"}, {name: "Start syncs", conclusion: "success"}]}],
      "920": [{name: "repin", conclusion: "failure", steps: []}]}}')"
export REPORT_RUN_ID=77 REPORT_RUN_URL=https://github.example/runs/77 REPORT_CI=c1c1 REPORT_NOW="$(iso "$(at '+1 day 12:30')")"

out="${t}/out"
mkdir -p "${out}"
"${hack}/report-collect.sh" "${day}" "${out}/${day}.json"
r="${out}/${day}.json"
jq -e '.schema == 1 and .status == "ok" and .partial == false and .date == "2026-03-10" and .window == {from: "2026-03-10T00:00:00Z", to: "2026-03-11T00:00:00Z"}
  and .run == {id: "77", url: "https://github.example/runs/77", ci: "c1c1", collected_at: "2026-03-11T12:30:00Z"}' "${r}" >/dev/null || fail "header"
jq -e --arg u0 "${u0}" --arg u2 "${u2}" '.syncs == [
  {repo: "timestamp-authority", pr: 6, opened_at: "2026-03-10T01:00:00Z", closed_at: "2026-03-10T01:30:00Z", merged: false, upstream: null},
  {repo: "timestamp-authority", pr: 7, opened_at: "2026-03-10T02:30:00Z", closed_at: "2026-03-10T03:00:00Z", merged: true,
   upstream: {count: 2, newest_at: "2026-03-10T01:00:00Z", oldest_at: "2026-03-09T22:00:00Z", from: $u0, to: $u2}}]' "${r}" >/dev/null ||
  fail "syncs: $(jq -c .syncs "${r}")"
ok "a merged sync counts the upstream commits it brought in; a closed one counts none"
jq -e --arg k "${k}" '.images | length == 1 and .[0].repo == "timestamp-authority" and .[0].commit == $k and .[0].image == "tsa"
  and .[0].pushed and (.[0].digest | startswith("sha256:")) and .[0].at == "2026-03-10T03:20:00Z"' "${r}" >/dev/null || fail "images: $(jq -c .images "${r}")"
ok "an image is the merge lane's push, found by its tag; a failed merge run pushes none"
jq -e '[.prs[] | "\(.repo)#\(.pr) \(.kind) \(.merged) \(.hands_off) \(.approved_by | join(","))"] == [
  "ci#3 other true false ", "secure-sign-pqc-operator#5 bump true false maint",
  "timestamp-authority#6 sync false true ", "timestamp-authority#7 sync true true "]' "${r}" >/dev/null || fail "prs: $(jq -c '[.prs[] | [.repo, .pr, .hands_off, .approved_by]]' "${r}")"
ok "PRs closed in the day, across pages: an event at 00:00:00 is in its day, the next midnight is not; bot approvals do not count"
jq -e --arg k "${k}" --arg o3 "${o3}" '.alphas == [{csv: "op.v0.1.0-alpha.2", at: "2026-03-10T05:00:00Z", operator_commit: $o3, components: [
  {repo: "timestamp-authority", commit: $k, upstream: {count: 2, newest_at: "2026-03-10T01:00:00Z", oldest_at: "2026-03-09T22:00:00Z"},
   synced_at: "2026-03-10T03:00:00Z", image_at: "2026-03-10T03:20:00Z", bump_at: "2026-03-10T04:00:00Z"}]}]' "${r}" >/dev/null ||
  fail "alphas: $(jq -c .alphas "${r}")"
ok "an alpha carries each component's chain: upstream, synced, image, bump"
jq -e '[.runs[] | .id] == [101, 102, 900, 910, 911, 912, 920, 921]' "${r}" >/dev/null || fail "runs: $(jq -c '[.runs[].id]' "${r}")"
jq -e '[.runs[] | select(.id == 910 or .id == 911 or .id == 920 or .id == 921) | .steps] ==
  [{"sync / Finish green syncs": "success", "sync / Start syncs": "failure"}, {"sync / Finish green syncs": "success"}, {}, {}]' "${r}" >/dev/null ||
  fail "run steps: $(jq -c '[.runs[] | {id, steps}]' "${r}")"
jq -e '.nightly == [{id: 900, conclusion: "success", created_at: "2026-03-10T08:40:00Z", url: "https://github.example/runs/900",
  jobs: [{name: "kind (1.33)", conclusion: "success"}, {name: "soak", conclusion: "skipped"}, {name: "vulns", conclusion: "success"}]}]' "${r}" >/dev/null ||
  fail "nightly: $(jq -c .nightly "${r}")"
ok "runs leave out PR checks and carry the steps they ran; the nightly carries its jobs"
jq -e '(.soak | map(.csv)) == ["op.v0.1.0-alpha.2"] and (.vulns | map([.repo, .osv, .fixed, .due])) ==
  [["timestamp-authority", "GO-2026-1", "v1.1.0", "2026-03-10"], ["timestamp-authority", "GO-2026-2", "", ""], ["timestamp-authority", "GO-2026-3", "v1.0.1", "2026-03-15"],
   ["secure-sign-pqc-operator", "GO-2026-4", "v1.0.1", null], ["secure-sign-pqc-operator", "", "", ""]]' "${r}" >/dev/null ||
  fail "trends: $(jq -c '[.soak, .vulns]' "${r}")"
ok "the soak and vulnerability trends give the day's rows"
jq -e '.snapshot.alpha == "op.v0.1.0-alpha.2" and .snapshot.behind == [
  {repo: "sigstore-go", behind: 0, oldest_at: null}, {repo: "timestamp-authority", behind: 1, oldest_at: "2026-03-11T06:00:00Z"}]
  and ([.snapshot.open_prs[] | "\(.repo)#\(.pr) \(.kind)"] == ["secure-sign-pqc-operator#6 bump"])' "${r}" >/dev/null ||
  fail "snapshot: $(jq -c .snapshot "${r}")"
jq -e --arg k "${k}" '.snapshot.carries == [{repo: "sigstore-go", commits: []},
  {repo: "timestamp-authority", commits: [{sha: $k, at: "2026-03-10T02:00:00Z", label: "drop", title: "Pin ci"}]}]' "${r}" >/dev/null ||
  fail "carries: $(jq -c .snapshot.carries "${r}")"
ok "the snapshot has each fork's waiting upstream commits, current carries and the open PRs"

REPORT_RUN_ID=78 REPORT_NOW=2026-03-12T01:00:00Z "${hack}/report-collect.sh" "${day}" "${out}/again.json"
cmp <(jq -S 'del(.run, .snapshot)' "${r}") <(jq -S 'del(.run, .snapshot)' "${out}/again.json") || fail "a rerun differs"
ok "a rerun of the same day gives the same report, but for the run and the snapshot"

"${hack}/report-collect.sh" 2026-03-01 "${out}/2026-03-01.json"
jq -e '.status == "ok" and .syncs == [] and .images == [] and .prs == [] and .alphas == [] and .runs == [] and .nightly == []
  and .soak == [] and .vulns == []' "${out}/2026-03-01.json" >/dev/null || fail "quiet day"
ok "a quiet day still gets a report, with nothing in it"

REPORT_NOW="$(iso "$(at '18:00')")" "${hack}/report-collect.sh" "${day}" "${out}/so-far.json"
jq -e '.partial' "${out}/so-far.json" >/dev/null || fail "a day collected before its end is not partial"
"${hack}/report-collect.sh" 2026-03-02 "${out}/2026-03-02.json"
jq -e '.partial and ([.runs[].id] == [930])' "${out}/2026-03-02.json" >/dev/null || fail "running day: $(jq -c '[.partial, [.runs[].id]]' "${out}/2026-03-02.json")"
mkdir -p "${t}/partial"
cp "${out}/2026-03-02.json" "${t}/partial/"
"${hack}/report-rollup.sh" "${t}/partial" "${t}/partial.json"
jq -e '.days[0].partial and .days[0].runs == 1 and .days[0].runs_failed == 0' "${t}/partial.json" >/dev/null || fail "rollup partial: $(jq -c .days "${t}/partial.json")"
ok "a day is partial until it has ended and its runs have completed; the timer's and the report's own runs are left out"

"${hack}/report-collect.sh" 2026-03-07 "${out}/2026-03-07.json"
jq -e --arg c0 "${c0}" '.images == [{repo: "timestamp-authority", commit: $c0, branch: "rhtas/main", image: "tsa", pushed: false, digest: null,
  at: "2026-03-07T00:00:00Z", run: "https://github.example/runs/104"}]' "${out}/2026-03-07.json" >/dev/null ||
  fail "unpushed image: $(jq -c .images "${out}/2026-03-07.json")"
ok "a green merge run whose tag is absent pushed no image"
"${hack}/report-collect.sh" 2026-03-08 "${out}/2026-03-08.json"
jq -e --arg c0 "${c0}" '.alphas | length == 1 and .[0].csv == "op.v0.1.0-alpha.1" and (.[0].components | length == 1)
  and .[0].components[0].commit == $c0 and .[0].components[0].upstream == null and .[0].components[0].synced_at == null
  and .[0].components[0].image_at == "2026-03-07T00:00:00Z"' "${out}/2026-03-08.json" >/dev/null ||
  fail "first pin: $(jq -c .alphas "${out}/2026-03-08.json")"
ok "a component's first pin has no upstream range, rather than the fork base's age"

state '{"fail_paths": ["/reviews"]}'
if "${hack}/report-collect.sh" "${day}" "${out}/broken.json" 2>/dev/null; then fail "a 502 did not fail the collection"; fi
[ ! -e "${out}/broken.json" ] || fail "a failed collection wrote a report"
state '{"fail_paths": []}'
if REPORT_REGISTRY=localhost:5010 "${hack}/report-collect.sh" "${day}" "${out}/broken.json" 2>/dev/null; then fail "an unreachable registry did not fail the collection"; fi
[ ! -e "${out}/broken.json" ] || fail "a registry error wrote a report"
ok "an API or registry error fails the collection and writes nothing"

# The rollup, over the day, a missing day and a failed one.
daily="${t}/daily"
mkdir -p "${daily}"
cp "${out}/2026-03-08.json" "${out}/${day}.json" "${daily}/"
jq -n '{schema: 1, date: "2026-03-11", status: "failed", run: {id: "79", url: "https://github.example/runs/79", ci: "c1c1", collected_at: "2026-03-12T12:30:00Z"}}' \
  >"${daily}/2026-03-11.json"
"${hack}/report-rollup.sh" "${daily}" "${t}/rollup.json"
ru="${t}/rollup.json"
jq -e '[.days[] | "\(.date) \(.status)"] == ["2026-03-08 ok", "2026-03-09 missing", "2026-03-10 ok", "2026-03-11 failed"]
  and .last_collected_at == "2026-03-11T12:30:00Z" and .last_attempt_at == "2026-03-12T12:30:00Z"' "${ru}" >/dev/null ||
  fail "days: $(jq -c '[.days, .last_collected_at]' "${ru}")"
jq -e '.days[2] | .syncs == 1 and .syncs_closed == 1 and .upstream_commits == 2 and .images == 1 and .alphas == 1 and .prs == 3
  and .hands_off == 1 and .runs == 8 and .runs_failed == 3' "${ru}" >/dev/null || fail "day counts: $(jq -c '.days[2]' "${ru}")"
ok "the rollup marks a missing day and a failed one, and counts a good one"
jq -e '.alphas[-1].components[0].hours == {newest_to_alpha: 4, oldest_to_alpha: 7, upstream_to_sync: 2, sync_to_image: 0.33,
  image_to_bump: 0.67, bump_to_alpha: 1}' "${ru}" >/dev/null || fail "lead hours: $(jq -c '.alphas[-1].components[0].hours' "${ru}")"
ok "lead time splits into its stages, in hours"
jq -e '.incidents == [
  {repo: "timestamp-authority", workflow: "sealhouse-merge", branch: "rhtas/main", step: "merge / Build", from: "2026-03-10T02:10:00Z",
   to: "2026-03-10T03:20:00Z", hours: 1.17, run: "https://github.example/runs/101"},
  {repo: "ci", workflow: "sealhouse-sync", branch: "main", step: "sync / Start syncs", from: "2026-03-10T10:00:00Z",
   to: "2026-03-10T14:06:00Z", hours: 4.1, run: "https://github.example/runs/910"},
  {repo: "ci", workflow: "sealhouse-repin", branch: "main", step: null, from: "2026-03-10T15:00:00Z",
   to: "2026-03-10T16:30:00Z", hours: 1.5, run: "https://github.example/runs/920"}]' "${ru}" >/dev/null || fail "incidents: $(jq -c .incidents "${ru}")"
ok "a failed step recovers only when it passes again, not at a run that skips it; a failure without a failed step recovers at the next green run"
jq -e '.vulns == [{date: "2026-03-10", fix: 2, baking: 1, nofix: 1, repos: 2}] and (.nightly[0].jobs == {"kind (1.33)": "success", soak: "skipped", vulns: "success"})
  and (.behind | length == 2) and .alpha == "op.v0.1.0-alpha.2" and ([.carries[] | "\(.repo) \(.commits | length)"] == ["sigstore-go 0", "timestamp-authority 1"])' "${ru}" >/dev/null ||
  fail "series: $(jq -c '[.vulns, .nightly, .behind, .carries]' "${ru}")"
ok "the vulnerability series, with a fix due that night fixable, a later one baking and one recorded before due counted fixable; the nightly and waiting-commit series, and the latest carries"
jq '.vulns = [.vulns[0] | .date = "2026-03-10T01:00:00Z" | .repo = "early" | .osv = "GO-2026-0009" | .fixed = "v2" | .due = "2026-03-01"]
  + .vulns' "${daily}/${day}.json" >"${t}/early.json"
mv "${t}/early.json" "${daily}/${day}.json"
"${hack}/report-rollup.sh" "${daily}" "${ru}"
jq -e '.vulns == [{date: "2026-03-10", fix: 2, baking: 1, nofix: 1, repos: 2}]' "${ru}" >/dev/null || fail "two scans: $(jq -c .vulns "${ru}")"
ok "a day with two scans counts the last, so a fix found in the first and merged before the second is gone"
cp "${out}/again.json" "${daily}/2026-03-12.json"
if "${hack}/report-rollup.sh" "${daily}" "${t}/bad.json" 2>/dev/null; then fail "a report under another date's name was accepted"; fi
rm "${daily}/2026-03-12.json"
jq '.schema = 2' "${out}/2026-03-01.json" >"${daily}/2026-03-01.json"
if "${hack}/report-rollup.sh" "${daily}" "${t}/bad.json" 2>/dev/null; then fail "a schema 2 report was accepted"; fi
rm "${daily}/2026-03-01.json"
ok "the rollup refuses a report for another date and an unknown schema"


# Publishing to reports, through the API, as the bot App.
openssl genrsa -out "${t}/key.pem" 2048 2>/dev/null
export BOT_APP_ID=11 BOT_APP_KEY="$(cat "${t}/key.pem")"
rep="${t}/w/reports"
git init -q -b main "${rep}"
commit "${rep}" "$(at '-30 days')" "Reports" >/dev/null
bare "${rep}" "${gitroot}/sealhouse/reports.git" main
: >"${log}"
"${hack}/report-publish.sh" "${day}" "${r}" >/dev/null
calls POST /git/trees | jq -e '[.body.tree[].path] == ["data/daily/2026-03-10.json", "data/rollup.json"]' >/dev/null || fail "publish paths"
calls POST 'reports/git/commits$' | jq -e '.body.message == "Report 2026-03-10 (ok)"' >/dev/null || fail "publish message"
calls PATCH 'reports/git/refs/heads/main$' | jq -e '.body.force == false and .auth == "Bearer installation-token"' >/dev/null || fail "publish ref"
calls POST access_tokens | jq -e '.body == {permissions: {contents: "write"}, repositories: ["reports"]}' >/dev/null || fail "publish token scope"
if "${hack}/report-publish.sh" 2026-03-09 "${r}" 2>/dev/null; then fail "a report was published under another date"; fi
ok "publish commits the day and the rollup to reports"
mkdir -p "${rep}/data/daily"
cp "${r}" "${rep}/data/daily/"
git -C "${rep}" add data
commit "${rep}" "$(at '+1 day 13:00')" "Report" >/dev/null
git -C "${rep}" push -q "${gitroot}/sealhouse/reports.git" main
: >"${log}"
"${hack}/report-publish.sh" "${day}" --failed >/dev/null
[ -z "$(calls POST /git/trees)" ] || fail "a failure overwrote a good report"
: >"${log}"
"${hack}/report-publish.sh" 2026-03-11 --failed >/dev/null
calls POST /git/blobs | jq -se '.[0].body.content | fromjson | .status == "failed" and .run.url == "https://github.example/runs/77"' >/dev/null ||
  fail "failed marker"
ok "a failed collection is recorded, but never over a good report"

: >"${log}"
REPORT_HEARTBEAT=24 "${hack}/report-publish.sh" "${day}" "${out}/again.json" | grep -q 'unchanged since 2026-03-11T12:30:00Z' || fail "no unchanged note"
[ -z "$(calls POST /git/trees)" ] || fail "an unchanged report was committed"
"${hack}/report-publish.sh" "${day}" "${out}/again.json" >/dev/null
calls POST /git/blobs | jq -se '.[0].body.content | fromjson | .run.collected_at == "2026-03-12T01:00:00Z"' >/dev/null || fail "the heartbeat did not commit"
: >"${log}"
jq '.prs = []' "${out}/again.json" >"${t}/changed.json"
REPORT_HEARTBEAT=24 "${hack}/report-publish.sh" "${day}" "${t}/changed.json" >/dev/null
calls POST /git/blobs | jq -se '.[0].body.content | fromjson | .prs == []' >/dev/null || fail "a changed report was not committed"
: >"${log}"
"${hack}/report-publish.sh" "${day}" "${out}/so-far.json" >/dev/null
calls POST 'reports/git/commits$' | jq -e '.body.message == "Report 2026-03-10 (so far)"' >/dev/null || fail "partial publish message"
ok "an unchanged report is not committed until the heartbeat, a changed one is, and a partial one says so far"

# report-run: today, after yesterday while reports has no final report for it.
: >"${log}"
REPORT_NOW=2026-03-11T05:00:00Z "${hack}/report-run.sh" >/dev/null
[ "$(calls POST /git/trees | jq -c '[.body.tree[].path]')" = '["data/daily/2026-03-11.json","data/rollup.json"]' ] ||
  fail "report-run with a final yesterday: $(calls POST /git/trees | jq -c '[.body.tree[].path]')"
jq '.partial = true' "${r}" >"${rep}/data/daily/${day}.json"
git -C "${rep}" add data
commit "${rep}" "$(at '+1 day 13:00')" "Report" >/dev/null
git -C "${rep}" push -q "${gitroot}/sealhouse/reports.git" main
: >"${log}"
REPORT_NOW=2026-03-11T05:00:00Z "${hack}/report-run.sh" >/dev/null
[ "$(calls POST /git/trees | jq -c '[.body.tree[0].path]')" = '["data/daily/2026-03-10.json"]
["data/daily/2026-03-11.json"]' ] || fail "report-run with a partial yesterday: $(calls POST /git/trees | jq -c '[.body.tree[0].path]')"
: >"${log}"
REPORT_NOW=2026-03-11T05:00:00Z "${hack}/report-run.sh" 2026-03-08 >/dev/null
[ "$(calls POST /git/trees | jq -c '[.body.tree[0].path]')" = '["data/daily/2026-03-08.json"]' ] || fail "report-run with a date"
state '{"fail_paths": ["/reviews"]}'
: >"${log}"
if REPORT_NOW=2026-03-11T05:00:00Z "${hack}/report-run.sh" >/dev/null 2>&1; then fail "report-run passed a failed collection"; fi
calls POST /git/blobs | jq -se 'map(.body.content | fromjson | select(.status == "failed") | .date) == ["2026-03-11"]' >/dev/null ||
  fail "report-run failure markers: $(calls POST /git/blobs | jq -c '.body.content | fromjson | [.date, .status]' 2>/dev/null)"
state '{"fail_paths": []}'
ok "report-run reports today, finishes a partial yesterday first, takes a date, and records a failure without covering a good report"

# The site: assembled from the rollup, and refused when a vendored file was changed.
"${hack}/report-site.sh" "${rep}/data" "${t}/site" 2>/dev/null && fail "a site without a rollup was assembled"
cp "${ru}" "${rep}/data/rollup.json"
"${hack}/report-site.sh" "${rep}/data" "${t}/site"
for f in index.html app.js style.css vendor/chart.umd.min.js data/rollup.json "data/daily/${day}.json"; do
  [ -f "${t}/site/${f}" ] || fail "site lacks ${f}"
done
copy="${t}/ci-copy"
mkdir -p "${copy}/hack"
cp -R "${root}/report" "${copy}/"
cp "${hack}/report-site.sh" "${copy}/hack/"
echo '/* changed */' >>"${copy}/report/site/vendor/chart.umd.min.js"
if "${copy}/hack/report-site.sh" "${rep}/data" "${t}/site2" 2>/dev/null; then fail "a changed vendored file was accepted"; fi
ok "the site assembles from the data, and refuses a vendored file that differs from vendor.lock"

# Freshness, against the site served locally and the reports repo.
cp "${ru}" "${rep}/data/rollup.json"
git -C "${rep}" add data
commit "${rep}" "$(at '+2 days')" "Report" >/dev/null
git -C "${rep}" push -q "${gitroot}/sealhouse/reports.git" main
python3 -m http.server -b 127.0.0.1 -d "${t}/site" 5009 >/dev/null 2>&1 &
http_pid=$!
for _ in $(seq 100); do curl -fs http://127.0.0.1:5009/ >/dev/null && break; sleep 0.1; done
REPORT_FRESH_NOW=2026-03-12T12:00:00Z "${hack}/report-fresh.sh" http://127.0.0.1:5009 >/dev/null || fail "a fresh report was stale"
if REPORT_FRESH_NOW=2026-03-13T02:00:00Z "${hack}/report-fresh.sh" http://127.0.0.1:5009 2>/dev/null; then fail "a 36 hour old report passed"; fi
jq '.days += []' "${ru}" | jq -c . >"${t}/site/data/rollup.json"
if REPORT_FRESH_NOW=2026-03-12T12:00:00Z "${hack}/report-fresh.sh" http://127.0.0.1:5009 2>/dev/null; then fail "a stale deploy passed"; fi
cp "${ru}" "${t}/site/data/rollup.json"
kill "${http_pid}"
ok "freshness fails on an old report and on a site behind reports' main"
[ -z "${REPORT_SITE_OUT:-}" ] || cp -R "${t}/site" "${REPORT_SITE_OUT}"
