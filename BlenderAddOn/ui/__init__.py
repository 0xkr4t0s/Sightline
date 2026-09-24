# SPDX-License-Identifier: GPL-3.0-or-later

import bpy
from .panels import VCAM_PT_main_panel, VCAM_PT_status_panel

_classes = (
    VCAM_PT_main_panel,
    VCAM_PT_status_panel,
)


def register():
    for cls in _classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_classes):
        bpy.utils.unregister_class(cls)
