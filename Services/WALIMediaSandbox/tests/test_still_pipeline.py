from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib

from test_still_contract import chunk, exif, png
ROOT = Path(__file__).resolve().parents[1]

class StillPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory(prefix="wali-still-pipeline-")
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary=Path(cls.build.name)/"still-image-contract"
        subprocess.run(["cc","-std=c11","-O2","-Wall","-Wextra","-Werror",str(ROOT/"bin/still-image-contract.c"),"-lz","-o",str(cls.binary)],check=True)
        cls.image=os.environ.get("WALI_STILL_TEST_IMAGE")
        if cls.image:
            import re
            if not re.fullmatch(r"sha256:[a-f0-9]{64}",cls.image):raise ValueError("test image must be exact local immutable ID")
    def setUp(self):
        self.work=tempfile.TemporaryDirectory(prefix="wali-still-pixels-");self.addCleanup(self.work.cleanup)
        self.base=Path(self.work.name);self.input=self.base/"input";self.output=self.base/"output"
        self.input.mkdir();self.output.mkdir();self.digest=""
    def run_pipeline(self,mode,source=None):
        if source is not None:
            (self.input/"source.bin").write_bytes(source);self.digest=hashlib.sha256(source).hexdigest()
        source_dir=self.input if mode=="process-still" else self.output
        destination=self.output if mode=="process-still" else self.base/"verified"
        destination.mkdir(exist_ok=True)
        env=dict(os.environ,WALI_MEDIA_KIND="still",WALI_POLICY_DIGEST=hashlib.sha256((ROOT/"policy/still-image-policy.json").read_bytes()).hexdigest(),WALI_INPUT_DIGEST=self.digest,WALI_ATTEMPT_ID="attempt-still",WALI_SUBMISSION_ID="submission-still",WALI_GENERATION="1")
        if self.image:
            args=["docker","run","--rm","--platform=linux/amd64","--network=none","--read-only","--cap-drop=ALL","--security-opt=no-new-privileges","--pids-limit=64","--cpus=2","--memory=2g","--memory-swap=2g","--user",f"{os.getuid()}:{os.getgid()}","--tmpfs=/tmp:rw,noexec,nosuid,nodev,size=536870912","--mount",f"type=bind,src={source_dir},dst=/work/input,readonly","--mount",f"type=bind,src={destination},dst=/work/output"]
            for key in ("WALI_MEDIA_KIND","WALI_POLICY_DIGEST","WALI_INPUT_DIGEST","WALI_ATTEMPT_ID","WALI_SUBMISSION_ID","WALI_GENERATION"):args.extend(["--env",f"{key}={env[key]}"])
            args.extend([self.image,"/opt/wali/bin/process-media" if mode=="process-still" else "/opt/wali/bin/verify-media"])
        else:
            # Same shipped scripts/pixels on host; only fixed sandbox locations
            # and GNU stat are projected into an isolated temporary directory.
            scratch=Path(tempfile.mkdtemp(prefix=mode+"-tmp-",dir=self.base))
            text=(ROOT/"bin"/mode).read_text().replace("/work/input",str(source_dir)).replace("/work/output",str(destination)).replace("/opt/wali/policy/still-image-policy.json",str(ROOT/"policy/still-image-policy.json")).replace("/opt/wali/bin/still-image-contract",str(self.binary)).replace("/tmp/",str(scratch)+"/")
            text=text.replace("stat -c", "gstat -c")
            script=self.base/mode;script.write_text(text);args=["bash",str(script)]
        return subprocess.run(args,env=env,capture_output=True,text=True,timeout=60)
    def accepted(self,source):
        result=self.run_pipeline("process-still",source)
        failure=self.output/"failure.json"
        self.assertEqual(result.returncode,0,result.stderr+(failure.read_text() if failure.exists() else str(list(self.output.iterdir()))))
        return json.loads((self.output/"media-claim.json").read_text())
    def raw_pixels(self,path):
        return subprocess.run(["ffmpeg","-v","error","-noautorotate","-i",str(path),"-frames:v","1","-pix_fmt","rgb24","-f","rawvideo","pipe:1"],capture_output=True,check=True).stdout
    def test_all_eight_exif_orientations_preserve_exact_pixels(self):
        colors=[bytes(c) for c in [(255,0,0),(0,255,0),(0,0,255),(255,255,0),(0,255,255),(255,0,255)]]
        expected=[[0,1,2,3,4,5],[2,1,0,5,4,3],[5,4,3,2,1,0],[3,4,5,0,1,2],[0,3,1,4,2,5],[3,0,4,1,5,2],[5,2,4,1,3,0],[2,5,1,4,0,3]]
        for orientation in range(1,9):
            with self.subTest(orientation=orientation):
                # Every production attempt owns fresh input/output roots.
                # Keep completed bind mounts intact through this corpus too.
                self.input=self.base/f"input-{orientation}";self.input.mkdir()
                self.output=self.base/f"output-{orientation}";self.output.mkdir()
                raw=b"\0"+b"".join(colors[:3])+b"\0"+b"".join(colors[3:])
                source=b"\x89PNG\r\n\x1a\n"+chunk("IHDR",struct.pack(">IIBBBBB",3,2,8,2,0,0,0))+chunk("eXIf",exif(orientation))+chunk("IDAT",zlib.compress(raw))+chunk("IEND",b"")
                claim=self.accepted(source);master=next(a for a in claim["artifacts"] if a["role"]=="image_default")
                self.assertEqual((master["width"],master["height"]),(2,3) if orientation>=5 else (3,2))
                self.assertEqual(self.raw_pixels(self.output/master["relative_path"]),b"".join(colors[i] for i in expected[orientation-1]))
    def test_real_alpha_flattening_roles_private_metadata_and_independent_verification(self):
        claim=self.accepted(png(alpha=True,extras=chunk("tEXt",b"Comment\0private-location")))
        self.assertEqual(claim["schema_version"],2);self.assertEqual(claim["media_kind"],"still")
        self.assertEqual({a["role"] for a in claim["artifacts"]},{"image_default","poster","thumbnail"})
        self.assertEqual(len(claim["sample_frames"]),1)
        master=self.output/"artifacts/image-default.png"
        self.assertNotIn(b"private-location",master.read_bytes())
        pixels=self.raw_pixels(master)
        self.assertEqual(len(pixels),8*4*3)
        self.assertTrue(all(pixels[i:i+3] in (bytes([127,0,0]),bytes([128,0,0])) for i in range(0,len(pixels),3)))
        result=self.run_pipeline("verify-still");self.assertEqual(result.returncode,0,result.stderr)
        verified=json.loads((self.base/"verified/verification-claim.json").read_text())
        self.assertEqual(verified,claim|{"kind":"verification"})
        # Re-hash a corrupt raster so digest-only validation cannot pass it.
        broken=bytearray(master.read_bytes());start=broken.index(b"IDAT")-4;size=struct.unpack(">I",broken[start:start+4])[0]
        broken[start+8:start+8+size]=b"x"*size
        broken[start+8+size:start+12+size]=struct.pack(">I",zlib.crc32(broken[start+4:start+8+size]))
        master.write_bytes(broken)
        for item in claim["artifacts"]:
            if item["role"]=="image_default":item["digest"]=hashlib.sha256(broken).hexdigest()
        (self.output/"media-claim.json").write_text(json.dumps(claim))
        (self.base/"verified/verification-claim.json").unlink()
        result=self.run_pipeline("verify-still");self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.base/"verified/verification-claim.json").exists())
    def test_jpeg_and_rejected_profile_have_truthful_failure(self):
        source=self.base/"jpeg-source.png";source.write_bytes(png())
        jpeg=self.base/"source.jpg"
        subprocess.run(["ffmpeg","-v","error","-i",str(source),"-frames:v","1","-pix_fmt","yuvj420p",str(jpeg)],check=True)
        self.accepted(jpeg.read_bytes())
        result=self.run_pipeline("verify-still");self.assertEqual(result.returncode,0,result.stderr)
        # A fresh attempt rejects forbidden profiles before any media claim.
        shutil.rmtree(self.output);self.output.mkdir()
        result=self.run_pipeline("process-still",png(extras=chunk("iCCP",b"icc\0\0"+zlib.compress(b"profile"))))
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads((self.output/"failure.json").read_text())["safe_code"],"image_color_profile_unsupported")
        self.assertFalse((self.output/"media-claim.json").exists())

if __name__=="__main__":unittest.main()
