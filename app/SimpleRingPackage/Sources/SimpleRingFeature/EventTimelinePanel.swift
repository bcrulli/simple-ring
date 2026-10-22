import SwiftUI
import RingClient
import DesignSystem
import AVKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Event Timeline Panel
// Bottom panel: Timeline → Video playback

public struct EventTimelinePanel: View {
    @Binding var playingVideoURL: URL?
    @Binding var isLoadingVideo: Bool

    let events: [RingEvent]
    let onEventTap: (RingEvent) -> Void

    public init(
        playingVideoURL: Binding<URL?>,
        isLoadingVideo: Binding<Bool>,
        events: [RingEvent],
        onEventTap: @escaping (RingEvent) -> Void
    ) {
        self._playingVideoURL = playingVideoURL
        self._isLoadingVideo = isLoadingVideo
        self.events = events
        self.onEventTap = onEventTap
    }

    public var body: some View {
        VStack(spacing: Spacing.sm) {
            // 1. Event Timeline (always visible at top)
            MiniEventTimeline(
                events: events,
                onEventTap: onEventTap
            )

            // 2. Video playback area (when playing history)
            if isLoadingVideo {
                videoLoadingView
            } else if let videoURL = playingVideoURL {
                historyVideoPlayer(url: videoURL)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.black)
    }

    // MARK: - Video Loading View

    private var videoLoadingView: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(.white)
            Text("Loading video...")
                .font(.Ring.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - History Video Player

    private func historyVideoPlayer(url: URL) -> some View {
        ZStack(alignment: .topTrailing) {
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onAppear {
                    // Auto-play
                    let player = AVPlayer(url: url)
                    player.play()
                }

            // Overlay buttons
            HStack(spacing: 6) {
                // Save button
                Button {
                    saveVideo(from: url)
                } label: {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Save video")

                // Close button
                Button {
                    playingVideoURL = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.8))
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(6)
        }
    }

    // MARK: - Save Video

    private func saveVideo(from url: URL) {
        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.mpeg4Movie, .movie]
        savePanel.nameFieldStringValue = "ring_event_\(dateFormatter.string(from: Date())).mp4"
        savePanel.title = "Save Recording"
        savePanel.message = "Choose a location to save the Ring event recording"

        savePanel.begin { result in
            if result == .OK, let destinationURL = savePanel.url {
                do {
                    // Copy from temp location to user-chosen location
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: url, to: destinationURL)
                    NSLog("📥 Saved video to: \(destinationURL.path)")
                } catch {
                    NSLog("❌ Failed to save video: \(error)")
                }
            }
        }
        #endif
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }
}

// MARK: - Event Filter

enum EventFilter: String, CaseIterable {
    case ring = "Ring"
    case motion = "Motion"

    var iconName: String {
        switch self {
        case .ring: return "bell.badge.fill"
        case .motion: return "figure.walk"
        }
    }
}

// MARK: - Mini Event Timeline

public struct MiniEventTimeline: View {
    let events: [RingEvent]
    let onEventTap: (RingEvent) -> Void

    // nil means no filter applied (show all events)
    @State private var selectedFilter: EventFilter?

    private var filteredEvents: [RingEvent] {
        switch selectedFilter {
        case nil:
            return events
        case .ring:
            return events.filter { $0.kind == .ding }
        case .motion:
            return events.filter { $0.kind == .motion }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Header: total count on the left, filters on the right
            HStack(spacing: Spacing.sm) {
                Text("\(events.count) event\(events.count == 1 ? "" : "s")")
                    .font(.Ring.caption)
                    .foregroundStyle(.white.opacity(0.6))

                Spacer()

                // Filter pills
                HStack(spacing: 4) {
                    ForEach(EventFilter.allCases, id: \.self) { filter in
                        FilterPill(
                            filter: filter,
                            isSelected: selectedFilter == filter,
                            count: countForFilter(filter)
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedFilter = (selectedFilter == filter) ? nil : filter
                            }
                        }
                    }
                }
            }

            // Horizontal scroll of event items
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if filteredEvents.isEmpty {
                        Text("No \(selectedFilter?.rawValue.lowercased() ?? "") events")
                            .font(.Ring.caption)
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filteredEvents, id: \.id) { event in
                            EventChip(event: event) {
                                onEventTap(event)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func countForFilter(_ filter: EventFilter) -> Int {
        switch filter {
        case .ring: return events.filter { $0.kind == .ding }.count
        case .motion: return events.filter { $0.kind == .motion }.count
        }
    }
}

// MARK: - Filter Pill

private struct FilterPill: View {
    let filter: EventFilter
    let isSelected: Bool
    let count: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Image(systemName: filter.iconName)
                    .font(.system(size: 9))
                if isSelected {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(isSelected ? Color.Ring.accent : .white.opacity(0.5))
            .padding(.horizontal, isSelected ? 8 : 6)
            .padding(.vertical, 4)
            .background(isSelected ? Color.Ring.accent.opacity(0.2) : Color.white.opacity(0.05))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Event Chip (Compact)

private struct EventChip: View {
    let event: RingEvent
    let onTap: () -> Void

    private var label: String {
        switch event.kind {
        case .ding: return "Ring"
        case .motion: return "Motion"
        case .onDemand: return "Live"
        }
    }

    private var timeAgo: String {
        let interval = Date().timeIntervalSince(event.createdAt)
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        } else if interval < 86400 {
            return "\(Int(interval / 3600))h"
        } else {
            return "\(Int(interval / 86400))d"
        }
    }

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Text(timeAgo)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(event.kind == .ding ? Color.Ring.accent : .white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(event.kind == .ding ? Color.Ring.accent.opacity(0.2) : Color.white.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#if DEBUG
struct EventTimelinePanel_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black

            VStack {
                Spacer()

                EventTimelinePanel(
                    playingVideoURL: .constant(nil),
                    isLoadingVideo: .constant(false),
                    events: [],
                    onEventTap: { _ in }
                )
            }
            .padding()
        }
        .frame(width: 340, height: 400)
    }
}
#endif
