# Third-party notices

WALI is Apache-2.0 software. The following components are used by source or
build tooling and retain their own licenses. The SPDX inventory records the
reviewed dependency versions and available artifact digests or Git revisions.

The complete resolved Swift graph is checked in at `Config/Package.resolved`.
The app includes `Contents/Resources/ThirdPartyLicenses`, containing the full
upstream license and copyright notices below, plus WALI's license and notice.
`Resources/ThirdPartyLicenses/manifest.json` records the exact upstream revision
and SHA-256 of each preserved text. Bundle verification checks the actual app
resources against these reviewed files.

| Swift package | Resolved version | License |
| --- | --- | --- |
| supabase-swift | 2.54.1 | MIT |
| swift-asn1 | 1.7.2 | Apache-2.0 |
| swift-clocks | 1.1.1 | MIT |
| swift-concurrency-extras | 1.4.1 | MIT |
| swift-crypto | 4.5.1 | Apache-2.0 |
| swift-http-types | 1.6.0 | Apache-2.0 |
| xctest-dynamic-overlay | 1.13.1 | MIT |

This graph includes package targets that may be excluded from macOS builds.
Swift Crypto uses Apple's CryptoKit on the ordinary macOS configuration.

| Component | Purpose | License |
| --- | --- | --- |
| Fastlane (official Git revision pinned in Gemfile.lock) | Developer ID release tooling | MIT |
| Supabase / PostgreSQL local tooling | Backend development and database | Apache-2.0 / PostgreSQL |
| pgx and Go transitive modules | Media worker database client | MIT / BSD-3-Clause |
| FFmpeg | Networkless media normalization | LGPL-2.1-or-later, configured without GPL/nonfree features |
| Kvazaar | HEVC Main 10 encoder used by the media sandbox, built with `KVZ_BIT_DEPTH=10` | BSD-3-Clause |
| FFmpeg libkvazaar 10-bit wrapper patch | In-tree LGPL patch so FFmpeg 7.1.2 accepts `yuv420p10le` | LGPL-2.1-or-later |
| SigLIP model code and declared weights | Offline taxonomy suggestions | Apache-2.0, subject to verified model manifest |
| PyTorch, Transformers, Pillow, NumPy, safetensors | Optional offline classifier runtime | BSD-3-Clause / Apache-2.0 / HPND / BSD-3-Clause / Apache-2.0 |
| pytest and development dependencies | Classifier tests | MIT / BSD licenses |
| Debian container base and packages | Isolated media runtime | Mixed free-software licenses in image package metadata |

Fastlane's Git source is included in the SPDX inventory. The remaining Ruby
toolchain graph and RubyGems artifact checksums are tracked in `Gemfile.lock`
and scanned by CI; these build tools are not embedded in the macOS app.

Wallpaper media is not licensed by WALI’s software license. Every seed or
marketplace item requires separate provenance and redistribution evidence.
No proprietary Backdrop or Wallsflow asset is distributed with WALI.
