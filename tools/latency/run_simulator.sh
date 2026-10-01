#!/usr/bin/env bash
# Measure motion-to-photon and every leg of the viewfinder path in the iPhone simulator (task 2.6;
# NFR-LAT-003, NFR-LAT-004) and write reports/latency-<date>-simulator.json.
#
#   tools/latency/run_simulator.sh [OUT.json]
#
# The real app runs in the iPhone 17 simulator in its QA mode (tools/mission/qa_ios.sh): scripted
# poses replace ARKit, and it pairs with and streams from the headless Blender QA host
# (tools/mission/qa_blender.sh) on 127.0.0.1:47000 at 960×540 JPEG, 30 fps. After a warm-up the
# script checks that frames flow, streams for DURATION seconds, then saves the host's report
# (qa_blender.sh cmd latency_report) and copies the app's latency-device.json out of its data
# container (qa_ios.sh latency, simctl get_app_container). tools/latency/merge_report.py merges
# the two into the report: each leg as p50/p95/p99 with its method, the derived network leg, and
# the verdict against M2P p95 ≤ 120 ms, labelled "environment": "simulator". Both reports cover
# the whole device session, warm-up included. The inputs stay in .mission/latency/.
#
# Settings (environment): DURATION seconds measured after the warm-up (60), WARMUP seconds (8),
# MOTION (orbit), SKIP_BUILD=1 to launch the existing app build. A running QA host is reused;
# the stream settings are set to 540p / 30 fps either way.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../mission/env.sh"

DATE="$(date +%Y-%m-%d)"
OUT="${1:-${ROOT}/reports/latency-${DATE}-simulator.json}"
DURATION="${DURATION:-60}"
WARMUP="${WARMUP:-8}"
MOTION="${MOTION:-orbit}"
FPS=30

WORK="${MISSION_DIR}/latency"
HOST_REPORT="${WORK}/latency-host.json"
DEVICE_REPORT="${WORK}/latency-device.json"
QA_BLENDER="${ROOT}/tools/mission/qa_blender.sh"
QA_IOS="${ROOT}/tools/mission/qa_ios.sh"
BUNDLE_ID="kr8t0s.Sightline"
if [ -x "${VENV}/bin/python" ]; then PY="${VENV}/bin/python"; else PY="python3"; fi

die() { echo "run_simulator: $*" >&2; exit 1; }
say() { echo "run_simulator: $*"; }

mkdir -p "${WORK}"
rm -f "${HOST_REPORT}" "${DEVICE_REPORT}"

started_host=""
cleanup() {
  "${QA_IOS}" terminate > /dev/null 2>&1 || true
  [ -n "${started_host}" ] && "${QA_BLENDER}" stop > /dev/null 2>&1
  return 0
}
trap cleanup EXIT

# video_sent: frames the host has streamed to the app so far (0 when there is no session).
video_sent() {
  "${PY}" - "${MISSION_DIR}/qa/state.json" << 'EOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        video = json.load(f).get("video") or {}
except (OSError, ValueError):
    video = {}
print(int(video.get("sent") or 0))
EOF
}

set_prop() {
  "${QA_BLENDER}" cmd "{\"cmd\":\"set\",\"prop\":\"$1\",\"value\":\"$2\"}" > /dev/null || die "could not set $1 to $2"
}

# The host prints its pairing code when it starts; keep it off the terminal.
if "${QA_BLENDER}" status > /dev/null 2>&1; then
  say "reusing the running QA host"
else
  say "starting the QA host on 127.0.0.1:47000"
  "${QA_BLENDER}" start --port 47000 --bind 127.0.0.1 > /dev/null
  started_host=1
fi
set_prop stream_resolution 540p
set_prop stream_fps "${FPS}"
"${QA_BLENDER}" cmd '{"cmd":"pair"}' > /dev/null || die "could not open pairing"

if [ "${SKIP_BUILD:-}" != 1 ]; then
  say "building the app"
  "${QA_IOS}" build > /dev/null
fi
"${QA_IOS}" boot > /dev/null
# A report left by an earlier run must not be read as this one's.
container="$(xcrun simctl get_app_container booted "${BUNDLE_ID}" data 2> /dev/null || true)"
[ -n "${container}" ] && rm -f "${container}/Documents/latency-device.json"

"${QA_IOS}" launch --motion "${MOTION}" --reset-pairings > /dev/null
say "app launched (${MOTION}); warming up for ${WARMUP} s"
sleep "${WARMUP}"
before="$(video_sent)"
sleep 1
[ "$(video_sent)" -gt "${before}" ] || die "the host isn't streaming to the app (see tools/mission/qa_blender.sh state)"

say "measuring for ${DURATION} s"
sleep "${DURATION}"
"${QA_BLENDER}" cmd "{\"cmd\":\"latency_report\",\"path\":\"${HOST_REPORT}\"}" > /dev/null \
  || die "the host couldn't save its latency report"
# The app writes its report every 2 s while frames are shown; take one written after the host's.
sleep 3
"${QA_IOS}" latency "${DEVICE_REPORT}" > /dev/null
"${QA_IOS}" terminate > /dev/null

"${PY}" "${ROOT}/tools/latency/merge_report.py" --host "${HOST_REPORT}" --device "${DEVICE_REPORT}" \
  --out "${OUT}" --date "${DATE}" --fps "${FPS}" --duration-s "${DURATION}" --motion "${MOTION}" \
  --note "Blender runs the debug vcam_native wheel tools/mission/setup.sh builds (local release wheels can fail to load, docs/LOOP_LOG.md), so encode_ms and M2P include debug-build JPEG encoding; SRS §13.2 (S-2a) has release encode times near 1 ms at 960x540." \
  --note "The simulator and Blender share one Mac (CPU, GPU and loopback network); the pose leg and network leg include no Wi-Fi."
