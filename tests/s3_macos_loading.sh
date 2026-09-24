#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Spike S-3a (SRS XP-004): does Blender load the extension's native module on macOS when the
# extension was downloaded (quarantined), and with which signature states?
#
# Usage: tests/s3_macos_loading.sh [--gui]
#   Needs the wheel in BlenderAddOn/wheels (see docs/LOOP_LOG.md iteration 5 for the maturin command).
#   --gui also runs each import in a GUI Blender (a window opens briefly). Each GUI run is
#   killed after 60 s if it hangs. Note: when Gatekeeper evaluates a quarantined .so it may show
#   a dialog on the desktop even for --background runs (syspolicyd logs "Prompt shown").
#
# Prints one "S3_RESULT <scenario> <mode> <PASS|FAIL> <detail>" line per run.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
GUI=0; [ "${1:-}" = "--gui" ] && GUI=1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# macOS has no GNU `timeout`: run "$@", SIGKILL it after $1 seconds, return its status.
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local watchdog=$!
  wait "$pid"; local st=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  return "$st"
}

# A Safari-style quarantine value: flags 0083, current time, agent, random UUID.
quarantine_value() { printf '0083;%x;Safari;%s' "$(date +%s)" "$(uuidgen)"; }

"$BLENDER" --command extension build --source-dir "$ROOT/BlenderAddOn" --output-dir "$WORK" >/dev/null 2>&1
ZIP="$(ls "$WORK"/vcam_blender-*.zip)" || { echo "S3_ERROR build failed"; exit 1; }

cat > "$WORK/gui_import.py" <<'EOF'
import bpy, sys, traceback
def run():
    try:
        exec(open(sys.argv[sys.argv.index("--") + 1]).read(), {"__name__": "__main__"})
    except BaseException:
        traceback.print_exc()
        print("S3_GUI_IMPORT_FAILED", flush=True)
    bpy.ops.wm.quit_blender()
bpy.app.timers.register(run, first_interval=1.0)
EOF

# $1 scenario name; $2 function that mutates the installed tree (receives the .so path).
scenario() {
  local name="$1" mutate="$2" mode user so out status
  for mode in background gui; do
    [ "$mode" = gui ] && [ "$GUI" = 0 ] && continue
    user="$WORK/user-$name-$mode"; mkdir -p "$user"
    local zip_copy="$WORK/$name-$mode.zip"; cp "$ZIP" "$zip_copy"
    [ "$name" != baseline ] && xattr -w com.apple.quarantine "$(quarantine_value)" "$zip_copy"
    BLENDER_USER_RESOURCES="$user" "$BLENDER" --command extension install-file -r user_default -e "$zip_copy" >/dev/null 2>&1
    so="$(ls "$user"/extensions/.local/lib/python3.*/site-packages/vcam_native/*.so 2>/dev/null)"
    if [ -z "$so" ]; then echo "S3_RESULT $name $mode FAIL not-installed"; continue; fi
    local inherited; inherited="$(xattr -p com.apple.quarantine "$so" 2>/dev/null || echo none)"
    $mutate "$so"
    local sig; sig="$(codesign -dv "$so" 2>&1 | grep -oE 'flags=0x[0-9a-f]+\([^)]*\)|not signed at all' | head -1)"
    local q; q="$(xattr -p com.apple.quarantine "$so" 2>/dev/null | cut -d';' -f1 || true)"
    if [ "$mode" = background ]; then
      out="$(BLENDER_USER_RESOURCES="$user" "$BLENDER" --background --factory-startup --python-exit-code 1 \
        --python "$ROOT/tests/blender/smoke_native.py" 2>&1)"; status=$?
    else
      out="$(BLENDER_USER_RESOURCES="$user" with_timeout 60 "$BLENDER" --factory-startup \
        --python "$WORK/gui_import.py" -- "$ROOT/tests/blender/smoke_native.py" 2>&1)"; status=$?
    fi
    local detail="exit=$status inherited_quarantine=${inherited%%;*} so_quarantine=${q:-none} sig=${sig:-?}"
    if echo "$out" | grep -q VCAM_NATIVE_OK; then
      echo "S3_RESULT $name $mode PASS $detail"
    else
      echo "S3_RESULT $name $mode FAIL $detail :: $(echo "$out" | grep -E 'Error|error|rror:|Killed|FAILED' | head -2 | tr '\n' ' ')"
    fi
  done
}

keep() { :; }
quarantine_so() { xattr -w com.apple.quarantine "$(quarantine_value)" "$1"; }
unsigned_quarantined() { codesign --remove-signature "$1" && quarantine_so "$1"; }
adhoc_quarantined() { codesign --force -s - "$1" >/dev/null 2>&1 && quarantine_so "$1"; }

scenario baseline keep                          # plain install, no quarantine anywhere
scenario zip_quarantined keep                   # downloaded zip; Blender extracts it
scenario so_quarantined quarantine_so           # worst case: the .so itself carries quarantine
scenario unsigned_so_quarantined unsigned_quarantined
scenario adhoc_resigned_so_quarantined adhoc_quarantined
