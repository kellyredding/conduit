import AppKit
import Combine
import SwiftUI

/// NSWindowController hosting DetailView.
///
/// Deliberately a near-copy of PreferencesWindowController — same Escape
/// handling, same live appearance updates, same reuse of one instance, same
/// refusal to be app-modal in an accessory application. Two differences, and both
/// are the content's doing rather than a change of mind:
///
///   - **Resizable, and sized once.** The settings window is exactly as tall as
///     its tallest field needs; this one holds lists whose length is decided by
///     the routing table, so it scrolls and can be made bigger. That also means
///     it must not be re-centred on every opening: a window the person has moved
///     and resized should reopen where they left it.
///   - **It starts and stops the sampling.** Doing that here rather than in the
///     view's `onAppear`/`onDisappear` is load-bearing. A window ordered out does
///     not reliably retire the SwiftUI view inside it, so a sampler tied to the
///     view's lifecycle can keep running against a window nobody can see — which
///     is precisely the cost this feature was scoped to avoid, one subprocess per
///     tunnel every couple of seconds, forever.
final class DetailWindowController: NSWindowController {
    private static var shared: DetailWindowController?
    private var escapeMonitor: Any?
    private var themeObserver: AnyCancellable?

    static func showDetail() {
        if shared == nil { shared = DetailWindowController() }
        guard let controller = shared, let window = controller.window else { return }

        controller.applyAppearance(ThemeController.shared.theme)
        // Only on first presentation. Centring an already-placed window would
        // move it out from under the person every time they reopened it.
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        // An accessory application is never frontmost, so a window ordered front
        // without this arrives behind whatever is being looked at.
        NSApp.activate(ignoringOtherApps: true)
        controller.startWatchingForEscape()

        // Last, so the first sample is taken against a window that is already up
        // rather than one that may yet fail to present.
        VPNStore.shared.detailOpened()
    }

    /// Escape is intercepted at the event level because NSHostingView swallows
    /// the key event before it reaches the responder chain.
    ///
    /// Guarded on this window being key: without modality the monitor sees every
    /// keystroke the application receives, and closing this because Escape was
    /// pressed in the panel would be its own bug.
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
        let hostingController = NSHostingController(rootView: DetailView(store: VPNStore.shared))

        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .resizable]
        window.backgroundColor = .windowBackgroundColor
        // Named for what it shows. "Conduit" is already on the window, and the
        // panel above it is where the profiles are acted on — this is the place
        // that describes them.
        window.title = "Connection Details"
        window.setContentSize(NSSize(width: 580, height: 640))
        window.contentMinSize = NSSize(width: 460, height: 320)

        super.init(window: window)

        window.delegate = self
        applyAppearance(ThemeController.shared.theme)

        // Applied to the live window rather than by rebuilding the hierarchy, so
        // changing the theme in the settings window updates this one underneath
        // the change.
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
        // Ordered out rather than closed: closing animates, and the controller is
        // reused rather than rebuilt on the next opening.
        window?.orderOut(nil)
        VPNStore.shared.detailClosed()
    }
}

extension DetailWindowController: NSWindowDelegate {
    /// The close button routes through the same path as Escape, so the sampling
    /// is stopped and the monitor torn down either way rather than outliving the
    /// window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
}
