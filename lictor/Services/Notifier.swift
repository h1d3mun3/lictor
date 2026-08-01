//
//  Notifier.swift
//  lictor
//
//  Notifications the app owns. The agent owns the automatic-disable notification
//  and this file must not duplicate it (ADR-0009).
//
//  The five-minute warning is the reason this exists. Turning SSH off kills live
//  sessions (ADR-0008), so an expiry that arrives unannounced destroys whatever was
//  running. The warning is what makes the deadline survivable, and letting it
//  lapse is the safe outcome: doing nothing closes SSH, extending takes a
//  deliberate act.
//

import Foundation
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    nonisolated private static let expiringCategory = "lictor.expiring"
    nonisolated private static let extendAction = "lictor.extend"

    /// How much time the Extend button grants, measured from when it is granted.
    static let extensionGranted: SessionDuration = .thirtyMinutes

    /// Invoked when the user taps Extend. Set by the Monitor.
    var onExtend: (() -> Void)?

    /// Requests permission and registers the actionable category.
    ///
    /// Failure is not fatal: notifications are a convenience layer, and the
    /// enforcement path does not depend on them at all.
    func configure() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let extend = UNNotificationAction(
            identifier: Self.extendAction,
            title: "Extend \(Self.extensionGranted.label)",
            options: [.authenticationRequired])

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.expiringCategory,
                actions: [extend],
                intentIdentifiers: [],
                options: [])
        ])

        // The answer is deliberately not kept. Caching it means a user who denies
        // at first launch and later turns Lictor on in System Settings gets no
        // notifications until the app restarts -- which for a menu bar resident
        // can be weeks. The system already drops requests from an unauthorised
        // app, so asking every time costs nothing and cannot go stale.
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    // MARK: - Posting

    func notifyEnabled(until deadline: Date) {
        post(id: "enabled-\(deadline.timeIntervalSince1970)",
             title: "SSH enabled",
             body: "Closes automatically at \(formatExpiry(deadline)).")
    }

    func notifyExtended(until deadline: Date) {
        post(id: "extended-\(deadline.timeIntervalSince1970)",
             title: "SSH extended",
             body: "Now closes automatically at \(formatExpiry(deadline)).")
    }

    func notifyExpiringSoon(remaining: TimeInterval) {
        post(id: "expiring",
             title: "SSH closes in \(formatRemaining(remaining))",
             body: "Any connected session will be disconnected. Extend to keep it open.",
             category: Self.expiringCategory)
    }

    private func post(id: String, title: String, body: String, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Show notifications even though a menu bar app is never really frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.extendAction else { return }
        await MainActor.run { self.onExtend?() }
    }
}
