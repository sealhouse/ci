#!/usr/bin/env bash
# scc-namespace.sh NAMESPACE...
set -euo pipefail

context="${KUBE_CONTEXT:-kind-${KIND_CLUSTER:-sealhouse}}"

if kubectl --context "${context}" api-resources --api-group=security.openshift.io -o name | grep -q '^securitycontextconstraints'; then
  for ns in "$@"; do
    kubectl --context "${context}" create namespace "${ns}" --dry-run=client -o yaml \
      | kubectl --context "${context}" apply -f - >/dev/null
    for _ in $(seq 1 30); do
      range="$(kubectl --context "${context}" get namespace "${ns}" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}')"
      [ -n "${range}" ] && break
      sleep 1
    done
    if [ -z "${range}" ]; then
      echo "${ns}: no openshift.io/sa.scc.uid-range assigned" >&2
      exit 1
    fi
    echo "${ns}: SCC uid-range=${range}"
  done
  exit 0
fi

for ns in "$@"; do
  # Block index from the namespace name, so two namespaces in one run differ.
  block=$(( $(printf '%s' "${ns}" | cksum | cut -d' ' -f1) % 100000 ))
  base=$(( 1000000000 + block * 10000 ))
  uid=$(( base + 1 + RANDOM % 9999 ))

  kubectl --context "${context}" create namespace "${ns}" --dry-run=client -o yaml \
    | kubectl --context "${context}" apply -f - >/dev/null
  kubectl --context "${context}" label namespace "${ns}" sealhouse.dev/scc=restricted --overwrite >/dev/null
  kubectl --context "${context}" -n "${ns}" create configmap sealhouse-scc \
    --from-literal=uid="${uid}" --from-literal=fsGroup="${base}" \
    --dry-run=client -o yaml | kubectl --context "${context}" apply -f - >/dev/null
  echo "${ns}: uid=${uid} fsGroup=${base}"
done
