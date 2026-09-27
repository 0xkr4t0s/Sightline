# Shared settings for tools/mission/*.sh. Source it; don't run it.
# Every value can be overridden from the environment.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MISSION_DIR="${MISSION_DIR:-${ROOT}/.mission}"
LOG_DIR="${MISSION_DIR}/logs"

BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
# Blender's bundled Python 3.13: the interpreter the vcam_native wheel must target.
BLENDER_PY="${BLENDER_PY:-$(ls /Applications/Blender.app/Contents/Resources/*/python/bin/python3.13 2>/dev/null | head -1)}"
# The system default developer dir is Command Line Tools, which can't run xcodebuild.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.0.0.app/Contents/Developer}"
IOS_DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"

VENV="${ROOT}/.venv.nosync"
FAKE_IPHONE="${FAKE_IPHONE:-${ROOT}/native/target.nosync/debug/vcam-fake-iphone}"
# An isolated Blender user dir, so the mission never touches the owner's installed extensions.
export BLENDER_USER_RESOURCES="${BLENDER_USER_RESOURCES:-${MISSION_DIR}/blender-user}"
export FAKE_IPHONE

mkdir -p "${LOG_DIR}"
