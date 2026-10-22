import Foundation
import UserNotifications
import RingClient

// MARK: - Notification Manager

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = NotificationManager()

    private let seenEventsKey = "seenEventIds"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission

    public func requestPermission() async -> Bool {
        do {
            let center = UNUserNotificationCenter.current()
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            NSLog("🔔 Notification permission error: \(error)")
            return false
        }
    }

    // MARK: - Send Notification

    public func sendNotification(for event: RingEvent) async {
        let content = UNMutableNotificationContent()

        switch event.kind {
        case .ding:
            content.title = "Ring"
            content.body = "Someone at \(event.deviceName ?? "your door")"
        case .motion:
            content.title = "Motion"
            content.body = "Movement at \(event.deviceName ?? "your camera")"
        case .onDemand, .other:
            return
        }
        let soundEnabled = UserDefaults.standard.object(forKey: "notificationSound") as? Bool ?? true
        if soundEnabled {
            content.sound = .default
        }

        // Add event ID to userInfo for potential click handling
        content.userInfo = ["eventId": event.id]

        let request = UNNotificationRequest(
            identifier: event.id,
            content: content,
            trigger: nil  // Deliver immediately
        )

        do {
            let center = UNUserNotificationCenter.current()
            try await center.add(request)
            // Mark as seen
            markEventAsSeen(event.id)
        } catch {
            NSLog("🔔 Failed to send notification: \(error)")
        }
    }

    // MARK: - Detect New Events

    public func detectNewEvents(old: [RingEvent], new: [RingEvent]) -> [RingEvent] {
        let oldIds = Set(old.map { $0.id })
        let seenIds = getSeenEventIds()
        let twoMinutesAgo = Date().addingTimeInterval(-120)

        return new.filter { event in
            // Must be a new event (not in old list and not previously seen)
            let isNew = !oldIds.contains(event.id) && !seenIds.contains(event.id)
            // Must be recent (within 2 minutes) to avoid spam on launch
            let isRecent = event.createdAt > twoMinutesAgo
            // Only ding and motion events
            let isNotifiable = event.kind == .ding || event.kind == .motion

            return isNew && isRecent && isNotifiable
        }
    }

    // MARK: - Seen Events Persistence

    private func getSeenEventIds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenEventsKey) ?? [])
    }

    private func markEventAsSeen(_ eventId: String) {
        // Ordered oldest -> newest so trimming drops the oldest IDs
        // (a Set has no order, so trimming it dropped arbitrary IDs)
        var seen = UserDefaults.standard.stringArray(forKey: seenEventsKey) ?? []
        seen.removeAll { $0 == eventId }
        seen.append(eventId)
        UserDefaults.standard.set(Array(seen.suffix(100)), forKey: seenEventsKey)
    }

    // MARK: - Delegate Methods

    // Handle notification when app is in foreground
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show banner even when app is open
        return [.banner, .sound]
    }

    // Handle notification tap
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .showMenuBarWindow, object: nil)
        }
    }
}
