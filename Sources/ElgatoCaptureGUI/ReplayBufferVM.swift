import SwiftUI
import CaptureCore

/// Replay buffer + replay-action sub-VM: buffer stats, replay duration/RAM
/// settings, thumbnails, save/screenshot feedback. didSet side-effects (engine
/// limit updates, settings persistence, thumbnail trim) are wired in by the
/// parent CaptureViewModel via the callback hooks below.
@MainActor
final class ReplayBufferVM: ObservableObject {

    // Live buffer stats (updated by the parent VM's 1Hz timer)
    @Published var bufferDuration: Double = 0
    @Published var bufferFrameCount: Int = 0
    @Published var bufferSizeMB: Int = 0

    // User-configurable replay settings
    @Published var replayDuration: Double = 30 {
        didSet { replayDurationChanged?(replayDuration) }
    }
    @Published var customReplayDuration: String = "" // for custom entry
    @Published var maxReplayRAM: Int = 0 { // bytes, 0 = unlimited
        didSet { maxReplayRAMChanged?(maxReplayRAM) }
    }

    /// Length to write when Save Replay is triggered. `0` is the "full buffer"
    /// sentinel — saves whatever the buffer currently contains, tracking it as
    /// the buffer grows/shrinks. Otherwise should satisfy `0 < saveDuration <=
    /// replayDuration`; the parent VM clamps it when `replayDuration` shrinks.
    @Published var saveDuration: Double = 0 {
        didSet { saveDurationChanged?(saveDuration) }
    }

    // Visual artefacts
    @Published var replayThumbnails: [ReplayThumbnail] = []

    // Action feedback
    @Published var replaySaveFeedback: ActionFeedback = .idle
    @Published var screenshotFeedback: ActionFeedback = .idle

    // Callbacks installed by CaptureViewModel.
    var replayDurationChanged: ((Double) -> Void)?
    var maxReplayRAMChanged: ((Int) -> Void)?
    var saveDurationChanged: ((Double) -> Void)?

    /// Effective save length given the current buffer cap. `0` is treated as "full
    /// buffer" and returns `replayDuration`; any positive value is clamped to
    /// `replayDuration` so the UI can't request more than the buffer can hold.
    var effectiveSaveDuration: Double {
        saveDuration <= 0 ? replayDuration : min(saveDuration, replayDuration)
    }

    /// True when the user has explicitly chosen a length shorter than the buffer.
    var isSaveDurationCustom: Bool {
        saveDuration > 0 && saveDuration < replayDuration
    }
}
