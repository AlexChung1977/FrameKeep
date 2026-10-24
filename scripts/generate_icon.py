#!/usr/bin/env python3
"""Graphite + amber Framekeep app icon (no third-party deps)."""

from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Framekeep" / "Assets.xcassets" / "AppIcon.appiconset"


def png(w: int, h: int, pixel) -> bytes:
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(pixel(x, y, w, h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")


def icon_pixel(x: int, y: int, w: int, h: int) -> bytes:
    nx = (x + 0.5) / w
    ny = (y + 0.5) / h
    # graphite base
    r, g, b = 26, 28, 30
    # vignette
    dx = nx - 0.5
    dy = ny - 0.48
    dist = math.sqrt(dx * dx + dy * dy)
    glow = max(0.0, 1.0 - dist * 1.7)
    r = min(255, int(r + 224 * 0.18 * glow))
    g = min(255, int(g + 168 * 0.18 * glow))
    b = min(255, int(b + 74 * 0.18 * glow))

    # rounded-rect frame
    inset = 0.18
    frame = 0.045
    inside_x = inset < nx < 1 - inset
    inside_y = inset < ny < 1 - inset
    in_outer = (inset - frame) < nx < (1 - inset + frame) and (inset - frame) < ny < (1 - inset + frame)
    if in_outer and not (inside_x and inside_y):
        r, g, b = 224, 168, 74

    # amber disc (lens)
    cdx = nx - 0.5
    cdy = ny - 0.5
    cr = math.sqrt(cdx * cdx + cdy * cdy)
    if cr < 0.16:
        t = cr / 0.16
        r = int(224 * (1 - t * 0.15) + 26 * t * 0.15)
        g = int(168 * (1 - t * 0.15) + 28 * t * 0.15)
        b = int(74 * (1 - t * 0.15) + 30 * t * 0.15)
    elif 0.16 <= cr < 0.19:
        r, g, b = 224, 168, 74

    return bytes((r, g, b, 255))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    for size in sizes:
        (OUT / f"icon_{size}.png").write_bytes(png(size, size, icon_pixel))
    (OUT / "Contents.json").write_text(
        """{
  "images" : [
    { "idiom" : "mac", "size" : "16x16", "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16", "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""",
        encoding="utf-8",
    )
    print(f"wrote icons in {OUT}")


if __name__ == "__main__":
    main()
