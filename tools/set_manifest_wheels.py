# SPDX-License-Identifier: GPL-3.0-or-later
"""Set `platforms` and `wheels` in blender_manifest.toml to the wheels actually present.

Blender's `extension build` fails if any listed wheel is missing, so the committed
manifest lists only what a local macOS build produces, and CI runs this after
collecting the wheels from every OS:

    python tools/set_manifest_wheels.py BlenderAddOn/blender_manifest.toml BlenderAddOn/wheels
"""

import re
import sys
import tomllib
from pathlib import Path

# Wheel platform tag -> Blender platform id (see Blender's bl_pkg/cli/blender_ext.py).
PLATFORM_PATTERNS = (
    (re.compile(r"^macosx_\d+_\d+_arm64$"), "macos-arm64"),
    (re.compile(r"^macosx_\d+_\d+_x86_64$"), "macos-x64"),
    (re.compile(r"^(many|musl)linux(_\d+_\d+|\d+)_x86_64$"), "linux-x64"),
    (re.compile(r"^(many|musl)linux(_\d+_\d+|\d+)_aarch64$"), "linux-arm64"),
    (re.compile(r"^win_amd64$"), "windows-x64"),
    (re.compile(r"^win_arm64$"), "windows-arm64"),
)


def blender_platform(wheel: Path) -> str:
    tag = wheel.stem.split("-")[-1]
    for pattern, platform in PLATFORM_PATTERNS:
        if pattern.match(tag):
            return platform
    raise SystemExit(f"unsupported wheel platform tag {tag!r} in {wheel.name}")


def toml_list(items: list[str]) -> str:
    if len(items) == 1:
        return f'["{items[0]}"]'
    return "[\n" + "".join(f'  "{item}",\n' for item in items) + "]"


def replace_key(text: str, key: str, value: str) -> str:
    pattern = re.compile(rf"^{key}\s*=\s*\[.*?\]", re.MULTILINE | re.DOTALL)
    text, count = pattern.subn(lambda _: f"{key} = {value}", text)
    if count != 1:
        raise SystemExit(f"expected exactly one top-level `{key} = [...]` in the manifest, found {count}")
    return text


def main() -> None:
    manifest, wheels_dir = Path(sys.argv[1]), Path(sys.argv[2])
    wheels = sorted(wheels_dir.glob("*.whl"))
    if not wheels:
        raise SystemExit(f"no wheels in {wheels_dir}")
    platforms = sorted({blender_platform(w) for w in wheels})
    rel = [f"./{w.relative_to(manifest.parent).as_posix()}" for w in wheels]

    text = manifest.read_text(encoding="utf-8")
    text = replace_key(text, "platforms", toml_list(platforms))
    text = replace_key(text, "wheels", toml_list(rel))
    parsed = tomllib.loads(text)
    assert parsed["platforms"] == platforms and parsed["wheels"] == rel, parsed
    manifest.write_text(text, encoding="utf-8")
    print(f"platforms = {platforms}")
    print(f"wheels = {rel}")


main()
