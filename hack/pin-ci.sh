#!/usr/bin/env bash
# pin-ci.sh SHA FILE... pins caller workflows to ci commit SHA.
set -euo pipefail

sha="$1"
shift
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "bad commit ${sha}" >&2; exit 1; }
sed -i -E "s#(sealhouse/ci/\.github/workflows/[a-z-]+\.yaml@)[0-9a-f]{40}#\1${sha}#; s#^( *ci-ref: )[0-9a-f]{40}#\1${sha}#" "$@"
