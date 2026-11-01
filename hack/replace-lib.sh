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
removable() {
  local module fork_module version reason drop fork rest subdir want
  while read -r module fork_module version reason drop; do
    fork="${sealhouse}/$(cut -d/ -f3 <<<"${fork_module}")"
    rest="${fork_module#"${org}/$(basename "${fork}")"}"
    subdir="$(sed -E 's#/v([2-9]|[1-9][0-9]+)$##; s#^/##' <<<"${rest}")"
    want="${drop#upstream>=}"
    [ -d "${fork}" ] || { echo "${module}: no fork clone at ${fork}" >&2; continue; }
    if git -C "${fork}" tag --list "$(tag_prefix "${subdir:-.}")v*" | sed "s#^$(tag_prefix "${subdir:-.}")##" |
      grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | while read -r v; do
        [ "$(go -C "${ci_root}/tools/semver" run . "${v}" "${want}")" -ge 0 ] && echo "${v}"
      done | grep -q .; then
      echo "${module}: upstream has released ${want} or newer (${reason}); its replace can go"
    fi
  done < <(replaces_inventory)
}
