# Bottom Tab Panel: Frames / Filters — Design

**Date:** 2026-06-25
**Status:** Approved

## Summary

Replace the bottom status area of the macOS capture app's main window — currently the
replay-frame timeline strip plus a "Capturing from <device>" status line — with a small
**tabbed panel** containing two tabs:

- **Frames** — the existing replay thumbnail timeline (unchanged).
- **Filters** — a new horizontal row of *live* preview tiles, one per video filter preset,
  each showing the current camera frame with that filter applied. Tapping a tile selects
  the filter (Photo-Booth-style live filter picker).

The "Capturing from <device>" line is removed; the device name already appears in the
device dropdown on the left of the controls row. Error messages remain visible.

## Motivation

The app already ships a full filter engine — 13 presets (`VideoFilter`) plus four
adjustment sliders (brightness/contrast/saturation/hue) — but the only place to pick a
filter is the Settings panel, where presets are shown as static color swatches with no
preview of the actual output. Users can't see what a filter does to *their* signal without
selecting it and watching the main preview, one at a time. A live, side-by-side grid makes
filter selection visual and immediate.

## Current state (as built)

- `Views/ReplayThumbnailStrip.swift` — horizontal `ScrollView` of 80×45 frame tiles with
  relative-age labels ("-19m50s"). Shown in `ContentView.swift` `normalView` only when
  `recording.isCapturing && !replay.replayThumbnails.isEmpty`.
- `Views/StatusMessageBanner.swift` — renders `recording.errorMessage` (priority) else
  `recording.statusMessage`. The capturing status is set in `CaptureViewModel` line ~557:
  `recording.statusMessage = "Capturing from \(device.localizedName)"`.
- `SettingsView.swift` — `GroupBox("Filters")` with a `LazyVGrid` of `FilterChip`s bound to
  `settings.previewFilter`; `GroupBox("Adjustments")` with the four sliders + master
  `settings.visualEffectsEnabled` toggle.
- `AppSettings.swift` — persisted `previewFilter`, `previewBrightness/Contrast/Saturation/
  HueDegrees`, `visualEffectsEnabled`; computed `previewAdjustments` and `effectsActive`.
- `CaptureViewModel.pushVisualEffectsToEngine()` — rebuilds the CIFilter chain from settings
  and calls `engine.setVisualEffectFilters(_:)`; fires whenever any filter setting changes.
- `CaptureEngine.swift` — bakes the active filter chain into every frame in `captureOutput`;
  stores the result in `latestPixelBuffer` (already filtered). `createThumbnail(maxWidth:)`
  renders `latestPixelBuffer` off-thread via `thumbnailContext`. There is **no** path to
  render a *different* filter chain for preview.

## Design

### 1. Layout & structure

In `ContentView.normalView`, the region currently occupied by `ReplayThumbnailStrip` and the
routine "Capturing from…" banner becomes a tab panel, shown while capturing:

```
┌ [ Frames | Filters ] ──────────────────────────────┐   segmented tab bar, left-aligned
│  ‹ timeline strip  OR  live filter row ›            │   ~68pt tall, same for both tabs
└─────────────────────────────────────────────────────┘
```

- Tab selection: `@State private var bottomTab: BottomTab = .frames` on `ContentView`
  (`enum BottomTab { case frames, filters }`).
- **Frames** tab content: existing `ReplayThumbnailStrip(replay:)`, unchanged.
- **Filters** tab content: new `FilterPreviewStrip`.
- The panel is gated to `recording.isCapturing` (same condition that gates the timeline
  today). When not capturing, the area collapses to a `Spacer()` as it does now.
- `StatusMessageBanner` keeps showing errors **and** transient status messages
  ("Screenshot saved", "Reconnecting…", "Replay saved", etc.), but suppresses the
  **steady-state** "Capturing from…" message (it adds `&& !statusMessage.hasPrefix("Capturing
  from")` to the status branch). This is Mac-UI-only: the underlying `statusMessage` is left
  intact, so the web remote and all transient feedback are unaffected.

### 2. Engine support — the core change

`CaptureEngine` keeps only the filtered frame, so it cannot render alternative looks. Two
additions:

1. **Retain the latest raw buffer.** Add `private var latestRawPixelBuffer: CVPixelBuffer?`
   guarded by the existing `latestFrameLock`. In `captureOutput`, store `rawPixelBuffer`
   (the pre-filter buffer) alongside the existing `latestPixelBuffer` assignment.

