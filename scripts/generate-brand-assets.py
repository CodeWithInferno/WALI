#!/usr/bin/env python3
"""Rebuild WALI's native assets from the owner's supplied raster artwork.

Requires Python 3, Pillow, NumPy, potrace 1.16, rsvg-convert, and macOS iconutil.
No font files, remote services, or application build tools are required.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path
from xml.etree import ElementTree

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / "Resources/Branding"
ASSETS = ROOT / "Resources/WALIAssets.xcassets"
PREVIEW = ROOT / "output/branding/wali-production"
BLUE = "#0037EE"
INK = "#18243D"
COLORS = {"blue": BLUE, "white": "#FFFFFF", "black": "#000000"}
SVG_NS = "http://www.w3.org/2000/svg"


def tool(name: str) -> str:
    executable = shutil.which(name)
    if executable:
        return executable
    homebrew = Path("/opt/homebrew/bin") / name
    if homebrew.exists():
        return str(homebrew)
    raise SystemExit(f"Missing required tool: {name}")


def run(*args: str | Path) -> None:
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def svg_document(width: float, height: float, body: str) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="{SVG_NS}" width="{width:g}" height="{height:g}" '
        f'viewBox="0 0 {width:g} {height:g}">\n{body}\n</svg>\n'
    )


def strip_namespaces(element: ElementTree.Element) -> None:
    element.tag = element.tag.rsplit("}", 1)[-1]
    for child in element:
        strip_namespaces(child)


def trace(mask: Image.Image, temporary: Path, name: str) -> tuple[str, int, int]:
    """Keep the original contour; discard only <=32 px islands/holes.

    Potrace fits cubic curves with 0.15 source-pixel optimization tolerance.
    The retained master contains real paths, never an embedded raster image.
    """
    bbox = mask.getbbox()
    if bbox is None:
        raise ValueError(f"No visible artwork in {name}")
    cropped = mask.crop(bbox)
    bitmap = temporary / f"{name}.pbm"
    # PBM black pixels are the foreground Potrace traces.
    cropped.point(lambda value: 0 if value else 255).convert("1").save(bitmap)
    vector = temporary / f"{name}.svg"
    run(tool("potrace"), bitmap, "--svg", "--output", vector,
        "--turdsize", "32", "--alphamax", "1", "--opttolerance", "0.15",
        "--unit", "100")
    root = ElementTree.parse(vector).getroot()
    group = root.find(f"{{{SVG_NS}}}g")
    if group is None:
        raise ValueError(f"Potrace produced no paths for {name}")
    strip_namespaces(group)
    group.attrib["fill"] = "currentColor"
    return ElementTree.tostring(group, encoding="unicode"), cropped.width, cropped.height


def glyph(group: str, source_width: int, source_height: int,
          x: float, y: float, width: float, color: str) -> str:
    scale = width / source_width
    return f'<g color="{color}" transform="translate({x:g} {y:g}) scale({scale:.9f})">{group}</g>'


def rasterize(svg: Path, png: Path, width: int, height: int) -> None:
    png.parent.mkdir(parents=True, exist_ok=True)
    run(tool("rsvg-convert"), "--width", str(width), "--height", str(height),
        "--output", png, svg)


def make_variants(mark: tuple[str, int, int], word: tuple[str, int, int]) -> None:
    mark_group, mark_width, mark_height = mark
    word_group, word_width, word_height = word
    for name, color in COLORS.items():
        for kind, group, width, height in (
            ("mark", mark_group, mark_width, mark_height),
            ("wordmark", word_group, word_width, word_height),
        ):
            target_height = round(1024 * height / width)
            source = BRANDING / f"wali-{kind}-{name}.svg"
            source.write_text(svg_document(1024, target_height,
                glyph(group, width, height, 0, 0, 1024, color)))
            rasterize(source, source.with_suffix(".png"), 1024, target_height)

        # The stacked proportions come directly from the supplied light lockup.
        stacked = glyph(mark_group, mark_width, mark_height, 0, 0, 1024, color)
        stacked += glyph(word_group, word_width, word_height, 240, 622, 544, color)
        source = BRANDING / f"wali-lockup-stacked-{name}.svg"
        source.write_text(svg_document(1024, 740, stacked))
        rasterize(source, source.with_suffix(".png"), 1024, 740)

        horizontal = glyph(mark_group, mark_width, mark_height, 0, 8, 420, color)
        horizontal += glyph(word_group, word_width, word_height, 512, 59, 512, color)
        source = BRANDING / f"wali-lockup-horizontal-{name}.svg"
        source.write_text(svg_document(1024, 226, horizontal))
        rasterize(source, source.with_suffix(".png"), 1024, 226)


def make_app_icon(mark: tuple[str, int, int], temporary: Path) -> None:
    group, width, height = mark
    body = '''<defs>
  <linearGradient id="tile" x1="0" y1="0" x2="0.72" y2="1">
    <stop offset="0" stop-color="#2464FA"/>
    <stop offset="0.54" stop-color="#1245D8"/>
    <stop offset="1" stop-color="#082D9D"/>
  </linearGradient>
  <linearGradient id="edge" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.30"/>
    <stop offset="0.40" stop-color="#FFFFFF" stop-opacity="0.02"/>
    <stop offset="1" stop-color="#071B66" stop-opacity="0.20"/>
  </linearGradient>
  <filter id="shadow" x="-0.2" y="-0.2" width="1.4" height="1.5">
    <feGaussianBlur stdDeviation="15"/>
  </filter>
</defs>
<rect x="100" y="114" width="824" height="824" rx="184" fill="#071C60" opacity="0.22" filter="url(#shadow)"/>
<rect x="100" y="100" width="824" height="824" rx="184" fill="url(#tile)"/>
<rect x="101" y="101" width="822" height="822" rx="183" fill="none" stroke="url(#edge)" stroke-width="2"/>
'''
    mark_render_width = 634
    mark_render_height = mark_render_width * height / width
    body += glyph(group, width, height, (1024 - mark_render_width) / 2,
                  (1024 - mark_render_height) / 2 + 4, mark_render_width, "#FFFFFF")
    source = BRANDING / "app-icon.svg"
    source.write_text(svg_document(1024, 1024, body))
    rasterize(source, BRANDING / "app-icon-1024.png", 1024, 1024)
    iconset = temporary / "WALI.iconset"
    iconset.mkdir()
    destination = ASSETS / "AppIcon.appiconset"
    destination.mkdir(parents=True, exist_ok=True)
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            filename = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            # Render each size from vector geometry, never enlarge a raster.
            rasterize(source, destination / filename, pixels, pixels)
            shutil.copyfile(destination / filename, iconset / filename)
            images.append({"filename": filename, "idiom": "mac",
                           "scale": f"{scale}x", "size": f"{size}x{size}"})
    write_json(destination / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})
    run(tool("iconutil"), "--convert", "icns", "--output", BRANDING / "WALI.icns", iconset)
    shutil.copyfile(BRANDING / "WALI.icns", BRANDING / "WALI-Volume.icns")


def make_imagesets(mark: tuple[str, int, int], temporary: Path) -> None:
    write_json(ASSETS / "Contents.json", {"info": {"author": "xcode", "version": 1}})
    group, width, height = mark
    for asset_name, points, inset, color, intent in (
        ("WALIMark", (128, 64), 0.0, BLUE, "original"),
        ("WALIMenuBar", (24, 14), 1.0, "#000000", "template"),
    ):
        target = ASSETS / f"{asset_name}.imageset"
        target.mkdir(parents=True, exist_ok=True)
        glyph_width = points[0] - inset * 2
        glyph_height = glyph_width * height / width
        source = temporary / f"{asset_name}.svg"
        source.write_text(svg_document(*points, glyph(group, width, height, inset,
            (points[1] - glyph_height) / 2, glyph_width, color)))
        images = []
        for scale in (1, 2):
            filename = f"{asset_name}{'@2x' if scale == 2 else ''}.png"
            rasterize(source, target / filename, points[0] * scale, points[1] * scale)
            images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x"})
        write_json(target / "Contents.json", {"images": images,
            "info": {"author": "xcode", "version": 1},
            "properties": {"template-rendering-intent": intent}})


def font(size: int) -> ImageFont.FreeTypeFont:
    # Render packaging copy using the local Mac's system face. No fonts ship.
    return ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)


def draw_centered(draw: ImageDraw.ImageDraw, text: str, center: tuple[float, float],
                  size: int, fill: str) -> None:
    draw.text(center, text, anchor="mm", font=font(size), fill=fill)


def make_dmg(mark: tuple[str, int, int], word: tuple[str, int, int], temporary: Path) -> None:
    scale, width, height = 2, 1320, 880
    yy, xx = np.mgrid[0:height, 0:width]
    wash = np.exp(-(((xx - 1100) / 900) ** 2 + ((yy - 900) / 700) ** 2))
    background = np.empty((height, width, 3), dtype=np.uint8)
    for channel, (base, tint) in enumerate(((249, 234), (250, 240), (252, 253))):
        background[:, :, channel] = np.rint(base * (1 - wash * .75) + tint * wash * .75)
    image = Image.fromarray(background).convert("RGBA")
    draw = ImageDraw.Draw(image)
    draw_centered(draw, "Install WALI", (330 * scale, 75 * scale),
                  24 * scale, INK)
    draw_centered(draw, "Drag the app into Applications to get started.",
                  (330 * scale, 111 * scale), 14 * scale, "#5C6780")
    # Finder positions the real .app and Applications folder at these centers.
    # Do not draw their icons, backgrounds, or labels into the artwork.
    draw.line([(270 * scale, 235 * scale), (390 * scale, 235 * scale)],
              fill="#9BAECF", width=2 * scale)
    draw.line([(383 * scale, 228 * scale), (390 * scale, 235 * scale),
               (383 * scale, 242 * scale)], fill="#9BAECF", width=2 * scale)
    draw_centered(draw, "Then open WALI from Applications.", (330 * scale, 374 * scale),
                  13 * scale, "#66748C")
    image.convert("RGB").save(BRANDING / "dmg-background@2x.png")
    image.convert("RGB").resize((660, 440), Image.Resampling.LANCZOS).save(BRANDING / "dmg-background.png")


def make_contact_sheet(applications_icon_path: Path | None = None) -> None:
    canvas = Image.new("RGB", (1600, 1420), "#F3F5F9")
    draw = ImageDraw.Draw(canvas)
    draw.text((64, 45), "WALI / Production identity", font=font(32), fill=INK)
    draw.text((64, 91), "Supplied ribbon mark · native app icon · adaptive menu symbol", font=font(18), fill="#69738A")
    icon = Image.open(BRANDING / "app-icon-1024.png").convert("RGBA")
    canvas.paste(icon.resize((430, 430), Image.Resampling.LANCZOS), (45, 145),
                 icon.resize((430, 430), Image.Resampling.LANCZOS))
    draw.text((80, 577), "App icon", font=font(20), fill=INK)
    for x, name, surface in ((550, "blue", "#FFFFFF"), (880, "white", "#163BBB"),
                              (1210, "black", "#FFFFFF")):
        draw.rounded_rectangle((x, 196, x + 280, 460), 24, fill=surface)
        mark = Image.open(BRANDING / f"wali-mark-{name}.png").convert("RGBA")
        mark.thumbnail((210, 130), Image.Resampling.LANCZOS)
        canvas.paste(mark, (x + (280-mark.width)//2, 272), mark)
        draw.text((x, 480), name.capitalize(), font=font(18), fill=INK)
    draw.text((550, 558), "Native sizes", font=font(20), fill=INK)
    x = 550
    for pixels in (16, 32, 64, 128):
        filename = "icon_32x32@2x.png" if pixels == 64 else f"icon_{pixels}x{pixels}.png"
        sample = Image.open(ASSETS / "AppIcon.appiconset" / filename).convert("RGBA")
        canvas.paste(sample, (x, 605 + (128-pixels)//2), sample)
        draw.text((x, 750), f"{pixels} px", font=font(15), fill="#69738A")
        x += pixels + 42
    draw.text((1190, 558), "Menu bar · 1× / 2×", font=font(20), fill=INK)
    for y, background, color in ((605, "#E9EEF7", (0, 0, 0)), (664, "#23304D", (255, 255, 255))):
        draw.rounded_rectangle((1190, y, 1490, y+42), 9, fill=background)
        for px, scale in ((1212, 1), (1270, 2)):
            path = ASSETS / "WALIMenuBar.imageset" / f"WALIMenuBar{'@2x' if scale == 2 else ''}.png"
            template = Image.open(path).convert("RGBA")
            tinted = Image.new("RGB", template.size, color)
            canvas.paste(tinted, (px, y + (42-template.height)//2), template.getchannel("A"))
    draw.text((64, 830), "Installer / assembled Finder preview", font=font(22), fill=INK)
    dmg = Image.open(BRANDING / "dmg-background.png").convert("RGBA")
    app_preview = icon.resize((128, 128), Image.Resampling.LANCZOS)
    dmg.alpha_composite(app_preview, (180 - 64, 235 - 64))
    # A review composite must show the real installation targets. The native
    # folder image is used only here, never copied into shipping artwork.
    applications_icon_path = applications_icon_path or Path(
        "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
    )
    folder = Image.open(applications_icon_path).convert("RGBA")
    folder.thumbnail((128, 128), Image.Resampling.LANCZOS)
    dmg.alpha_composite(folder, (480 - folder.width // 2, 235 - folder.height // 2))
    installer_draw = ImageDraw.Draw(dmg)
    draw_centered(installer_draw, "WALI", (180, 316), 14, INK)
    draw_centered(installer_draw, "Applications", (480, 316), 14, INK)
    canvas.paste(dmg, (64, 884))
    # The adjacent lockup makes the source wordmark reviewable independently.
    lockup = Image.open(BRANDING / "wali-lockup-stacked-blue.png").convert("RGBA")
    lockup.thumbnail((490, 360), Image.Resampling.LANCZOS)
    canvas.paste(lockup, (885, 935), lockup)
    draw.text((925, 1320), "Original wordmark, traced from supplied artwork", font=font(16), fill="#69738A")
    PREVIEW.mkdir(parents=True, exist_ok=True)
    dmg.convert("RGB").save(PREVIEW / "installer-preview.png")
    canvas.save(PREVIEW / "contact-sheet.png")


def validate(mark_mask: Image.Image, mark: tuple[str, int, int], temporary: Path) -> dict[str, object]:
    """Check format/dimensions/alpha and quantify source silhouette retention."""
    _, width, height = mark
    validation_image = temporary / "mark-native-size.png"
    rasterize(BRANDING / "wali-mark-black.svg", validation_image, width, height)
    original = np.asarray(mark_mask.crop(mark_mask.getbbox())) >= 128
    traced = np.asarray(Image.open(validation_image).convert("RGBA"))[:, :, 3] >= 128
    intersection = int(np.logical_and(original, traced).sum())
    union = int(np.logical_or(original, traced).sum())
    iou = intersection / union
    if iou < .995:
        raise ValueError(f"Trace changed the supplied silhouette too much: IoU {iou:.6f}")
    slots = json.loads((ASSETS / "AppIcon.appiconset/Contents.json").read_text())["images"]
    for slot in slots:
        pixels = int(slot["size"].split("x")[0]) * int(slot["scale"][0])
        path = ASSETS / "AppIcon.appiconset" / slot["filename"]
        image = Image.open(path)
        assert image.size == (pixels, pixels), path
        assert image.convert("RGBA").getpixel((0, 0))[3] == 0, path
    for name in ("WALIMenuBar.png", "WALIMenuBar@2x.png"):
        image = np.asarray(Image.open(ASSETS / "WALIMenuBar.imageset" / name).convert("RGBA"))
        assert np.all(image[image[:, :, 3] > 0, :3] == 0), name
    icon_bytes = (BRANDING / "WALI.icns").read_bytes()
    assert icon_bytes[:4] == b"icns"
    assert struct.unpack_from(">I", icon_bytes, 4)[0] == len(icon_bytes)
    element_types: set[bytes] = set()
    offset = 8
    while offset < len(icon_bytes):
        element_type, length = struct.unpack_from(">4sI", icon_bytes, offset)
        assert length >= 8 and offset + length <= len(icon_bytes)
        element_types.add(element_type)
        offset += length
    assert {b"ic07", b"ic08", b"ic09", b"ic10", b"ic11", b"ic12", b"ic13", b"ic14"} <= element_types
    # Current iconutil writes ARGB ic04/ic05 for 16/32 pt, which Pillow does
    # not decode. Older encoders may produce equivalent PNG icp4/icp5 blocks.
    assert element_types & {b"ic04", b"icp4"}
    assert element_types & {b"ic05", b"icp5"}
    icon = Image.open(BRANDING / "WALI.icns")
    for size in icon.info["sizes"]:
        assert icon.icns.getimage(size).size == (size[0] * size[2], size[1] * size[2]), size
    roundtrip = temporary / "WALI-roundtrip.iconset"
    run(tool("iconutil"), "--convert", "iconset", "--output", roundtrip, BRANDING / "WALI.icns")
    for slot in slots:
        pixels = int(slot["size"].split("x")[0]) * int(slot["scale"][0])
        assert Image.open(roundtrip / slot["filename"]).size == (pixels, pixels), slot
    for filename, dimensions in (("dmg-background.png", (660, 440)),
                                  ("dmg-background@2x.png", (1320, 880))):
        assert Image.open(BRANDING / filename).size == dimensions, filename
    return {"source_contour_pixels": [width, height], "traced_silhouette_iou": round(iou, 8),
            "app_icon_slots": len(slots), "icns_roundtrip_slots": len(slots),
            "template_rgb": "black", "dmg_icon_centers_pt": [[180, 235], [480, 235]],
            "source_sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in sorted((BRANDING / "Sources").glob("*.png"))}}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    BRANDING.mkdir(parents=True, exist_ok=True)
    supplied = Image.open(BRANDING / "Sources/supplied-mark.png").convert("RGBA")
    mark_mask = supplied.getchannel("A").point(lambda value: 255 if value >= 128 else 0)
    lockup = np.asarray(Image.open(BRANDING / "Sources/supplied-lockup-light.png").convert("RGB"), dtype=np.int16)
    word_pixels = (lockup[:, :, 2] - lockup[:, :, 0]) > 100
    word_pixels[:850, :] = False
    word_mask = Image.fromarray((word_pixels * 255).astype(np.uint8))
    with tempfile.TemporaryDirectory(prefix="wali-brand-assets-") as directory:
        temporary = Path(directory)
        mark = trace(mark_mask, temporary, "mark")
        word = trace(word_mask, temporary, "wordmark")
        make_variants(mark, word)
        make_app_icon(mark, temporary)
        make_imagesets(mark, temporary)
        make_dmg(mark, word, temporary)
        make_contact_sheet()
        report = validate(mark_mask, mark, temporary)
        write_json(PREVIEW / "validation.json", report)
        print(json.dumps(report, indent=2))
        print(f"Preview: {PREVIEW / 'contact-sheet.png'}")


if __name__ == "__main__":
    main()
