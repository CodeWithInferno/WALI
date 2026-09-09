# WALI Design System

**Status:** Product direction locked on 2026-08-30  
**Platform:** Native macOS 15+, enhanced automatically on macOS 26+  
**Design thesis:** The wallpaper is the product. WALI's interface should recede until the user needs it, then behave exactly like a well-made Mac app.

## Source and interpretation

The primary craft reference is [emilkowalski/skills](https://github.com/emilkowalski/skills), especially its `apple-design`, `emil-design-eng`, and `write-swift` guidance. It captures the requested Apple qualities beyond appearance: immediate feedback, spatial consistency, interruptible physical motion, restraint, careful typography, accessibility, and modern Swift engineering.

Its Apple motion examples are translated primarily for the web, so WALI adopts the principles rather than its CSS or JavaScript implementation details. Native SwiftUI and AppKit own timing, spring behavior, popover origins, materials, pointer response, and accessibility wherever they provide the behavior.

The Apple entry in [VoltAgent/awesome-design-md](https://github.com/VoltAgent/awesome-design-md/blob/main/design-md/apple/DESIGN.md) remains a secondary visual reference. It analyzes **apple.com**, not native macOS software. WALI borrows image-first composition, quiet typography, generous space, a single accent, and restrained chrome, but does not copy its web-only measurements, navigation, giant marketing type, or pill-heavy controls.

Native application behavior follows Apple's macOS Human Interface Guidelines and current SwiftUI/AppKit behavior. Standard system controls take precedence over custom imitations.

## Product character

- **Quiet:** Controls never compete with motion artwork.
- **Native:** Menus, windows, focus, selection, drag and drop, keyboard shortcuts, undo, and accessibility behave like macOS.
- **Tactile:** Feedback is immediate but subtle. Motion communicates state instead of decorating it.
- **Honest:** Performance and storage costs are visible in plain language.
- **Personal:** The active wallpaper supplies atmosphere; WALI does not impose decorative gradients over it.

## App identity

WALI's identity uses the supplied folded W silhouette. Production artwork and
export instructions live in [the branding guide](docs/design/2026-09-09-wali-branding.md).
The Dock, Finder, standard About panel, and installer use a text-free white W
on a cobalt app tile. The menu bar uses a monochrome template W, letting macOS
provide contrast in every appearance; playback state remains in the accessible
label and status panel. Small identity marks may appear in the status panel and
Settings. Keep the shared window toolbar and its functional symbols unchanged.

Brand artwork may retain its fixed cobalt color. Native controls continue to
respect the person's macOS accent choice. Lockups with the WALI wordmark belong
in larger brand and installer artwork, never inside small app or menu-bar icons.

## Signature element — Ambient Edge

The selected wallpaper may extend beneath the sidebar and toolbar so the system material picks up its color. On macOS 26+, the sidebar overlays the detail column (`automaticallyAdjustsSafeAreaInsets`) and the Discover hero **draws the actual artwork under that glass**. Do not use `backgroundExtensionEffect()` for Discover: it mirrors and blurs a copy, which reads as a reflection instead of Liquid Glass. Empty states, Browse/Library grids, settings, and poster tiles stay on the semantic surface.

The Discover hero is a paging carousel. As the featured wallpaper changes, the rest of Discover follows it: a darkened, blurred poster wash behind the collection rows, and the same slide continuing under the sidebar. Wrapping from the last featured wallpaper continues forward instead of rewinding through the strip. The hero dissolve is a dark media scrim that reveals that wash instead of a flat window fill. Reduce Motion keeps paging manual. Reduce Transparency and Increase Contrast keep the page on the semantic window surface.

Earlier systems use system vibrancy/materials.

Ambient Edge is the one expressive visual device. It must never reduce text contrast, stack glass on glass, or become a synthetic gradient. When Reduce Transparency or Increase Contrast is enabled, it becomes an opaque semantic system surface.

## Foundation tokens

### Color

Use semantic macOS colors in production:

- Primary text: `Color.primary`
- Secondary text: `Color.secondary`
- Tertiary text: `Color(nsColor: .tertiaryLabelColor)`
- Window surface: `Color(nsColor: .windowBackgroundColor)`
- Control surface: `Color(nsColor: .controlBackgroundColor)`
- Separator: `Color(nsColor: .separatorColor)`
- Selection and focus: `Color.accentColor`
- Destructive actions: system destructive role

WALI ships with system blue as its default accent but respects the person's macOS accent choice. Fixed color is reserved for artwork metadata or a genuine status meaning. Never use color as the only status cue.

### Typography

Use semantic system styles so macOS controls size, optical variants, localization, and accessibility:

- Window title: `.largeTitle`
- Page title: `.title`
- Section title: `.title2`
- Item name and emphasized labels: `.headline`
- Primary interface copy: `.body`
- Supporting copy: `.callout`
- Metadata: `.caption`
- Compact metadata: `.caption2`
- CPU and memory values: `.body.monospacedDigit()`

Do not bundle or hardcode SF Pro. Do not apply manual tracking to ordinary controls. Large editorial type is allowed only in an empty state or a featured wallpaper hero.

### Spacing

Use this compact Mac rhythm:

- 4 pt: icon/label micro-gap
- 8 pt: related controls
- 12 pt: compact group inset
- 16 pt: standard group inset
- 20 pt: window content edge
- 24 pt: section separation
- 32 pt: major section separation

Media grids use 16 pt gutters and adapt column count to available width. Do not force mobile-sized 44 pt controls everywhere; use native macOS control sizes and preserve accessible hit regions.

### Shape and depth

- Let standard controls own their native shape.
- Wallpaper thumbnails: 12 pt radius.
- Large preview surfaces: 16 pt radius.
- Compact status panels: system container shape.
- Pills are reserved for compact filters, tags, and true binary status—not every button.
- Avoid decorative card shadows. Use hierarchy, material, and content contrast.
- Never place Liquid Glass on content tiles. Glass belongs to navigation and controls.

## Main window

### Window shell

- Standard resizable macOS window with traffic lights, restoration, tabbing behavior, and a unified toolbar.
- Default size: 1120 × 720 pt.
- Minimum useful size: 820 × 560 pt.
- `NavigationSplitView` provides a hideable sidebar.
- Content extends edge-to-edge where system APIs make that safe.
- Closing the window does not stop the wallpaper agent.

### Sidebar

Sections:

1. Discover
2. Browse
3. Creator Studio (signed-in creators)
4. Review Queue (authorized moderators only)
5. Library
6. Downloads
7. Account

Local importing is available from the sidebar plus control, Library/Downloads
empty states, drag and drop, and `⌘O`. Creator Studio is a distinct marketplace
submission flow: rights declaration, resumable upload, server processing, and
review. It never duplicates local import.

Settings stays in the standard application menu and `⌘,`; it is not a fake sidebar page. Sidebar icon color follows the system accent. Selection, row height, disclosure, and hide/show behavior remain native.

### Toolbar

The shared content header stays empty as the selected sidebar page changes. Search and import live in the sidebar; they are not window-toolbar items. App Store–style chrome keeps that common strip still so nothing jumps when the page changes.

- Leading: native sidebar toggle, owned by the sidebar column, sitting in the same strip as the traffic lights. The sidebar material runs to the top of the window. Do not hide the window toolbar: that splits the lights into a disconnected titlebar. On macOS 26+ WALI pins the system `DefaultToolbarItem(kind: .sidebarToggle)` there and removes the wandering split-view copy. On a marketplace wallpaper page, Back is an extra titlebar control placed immediately after that toggle. It is not a SwiftUI `.navigation` toolbar item (that lands in the detail column) and it must not create a second header.
- Search is the system `.searchable` field with sidebar placement, always present, with a stable “Search” prompt.
- Import is a plus control in the sidebar, plus Library/Downloads empty states, drag and drop, and `⌘O`. It is not a window-toolbar button.
- Display assignment belongs to Apply: the Library inspector already lists displays. There is no display button in the header.
- Playback and renderer status live in the menu-bar extra, not the window toolbar.
- Browse sort lives on the Browse page, not the window toolbar.
- Creator Studio upload lives on that page, not the window toolbar.
- The split-view tracking separator is hidden with AppKit’s `sidebarTrackingSeparator` / `isHidden` APIs. Liquid Glass grouping on the sidebar toggle uses `sharedBackgroundVisibility(.hidden)` (WWDC 25). Collapse still uses the sidebar toggle.
- Wallpaper details open in a trailing inspector after selection on Library only. Discover, Browse, Account, and Creator Studio must not show an inspector chevron.
- Display assignment opens from the inspector when applying a wallpaper. Its centered, proportional monitor tiles are selection
  controls, not draggable arrangement controls. Tiles show the current wallpaper,
  display role, and scaling mode; the detail inspector's Apply button remains the
  only commit point for wallpaper changes.

Toolbar items use native grouping. Do not hide the toolbar background; Liquid Glass and the scroll edge effect own that surface.

### Wallpaper surfaces

- Artwork dominates each tile. Library and Discover lockups keep labels below; Browse masonry tiles are image-only until hover.
- **Discover** is editorial: a composed **Featured** carousel sits above the collection rows. It gathers unique published wallpapers from Discover home (not a single collection’s first item), **continues under the floating sidebar** as the real artwork (not a mirrored copy), and **dissolves through a dark media scrim into a wash of the current featured wallpaper**. Collection name, wallpaper title, and a View action sit on that scrim, inset from the sidebar. Featured wallpapers page horizontally with a native indicator and auto-advance unless Reduce Motion is on; wrapping from the last slide continues forward instead of rewinding, and the next card does not peek as a rounded tile. Collection rows rest **after the overlay sidebar** (title and first lockup), then continue **under that glass** when scrolled. Those lockups are landscape **16:10** shelves — three across the visible column with 40 pt gutters, matching Apple’s media-catalog rows — not a 2:3 movie-poster crop of a Mac wallpaper. Featured banner paging and the ambient wash crossfade without resizing the page. Remaining Discover chrome uses the standard 12 pt thumbnail radius.
- **Browse** is the catalog index: searchable and sortable. It is a dense **masonry of native-aspect artwork** (portrait, landscape, and square tiles packed into 3–6 columns with 8 pt gutters), not a second Discover and not a uniform 2:3 poster grid. Tiles are image-first; title and creator appear on hover. Sort stays on the page.
- Library is a **16:10 grid that fills the column** (2–4 equal tiles), not a 2:3 movie-poster strip. Titles sit under the artwork; hash-prefixed import filenames are shown as readable names. The inspector and preview keep a 16:10 crop because they represent a Mac display.
- Hovering for 350 ms starts one silent low-resolution preview. Leaving stops and releases it.
- Only one grid preview may decode at a time.
- Single click selects. Double click applies. Space opens a Quick Look-style preview.
- A detail surface shows full preview, title, creator/license, dimensions, duration, file size, per-display targets, scaling, and Apply.
- A marketplace detail opens on a **full-viewport hero**. The canonical
  playback video fills the
  window, including under the overlay sidebar and through the unified titlebar
  to the top of the window. The window toolbar stays for traffic lights and the
  sidebar toggle; its background is hidden on this page so it does not paint a
  strip over the artwork. Back sits beside the sidebar toggle in that same
  titlebar row, not as a floating control on the image and not in a second bar.
  Title, description, compact specs, and primary actions sit on that image.
  Scrolling reveals rights, license, and related wallpapers on the semantic
  surface. Reduce Motion replaces the moving hero with its verified poster.
- Catalog cards may preview on hover, but detail plays the verified canonical
  `video_default` master. The cheaper preview rung is for grids only.
  Marketplace counters
  are server aggregates; WALI never invents a live-viewer count.
- Scaling is saved with each display assignment: Fill Screen, Fit to Screen, Stretch to Fill, or Center at native size.
- Imported videos clearly show conversion state.

### Empty, loading, and error states

- Empty Library: explain how to drag in a video and provide one `Import Video…` action.
- Loading: preserve layout with neutral placeholders; do not show indefinite decorative animation.
- Error: name the failed operation and offer the next action. Preserve the source file.
- Connection and import notices are a single material banner anchored **bottom-trailing** in the window, with a dismiss control. They must not recenter when the sidebar page or inspector changes.
- Offline catalog: keep local wallpapers usable and label remote content as unavailable.

## Menu-bar control

The global control belongs in the **macOS menu bar** at the top-right of the screen. It is not technically part of a window title bar. Playback pause/resume and renderer status are not duplicated in the main window header.

Clicking the menu-bar icon opens a compact, popover-like window containing:

1. Active wallpaper thumbnail, title, and target display count.
2. Renderer status: Playing, Automatically Paused, User Paused, Converting, or Error.
3. WALI process CPU and physical-memory usage.
4. Primary controls: Pause/Resume, Next, and Open WALI.
5. Secondary actions: Stop Wallpaper, Settings…, and Quit WALI.

`Stop Wallpaper` stops rendering but leaves WALI available. `Quit WALI` exits the agent and main app. Destructive or disruptive actions use explicit labels rather than ambiguous icon-only controls.

Performance sampling is demand-driven: 1 Hz while the popover or diagnostics view is visible, then suspended. The monitor must not create meaningful background energy use.

## Lock Screen continuity

WALI renders the signed-in user's desktop and follows that desktop across Spaces, display reconnects, wake, and unlock. macOS does not expose a public API for an app to draw arbitrary content inside the protected Lock Screen or FileVault login surface.

Settings uses a native `Form` section with one opt-in toggle beside direct,
inline status text. Permission copy names `WALI Lock Screen Helper` as the only
WALI product that may receive Full Disk Access and explicitly excludes the main
app, agent, catalog, downloads, previews, and desktop playback. Ad-hoc Debug
builds cannot authenticate the signed helper boundary and must not receive the
permission. The feature is labeled experimental private compatibility:
it mirrors active assignments through Apple's current-user Aerial provider on
verified macOS builds. The copy states that the authenticated Lock Screen has
an independent playback timeline and that FileVault startup is unavailable.
Turning the toggle off rolls back only WALI-owned records.
The Lock Screen mirrors the main display's assignment as one global Aerial
selection. While enabled, WALI temporarily clears per-display and per-Space
overrides so macOS uses that linked selection everywhere; disabling restores
the exact prior values when they remain safe to restore. A conflicting external
change is preserved and reported rather than overwritten.

This is never presented as direct Lock Screen drawing or a frame-continuous
handoff. It does not add custom chrome, elevated setup, a server, or a separate
Create surface.

## Motion and interaction

- Prefer native transitions and control feedback.
- Give feedback on press, not after an action completes.
- Any gesture-driven motion must begin from its current presentation state and remain interruptible.
- Preserve velocity only when a real drag or flick supplies momentum; routine controls do not bounce.
- Enter and exit along the same spatial path, with popovers anchored to the control that opened them.
- Repeated keyboard actions are immediate and do not wait for decorative animation.
- Use short state transitions around 150–220 ms; use spring behavior only for spatial changes.
- Never animate continuously in the application chrome.
- Wallpaper previews crossfade only after the replacement frame is ready.
- Respect Reduce Motion, Reduce Transparency, Increase Contrast, VoiceOver, Full Keyboard Access, and system appearance.
- Preserve focus during background updates.
- Every menu action has a discoverable command and standard shortcut where one exists.

Core shortcuts:

- `⌘F`: Search
- `⌘O`: Import video
- `Space`: Preview selection
- `Return`: Apply selection
- `⌘⇧P`: Pause or resume wallpaper
- `⌘,`: Settings
- `⌘Q`: Quit WALI

## Performance rules visible in design

- Never autoplay more than one preview in the browser.
- Do not poll metrics when no diagnostics surface is visible.
- Pause preview playback when the app window is occluded.
- Show conversion progress without blocking browsing.
- Surface asset size before download and storage used in Settings.
- Use thumbnails for grids; never decode full wallpaper media merely to draw a tile.
- Keep the catalog application disposable: the lightweight wallpaper agent continues after the main window closes.

## Guardrails

Do:

- Use native SwiftUI/AppKit controls and semantic values.
- Let artwork provide color and atmosphere.
- Keep actions named consistently across toolbar, menu bar, context menus, and commands.
- Test light, dark, graphite accent, increased contrast, and reduced transparency.
- Verify layouts at minimum, default, and wide window sizes.

Do not:

- Recreate apple.com inside a desktop window.
- Fake Liquid Glass with layered blur effects.
- hide standard window behavior to appear “custom.”
- Put every group in a rounded card.
- use web-style oversized type for routine app content.
- Copy Backdrop's branding, artwork, proprietary layout, or private service behavior.
