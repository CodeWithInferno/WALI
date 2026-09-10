# WALI production identity

**Date:** 2026-09-09

**Scope:** Supplied identity artwork, native application resources, and installer artwork.

The owner-supplied curved ribbon W is the authoritative mark. The artwork in
`Resources/Branding/Sources/` retains the supplied transparent mark, blue lockup
on a light surface, and white lockup on a blue surface. These source files are
unaltered. The earlier work under `output/branding/wali-fold/` is separate and
is not used by the application or installer.

## Artwork license — 2026-09-10

The repository owner approved explicit Apache License 2.0 coverage for the
original supplied artwork and its generated application and installer
resources. [The branding license](../../Resources/Branding/LICENSE.md) names
the three source PNGs, the exports under `Resources/Branding/`, and the AppIcon,
WALIMark, and WALIMenuBar asset sets. Copyright remains with the respective
contributors; Apache License 2.0 section 6 governs trademark permissions.
Separately supplied media and third-party artwork retain their own terms.

## Master artwork

`scripts/generate-brand-assets.py` extracts the transparent mark's alpha
silhouette at its original resolution and fits cubic vector paths using
Potrace 1.16. Curve optimization tolerance is 0.15 source pixels; only stray
islands or holes of 32 pixels or fewer are suppressed. This removes isolated
speckles and color fringes without replacing the supplied silhouette. The
resulting native-resolution silhouette overlap is **99.81309%** by
intersection-over-union against the supplied alpha mask. No raster image is
embedded in the SVG masters.

The WALI lettering is traced from the actual supplied light-background
lockup, preserving its letterforms and spacing. It is not recreated with a
substitute font. The standalone mark and wordmark exports use solid blue
`#0037EE`, white, and black. The blue follows the supplied transparent mark.

Each color has transparent SVG and PNG exports:

| Filename pattern under `Resources/Branding/` | Raster canvas |
| --- | --- |
| `wali-mark-{blue,white,black}` | 1024 × 511 px |
| `wali-wordmark-{blue,white,black}` | 1024 × 220 px |
| `wali-lockup-stacked-{blue,white,black}` | 1024 × 740 px |
| `wali-lockup-horizontal-{blue,white,black}` | 1024 × 226 px |

Use the mark without lettering at small sizes. Use lockups only where the
wordmark remains clearly legible. Blue/black exports belong on light surfaces;
white belongs on dark surfaces. Do not stretch the artwork or crop away the
ribbon's ends. Ordinary interface controls continue to use semantic system
colors and respect the person's accent choice as required by `DESIGN.md`.

## Native application resources

`Resources/WALIAssets.xcassets` is the shared catalog. Its resource names are
stable integration contracts:

| Resource | Contract |
| --- | --- |
| `AppIcon` | macOS app-icon set: 16, 32, 128, 256, and 512 pt at 1× and 2×; all ten representations are present. |
| `WALIMark` | Original-rendering blue mark, transparent 128 × 64 px and 256 × 128 px representations. |
| `WALIMenuBar` | Template-rendering black alpha symbol, 24 × 14 pt at 1× and 2×; visible contour is 22 pt wide and vertically centered. No wordmark. |

The application icon uses the supplied white W on a restrained cobalt-to-deep
blue tile. The 1024 px canvas has a rounded 824 × 824 px tile inset 100 px on
each side, a small lower shadow, and a 634 px wide mark. Transparent exterior
pixels preserve the native macOS icon footprint. Every catalog representation
is rendered directly from `app-icon.svg` at its destination size.

`app-icon-1024.png` is the review/export master. `WALI.icns` is assembled by
macOS `iconutil` from the same ten source images. `WALI-Volume.icns` uses the
same artwork for the mounted installer volume. The app, agent, and optional
helper share the identity; they do not introduce extra logos.

The menu-bar asset must remain a template so AppKit supplies the appropriate
foreground color across light/dark menu bars and selection states. Callers
should give it its native 24 × 14 pt frame and a meaningful accessibility
label rather than rendering the colored application tile in the menu bar.

## Installer artwork

The installer window is **660 × 440 pt**:

