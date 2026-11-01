#!/usr/bin/env bash
# Starts MicroShift (microshift-io's OKD bootc image) in a privileged container.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

name="${MICROSHIFT_CONTAINER:-sealhouse-microshift}"
version="${MICROSHIFT_VERSION:-4.22}"
image="${MICROSHIFT_IMAGE:-$(lock "MICROSHIFT_${version//./_}")}"
# The API server gets a free host port unless MICROSHIFT_API_PORT names one:
# 6443 and its neighbours are often taken (k3s holds 6443 and 6444).
port="${MICROSHIFT_API_PORT:-}"
context=microshift-sealhouse
kubeconfig="${root}/.state/microshift.kubeconfig"
lvm_volume="${name}-lvm"
lvm_size="${MICROSHIFT_LVM_SIZE:-4G}"
lvmlocal="${root}/.state/microshift-lvmlocal.conf"
vg=myvg1

if ! docker network inspect kind >/dev/null 2>&1; then
  docker network create kind >/dev/null
fi
start_registry
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' kind-registry)" = 'null' ]; then
  docker network connect kind kind-registry
fi

if [ "$(docker inspect -f '{{.State.Running}} {{.Config.Image}}' "${name}" 2>/dev/null || true)" != "true ${image}" ]; then
  docker rm -f "${name}" >/dev/null 2>&1 || true

  # The volume group sits on a loop device over a file in a docker volume.
  docker volume create "${lvm_volume}" >/dev/null
  loop="$(docker run --rm --privileged -v /dev:/dev -v "${lvm_volume}:/lvm" \
    -e SIZE="${lvm_size}" --entrypoint /bin/bash "${image}" -c '
      set -euo pipefail
      [ -f /lvm/disk.img ] || truncate --size="${SIZE}" /lvm/disk.img
      dev="$(losetup -j /lvm/disk.img | cut -d: -f1 | head -1)"
      [ -n "${dev}" ] || dev="$(losetup --find --show --nooverlap /lvm/disk.img)"
      echo "${dev}"')"
  mkdir -p "${root}/.state"
  printf '%s\n' \
    'devices {' \
    '  use_devicesfile = 0' \
    "  global_filter = [ \"a|^${loop}\$|\", \"r|.*|\" ]" \
    '}' \
    'activation {' \
    '  udev_sync = 0' \
    '  udev_rules = 0' \
    '}' >"${lvmlocal}"
  docker run --rm --privileged -v /dev:/dev -v "${lvmlocal}:/etc/lvm/lvmlocal.conf:ro" \
    -e VG="${vg}" -e LOOP="${loop}" --entrypoint /bin/bash "${image}" -c '
      set -euo pipefail
      if ! vgs "${VG}" >/dev/null 2>&1; then
        if pvs "${LOOP}" >/dev/null 2>&1; then
          vgscan >/dev/null
        else
          vgcreate -f -y "${VG}" "${LOOP}" >/dev/null
        fi
      fi
      vgs "${VG}" >/dev/null'

  udev_masks=()
  for unit in systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
    systemd-udev-trigger.service systemd-udev-settle.service; do
    udev_masks+=(-v "/dev/null:/etc/systemd/system/${unit}:ro")
  done
  # /dev is shared for TopoLVM; a pseudo-TTY and tmpfs over the input, sound
  # and GPU devices keep the container's systemd off the host's consoles.
  docker run --privileged -d --tty --name "${name}" \
    --hostname 127.0.0.1.nip.io --network kind -p "127.0.0.1:${port}:6443" \
    -v /dev:/dev --tmpfs /dev/input --tmpfs /dev/snd --tmpfs /dev/dri \
    -v "${root}/microshift/registries.conf:/etc/containers/registries.conf.d/50-sealhouse.conf:ro" \
    -v "${lvmlocal}:/etc/lvm/lvmlocal.conf:ro" \
    "${udev_masks[@]}" \
    "${image}" >/dev/null
fi

port="$(docker port "${name}" 6443/tcp | head -1 | cut -d: -f2)"

src=/var/lib/microshift/resources/kubeadmin/127.0.0.1.nip.io/kubeconfig
for _ in $(seq 1 150); do
  docker exec "${name}" test -f "${src}" 2>/dev/null && break
  sleep 2
done
mkdir -p "${root}/.state"
docker exec "${name}" cat "${src}" >"${kubeconfig}"
# The serving certificate names 127.0.0.1.nip.io, not 127.0.0.1: keep the
# name for TLS without depending on nip.io's DNS.
cluster="$(kubectl --kubeconfig "${kubeconfig}" config view -o jsonpath='{.clusters[0].name}')"
kubectl --kubeconfig "${kubeconfig}" config set-cluster "${cluster}" \
  --server "https://127.0.0.1:${port}" --tls-server-name 127.0.0.1.nip.io >/dev/null
current="$(kubectl --kubeconfig "${kubeconfig}" config current-context)"
if [ "${current}" != "${context}" ]; then
  kubectl --kubeconfig "${kubeconfig}" config rename-context "${current}" "${context}" >/dev/null
fi
k() { kubectl --kubeconfig "${kubeconfig}" --context "${context}" "$@"; }

# MicroShift is ready when its node is and every pod it deploys runs.
for _ in $(seq 1 150); do
  if k wait --for=condition=Ready node --all --timeout=2s >/dev/null 2>&1; then
    pending="$(k get pods -A --no-headers 2>/dev/null | awk '{ split($3, r, "/") } r[1] != r[2] || $4 != "Running"' | wc -l)"
    total="$(k get pods -A --no-headers 2>/dev/null | wc -l)"
    [ "${total}" -gt 0 ] && [ "${pending}" -eq 0 ] && break
  fi
  sleep 4
done
if [ "${pending:-1}" -ne 0 ]; then
  echo "MicroShift pods not ready:" >&2
  k get pods -A >&2
  exit 1
fi
echo "MicroShift $(docker exec "${name}" microshift version -o json | jq -r .gitVersion) ready, Kubernetes $(k version -o json | jq -r .serverVersion.gitVersion)"

KUBECONFIG="${kubeconfig}" KUBE_CONTEXT="${context}" OLM_OVERLAY="${root}/microshift/olm" "${ci_root}/hack/olm-up.sh"
echo "cluster ${context} ready: export KUBECONFIG=${kubeconfig}"
