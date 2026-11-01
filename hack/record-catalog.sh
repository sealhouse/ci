#!/usr/bin/env bash
# record-catalog.sh HEAD_ENV_BASE64 records the promoted alpha catalog in pqc-catalog.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/github.sh"

registry="${REGISTRY_HOST:-ghcr.io}"
catalog="${gh_org}/pqc-catalog"
package=secure-sign-pqc-operator
crane_args=()
case "${registry}" in localhost:*) crane_args=(--insecure) ;; esac
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

printf '%s' "$1" | base64 -d >"${work}/head.env"
grep -qvE '^(OPERATOR_IMAGE|BUNDLE_IMAGE|CATALOG_IMAGE|CSV|PREVIOUS_CSV|OPERATOR_COMMIT)=[A-Za-z0-9_./:@-]*$' "${work}/head.env" &&
  { echo "head.env has an unexpected line" >&2; exit 1; }
get() { sed -n "s/^$1=//p" "${work}/head.env"; }
image="$(get CATALOG_IMAGE)" csv="$(get CSV)"
[[ "${image}" =~ ^${registry}/${gh_org}/pqc-catalog@sha256:[0-9a-f]{64}$ ]] || { echo "bad catalog ${image}" >&2; exit 1; }
[[ "${csv}" =~ ^${package}\.v[0-9A-Za-z.-]+$ ]] || { echo "bad CSV ${csv}" >&2; exit 1; }
alpha="$(crane digest "${crane_args[@]}" "${registry}/${gh_org}/pqc-catalog:alpha")"
[ "${image##*@}" = "${alpha}" ] || { echo "pqc-catalog:alpha is ${alpha}, not ${image##*@}" >&2; exit 1; }

crane export "${crane_args[@]}" "${image}" - | tar -xO "configs/${package}/catalog.json" >"${work}/catalog.json"
jq -e -s --arg c "${csv}" 'any(.[]; .schema == "olm.bundle" and .name == $c)' "${work}/catalog.json" >/dev/null ||
  { echo "${image} has no bundle ${csv}" >&2; exit 1; }

GH_TOKEN="$(gh_app_token "${BOT_APP_ID:?}" "${BOT_APP_KEY:?}" '{"contents":"write"}' pqc-catalog)"
export GH_TOKEN
recorded="$(gh_file "${catalog}" alpha/head.env | sed -n 's/^CSV=//p')"
[ "$(get PREVIOUS_CSV)" = "${recorded}" ] ||
  { echo "${csv} replaces $(get PREVIOUS_CSV), but ${catalog} records ${recorded:-no head}" >&2; exit 1; }
new="$(gh_commit "${catalog}" main "alpha: ${csv}" "alpha/catalog.json=${work}/catalog.json" "alpha/head.env=${work}/head.env")"
jq -n --arg s "${new}" '{sha: $s, force: false}' | gh_api PATCH "/repos/${catalog}/git/refs/heads/main" - >/dev/null
echo "pqc-catalog main is ${new}: alpha: ${csv}"
