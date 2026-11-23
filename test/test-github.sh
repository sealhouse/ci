#!/usr/bin/env bash
# Runs ci's GitHub scripts against real git repos, a real registry and a fake API.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"
hack="${root}/hack"
t="$(mktemp -d)"
api_port=5005 reg_port=5004 reg=test-github-registry
cleanup() {
  [ -z "${api_pid:-}" ] || kill "${api_pid}" 2>/dev/null || true
  docker rm -f "${reg}" >/dev/null 2>&1 || true
  chmod -R u+w "${t}" 2>/dev/null || true
  rm -rf "${t}"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

log="${t}/api.log"
touch "${log}"
python3 "${root}/test/fake-github.py" "${api_port}" "${log}" &
api_pid=$!
export GITHUB_API_URL="http://127.0.0.1:${api_port}"
until curl -fs -X POST -d '{}' "${GITHUB_API_URL}/__state" >/dev/null; do sleep 0.1; done
state() { curl -fs -X POST -d "$1" "${GITHUB_API_URL}/__state" >/dev/null; }
calls() { jq -c --arg m "$1" --arg p "$2" 'select(.method == $m and (.path | test($p)))' "${log}"; }
reset_log() { : >"${log}"; }
expect_fail() { if "$@" >"${t}/out" 2>&1; then fail "expected a refusal: $*"; fi; }

docker rm -f "${reg}" >/dev/null 2>&1 || true
docker run -d --rm -p "127.0.0.1:${reg_port}:5000" --name "${reg}" "$(lock REGISTRY)" >/dev/null
registry="localhost:${reg_port}"
export REGISTRY_HOST="${registry}"
until crane catalog --insecure "${registry}" >/dev/null 2>&1; do sleep 0.2; done
openssl genrsa -out "${t}/key.pem" 2048 2>/dev/null
openssl rsa -in "${t}/key.pem" -pubout -out "${t}/pub.pem" 2>/dev/null
key="$(cat "${t}/key.pem")"
export BOT_APP_ID=11 BOT_APP_KEY="${key}" DISPATCH_APP_ID=22 DISPATCH_APP_KEY="${key}" SYNC_APP_ID=33 SYNC_APP_KEY="${key}"

# request-lane: a token limited to actions on ci, from a JWT the key signed.
"${hack}/request-lane.sh" sealhouse-bump.yaml fork=cosign image=x >/dev/null
jwt="$(calls GET /installation | jq -r .auth | sed 's/^Bearer //')"
printf '%s.%s' "${jwt%%.*}" "$(cut -d. -f2 <<<"${jwt}")" >"${t}/signed"
cut -d. -f3 <<<"${jwt}" | tr -- '-_' '+/' | awk '{ l = length($0) % 4; printf "%s%s", $0, substr("==", 1, l ? 4 - l : 0) }' |
  openssl base64 -d -A >"${t}/sig"
openssl dgst -sha256 -verify "${t}/pub.pem" -signature "${t}/sig" "${t}/signed" >/dev/null || fail "the JWT does not verify"
cut -d. -f2 <<<"${jwt}" | tr -- '-_' '+/' | awk '{ l = length($0) % 4; printf "%s%s", $0, substr("==", 1, l ? 4 - l : 0) }' |
  openssl base64 -d -A | jq -e '.iss == "22"' >/dev/null || fail "the JWT names the wrong App"
calls POST access_tokens | jq -e '.body == {permissions: {actions: "write"}, repositories: ["ci"]}' >/dev/null || fail "dispatch token scope"
calls POST 'sealhouse/ci/actions/workflows/sealhouse-bump.yaml/dispatches' |
  jq -e '.auth == "Bearer installation-token" and .body == {ref: "main", inputs: {fork: "cosign", image: "x"}}' >/dev/null || fail "dispatch"
ok "request-lane signs a JWT, narrows its token and dispatches"

# bump-pr. The registry holds the fork's image under its merge lane's tag, and the fork's commit is
# scanned against a local vulnerability database in which example.com/vulnlib's Bad is fixed in v1.0.1.
export GOVULNDB="file://${t}/vulndb"
mkdir -p "${t}/vulndb/index" "${t}/vulndb/ID"
echo '{"modified": "2026-01-01T00:00:00Z"}' >"${t}/vulndb/index/db.json"
echo '[{"path": "example.com/vulnlib", "vulns": [{"id": "GO-2099-0001", "modified": "2026-01-01T00:00:00Z", "fixed": "1.0.1"}]}]' >"${t}/vulndb/index/modules.json"
jq -n '{schema_version: "1.3.1", id: "GO-2099-0001", modified: "2026-01-01T00:00:00Z", published: "2026-01-01T00:00:00Z", summary: "Bad is bad",
  affected: [{package: {name: "example.com/vulnlib", ecosystem: "Go"}, ranges: [{type: "SEMVER", events: [{introduced: "0"}, {fixed: "1.0.1"}]}],
    ecosystem_specific: {imports: [{path: "example.com/vulnlib", symbols: ["Bad"]}]}}]}' >"${t}/vulndb/ID/GO-2099-0001.json"
gover="$(go env GOVERSION | sed -E 's/^go([0-9]+\.[0-9]+).*/\1/')"
tsa="${t}/tsa-src"
git init -q -b rhtas/main "${tsa}"
printf 'module example.com/tsa\n\ngo %s\n' "${gover}" >"${tsa}/go.mod"
printf 'package tsa\n' >"${tsa}/tsa.go"
git -C "${tsa}" add -A
git -C "${tsa}" -c user.name=test -c user.email=test@test.invalid commit -q -m tsa
mkdir -p "${t}/origin"
git clone -q --bare "${tsa}" "${t}/origin/timestamp-authority.git"
export SEALHOUSE_GIT_BASE="${t}/origin"
: >"${t}/empty"
tar -C "${t}" -cf "${t}/layer.tar" empty
commit="$(git -C "${tsa}" rev-parse HEAD)"
crane append --insecure -f "${t}/layer.tar" -t "${registry}/sealhouse/tsa:rhtas-main-${commit:0:12}" >/dev/null 2>&1
digest="$(crane digest --insecure "${registry}/sealhouse/tsa:rhtas-main-${commit:0:12}")"
image="${registry}/sealhouse/tsa@${digest}"
file=versions/2.0/images.env
state "$(jq -n --arg f "${file}" '{files: {($f): "# Pins.\nTSA_IMAGE=old\nOTHER_IMAGE=keep\n"},
  pulls: [{number: 9, node_id: "PR_old", head: {ref: "bump/2.0-tsa-image-aaaaaaaaaaaa", sha: "d"}},
          {number: 8, node_id: "PR_keep", head: {ref: "bump/2.0-fulcio-image-aaaaaaaaaaaa", sha: "e"}}]}')"
reset_log
"${hack}/bump-pr.sh" timestamp-authority "${commit}" "${image}" rhtas/main >/dev/null
calls POST access_tokens | jq -e '.body == {permissions: {contents: "write", pull_requests: "write", members: "read"}, repositories: ["secure-sign-pqc-operator"]}' >/dev/null || fail "bot token scope"
calls POST /git/blobs | jq -r .body.content | grep -qx "TSA_IMAGE=${image}" || fail "the blob does not pin the image"
calls POST /git/blobs | jq -r .body.content | grep -qx 'OTHER_IMAGE=keep' || fail "the blob lost a pin"
calls POST /git/commits | jq -e --arg s "Bump the 2.0 tsa image to timestamp-authority rhtas/main ${commit:0:12}" \
  '.body.message == $s and (.body | has("author") | not) and (.body | has("committer") | not)' >/dev/null || fail "the commit must be unattributed so GitHub signs it"
calls POST /git/refs | jq -e --arg r "refs/heads/bump/2.0-tsa-image-${commit:0:12}" '.body.ref == $r' >/dev/null || fail "bump branch"
calls POST 'operator/pulls$' | jq -e '.body.base == "main"' >/dev/null || fail "bump PR"
calls PATCH 'pulls/9$' | jq -e '.body.state == "closed"' >/dev/null || fail "stale PR left open"
calls DELETE 'bump/2.0-tsa-image-aaaaaaaaaaaa$' | grep -q . || fail "stale branch left"
[ -z "$(calls PATCH 'pulls/8$')" ] || fail "closed another image's PR"
calls POST /graphql | jq -e '.body.variables.id == "PR_new" and (.body.query | test("mergeMethod: SQUASH"))' >/dev/null || fail "auto-merge"
calls POST 'operator/pulls/[0-9]+/requested_reviewers$' | jq -e '.body == {team_reviewers: ["maintainers"]}' >/dev/null || fail "bump-pr review request"
ok "bump-pr opens one PR, asks the maintainers for a review, closes the stale one and asks for auto-merge"

