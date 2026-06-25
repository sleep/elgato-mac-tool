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
