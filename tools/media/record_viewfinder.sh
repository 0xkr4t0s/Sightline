#!/usr/bin/env bash
# Make docs/media/viewfinder.gif (README media task M.4): Blender's render streamed to the iPhone
# app's viewfinder, following the camera.
#
#   tools/media/record_viewfinder.sh [OUT.gif]     # default docs/media/viewfinder.gif
#
# The real app runs in the iPhone 17 simulator in its QA mode (tools/mission/qa_ios.sh): the
# scripted `orbit` motion replaces ARKit, and the app pairs with and streams from the headless
# Blender QA host (tools/mission/qa_blender.sh) on 127.0.0.1:47000. The scene is the QA scene
# (tools/mission/qa_host.py: a colour totem inside a ring of lettered pillars), because the M.0
# demo scene (tools/media/demo_scene.py) doesn't exist yet. The host advertises itself as
# "Sightline Demo" rather than this computer's name. Nothing in the recorded screen shows a host
# name, path or address; check the frames anyway after changing the app's overlays.
#
# Steps: start the host (or reuse a running one), build and launch the app with a fresh pairing,
# wait for the stream to settle and the control rail to hide, record the screen with
# `xcrun simctl io recordVideo`, pick the most seamless 6-10 s loop (tools/media/find_loop.py),
# then make the GIF with ffmpeg in two passes (palettegen, then paletteuse with dither
# sierra2_4a). Colours are reduced to 4 bits per channel before the palette pass, which keeps the
# GIF under 3 MB with little visible change. The raw recording stays in .mission/media/ (not in
# git). The script fails when the GIF breaks the README media limits: at most 960 px wide,
# 12-15 fps, 3 MB and 10 s.
#
# Settings (environment): WIDTH (640), FPS (12), WARMUP seconds before recording (8), CAPTURE
# seconds recorded (20), SKIP_BUILD=1 to launch the existing app build, REENCODE=1 to make the
# GIF again from the last recording without starting the host or the app.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../mission/env.sh"

OUT="${1:-${ROOT}/docs/media/viewfinder.gif}"
WIDTH="${WIDTH:-640}"
FPS="${FPS:-12}"
WARMUP="${WARMUP:-8}"
CAPTURE="${CAPTURE:-20}"
DEMO_HOST_NAME="Sightline Demo"
MAX_BYTES=3145728

WORK="${MISSION_DIR}/media"
RAW="${WORK}/viewfinder.mov"
PALETTE="${WORK}/viewfinder-palette.png"
QA_BLENDER="${ROOT}/tools/mission/qa_blender.sh"
QA_IOS="${ROOT}/tools/mission/qa_ios.sh"
if [ -x "${VENV}/bin/python" ]; then PY="${VENV}/bin/python"; else PY="python3"; fi

die() { echo "record_viewfinder: $*" >&2; exit 1; }
say() { echo "record_viewfinder: $*"; }

command -v ffmpeg > /dev/null && command -v ffprobe > /dev/null || die "ffmpeg and ffprobe are needed"
mkdir -p "${WORK}" "$(dirname "${OUT}")"

started_host=""
recorder=""
cleanup() {
  [ -n "${recorder}" ] && kill -INT "${recorder}" 2> /dev/null && wait "${recorder}" 2> /dev/null
  if [ "${REENCODE:-}" != 1 ]; then
    "${QA_IOS}" terminate > /dev/null 2>&1 || true
  fi
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

# simulator_udid: the simulator qa_ios.sh runs the app in (by name, preferring a booted one).
simulator_udid() {
  xcrun simctl list devices available -j | "${PY}" -c '
import json, sys
name = sys.argv[1]
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime if d["name"] == name]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")
' "${QA_IOS_SIMULATOR:-iPhone 17}"
}