- `dmg-background.png`: 660 × 440 px.
- `dmg-background@2x.png`: 1320 × 880 px.
- WALI app icon center: **(180, 235)** pt.
- Applications folder/alias icon center: **(480, 235)** pt.
- The connecting arrow lies between the two icon areas. The real Finder icons
  and their labels are not baked into the image.

The light surface carries a modest centered “Install WALI” title at y = 75 pt
and a short drag instruction. WALI's logo appears on the actual application
icon beside the arrow; there is no extra header logo. A small footer explains
that the installed app can be opened from Applications. The header and arrow
leave both installation targets clear. Packaging should preserve the
background's native point dimensions when selecting its Retina representation.

The contact sheet and `output/branding/wali-production/installer-preview.png`
show an assembled installer preview: WALI's real app icon and the native macOS
Applications folder icon sit at their intended centers, with labels beneath
them. This review composite is distinct from the shipping background; Finder
supplies the real draggable icons in the mounted installer. The preview reads
the system Applications icon or a provided export and does not copy Apple's
folder artwork into the application's resources.

## Regeneration and verification

Use Python 3 with Pillow and NumPy, Potrace 1.16, librsvg's `rsvg-convert`, and
the macOS system `iconutil`. These are artwork-generation tools, not new
application runtime dependencies. Tools are found on `PATH`, with an
`/opt/homebrew/bin` fallback for Homebrew executables.

```sh
python3 scripts/generate-brand-assets.py
```

The script reads only the checked-in source artwork, generates the vector and
raster outputs, assembles the ICNS files, and writes the contact sheet plus a
validation report to `output/branding/wali-production/`. Packaging text is
rasterized using the local system font; no font file is copied or bundled.
For byte-identical packaging typography, use the same macOS/font and tool
versions. Run the system icon encoder from a normal macOS process context: a
restricted graphics-service sandbox can report `Invalid Iconset` for valid
PNG inputs. The same complete iconset successfully encoded using system
`iconutil` with normal system access during this change.

The generator checks source-contour overlap, all app-icon dimensions and
transparent corners, both template images' black RGB values, every decoded
ICNS representation, and both installer background dimensions. The validation
report includes SHA-256 hashes for all three unchanged supplied source images.
The contact sheet makes the application icon, native small sizes, template
appearance on light/dark backgrounds, source wordmark, and assembled installer
reviewable together. These checks do not substitute for inspecting the built
application, menu-bar extra, or mounted installer.

## Integration verification — 2026-09-09

`make verify` passed, including architecture policy fixtures, package and native
unit tests, coverage gates, the Debug build, and embedded-bundle verification.
`scripts/verify-branding.swift` loaded the compiled app icon and both named
images independently from the main app, agent, and helper bundles; the menu
image retained its template flag and 24 × 14 pt size.

The corrected installer artwork was packaged as a local Debug DMG. The packager
verified its compressed-image checksum, reopened it read-only at a different
mount point, resolved the background alias, checked icon positions and the
Applications shortcut, and compared the contained app against the built app.
The app's local ad-hoc signatures were preserved. Developer ID signing and
notarization were not run; the local DMG is not a public distribution build.

`output/branding/wali-production/installer-preview.png` is an assembled layout
preview, not a Finder screenshot. The real draggable icons are supplied by
Finder when the disk image opens.

The first mounted image did not display that layout: its single-leaf Finder
B-tree incorrectly declared an internal level, and its icon-view property list
omitted the three background-color components required even with an image
background. Structural checks alone had missed the Finder behavior. The writer
now declares zero internal levels and includes the RGB fields as real values.
`Tests/Bundle/dmg-metadata-tests.py` covers these regressions and runs in both
the packager and `make verify`.

After those corrections, the rebuilt DMG was opened in Finder and visually
checked on 2026-09-09. The actual mounted window displayed the light artwork,
128 pt draggable icons, WALI on the left, the centered arrow, Applications on
the right, and the installation instructions. Finder adds its native title bar
and shortcut badge. This visual check is separate from the automated metadata,
image-integrity, and bundle checks above.
