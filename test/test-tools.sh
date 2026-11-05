#!/usr/bin/env bash
# test-tools.sh
set -euo pipefail

ci_root="$(cd "$(dirname "$0")/.." && pwd)"
t="$(mktemp -d)"
server=""
trap '[ -z "${server}" ] || kill "${server}"; rm -rf "${t}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
[ "$(uname -sm)" = "Linux x86_64" ] || { echo "test-tools: release downloads are linux/amd64 only; skipped"; exit 0; }

# Releases: fake binaries that print the versions tools.sh asks for, served over HTTP.
fake() { # NAME OUTPUT
  printf '#!/bin/sh\necho %q\n' "$2" >"${t}/$1"
  chmod +x "${t}/$1"
}
rel="${t}/releases"
mkdir -p "${rel}/kind/v0.33.0" "${rel}/cosign/v3.1.4" "${rel}/ggcr/v0.22.1" "${t}/pkg"
fake kind 'kind v0.33.0 go1.27.3 linux/amd64'
fake cosign '{"gitVersion":"v3.1.4"}'
fake crane '0.22.1'
cp "${t}/kind" "${rel}/kind/v0.33.0/kind-linux-amd64"
cp "${t}/cosign" "${rel}/cosign/v3.1.4/cosign-linux-amd64"
cp "${t}/crane" "${t}/pkg/crane"
cp "${t}/crane" "${t}/pkg/gcrane"
tar -C "${t}/pkg" -czf "${rel}/ggcr/v0.22.1/ggcr_Linux_x86_64.tar.gz" crane gcrane
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server -b 127.0.0.1 -d "${rel}" "${port}" >/dev/null 2>&1 &
server=$!
for _ in $(seq 50); do curl -fs "http://127.0.0.1:${port}/" >/dev/null && break; sleep 0.1; done

# A ci tree whose tools.lock points at the fake releases.
root="${t}/ci"
mkdir -p "${root}/hack"
cp "${ci_root}/hack/tools.sh" "${root}/hack/"
sum() { sha256sum "${rel}/$1" | cut -d' ' -f1; }
lock() { # KIND_SUM
  cat >"${root}/tools.lock" <<EOF
KIND=sigs.k8s.io/kind@v0.33.0
KIND_BIN=http://127.0.0.1:${port}/kind/v0.33.0/kind-linux-amd64 ${1:-$(sum kind/v0.33.0/kind-linux-amd64)}
COSIGN=github.com/sigstore/cosign/v3/cmd/cosign@v3.1.4
COSIGN_BIN=http://127.0.0.1:${port}/cosign/v3.1.4/cosign-linux-amd64 $(sum cosign/v3.1.4/cosign-linux-amd64)
CRANE=github.com/google/go-containerregistry/cmd/crane@v0.22.1
CRANE_BIN=http://127.0.0.1:${port}/ggcr/v0.22.1/ggcr_Linux_x86_64.tar.gz $(sum ggcr/v0.22.1/ggcr_Linux_x86_64.tar.gz)
GOVULNCHECK=golang.org/x/vuln/cmd/govulncheck@v1.9.0
EOF
}

# govulncheck has no release binaries; it is already installed, so nothing builds.
mkdir -p "${t}/have"
fake govulncheck 'Scanner: govulncheck@v1.9.0'
mv "${t}/govulncheck" "${t}/have/"
export GOPATH="${t}/gopath"
export PATH="${GOPATH}/bin:${t}/have:$(dirname "$(command -v go)"):/usr/bin:/bin"
tools() { "${root}/hack/tools.sh" "$@" >"${t}/out" 2>&1; }

lock
tools crane || fail "crane alone: $(cat "${t}/out")"
[ -x "${GOPATH}/bin/crane" ] || fail "crane not installed"
[ ! -e "${GOPATH}/bin/gcrane" ] || fail "installed more of the tarball than crane"
[ ! -e "${GOPATH}/bin/kind" ] && [ ! -e "${GOPATH}/bin/cosign" ] || fail "installed tools it was not asked for"
ok "tools.sh installs only the tools it is asked for, and only that binary from a tarball"

tools || fail "all: $(cat "${t}/out")"
for name in kind cosign crane; do [ -x "${GOPATH}/bin/${name}" ] || fail "${name} not installed"; done
tools || fail "again: $(cat "${t}/out")"
grep -q installing "${t}/out" && fail "reinstalled a current tool: $(cat "${t}/out")"
grep -qx 'crane 0.22.1' "${t}/out" || fail "a release's version without the v must count as current"
ok "tools.sh fetches the pinned releases, and leaves current tools alone"

rm -f "${GOPATH}/bin/kind"
lock "$(printf '0%.0s' {1..64})"
if tools kind; then fail "installed a download whose sha256 does not match"; fi
[ ! -e "${GOPATH}/bin/kind" ] || fail "kept a download whose sha256 does not match"
sed -i 's#/kind/v0.33.0/#/kind/v0.32.0/#' "${root}/tools.lock"
if tools kind; then fail "used a release URL for another version"; fi
grep -q 'KIND_BIN is not v0.33.0' "${t}/out" || fail "the version mismatch not reported: $(cat "${t}/out")"
if tools helm; then fail "accepted a tool tools.lock does not have"; fi
ok "tools.sh refuses a bad sha256, a release of another version and an unknown tool"