state "$(jq -n --arg f "${file}" '{files: {($f): "TSA_IMAGE=old\n"}, pulls: [], reviews_refused: true}')"
reset_log
"${hack}/bump-pr.sh" timestamp-authority "${commit}" "${image}" rhtas/main >"${t}/out" 2>&1 || fail "a refused review request stopped bump-pr"
grep -q '::warning::could not request a review from sealhouse/maintainers' "${t}/out" || fail "no warning for a refused review request"
calls POST /graphql | grep -q . || fail "a refused review request skipped auto-merge"
state '{"reviews_refused": false}'
ok "bump-pr warns and carries on when GitHub refuses the review request"

state "$(jq -n --arg f "${file}" '{files: {($f): "TSA_IMAGE=old\n"}, pulls: [], graphql_error: true}')"
expect_fail "${hack}/bump-pr.sh" timestamp-authority "${commit}" "${image}" rhtas/main
state '{"graphql_error": false}'
ok "bump-pr fails when GitHub refuses auto-merge"

bump() { printf '{"number": %s, "node_id": "x", "head": {"ref": "%s", "sha": "%s"}}' "$1" "$2" "$3"; }
green='[{"name": "pr / pr", "status": "completed", "conclusion": "success"}]'
running='[{"name": "pr / pr", "status": "in_progress", "conclusion": null}]'
red='[{"name": "pr / pr", "status": "completed", "conclusion": "failure"}]'
bumps="[$(bump 2 bump/2.0-b-image-bbb sha2), $(bump 1 bump/2.0-a-image-aaa sha1), $(bump 3 feature sha3)]"
behind='{"bump/2.0-a-image-aaa": 2, "bump/2.0-b-image-bbb": 1, "feature": 9}'
update_with() { # CHECKS_BY_SHA BEHIND
  state "{\"pulls\": ${bumps}, \"checks\": [], \"checks_by_sha\": $1, \"behind\": $2}"
  reset_log
  "${hack}/bump-update.sh" >"${t}/out"
}
update_with "{\"sha1\": ${green}, \"sha2\": ${green}, \"sha3\": ${green}}" "${behind}"
calls POST access_tokens | jq -e '.body.permissions.checks == "read"' >/dev/null || fail "bump-update cannot read checks"
calls PUT 'pulls/1/update-branch$' | jq -e '.body.expected_head_sha == "sha1"' >/dev/null || fail "oldest bump PR not updated"
[ "$(calls PUT update-branch | wc -l)" -eq 1 ] || fail "updated more than one PR"
ok "bump-update updates only the oldest bump PR behind main"

update_with "{\"sha1\": ${running}, \"sha2\": ${green}}" '{"bump/2.0-b-image-bbb": 1}'
[ -z "$(calls PUT update-branch)" ] || fail "updated a PR while another runs its checks"
grep -q 'PR 1 .*waiting' "${t}/out" || fail "running checks must wait"
update_with "{\"sha2\": ${green}}" "${behind}"
[ -z "$(calls PUT update-branch)" ] || fail "updated a PR before another's checks started"
handoff_green='[{"name": "pr / pr", "status": "completed", "conclusion": "success"}, {"name": "pr / hand-off", "status": "in_progress", "conclusion": null}]'
update_with "{\"sha1\": ${handoff_green}, \"sha2\": ${green}}" "${behind}"
calls PUT 'pulls/1/update-branch$' | grep -q . || fail "a running hand-off held bump-update"
ok "bump-update waits for a PR whose checks are not finished, but not for the hand-off"

update_with "{\"sha1\": ${red}, \"sha2\": ${green}}" "${behind}"
calls PUT 'pulls/2/update-branch$' | jq -e '.body.expected_head_sha == "sha2"' >/dev/null || fail "a failed PR blocked the next"
[ "$(calls PUT update-branch | wc -l)" -eq 1 ] || fail "updated a failed PR"
grep -q 'PR 1 .*needs a maintainer: pr / pr' "${t}/out" || fail "failed PR not reported"
ok "bump-update skips a failed PR"

update_with "{\"sha1\": ${green}, \"sha2\": ${green}}" '{"bump/2.0-b-image-bbb": 1}'
calls PUT 'pulls/2/update-branch$' | grep -q . || fail "a current green PR blocked the next"
update_with "{\"sha1\": ${green}, \"sha2\": ${green}}" '{}'
[ -z "$(calls PUT update-branch)" ] || fail "updated a current PR"
ok "bump-update passes over current green PRs and leaves them alone"

state "{\"pulls\": [$(bump 4 ci-pin/abc sha4)], \"checks\": [], \"checks_by_sha\": {\"sha4\": ${green}}, \"behind\": {\"ci-pin/abc\": 1}}"
reset_log
"${hack}/bump-update.sh" >/dev/null
calls PUT 'pulls/4/update-branch$' | grep -q . || fail "ci-pin PR not updated"
calls POST access_tokens | jq -e '.body.permissions.workflows == "write"' >/dev/null || fail "main can carry workflow changes"
ok "bump-update also takes ci-pin PRs"

# bot-merge.
p40="$(printf 'd%.0s' {1..40})" o40="$(printf 'e%.0s' {1..40})" x40="$(printf 'f%.0s' {1..40})"
botpr() { printf '{"number": %s, "node_id": "x", "user": {"login": "%s"}, "head": {"ref": "%s", "sha": "%s"}}' "$1" "$3" "$2" "sha$1"; }
signed() { jq -nc --arg m "$1" --arg a "${2:-sealhouse-bot[bot]}" --argjson v "${3:-true}" '[{author: {login: $a}, committer: {login: "web-flow"}, commit: {message: $m, verification: {verified: $v}}}]'; }
pinfile() { # FILE OLD NEW [EXTRA_LINE]
  jq -nc --arg f "$1" --arg o "$2" --arg n "$3" --arg x "${4:-}" '{filename: $f, status: "modified",
    patch: ("@@ -1,4 +1,4 @@\n jobs:\n-    uses: sealhouse/ci/.github/workflows/pr.yaml@\($o)\n+    uses: sealhouse/ci/.github/workflows/pr.yaml@\($n)\n     with:\n-      ci-ref: \($o)\n+      ci-ref: \($n)" + (if $x == "" then "" else "\n+" + $x end))}'
}
pin_msg="UPSTREAM: <drop>: Pin ci ${p40:0:12}

Ci-Pin: ${p40}"
merge_with() { # PULLS EXTRA_STATE
  state "$(jq -nc --argjson p "$1" --argjson g "${green}" --argjson x "${2:-{\}}" '{pulls: $p, checks: $g, checks_by_sha: {}, compare_status: {}, merge_refused: [], pr_commits: {}, pr_files: {}} + $x')"
  reset_log
  "${hack}/bot-merge.sh" app rhtas/main >"${t}/out"
}
good_pin="$(pinfile .github/workflows/sealhouse-pr.yaml "${o40}" "${p40}")"
good_rep='[{"filename": "go.mod", "status": "modified"}, {"filename": "tools/go.sum", "status": "modified"}]'
merge_with "[$(botpr 4 "ci-pin/${p40:0:12}" 'sealhouse-bot[bot]'), $(botpr 6 replaces/abc 'sealhouse-bot[bot]'), $(botpr 7 bump/2.0-tsa-image-abc 'sealhouse-bot[bot]'), $(botpr 8 ci-pin/xyz someone), $(botpr 10 vulns/abc 'sealhouse-bot[bot]')]" \
  "$(jq -nc --argjson pc "$(signed "${pin_msg}")" --argjson rc "$(signed $'UPSTREAM: <drop>: Replace modules\n\nGo-Replaces: replaces.lock')" \
    --argjson vc "$(signed $'UPSTREAM: <drop>: Fix GO-2099-0001\n\nGo-Get: . example.com/vulnlib@v1.0.1')" \
    --argjson pf "[${good_pin}]" --argjson rf "${good_rep}" '{pr_commits: {"4": $pc, "6": $rc, "10": $vc}, pr_files: {"4": $pf, "6": $rf, "10": $rf}}')"
