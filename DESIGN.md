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

## Signature element — Ambient Edge

The selected wallpaper may extend beneath the sidebar and toolbar so the system material picks up a faint amount of its color. On macOS 26+, native Liquid Glass and background-extension APIs create this response. Earlier systems use system vibrancy/materials.

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

1. Library
2. Downloads

Importing is available from the toolbar, the empty Library and Downloads states, and drag and drop. A separate Create destination would duplicate that flow and is intentionally omitted.

Settings stays in the standard application menu and `⌘,`; it is not a fake sidebar page. Sidebar icon color follows the system accent. Selection, row height, disclosure, and hide/show behavior remain native.

### Toolbar

- Leading: native sidebar toggle and navigation history when applicable.
- Center/primary area: search scoped to the current library surface.
- Trailing: display assignment, active-wallpaper state, and a WALI status button.
- Display assignment opens a popover that mirrors the connected display geometry
  reported by macOS. Its centered, proportional monitor tiles are selection
  controls, not draggable arrangement controls. Tiles show the current wallpaper,
  display role, and scaling mode; the detail surface's Apply button remains the
  only commit point for wallpaper changes.
- The WALI status button opens the same compact status content used by the menu-bar extra: renderer CPU, memory, playback state, and quick controls.

Toolbar items use native grouping. No custom toolbar background is drawn.

### Wallpaper surfaces

- Artwork dominates each tile; labels and metadata sit below or in a legible system material only when necessary.
- Default thumbnails use a 16:10 crop because they represent Mac displays.
- Hovering for 350 ms starts one silent low-resolution preview. Leaving stops and releases it.
- Only one grid preview may decode at a time.
- Single click selects. Double click applies. Space opens a Quick Look-style preview.
- A detail surface shows full preview, title, creator/license, dimensions, duration, file size, per-display targets, scaling, and Apply.
- Scaling is saved with each display assignment: Fill Screen, Fit to Screen, Stretch to Fill, or Center at native size.
- Imported videos clearly show conversion state.

### Empty, loading, and error states

- Empty Library: explain how to drag in a video and provide one `Import Video…` action.
- Loading: preserve layout with neutral placeholders; do not show indefinite decorative animation.
- Error: name the failed operation and offer the next action. Preserve the source file.
- Offline catalog: keep local wallpapers usable and label remote content as unavailable.

## Menu-bar control

The global control belongs in the **macOS menu bar** at the top-right of the screen. It is not technically part of a window title bar.

WALI also exposes a matching status button in the main window toolbar so the controls are available in both contexts.

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
inline status text. The feature is labeled experimental private compatibility:
it mirrors active assignments through Apple's current-user Aerial provider on
verified macOS builds. The copy states that the authenticated Lock Screen has
an independent playback timeline and that FileVault startup is unavailable.
Turning the toggle off rolls back only WALI-owned records.
If Apple has not created a per-display override yet, WALI may add a reversible
top-level override for that connected display; it never changes the global,
system-default, or Space-default selection.

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
