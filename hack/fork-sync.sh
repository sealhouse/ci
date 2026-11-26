#!/usr/bin/env bash
# fork-sync.sh [--list | --check [--since <commit>] | --merge] <fork-dir>
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
mode=sync
since=
case "${1:-}" in
  --list | --check | --merge) mode="${1#--}"; shift ;;
esac
if [ "${mode}" = check ] && [ "${1:-}" = --since ] && [ $# -ge 2 ]; then
  since="$2"
  shift 2
fi
[ $# -eq 1 ] || { echo "usage: $0 [--list | --check [--since <commit>] | --merge] <fork-dir>" >&2; exit 2; }
fork="$1"

remote="${FORK_UPSTREAM:-upstream}"
upstream_branch="${FORK_UPSTREAM_BRANCH:-}"
if [ -z "${upstream_branch}" ]; then
  upstream_branch="$(git -C "${fork}" symbolic-ref -q --short "refs/remotes/${remote}/HEAD" || true)"
  upstream_branch="${upstream_branch#"${remote}"/}"
  upstream_branch="${upstream_branch:-main}"
fi
dest="${FORK_BRANCH:-rhtas/main}"
staging="${FORK_SYNC_BRANCH:-rhtas/sync}"
upstream_ref="refs/remotes/${remote}/${upstream_branch}"
sync_subject="Merge upstream ${upstream_branch} "
label_re='^UPSTREAM: (<carry>|<drop>|[0-9]+): '
goget_re='^(Go-Get: [^ ]+ [^ @]+@v[0-9]+\.[0-9]+\.[0-9]+|Go-Replaces: replaces\.lock|Ci-Pin: [0-9a-f]{40})$'
pr_re='^UPSTREAM: ([0-9]+): '
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

g() { git -C "${fork}" "$@"; }

# load_carries reads the fork's carries.lock lines, once.
carry_lines="" carries_loaded=""
load_carries() {
  [ -z "${carries_loaded}" ] || return 0
  local name="${FORK_NAME:-}" all
  [ -n "${name}" ] || name="$(basename "$(g remote get-url origin 2>/dev/null || true)" .git)"
  [ -n "${name}" ] || { echo "set FORK_NAME: ${fork} has no origin remote to name the fork by" >&2; return 1; }
  all="$(carries_inventory)" || return 1
  carry_lines="$(awk -v f="${name}" '$1 == f { $1 = ""; print substr($0, 2) }' <<<"${all}")"
  carries_loaded=1
}

# carry_entry PR prints PR's line as "<PR> <carried head> [remove | replaced-by <PR>]", or nothing.
carry_entry() { awk -v p="$1" '$1 == p' <<<"${carry_lines}"; }

# carry_key PR follows replaced-by lines to the PR that carries PR's change now.
carry_key() {
  local pr="$1" entry hops=0
  while entry="$(carry_entry "${pr}")" && [[ "${entry}" == *" replaced-by "* ]]; do
    pr="${entry##* }"
    hops=$((hops + 1))
    [ "${hops}" -lt 10 ] || { echo "carries.lock: replaced-by lines loop at #$1" >&2; return 1; }
  done
  echo "${pr}"
}

# upstream_repo prints the upstream remote as OWNER/REPO.
upstream_repo() {
  local url
  url="$(g remote get-url "${remote}")"
  url="${url%/}"
  url="${url%.git}"
  awk -F'[/:]' '{ print $(NF - 1) "/" $NF }' <<<"${url}"
}

# pr_merge PR prints the commit upstream merged PR as, or nothing while it is unmerged.
pr_merge() {
  local url out
  url="${GITHUB_API_URL:-https://api.github.com}/repos/$(upstream_repo)/pulls/$1"
  if [ -n "${GH_TOKEN:-}" ]; then
    out="$(curl -fsS --retry 3 --config <(printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN}") \
      -H 'Accept: application/vnd.github+json' "${url}")"
  else
    out="$(curl -fsS --retry 3 -H 'Accept: application/vnd.github+json' "${url}")"
  fi || { echo "cannot look up upstream PR #$1 in $(upstream_repo)" >&2; return 1; }
  jq -r 'if .merged then .merge_commit_sha else "" end' <<<"${out}"
}

# The last sync merge on the branch's first-parent line, if any.
last_sync() {
  g log --first-parent --merges --format=%H --grep="^${sync_subject}" -1 "$1"
}

