#!/usr/bin/env python3
"""Write and verify WALI's small, fixed Finder layout without scripting Finder.

Only the packaging process uses this tool. Python's standard library writes one
DS_Store B-tree leaf; macOS Alias Manager supplies the background file reference.
The Buddy/DSDB record layout is documented by the upstream ds_store project:
https://github.com/dmgbuild/ds_store
"""

import ctypes
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def u32(*values):
    return struct.pack(">" + "I" * len(values), *values)


def alias_services():
    library = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
    pointer = ctypes.c_void_p
    signatures = {
        "FSPathMakeRef": ([ctypes.c_char_p, pointer, pointer], ctypes.c_int16),
        "FSNewAlias": ([pointer, pointer, pointer], ctypes.c_int16),
        "NewHandle": ([ctypes.c_ssize_t], pointer),
        "GetHandleSize": ([pointer], ctypes.c_ssize_t),
        "DisposeHandle": ([pointer], None),
        "FSResolveAliasWithMountFlags": ([pointer, pointer, pointer, pointer, ctypes.c_uint32], ctypes.c_int16),
        "FSRefMakePath": ([pointer, pointer, ctypes.c_uint32], ctypes.c_int16),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(library, name)
        function.argtypes, function.restype = arguments, result
    return library


def file_reference(library, path):
    reference = ctypes.create_string_buffer(80)  # Carbon FSRef is 80 opaque bytes.
    status = library.FSPathMakeRef(os.fsencode(path), reference, None)
    require(status == 0, f"Cannot reference packaging file ({status}): {path}")
    return reference


def new_alias(source, target):
    library = alias_services()
    source_ref, target_ref = file_reference(library, source), file_reference(library, target)
    handle = ctypes.c_void_p()
    status = library.FSNewAlias(source_ref, target_ref, ctypes.byref(handle))
    require(status == 0 and handle.value, f"Cannot create background alias ({status})")
    try:
        size = library.GetHandleSize(handle)
        require(0 < size < 2048, "Background alias exceeds packaging bounds")
        return ctypes.string_at(ctypes.cast(handle, ctypes.POINTER(ctypes.c_void_p))[0], size)
    finally:
        library.DisposeHandle(handle)


def resolve_alias(source, data):
    library = alias_services()
    handle = library.NewHandle(len(data))
    require(handle, "Cannot allocate background alias")
    try:
        ctypes.memmove(ctypes.cast(handle, ctypes.POINTER(ctypes.c_void_p))[0], data, len(data))
        target = ctypes.create_string_buffer(80)
        changed = ctypes.c_ubyte()
        # kResolveAliasFileNoUI: never ask Finder to locate or mount anything.
        status = library.FSResolveAliasWithMountFlags(
            file_reference(library, source), handle, target, ctypes.byref(changed), 1
        )
        require(status == 0, f"Cannot resolve packaged background alias ({status})")
        path = ctypes.create_string_buffer(4096)
        require(library.FSRefMakePath(target, path, len(path)) == 0, "Cannot read background path")
        return Path(os.fsdecode(path.value)).resolve()
    finally:
        library.DisposeHandle(handle)


def record(filename, code, kind, value):
    name = filename.encode("utf-16be")
    payload = u32(len(value)) + value if kind == "blob" else value
    return u32(len(name) // 2) + name + code.encode("ascii") + kind.encode("ascii") + payload


def write_layout(volume):
    destination = volume / ".DS_Store"
    destination.touch(exist_ok=False)
    background_alias = new_alias(destination, volume / ".background" / "background.tiff")
    window = {
        "WindowBounds": "{{160, 120}, {660, 440}}",
        "ShowStatusBar": False, "ShowTabView": False, "ShowToolbar": False,
        "ShowPathbar": False, "ShowSidebar": False, "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False, "SidebarWidth": 0,
    }
    icons = {
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundColorRed": 1.0, "backgroundColorGreen": 1.0, "backgroundColorBlue": 1.0,
        "backgroundImageAlias": background_alias, "arrangeBy": "none",
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "iconSize": 128.0, "textSize": 14.0, "labelOnBottom": True,
        "showIconPreview": True, "showItemInfo": False,
        "scrollPositionX": 0.0, "scrollPositionY": 0.0,
    }
    entries = [
        record(".", "bwsp", "blob", plistlib.dumps(window, fmt=plistlib.FMT_BINARY)),
        record(".", "icvl", "type", b"icnv"),
        record(".", "icvp", "blob", plistlib.dumps(icons, fmt=plistlib.FMT_BINARY)),
        record(".", "vSrn", "long", u32(1)),
        record("Applications", "Iloc", "blob", u32(480, 235, 0xFFFFFFFF, 0xFFFF0000)),
        record("WALI.app", "Iloc", "blob", u32(180, 235, 0xFFFFFFFF, 0xFFFF0000)),
    ]
    leaf = u32(0, len(entries)) + b"".join(entries)
    require(len(leaf) <= 4096, "Finder layout exceeds its fixed B-tree leaf")
    # Buddy addresses have a four-byte file offset and five size-exponent bits.
    # Block 0: allocator, block 1: DSDB header, block 2: the only leaf.
    allocator = u32(3, 0, 2048 | 11, 32 | 5, 4096 | 12) + bytes(253 * 4)
    allocator += u32(1) + b"\x04DSDB" + u32(1)
    for exponent in range(32):
        free = 6 <= exponent <= 10 or 13 <= exponent <= 30
        allocator += u32(1, 1 << exponent) if free else u32(0)
    require(len(allocator) <= 2048, "Finder allocator exceeds its fixed block")
    image = bytearray(8196)
    image[:36] = u32(1) + b"Bud1" + u32(2048, 2048, 2048) + bytes(16)
    # DSDB counts internal levels: a root that is itself a leaf has zero.
    image[36:56] = u32(2, 0, len(entries), 1, 4096)
    image[2052:2052 + len(allocator)] = allocator
    image[4100:4100 + len(leaf)] = leaf
    destination.write_bytes(image)


def read_layout(path):
    data = path.read_bytes()
    require(len(data) == 8196 and data[4:8] == b"Bud1", "Invalid Finder metadata header")
    root, levels, record_count, node_count, page_size = struct.unpack_from(">IIIII", data, 36)
    require(root == 2 and node_count == 1 and page_size == 4096, "Invalid Finder B-tree layout")
    child, count = struct.unpack_from(">II", data, 4100)
    require(child == 0, "Finder B-tree root must be a leaf")
    require(levels == 0, "Finder leaf tree must have zero internal levels")
    require(count == record_count and count == 6, "Invalid Finder layout record count")
    position, entries = 4108, {}
    for _ in range(count):
        length = struct.unpack_from(">I", data, position)[0]
        position += 4
        name = data[position:position + length * 2].decode("utf-16be")
        position += length * 2
        code, kind = struct.unpack_from(">4s4s", data, position)
        position += 8
        size = 4
        if kind == b"blob":
            size = struct.unpack_from(">I", data, position)[0]
            position += 4
        require(kind in (b"blob", b"type", b"long") and position + size <= len(data), "Invalid Finder record")
        entries[(name, code)] = data[position:position + size]
        position += size
    return entries


def verify_layout(volume):
    require((volume / "Applications").is_symlink(), "Applications link is missing")
    require(os.readlink(volume / "Applications") == "/Applications", "Applications link has the wrong target")
    for name in (".VolumeIcon.icns", ".background/background.tiff"):
        require((volume / name).is_file() and (volume / name).stat().st_size > 0, f"Missing {name}")
    entries = read_layout(volume / ".DS_Store")
    require(entries[(".", b"icvl")] == b"icnv", "Finder must open in icon view")
    window = plistlib.loads(entries[(".", b"bwsp")])
    require(window["WindowBounds"] == "{{160, 120}, {660, 440}}" and not window["ShowToolbar"], "Wrong Finder window layout")
    for name, point in (("WALI.app", (180, 235)), ("Applications", (480, 235))):
        require(struct.unpack_from(">II", entries[(name, b"Iloc")]) == point, f"Wrong icon location: {name}")
    icons = plistlib.loads(entries[(".", b"icvp")])
    require(icons["backgroundType"] == 2, "Finder background is not an image")
    require(icons["iconSize"] == 128.0, "Finder icon size does not match the installer preview")
    for channel in ("Red", "Green", "Blue"):
        key = "backgroundColor" + channel
        value = icons.get(key)
        require(type(value) is float and value == 1.0, f"Invalid Finder icon-view field: {key}")
    expected = (volume / ".background" / "background.tiff").resolve()
    require(resolve_alias(volume / ".DS_Store", icons["backgroundImageAlias"]) == expected, "Background alias escaped this disk image")
    info = plistlib.loads((volume / "WALI.app" / "Contents" / "Info.plist").read_bytes())
    icon = info.get("CFBundleIconFile", "")
    require(icon and "/" not in icon, "App bundle does not declare an icon")
    icon_path = volume / "WALI.app" / "Contents" / "Resources" / (icon if icon.endswith(".icns") else icon + ".icns")
    require(icon_path.is_file() and icon_path.read_bytes()[:4] == b"icns", "Declared app icon is missing")
    finder_info = bytes.fromhex(subprocess.check_output(
        ["/usr/bin/xattr", "-px", "com.apple.FinderInfo", str(volume)], text=True
    ))
    require(struct.unpack_from(">H", finder_info, 8)[0] & 0x0400, "Volume custom icon flag is missing")
    print("Verified DMG metadata: app icon, Applications link, Retina background, volume icon, and Finder positions.")


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 3 and sys.argv[1] in ("write", "verify"), "Usage: package-dmg-metadata.py write|verify MOUNT_POINT")
        root = Path(sys.argv[2]).resolve(strict=True)
        require(root.is_dir() and root != Path("/"), "A mounted packaging directory is required")
        if sys.argv[1] == "write":
            write_layout(root)
        else:
            verify_layout(root)
    except (ValueError, OSError, KeyError, struct.error, subprocess.CalledProcessError) as error:
        sys.exit(f"DMG metadata failed: {error}")
