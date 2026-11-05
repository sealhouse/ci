#!/usr/bin/env bash
# tools.sh [TOOL...] installs the tools in tools.lock that are missing or differ, or only TOOLs.
# On linux/amd64 a tool with a _BIN line comes from its release, checked against the pinned sha256; others build with go install.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

pin() { grep -E "^$1=" "${root}/tools.lock" | cut -d= -f2-; }
only=("$@")

# fetch NAME KEY VERSION installs NAME from KEY_BIN's release download, a binary or a tarball holding NAME.
fetch() {
  local name="$1" url sum tmp bin
  read -r url sum <<<"$(pin "$2_BIN")"
  [[ "${url}" == *"/$3/"* ]] || { echo "tools.lock: $2_BIN is not $3" >&2; exit 1; }
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "${tmp}/download" "${url}"
  echo "${sum}  ${tmp}/download" | sha256sum -c --quiet -
  case "${url}" in
    *.tar.gz) tar -C "${tmp}" -xzf "${tmp}/download" "${name}" ;;
    *) mv "${tmp}/download" "${tmp}/${name}" ;;
  esac
  bin="$(go env GOPATH)/bin"
  mkdir -p "${bin}"
  install -m 0755 "${tmp}/${name}" "${bin}/${name}"
  rm -rf "${tmp}"
}

ensure() {
  local name="$1" have="$2" module want
  if [ "${#only[@]}" -gt 0 ] && [[ " ${only[*]} " != *" ${name} "* ]]; then return; fi
  module="$(pin "$3")"
  want="${module##*@}"
  # Release builds print their version without the v.
  if [ "${have#v}" = "${want#v}" ]; then
    echo "${name} ${have}"
    return
  fi
  echo "${name} ${have:-missing}, installing ${want}" >&2
  if [ -n "$(pin "$3_BIN")" ] && [ "$(uname -sm)" = "Linux x86_64" ]; then
    fetch "${name}" "$3" "${want}"
  else
    go install "${module}"
  fi
  command -v "${name}" >/dev/null || { echo "${name} installed to $(go env GOPATH)/bin, which is not on PATH" >&2; exit 1; }
}

for name in "${only[@]}"; do
  case "${name}" in cosign | kind | crane | govulncheck) ;; *) echo "tools.lock has no ${name}" >&2; exit 1 ;; esac
done
ensure cosign "$(cosign version --json 2>/dev/null | jq -r .gitVersion 2>/dev/null || true)" COSIGN
ensure kind "$(kind version 2>/dev/null | awk '{ print $2 }')" KIND
ensure crane "$(crane version 2>/dev/null || true)" CRANE
ensure govulncheck "$(govulncheck -version 2>/dev/null | sed -n 's/^Scanner: govulncheck@//p')" GOVULNCHECK
