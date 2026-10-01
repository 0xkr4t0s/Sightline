#!/usr/bin/env bash
# Run the Sightline iOS app in the iPhone 17 simulator in QA mode: scripted poses instead of ARKit,
# paired with and streaming from a Blender host on this Mac (tools/mission/qa_blender.sh). The
# launch arguments are documented in SightlineIOS/SightlineIOS/SimulatorQA.swift.
#
#   tools/mission/qa_ios.sh build                  # Debug simulator build into .mission/ios-build
#   tools/mission/qa_ios.sh boot                   # boot the simulator if it isn't
#   tools/mission/qa_ios.sh launch [--motion orbit|pan|still] [--host H:PORT] [--code CODE]
#                          [--no-autostart] [--reset-pairings] [--limited FROM-TO] [-- APP_ARGS...]
#   tools/mission/qa_ios.sh screenshot [--raw] [PATH]   # upright; default .mission/qa/ios-<timestamp>.png
#   tools/mission/qa_ios.sh terminate              # quit the app and stop the log stream
#   tools/mission/qa_ios.sh status                 # simulator, app process, log stream
#   tools/mission/qa_ios.sh logs [LINES]           # tail .mission/logs/qa-ios.log
#   tools/mission/qa_ios.sh uitest [XCODEBUILD_ARGS...]   # default: -only-testing:SightlineIOSUITests
#   tools/mission/qa_ios.sh defaults write KEY VALUE | read [KEY] | delete KEY
#
# `launch` takes the host and pairing code from .mission/qa/host.json when there is one (port,
# pairing_code), installs the latest build, restarts the app, and streams its unified log
# (subsystem kr8t0s.Sightline) into .mission/logs/qa-ios.log. `uitest` passes the same host and
# code to the UI tests (TEST_RUNNER_SIGHTLINE_QA_HOST/CODE; SIGHTLINE_QA_HOST/CODE override them),
# keeps the result bundle in .mission/xcresult/uitest and copies the screenshots it attached into
# .mission/qa/uitest-attachments/. Set QA_IOS_SIMULATOR to use another simulator by name.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

BUNDLE_ID="kr8t0s.Sightline"
SIM_NAME="${QA_IOS_SIMULATOR:-iPhone 17}"
PROJECT="${ROOT}/SightlineIOS/SightlineIOS.xcodeproj"
DERIVED="${MISSION_DIR}/ios-build"
APP="${DERIVED}/Build/Products/Debug-iphonesimulator/SightlineIOS.app"
QA_DIR="${MISSION_DIR}/qa"
HOST_JSON="${QA_DIR}/host.json"
APP_LOG="${LOG_DIR}/qa-ios.log"
LOG_PID="${QA_DIR}/ios-log.pid"
BUILD_LOG="${LOG_DIR}/qa-ios-build.log"
UITEST_LOG="${LOG_DIR}/qa-ios-uitest.log"
UITEST_BUNDLE="${MISSION_DIR}/xcresult/uitest"
ATTACHMENTS="${QA_DIR}/uitest-attachments"
mkdir -p "${QA_DIR}"

die() { echo "qa_ios: $*" >&2; exit 1; }

# The simulator's UDID: an exact name match, preferring a booted one.
udid() {
  local id
  id="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime if d["name"] == name]
devices.sort(key=lambda d: d["state"] != "Booted")
print(devices[0]["udid"] if devices else "")
' "${SIM_NAME}")"
  [ -n "${id}" ] || die "no available simulator named '${SIM_NAME}'"
  echo "${id}"
}

# json_get KEY: a top-level value of host.json, empty when missing.
json_get() {
  [ -f "${HOST_JSON}" ] || return 0
  python3 - "${HOST_JSON}" "$1" <<'EOF'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        value = json.load(f).get(sys.argv[2])
except (OSError, ValueError):
    value = None
print("" if value is None else value)
EOF
}

# The host harness's control address ("127.0.0.1:47000") and pairing code, when it is up.
harness_host() {
  local port bind
  [ "$(json_get state)" = running ] || return 0
  port="$(json_get port)"
  [ -n "${port}" ] || return 0
  bind="$(json_get bind)"
  case "${bind}" in "" | 0.0.0.0 | "::") bind="127.0.0.1" ;; esac
  echo "${bind}:${port}"
}
harness_code() { [ "$(json_get state)" = running ] && json_get pairing_code || true; }

cmd_build() {
  echo "Building (log: ${BUILD_LOG#"${ROOT}/"})"
  xcodebuild build -project "${PROJECT}" -scheme SightlineIOS -configuration Debug \
    -destination "platform=iOS Simulator,id=$(udid)" -derivedDataPath "${DERIVED}" \
    > "${BUILD_LOG}" 2>&1 || { tail -30 "${BUILD_LOG}" >&2; die "build failed"; }
  echo "Built ${APP#"${ROOT}/"}"
}

