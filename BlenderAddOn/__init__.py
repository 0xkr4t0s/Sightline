# SPDX-License-Identifier: GPL-3.0-or-later
# VCam Blender - Real-time virtual camera tracking receiver

# Submodules import bpy, so load them lazily; this lets pytest import the
# package outside Blender.


def register():
    from . import operators, ui, properties
    from .core import session

    session.register(__package__)
    properties.register()
    operators.register()
    ui.register()


def unregister():
    from . import operators, ui, properties
    from .core import session

    # First: stop threads and close sockets before anything they report to goes away
    # (NFR-REL-002).
    session.unregister()
    ui.unregister()
    operators.unregister()
    properties.unregister()
