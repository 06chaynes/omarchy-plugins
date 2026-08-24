#!/usr/bin/env python3
"""Crop a screenshot of the bar to the Omaherd widget alone.

    barcrop.py IN OUT RIGHT_EDGE [HEIGHT]

The widget is right-aligned in the bar, so its right edge stays put while
its left edge moves as dots come and go. Starting from RIGHT_EDGE, the
widget's left edge is the sheep: the widest run of non-background columns
within the widget's possible width. Neighbouring widgets never get in.
"""

from __future__ import annotations

import subprocess
import sys


def main() -> int:
    source, target, right = sys.argv[1], sys.argv[2], int(sys.argv[3])
    height = int(sys.argv[4]) if len(sys.argv) > 4 else 26
    span = 110
    left = right - span
    raw = subprocess.run(
        ["magick", source, "-crop", f"{span}x{height}+{left}+0", "+repage", "-depth", "8", "-compress", "none", "ppm:-"],
        capture_output=True, check=True,
    ).stdout.split()
    width, rows = int(raw[1]), int(raw[2])
    values = list(map(int, raw[4:4 + width * rows * 3]))
    pixels = [tuple(values[i:i + 3]) for i in range(0, len(values), 3)]
    background = pixels[2 * width + 1]

    def content(x: int) -> bool:
        return any(max(abs(a - b) for a, b in zip(pixels[y * width + x], background)) > 40 for y in range(4, rows - 4))

    runs: list[tuple[int, int]] = []
    start = None
    for x, filled in enumerate([content(x) for x in range(width)] + [False]):
        if filled and start is None:
            start = x
        if not filled and start is not None:
            runs.append((start, x - 1))
            start = None
    if not runs:
        raise SystemExit("no widget found")
    sheep = max(runs, key=lambda run: run[1] - run[0])
    crop_left = max(0, sheep[0] - 5)
    subprocess.run(
        ["magick", source, "-crop", f"{span - crop_left}x{height}+{left + crop_left}+0", "+repage", "-scale", "400%", target],
        check=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