# ci_pin_of COMMIT prints a <drop> carry's Ci-Pin trailer.
ci_pin_of() { g log -1 --format='%(trailers:key=Ci-Pin,valueonly)' "$1" | grep -v '^$' || true; }

# go_gets COMMIT prints a <drop> carry's Go-Get trailers as "<dir> <module>@<version>".
go_gets() {
  g log -1 --format='%(trailers:key=Go-Get,separator=%x0a)' "$1" | sed -n 's/^Go-Get: //p'
}

# carries BRANCH prints the branch's carries, oldest first.
carries() {
  local last base
  last="$(last_sync "$1")"
  if [ -n "${last}" ]; then
    base="${last}"
  else
    base="$(g merge-base "$1" "${upstream_ref}")"
  fi
  g rev-list --reverse --no-merges "${base}..$1"
}

# check_labels COMMIT...
check_labels() {
  local bad=0 c subject
  for c in "$@"; do
    subject="$(g log -1 --format=%s "${c}")"
    if ! grep -qE "${label_re}" <<<"${subject}"; then
      echo "unlabelled carry $(g rev-parse --short "${c}"): ${subject}" >&2
      bad=1
    elif [[ "${subject}" =~ ${pr_re} ]]; then
      load_carries || return 1
      if [ -z "$(carry_entry "${BASH_REMATCH[1]}")" ]; then
        echo "carry $(g rev-parse --short "${c}") for upstream PR #${BASH_REMATCH[1]} has no line in carries.lock: ${subject}" >&2
        bad=1
      fi
    elif [[ "${subject}" == "UPSTREAM: <drop>: "* ]]; then
      local trailers
      trailers="$(g log -1 --format='%(trailers:key=Go-Get,key=Go-Replaces,key=Ci-Pin)' "${c}" | grep -v '^$' || true)"
      if [ -z "${trailers}" ] && g log -1 --format=%b "${c}" | grep -qE '^(Go-Get|Go-Replaces|Ci-Pin): '; then
        echo "<drop> carry $(g rev-parse --short "${c}") has Go-Get, Go-Replaces or Ci-Pin lines outside its message's last paragraph, so git does not read them as trailers: ${subject}" >&2
        bad=1
      elif [ -z "${trailers}" ] || grep -vqE "${goget_re}" <<<"${trailers}"; then
        echo "<drop> carry $(g rev-parse --short "${c}") needs Go-Get: <dir> <module>@vX.Y.Z, Go-Replaces: replaces.lock or Ci-Pin: <commit> trailers to regenerate it: ${subject}" >&2
        bad=1
      fi
    fi
  done
  return "${bad}"
}

case "${mode}" in
  list)
    for c in $(carries "${dest}"); do g log -1 --format='%h %s' "${c}"; done
    exit 0
    ;;
  check)
    if [ -n "${since}" ]; then
      g merge-base --is-ancestor "${since}" "${dest}" ||
        { echo "${dest} does not descend from ${since}; rebase it" >&2; exit 1; }
      # shellcheck disable=SC2046 # commit ids
      check_labels $(g rev-list --reverse --first-parent --no-merges "${since}..${dest}")
      echo "all commits on ${dest} since $(g rev-parse --short "${since}") are labelled"
    else
      # shellcheck disable=SC2046 # commit ids
      check_labels $(carries "${dest}")
      echo "all carries on ${dest} are labelled"
    fi
    exit 0
    ;;
  merge)
    g merge-base --is-ancestor "${dest}" "${staging}" ||
      { echo "${staging} does not descend from ${dest}; run the sync again" >&2; exit 1; }
    if [ "$(g symbolic-ref -q --short HEAD || true)" = "${dest}" ]; then
      g merge -q --ff-only "${staging}"
    else
      g branch -f "${dest}" "${staging}"
    fi
    g branch -q -D "${staging}"
    echo "${dest} is now $(g log -1 --format='%h %s' "${dest}")"
    exit 0
    ;;
esac

g fetch -q "${remote}" "${upstream_branch}"
# Assigned first so a failed listing stops the sync, never drops the carries.
carry_list="$(carries "${dest}")"
# shellcheck disable=SC2206 # commit ids
picks=(${carry_list})
check_labels "${picks[@]}"

tip="$(g rev-parse "${upstream_ref}")"
if [ "$(g symbolic-ref -q --short HEAD || true)" = "${upstream_branch}" ]; then
  g merge -q --ff-only "${tip}"
