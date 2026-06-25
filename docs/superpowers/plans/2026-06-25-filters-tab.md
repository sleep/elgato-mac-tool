# Filters Tab (Bottom Tab Panel) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the bottom status/timeline area of the macOS capture app with a two-tab panel — "Frames" (the existing replay timeline) and "Filters" (a live, Photo-Booth-style picker showing the current camera frame through each filter preset).

**Architecture:** The engine retains the latest *raw* (pre-effects) frame and exposes a thread-safe method to render it through an arbitrary CIFilter chain into a thumbnail. A throttled `ObservableObject` renders every preset off the main thread while the Filters tab is visible during capture, and a SwiftUI strip displays the tiles. Selecting a tile sets `AppSettings.previewFilter` and enables effects, reusing the existing settings→engine plumbing.

**Tech Stack:** Swift 5.9, SwiftPM (no test target), SwiftUI, AppKit, Core Image, Core Video. Build/verify with `swift build` plus manual run (this repo has no unit-test harness; verification is compile + observed behavior).

## Global Constraints

- **No `^`/ambiguous versions, no new dependencies** — pure stdlib/Apple frameworks only.
- **No AI-branding in commits or branches** — no `Co-Authored-By: Claude`, no `claude/`/`ai/` branch prefixes. Match repo style (`feat:` / `fix:` Conventional Commit prefixes).
- **Match existing patterns** — tile sizing (80×45, corner radius 4), monospaced size-8 labels, and `.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))` come straight from `ReplayThumbnailStrip.swift`.
- **Do not alter the live render/encode path** (`renderFilteredFrame`, `effectsContext`, `effectsPool`) or the web remote UI.
- **Engine accessor:** `vm.engine` (`CaptureViewModel.engine: CaptureEngine`, line 34).

---

### Task 1: Engine — retain raw frame + `renderFilterPreview`

**Files:**
- Modify: `Sources/CaptureCore/CaptureEngine.swift` (property ~line 17; `captureOutput` ~lines 996-998; new method after `createThumbnail` ~line 777)

**Interfaces:**
- Produces: `public func renderFilterPreview(maxWidth: CGFloat, filters: [CIFilter]) -> CGImage?` on `CaptureEngine`. Returns nil if no frame yet or a filter fails. Empty `filters` ⇒ the raw look.

- [ ] **Step 1: Add the raw-buffer storage property.** In `CaptureEngine.swift`, change the block at line 17-18 from:

```swift
    private(set) public var latestPixelBuffer: CVPixelBuffer?
    private let latestFrameLock = NSLock()
```

to:

```swift
    private(set) public var latestPixelBuffer: CVPixelBuffer?
    /// The most recent UNFILTERED camera frame, retained so the filter picker can
    /// render alternative looks without disturbing the active effects chain.
    private var latestRawPixelBuffer: CVPixelBuffer?
    private let latestFrameLock = NSLock()
```

- [ ] **Step 2: Store the raw buffer in `captureOutput`.** Change the block at lines 996-998 from:

```swift
        latestFrameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestFrameLock.unlock()
```

to:

```swift
        latestFrameLock.lock()
        latestPixelBuffer = pixelBuffer
        latestRawPixelBuffer = rawPixelBuffer
        latestFrameLock.unlock()
```

- [ ] **Step 3: Add the `renderFilterPreview` method.** Immediately after `createThumbnail(maxWidth:)` (ends at line 777), insert:

```swift
    /// Render the latest UNFILTERED frame through an arbitrary CIFilter chain and
    /// return a scaled thumbnail. Used by the live filter picker to show every
    /// preset side-by-side. Pass an empty `filters` array for the raw look.
    /// Thread-safe — designed to be called from a background queue.
    public func renderFilterPreview(maxWidth: CGFloat, filters: [CIFilter]) -> CGImage? {
        latestFrameLock.lock()
        let pb = latestRawPixelBuffer
        latestFrameLock.unlock()
        guard let pb else { return nil }

        var ci = CIImage(cvPixelBuffer: pb)
        for filter in filters {
            filter.setValue(ci, forKey: kCIInputImageKey)
            guard let output = filter.outputImage else { return nil }
            ci = output
        }
        let scale = maxWidth / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return thumbnailContext.createCGImage(scaled, from: scaled.extent)
    }
```

