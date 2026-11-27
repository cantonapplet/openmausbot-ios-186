import Foundation
import Intents
import SwiftUI
import UserNotifications
import UIKit
import CompanionCore

/// The on-device notification surface. Delivery comes from live or replayed
/// companion frames; a future APNs relay can feed the same categories and
/// userInfo without changing the rest of the app.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()
    private let center = UNUserNotificationCenter.current()
    private var lastBadgeCount: Int?
    /// Set by `Session`; kept as an id-only value so the notification layer
    /// does not know about SwiftUI navigation or mutable fleet state.
    var responseHandler: ((NotificationTarget) -> Void)?

    private override init() {
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true
    }

    /// Only requests arriving while this app is not on screen become iOS
    /// notifications. While the person is in the app, the roster and Updates
    /// bar are the signal; a banner would duplicate them.
    @MainActor
    func deliver(_ notification: NotificationFrame, sequence: Int?, botColor: String?) {
        guard UIApplication.shared.applicationState == .background else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = notification.isBlocking ? "OPENMAUS_APPROVAL" : "OPENMAUS_UPDATE"
        content.threadIdentifier = notification.threadId
        content.userInfo = [
            "threadId": notification.threadId,
            "botId": notification.botId,
            "kind": notification.kind,
        ]
        if notification.isBlocking { content.interruptionLevel = .timeSensitive }

        // A messaging notification puts the bot's face where the app icon
        // would otherwise be. If the system will not adopt the intent, the
        // image falls back to a normal notification attachment.
        var delivered: UNNotificationContent = content
        if let botColor, let data = avatarData(for: botColor) {
            let person = INPerson(
                personHandle: INPersonHandle(value: notification.botId, type: .unknown),
                nameComponents: nil,
                displayName: notification.botName,
                image: INImage(imageData: data),
                contactIdentifier: nil,
                customIdentifier: notification.botId
            )
            let intent = INSendMessageIntent(
                recipients: nil,
                outgoingMessageType: .outgoingMessageText,
                content: notification.body,
                speakableGroupName: nil,
                conversationIdentifier: notification.threadId,
                serviceName: "MausBot",
                sender: person,
                attachments: nil
            )
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            interaction.donate(completion: nil)
            if let updated = try? content.updating(from: intent),
               let mutable = updated.mutableCopy() as? UNMutableNotificationContent {
                mutable.categoryIdentifier = content.categoryIdentifier
                mutable.threadIdentifier = content.threadIdentifier
                mutable.userInfo = content.userInfo
                if notification.isBlocking { mutable.interruptionLevel = .timeSensitive }
                delivered = mutable
            }
        }

        // A replay after a short disconnect must reconcile a missed alert,
        // but a repeated frame must not draw it twice.
        let identifier = "openmaus.\(notification.threadId).\(sequence.map(String.init) ?? notification.title)"
        center.add(UNNotificationRequest(identifier: identifier, content: delivered, trigger: nil))
    }

    /// The bot's face rendered once, used either as the sender image or as
    /// the fallback attachment.
    @MainActor
    private func avatarData(for colorName: String) -> Data? {
        let face = ZStack {
            Rectangle().fill(MausPalette.color(colorName))
            MausFaceStill(color: colorName, state: .idle, size: 72)
        }
        .frame(width: 96, height: 96)
        let renderer = ImageRenderer(content: face)
        renderer.scale = 3
        return renderer.uiImage?.pngData()
    }

    /// Opening the app takes every delivered alert out of Notification
    /// Centre; what still matters is in the roster.
    @MainActor
    func clearDelivered() {
        center.removeAllDeliveredNotifications()
    }

    func setBadge(_ count: Int) {
        let count = max(0, count)
        guard count != lastBadgeCount else { return }
        lastBadgeCount = count
        center.setBadgeCount(count) { [weak self] error in
            if error != nil {
                DispatchQueue.main.async { self?.lastBadgeCount = nil }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A notification scheduled in the background can land just as the
        // person returns; never show it over the app itself.
        completionHandler([])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let strings = response.notification.request.content.userInfo.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else { return }
            result[key] = value
        }
        if let target = NotificationTarget(payload: strings) { responseHandler?(target) }
        completionHandler()
    }
}
