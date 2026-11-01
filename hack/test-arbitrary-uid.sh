#!/usr/bin/env bash
# Tests the arbitrary-UID policy on the running kind cluster.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
context="${KUBE_CONTEXT:-kind-${KIND_CLUSTER:-sealhouse}}"
k() { kubectl --context "${context}" "$@"; }

suffix="$(date +%s)"
a="uidtest-a-${suffix}" b="uidtest-b-${suffix}" plain="uidtest-plain-${suffix}" missing="uidtest-missing-${suffix}"
trap 'k delete ns "${a}" "${b}" "${plain}" "${missing}" --ignore-not-found --wait=false >/dev/null' EXIT

"${root}/hack/scc-namespace.sh" "${a}" "${b}" >/dev/null
k create ns "${plain}" >/dev/null
k create ns "${missing}" >/dev/null
k label ns "${missing}" sealhouse.dev/scc=restricted >/dev/null

sc() { k -n "$1" run probe --image=localhost:5001/probe:none --restart=Never --dry-run=server -o jsonpath='{.spec.securityContext}'; }

for ns in "${a}" "${b}"; do
  want_uid="$(k -n "${ns}" get cm sealhouse-scc -o jsonpath='{.data.uid}')"
  want_fs="$(k -n "${ns}" get cm sealhouse-scc -o jsonpath='{.data.fsGroup}')"
  got="$(sc "${ns}")"
  want="{\"fsGroup\":${want_fs},\"runAsGroup\":0,\"runAsUser\":${want_uid}}"
  [ "${got}" = "${want}" ] || { echo "FAIL: ${ns} got ${got}, want ${want}" >&2; exit 1; }
  echo "ok: ${ns} ${got}"
done

uid_a="$(k -n "${a}" get cm sealhouse-scc -o jsonpath='{.data.uid}')"
uid_b="$(k -n "${b}" get cm sealhouse-scc -o jsonpath='{.data.uid}')"
[ "${uid_a}" != "${uid_b}" ] || { echo "FAIL: both namespaces got UID ${uid_a}" >&2; exit 1; }

got="$(sc "${plain}")"
[ -z "${got}" ] || [ "${got}" = "{}" ] || { echo "FAIL: unlabelled namespace mutated: ${got}" >&2; exit 1; }
echo "ok: unlabelled namespace not mutated"

if sc "${missing}" >/dev/null 2>&1; then
  echo "FAIL: labelled namespace without sealhouse-scc admitted a pod" >&2
  exit 1
fi
echo "ok: labelled namespace without ConfigMap rejects pods"