- [ ] **Step 4: Build.**

Run: `swift build`
Expected: `Build complete!` with no errors or warnings from `CaptureEngine.swift`.

- [ ] **Step 5: Commit.**

```bash
git add Sources/CaptureCore/CaptureEngine.swift
git commit -m "feat: retain raw frame + renderFilterPreview for live filter picker"
```

---

### Task 2: `FilterPreviewModel` — throttled off-thread renderer

**Files:**
- Create: `Sources/ElgatoCaptureGUI/FilterPreviewModel.swift`

**Interfaces:**
- Consumes: `CaptureEngine.renderFilterPreview(maxWidth:filters:)` (Task 1); `VideoFilterChain.buildFilters(adjustments:filter:) -> [CIFilter]` and `VideoFilter.allCases` (existing in `VideoAdjustments.swift`); `VideoAdjustments` (existing).
- Produces: `@MainActor final class FilterPreviewModel: ObservableObject` with `@Published private(set) var images: [VideoFilter: NSImage]`, `var adjustments: VideoAdjustments`, `init(engine:)`, `func start()`, `func stop()`.

- [ ] **Step 1: Create the file** `Sources/ElgatoCaptureGUI/FilterPreviewModel.swift` with:

```swift
import SwiftUI
import CaptureCore

/// Drives the live filter-picker grid: on a throttled timer it renders the latest
/// camera frame through every `VideoFilter` preset (layered over the user's current
/// adjustments) and publishes the resulting thumbnails.
///
/// The timer only runs between `start()` and `stop()` — the view ties that to
/// (Filters tab visible && capturing) so no render work happens otherwise.
@MainActor
final class FilterPreviewModel: ObservableObject {
    @Published private(set) var images: [VideoFilter: NSImage] = [:]

    /// Adjustments the presets are layered on top of (WYSIWYG with the sliders).
    var adjustments: VideoAdjustments = .neutral

    private let engine: CaptureEngine
    private var timer: Timer?
    private let renderQueue = DispatchQueue(label: "filter.preview.render", qos: .utility)
    private var rendering = false

    init(engine: CaptureEngine) {
        self.engine = engine
    }

    func start() {
        guard timer == nil else { return }
        // ~2.5 fps — enough to feel live, cheap on the GPU.
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick() // render immediately so the grid isn't blank on open
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !rendering else { return }   // skip if a render is still in flight
        rendering = true
        let adjustments = self.adjustments
        let engine = self.engine
        renderQueue.async { [weak self] in
            var rendered: [VideoFilter: NSImage] = [:]
            for filter in VideoFilter.allCases {
                let chain = VideoFilterChain.buildFilters(adjustments: adjustments, filter: filter)
                if let cg = engine.renderFilterPreview(maxWidth: 160, filters: chain) {
                    rendered[filter] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            Task { @MainActor in
                guard let self else { return }
                if !rendered.isEmpty { self.images = rendered }
                self.rendering = false
            }
        }
    }
}
```

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: `Build complete!` — `FilterPreviewModel.swift` compiles. (No runtime exercise yet; it's wired up in Task 4.)

- [ ] **Step 3: Commit.**

```bash
git add Sources/ElgatoCaptureGUI/FilterPreviewModel.swift
git commit -m "feat: FilterPreviewModel renders all presets on a throttled background timer"
```

---

### Task 3: `FilterPreviewStrip` — the live tile row

**Files:**
- Create: `Sources/ElgatoCaptureGUI/Views/FilterPreviewStrip.swift`

**Interfaces:**
- Consumes: `FilterPreviewModel.images` (Task 2); `AppSettings.previewFilter`, `.visualEffectsEnabled` (existing `@Published`); `VideoFilter.allCases`, `.label`, `.swatchColor` (existing).
- Produces: `struct FilterPreviewStrip: View` with `init(settings: AppSettings, model: FilterPreviewModel)` (memberwise via `@ObservedObject` properties).

- [ ] **Step 1: Create the file** `Sources/ElgatoCaptureGUI/Views/FilterPreviewStrip.swift` with:

```swift
import SwiftUI
import CaptureCore

/// Horizontal row of live filter previews. Each tile shows the current camera frame
/// with one `VideoFilter` preset applied; tapping selects it and enables the master
/// effects toggle so the main preview matches immediately. Mirrors ReplayThumbnailStrip.
struct FilterPreviewStrip: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: FilterPreviewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(VideoFilter.allCases) { filter in
                    FilterPreviewTile(
                        filter: filter,
                        image: model.images[filter],
                        isSelected: settings.visualEffectsEnabled && settings.previewFilter == filter
                    ) {
                        settings.previewFilter = filter
                        settings.visualEffectsEnabled = true
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .frame(height: 68)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FilterPreviewTile: View {
    let filter: VideoFilter
    let image: NSImage?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // No frame yet — fall back to the preset's swatch colour.
                        LinearGradient(
                            colors: [filter.swatchColor.opacity(0.65), filter.swatchColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                    }
                }
                .frame(width: 80, height: 45)
                .clipped()
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : .white.opacity(0.1),
                                lineWidth: isSelected ? 2 : 0.5)
                )
                Text(filter.label)
                    .font(.system(size: 8, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Build.**

Run: `swift build`
Expected: `Build complete!` — `FilterPreviewStrip.swift` compiles.

- [ ] **Step 3: Commit.**

```bash
git add Sources/ElgatoCaptureGUI/Views/FilterPreviewStrip.swift
git commit -m "feat: FilterPreviewStrip live filter tile row"
```

---

### Task 4: `BottomTabPanel` + ContentView wiring + status suppression

**Files:**
- Create: `Sources/ElgatoCaptureGUI/Views/BottomTabPanel.swift`
- Modify: `Sources/ElgatoCaptureGUI/ContentView.swift` (`ContentBody` state ~line 36; `normalView` controls block lines 174-179 and after 211)
- Modify: `Sources/ElgatoCaptureGUI/Views/StatusMessageBanner.swift` (line 20)

**Interfaces:**
- Consumes: `FilterPreviewModel` (Task 2), `FilterPreviewStrip` (Task 3), `ReplayThumbnailStrip` (existing), `vm.engine` (`CaptureEngine`), `AppSettings.previewAdjustments`/slider props (existing), `ReplayBufferVM`, `RecordingVM`.
- Produces: `enum BottomTab` and `struct BottomTabPanel: View` with `init(selection: Binding<BottomTab>, settings: AppSettings, replay: ReplayBufferVM, recording: RecordingVM, engine: CaptureEngine)`.

- [ ] **Step 1: Create** `Sources/ElgatoCaptureGUI/Views/BottomTabPanel.swift` with:

```swift
import SwiftUI
import CaptureCore

enum BottomTab: String, CaseIterable, Identifiable {
    case frames, filters
    var id: String { rawValue }
    var label: String {
        switch self {
        case .frames: return "Frames"
        case .filters: return "Filters"
        }
    }
}

/// The tabbed strip beneath the controls: "Frames" shows the replay timeline,
/// "Filters" shows the live filter picker. Shown only while capturing. Owns the
/// FilterPreviewModel and runs its render timer only while the Filters tab is up.
struct BottomTabPanel: View {
    @Binding var selection: BottomTab
    @ObservedObject var settings: AppSettings
    @ObservedObject var replay: ReplayBufferVM
    @ObservedObject var recording: RecordingVM
    @StateObject private var filterModel: FilterPreviewModel

    init(selection: Binding<BottomTab>,
         settings: AppSettings,
         replay: ReplayBufferVM,
         recording: RecordingVM,
         engine: CaptureEngine) {
        self._selection = selection
        self.settings = settings
        self.replay = replay
        self.recording = recording
        self._filterModel = StateObject(wrappedValue: FilterPreviewModel(engine: engine))
    }

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $selection) {
                ForEach(BottomTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)

            switch selection {
            case .frames:
                ReplayThumbnailStrip(replay: replay)
            case .filters:
                FilterPreviewStrip(settings: settings, model: filterModel)
            }
        }
        .onAppear { syncModel() }
        .onDisappear { filterModel.stop() }
        .onChange(of: selection) { _ in syncModel() }
        .onChange(of: recording.isCapturing) { _ in syncModel() }
        .onChange(of: settings.previewBrightness) { _ in pushAdjustments() }
        .onChange(of: settings.previewContrast) { _ in pushAdjustments() }
        .onChange(of: settings.previewSaturation) { _ in pushAdjustments() }
        .onChange(of: settings.previewHueDegrees) { _ in pushAdjustments() }
    }

    private func pushAdjustments() {
        filterModel.adjustments = settings.previewAdjustments
    }

    private func syncModel() {
        pushAdjustments()
        if selection == .filters && recording.isCapturing {
            filterModel.start()
        } else {
            filterModel.stop()
        }
    }
}
```

- [ ] **Step 2: Add tab state to `ContentBody`.** In `ContentView.swift`, after line 36 (`@State private var showReplaySettings = false`) add:

```swift
    @State private var bottomTab: BottomTab = .frames