calls POST access_tokens | jq -e '.body == {permissions: {contents: "write", pull_requests: "write", checks: "read", workflows: "write"}, repositories: ["app", "ci"]}' >/dev/null || fail "bot-merge token scope"
calls PUT 'pulls/4/merge$' | jq -e --arg p "${p40}" '.body == {merge_method: "squash", sha: "sha4", commit_title: "UPSTREAM: <drop>: Pin ci \($p[0:12])", commit_message: "Ci-Pin: \($p)"}' >/dev/null || fail "ci-pin merge keeps its trailer"
calls GET "ci/compare/${p40}...main" | grep -q . || fail "the pin was not checked against ci main"
calls PUT 'pulls/6/merge$' | jq -e '.body.commit_message == "Go-Replaces: replaces.lock"' >/dev/null || fail "replaces merge keeps its trailer"
calls PUT 'pulls/10/merge$' | jq -e '.body == {merge_method: "squash", sha: "sha10", commit_title: "UPSTREAM: <drop>: Fix GO-2099-0001", commit_message: "Go-Get: . example.com/vulnlib@v1.0.1"}' >/dev/null ||
  fail "vulns merge keeps its trailer"
[ -z "$(calls PUT 'pulls/(7|8)/merge$')" ] || fail "merged a bump or someone else's PR"
grep -q 'PR 8 (ci-pin/xyz) is not from' "${t}/out" || fail "someone else's PR not reported"
ok "bot-merge squashes green ci-pin, replaces and vulns PRs from the bot, keeping their trailers, and leaves bumps alone"

refused() { # NAME PR_COMMITS PR_FILES [EXTRA_STATE]
  merge_with "[$(botpr 4 "ci-pin/${p40:0:12}" 'sealhouse-bot[bot]')]" \
    "$(jq -nc --argjson c "$2" --argjson f "$3" --argjson x "${4:-{\}}" '{pr_commits: {"4": $c}, pr_files: {"4": $f}} + $x')"
  [ -z "$(calls PUT 'pulls/4/merge$')" ] || fail "merged $1"
}
refused "a commit someone else wrote" "$(signed "${pin_msg}" someone)" "[${good_pin}]"
grep -q 'did not sign' "${t}/out" || fail "a foreign commit not reported"
refused "an unverified commit" "$(signed "${pin_msg}" 'sealhouse-bot[bot]' false)" "[${good_pin}]"
refused "an extra line in a caller" "$(signed "${pin_msg}")" "[$(pinfile .github/workflows/sealhouse-pr.yaml "${o40}" "${p40}" '    run: curl evil')]"
grep -q 'changes more than the pin' "${t}/out" || fail "an extra line not reported"
refused "another workflow" "$(signed "${pin_msg}")" "[${good_pin}, $(pinfile .github/workflows/release.yaml "${o40}" "${p40}")]"
refused "a pin the branch does not name" "$(signed "${pin_msg}")" "[$(pinfile .github/workflows/sealhouse-pr.yaml "${o40}" "${x40}")]"
refused "a pin off ci main" "$(signed "${pin_msg}")" "[${good_pin}]" "{\"compare_status\": {\"${p40}...main\": \"diverged\"}}"
calls GET "ci/compare/${p40}...main" | grep -q . || fail "a pin off ci main was refused before the compare"
refused "a red PR" "$(signed "${pin_msg}")" "[${good_pin}]" "{\"checks\": ${red}}"
grep -q 'PR 4 .*needs a maintainer: pr / pr' "${t}/out" || fail "a red PR not reported"
refused "a PR still running its checks" "$(signed "${pin_msg}")" "[${good_pin}]" "{\"checks\": ${running}}"
grep -q 'waiting for its checks' "${t}/out" || fail "running checks not reported"
merge_with "[$(botpr 6 replaces/abc 'sealhouse-bot[bot]')]" \
  "$(jq -nc --argjson c "$(signed x)" '{pr_commits: {"6": $c}, pr_files: {"6": [{filename: "main.go", status: "modified"}]}}')"
[ -z "$(calls PUT 'pulls/6/merge$')" ] || fail "merged a replaces PR that changes code"
merge_with "[$(botpr 10 vulns/abc 'sealhouse-bot[bot]')]" \
  "$(jq -nc --argjson c "$(signed x)" '{pr_commits: {"10": $c}, pr_files: {"10": [{filename: "go.mod", status: "modified"}, {filename: "main.go", status: "modified"}]}}')"
[ -z "$(calls PUT 'pulls/10/merge$')" ] || fail "merged a vulns PR that changes code"
ok "bot-merge refuses foreign or unsigned commits, changes beyond the pin or go.mod, pins off ci main, and unfinished checks"

merge_with "[$(botpr 4 "ci-pin/${p40:0:12}" 'sealhouse-bot[bot]'), {\"number\": 9, \"user\": {\"login\": \"sealhouse-sync[bot]\"}, \"head\": {\"ref\": \"rhtas/sync\", \"sha\": \"s\"}}]" \
  "$(jq -nc --argjson c "$(signed "${pin_msg}")" --argjson f "[${good_pin}]" '{pr_commits: {"4": $c}, pr_files: {"4": $f}}')"
[ -z "$(calls PUT merge)" ] || fail "merged under an open sync PR"
grep -q 'waiting for the sync PR' "${t}/out" || fail "the sync wait not reported"
merge_with "[$(botpr 4 "ci-pin/${p40:0:12}" 'sealhouse-bot[bot]')]" \
  "$(jq -nc --argjson c "$(signed "${pin_msg}")" --argjson f "[${good_pin}]" '{pr_commits: {"4": $c}, pr_files: {"4": $f}, merge_refused: ["4"]}')"
grep -q 'PR 4 .*could not merge yet' "${t}/out" || fail "a refused merge must wait, not fail"
merge_with "[$(botpr 4 "ci-pin/${p40:0:12}" 'sealhouse-bot[bot]')]" \
  "$(jq -nc --argjson c "$(signed "${pin_msg}")" --argjson f "[${good_pin}]" --argjson g "${green}" \
    '{pr_commits: {"4": $c}, pr_files: {"4": $f}, checks: ($g + [{name: "pr / hand-off", status: "in_progress", conclusion: null}])}')"
calls PUT 'pulls/4/merge$' | grep -q . || fail "the hand-off that asked for the run held the merge"
ok "bot-merge waits for an open sync PR and for a merge GitHub refuses, but not for the hand-off"

# repin
pin="$(printf 'f%.0s' {1..40})"
old="$(printf 'e%.0s' {1..40})"
printf 'app https://example.com/app.git main\n' >"${t}/repin-forks.lock"
caller_yaml="uses: sealhouse/ci/.github/workflows/pr.yaml@${old}\nwith:\n  ci-ref: ${old}\n"
stale_pin='{"number": 5, "node_id": "x", "base": {"ref": "rhtas/main"}, "head": {"ref": "ci-pin/oldoldoldold", "sha": "s"}}'
state "{\"files\": {\".github/workflows/sealhouse-pr.yaml\": \"${caller_yaml}\", \".github/workflows/other.yaml\": \"x\"}, \"pulls\": [${stale_pin}]}"
reset_log
FORKS_LOCK="${t}/repin-forks.lock" "${hack}/repin.sh" "${pin}" >"${t}/out"
calls POST access_tokens | jq -e '.body.permissions.workflows == "write"' >/dev/null || fail "repin cannot change workflows"
calls POST /git/commits | jq -se --arg p "${pin}" --arg s "${pin:0:12}" 'map(.body.message) == ["UPSTREAM: <drop>: Pin ci \($s)\n\nCi-Pin: \($p)", "Pin ci \($s)"]' >/dev/null || fail "repin messages"
calls POST /git/blobs | jq -r .body.content | grep -c "${pin}" | grep -qx 4 || fail "repin blobs"
[ -z "$(calls POST /git/blobs | grep "${old}")" ] || fail "repin left the old pin"
calls POST /git/trees | jq -e '[.body.tree[].path] == [".github/workflows/sealhouse-pr.yaml"]' >/dev/null || fail "repin touched another workflow"
calls GET 'contents/.github/workflows' | grep -q 'ref=rhtas/main' || fail "repin read the wrong branch"
calls POST /graphql | jq -s -e --arg p "${pin}" '.[0].body.query | test("Ci-Pin: " + $p)' >/dev/null || fail "the squash must keep the pin"
calls PATCH 'pulls/5$' | jq -e '.body.state == "closed"' >/dev/null || fail "stale ci-pin PR left open"
reset_log
FORKS_LOCK="${t}/repin-forks.lock" "${hack}/repin.sh" "${pin}" >"${t}/out"
[ -z "$(calls POST /git/commits)" ] || fail "opened the same ci-pin PR twice"
state "{\"files\": {\".github/workflows/sealhouse-pr.yaml\": \"uses: sealhouse/ci/.github/workflows/pr.yaml@${pin}\\n\"}, \"pulls\": []}"
reset_log
FORKS_LOCK="${t}/repin-forks.lock" "${hack}/repin.sh" "${pin}" >"${t}/out"
[ -z "$(calls POST /git/commits)" ] || fail "opened a ci-pin PR on a caller already pinned"
expect_fail "${hack}/repin.sh" nothex
ok "repin opens one PR per caller, keeps the trailer, and closes stale ones"

