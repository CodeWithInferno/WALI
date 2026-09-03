# Third-party notices

WALI is Apache-2.0 software. The following components are used by source or
build tooling and retain their own licenses. Release SBOMs contain the exact
resolved versions and checksums.

| Component | Purpose | License |
| --- | --- | --- |
| supabase-swift and transitive Swift packages | Marketplace client | Apache-2.0 / MIT as recorded upstream |
| Supabase / PostgreSQL local tooling | Backend development and database | Apache-2.0 / PostgreSQL |
| pgx and Go transitive modules | Media worker database client | MIT / BSD-3-Clause |
| FFmpeg | Networkless media normalization | LGPL-2.1-or-later, configured without GPL/nonfree features |
| Kvazaar | HEVC Main 10 encoder used by the media sandbox, built with `KVZ_BIT_DEPTH=10` | BSD-3-Clause |
| FFmpeg libkvazaar 10-bit wrapper patch | In-tree LGPL patch so FFmpeg 7.1.2 accepts `yuv420p10le` | LGPL-2.1-or-later |
| SigLIP model code and declared weights | Offline taxonomy suggestions | Apache-2.0, subject to verified model manifest |
| PyTorch, Transformers, Pillow, NumPy, safetensors | Optional offline classifier runtime | BSD-3-Clause / Apache-2.0 / HPND / BSD-3-Clause / Apache-2.0 |
| pytest and development dependencies | Classifier tests | MIT / BSD licenses |
| Debian container base and packages | Isolated media runtime | Mixed free-software licenses in image package metadata |

Wallpaper media is not licensed by WALI’s software license. Every seed or
marketplace item requires separate provenance and redistribution evidence.
No proprietary Backdrop or Wallsflow asset is distributed with WALI.
