import AppKit
import SwiftUI

/// Starts and stops polling with the application itself. The menu bar item has
/// no lifecycle callbacks of its own, and the store must run whether or not the
/// menu has ever been opened — the icon is the entire interface most of the
/// time.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
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
