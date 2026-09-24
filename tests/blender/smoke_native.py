# SPDX-License-Identifier: GPL-3.0-or-later
"""Headless Blender check: the installed extension is enabled and imports `vcam_native`.

Run after installing the built extension zip into an isolated user dir:

    B=/Applications/Blender.app/Contents/MacOS/Blender
    export BLENDER_USER_RESOURCES=$(mktemp -d)
    "$B" --command extension build --source-dir BlenderAddOn --output-dir "$BLENDER_USER_RESOURCES"
    "$B" --command extension install-file -r user_default -e "$BLENDER_USER_RESOURCES"/vcam_blender-*.zip
    "$B" --background --factory-startup --python-exit-code 1 --python tests/blender/smoke_native.py

`--factory-startup` ignores saved prefs, so this script enables the add-on itself.
"""

import addon_utils
import bpy

MODULE = "bl_ext.user_default.vcam_blender"

addon_utils.enable(MODULE, default_set=True, handle_error=None)
assert MODULE in bpy.context.preferences.addons, f"{MODULE} not enabled"

import vcam_native  # noqa: E402  (importable only once the extension's wheels are installed)

version = vcam_native.version()
assert isinstance(version, str) and version, version
print(f"VCAM_NATIVE_OK {version} from {vcam_native.__file__}")
