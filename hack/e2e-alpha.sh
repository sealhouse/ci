#!/usr/bin/env bash
# e2e-alpha.sh KUBECONFIG CONTEXT TREE runs the e2e suite, upgrade included, against the alpha head.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

kubeconfig="$1" context="$2" tree="$3"
alpha_head_tree "${tree}"
KUBECONFIG="${kubeconfig}" KUBE_CONTEXT="${context}" "${root}/hack/scc-namespace.sh" sealhouse-upgrade
make -C "${tree}" --no-print-directory e2e-run CI_DIR="${root}" \
  E2E_KUBECONFIG="${kubeconfig}" E2E_CONTEXT="${context}" UPGRADE_NAMESPACE=sealhouse-upgrade
