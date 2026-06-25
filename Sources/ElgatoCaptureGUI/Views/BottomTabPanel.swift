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