record() {
  # The host prints its pairing code when it starts; keep it off the terminal.
  if "${QA_BLENDER}" status > /dev/null 2>&1; then
    say "reusing the running QA host"
  else
    say "starting the QA host on 127.0.0.1:47000"
    "${QA_BLENDER}" start --port 47000 --bind 127.0.0.1 > /dev/null
    started_host=1
  fi
  "${QA_BLENDER}" cmd "{\"cmd\":\"eval\",\"code\":\"session.current().advertise('${DEMO_HOST_NAME}', ''); result = True\"}" \
    > /dev/null || die "could not set the advertised host name"
  "${QA_BLENDER}" cmd '{"cmd":"pair"}' > /dev/null || die "could not open pairing"

  if [ "${SKIP_BUILD:-}" != 1 ]; then
    "${QA_IOS}" build > /dev/null
  fi
  "${QA_IOS}" launch --motion orbit --reset-pairings > /dev/null
  say "app launched; waiting ${WARMUP} s for the stream to settle"
  sleep "${WARMUP}"
  local before udid
  before="$(video_sent)"
  sleep 1
  [ "$(video_sent)" -gt "${before}" ] || die "the host isn't streaming to the app (see tools/mission/qa_blender.sh state)"
  udid="$(simulator_udid)"
  [ -n "${udid}" ] || die "no simulator named '${QA_IOS_SIMULATOR:-iPhone 17}'"

  say "recording ${CAPTURE} s"
  xcrun simctl io "${udid}" recordVideo --codec=h264 --force "${RAW}" > "${WORK}/record.log" 2>&1 &
  recorder=$!
  sleep "${CAPTURE}"
  kill -INT "${recorder}"
  wait "${recorder}" || die "recordVideo failed (see ${WORK#"${ROOT}/"}/record.log)"
  recorder=""
  "${QA_IOS}" terminate > /dev/null
}

if [ "${REENCODE:-}" = 1 ]; then
  [ -f "${RAW}" ] || die "no recording at ${RAW#"${ROOT}/"}; run without REENCODE=1 first"
  say "re-encoding ${RAW#"${ROOT}/"}"
else
  record
fi

loop="$("${PY}" "${ROOT}/tools/media/find_loop.py" "${RAW}" --fps "${FPS}" --min 6 --max 10)" \
  || die "no loop found in the recording"
read -r start end <<< "${loop}"

# The same resampling as find_loop.py, so frame numbers match; frames start..end-1 make the loop.
frames="fps=${FPS},trim=start_frame=${start}:end_frame=${end},setpts=PTS-STARTPTS"
frames+=",scale=${WIDTH}:-2:flags=lanczos,format=rgb24"
frames+=",lutrgb=r='bitand(val,240)':g='bitand(val,240)':b='bitand(val,240)'"
ffmpeg -v error -y -i "${RAW}" -vf "${frames},palettegen=stats_mode=diff" "${PALETTE}"
ffmpeg -v error -y -i "${RAW}" -i "${PALETTE}" \
  -lavfi "${frames}[x];[x][1:v]paletteuse=dither=sierra2_4a:diff_mode=rectangle" -loop 0 "${OUT}"

# Check the README media limits.
probe="$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,avg_frame_rate:format=duration -of csv=p=0 "${OUT}" | tr ',\n' '  ')"
read -r width rate duration <<< "${probe}"
bytes="$(wc -c < "${OUT}" | tr -d ' ')"
say "wrote ${OUT#"${ROOT}/"}: ${width} px wide, ${rate} fps, ${duration} s, ${bytes} bytes"
"${PY}" - "${width}" "${rate}" "${duration}" "${bytes}" "${MAX_BYTES}" << 'EOF' || die "the GIF breaks the README media limits"
import sys
from fractions import Fraction
width, rate, duration, size, limit = sys.argv[1:]
fps = float(Fraction(rate))
problems = [
    f"{what} {value}"
    for what, value, ok in (
        ("width", width, int(width) <= 960),
        ("frame rate", f"{fps:.2f}", 12 <= fps <= 15),
        ("duration", duration, float(duration) <= 10),
        ("size", size, int(size) <= int(limit)),
    )
    if not ok
]
if problems:
    sys.exit("limits broken: " + ", ".join(problems))
EOF
