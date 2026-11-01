# GitHub API helpers. Source, do not execute.

gh_api_url="${GITHUB_API_URL:-https://api.github.com}"
gh_org="${SEALHOUSE_ORG:-sealhouse}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# gh_app_jwt APP_ID KEY prints a ten-minute App JWT.
gh_app_jwt() {
  local now head body sig
  now="$(date +%s)"
  head="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
  body="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$1" | b64url)"
  sig="$(printf '%s.%s' "${head}" "${body}" | openssl dgst -sha256 -sign <(printf '%s\n' "$2") -binary | b64url)"
  printf '%s.%s.%s\n' "${head}" "${body}" "${sig}"
}

# gh_app_token APP_ID KEY PERMISSIONS_JSON REPO... prints a token limited to REPOs and PERMISSIONS_JSON.
gh_app_token() {
  local id="$1" key="$2" perms="$3" jwt installation token
  shift 3
  jwt="$(gh_app_jwt "${id}" "${key}")"
  installation="$(GH_TOKEN="${jwt}" gh_api GET "/orgs/${gh_org}/installation" | jq -r .id)"
  [ -n "${installation}" ] && [ "${installation}" != null ] || { echo "no installation of App ${id} on ${gh_org}" >&2; return 1; }
  token="$(jq -n --argjson p "${perms}" '{permissions: $p, repositories: $ARGS.positional}' --args "$@" |
    GH_TOKEN="${jwt}" gh_api POST "/app/installations/${installation}/access_tokens" - | jq -r .token)"
  [ -n "${token}" ] && [ "${token}" != null ] || { echo "no token from App ${id}" >&2; return 1; }
  [ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::${token}" >&2
  printf '%s\n' "${token}"
}

# gh_api METHOD PATH [BODY | -] uses GH_TOKEN and prints the response.
gh_api() {
  local method="$1" path="$2" body="${3:-}" args=()
  [ -z "${body}" ] || args=(--data-binary "@-")
  if [ "${body}" = - ]; then body="$(cat)"; fi
  printf '%s' "${body}" | curl -fsS --retry 3 -X "${method}" "${args[@]}" \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN}") \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${gh_api_url}${path}"
}

# gh_file REPO PATH prints a file from the default branch, or nothing if it is absent.
gh_file() {
  local out code
  out="$(mktemp)"
  code="$(curl -sS --retry 3 -o "${out}" -w '%{http_code}' \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${GH_TOKEN}") \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${gh_api_url}/repos/$1/contents/$2")"
  case "${code}" in
    200) jq -r .content "${out}" | base64 -d ;;
    404) ;;
    *) echo "GET $1 $2: ${code}" >&2; rm -f "${out}"; return 1 ;;
  esac
  rm -f "${out}"
}

# gh_graphql QUERY ID runs a mutation on one node id.
gh_graphql() {
  local out
  out="$(jq -n --arg q "$1" --arg id "$2" '{query: $q, variables: {id: $id}}' | gh_api POST /graphql -)"
  jq -e '.errors == null' <<<"${out}" >/dev/null || { echo "GraphQL: $(jq -c .errors <<<"${out}")" >&2; return 1; }
}

# gh_commit REPO BRANCH MESSAGE PATH=FILE... commits files on BRANCH's head through the API,
# which GitHub signs, and prints the new commit. It moves no ref.
gh_commit() {
  local repo="$1" branch="$2" message="$3" head tree entries='[]' spec path file blob commit
  shift 3
  head="$(gh_api GET "/repos/${repo}/git/ref/heads/${branch}" | jq -r .object.sha)"
  tree="$(gh_api GET "/repos/${repo}/git/commits/${head}" | jq -r .tree.sha)"
  for spec in "$@"; do
    path="${spec%%=*}"
    file="${spec#*=}"
    blob="$(jq -Rs '{content: ., encoding: "utf-8"}' "${file}" | gh_api POST "/repos/${repo}/git/blobs" - | jq -r .sha)"
    entries="$(jq --arg p "${path}" --arg b "${blob}" '. + [{path: $p, mode: "100644", type: "blob", sha: $b}]' <<<"${entries}")"
  done
  tree="$(jq -n --arg t "${tree}" --argjson e "${entries}" '{base_tree: $t, tree: $e}' |
    gh_api POST "/repos/${repo}/git/trees" - | jq -r .sha)"
  commit="$(jq -n --arg m "${message}" --arg t "${tree}" --arg p "${head}" '{message: $m, tree: $t, parents: [$p]}' |
    gh_api POST "/repos/${repo}/git/commits" - | jq -r .sha)"
  printf '%s\n' "${commit}"
}