reset_log
"${hack}/request-lane.sh" sealhouse-bump-update.yaml >/dev/null
calls POST 'sealhouse-bump-update.yaml/dispatches' | jq -e '.body == {ref: "main", inputs: {}}' >/dev/null || fail "dispatch with no inputs"
ok "request-lane dispatches a workflow with no inputs"

state "$(jq -n --arg f "${file}" --arg i "${image}" '{files: {($f): "TSA_IMAGE=\($i)\n"}, pulls: []}')"
reset_log
"${hack}/bump-pr.sh" timestamp-authority "${commit}" "${image}" rhtas/main | grep -q 'already pins' || fail "same pin"
[ -z "$(calls POST /git/commits)" ] || fail "committed a bump with no change"
state "$(jq -n --arg f "${file}" '{files: {($f): "FULCIO_IMAGE=x\n"}}')"
"${hack}/bump-pr.sh" timestamp-authority "${commit}" "${image}" rhtas/main | grep -q 'no TSA_IMAGE' || fail "unknown key"
ok "bump-pr does nothing for a pin it already has or a key the operator lacks"

state "$(jq -n --arg f "${file}" '{files: {($f): "TSA_IMAGE=old\n"}}')"
reset_log
other="sha256:$(printf '0%.0s' {1..64})"
expect_fail "${hack}/bump-pr.sh" not-a-fork "${commit}" "${image}" rhtas/main
expect_fail "${hack}/bump-pr.sh" timestamp-authority nothex "${image}" rhtas/main
expect_fail "${hack}/bump-pr.sh" timestamp-authority "${commit}" "${image}" evil
expect_fail "${hack}/bump-pr.sh" timestamp-authority "${commit}" "evil.example/sealhouse/tsa@${digest}" rhtas/main
expect_fail "${hack}/bump-pr.sh" timestamp-authority "${commit}" "${registry}/sealhouse/tsa@${other}" rhtas/main
[ ! -s "${log}" ] || fail "a refused bump called the API"
ok "bump-pr refuses bad inputs and an image its lane's tag does not name, before minting a token"

# record-catalog: the catalog's content comes from the promoted image.
csv=secure-sign-pqc-operator.v2.0.0-alpha.3
mkdir -p "${t}/image/configs/secure-sign-pqc-operator"
jq -n --arg c "${csv}" '{schema: "olm.bundle", name: $c}' >"${t}/image/configs/secure-sign-pqc-operator/catalog.json"
tar -C "${t}/image" -cf "${t}/catalog.tar" configs
crane append --insecure -f "${t}/catalog.tar" -t "${registry}/sealhouse/pqc-catalog:candidate" >/dev/null 2>&1
catalog="${registry}/sealhouse/pqc-catalog@$(crane digest --insecure "${registry}/sealhouse/pqc-catalog:candidate")"
head_env() { printf 'CATALOG_IMAGE=%s\nCSV=%s\nPREVIOUS_CSV=%s\nOPERATOR_COMMIT=%s\n' "$1" "$2" "${3:-}" "${commit}" | base64 -w0; }
reset_log
expect_fail "${hack}/record-catalog.sh" "$(head_env "${catalog}" "${csv}")"
crane tag --insecure "${catalog}" alpha
expect_fail "${hack}/record-catalog.sh" "$(head_env "${catalog}" secure-sign-pqc-operator.v9.9.9)"
expect_fail "${hack}/record-catalog.sh" "$(printf 'EVIL=1\n' | base64 -w0)"
expect_fail "${hack}/record-catalog.sh" "$(head_env "${registry}/sealhouse/tsa@${digest}" "${csv}")"
[ ! -s "${log}" ] || fail "a refused record called the API"
state '{"files": {}}'
"${hack}/record-catalog.sh" "$(head_env "${catalog}" "${csv}" secure-sign-pqc-operator.v2.0.0-alpha.2)" >"${t}/out" 2>&1 &&
  fail "recorded a head that replaces one the catalog does not have"
state '{"files": {"alpha/head.env": "CSV=secure-sign-pqc-operator.v2.0.0-alpha.1\n"}}'
"${hack}/record-catalog.sh" "$(head_env "${catalog}" "${csv}" secure-sign-pqc-operator.v2.0.0-alpha.2)" >"${t}/out" 2>&1 &&
  fail "recorded a head that skips the recorded one"
[ -z "$(calls POST /git/commits)" ] || fail "a refused record committed"
state '{"files": {"alpha/head.env": "CSV=secure-sign-pqc-operator.v2.0.0-alpha.2\n"}}'
"${hack}/record-catalog.sh" "$(head_env "${catalog}" "${csv}" secure-sign-pqc-operator.v2.0.0-alpha.2)" >/dev/null
[ "$(calls POST /git/blobs | wc -l)" -eq 2 ] || fail "expected catalog.json and head.env"
calls POST /git/trees | jq -e '[.body.tree[].path] == ["alpha/catalog.json", "alpha/head.env"]' >/dev/null || fail "catalog paths"
calls POST /git/commits | jq -e --arg m "alpha: ${csv}" '.body.message == $m and (.body | has("author") | not)' >/dev/null || fail "catalog commit"
calls PATCH 'pqc-catalog/git/refs/heads/main$' | jq -e '.body.force == false' >/dev/null || fail "catalog ref"
ok "record-catalog refuses anything but the promoted alpha, then records it"

