from __future__ import annotations
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]

def chunk(kind, payload):
    body = kind.encode("ascii") + payload
    return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

def png(width=8, height=4, alpha=False, extras=b""):
    color = 6 if alpha else 2
    pixel = bytes([255, 0, 0, 128] if alpha else [255, 0, 0])
    raw = (b"\0" + pixel * width) * height
    return (b"\x89PNG\r\n\x1a\n" + chunk("IHDR", struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0))
            + extras + chunk("IDAT", zlib.compress(raw)) + chunk("IEND", b""))

def exif(orientation):
    return b"II*\0" + struct.pack("<I", 8) + struct.pack("<H", 1) + struct.pack("<HHIH", 0x112, 3, 1, orientation) + b"\0\0" + b"\0"*4

def jpeg(orientation=1, extra=b""):
    def marker(kind, value): return bytes([255, kind]) + struct.pack(">H", len(value)+2) + value
    return (b"\xff\xd8" + marker(0xe1, b"Exif\0\0"+exif(orientation)) + extra
        + marker(0xc0, bytes([8])+struct.pack(">HH",4,8)+bytes([3,1,0x11,0,2,0x11,0,3,0x11,0]))
        + marker(0xda, bytes([3,1,0,2,0,3,0,0,63,0])) + b"\x01\x02\xff\xd9")

class StillContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="wali-still-contract-")
        cls.binary = Path(cls.build.name)/"still-image-contract"
        subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", str(ROOT/"bin/still-image-contract.c"), "-lz", "-o", str(cls.binary)], check=True)
    @classmethod
    def tearDownClass(cls): cls.build.cleanup()
    def setUp(self):
        self.work=tempfile.TemporaryDirectory(prefix="wali-still-fixture-")
        self.addCleanup(self.work.cleanup)
        self.path=Path(self.work.name)/"source.bin"
    def run_helper(self, mode="inspect-source", data=None, extra=()):
        if data is not None: self.path.write_bytes(data)
        return subprocess.run([str(self.binary), mode, str(self.path), *map(str, extra)], capture_output=True, text=True)
    def rejected(self, data, code=None):
        result=self.run_helper(data=data)
        self.assertNotEqual(result.returncode,0)
        if code: self.assertEqual(result.stderr.strip(),code)
        self.assertEqual(result.stdout,"")
    def test_srgb_png_and_alpha_have_bounded_explicit_shape(self):
        result=self.run_helper(data=png(alpha=True,extras=chunk("sRGB",b"\0")))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout),{"format":"png","width":8,"height":4,"orientation":1,"has_alpha":True,"color_profile":"srgb"})
    def test_exif_all_eight_orientations_are_read_without_thumbnail_or_file_access(self):
        for orientation in range(1,9):
            with self.subTest(orientation=orientation):
                result=self.run_helper(data=jpeg(orientation))
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(json.loads(result.stdout)["orientation"],orientation)
        self.rejected(jpeg(9),"invalid_image_orientation")
        result=self.run_helper(data=png(extras=chunk("eXIf",exif(6))))
        self.assertEqual(json.loads(result.stdout)["orientation"],6)
    def test_animation_icc_hdr_and_conflicting_gamma_are_rejected(self):
        for metadata in [chunk("acTL",struct.pack(">II",1,0)),chunk("fcTL",b"x"),chunk("fdAT",b"x")]:
            self.rejected(png(extras=metadata),"animated_image_unsupported")
        for metadata in [chunk("iCCP",b"icc\0\0"+zlib.compress(b"profile")),chunk("gAMA",struct.pack(">I",100000)),chunk("cICP",bytes([9,16,0,1])),chunk("mDCV",b"\0"*24),chunk("cLLI",b"\0"*8)]:
            self.rejected(png(extras=metadata),"image_color_profile_unsupported")
    def test_malformed_crc_dimensions_trailing_bytes_and_links_fail(self):
        bad=bytearray(png());bad[-1]^=1
        self.rejected(bytes(bad))
        self.rejected(png(width=7681,height=1),"media_limits_exceeded")
        self.rejected(png()+b"private trailing data")
        self.rejected(png()[:40])
        target=Path(self.work.name)/"target.png";target.write_bytes(png())
        self.path.unlink(missing_ok=True);self.path.symlink_to(target)
        self.assertNotEqual(self.run_helper().returncode,0)
    def test_canonical_png_strips_metadata_and_adds_srgb_without_changing_pixels(self):
        source=png(extras=chunk("tEXt",b"Comment\0private")+chunk("eXIf",exif(1)))
        output=Path(self.work.name)/"master.png"
        result=self.run_helper("canonicalize-png",source,(output,))
        self.assertEqual(result.returncode,0,result.stderr)
        result=subprocess.run([str(self.binary),"inspect-canonical",str(output)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        raw=output.read_bytes();self.assertNotIn(b"private",raw);self.assertNotIn(b"eXIf",raw);self.assertIn(b"sRGB",raw)
        def pixels(value):
            offset=8; result=b""
            while offset<len(value):
                count=struct.unpack(">I",value[offset:offset+4])[0]
                if value[offset+4:offset+8]==b"IDAT": result+=value[offset+8:offset+8+count]
                offset+=count+12
            return zlib.decompress(result)
        self.assertEqual(pixels(raw),pixels(source))
        self.path.write_bytes(source)
        self.assertNotEqual(self.run_helper("inspect-canonical").returncode,0)
    def test_untagged_input_assumption_is_explicit_and_non_rgb_jpeg_rejected(self):
        result=self.run_helper(data=png())
        self.assertEqual(json.loads(result.stdout)["color_profile"],"untagged_assumed_srgb")
        self.rejected(b"GIF89a"+b"\0"*20,"unsupported_image_format")
        gray=(b"\x89PNG\r\n\x1a\n"+chunk("IHDR",struct.pack(">IIBBBBB",1,1,8,0,0,0,0))
              +chunk("IDAT",zlib.compress(b"\0\xff"))+chunk("IEND",b""))
        self.rejected(gray,"image_color_profile_unsupported")
    def test_canonical_jpeg_rejects_embedded_app0_thumbnail(self):
        # JFIF RGB thumbnail is metadata even though it is not APP1/EXIF.
        payload=b"JFIF\0"+bytes([1,2,0,0,1,0,1,1,1])+bytes([1,2,3])
        app0=bytes([255,0xe0])+struct.pack(">H",len(payload)+2)+payload
        encoded=jpeg();app1length=struct.unpack(">H",encoded[4:6])[0]
        source=encoded[:2]+app0+encoded[4+app1length:]
        result=self.run_helper("inspect-canonical",source)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stderr.strip(),"private_image_metadata")
    def test_progressive_markers_after_first_scan_cannot_hide_profiles(self):
        # Header parser must inspect all marker segments, even after entropy.
        profile=bytes([255,0xe2])+struct.pack(">H",16)+b"ICC_PROFILE\0\1\1"
        self.rejected(jpeg()[:-2]+profile+b"\xff\xd9","image_color_profile_unsupported")


if __name__=="__main__": unittest.main()
