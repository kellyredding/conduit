import AppKit
import SwiftUI

/// Starts and stops polling with the application itself. The menu bar item has
/// no lifecycle callbacks of its own, and the store must run whether or not the
/// menu has ever been opened — the icon is the entire interface most of the
/// time.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Becomes a menu bar accessory here rather than through LSUIElement in
        // the bundle. The key would hide it from Launch Services as well as
        // from the Dock, and an application nothing can find is a poor one to
        // ship — doing it at runtime keeps the icon out of the Dock and the
        // ⌘-Tab switcher while leaving it listed everywhere it is looked for.
        NSApp.setActivationPolicy(.accessory)

        // The client writes a log a day and removes none of them, and this is
        // the only thing that will. Repeating rather than running once at
        // launch: with login items arriving, this process can stay up for
        // weeks, and housekeeping that only happens at startup stops
        // happening at all on exactly the machines that need it most.
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let home = ConduitConfig.clientHome
                // Retention first: it removes whole days cheaply, and the cap
                // then only has to deal with whatever bulk is left.
                ClientLogs.prune(
                    clientHome: home,
                    retainingDays: ConduitConfig.int("log-retention-days") ?? 3
                )
                ClientLogs.enforceCap(
                    clientHome: home,
                    maxBytes: Int64(ConduitConfig.int("log-max-megabytes") ?? 5)
                        * 1_048_576
                )
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }

        // Asked at launch rather than at the first interesting moment: a
        // permission prompt arriving in the same instant as the news it wants
        // to deliver costs the notification it was asking for.
        Notifier.requestAuthorization()

        Task { @MainActor in ThemeController.shared.reload() }

        Task { @MainActor in VPNStore.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in VPNStore.shared.stop() }
    }
}

@main
struct ConduitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = VPNStore.shared
    @ObservedObject private var appearance = ThemeController.shared

    var body: some Scene {
        MenuBarExtra {
            // The panel lives in a window macOS owns, so it takes a colour
            // scheme rather than an NSAppearance. Nil inherits the system one.
            MenuContent(store: store)
                .preferredColorScheme(appearance.colorScheme)
        } label: {
            // Rendered as a template, so macOS paints it in the menu bar's own
            // foreground colour and it follows the system appearance without a
            // second asset. Every state is separated by shape rather than by
            // colour, which is what keeps them apart at this size.
            Image(systemName: store.iconState.symbolName)
                .accessibilityLabel(store.iconState.accessibilityLabel)
        }
        // `.menu` renders a real NSMenu, which cannot host a live throughput
        // readout or a wrapped health banner.
        .menuBarExtraStyle(.window)
    }
}