# sync-fork, on real repos.
export SEALHOUSE_GIT_BASE="${t}/origin" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test.invalid
up="${t}/upstream"
git init -q -b main "${up}"
printf 'module example.com/app\n\ngo 1.25\n' >"${up}/go.mod"
git -C "${up}" add -A; git -C "${up}" commit -q -m one; git -C "${up}" tag v1.0.0
mkdir -p "${t}/origin"
git clone -q --bare "${up}" "${t}/origin/app.git"
fork="${t}/fork"
git clone -q "${t}/origin/app.git" "${fork}"
git -C "${fork}" switch -q -c rhtas/main
echo carry >"${fork}/CARRY"
git -C "${fork}" add -A
GIT_AUTHOR_NAME=carry-author git -C "${fork}" commit -q -m "UPSTREAM: <carry>: a carry"
git -C "${fork}" push -q origin rhtas/main
state '{"pulls": []}'
reset_log
"${hack}/sync-fork.sh" app "${up}" main | grep -q 'already sits' || fail "no new upstream, no sync"
[ -z "$(calls POST 'pulls$')" ] || fail "opened a PR with nothing to sync"
echo two >"${up}/TWO"
git -C "${up}" add -A; git -C "${up}" commit -q -m two; git -C "${up}" tag v1.1.0
git -C "${up}" switch -q -c side HEAD~1; git -C "${up}" commit -q --allow-empty -m side; git -C "${up}" tag side-only; git -C "${up}" switch -q main
"${hack}/sync-fork.sh" app "${up}" main >/dev/null
o() { git -C "${t}/origin/app.git" "$@"; }
[ "$(o rev-parse main)" = "$(git -C "${up}" rev-parse main)" ] || fail "the mirror did not move"
o rev-parse -q --verify refs/tags/v1.1.0 >/dev/null || fail "the upstream tag was not pushed"
if o rev-parse -q --verify refs/tags/side-only >/dev/null; then fail "pushed a tag off the mirror"; fi
[ "$(o log -1 --format=%s rhtas/sync)" = "UPSTREAM: <carry>: a carry" ] || fail "the carry was not replayed"
[ "$(o log -1 --format=%an rhtas/sync)" = carry-author ] || fail "the carry lost its author"
[ "$(o log -1 --format=%cn rhtas/sync)" = sealhouse-sync ] || fail "the sync committer"
o merge-base --is-ancestor rhtas/main rhtas/sync || fail "rhtas/sync does not descend from rhtas/main"
calls POST 'pulls$' | jq -e '.body.draft == true and .body.head == "rhtas/sync" and .body.base == "rhtas/main"' >/dev/null || fail "draft PR"
[ "$(calls POST 'pulls$' | wc -l)" -eq 1 ] || fail "PR count"
"${hack}/sync-fork.sh" app "${up}" main >/dev/null
[ "$(calls POST 'pulls$' | wc -l)" -eq 1 ] || fail "opened a second sync PR"
git -C "${fork}" switch -q rhtas/main
git -C "${fork}" commit -q --allow-empty -m "not labelled"
git -C "${fork}" push -q origin rhtas/main
sync_before="$(o rev-parse rhtas/sync)"
expect_fail "${hack}/sync-fork.sh" app "${up}" main
grep -q 'unlabelled carry' "${t}/out" || fail "an unlabelled carry must stop the sync"
[ "$(o rev-parse rhtas/sync)" = "${sync_before}" ] || fail "an unlabelled carry moved rhtas/sync"
ok "sync-fork mirrors upstream and its tags, keeps carry authors, and opens one draft PR"

# sync-finish.
sync_pr='{"number": 5, "node_id": "PR_sync", "head": {"ref": "rhtas/sync", "sha": "feed"}}'
guard='{"name": "sync-merge-guard / sync-merge-guard", "status": "completed", "conclusion": "failure"}'
workflows='[{"id": 1, "path": ".github/workflows/sealhouse-pr.yaml", "state": "active"},
  {"id": 2, "path": ".github/workflows/ci.yml", "state": "active"},
  {"id": 3, "path": ".github/workflows/release.yml", "state": "disabled_manually"},
  {"id": 4, "path": "dynamic/dependabot/dependabot-updates", "state": "active"}]'
reset_log
state "{\"pulls\": [], \"workflows\": ${workflows}}"
"${hack}/sync-finish.sh" app >"${t}/out"
grep -q 'no sync PR' "${t}/out" || fail "no PR"
grep -q 'disabled .github/workflows/ci.yml' "${t}/out" || fail "reports the disabled workflow"
[ "$(calls PUT '/actions/workflows/[0-9]+/disable$' | jq -r .path)" = /repos/sealhouse/app/actions/workflows/2/disable ] ||
  fail "disables only the active upstream workflow, even with no sync PR"
state '{"workflows": []}'
state "{\"pulls\": [${sync_pr}], \"checks\": [${guard}]}"
"${hack}/sync-finish.sh" app | grep -q waiting || fail "only the guard reported, so it must wait"
state "{\"checks\": [${guard}, {\"name\": \"pr / pr\", \"status\": \"in_progress\", \"conclusion\": null}]}"
"${hack}/sync-finish.sh" app | grep -q waiting || fail "a running check must wait"
state "{\"checks\": [${guard}, {\"name\": \"pr / pr\", \"status\": \"completed\", \"conclusion\": \"failure\"}]}"
expect_fail "${hack}/sync-finish.sh" app
[ -z "$(calls PATCH refs/heads/rhtas/main)" ] || fail "fast-forwarded a red sync"
handoff='{"name": "sealhouse-pr / pr / hand-off", "status": "in_progress", "conclusion": null}'
state "{\"checks\": [${guard}, ${handoff}, {\"name\": \"pr / pr\", \"status\": \"completed\", \"conclusion\": \"success\"}]}"
"${hack}/sync-finish.sh" app >/dev/null
calls POST /graphql | jq -e '.body.variables.id == "PR_sync" and (.body.query | test("markPullRequestReadyForReview"))' >/dev/null || fail "ready for review"
calls PATCH 'refs/heads/rhtas/main$' | jq -e '.body == {sha: "feed", force: false}' >/dev/null || fail "fast-forward"
calls DELETE 'refs/heads/rhtas/sync$' | grep -q . || fail "branch delete"
ok "sync-finish waits, stops on red, ignores the guard and the hand-off, and fast-forwards a green sync"
# trend-record.
state '{"missing_refs": ["heads/soak-trend"]}'
reset_log
printf 'date\tresult\n' >"${t}/soak-trend.tsv"
GH_TOKEN=job-token "${hack}/soak-record.sh" "${t}/soak-trend.tsv" >/dev/null
calls POST /git/refs | jq -e '.body.ref == "refs/heads/soak-trend" and .auth == null | not' >/dev/null || fail "soak-trend branch"
calls POST /git/trees | jq -e '.body.tree[0].path == "soak-trend.tsv"' >/dev/null || fail "soak trend path"
calls PATCH 'ci/git/refs/heads/soak-trend$' | jq -e '.body.force == false' >/dev/null || fail "soak trend ref"
state '{"missing_refs": []}'
reset_log
GH_TOKEN=job-token "${hack}/trend-record.sh" vuln-trend "${t}/soak-trend.tsv" >/dev/null
[ -z "$(calls POST /git/refs)" ] || fail "an existing trend branch is made again"
calls PATCH 'ci/git/refs/heads/vuln-trend$' | jq -e '.body.force == false' >/dev/null || fail "vuln trend ref"
ok "soak-record and trend-record make their branch when absent and commit the trend"

# Library releases, on real repos and a file proxy.
export GOPROXY="file://${t}/proxy" GONOPROXY=none GOSUMDB=off GOFLAGS= GOWORK=off GOMODCACHE="${t}/modcache" GOTOOLCHAIN=local
publish() {
  local served="$1" ver="$2" mod="$3" dir="${t}/proxy/$1/@v" src="${t}/src/$1@$2"
  mkdir -p "${dir}" "${src}"
  printf 'module %s\n\ngo %s\n' "${mod}" "${gover}" >"${src}/go.mod"
  printf 'package lib\n\nconst Version = "%s"\n' "${ver}" >"${src}/lib.go"
  cp "${src}/go.mod" "${dir}/${ver}.mod"
  printf '{"Version":"%s","Time":"2026-01-01T00:00:00Z"}\n' "${ver}" >"${dir}/${ver}.info"
  (cd "${t}/src" && zip -qr "${dir}/${ver}.zip" "${served}@${ver}")
  echo "${ver}" >>"${dir}/list"
}
publish example.com/lib v1.0.0 example.com/lib
publish github.com/sealhouse/foo v1.2.1-rhtas.1 example.com/lib

repo_from() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$3"
  git clone -q --bare "$1" "${t}/origin/$2.git"
}
foo="${t}/foo-src"
git init -q -b rhtas/main "${foo}"
printf 'module github.com/example-sh/foo\n\ngo %s\n' "${gover}" >"${foo}/go.mod"
printf 'package foo\n' >"${foo}/foo.go"
git -C "${foo}" add -A; git -C "${foo}" commit -q -m base; git -C "${foo}" tag v1.2.0
git clone -q --bare "${foo}" "${t}/origin/foo.git"
consumer="${t}/consumer-src"
git init -q -b rhtas/main "${consumer}"
printf 'module example.com/consumer\n\ngo %s\n' "${gover}" >"${consumer}/go.mod"
printf 'package consumer\n\nimport _ "example.com/lib"\n' >"${consumer}/consumer.go"
go -C "${consumer}" get example.com/lib@v1.0.0 2>/dev/null
go -C "${consumer}" mod tidy 2>/dev/null
repo_from "${consumer}" consumer "UPSTREAM: <carry>: consumer"
op="${t}/operator-src"
git init -q -b main "${op}"
printf 'module example.com/operator\n\ngo %s\n' "${gover}" >"${op}/go.mod"
printf 'package operator\n' >"${op}/operator.go"
repo_from "${op}" secure-sign-pqc-operator operator
cat >"${t}/forks.lock" <<FORKS
# <fork> <upstream url> <upstream branch>
foo https://github.com/example-sh/foo.git main
consumer https://github.com/example-sh/consumer.git main
FORKS
export FORKS_LOCK="${t}/forks.lock" SEALHOUSE_REPLACES="${t}/replaces.lock"
: >"${SEALHOUSE_REPLACES}"

