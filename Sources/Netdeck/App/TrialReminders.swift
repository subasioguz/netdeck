import Foundation
import NetdeckCore
import SwiftUI
import UserNotifications

/// A local notification one minute before a confirmation timer ends (§3.9, Settings → General).
/// Netdeck sets no notification delegate, so macOS shows it only while Netdeck is in the background;
/// in the foreground the banners already count down. Permission is asked the first time a timer
/// starts with the setting on.
@MainActor
final class TrialReminders {
    /// Device ID → the deadline its reminder was scheduled for.
    private var scheduled: [String: Date] = [:]
    private var askedForPermission = false

    /// `UNUserNotificationCenter.current()` traps in a bare SwiftPM executable without a bundle
    /// identifier, so renders and `swift run` skip notifications altogether.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && !RenderMode.active }

    private static func identifier(_ deviceID: String) -> String { "netdeck.confirm-reminder." + deviceID }

    /// Brings the scheduled reminders in line with the timers running now: new timers get one,
    /// confirmed, rolled-back or replaced timers lose theirs.
    func sync(_ waiting: [(id: String, name: String, deadline: Date)], enabled: Bool) {
        guard Self.isAvailable else { return }
        var wanted: [String: (name: String, deadline: Date)] = [:]
        if enabled { for w in waiting { wanted[w.id] = (w.name, w.deadline) } }

        let stale = scheduled.filter { wanted[$0.key]?.deadline != $0.value }.map(\.key)
        if !stale.isEmpty {
            let ids = stale.map(Self.identifier)
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
            stale.forEach { scheduled[$0] = nil }
        }

        for (id, w) in wanted where scheduled[id] == nil {
            let delay = w.deadline.addingTimeInterval(-60).timeIntervalSinceNow
            guard delay > 1 else { continue }   // less than a minute left: the banner is already red
            scheduled[id] = w.deadline
            let ask = !askedForPermission
            askedForPermission = true
            let title = w.name, body = t("If you don't confirm within 1 minute, the switch rolls back.")
            let identifier = Self.identifier(id)
            Task {
                let center = UNUserNotificationCenter.current()
                if ask { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            }
        }
    }
}

/// Runs `AppModel.runTrialClock()` again whenever a timer or a trial outcome changes. Invisible.
struct TrialClock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: model.trialClockKey) {
                guard !RenderMode.active else { return }
                await model.runTrialClock()
            }
    }
}