else
  g fetch -q . "${upstream_ref}:refs/heads/${upstream_branch}"
fi

last="$(last_sync "${dest}")"
old_base="$(if [ -n "${last}" ]; then g rev-parse "${last}^2"; else g merge-base "${dest}" "${tip}"; fi)"
if [ "${old_base}" = "${tip}" ]; then
  echo "${dest} already sits on ${upstream_branch} $(g rev-parse --short "${tip}")"
  exit 0
fi

merge="$(g commit-tree "${tip}^{tree}" -p "${dest}" -p "${tip}" \
  -m "${sync_subject}$(g rev-parse --short "${tip}") into ${dest}")"

work="$(mktemp -d)"
cleanup() {
  local w
  for w in "${work}.repin" "${work}.fold" "${work}"; do
    [ -e "${w}" ] || continue
    g worktree remove --force "${w}" >/dev/null 2>&1 || rm -rf "${w}"
  done
}
trap cleanup EXIT
g worktree add -q --detach "${work}" "${merge}"

# regenerate COMMIT redoes a <drop> carry's Go-Get bumps, Go-Replaces and Ci-Pin.
regenerate() {
  local c="$1" dir modver module want have build cmp
  while read -r dir modver; do
    module="${modver%@*}"
    want="${modver#*@}"
    # A failed go list must stop the sync, never drop a fix.
    if ! build="$(go -C "${work}/${dir}" list -m -f '{{.Path}} {{.Version}}' all 2>&1)"; then
      echo "go list -m all in ${dir} failed on ${upstream_branch} $(g rev-parse --short "${tip}"):" >&2
      echo "${build}" >&2
      return 1
    fi
    have="$(awk -v m="${module}" '$1 == m { print $2 }' <<<"${build}")"
    if [ -z "${have}" ]; then
      echo "  ${dir}: upstream no longer uses ${module}"
      continue
    fi
    cmp="$(go -C "${root}/tools/semver" run . "${have}" "${want}")" || return 1
    if [ "${cmp}" -ge 0 ]; then
      echo "  ${dir}: upstream has ${module} ${have} (carry wants ${want})"
      continue
    fi
    go -C "${work}/${dir}" get "${module}@${want}" >/dev/null 2>&1 &&
      go -C "${work}/${dir}" mod tidy >/dev/null 2>&1 ||
      { echo "go get ${module}@${want} in ${dir} failed on ${upstream_branch} $(g rev-parse --short "${tip}")" >&2; return 1; }
  done < <(go_gets "${c}")
  if g log -1 --format='%(trailers:key=Go-Replaces,valueonly)' "${c}" | grep -qx 'replaces.lock'; then
    "${root}/hack/apply-replaces.sh" "${work}" ||
      { echo "apply-replaces.sh failed on ${upstream_branch} $(g rev-parse --short "${tip}")" >&2; return 1; }
  fi
  git -C "${work}" add -A -- ':(glob)**/go.mod' ':(glob)**/go.sum'
  if [ -n "$(ci_pin_of "${c}")" ]; then
    "${root}/hack/pin-ci.sh" "$(ci_pin_of "${c}")" "${work}"/.github/workflows/sealhouse-*.yaml
    git -C "${work}" add -A -- .github/workflows
  fi
  git -C "${work}" diff --cached --quiet || git -C "${work}" commit -q -C "${c}"
}

# pin_at REV prints the ci commit REV's caller workflows pin, if any.
pin_at() {
  { g grep -h -o -E 'sealhouse/ci/\.github/workflows/[a-z-]+\.yaml@[0-9a-f]{40}' "$1" -- '.github/workflows/sealhouse-*.yaml' || true; } |
    awk -F@ 'NR == 1 { print $2 }'
}

# repin REV PIN pins REV's caller workflows to PIN in the scratch worktree and prints the tree.
repin() {
  local files
  git -C "${work}.repin" checkout -q -f --detach "$1"
  mapfile -t files < <(git -C "${work}.repin" ls-files -- '.github/workflows/sealhouse-*.yaml')
  if [ "${#files[@]}" -gt 0 ]; then
    (cd "${work}.repin" && "${root}/hack/pin-ci.sh" "$2" "${files[@]}")
    git -C "${work}.repin" add -A -- .github/workflows
  fi
  git -C "${work}.repin" write-tree
}