state '{"pulls": [], "files": {"replaces.lock": "# inventory\n"}}'
reset_log
"${hack}/release-library.sh" foo . CVE-2026-1 'upstream>=v1.3.0' >/dev/null
git -C "${t}/origin/foo.git" rev-parse -q --verify refs/tags/v1.2.1-rhtas.1 >/dev/null || fail "the release tag was not pushed"
line='github.com/example-sh/foo github.com/sealhouse/foo v1.2.1-rhtas.1 CVE-2026-1 upstream>=v1.3.0'
calls POST /git/blobs | jq -r .body.content | grep -qxF "${line}" || fail "replaces.lock line"
calls POST /git/blobs | jq -r .body.content | grep -qx '# inventory' || fail "replaces.lock lost a line"
calls POST 'sealhouse/ci/pulls$' | jq -e '.body.base == "main"' >/dev/null || fail "the inventory PR"
calls POST /graphql | grep -q SQUASH || fail "inventory auto-merge"
ok "release-library tags the module and opens the inventory PR"

# --auto releases again only when consumers would see a change.
printf '%s\n' "${line}" >"${SEALHOUSE_REPLACES}"
reset_log
"${hack}/release-library.sh" --auto >/dev/null 2>&1
[ -z "$(calls POST /git/commits)" ] || fail "--auto released an unchanged fork"
git -C "${foo}" fetch -q "${t}/origin/foo.git" --tags
printf 'package foo\n\nconst X = 1\n' >"${foo}/foo.go"
git -C "${foo}" add -A; git -C "${foo}" commit -q -m "UPSTREAM: <carry>: change"
git -C "${foo}" push -q "${t}/origin/foo.git" rhtas/main
"${hack}/release-library.sh" --auto >/dev/null 2>&1
git -C "${t}/origin/foo.git" rev-parse -q --verify refs/tags/v1.2.1-rhtas.2 >/dev/null || fail "--auto did not release the change"
ok "release-library --auto follows real changes only"

# Consumers.
printf 'example.com/lib github.com/sealhouse/foo v1.2.1-rhtas.1 CVE-2026-1 upstream>=v1.3.0\n' >"${SEALHOUSE_REPLACES}"
id="$(sha256sum "${SEALHOUSE_REPLACES}" | cut -c1-12)"
stale='{"number": 3, "node_id": "x", "base": {"ref": "rhtas/main"}, "head": {"ref": "replaces/oldoldoldold", "sha": "s"}}'
state "{\"pulls\": [${stale}]}"
reset_log
"${hack}/replace-consumers.sh" >"${t}/out" 2>&1 || { cat "${t}/out"; fail "replace-consumers"; }
calls POST /git/commits | jq -e '.body.message == "UPSTREAM: <drop>: Replace modules as ci'"'"'s replaces.lock asks\n\nGo-Replaces: replaces.lock"' >/dev/null || fail "the carry's message"
[ "$(calls POST /git/commits | wc -l)" -eq 1 ] || fail "only the consumer uses the module"
calls POST /git/refs | jq -e --arg r "refs/heads/replaces/${id}" '.path | test("consumer") and true' >/dev/null || fail "the branch repo"
calls POST /git/refs | jq -e --arg r "refs/heads/replaces/${id}" '.body.ref == $r' >/dev/null || fail "the branch"
calls POST /git/trees | jq -e '[.body.tree[].path] | index("go.mod") != null' >/dev/null || fail "go.mod"
calls POST 'consumer/pulls$' | jq -e '.body.base == "rhtas/main"' >/dev/null || fail "consumer PR"
calls POST /graphql | jq -e '.body.query | test("Go-Replaces: replaces.lock")' >/dev/null || fail "the squash must keep the trailer"
calls PATCH 'pulls/3$' | jq -e '.body.state == "closed"' >/dev/null || fail "stale replaces PR left open"
reset_log
"${hack}/replace-consumers.sh" >/dev/null 2>&1
[ -z "$(calls POST /git/commits)" ] || fail "opened the same replaces PR twice"
ok "replace-consumers opens one labelled PR per consumer and closes stale ones"

# Vulnerability fixes: example.com/vulnlib v1.0.0's Bad is GO-2099-0001, fixed in v1.0.1.
for v in v1.0.0 v1.0.1; do
  src="${t}/src/example.com/vulnlib@${v}" dir="${t}/proxy/example.com/vulnlib/@v"
  mkdir -p "${src}" "${dir}"
  printf 'module example.com/vulnlib\n\ngo %s\n' "${gover}" >"${src}/go.mod"
  printf 'package vulnlib\n\nfunc Bad() {}\n' >"${src}/vulnlib.go"
  cp "${src}/go.mod" "${dir}/${v}.mod"
  printf '{"Version":"%s","Time":"2026-01-01T00:00:00Z"}\n' "${v}" >"${dir}/${v}.info"
  (cd "${t}/src" && zip -qr "${dir}/${v}.zip" "example.com/vulnlib@${v}")
  echo "${v}" >>"${dir}/list"
done
# released SERVED VERSION AGE_DAYS puts a version in the proxy, released AGE_DAYS ago.
released() {
  local dir="${t}/proxy/$1/@v"
  mkdir -p "${dir}"
  printf 'module %s\n' "$1" >"${dir}/$2.mod"
  printf '{"Version":"%s","Time":"%s"}\n' "$2" "$(date -u -d "$3 days ago" +%Y-%m-%dT%H:%M:%SZ)" >"${dir}/$2.info"
  echo "$2" >>"${dir}/list"
}
# Go's release dates come from its toolchain module.
released golang.org/toolchain v0.0.1-go1.27.4.linux-amd64 30
# vulnerable DIR MODULE writes a module in DIR that reaches Bad.
vulnerable() {
  mkdir -p "$1"
  printf 'module %s\n\ngo %s\n' "$2" "${gover}" >"$1/go.mod"
  printf 'package main\n\nimport "example.com/vulnlib"\n\nfunc main() { vulnlib.Bad() }\n' >"$1/main.go"
  go -C "$1" get example.com/vulnlib@v1.0.0 2>/dev/null
}
vfork="${t}/vfork-src"
git init -q -b rhtas/main "${vfork}"
vulnerable "${vfork}" example.com/vfork
vulnerable "${vfork}/cmd" example.com/vfork/cmd
vulnerable "${vfork}/cmd/testdata/x" example.com/vfork/cmd/testdata
repo_from "${vfork}" vfork "UPSTREAM: <carry>: vfork"
git clone -q -b rhtas/main "${t}/origin/vfork.git" "${t}/vfork-scan"
"${hack}/vulncheck.sh" "${t}/vfork-scan" >"${t}/vfork-summary"
[ "$(grep -c '^fix available: GO-2099-0001 in example.com/vulnlib@v1.0.0, fixed in v1.0.1 ' "${t}/vfork-summary")" -eq 2 ] ||
  fail "vulncheck did not find Bad in both modules: $(cat "${t}/vfork-summary")"
echo 'fix available: GO-2099-0002 in stdlib@v1.27.3, fixed in v1.27.4 (example.com/vfork)' >>"${t}/vfork-summary"
echo 'no fix yet: GO-2099-0003 in example.com/other@v1.0.0 (example.com/vfork)' >>"${t}/vfork-summary"

