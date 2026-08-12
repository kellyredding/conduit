import Foundation
import UserNotifications
import os

/// Says out loud what the menu bar cannot.
///
/// Deliberately outside Models: that layer is compiled by the sandboxed check
/// target and has to stay Foundation-only, and this needs UserNotifications.
///
/// Two things shape everything here. The bar carries no profile name — nothing
/// legible survived at that size — so this is the only surface that can say
/// *which* tunnel changed, which is most of the value once more than one
/// profile exists. And the person is usually looking at something else
/// entirely: agents connect and disconnect on their behalf while they work in
/// another application, and a change nobody witnessed is exactly the change
/// worth announcing.
enum Notifier {
    private static let log = Logger(
        subsystem: "com.kellyredding.Conduit", category: "notify"
    )

    /// Requested once at launch rather than at the first interesting moment.
    /// A permission prompt arriving in the same instant as the news it wants
    /// to deliver costs the notification it was asking for.
    static func requestAuthorization() {
        Task.detached(priority: .utility) {
            do {
                // Sound is deliberately absent. With an agent driving
                // connections these arrive unpredictably and often, and a
                // noise per tunnel change is the fastest way to have the whole
                // category muted — which would take the useful ones with it.
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert])
                log.notice("authorization granted=\(granted, privacy: .public)")
            } catch {
                // Never fatal. A menu bar that reports VPN state is still
                // worth running without permission to interrupt, and the most
                // common cause is a build the notification service will not
                // register at all.
                log.error(
                    "authorization failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Titles carry the profile; bodies carry the circumstance.
    ///
    /// Worded as observation, never as cause. Conduit cannot know why a
    /// connection ended — the client reports no reason, the daemon cannot be
    /// asked, and the transition that would have carried the hint was measured
    /// twice and does not survive a poll. "Dev disconnected" is true whether a
    /// person tore it down or the tunnel collapsed; "Dev dropped" is a guess
    /// that will be wrong regularly and teaches the reader to distrust the
    /// rest.
    static func post(title: String, body: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        Task.detached(priority: .utility) {
            do {
                try await UNUserNotificationCenter.current().add(request)
                // Logged on success as well as failure. Only an error line
                // meant "posted fine" and "never ran" were indistinguishable
                // from outside, and confirming a notification had actually
                // been sent otherwise meant reading Apple's own subsystem log.
                //
                // The profile is deliberately not named, same as the restore
                // log: this repository is public and the unified log is
                // readable by anything on the machine.
                log.notice("posted")
            } catch {
                log.error(
                    "post failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
