#!/bin/bash
# Build then run the perf benchmark with per-section draw timings.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/build-app.sh >/dev/null 2>&1
timeout 60 build/Designer.app/Contents/MacOS/Designer --perf-test --perf-probe 2>&1 | grep -E "PROBE|PERF|phase"
