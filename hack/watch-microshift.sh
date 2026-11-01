#!/usr/bin/env bash
# Fails when microshift-io publishes a minor newer than images.lock pins.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(grep -E '^MICROSHIFT_[0-9]+_[0-9]+=' "${root}/images.lock" | sort -V | tail -1)"
pinned="$(sed -E 's/^MICROSHIFT_([0-9]+)_([0-9]+)=.*/\1.\2/' <<<"${pin}")"
repo="$(sed -E 's/^[^=]*=([^:@]*).*/\1/' <<<"${pin}")"
# Release tags start with the version (4.22.0_...); the -amd64 and -arm64
# tags are their per-architecture halves.
tags="$(crane ls "${repo}" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+_' | grep -vE -- '-(amd64|arm64)$')"
latest="$(sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/' <<<"${tags}" | sort -uV | tail -1)"
echo "MicroShift: newest pinned ${pinned}, newest in ${repo} ${latest}"
if [ "$(printf '%s\n' "${pinned}" "${latest}" | sort -V | tail -1)" != "${pinned}" ]; then
  echo "${repo} publishes MicroShift ${latest}; pin it as MICROSHIFT_${latest//./_} in images.lock:" >&2
  grep -E "^${latest//./\\.}\." <<<"${tags}" | sed 's/^/  /' >&2
  exit 1
fi
