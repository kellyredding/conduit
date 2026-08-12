import Foundation
import ServiceManagement
import os

/// Whether macOS starts Conduit when the user logs in.
///
/// This is what makes restoring a connection after a wake worth having rather
/// than incidental. Conduit only restores tunnels it was running to observe —
/// a launch has no memory of what was up before it — so an application that
/// starts with the session is the state the whole feature assumes. Off by
/// default anyway: registering a login item on someone's behalf without asking
/// is exactly the kind of thing that gets an application deleted.
enum LaunchAtLogin {
    private static let log = Logger(
        subsystem: "com.kellyredding.Conduit", category: "login-item"
    )

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Reported rather than thrown. There is nothing a menu bar can usefully
    /// do about a refused registration except stop claiming it worked, and the
    /// toggle reads back from the real status rather than from what was asked.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            log.notice("set enabled=\(enabled, privacy: .public)")
        } catch {
            log.error(
                """
                could not set enabled=\(enabled, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
        return isEnabled
    }

    /// Distinguishes "the user said no" from "macOS is holding this back".
    ///
    /// A registration the system has flagged shows up in Login Items as a
    /// blocked entry, and until someone approves it there the app is
    /// registered and not launching — a state no amount of retrying moves.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
