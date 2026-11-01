#!/usr/bin/env bash
# Installs the pinned Go on a GitHub runner. Local lanes use the host's.
set -euo pipefail

[ -z "${SEALHOUSE_CI:-}" ] || exit 0
root="$(cd "$(dirname "$0")/.." && pwd)"
read -r version sum < <(sed -n 's/^GO=//p' "${root}/tools.lock")
dir="${RUNNER_TEMP:?}/go-${version}"
archive="${dir}.tar.gz"
curl -fsSL --retry 3 -o "${archive}" "https://go.dev/dl/go${version}.linux-amd64.tar.gz"
echo "${sum}  ${archive}" | sha256sum -c --quiet -
mkdir -p "${dir}"
tar -C "${dir}" -xzf "${archive}"
rm -f "${archive}"
{
  echo "${dir}/go/bin"
  echo "$("${dir}/go/bin/go" env GOPATH)/bin"
} >>"${GITHUB_PATH:?}"
echo "GOTOOLCHAIN=local" >>"${GITHUB_ENV:?}"
