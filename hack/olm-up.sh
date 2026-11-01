#!/usr/bin/env bash
# Installs OLM v0 from olm/ and waits for it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

context="${KUBE_CONTEXT:-kind-${KIND_CLUSTER:-sealhouse}}"
overlay="${OLM_OVERLAY:-${root}/olm}"
k() { kubectl --context "${context}" "$@"; }

(cd "${root}/olm" && grep -E '^[0-9a-f]{64}  ' SOURCE | sha256_check)

# Every rendered image must be a digest, and opm the one images.lock pins.
rendered="$(k kustomize "${overlay}")"
got="$(printf '%s\n' "${rendered}" | grep -oE 'quay\.io/[^ "]+' | sort -u)"
if grep -v '@sha256:' <<<"${got}" >&2; then
  echo "olm images above are not pinned by digest" >&2
  exit 1
fi
opm="$(lock OPM | sed -E 's/:[^:@/]+@/@/')"
if [ "$(grep '/opm@' <<<"${got}")" != "${opm}" ]; then
  echo "olm opm differs from images.lock's ${opm}" >&2
  exit 1
fi

k apply --server-side --force-conflicts -f "${root}/olm/crds.yaml" >/dev/null
k wait --for=condition=Established --timeout=60s -f "${root}/olm/crds.yaml" >/dev/null
# OLM rewrites fields of what it installs, so force conflicts.
printf '%s\n' "${rendered}" | k apply --server-side --force-conflicts -f - >/dev/null

k -n olm rollout status deployment/olm-operator --timeout=180s
k -n olm rollout status deployment/catalog-operator --timeout=180s
# packageserver is installed by OLM itself, from the CSV in olm.yaml.
for _ in $(seq 1 90); do
  phase="$(k -n olm get csv packageserver -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${phase}" = Succeeded ] && break
  sleep 2
done
if [ "${phase}" != Succeeded ]; then
  echo "packageserver CSV is ${phase:-absent}, not Succeeded" >&2
  k -n olm get csv packageserver -o yaml >&2 || true
  exit 1
fi
k get apiservice v1.packages.operators.coreos.com -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -qx True
echo "OLM $(grep '^tag=' "${root}/olm/SOURCE" | cut -d= -f2) ready"
