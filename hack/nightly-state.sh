#!/usr/bin/env bash
# nightly-state.sh plan CI_DIR STATE ALPHA_ENV IMAGES NEXT
#   prints e2e=true|false and rebuild=<JSON list of forks> for GITHUB_OUTPUT, and writes NEXT,
#   the state the run records for the jobs that pass. IMAGES holds "<fork> <commit> <digest>" lines.
#   A job runs when its inputs differ from its last green run, when that run is a week old, or with FULL=1.
# nightly-state.sh merge STATE NEXT KEY... prints STATE with the KEY lines taken from NEXT.
# nightly-state.sh record STATE NEXT KEY... commits that to ci's nightly-state branch, with GH_TOKEN.
# STATE holds "<key> <fingerprint> <date>" lines: e2e, and rebuild/<fork> for each fork.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

fingerprint() { printf '%s\n' "$@" | sha256sum | cut -c1-16; }

# due KEY FINGERPRINT says whether KEY runs, and writes its NEXT line.
due() {
  local key="$1" fp="$2" line last_fp="" last_date="" why
  line="$(awk -v k="${key}" '$1 == k' "${state}")"
  [ -z "${line}" ] || read -r _ last_fp last_date <<<"${line}"
  if [ -n "${FULL:-}" ]; then
    why="a full run was asked for"
  elif [ -z "${line}" ]; then
    why="no green run on record"
  elif [ "${last_fp}" != "${fp}" ]; then
    why="its inputs changed since the green run on ${last_date}"
  elif [[ ! "${today}" < "$(date -u -d "${last_date} + 7 days" +%F)" ]]; then
    why="the last green run, on ${last_date}, is a week old"
  else
    echo "${key}: unchanged since the green run on ${last_date}; skipped" >&2
    echo "${line}" >>"${next}"
    return 1
  fi
  echo "${key}: runs, ${why}" >&2
  echo "${key} ${fp} ${today}" >>"${next}"
}

merge() {
  local state="$1" next="$2" keys
  shift 2
  keys=" $* "
  {
    awk -v keys="${keys}" 'index(keys, " " $1 " ") == 0' "${state}"
    awk -v keys="${keys}" 'index(keys, " " $1 " ") > 0' "${next}"
  } | sort
}

case "${1:-}" in
  plan)
    [ $# -eq 6 ] || { echo "usage: $0 plan CI_DIR STATE ALPHA_ENV IMAGES NEXT" >&2; exit 2; }
    ci="$2" state="$3" alpha="$4" images="$5" next="$6"
    today="${TODAY:-$(date -u +%F)}"
    : >"${next}"
    # Everything the nightly runs from ci: its scripts, pins and this workflow.
    ci_fp="$(git -C "${ci}" ls-tree -r HEAD -- hack images.lock tools.lock .github/workflows/sealhouse-nightly.yaml | sha256sum | cut -c1-16)"
    if due e2e "$(fingerprint "${ci_fp}" "$(sha256sum <"${alpha}")")"; then e2e=true; else e2e=false; fi
    rebuild=()
    while read -r fork commit digest; do
      if due "rebuild/${fork}" "$(fingerprint "${ci_fp}" "${commit}" "${digest}")"; then rebuild+=("${fork}"); fi
    done <"${images}"
    echo "e2e=${e2e}"
    echo "rebuild=$(printf '%s\n' "${rebuild[@]}" | jq -Rnc '[inputs | select(. != "")]')"
    ;;
  merge)
    [ $# -ge 3 ] || { echo "usage: $0 merge STATE NEXT KEY..." >&2; exit 2; }
    merge "${@:2}"
    ;;
  record)
    [ $# -ge 3 ] || { echo "usage: $0 record STATE NEXT KEY..." >&2; exit 2; }
    # shellcheck disable=SC1091
    source "${root}/hack/github.sh"
    merged="$(mktemp)"
    trap 'rm -f "${merged}"' EXIT
    merge "${@:2}" >"${merged}"
    if cmp -s "$2" "${merged}"; then
      echo "nightly-state is unchanged"
      exit 0
    fi
    repo="${gh_org}/ci"
    if ! gh_api GET "/repos/${repo}/git/ref/heads/nightly-state" >/dev/null 2>&1; then
      main="$(gh_api GET "/repos/${repo}/git/ref/heads/main" | jq -r .object.sha)"
      jq -n --arg s "${main}" '{ref: "refs/heads/nightly-state", sha: $s}' | gh_api POST "/repos/${repo}/git/refs" - >/dev/null
    fi
    new="$(gh_commit "${repo}" nightly-state "Nightly state: ${*:4}" "nightly-state.env=${merged}")"
    jq -n --arg s "${new}" '{sha: $s, force: false}' | gh_api PATCH "/repos/${repo}/git/refs/heads/nightly-state" - >/dev/null
    echo "recorded ${*:4}"
    ;;
  *)
    echo "usage: $0 plan|merge|record ..." >&2
    exit 2
    ;;
esac
