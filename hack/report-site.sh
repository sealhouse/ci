#!/usr/bin/env bash
# report-site.sh DATA_DIR OUT assembles the report site in OUT: ci's report/site with DATA_DIR's
# rollup.json and daily/*.json under data/. Refuses a vendored file whose checksum differs from report/vendor.lock.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 2 ] || { echo "usage: $0 DATA_DIR OUT" >&2; exit 2; }
data="$1" out="$2"
[ -f "${data}/rollup.json" ] || { echo "${data}/rollup.json is missing" >&2; exit 1; }

while read -r file pkg _ sum; do
  have="$(sha256sum "${root}/report/${file}" | cut -d' ' -f1)"
  [ "${have}" = "${sum}" ] || { echo "${file} (${pkg}) has sha256 ${have}, vendor.lock pins ${sum}" >&2; exit 1; }
done < <(grep -v '^#' "${root}/report/vendor.lock")

rm -rf "${out}"
mkdir -p "${out}/data/daily"
cp -R "${root}/report/site/." "${out}/"
cp "${data}/rollup.json" "${out}/data/"
find "${data}/daily" -maxdepth 1 -name '*.json' -exec cp {} "${out}/data/daily/" \;
