# Library release helpers. Source, do not execute. Callers set org, branch and sealhouse.

# dir_prefix SUBDIR prints SUBDIR as a path prefix: "" for ".", else "SUBDIR/".
dir_prefix() {
  local d="${1#.}"
  d="${d#/}"
  echo "${d:+${d%/}/}"
}

# module_of FORK SUBDIR prints the upstream module path SUBDIR's go.mod on
# rhtas/main declares.
module_of() {
  git -C "$1" show "${branch}:$(dir_prefix "$2")go.mod" 2>/dev/null | awk '$1 == "module" { print $2; exit }'
}

# tag_prefix SUBDIR prints the tag prefix for a module in SUBDIR.
tag_prefix() { dir_prefix "$1"; }

# release FORK SUBDIR tags SUBDIR's module on rhtas/main and prints
# "<module> <fork module> <version>".
release() {
  local fork="$1" subdir="$2" module upstream_repo rest major prefix base next n tag log
  module="$(module_of "${fork}" "${subdir}")"
  [ -n "${module}" ] || { echo "${fork##*/}: no go.mod in ${subdir} on ${branch}" >&2; return 1; }
  upstream_repo="$(git -C "${fork}" remote get-url upstream | sed -E 's#^https://##; s#\.git$##')"
  rest="${module#"${upstream_repo}"}"
  [ "${rest}" != "${module}" ] || { echo "${module} is not under ${upstream_repo}" >&2; return 1; }
  major="$(sed -nE 's#.*/v([2-9]|[1-9][0-9]+)$#\1#p' <<<"${module}")"
  prefix="$(tag_prefix "${subdir}")"
  # The newest upstream release of this module (its major) rhtas/main holds.
  base="$(git -C "${fork}" tag --merged "${branch}" --list "${prefix}v*" |
    sed -n "s#^${prefix}\(v[0-9]*\.[0-9]*\.[0-9]*\)\$#\1#p" |
    grep -E "^v${major:-[01]}\." | sort -V | tail -1 || true)"
  [ -n "${base}" ] || { echo "${fork##*/}: no upstream ${prefix}v${major:-0|1}.x.y release on ${branch}" >&2; return 1; }
  next="$(awk -F. '{ printf "%s.%s.%d", $1, $2, $3 + 1 }' <<<"${base}")"
  tag="$(git -C "${fork}" tag --points-at "${branch}" --list "${prefix}${next}-rhtas.*" | sort -V | tail -1)"
  if [ -z "${tag}" ]; then
    n="$(git -C "${fork}" tag --list "${prefix}${next}-rhtas.*" | sed -n 's/.*-rhtas\.\([0-9]*\)$/\1/p' | sort -n | tail -1)"
    log="$(git -C "${fork}" rev-parse --path-format=absolute --git-common-dir)/sealhouse/released"
    n="$( (sed -n "s#^${prefix}${next}-rhtas\.\([0-9]*\) .*#\1#p" "${log}" 2>/dev/null; echo "${n:-0}") | sort -n | tail -1)"
    tag="${prefix}${next}-rhtas.$((n + 1))"
    git -C "${fork}" tag "${tag}" "${branch}"
    mkdir -p "$(dirname "${log}")"
    echo "${tag} $(git -C "${fork}" rev-parse "${branch}") $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${log}"
    echo "${fork##*/}: tagged ${tag} on ${branch} $(git -C "${fork}" rev-parse --short "${branch}")" >&2
  fi
  echo "${module} ${org}/$(basename "${fork}")${rest} ${tag##*/}"
}

