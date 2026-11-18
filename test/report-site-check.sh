#!/usr/bin/env bash
# report-site-check.sh SITE [SCREENSHOT] loads SITE in headless Chrome and fails on a script error, a page
# that did not finish rendering, or fewer charts than the data gives. SCREENSHOT saves a full-page capture.
# Needs google-chrome, as on GitHub's runners.
set -euo pipefail

command -v google-chrome >/dev/null || { echo "report-site-check.sh needs google-chrome" >&2; exit 1; }
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: $0 SITE [SCREENSHOT]" >&2; exit 2; }
site="$(cd "$1" && pwd)" shot="${2:-}"
port="${REPORT_SITE_PORT:-5006}"
work="$(mktemp -d)"
python3 -m http.server -b 127.0.0.1 -d "${site}" "${port}" >"${work}/http.log" 2>&1 &
pid=$!
trap 'kill "${pid}" 2>/dev/null || true; rm -rf "${work}"' EXIT
for _ in $(seq 100); do curl -fs "http://127.0.0.1:${port}/" >/dev/null && break; sleep 0.1; done

chrome() {
  timeout 60 google-chrome --headless=new --no-sandbox --disable-gpu --hide-scrollbars --enable-logging=stderr --v=0 \
    --virtual-time-budget=15000 --window-size=1280,900 --user-data-dir="${work}/profile" "$@"
}

url="http://127.0.0.1:${port}/"
chrome --dump-dom "${url}" >"${work}/dom.html" 2>"${work}/console.log"
if grep -E 'CONSOLE.*(Uncaught|Error)|"(Uncaught|Error)' "${work}/console.log" >&2; then
  echo "script errors on the report page" >&2
  exit 1
fi
ready="$(grep -o 'data-ready="[a-z]*"' "${work}/dom.html" | head -1 | cut -d'"' -f2)"
[ "${ready}" = ok ] || { echo "the page did not render: data-ready=${ready:-unset}" >&2; sed -n 's/.*id="error-text"[^>]*>\([^<]*\)<.*/\1/p' "${work}/dom.html" >&2; exit 1; }

# Each series with data is a chart; a section without data says so instead of drawing an empty canvas.
rollup="${site}/data/rollup.json"
want="$(jq '[
  ([.alphas[].components[] | select(.upstream.count > 0)] | length > 0),
  true, true, true, true, true,
  (.behind | length > 0),
  (.vulns | length > 0),
  (.soak | length > 0), (.soak | length > 0)
] | map(select(.)) | length' "${rollup}")"
have="$(grep -o 'data-charts="[0-9]*"' "${work}/dom.html" | cut -d'"' -f2)"
[ "${have}" = "${want}" ] || { echo "the page drew ${have:-no} charts, the data gives ${want}" >&2; exit 1; }
canvases="$(grep -o '<canvas' "${work}/dom.html" | wc -l)"
[ "${canvases}" = "${want}" ] || { echo "${canvases} canvases on the page, want ${want}" >&2; exit 1; }

if [ -n "${shot}" ]; then
  chrome --screenshot="${work}/shot.png" --window-size=1280,4200 "${url}" 2>/dev/null
  cp "${work}/shot.png" "${shot}"
fi
echo "ok: the report page renders ${have} charts"
