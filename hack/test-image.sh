#!/usr/bin/env bash
# test-image.sh REPO_DIR IMAGE_REF
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$1" && pwd)"
ref="$2"
# shellcheck disable=SC1091
source "${repo}/.sealhouse/build.env"

work="$(mktemp -d)"
cid=""
cleanup() {
  [ -n "${cid}" ] && docker rm -f "${cid}" >/dev/null 2>&1 || true
  rm -rf "${work}"
}
trap cleanup EXIT

# 1. Random UID, GID 0.
uid=$(( 1000000000 + RANDOM * 10 + RANDOM % 10 ))
run_opts=()
for kv in ${SMOKE_ENV:-}; do run_opts+=(-e "${kv}"); done
if [ "${SMOKE_KUBECONFIG:-0}" = "1" ]; then
  # 192.0.2.0/24 is TEST-NET-1: never routed, so every request times out.
  cat >"${work}/kubeconfig" <<'KC'
apiVersion: v1
kind: Config
clusters: [{name: smoke, cluster: {server: "https://192.0.2.1:6443", insecure-skip-tls-verify: true}}]
users: [{name: smoke, user: {token: smoke}}]
contexts: [{name: smoke, context: {cluster: smoke, user: smoke}}]
current-context: smoke
KC
  chmod 0644 "${work}/kubeconfig"
  run_opts+=(-v "${work}/kubeconfig:/etc/smoke/kubeconfig:ro" -e KUBECONFIG=/etc/smoke/kubeconfig)
fi
if [ -n "${SMOKE_KEY:-}" ]; then
  read -r key_params key_path <<<"${SMOKE_KEY}"
  go run "${root}/hack/mldsa-key.go" "${key_params}" >"${work}/key.pem"
  chmod 0644 "${work}/key.pem"
  run_opts+=(-v "${work}/key.pem:${key_path}:ro")
fi
run_opts=(--user "${uid}:0" -e GODEBUG=fips140=on --read-only --tmpfs /tmp --cap-drop ALL \
  --security-opt no-new-privileges "${run_opts[@]}")
if [ "${SMOKE_ONESHOT:-0}" = "1" ]; then
  # shellcheck disable=SC2086
  if ! docker run --rm "${run_opts[@]}" "${ref}" ${SMOKE_ARGS} >"${work}/oneshot.log" 2>&1; then
    echo "FAIL: ${ref} ${SMOKE_ARGS} failed under --user ${uid}:0" >&2
    cat "${work}/oneshot.log" >&2
    exit 1
  fi
  echo "ok: ${ref} ${SMOKE_ARGS} exits 0 under --user ${uid}:0"
else
  # shellcheck disable=SC2086
  cid="$(docker run -d "${run_opts[@]}" "${ref}" ${SMOKE_ARGS})"
  sleep "${SMOKE_SECONDS:-5}"
  if [ "$(docker inspect -f '{{.State.Running}}' "${cid}")" != "true" ]; then
    echo "FAIL: ${ref} exited under --user ${uid}:0" >&2
    docker logs "${cid}" >&2 || true
    exit 1
  fi
  echo "ok: ${ref} runs under --user ${uid}:0"
  docker rm -f "${cid}" >/dev/null
fi
cid="$(docker create "${ref}")"

# 2. Writable paths.
for path in ${WRITABLE_PATHS:-}; do
  entry="$(docker export "${cid}" | tar -tvf - "${path#/}" 2>/dev/null | head -1 || true)"
  if [ -z "${entry}" ]; then
    echo "FAIL: ${path} missing from ${ref}" >&2
    exit 1
  fi
  mode="$(awk '{print $1}' <<<"${entry}")"
  group="$(awk '{print $2}' <<<"${entry}" | cut -d/ -f2)"
  if [ "${mode:5:1}" != "w" ] || { [ "${group}" != "0" ] && [ "${group}" != "root" ]; }; then
    echo "FAIL: ${path} is ${mode} ${group}; want group 0 with g+w" >&2
    exit 1
  fi
  echo "ok: ${path} ${mode} group ${group}"
done

# 3. Build settings of each binary.
for bin in ${BINARIES}; do
  docker cp "${cid}:${bin}" "${work}/bin" >/dev/null
  info="$(go version -m "${work}/bin")"
  grep -q $'\tbuild\tGOFIPS140=v1.26.0' <<<"${info}" || { echo "FAIL: ${bin} not built with GOFIPS140=v1.26.0" >&2; exit 1; }
  grep -q $'\tbuild\tCGO_ENABLED=0' <<<"${info}" || { echo "FAIL: ${bin} not built with CGO_ENABLED=0" >&2; exit 1; }
  echo "ok: ${bin} GOFIPS140=v1.26.0 CGO_ENABLED=0 ($(head -1 <<<"${info}" | awk '{print $2}'))"
  rm -f "${work}/bin"
done
