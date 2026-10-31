#!/usr/bin/env python3
"""Resize the Framekeep app icon master into the asset catalog."""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts" / "framekeep-icon-source.png"
OUT = ROOT / "Framekeep" / "Assets.xcassets" / "AppIcon.appiconset"
SIZES = (16, 32, 64, 128, 256, 512, 1024)


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"missing icon master: {SOURCE}")
    OUT.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        dest = OUT / f"icon_{size}.png"
        subprocess.run(
            ["sips", "-z", str(size), str(size), str(SOURCE), "--out", str(dest)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    print(f"wrote icons in {OUT}")


if __name__ == "__main__":
    main()
