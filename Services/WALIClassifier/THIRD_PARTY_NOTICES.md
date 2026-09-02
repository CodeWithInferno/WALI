# Third-party notices

WALI's classifier source is licensed separately from the dependencies below.
This file is an inventory, not a replacement for the license text distributed
by each upstream project. A release image must preserve those license texts in
its SBOM/license bundle.

| Component | Pinned version or revision | License |
|---|---:|---|
| Python | 3.12.11 | PSF-2.0 |
| uv | 0.8.17 | Apache-2.0 OR MIT |
| NumPy | 2.2.6 | BSD-3-Clause |
| Pillow | 11.3.0 | HPND |
| safetensors | 0.5.3 | Apache-2.0 |
| PyTorch | 2.7.1 | BSD-3-Clause |
| Transformers | 4.53.3 | Apache-2.0 |
| google/siglip-base-patch16-224 | revision `7fd15f0689c79d79e38b1c2e2e2370a7bf2761ed` | Apache-2.0 |

The SigLIP model files are not stored in this repository or baked into the
source-only image. `model-manifest.json` records the reviewed revision, expected
files, byte counts, and SHA-256 digests. Distribution of a weight-bearing image
is permitted only after the release process independently verifies the model
card, source, recorded digests, and generated SBOM.
