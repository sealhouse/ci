#!/usr/bin/env bash
# Verifies the Red Hat signature on every Hummingbird image pinned in images.lock.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
key="${root}/keys/redhat-release3.pub"
command -v cosign >/dev/null || {
  echo "cosign is not installed (go install github.com/sigstore/cosign/v3/cmd/cosign@v3.1.4)" >&2
  exit 1
}

grep -E '^HI_[A-Z_]+=' "${root}/images.lock" | while IFS='=' read -r name ref; do
  # cosign verifies by digest; drop the tag so the reference is repo@digest.
  repo="${ref%%@*}"
  repo="${repo%:*}"
  digest="${ref##*@}"
  echo "verifying ${name} ${repo}@${digest}"
  cosign verify --key "${key}" --insecure-ignore-tlog=true "${repo}@${digest}" >/dev/null 2>&1 || {
    echo "signature verification failed for ${name}" >&2
    exit 1
  }
done
echo "all Hummingbird base images verified"
