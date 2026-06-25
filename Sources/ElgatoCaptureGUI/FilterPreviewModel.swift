import SwiftUI
// CaptureCore predates Swift concurrency annotations; @preconcurrency silences the
// Sendable advisory for capturing the (internally thread-safe) engine in renderQueue.
@preconcurrency import CaptureCore

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
