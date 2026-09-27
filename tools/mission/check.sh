#!/usr/bin/env bash
# Run the local test suites and write one log per suite to .mission/logs/<suite>.log.
#
#   tools/mission/check.sh                 # every suite
#   tools/mission/check.sh rust python     # only these
#   BLENDER_TESTS="addon_apply" tools/mission/check.sh blender
#
# Suites: rust, python, blender, ios. Run tools/mission/setup.sh first; the blender suite needs
# its installed extension and fake iPhone (re-run setup after changing native/ or BlenderAddOn/).
# Exits non-zero if any suite failed. The last lines of each log hold its pass/fail summary.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "${ROOT}"

# The CI blender-smoke scripts plus the two GPU-only render checks (CI runners have no GPU).
BLENDER_TESTS="${BLENDER_TESTS:-smoke_native session_native addon_session addon_apply addon_panel addon_robust pose_leg_latency video_native render_offscreen render_session}"

suite_rust() {
  (cd native && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test)
}

suite_python() {
  "${VENV}/bin/pytest" -q -p no:cacheprovider BlenderAddOn/tests &&
    "${VENV}/bin/python" tools/gen_testdata.py --check
}

suite_blender() {
  [ -d "${BLENDER_USER_RESOURCES}/extensions" ] || { echo "No installed extension: run tools/mission/setup.sh"; return 1; }
  [ -x "${FAKE_IPHONE}" ] || { echo "No fake iPhone at ${FAKE_IPHONE}: run tools/mission/setup.sh"; return 1; }
  local t failed=0
  for t in ${BLENDER_TESTS}; do
    echo "== ${t}"
    if "${BLENDER}" --background --factory-startup --python-exit-code 1 --python "tests/blender/${t}.py"; then
      echo "PASS ${t}"
    else
      echo "FAIL ${t}"; failed=1
    fi
  done
  return "${failed}"
}

suite_ios() {
  local bundle="${MISSION_DIR}/xcresult"
  rm -rf "${bundle}"
  xcodebuild test -project SightlineIOS/SightlineIOS.xcodeproj -scheme SightlineIOS \
    -destination "${IOS_DESTINATION}" -resultBundlePath "${bundle}/debug" &&
    xcodebuild test -configuration Release -project SightlineIOS/SightlineIOS.xcodeproj -scheme SightlineIOS \
      -destination "${IOS_DESTINATION}" -resultBundlePath "${bundle}/release" \
      -only-testing:SightlineIOSTests/TrackingPipelineTests/testPoseSendPathAllocatesNothing
}

suites=("$@")
[ ${#suites[@]} -gt 0 ] || suites=(rust python blender ios)

status=0
for s in "${suites[@]}"; do
  declare -F "suite_${s}" > /dev/null || { echo "Unknown suite: ${s} (rust, python, blender, ios)" >&2; exit 2; }
  log="${LOG_DIR}/${s}.log"
  start=$(date +%s)
  if "suite_${s}" > "${log}" 2>&1; then result=PASS; else result=FAIL; status=1; fi
  echo "${result} ${s} ($(( $(date +%s) - start )) s) log: ${log#"${ROOT}/"}"
done
exit "${status}"
