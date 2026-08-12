import AppKit
import Combine
import SwiftUI

/// NSWindowController hosting SettingsView.
///
/// Mirrors assist-ant's PreferencesWindowController, itself mirroring Galaxy's:
/// same title, same content auto-sizing, same Escape handling, same live
/// appearance updates.
///
/// Deliberately NOT app-modal, which is the one place this departs from the
/// siblings — and it departs to keep their reason rather than their code.
///
/// They run modal so key events cannot leak through to the main window
/// underneath. A menu bar accessory has no main window to protect; the window
/// underneath belongs to somebody else's application, which macOS already
/// keeps separate. So modality buys nothing here, and it costs: under
/// `runModal` in an accessory application the pop-up menus would not open and
/// the controls rendered half-drawn.
final class PreferencesWindowController: NSWindowController {
    private static var shared: PreferencesWindowController?
    private var escapeMonitor: Any?
    private var themeObserver: AnyCancellable?

    static func showPreferences() {
        if shared == nil { shared = PreferencesWindowController() }
        guard let controller = shared, let window = controller.window else { return }

        controller.applyAppearance(ThemeController.shared.theme)
        window.center()
        window.makeKeyAndOrderFront(nil)
        // An accessory application is never frontmost, so a window ordered
        // front without this arrives behind whatever is being looked at.
        NSApp.activate(ignoringOtherApps: true)
        controller.startWatchingForEscape()
    }

    /// Escape is intercepted at the event level because NSHostingView swallows
    /// the key event before it reaches the responder chain.
    ///
    /// Guarded on the window being key: without modality this monitor sees
    /// every keystroke the application receives, and closing settings because
    /// Escape was pressed somewhere else would be its own bug.
    private func startWatchingForEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.keyCode == 53 {
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func stopWatchingForEscape() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    private init() {
        // The hosting controller publishes SwiftUI's preferred content size,
        // so the window is exactly as tall as the selected tab needs — General
        // is short, Connections is not. Without `.preferredContentSize` only
        // growth propagates reliably, and the window sticks at the tallest tab
        // it has ever shown.
        let hostingController = NSHostingController(rootView: SettingsView())
        hostingController.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        // Named for the same reason the content names it: so the titlebar
        // resolves to the surface underneath it rather than to whatever a
        // window would otherwise pick.
        window.backgroundColor = .windowBackgroundColor
        // Just "Settings". The application's name is already on the window,
        // and every other application on the machine says only this.
        window.title = "Settings"

        super.init(window: window)

        window.delegate = self
        window.center()
        applyAppearance(ThemeController.shared.theme)

        // Appearance changes are applied to the live window rather than by
        // rebuilding the view hierarchy, so the window being used to change
        // the setting updates underneath the change.
        themeObserver = ThemeController.shared.$theme
            .removeDuplicates()
            .sink { [weak self] theme in self?.applyAppearance(theme) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Nil inherits the system appearance — that is how matching it works.
    private func applyAppearance(_ theme: ThemePreference) {
        window?.appearance = nsAppearance(for: theme)
    }

    private func nsAppearance(for theme: ThemePreference) -> NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    fileprivate func dismiss() {
        stopWatchingForEscape()
        // Ordered out rather than closed: closing animates, and the controller
        // is reused rather than rebuilt on the next opening.
        window?.orderOut(nil)
    }
}

extension PreferencesWindowController: NSWindowDelegate {
    /// The close button routes through the same path as Escape, so the event
    /// monitor is torn down either way rather than outliving the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}
