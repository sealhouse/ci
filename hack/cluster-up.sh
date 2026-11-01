#!/usr/bin/env bash
# Creates the kind cluster and its local registry. KIND_VERSION picks a minor.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

version="${KIND_VERSION:-}"
node_image="$(lock "KIND_NODE${version:+_${version//./_}}")"
cluster="${KIND_CLUSTER:-sealhouse${version:+-${version//./-}}}"
case "${version}" in
  "") map_api="" ;;
  1.33) map_api=v1alpha1 ;;
  1.34 | 1.35) map_api=v1beta1 ;;
  *) echo "KIND_VERSION ${version} is not in the matrix (1.33, 1.34, 1.35)" >&2; exit 2 ;;
esac
if [ "${cluster}" != sealhouse ]; then export KUBECONFIG="${root}/.state/${cluster}.kubeconfig"; fi
reg_name=kind-registry
reg_port=5001

start_registry

mkdir -p "$(dirname "${KUBECONFIG}")"
if kind get clusters | grep -qx "${cluster}"; then
  have="$(docker inspect -f '{{.Config.Image}}' "${cluster}-control-plane" 2>/dev/null || true)"
  if [ "${have}" != "${node_image}" ]; then
    echo "cluster ${cluster} runs ${have:-an unknown image}, not ${node_image}; replacing it" >&2
    kind delete cluster --name "${cluster}"
  fi
fi
if ! kind get clusters | grep -qx "${cluster}"; then
  config="${root}/kind/cluster.yaml"
  if [ -n "${map_api}" ]; then
    config="$(mktemp)"
    trap 'rm -f "${config}"' EXIT
    cat "${root}/kind/cluster.yaml" - >"${config}" <<EOF
featureGates:
  MutatingAdmissionPolicy: true
runtimeConfig:
  admissionregistration.k8s.io/${map_api}: "true"
EOF
  fi
  kind create cluster --name "${cluster}" --image "${node_image}" --config "${config}" --wait 120s
fi
kind export kubeconfig --name "${cluster}" >/dev/null

for node in $(kind get nodes --name "${cluster}"); do
  dir="/etc/containerd/certs.d/localhost:${reg_port}"
  docker exec "${node}" mkdir -p "${dir}"
  printf '[host."http://%s:5000"]\n' "${reg_name}" | docker exec -i "${node}" cp /dev/stdin "${dir}/hosts.toml"
done

if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect kind "${reg_name}"
fi

kubectl --context "kind-${cluster}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${reg_port}"
    hostFromContainerRuntime: "${reg_name}:5000"
    hostFromClusterNetwork: "${reg_name}:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

sed "s#^apiVersion: admissionregistration.k8s.io/v1\$#apiVersion: admissionregistration.k8s.io/${map_api:-v1}#" \
  "${root}/policies/arbitrary-uid.yaml" | kubectl --context "kind-${cluster}" apply -f -
KUBE_CONTEXT="kind-${cluster}" "${root}/hack/olm-up.sh"
echo "cluster ${cluster} ready; registry localhost:${reg_port}: export KUBECONFIG=${KUBECONFIG}"
