#!/usr/bin/env bash
# soak-record.sh TREND commits TREND to ci's soak-trend branch, with GH_TOKEN.
set -euo pipefail

exec "$(dirname "$0")/trend-record.sh" soak-trend "$1"