gets=$'. example.com/vulnlib@v1.0.1\ncmd example.com/vulnlib@v1.0.1'
name="vulns/$(sha256sum <<<"${gets}" | cut -c1-12)"
vpr() { printf '{"number": %s, "node_id": "PR_%s", "base": {"ref": "%s"}, "head": {"ref": "%s", "sha": "s"}}' "$1" "$1" "$2" "$3"; }
state "{\"pulls\": [$(vpr 21 rhtas/main vulns/oldoldoldold), $(vpr 22 rhtas/main replaces/keep)], \"pr_details\": {}}"
reset_log
"${hack}/vuln-fix.sh" vfork rhtas/main "${t}/vfork-summary" >"${t}/out" 2>&1 || { cat "${t}/out"; fail "vuln-fix"; }
message="$(calls POST /git/commits | jq -r .body.message)"
[ "${message}" = $'UPSTREAM: <drop>: Fix GO-2099-0001\n\nGo-Get: . example.com/vulnlib@v1.0.1\nGo-Get: cmd example.com/vulnlib@v1.0.1' ] ||
  fail "the carry's message: ${message}"
[ "$(calls POST /git/commits | wc -l)" -eq 1 ] || fail "one commit for every module fix"
calls POST /git/trees | jq -e '[.body.tree[].path] | sort == ["cmd/go.mod", "cmd/go.sum", "go.mod", "go.sum"]' >/dev/null || fail "the fix changes go.mod and go.sum in both modules"
[ "$(calls POST /git/blobs | jq -r .body.content | grep -c 'example.com/vulnlib v1.0.1$')" -eq 2 ] || fail "go.mod does not require the fixed version"
calls POST 'vfork/git/refs$' | jq -e --arg r "refs/heads/${name}" '.body.ref == $r' >/dev/null || fail "the branch"
calls POST 'vfork/pulls$' | jq -e --arg n "${name}" '.body.base == "rhtas/main" and .body.head == $n and .body.title == "UPSTREAM: <drop>: Fix GO-2099-0001"' >/dev/null || fail "the PR"
calls POST /graphql | jq -e '.body.query | test("commitBody: \"Go-Get: . example.com/vulnlib@v1.0.1\\\\nGo-Get: cmd example.com/vulnlib@v1.0.1\"")' >/dev/null ||
  fail "the squash must keep the trailers"
calls PATCH 'pulls/21$' | jq -e '.body.state == "closed"' >/dev/null || fail "stale vulns PR left open"
calls DELETE 'vulns/oldoldoldold$' | grep -q . || fail "stale vulns branch left"
[ -z "$(calls PATCH 'pulls/22$')" ] || fail "closed a replaces PR"

# The commit, made for real: the sync reads its trailers, and nothing reachable is left.
scan="${t}/vfork-scan"
base="$(git -C "${scan}" rev-parse HEAD)"
for path in go.mod go.sum cmd/go.mod cmd/go.sum; do
  i="$(calls POST /git/trees | jq -r --arg p "${path}" '.body.tree | map(.path) | index($p)')"
  calls POST /git/blobs | jq -rs --argjson i "${i}" '.[$i].body.content' >"${scan}/${path}"
done
printf '%s' "${message}" >"${t}/message"
git -C "${scan}" add -A
git -C "${scan}" commit -q -F "${t}/message"
"${hack}/fork-sync.sh" --check --since "${base}" "${scan}" >/dev/null || fail "the sync refuses the carry"
"${hack}/vulncheck.sh" "${scan}" | grep -qx 'govulncheck: no reachable vulnerabilities' || fail "the fix left Bad reachable"
ok "vuln-fix opens one <drop> carry PR with Go-Get trailers that clears the findings, leaving Go to a person"

state "{\"pulls\": [$(vpr 30 rhtas/main "${name}")], \"pr_details\": {\"30\": {\"mergeable\": true}}, \"checks\": ${running}}"
reset_log
"${hack}/vuln-fix.sh" vfork rhtas/main "${t}/vfork-summary" | grep -q "${name} is open" || fail "an open fix PR"
[ -z "$(calls POST /git/commits)$(calls PATCH 'pulls/30$')" ] || fail "replaced a fix PR that still merges"
state "{\"checks\": ${red}}"
expect_fail "${hack}/vuln-fix.sh" vfork rhtas/main "${t}/vfork-summary"
grep -q "PR 30 (${name}) needs a maintainer: pr / pr" "${t}/out" || fail "a red fix PR not reported"
state "{\"checks\": ${green}}"
state "{\"pulls\": [$(vpr 30 rhtas/main "${name}")], \"pr_details\": {\"30\": {\"mergeable\": false}}}"
reset_log
"${hack}/vuln-fix.sh" vfork rhtas/main "${t}/vfork-summary" >/dev/null
calls PATCH 'pulls/30$' | jq -e '.body.state == "closed"' >/dev/null || fail "a fix PR that no longer merges left open"
[ "$(calls POST 'vfork/pulls$' | wc -l)" -eq 1 ] || fail "no new fix PR for one that no longer merges"
ok "vuln-fix keeps an open fix PR, fails while its checks are red, and opens it again once its base has moved away from it"

grep stdlib "${t}/vfork-summary" >"${t}/go-only"
state "{\"pulls\": [$(vpr 21 rhtas/main vulns/oldoldoldold)]}"
reset_log
"${hack}/vuln-fix.sh" vfork rhtas/main "${t}/go-only" | grep -q 'no module fixes' || fail "Go's own fix"
[ -z "$(calls POST /git/commits)" ] || fail "vuln-fix tried to fix Go"
calls PATCH 'pulls/21$' | jq -e '.body.state == "closed"' >/dev/null || fail "a fix PR with nothing left to fix stayed open"
released example.com/vulnlib v1.0.2-rc.1 30
echo 'fix available: GO-2099-0004 in example.com/vulnlib@v1.0.0, fixed in v1.0.2-rc.1 (example.com/vfork)' >"${t}/odd"
state '{"pulls": []}'
reset_log
expect_fail "${hack}/vuln-fix.sh" vfork rhtas/main "${t}/odd"
grep -q 'not vX.Y.Z: it needs a maintainer' "${t}/out" || fail "a fix the sync cannot regenerate not reported"
[ -z "$(calls POST /git/commits)" ] || fail "committed a fix the sync cannot regenerate"
ok "vuln-fix leaves Go to a person, closes fix PRs with nothing left to fix, and fails on fixes a sync cannot regenerate"

git -C "${op}" rm -q operator.go
vulnerable "${op}" example.com/operator
git -C "${op}" add -A
git -C "${op}" commit -q -m vulnerable
git -C "${op}" push -q "${t}/origin/secure-sign-pqc-operator.git" main
git clone -q "${t}/origin/secure-sign-pqc-operator.git" "${t}/op-scan"
"${hack}/vulncheck.sh" "${t}/op-scan" >"${t}/op-summary"
state '{"pulls": []}'
reset_log
"${hack}/vuln-fix.sh" secure-sign-pqc-operator main "${t}/op-summary" >/dev/null
calls POST /git/commits | jq -e '.body.message == "Fix GO-2099-0001"' >/dev/null || fail "the operator's fix is no carry"
calls POST 'operator/pulls$' | jq -e '.body.base == "main"' >/dev/null || fail "the operator's fix PR"
ok "vuln-fix fixes the operator with a plain commit"

# bump-pr refuses a commit that reaches a vulnerability with a fix.
git -C "${tsa}" rm -q tsa.go
vulnerable "${tsa}" example.com/tsa
git -C "${tsa}" add -A
git -C "${tsa}" commit -q -m vulnerable
git -C "${tsa}" push -q "${t}/origin/timestamp-authority.git" rhtas/main
bad="$(git -C "${tsa}" rev-parse HEAD)"
crane append --insecure -f "${t}/layer.tar" -t "${registry}/sealhouse/tsa:rhtas-main-${bad:0:12}" >/dev/null 2>&1
state "$(jq -n --arg f "${file}" '{files: {($f): "TSA_IMAGE=old\n"}, pulls: []}')"
reset_log
expect_fail "${hack}/bump-pr.sh" timestamp-authority "${bad}" "${registry}/sealhouse/tsa@$(crane digest --insecure "${registry}/sealhouse/tsa:rhtas-main-${bad:0:12}")" rhtas/main
grep -q '^fix available: GO-2099-0001' "${t}/out" || fail "the bump refusal does not name the finding"
grep -q 'there is no bump until they are fixed' "${t}/out" || fail "the bump refusal"
[ -z "$(calls POST /git/commits)" ] || fail "bumped to a vulnerable image"
ok "bump-pr refuses an image whose commit reaches a vulnerability with a fix"