# changed FORK SUBDIR TAG says whether SUBDIR's module on rhtas/main differs
# from TAG in anything a consumer builds with.
changed() {
  local fork="$1" subdir="$2" tag="$3" dir f nested=()
  dir="$(dir_prefix "${subdir}")"
  # Modules nested below this one are theirs, not its.
  while read -r f; do
    [ "${f}" = "${dir}go.mod" ] || nested+=(":(exclude)$(dirname "${f}")")
  done < <(git -C "${fork}" ls-tree -r --name-only "${branch}" -- "${dir:-.}" | grep -E '(^|/)go\.mod$')
  while read -r f; do
    case "${f}" in
      "${dir}go.sum") ;;
      "${dir}go.mod")
        [ "$(git -C "${fork}" show "${tag}:${f}" | go mod edit -json /dev/stdin | jq -c '[.Go, .Require]')" = \
          "$(git -C "${fork}" show "${branch}:${f}" | go mod edit -json /dev/stdin | jq -c '[.Go, .Require]')" ] || return 0 ;;
      *) return 0 ;;
    esac
  done < <(git -C "${fork}" diff --name-only "${tag}" "${branch}" -- "${dir:-.}" ":(exclude).github" ":(exclude).sealhouse" "${nested[@]}")
  return 1
}

# removable prints the inventory lines upstream has released the fix for.
# fork_subdir FORK_MODULE prints the fork's subdirectory that holds FORK_MODULE, "." for the root.
fork_subdir() {
  local f rest
  f="$(cut -d/ -f3 <<<"$1")"
  rest="${1#"github.com/$(cut -d/ -f2 <<<"$1")/${f}"}"
  rest="$(sed -E 's#/v([2-9]|[1-9][0-9]+)$##; s#^/##' <<<"${rest}")"
  echo "${rest:-.}"
}

# drop_state FORK SUBDIR DROP SLUG prints how far upstream SLUG is with a replaces.lock drop condition, as
# {kind: "pr", number, state, url, released} or {kind: "version", want, released}; released is the first
# upstream release, a plain vX.Y.Z tag in FORK, that meets it, or null.
drop_state() {
  local fork="$1" prefix pr got merged want released=""
  prefix="$(tag_prefix "$2")"
  case "$3" in
    upstream-pr=*)
      pr="${3#upstream-pr=}"
      got="$(upstream_pr "$4" "${pr}")" || got='{"state": "unknown", "merge_sha": null, "url": null}'
      merged="$(jq -r '.merge_sha // empty' <<<"${got}")"
      [ -z "${merged}" ] || released="$(git -C "${fork}" tag --contains "${merged}" --list "${prefix}v*" 2>/dev/null |
        sed "s#^${prefix}##" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | head -1 || true)"
      jq -c --arg n "${pr}" --arg slug "$4" --arg r "${released}" '{kind: "pr", number: ($n | tonumber), state,
        url: (.url // "https://github.com/\($slug)/pull/\($n)"), released: (if $r == "" then null else $r end)}' <<<"${got}"
      ;;
    *)
      want="${3#upstream>=}"
      released="$(git -C "${fork}" tag --list "${prefix}v*" | sed "s#^${prefix}##" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V |
        while read -r v; do
          [ "$(go -C "${ci_root}/tools/semver" run . "${v}" "${want}")" -lt 0 ] || { echo "${v}"; break; }
        done || true)"
      jq -nc --arg w "${want}" --arg r "${released}" '{kind: "version", want: $w, released: (if $r == "" then null else $r end)}'
      ;;
  esac
}

removable() {
  local module fork_module version drop reason fork slug st released
  while read -r module fork_module version drop reason; do
    fork="${sealhouse}/$(cut -d/ -f3 <<<"${fork_module}")"
    [ -d "${fork}" ] || { echo "${module}: no fork clone at ${fork}" >&2; continue; }
    slug="$(git -C "${fork}" remote get-url upstream | sed -E 's#/$##; s#\.git$##' | awk -F'[/:]' '{ print $(NF - 1) "/" $NF }')"
    st="$(drop_state "${fork}" "$(fork_subdir "${fork_module}")" "${drop}" "${slug}")"
    released="$(jq -r '.released // empty' <<<"${st}")"
    [ -n "${released}" ] || continue
    case "${drop}" in
      upstream-pr=*) echo "${module}: upstream released #${drop#upstream-pr=} in ${released} (${reason}); its replace can go" ;;
      *) echo "${module}: upstream has released ${drop#upstream>=} or newer (${reason}); its replace can go" ;;
    esac
  done < <(replaces_inventory)
}