```

- [ ] **Step 3: Remove the inline strip from the controls row.** In `normalView`, replace lines 174-179:

```swift
                    if recording.isCapturing && !replay.replayThumbnails.isEmpty {
                        ReplayThumbnailStrip(replay: replay)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        Spacer()
                    }
```

with:

```swift
                    Spacer()
```

- [ ] **Step 4: Add the full-width tab panel below the controls.** In the same `VStack(spacing: 12)`, between the `ReplaySettingsPanel` block (ends line 211) and `StatusMessageBanner(recording: recording)` (line 213), insert:

```swift
                if recording.isCapturing {
                    BottomTabPanel(
                        selection: $bottomTab,
                        settings: settings,
                        replay: replay,
                        recording: recording,
                        engine: vm.engine
                    )
                }
```

- [ ] **Step 5: Suppress the steady "Capturing from" status.** In `StatusMessageBanner.swift`, change line 20 from:

```swift
        } else if !recording.statusMessage.isEmpty {
```

to:

```swift
        // Device name already shows in the left dropdown, so the steady "Capturing
        // from …" message is hidden here; transient statuses + errors still show.
        } else if !recording.statusMessage.isEmpty && !recording.statusMessage.hasPrefix("Capturing from") {
```

- [ ] **Step 6: Build.**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 7: Manual run verification.**

Run the GUI (via the `/run` skill or `swift run elgato-capture-gui`) with a capture device connected, then confirm:
1. While capturing, a segmented **Frames | Filters** control appears below the controls; "Capturing from …" no longer shows.
2. **Frames** tab shows the replay timeline as before.
3. **Filters** tab shows a scrolling row of live tiles, each a distinct look of the current frame; the selected filter has an accent ring + checkmark.
4. Tapping a tile updates the main preview immediately and enables effects; the Settings → Filters grid reflects the same selection.
5. Switching back to **Frames** stops the render timer (no lingering CPU/GPU churn — check Activity Monitor or that the app stays responsive).
6. Trigger a transient status (e.g. take a screenshot) and confirm "Screenshot saved" still appears in the banner.

- [ ] **Step 8: Commit.**

```bash
git add Sources/ElgatoCaptureGUI/Views/BottomTabPanel.swift Sources/ElgatoCaptureGUI/ContentView.swift Sources/ElgatoCaptureGUI/Views/StatusMessageBanner.swift
git commit -m "feat: Frames/Filters bottom tab panel with live filter picker"
```

---

## Self-Review

**Spec coverage:**
- §1 layout (tab bar + 68pt strip, capturing-gated, status removed) → Task 4. ✓
- §2 engine raw buffer + `renderFilterPreview` → Task 1. ✓
- §3 throttled off-thread model, WYSIWYG, swatch fallback → Tasks 2 & 3. ✓
- §4 selection sets `previewFilter` + enables effects, Settings stays in sync → Task 3 tap action. ✓
- §5 file list → Tasks 1-4 match exactly. ✓
- §Scope (capturing-only, no new persistence, no render/encode or web change) → respected; status suppression is Mac-UI-only. ✓
- §Performance (gated timer, ~2-3 fps, small images) → Task 2 (0.4s timer, maxWidth 160, in-flight skip). ✓
- §Testing → Task 4 Step 7 manual checklist. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `renderFilterPreview(maxWidth:filters:)`, `FilterPreviewModel(engine:)`/`start()`/`stop()`/`images`/`adjustments`, `FilterPreviewStrip(settings:model:)`, `BottomTabPanel(selection:settings:replay:recording:engine:)`, `BottomTab` — names match across producing/consuming tasks. ✓
