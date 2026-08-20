#!/usr/bin/env python3
"""Generates every app-icon asset from the single source of truth.

Source: assets/iCam.ico
Outputs: the iOS app icon set and the Windows / MSIX logo assets.

Run from the repository root:  python tools/generate-icons.py
"""
from __future__ import annotations

import json
import pathlib
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.exit("Pillow is required:  pip install Pillow")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "iCam.ico"

IOS_ICONSET = ROOT / "ios" / "iCam" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
WINDOWS_ASSETS = ROOT / "windows" / "iCam.App" / "Assets"

# The artwork's own body colour. iOS masks the icon to a squircle and forbids
# alpha, so the transparent corners are filled with this rather than with white:
# a white corner would show as a pale rim outside the black outline.
BODY = (252, 246, 237, 255)


def load_source() -> Image.Image:
    if not SOURCE.exists():
        sys.exit(f"missing source icon: {SOURCE}")
    image = Image.open(SOURCE)
    # Pick the largest frame the .ico actually contains.
    if hasattr(image, "ico"):
        largest = max(image.ico.sizes())
        image.size = largest
        image = image.ico.getimage(largest)
    return image.convert("RGBA")


def scaled(source: Image.Image, size: int) -> Image.Image:
    return source.resize((size, size), Image.LANCZOS)


def flattened(image: Image.Image, background=BODY) -> Image.Image:
    canvas = Image.new("RGBA", image.size, background)
    canvas.alpha_composite(image)
    return canvas.convert("RGB")


def write_ios(source: Image.Image) -> None:
    IOS_ICONSET.mkdir(parents=True, exist_ok=True)
    # Xcode 14 and later take one 1024 pt universal image for every slot.
    flattened(scaled(source, 1024)).save(IOS_ICONSET / "icon-1024.png", "PNG")

    contents = {
        "images": [
            {"filename": "icon-1024.png", "idiom": "universal",
             "platform": "ios", "size": "1024x1024"}
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (IOS_ICONSET / "Contents.json").write_text(
        json.dumps(contents, indent=2) + "\n", encoding="utf-8")
    print(f"iOS   -> {IOS_ICONSET.relative_to(ROOT)}")


def write_windows(source: Image.Image) -> None:
    WINDOWS_ASSETS.mkdir(parents=True, exist_ok=True)

    # Square logos, at scale 100 and scale 200, keeping alpha so the tile's own
    # background shows through the rounded corners.
    squares = {
        "StoreLogo": 50,
        "Square44x44Logo": 44,
        "SmallTile": 71,
        "Square150x150Logo": 150,
        "LargeTile": 310,
        "LockScreenLogo": 24,
    }
    for name, base in squares.items():
        for scale in (100, 200):
            size = round(base * scale / 100)
            scaled(source, size).save(
                WINDOWS_ASSETS / f"{name}.scale-{scale}.png", "PNG")
        scaled(source, base).save(WINDOWS_ASSETS / f"{name}.png", "PNG")

    # Unplated target sizes: what Windows shows in the taskbar, Alt-Tab and the
    # Start search results.
    for size in (16, 24, 32, 48, 256):
        icon = scaled(source, size)
        icon.save(WINDOWS_ASSETS / f"Square44x44Logo.targetsize-{size}.png", "PNG")
        icon.save(WINDOWS_ASSETS
                  / f"Square44x44Logo.targetsize-{size}_altform-unplated.png", "PNG")

    # Wide tile and splash: the square artwork centred on its own body colour.
    for name, (width, height) in {"Wide310x150Logo": (310, 150),
                                  "SplashScreen": (620, 300)}.items():
        for scale in (100, 200):
            canvas = Image.new("RGBA", (round(width * scale / 100),
                                        round(height * scale / 100)), BODY)
            art = scaled(source, round(canvas.height * 0.72))
            canvas.alpha_composite(art,
                                   ((canvas.width - art.width) // 2,
                                    (canvas.height - art.height) // 2))
            canvas.save(WINDOWS_ASSETS / f"{name}.scale-{scale}.png", "PNG")
        canvas = Image.new("RGBA", (width, height), BODY)
        art = scaled(source, round(height * 0.72))
        canvas.alpha_composite(art, ((width - art.width) // 2,
                                     (height - art.height) // 2))
        canvas.save(WINDOWS_ASSETS / f"{name}.png", "PNG")

    # The executable's own icon, with every size Windows asks for.
    scaled(source, 256).save(
        WINDOWS_ASSETS / "iCam.ico", "ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64),
               (128, 128), (256, 256)])
    print(f"Win   -> {WINDOWS_ASSETS.relative_to(ROOT)}")


def main() -> None:
    source = load_source()
    print(f"source {SOURCE.relative_to(ROOT)} at {source.size[0]}x{source.size[1]}")
    if source.size[0] < 1024:
        print("note: the source is smaller than 1024 px, so the iOS icon is upscaled.\n"
              "      Drop a 1024 px PNG or an SVG export in as assets/iCam.ico's source\n"
              "      to get a crisp App Store icon.")
    write_ios(source)
    write_windows(source)


if __name__ == "__main__":
    main()
