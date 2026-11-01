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

g() { git -C "${fork}" "$@"; }

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
cleanup() { g worktree remove --force "${work}" >/dev/null 2>&1 || rm -rf "${work}"; }
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
  if ! git -C "${work}" cherry-pick --empty=drop "${c}" >/dev/null 2>&1; then
    echo "conflict replaying ${short} $(g log -1 --format=%s "${c}"):" >&2
    git -C "${work}" diff --name-only --diff-filter=U >&2
    git -C "${work}" cherry-pick --abort
    echo "fix the carry on ${dest} against ${upstream_branch} $(g rev-parse --short "${tip}") and sync again" >&2
    exit 1
  fi
  if [ "$(git -C "${work}" rev-parse HEAD)" = "${before}" ]; then
    echo "dropped ${short} $(g log -1 --format=%s "${c}") (upstream contains it)"
  else
    echo "replayed ${short} $(g log -1 --format=%s "${c}")"
  fi
done

g branch -f "${staging}" "$(git -C "${work}" rev-parse HEAD)"
echo "upstream ${upstream_branch} $(g rev-parse --short "${old_base}")..$(g rev-parse --short "${tip}"): $(g rev-list --count "${old_base}..${tip}") commits"
echo "${staging} = ${upstream_branch} $(g rev-parse --short "${tip}") + carries:"
g diff --stat "${tip}" "${staging}" | sed 's/^/  /'
echo "test ${staging}, then: $0 --merge ${fork}"
