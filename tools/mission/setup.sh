#!/usr/bin/env bash
# Prepare a fresh checkout or worktree for local checks and mission work:
#   1. the project venv (.venv.nosync) with the pytest and maturin versions CI uses;
#   2. the vcam_native wheel for Blender's Python 3.13, in BlenderAddOn/wheels/;
#   3. the fake iPhone (debug build) used by the headless Blender tests;
#   4. the extension zip, installed into an isolated Blender user dir under .mission/.
# Output goes to .mission/logs/setup.log. Re-run it after changing native/ or BlenderAddOn/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "${ROOT}"

LOG="${LOG_DIR}/setup.log"
: > "${LOG}"
step() { echo "== $*" | tee -a "${LOG}"; }
run() { "$@" >> "${LOG}" 2>&1 || { echo "FAILED: $* (see ${LOG})" >&2; tail -30 "${LOG}" >&2; exit 1; }; }

[ -x "${BLENDER}" ] || { echo "Blender not found at ${BLENDER} (set BLENDER)" >&2; exit 1; }
[ -n "${BLENDER_PY}" ] || { echo "Blender's python3.13 not found (set BLENDER_PY)" >&2; exit 1; }

step "venv"
if [ ! -x "${VENV}/bin/python" ]; then
  run python3 -m venv "${VENV}"
fi
run "${VENV}/bin/python" -m pip install --quiet pytest==9.1.1 maturin==1.15.0

# Debug profile on purpose: the local macOS 27 linker can leave a release .so with a string pool
# dyld rejects ("mis-aligned LINKEDIT string pool", docs/LOOP_LOG.md). CI builds release wheels.
step "vcam_native wheel (debug) for ${BLENDER_PY}"
rm -f BlenderAddOn/wheels/vcam_native-*.whl
run "${VENV}/bin/maturin" build -m native/vcam-py/Cargo.toml -o BlenderAddOn/wheels -i "${BLENDER_PY}"

step "wheel imports in Blender's Python"
check_dir="$(mktemp -d)"
run unzip -q -o "$(ls BlenderAddOn/wheels/vcam_native-*.whl | head -1)" -d "${check_dir}"
run env PYTHONPATH="${check_dir}" "${BLENDER_PY}" -c "import vcam_native; print('vcam_native', vcam_native.version())"
rm -rf "${check_dir}"

step "fake iPhone"
run cargo build --manifest-path native/Cargo.toml -p vcam-fake-iphone

step "extension zip -> ${BLENDER_USER_RESOURCES}"
rm -rf "${MISSION_DIR}/dist" "${BLENDER_USER_RESOURCES}"
mkdir -p "${MISSION_DIR}/dist" "${BLENDER_USER_RESOURCES}"
run "${BLENDER}" --command extension build --source-dir BlenderAddOn --output-dir "${MISSION_DIR}/dist"
run "${BLENDER}" --command extension install-file -r user_default -e "$(ls "${MISSION_DIR}"/dist/vcam_blender-*.zip | head -1)"

step "done"
