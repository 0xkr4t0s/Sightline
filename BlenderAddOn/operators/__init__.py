# SPDX-License-Identifier: GPL-3.0-or-later

import bpy
from .session import VCAM_OT_session_start, VCAM_OT_session_stop
from .tracking_receiver import VCAM_OT_start_tracking, VCAM_OT_stop_tracking

_classes = (
    VCAM_OT_start_tracking,
    VCAM_OT_stop_tracking,
    VCAM_OT_session_start,
    VCAM_OT_session_stop,
)


def register():
    for cls in _classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_classes):
        bpy.utils.unregister_class(cls)
