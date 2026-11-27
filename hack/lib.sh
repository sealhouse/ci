# Shared helpers. Source, do not execute.

ci_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Never ~/.kube/config.
export KUBECONFIG="${KUBECONFIG:-${ci_root}/.state/kind.kubeconfig}"

# sha256_check verifies "<sha256>  <file>" lines on stdin.
sha256_check() {
  if command -v sha256sum >/dev/null; then
    sha256sum -c --quiet -
  else
    shasum -a 256 -c --quiet -
  fi
}

# lock NAME prints NAME's pin from images.lock.
lock() {
  local value
  value="$(grep -E "^$1=" "${ci_root}/images.lock" | head -1 | cut -d= -f2-)"
  if [ -z "${value}" ]; then
    echo "images.lock has no entry for $1" >&2
    return 1
  fi
  printf '%s\n' "${value}"
}

# start_registry runs the registry on localhost:5001, kind-registry:5000 in kind.
start_registry() {
  local volume=kind-registry-data mounted
  mounted="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/registry"}}{{.Name}}{{end}}{{end}}' kind-registry 2>/dev/null || true)"
  if [ "$(docker inspect -f '{{.State.Running}}' kind-registry 2>/dev/null || true)" = "true" ] && [ "${mounted}" = "${volume}" ]; then
    return
  fi
  docker rm -f kind-registry >/dev/null 2>&1 || true
  docker run -d --restart=always -p 127.0.0.1:5001:5000 \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true -v "${volume}:/var/lib/registry" \
    --network bridge --name kind-registry "$(lock REGISTRY)" >/dev/null
}

# replaces_inventory [FILE] prints replaces.lock's entries, from main by default.
replaces_inventory() {
  local entries ref=main module fork version drop reason
  if [ $# -eq 1 ] || [ -n "${SEALHOUSE_REPLACES:-}" ]; then
    entries="$(grep -vE '^\s*(#|$)' "${1:-${SEALHOUSE_REPLACES}}" || true)"
  else
    git -C "${ci_root}" rev-parse -q --verify refs/heads/main >/dev/null || ref=origin/main
    entries="$(git -C "${ci_root}" show "${ref}:replaces.lock" | grep -vE '^\s*(#|$)' || true)"
  fi
  while read -r module fork version drop reason; do
    [ -n "${module}" ] || continue
    if [ -z "${reason}" ] || [[ "${version}" != v*-rhtas.* ]] || [[ "${fork}" != github.com/sealhouse/* ]] ||
      [[ ! "${drop}" =~ ^(upstream\>=v[0-9]|upstream-pr=[0-9]+$) ]]; then
      echo "replaces.lock: bad line: ${module} ${fork} ${version} ${drop} ${reason}" >&2
      return 1
    fi
  done <<<"${entries}"
  [ -z "${entries}" ] || echo "${entries}"
}

# upstream_pr OWNER/REPO PR prints {state: open|draft|merged|closed, merge_sha, url} for an upstream PR.
upstream_pr() {
  local url="${GITHUB_API_URL:-https://api.github.com}/repos/$1/pulls/$2" out
  if [ -n "${GH_TOKEN:-}" ]; then
    out="$(curl -fsS --retry 3 --config <(printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN}") \
      -H 'Accept: application/vnd.github+json' "${url}")"
  else
    out="$(curl -fsS --retry 3 -H 'Accept: application/vnd.github+json' "${url}")"
  fi || { echo "cannot look up upstream PR #$2 in $1" >&2; return 1; }
  jq -c '{state: (if .merged then "merged" elif .state == "closed" then "closed" elif .draft then "draft" else "open" end),
    merge_sha: (if .merged then .merge_commit_sha else null end), url: .html_url}' <<<"${out}"
}

# carries_inventory [FILE] prints carries.lock's entries, from main by default.
carries_inventory() {
  local entries ref=main fork pr head action target extra
  if [ $# -eq 1 ] || [ -n "${SEALHOUSE_CARRIES:-}" ]; then
    entries="$(grep -vE '^\s*(#|$)' "${1:-${SEALHOUSE_CARRIES}}" || true)"
  else
    git -C "${ci_root}" rev-parse -q --verify refs/heads/main >/dev/null || ref=origin/main
    entries="$(git -C "${ci_root}" show "${ref}:carries.lock" | grep -vE '^\s*(#|$)' || true)"
  fi
  while read -r fork pr head action target extra; do
    [ -n "${fork}" ] || continue
    if [[ ! "${pr}" =~ ^[0-9]+$ || ! "${head}" =~ ^[0-9a-f]{40}$ ]] || [ -n "${extra}" ] ||
      { [ "${action}" != replaced-by ] && [ -n "${target}" ]; } ||
      { [ "${action}" = replaced-by ] && [[ ! "${target}" =~ ^[0-9]+$ ]]; } ||
      [[ ! "${action}" =~ ^(|remove|replaced-by)$ ]]; then
      echo "carries.lock: bad line: ${fork} ${pr} ${head} ${action} ${target} ${extra}" >&2
      return 1
    fi
  done <<<"${entries}"
  [ -z "${entries}" ] || echo "${entries}"
}

# ci_pin CALLER WORKFLOW prints the ci commit CALLER pins WORKFLOW at.
ci_pin() {
  local caller="$1" workflow="$2" ref pinned
  ref="$(sed -nE "s#^ *uses: *sealhouse/ci/\\.github/workflows/${workflow//./\\.}@([0-9a-f]{40}) *(\\#.*)?\$#\\1#p" "${caller}")"
  pinned="$(sed -nE 's#^ *ci-ref: *([0-9a-f]{40}) *(\#.*)?$#\1#p' "${caller}")"
  [ -n "${ref}" ] || { echo "$(basename "${caller}") must use sealhouse/ci/.github/workflows/${workflow}@<40-hex commit>" >&2; return 1; }
  [ "${ref}" = "${pinned}" ] || { echo "$(basename "${caller}") uses ci ${ref} but passes ci-ref ${pinned:-none}" >&2; return 1; }
  git -C "${ci_root}" cat-file -e "${ref}^{commit}" 2>/dev/null || { echo "ci has no commit ${ref}" >&2; return 1; }
  printf '%s\n' "${ref}"
}

# ci_worktree REF prints a ci worktree at REF.
ci_worktree() {
  local worktree="${ci_root}/.state/worktrees/$1"
  if [ ! -d "${worktree}" ]; then
    mkdir -p "$(dirname "${worktree}")"
    git -C "${ci_root}" worktree add -q --detach "${worktree}" "$1"
  fi
  printf '%s\n' "${worktree}"
}

# alpha_head_tree TREE clones the operator into TREE at the alpha head's commit,
# from OPERATOR_REPO and CATALOG_REPO.
alpha_head_tree() {
  local tree="$1" head_env="${CATALOG_REPO:?}/alpha/head.env" commit
  commit="$(sed -n 's/^OPERATOR_COMMIT=//p' "${head_env}")"
  [ -n "${commit}" ] || { echo "${head_env} names no OPERATOR_COMMIT" >&2; return 1; }
  echo "alpha head $(sed -n 's/^CSV=//p' "${head_env}") from operator ${commit:0:12}" >&2
  if ! [ -d "${tree}" ] || [ "$(git -C "${tree}" rev-parse HEAD)" != "${commit}" ]; then
    rm -rf "${tree}"
    git clone -q --no-checkout "${OPERATOR_REPO:?}" "${tree}"
    git -C "${tree}" checkout -q --detach "${commit}"
  fi
  mkdir -p "${tree}/dist"
  cp "${head_env}" "${tree}/dist/alpha.env"
}