# repinned COMMIT PIN prints a copy of COMMIT whose parent and tree both pin PIN, so a carry written
# against a pin the sync dropped replays only its own change.
repinned() {
  [ -e "${work}.repin" ] || g worktree add -q --detach "${work}.repin" "$1"
  local base
  base="$(g commit-tree "$(repin "$1^" "$2")" -m base)"
  g commit-tree "$(repin "$1" "$2")" -p "${base}" -m "$(g log -1 --format=%B "$1")"
}

# fold COMMIT... prints one commit of COMMITs' changes on the first's parent, with the last's message and author.
fold() {
  local m
  [ -e "${work}.fold" ] || g worktree add -q --detach "${work}.fold" "$1^"
  git -C "${work}.fold" checkout -q -f --detach "$1^"
  for m in "$@"; do
    git -C "${work}.fold" cherry-pick --no-commit "${m}" >/dev/null 2>&1 || {
      git -C "${work}.fold" cherry-pick --abort >/dev/null 2>&1 || git -C "${work}.fold" reset -q --hard
      echo "cannot fold $(g log -1 --format='%h %s' "${m}") onto the carry it replaces" >&2
      return 1
    }
  done
  GIT_AUTHOR_NAME="$(g log -1 --format=%an "${m}")" GIT_AUTHOR_EMAIL="$(g log -1 --format=%ae "${m}")" \
    GIT_AUTHOR_DATE="$(g log -1 --format=%aD "${m}")" \
    g commit-tree "$(git -C "${work}.fold" write-tree)" -p "$1^" -m "$(g log -1 --format=%B "${m}")"
}

# Carries for upstream PRs, grouped by the PR that carries them now: later commits of a group fold into its first.
declare -A pr_of key_of first_of members_of
for c in "${picks[@]}"; do
  [[ "$(g log -1 --format=%s "${c}")" =~ ${pr_re} ]] || continue
  pr_of[${c}]="${BASH_REMATCH[1]}"
  key="$(carry_key "${pr_of[${c}]}")" || exit 1
  key_of[${c}]="${key}"
  [ -n "${first_of[${key}]:-}" ] || first_of[${key}]="${c}"
  members_of[${key}]+=" ${c}"
done
for key in "${!members_of[@]}"; do
  [ -n "$(carry_entry "${key}")" ] || { echo "carries.lock replaces a carry by #${key}, which has no line" >&2; exit 1; }
  for c in ${members_of[${key}]}; do [ "${pr_of[${c}]}" != "${key}" ] || continue 2; done
  [[ "$(carry_entry "${key}")" == *" remove" ]] ||
    { echo "carries.lock replaces a carry by #${key}, but ${dest} has no #${key} carry to replace it with" >&2; exit 1; }
done

# Only the last pin is kept, so pins do not pile up between syncs.
last_pin=""
for c in "${picks[@]}"; do
  if [ -n "$(ci_pin_of "${c}")" ]; then last_pin="${c}"; fi
done

