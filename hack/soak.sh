#!/usr/bin/env bash
# soak.sh TREE OUT_DIR TREND soaks the alpha head on a fresh cluster and appends to TREND.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/hack/lib.sh"

tree="$1" out="$2" trend="$3"
cluster=sealhouse-soak
kubeconfig="${root}/.state/${cluster}.kubeconfig"
result=0

# Fails past 20% (plus 5) goroutines or 30% heap over the median of the last seven passes.
soak_trend() {
  local summary="$1" commit="$2" result="$3"
  local g h sys kills csv base n mg mh
  g="$(jq -r .goroutines "${summary}")"
  h="$(jq -r '(.heapInuseBytes / 1048576 * 10 | round) / 10' "${summary}")"
  sys="$(jq -r '(.sysBytes / 1048576 * 10 | round) / 10' "${summary}")"
  kills="$(jq -r '.kills | length' "${summary}")"
  csv="$(jq -r .csv "${summary}")"
  [ -f "${trend}" ] || printf 'date\tcommit\tcsv\tgoroutines\theap_mib\tsys_mib\tkills\tresult\n' >"${trend}"
  base="$(awk -F'\t' 'NR > 1 && $8 == "pass" { print $4 "\t" $5 }' "${trend}" | tail -7)"
  n="$(grep -c . <<<"${base}" || true)"
  if [ "${n}" -lt 3 ]; then
    echo "soak trend: building the baseline (${n} of 3 earlier passing runs); goroutines ${g}, heap ${h} MiB"
  else
    mg="$(cut -f1 <<<"${base}" | sort -n | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }')"
    mh="$(cut -f2 <<<"${base}" | sort -n | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }')"
    echo "soak trend: goroutines ${g} (median ${mg}), heap ${h} MiB (median ${mh}) over ${n} runs"
    awk -v g="${g}" -v h="${h}" -v mg="${mg}" -v mh="${mh}" 'BEGIN {
      bad = 0
      if (g > mg * 1.2 + 5) { print "goroutines regressed: " g " against a median of " mg > "/dev/stderr"; bad = 1 }
      if (h > mh * 1.3) { print "heap in use regressed: " h " MiB against a median of " mh " MiB" > "/dev/stderr"; bad = 1 }
      exit bad
    }' || result=1
  fi
  # A failed or regressed run is kept but never joins the baseline.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${commit:0:12}" "${csv}" \
    "${g}" "${h}" "${sys}" "${kills}" "$([ "${result}" -eq 0 ] && echo pass || echo fail)" >>"${trend}"
  return "${result}"
}

alpha_head_tree "${tree}"
commit="$(git -C "${tree}" rev-parse HEAD)"
# A plain install: upgrades belong to the e2e runs.
sed -i 's/^PREVIOUS_CSV=.*/PREVIOUS_CSV=/' "${tree}/dist/alpha.env"
mkdir -p "${out}"
kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
KIND_CLUSTER="${cluster}" "${root}/hack/cluster-up.sh"
make -C "${tree}" --no-print-directory test-soak CI_DIR="${root}" ALPHA_ENV="${tree}/dist/alpha.env" \
  SOAK_KUBECONFIG="${kubeconfig}" SOAK_CONTEXT="kind-${cluster}" SOAK_OUT="${out}/soak.json" || result=1
if [ -f "${out}/soak.json" ]; then
  soak_trend "${out}/soak.json" "${commit}" "${result}" || result=1
else
  echo "the soak wrote no summary" >&2
  result=1
fi
if [ "${result}" -ne 0 ]; then
  kind export logs --name "${cluster}" "${out}/soak-cluster" >/dev/null 2>&1 || true
fi
kind delete cluster --name "${cluster}" >/dev/null 2>&1 || true
rm -f "${kubeconfig}"
exit "${result}"