2. **Public preview render method:**
   ```swift
   /// Render the latest RAW (pre-effects) frame with an arbitrary filter chain into a
   /// thumbnail. Used by the live filter picker to show each preset side-by-side without
   /// disturbing the active effects chain. Thread-safe; safe to call off the main thread.
   public func renderFilterPreview(maxWidth: CGFloat, filters: [CIFilter]) -> CGImage?
   ```
   Implementation mirrors `createThumbnail`: lock, copy `latestRawPixelBuffer`, unlock;
   build `CIImage(cvPixelBuffer:)`; apply each filter in `filters` in order (empty chain =
   raw frame); scale to `maxWidth`; render via the existing off-thread `thumbnailContext`.
   The live render loop (`renderFilteredFrame` / `effectsContext`) is untouched, avoiding
   contention with the capture queue.

### 3. Filter preview model

New `FilterPreviewModel: ObservableObject` drives the grid:

- Holds `@Published var images: [VideoFilter: NSImage]`.
- A throttled timer (~0.4s, i.e. ~2–3 fps) runs **only while the Filters tab is active and
  `recording.isCapturing`**. Started/stopped by the view via `.onAppear`/`.onDisappear` and
  `onChange(of: bottomTab)` / `onChange(of: isCapturing)`.
- Each tick, on a background queue: for each `VideoFilter.allCases`, build the chain via
  `VideoFilterChain.buildFilters(adjustments: settings.previewAdjustments, filter:)`
  (WYSIWYG — the preset layered over the user's current adjustment sliders), call
  `engine.renderFilterPreview(maxWidth: 160, filters:)`, collect `[VideoFilter: NSImage]`,
  and publish on the main actor.
- `maxWidth: 160` source for 80pt tiles (retina-crisp). 13 small renders per tick is cheap.

### 4. FilterPreviewStrip view

- Horizontal `ScrollView` mirroring `ReplayThumbnailStrip` styling: 80×45 tiles, corner
  radius 4, name label below (`filter.label`) in the same small monospaced/secondary style.
- Tile image = `model.images[filter]`; before the first frame, fall back to the existing
  static swatch gradient (`filter.swatchColor`) as a placeholder so the row is never empty.
- The currently-selected filter (`settings.previewFilter == filter`) gets a highlight ring
  (accent stroke) + checkmark badge.
- Tap action:
  ```swift
  settings.previewFilter = filter
  settings.visualEffectsEnabled = true   // auto-enable so the main preview matches
  ```
  Both already trigger `pushVisualEffectsToEngine()`. The Settings filter grid stays in sync
  because it binds the same `AppSettings` properties.

### 5. Files

**New**
- `Views/FilterPreviewStrip.swift` — the live tile row.
- `Views/BottomTabPanel.swift` — segmented tab bar + content switch (`BottomTab` enum).
- `FilterPreviewModel.swift` — throttled off-thread thumbnail renderer.

**Changed**
- `Sources/CaptureCore/CaptureEngine.swift` — `latestRawPixelBuffer` + `renderFilterPreview`.
- `Sources/ElgatoCaptureGUI/ContentView.swift` — swap the timeline region for the tab panel;
  gate `StatusMessageBanner` to errors only.

## Scope boundaries (YAGNI)

- The tab panel appears **only while capturing** — the live grid needs the video-data-output
  frames that flow during capture. Picking filters before capture stays in Settings.
- No new persisted settings; reuses existing `AppSettings` filter properties.
- No change to the live render/encode path or the web remote UI.
- Tiles render the preset over current adjustments (WYSIWYG), not a normalized
  preset-only look.

## Performance

- Grid renders 13 thumbnails at ~2–3 fps, off the main thread, on the existing
  `thumbnailContext`. Tiny images → negligible GPU cost.
- Strictly gated to "Filters tab visible + capturing"; zero cost otherwise (timer not
  running, no raw-buffer extra work beyond a pointer assignment in `captureOutput`).

## Testing

- Manual: start capture, switch to Filters tab, confirm tiles show live frames with distinct
  looks; tap a tile and confirm the main preview + Settings grid update and effects enable.
- Confirm switching to Frames tab stops the preview timer (no ongoing render work).
- Confirm error messages still display; routine "Capturing from…" no longer shows.
- Confirm no regression to the live preview/recording path (filters still bake correctly).