for c in "${picks[@]}"; do
  short="$(g rev-parse --short "${c}")"
  before="$(git -C "${work}" rev-parse HEAD)"
  if g log -1 --format=%s "${c}" | grep -q '^UPSTREAM: <drop>: '; then
    if [ -n "$(ci_pin_of "${c}")" ] && [ "${c}" != "${last_pin}" ]; then
      echo "dropped ${short} $(g log -1 --format=%s "${c}") (a later pin replaces it)"
      continue
    fi
    regenerate "${c}" || exit 1
    if [ "$(git -C "${work}" rev-parse HEAD)" = "${before}" ]; then
      echo "dropped ${short} $(g log -1 --format=%s "${c}") (upstream contains every bump)"
    else
      echo "regenerated ${short} $(g log -1 --format=%s "${c}")"
    fi
    continue
  fi
  pick="${c}" key="${key_of[${c}]:-}" merged="" folded=""
  if [ -n "${key}" ]; then
    if [[ "$(carry_entry "${key}")" == *" remove" ]]; then
      echo "removed ${short} $(g log -1 --format=%s "${c}") (carries.lock)"
      continue
    fi
    if [ "${c}" != "${first_of[${key}]}" ]; then
      echo "folded ${short} $(g log -1 --format=%s "${c}") into $(g rev-parse --short "${first_of[${key}]}")"
      continue
    fi
    read -ra members <<<"${members_of[${key}]}"
    if [ "${#members[@]}" -gt 1 ]; then
      pick="$(fold "${members[@]}")" || exit 1
      folded=" (folded ${#members[@]} commits)"
    fi
    merged="$(pr_merge "${key}")" || exit 1
    # Merged upstream, but not yet in the tip this sync is on: replay it as an open PR.
    [ -z "${merged}" ] || g merge-base --is-ancestor "${merged}" "${tip}" 2>/dev/null || merged=""
  elif [ -n "$(g diff --name-only "${c}^" "${c}" -- '.github/workflows/sealhouse-*.yaml')" ]; then
    was="$(pin_at "${c}^")"
    have="$(pin_at "${before}")"
    if [ -n "${was}" ] && [ -n "${have}" ] && [ "${was}" != "${have}" ]; then pick="$(repinned "${c}" "${have}")"; fi
  fi
  if ! git -C "${work}" cherry-pick --empty=drop "${pick}" >/dev/null 2>&1; then
    # A carry that deletes a file upstream has since changed still deletes it.
    if [ -z "$(git -C "${work}" status --porcelain | grep -E '^(U[^D]|[^U]U|DD|AA)')" ] &&
      [ -n "$(git -C "${work}" status --porcelain | grep '^UD ')" ]; then
      git -C "${work}" status --porcelain | sed -n 's/^UD //p' | xargs git -C "${work}" rm -q --
      git -C "${work}" -c core.editor=true cherry-pick --continue >/dev/null
      [ "${pick}" = "${c}" ] || [ -n "${folded}" ] || git -C "${work}" commit -q --amend --no-edit -C "${c}"
      echo "replayed ${short} $(g log -1 --format=%s "${c}") (kept its deletes over upstream changes)"
      continue
    fi
    if [ -n "${merged}" ]; then
      echo "upstream merged #${key} as $(g rev-parse --short "${merged}"), but ${short} $(g log -1 --format=%s "${pick}") conflicts with it:" >&2
      git -C "${work}" diff --name-only --diff-filter=U >&2
      git -C "${work}" cherry-pick --abort
      echo "replace the carry, or mark #${key} remove in carries.lock" >&2
      exit 1
    fi
    echo "conflict replaying ${short} $(g log -1 --format=%s "${c}"):" >&2
    git -C "${work}" diff --name-only --diff-filter=U >&2
    git -C "${work}" cherry-pick --abort
    echo "fix the carry on ${dest} against ${upstream_branch} $(g rev-parse --short "${tip}") and sync again" >&2
    exit 1
  fi
  if [ "$(git -C "${work}" rev-parse HEAD)" = "${before}" ]; then
    if [ -n "${merged}" ]; then
      echo "dropped ${short} $(g log -1 --format=%s "${pick}") (upstream merged #${key})${folded}"
    else
      echo "dropped ${short} $(g log -1 --format=%s "${c}") (upstream contains it)"
    fi
  elif [ -n "${merged}" ]; then
    echo "upstream merged #${key} as $(g rev-parse --short "${merged}"), but ${short} $(g log -1 --format=%s "${pick}") still changes:" >&2
    git -C "${work}" diff --name-only HEAD^ HEAD >&2
    echo "replace the carry, or mark #${key} remove in carries.lock" >&2
    exit 1
  elif [ -n "${folded}" ]; then
    echo "replayed ${short} $(g log -1 --format=%s "${pick}")${folded}"
  elif [ "${pick}" != "${c}" ]; then
    git -C "${work}" commit -q --amend --no-edit -C "${c}"
    echo "replayed ${short} $(g log -1 --format=%s "${c}") (written against ci ${was:0:12}, replayed against ${have:0:12})"
  else
    echo "replayed ${short} $(g log -1 --format=%s "${c}")"
  fi
done

if [ -n "${carries_loaded}" ]; then
  while read -r pr _; do
    [ -n "${pr}" ] || continue
    for c in "${picks[@]}"; do [ "${pr_of[${c}]:-}" != "${pr}" ] || continue 2; done
    echo "carries.lock lists #${pr}, which ${dest} no longer carries: delete its line"
  done <<<"${carry_lines}"
fi

g branch -f "${staging}" "$(git -C "${work}" rev-parse HEAD)"
echo "upstream ${upstream_branch} $(g rev-parse --short "${old_base}")..$(g rev-parse --short "${tip}"): $(g rev-list --count "${old_base}..${tip}") commits"
echo "${staging} = ${upstream_branch} $(g rev-parse --short "${tip}") + carries:"
g diff --stat "${tip}" "${staging}" | sed 's/^/  /'
echo "test ${staging}, then: $0 --merge ${fork}"
