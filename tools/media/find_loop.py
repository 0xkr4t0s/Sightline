#!/usr/bin/env python3
"""Find the frame range of a screen recording that loops most seamlessly.

The recording is resampled at the GIF's frame rate and shrunk to a small grey thumbnail per
frame. A loop from frame `start` up to (not including) frame `end` is seamless when frame `end`
looks like frame `start`, so that the GIF's first frame follows its last as if the recording went
on. Frames `start + 1` and `end + 1` are compared too, which rejects mirror-image matches where
the camera passes the same spot moving the other way.

Usage (from the repository root):
    python3 tools/media/find_loop.py RECORDING [--fps 12] [--min 6] [--max 10]

Prints `START END` (frame numbers at --fps) on stdout and the match quality on stderr.
"""

from __future__ import annotations

import argparse
import operator
import subprocess
import sys
from collections.abc import Sequence

THUMB_W, THUMB_H = 48, 22


def thumbnails(path: str, fps: float) -> list[bytes]:
    """Grey THUMB_W x THUMB_H frames of the recording, resampled at `fps` from its first frame."""
    out = subprocess.run(
        [
            "ffmpeg", "-v", "error", "-i", path,
            "-vf", f"fps={fps},scale={THUMB_W}:{THUMB_H}:flags=area,format=gray",
            "-f", "rawvideo", "-",
        ],
        capture_output=True,
        check=True,
    ).stdout  # fmt: skip
    size = THUMB_W * THUMB_H
    return [out[i : i + size] for i in range(0, len(out) - size + 1, size)]


def difference(a: bytes, b: bytes) -> int:
    return sum(map(abs, map(operator.sub, a, b)))


def best_loop(frames: Sequence[bytes], min_len: int, max_len: int) -> tuple[int, int, float]:
    """(start, end, mean per-pixel difference) of the best loop of min_len..max_len frames."""
    if min_len < 1 or max_len < min_len:
        raise ValueError("need 1 <= min_len <= max_len")
    best: tuple[int, int, float] | None = None
    pixels = 2 * len(frames[0]) if frames else 1
    for start in range(len(frames)):
        for end in range(start + min_len, min(start + max_len, len(frames) - 2) + 1):
            cost = difference(frames[start], frames[end]) + difference(frames[start + 1], frames[end + 1])
            if best is None or cost < best[2]:
                best = (start, end, cost)
    if best is None:
        raise ValueError(f"the recording has {len(frames)} frames, too few for a {min_len}-frame loop")
    return best[0], best[1], best[2] / pixels


def main(argv: Sequence[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("recording")
    p.add_argument("--fps", type=float, default=12.0, help="the GIF's frame rate (default 12)")
    p.add_argument("--min", type=float, default=6.0, help="shortest loop in seconds (default 6)")
    p.add_argument("--max", type=float, default=10.0, help="longest loop in seconds (default 10)")
    a = p.parse_args(argv)
    frames = thumbnails(a.recording, a.fps)
    try:
        start, end, mean = best_loop(frames, round(a.min * a.fps), int(a.max * a.fps))
    except ValueError as e:
        print(f"find_loop: {e}", file=sys.stderr)
        return 1
    print(
        f"find_loop: frames {start}..{end} of {len(frames)} ({(end - start) / a.fps:.2f} s), "
        f"mean difference {mean:.2f}/255",
        file=sys.stderr,
    )
    print(start, end)
    return 0


if __name__ == "__main__":
    sys.exit(main())
