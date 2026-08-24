#!/usr/bin/env python3
"""Crop a screenshot to the card the shell framed in its accent color.

    framecrop.py IN OUT WxH+X+Y

Looks inside the region for the frame: the color is sampled as the first
saturated pixel on the region's middle row, the edges are the outermost
columns and rows that carry a long unbroken run of that color. Everything
outside the frame — other windows, other people's names — is discarded.
"""

from __future__ import annotations

import os
import subprocess
import sys


def read_region(path: str, region: str) -> tuple[int, int, list[tuple[int, int, int]]]:
    raw = subprocess.run(
        ["magick", path, "-crop", region, "+repage", "-depth", "8", "-compress", "none", "ppm:-"],
        capture_output=True, check=True,
    ).stdout
    parts = raw.split()
    assert parts[0] == b"P3"
    width, height = int(parts[1]), int(parts[2])
    values = list(map(int, parts[4:4 + width * height * 3]))
    pixels = [tuple(values[i:i + 3]) for i in range(0, len(values), 3)]
    return width, height, pixels


def saturated(px: tuple[int, int, int]) -> bool:
    return max(px) - min(px) > 90


def close(a: tuple[int, int, int], b: tuple[int, int, int], tolerance: int = 36) -> bool:
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def longest_run(flags: list[bool]) -> int:
    best = run = 0
    for flag in flags:
        run = run + 1 if flag else 0
        best = max(best, run)
    return best


def find_frame(width: int, height: int, pixels: list[tuple[int, int, int]]) -> tuple[int, int, int, int]:
    # Candidate frame colors: saturated pixels met on a few sample rows. The
    # winner is the one that draws the longest vertical line — a frame edge —
    # which a link, an icon or a dot behind the card never does.
    candidates: list[tuple[int, int, int]] = []
    for fraction in (0.15, 0.3, 0.5, 0.7, 0.85):
        y = min(height - 1, int(height * fraction))
        for x in range(width):
            px = pixels[y * width + x]
            if saturated(px) and not any(close(px, c, 24) for c in candidates):
                candidates.append(px)
    if not candidates:
        raise SystemExit("no frame color found")
    best = None
    for color in candidates:
        mask = [close(px, color) for px in pixels]
        columns = [longest_run([mask[y * width + x] for y in range(height)]) for x in range(width)]
        tallest = max(columns)
        if best is None or tallest > best[0]:
            best = (tallest, color, mask, columns)
    tallest, color, mask, columns = best
    rows = [longest_run(mask[y * width:(y + 1) * width]) for y in range(height)]
    vertical = [x for x, run in enumerate(columns) if run >= tallest * 0.8]
    widest = max(rows)
    horizontal = [y for y, run in enumerate(rows) if run >= widest * 0.8]
    if os.environ.get("FRAMECROP_DEBUG"):
        print(f"candidates={candidates} color={color} tallest={tallest} widest={widest} "
              f"v={min(vertical)}..{max(vertical)} h={min(horizontal)}..{max(horizontal)}", file=sys.stderr)
    if tallest < 40 or widest < 120:
        raise SystemExit("no frame edges found")
    return min(vertical), min(horizontal), max(vertical), max(horizontal)


def main() -> int:
    source, target, region = sys.argv[1:4]
    width, height, pixels = read_region(source, region)
    left, top, right, bottom = find_frame(width, height, pixels)
    geometry = f"{right - left + 1}x{bottom - top + 1}+{left}+{top}"
    subprocess.run(["magick", source, "-crop", region, "+repage", "-crop", geometry, "+repage", target], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