cmd_boot() {
  local id
  id="$(udid)"
  if ! xcrun simctl list devices | grep -q "${id}) (Booted)"; then
    xcrun simctl boot "${id}"
  fi
  xcrun simctl bootstatus "${id}" -b > /dev/null
  echo "Booted ${SIM_NAME} (${id})"
}

stop_log_stream() {
  if [ -f "${LOG_PID}" ]; then
    kill "$(cat "${LOG_PID}")" 2>/dev/null || true
    rm -f "${LOG_PID}"
  fi
}

cmd_launch() {
  local motion="orbit" host code autostart=YES reset="" limited="" extra=()
  host="$(harness_host)"
  code="$(harness_code)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --motion) motion="$2"; shift 2 ;;
      --host) host="$2"; shift 2 ;;
      --code) code="$2"; shift 2 ;;
      --no-autostart) autostart=NO; shift ;;
      --reset-pairings) reset=YES; shift ;;
      --limited) limited="$2"; shift 2 ;;
      --) shift; extra=("$@"); break ;;
      *) die "unknown launch option: $1" ;;
    esac
  done
  [ -d "${APP}" ] || cmd_build
  cmd_boot > /dev/null
  local id args=()
  id="$(udid)"
  [ -n "${host}" ] && args+=(-SightlineQAHost "${host}")
  [ -n "${code}" ] && args+=(-SightlineQACode "${code}")
  [ -n "${motion}" ] && args+=(-SightlineQAMotion "${motion}")
  args+=(-SightlineQAAutoStart "${autostart}")
  [ -n "${reset}" ] && args+=(-SightlineQAResetPairings YES)
  [ -n "${limited}" ] && args+=(-SightlineQALimited "${limited}")
  [ ${#extra[@]} -gt 0 ] && args+=("${extra[@]}")

  xcrun simctl terminate "${id}" "${BUNDLE_ID}" > /dev/null 2>&1 || true
  xcrun simctl install "${id}" "${APP}"
  stop_log_stream
  : > "${APP_LOG}"
  nohup xcrun simctl spawn "${id}" log stream --style compact --level debug \
    --predicate "subsystem == \"${BUNDLE_ID}\"" >> "${APP_LOG}" 2>&1 < /dev/null &
  echo $! > "${LOG_PID}"
  sleep 1
  xcrun simctl launch "${id}" "${BUNDLE_ID}" "${args[@]}" > /dev/null
  echo "Launched ${BUNDLE_ID}: host ${host:-none}, code $([ -n "${code}" ] && echo given || echo none), motion ${motion:-arkit}, autostart ${autostart}"
  echo "App log: ${APP_LOG#"${ROOT}/"}"
}

# simctl captures the portrait framebuffer; the app is landscape-only on iPhone, so a portrait
# capture is turned upright (--raw keeps it as captured).
cmd_screenshot() {
  local raw="" path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --raw) raw=1; shift ;;
      *) path="$1"; shift ;;
    esac
  done
  path="${path:-${QA_DIR}/ios-$(date +%Y%m%d-%H%M%S).png}"
  mkdir -p "$(dirname "${path}")"
  xcrun simctl io "$(udid)" screenshot --type=png "${path}" > /dev/null 2>&1 || die "screenshot failed (is the simulator booted?)"
  if [ -z "${raw}" ]; then
    local w h
    w="$(sips -g pixelWidth "${path}" | awk '/pixelWidth/ {print $2}')"
    h="$(sips -g pixelHeight "${path}" | awk '/pixelHeight/ {print $2}')"
    [ "${w}" -lt "${h}" ] && sips -r 270 "${path}" > /dev/null
  fi
  echo "${path}"
}

cmd_terminate() {
  xcrun simctl terminate "$(udid)" "${BUNDLE_ID}" > /dev/null 2>&1 || true
  stop_log_stream
  echo "Terminated ${BUNDLE_ID}"
}

cmd_status() {
  local id
  id="$(udid)"
  if xcrun simctl list devices | grep -q "${id}) (Booted)"; then
    echo "simulator: ${SIM_NAME} booted"
    # Simulator apps are host processes, running from the simulator's data directory.
    if pgrep -f "${id}/.*/SightlineIOS.app/SightlineIOS" > /dev/null; then
      echo "app: running"
    else
      echo "app: not running"
    fi
  else
    echo "simulator: ${SIM_NAME} shut down"
  fi
  if [ -f "${LOG_PID}" ] && kill -0 "$(cat "${LOG_PID}")" 2>/dev/null; then
    echo "log stream: running -> ${APP_LOG#"${ROOT}/"}"
  else
    echo "log stream: stopped"
  fi
  echo "harness host: $(harness_host)"
}

