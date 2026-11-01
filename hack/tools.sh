#!/usr/bin/env bash
# Installs the tools in tools.lock that are missing or differ.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

pin() { grep -E "^$1=" "${root}/tools.lock" | cut -d= -f2-; }

ensure() {
  local name="$1" have="$2" module want
  module="$(pin "$3")"
  want="${module##*@}"
  if [ "${have}" = "${want}" ]; then
    echo "${name} ${have}"
    return
  fi
  echo "${name} ${have:-missing}, installing ${want}" >&2
  go install "${module}"
  command -v "${name}" >/dev/null || { echo "${name} installed to $(go env GOPATH)/bin, which is not on PATH" >&2; exit 1; }
}

ensure cosign "$(cosign version --json 2>/dev/null | jq -r .gitVersion 2>/dev/null || true)" COSIGN
ensure kind "$(kind version 2>/dev/null | awk '{ print $2 }')" KIND
ensure crane "$(crane version 2>/dev/null || true)" CRANE
ensure govulncheck "$(govulncheck -version 2>/dev/null | sed -n 's/^Scanner: govulncheck@//p')" GOVULNCHECK
