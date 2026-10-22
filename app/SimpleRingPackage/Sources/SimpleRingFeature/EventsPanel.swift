import SwiftUI
import AVKit
import UniformTypeIdentifiers
import RingClient
import DesignSystem

// MARK: - Events List

/// Recent rings and motion, grouped by day. Live-view events are hidden: the
/// app itself creates one every time the window opens.
struct EventsPanel: View {
    let events: [RingEvent]
    let selectedEventId: String?
    let onSelect: (RingEvent) -> Void

    private enum Filter { case ring, motion }
    @State private var filter: Filter?

    private var relevantEvents: [RingEvent] {
        events.filter { $0.kind == .ding || $0.kind == .motion }
    }

    private var visibleEvents: [RingEvent] {
        switch filter {
        case nil: return relevantEvents
        case .ring: return relevantEvents.filter { $0.kind == .ding }
        case .motion: return relevantEvents.filter { $0.kind == .motion }
        }
    }

    private var sections: [(title: String, events: [RingEvent])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleEvents) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            (Self.dayTitle(for: day), grouped[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.sm)

            if visibleEvents.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.title) { section in
                            Section {
                                ForEach(section.events) { event in
                                    EventRow(event: event, isSelected: event.id == selectedEventId) {
                                        onSelect(event)
                                    }
                                }
                            } header: {
                                Text(section.title.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Spacing.sm)
                                    .padding(.top, Spacing.sm)
                                    .padding(.bottom, Spacing.xs)
                                    .background(Color(white: 0.07))
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.bottom, Spacing.sm)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text("\(relevantEvents.count) event\(relevantEvents.count == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))

            Spacer()

            FilterPill(title: "Rings", systemName: "bell.fill", isOn: filter == .ring) {
                filter = filter == .ring ? nil : .ring
            }
            FilterPill(title: "Motion", systemName: "figure.walk", isOn: filter == .motion) {
                filter = filter == .motion ? nil : .motion
            }
        }
        .animation(.easeInOut(duration: 0.15), value: filter)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: filter == .ring ? "bell.slash" : "figure.walk.motion")
                .font(.system(size: 20))
                .foregroundStyle(.white.opacity(0.3))
            Text(filter == nil ? "No recent events" : "No matching events")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        return formatter
    }()

    private static func dayTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return weekdayFormatter.string(from: day)
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: RingEvent
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private var isRing: Bool { event.kind == .ding }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isRing ? "bell.fill" : "figure.walk")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isRing ? Color.Ring.accent : .white.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isRing ? Color.Ring.accent.opacity(0.18) : .white.opacity(0.08))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(isRing ? "Doorbell ring" : "Motion")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    if let deviceName = event.deviceName {
                        Text(deviceName)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: Spacing.sm)

                if isSelected || isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.Ring.accent : .white.opacity(0.6))
                }
                Text(Self.timeFormatter.string(from: event.createdAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.Ring.accent.opacity(0.16) : (isHovering ? .white.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Filter Pill

private struct FilterPill: View {
    let title: String
    let systemName: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.Ring.accent : .white.opacity(0.65))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? Color.Ring.accent.opacity(0.2) : .white.opacity(0.07)))
            .overlay(Capsule().strokeBorder(isOn ? Color.Ring.accent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Recording Overlay

/// State of a recording being shown in place of the live video.
struct RecordingState: Equatable {
    let event: RingEvent
    var url: URL?
    var error: String?

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        lhs.event.id == rhs.event.id && lhs.url == rhs.url && lhs.error == rhs.error
    }
}

/// Plays an event recording over the live video area.
struct RecordingOverlay: View {
    let recording: RecordingState
    let onBackToLive: () -> Void

    @State private var player: AVPlayer?

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        ZStack {
            Color.black

            if let player {
                VideoPlayer(player: player)
            } else if let error = recording.error {
                VStack(spacing: Spacing.sm) {
                    Image(systemName: "film")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.4))
                    Text(error)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
                .padding(Spacing.xl)
            } else {
                VStack(spacing: Spacing.md) {
                    ProgressView().tint(.white)
                    Text("Loading recording…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            VStack {
                topBar
                Spacer()
            }
        }
        .onAppear { updatePlayer() }
        .onChange(of: recording.url) { _, _ in updatePlayer() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var topBar: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: onBackToLive) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                    Circle()
                        .fill(Color.Ring.live)
                        .frame(width: 6, height: 6)
                    Text("Live")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
            }
            .buttonStyle(.plain)
            .help("Back to live view")

            VStack(alignment: .leading, spacing: 0) {
                Text(recording.event.kind == .ding ? "Doorbell ring" : "Motion")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text([recording.event.deviceName, Self.titleFormatter.string(from: recording.event.createdAt)]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.sm)

            if let url = recording.url {
                GlassButton(systemName: "square.and.arrow.down", size: 28, help: "Save recording") {
                    save(url)
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 4)
        .padding(Spacing.md)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private func updatePlayer() {
        player?.pause()
        guard let url = recording.url else {
            player = nil
            return
        }
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }

    private func save(_ url: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(recording.event.deviceName ?? "Ring") \(formatter.string(from: recording.event.createdAt)).mp4"
        panel.level = .modalPanel  // above the floating menu bar panel
        panel.begin { result in
            guard result == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                ringLog.error("❌ Failed to save recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