cmd_logs() {
  [ -f "${APP_LOG}" ] || die "no app log yet: run launch"
  tail -n "${1:-50}" "${APP_LOG}"
}

# Moves an old output aside (into a fresh temp dir the OS cleans up) instead of deleting it.
move_aside() {
  [ -e "$1" ] || return 0
  mv "$1" "$(mktemp -d "${TMPDIR:-/tmp}/qa-ios.XXXXXX")/"
}

cmd_uitest() {
  local host="${SIGHTLINE_QA_HOST-$(harness_host)}" code="${SIGHTLINE_QA_CODE-$(harness_code)}"
  local args=("$@")
  [ ${#args[@]} -gt 0 ] || args=(-only-testing:SightlineIOSUITests)
  mkdir -p "$(dirname "${UITEST_BUNDLE}")"
  move_aside "${UITEST_BUNDLE}"
  echo "UI tests: host ${host:-none (end-to-end test skips)} (log: ${UITEST_LOG#"${ROOT}/"})"
  local status=0
  TEST_RUNNER_SIGHTLINE_QA_HOST="${host}" TEST_RUNNER_SIGHTLINE_QA_CODE="${code}" \
    TEST_RUNNER_SIGHTLINE_QA_MOTION="${SIGHTLINE_QA_MOTION:-orbit}" \
    xcodebuild test -project "${PROJECT}" -scheme SightlineIOS \
    -destination "platform=iOS Simulator,id=$(udid)" -derivedDataPath "${DERIVED}" \
    -resultBundlePath "${UITEST_BUNDLE}" "${args[@]}" > "${UITEST_LOG}" 2>&1 || status=$?
  grep -E "^Test Case .*(passed|failed|skipped)|error: -\[|Executed [0-9]+ test" "${UITEST_LOG}" | sed -E 's/^Test Case //' || true
  export_attachments
  [ "${status}" -eq 0 ] && echo "PASS uitest" || echo "FAIL uitest (exit ${status})"
  return "${status}"
}

# Exports the result bundle's attachments and gives the screenshots the tests named readable
# file names: <test>/<name>.png.
export_attachments() {
  [ -d "${UITEST_BUNDLE}" ] || return 0
  move_aside "${ATTACHMENTS}"
  mkdir -p "${ATTACHMENTS}/raw"
  xcrun xcresulttool export attachments --path "${UITEST_BUNDLE}" --output-path "${ATTACHMENTS}/raw" \
    > /dev/null 2>&1 || { echo "qa_ios: couldn't export attachments (xcresulttool)" >&2; return 0; }
  python3 - "${ATTACHMENTS}" <<'EOF'
import json, os, re, shutil, sys
root = sys.argv[1]
raw = os.path.join(root, "raw")
with open(os.path.join(raw, "manifest.json"), encoding="utf-8") as f:
    manifest = json.load(f)
for test in manifest:
    name = re.sub(r"[^A-Za-z0-9_.-]+", "_", test.get("testIdentifier", "test").split("/")[-1].rstrip("()"))
    for a in test.get("attachments", []):
        human = a.get("suggestedHumanReadableName", "")
        if human.startswith(("UI Snapshot", "Synthesized Event")):
            continue
        # XCTest appends "_<index>_<UUID>.<ext>" to the attachment's name.
        base, ext = os.path.splitext(human)
        base = re.sub(r"_\d+_[0-9A-F-]{36}$", "", base)
        os.makedirs(os.path.join(root, name), exist_ok=True)
        target = os.path.join(root, name, re.sub(r"[^A-Za-z0-9_., -]+", "_", base) + ext)
        shutil.copyfile(os.path.join(raw, a["exportedFileName"]), target)
        print("attachment:", os.path.relpath(target, os.path.dirname(os.path.dirname(os.path.dirname(root)))))
EOF
}

cmd_defaults() {
  local id
  id="$(udid)"
  case "${1:-}" in
    write) [ $# -eq 3 ] || die "usage: defaults write KEY VALUE"; xcrun simctl spawn "${id}" defaults write "${BUNDLE_ID}" "$2" "$3" ;;
    read) xcrun simctl spawn "${id}" defaults read "${BUNDLE_ID}" ${2:+"$2"} ;;
    delete) [ $# -eq 2 ] || die "usage: defaults delete KEY"; xcrun simctl spawn "${id}" defaults delete "${BUNDLE_ID}" "$2" ;;
    *) die "usage: defaults write KEY VALUE | read [KEY] | delete KEY" ;;
  esac
}

sub="${1:-}"
[ $# -gt 0 ] && shift
case "${sub}" in
  build | boot | launch | screenshot | terminate | status | logs | uitest | defaults) "cmd_${sub}" "$@" ;;
  *) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