# watch-go: the builder's Go against tools.lock's, and fixes only a newer Go has.
read -r scan_go _ < <(sed -n 's/^GO=//p' "${root}/tools.lock")
newer="$(awk -F. '{ printf "%s.%s.%d", $1, $2, $3 + 1 }' <<<"${scan_go}")"
released golang.org/toolchain "v0.0.1-go${newer}.linux-amd64" 30
# builder GO TAG pushes a builder image and prints it as images.lock pins one.
builder() {
  local ref
  ref="$(crane mutate --insecure --env "GOLANG_VERSION=$1" -t "${registry}/hi/go:$2" "${registry}/sealhouse/tsa:rhtas-main-${commit:0:12}" 2>/dev/null)"
  echo "${registry}/hi/go:$2@${ref#*@}"
}
pinned="$(builder "${scan_go}" 1.27-fips-builder)"
: >"${t}/none"
GO_BUILDER="${pinned}" "${hack}/watch-go.sh" "${t}/none" >/dev/null || fail "watch-go failed with nothing to fix"
GO_BUILDER="$(builder "${newer}" other)" expect_fail "${hack}/watch-go.sh" "${t}/none"
grep -q "builds with Go ${newer}, tools.lock scans with Go ${scan_go}" "${t}/out" || fail "a builder off tools.lock's Go not reported"
printf '%s\n' "app: fix available: GO-2099-0002 in stdlib@v${scan_go}, fixed in v${newer} (example.com/app)" \
  "other: fix available: GO-2099-0002 in stdlib@v${scan_go}, fixed in v${newer} (example.com/other)" >"${t}/go-fix"
GO_BUILDER="${pinned}" expect_fail "${hack}/watch-go.sh" "${t}/go-fix"
grep -q "Go ${newer} fixes vulnerabilities" "${t}/out" && grep -q "GO-2099-0002 (Go ${newer}): app other" "${t}/out" || fail "the Go fix not reported"
grep -q "1.27-fips-builder still has Go ${scan_go}" "${t}/out" || fail "the builder tag without the fix not reported"
floating="$(builder "${newer}" 1.27-fips-builder)"
GO_BUILDER="${pinned}" expect_fail "${hack}/watch-go.sh" "${t}/go-fix"
grep -q "1.27-fips-builder has Go ${newer}: pin it as ${floating#*@}" "${t}/out" || fail "the builder with the fix not offered"
ok "watch-go fails on a fix only a newer Go has, names the builder that has it, and on a builder off tools.lock's Go"

# vuln-due: a fix waits vulns.lock's DAYS from its release, unless vulns.lock names it.
released example.com/young v1.0.1 2
released golang.org/toolchain v0.0.1-go1.99.1.linux-amd64 2
cat >"${t}/due-summary" <<SUMMARY
govulncheck says
fix available: GO-2099-0001 in example.com/vulnlib@v1.0.0, fixed in v1.0.1 (example.com/vfork)
fix available: GO-2099-0005 in example.com/young@v1.0.0, fixed in v1.0.1 (example.com/vfork)
app: fix available: GO-2099-0006 in stdlib@v1.99.0, fixed in v1.99.1 (example.com/app)
no fix yet: GO-2099-0003 in example.com/other@v1.0.0 (example.com/vfork)
SUMMARY
export SEALHOUSE_VULNS="${t}/vulns.lock"
printf '# test\nDAYS=7\n' >"${SEALHOUSE_VULNS}"
"${hack}/vuln-due.sh" "${t}/due-summary" >"${t}/due" 2>"${t}/due.err"
[ "$(cat "${t}/due")" = 'fix available: GO-2099-0001 in example.com/vulnlib@v1.0.0, fixed in v1.0.1 (example.com/vfork)' ] || fail "vuln-due took: $(cat "${t}/due")"
grep -q "^GO-2099-0005: example.com/young v1.0.1 was released $(date -u -d '2 days ago' +%F), ci takes it from $(date -u -d '5 days' +%F)$" "${t}/due.err" ||
  fail "the young fix's wait: $(cat "${t}/due.err")"
grep -q '^GO-2099-0006: stdlib v1.99.1 was released' "${t}/due.err" || fail "a young Go waits from the Go release"
printf 'DAYS=1\n' >"${SEALHOUSE_VULNS}"
[ "$("${hack}/vuln-due.sh" "${t}/due-summary" 2>/dev/null | wc -l)" -eq 3 ] || fail "DAYS=1 did not take the two-day-old fixes"
printf 'DAYS=7\nGO-2099-0005 exploited\nGO-2099-0001 long fixed\n' >"${SEALHOUSE_VULNS}"
"${hack}/vuln-due.sh" "${t}/due-summary" >"${t}/due" 2>"${t}/due.err"
grep -q GO-2099-0005 "${t}/due" || fail "vulns.lock did not take a named fix early"
grep -q '^GO-2099-0001: its fix is over 7 days old, so its line in vulns.lock can go$' "${t}/due.err" || fail "an outdated vulns.lock line not reported"
"${hack}/vuln-due.sh" --rows T app "${t}/due-summary" >"${t}/rows" 2>/dev/null
printf 'T\tapp\t%s\n' $'GO-2099-0001\texample.com/vulnlib\tv1.0.0\tv1.0.1\t2026-01-01' \
  "GO-2099-0005"$'\texample.com/young\tv1.0.0\tv1.0.1\t'"$(date -u -d '2 days ago' +%F)" \
  "GO-2099-0006"$'\tstdlib\tv1.99.0\tv1.99.1\t'"$(date -u -d '5 days' +%F)" $'GO-2099-0003\texample.com/other\tv1.0.0\t\t' |
  cmp - "${t}/rows" || fail "vuln-due rows: $(cat "${t}/rows")"
echo 'govulncheck: no reachable vulnerabilities' >"${t}/clean"
[ "$("${hack}/vuln-due.sh" --rows T sigstore "${t}/clean")" = "$(printf 'T\tsigstore\t\t\t\t\t')" ] || fail "clean row"
: >"${t}/garbled"
expect_fail "${hack}/vuln-due.sh" --rows T sigstore "${t}/garbled"
printf 'DAYS=soon\n' >"${SEALHOUSE_VULNS}"
expect_fail "${hack}/vuln-due.sh" "${t}/due-summary"
printf 'DAYS=7\n' >"${SEALHOUSE_VULNS}"
echo 'fix available: GO-2099-0007 in example.com/unknown@v1.0.0, fixed in v1.0.1 (example.com/vfork)' >"${t}/unknown"
expect_fail "${hack}/vuln-due.sh" "${t}/unknown"
grep -q 'no release time\|example.com/unknown' "${t}/out" || fail "a fix with no release time not reported"
ok "vuln-due holds a fix DAYS from its release, Go's from the Go release, takes what vulns.lock names, and fails on what it cannot date; its trend rows date each fix, give a clean repo one empty row, and refuse an unreadable summary"

grep young "${t}/due-summary" >"${t}/young"
state '{"pulls": []}'
reset_log
"${hack}/vuln-fix.sh" vfork rhtas/main "${t}/young" 2>"${t}/young.err" | grep -q 'no module fixes' || fail "vuln-fix took a fix still baking"
[ -z "$(calls POST /git/commits)" ] || fail "committed a fix still baking"
grep -q 'ci takes it from' "${t}/young.err" || fail "vuln-fix does not say when it takes the fix"
printf 'DAYS=100000\n' >"${SEALHOUSE_VULNS}"
state "$(jq -n --arg f "${file}" '{files: {($f): "TSA_IMAGE=old\n"}, pulls: []}')"
reset_log
"${hack}/bump-pr.sh" timestamp-authority "${bad}" "${registry}/sealhouse/tsa@$(crane digest --insecure "${registry}/sealhouse/tsa:rhtas-main-${bad:0:12}")" rhtas/main >/dev/null 2>&1 ||
  fail "bump-pr refused a vulnerability whose fix is still baking"
calls POST 'operator/pulls$' | grep -q . || fail "no bump while the fix bakes"
GO_BUILDER="${pinned}" "${hack}/watch-go.sh" "${t}/go-fix" >/dev/null 2>&1 || fail "watch-go failed on a Go fix still baking"
printf 'DAYS=7\n' >"${SEALHOUSE_VULNS}"
ok "vuln-fix, bump-pr and watch-go all wait out a fix that is still baking"

echo "test-github: all passed"
