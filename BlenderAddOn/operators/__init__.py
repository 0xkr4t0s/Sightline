# SPDX-License-Identifier: GPL-3.0-or-later

import bpy
from .session import (
    VCAM_OT_latency_report_save,
    VCAM_OT_origin_clear,
    VCAM_OT_origin_set,
    VCAM_OT_pairing_cancel,
    VCAM_OT_pairing_start,
    VCAM_OT_session_start,
    VCAM_OT_session_stop,
)

_classes = (
    VCAM_OT_session_start,
    VCAM_OT_session_stop,
    VCAM_OT_pairing_start,
    VCAM_OT_pairing_cancel,
    VCAM_OT_origin_set,
    VCAM_OT_origin_clear,
    VCAM_OT_latency_report_save,
)


def register():
    for cls in _classes:
        bpy.utils.register_class(cls)


def unregister():
    for cls in reversed(_classes):
        bpy.utils.unregister_class(cls)
