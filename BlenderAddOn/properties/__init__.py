# SPDX-License-Identifier: GPL-3.0-or-later

import bpy
from .scene_props import VCamProperties

_classes = (
    VCamProperties,
)


def register():
    for cls in _classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.vcam_props = bpy.props.PointerProperty(type=VCamProperties)


def unregister():
    del bpy.types.Scene.vcam_props
    for cls in reversed(_classes):
        bpy.utils.unregister_class(cls)
