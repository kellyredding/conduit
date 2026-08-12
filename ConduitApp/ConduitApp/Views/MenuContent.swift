import SwiftUI

/// The dropdown: every profile's state, and the two things you can do about it.
struct MenuContent: View {
    @ObservedObject var store: VPNStore

    /// The profile whose confirmation is currently being asked for.
    ///
    /// Asked inline rather than in a sheet. This panel closes when it loses
    /// focus, and anything presented over it inherits that — a confirmation
    /// that can vanish mid-question is worse than none, because the answer it
    /// was protecting is the one nobody should give by accident.
    @State private var confirming: String?

    /// The panel's own window, so Escape can close it.
    @State private var panelWindow: NSWindow?
    @State private var escapeMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "Conduit VPN" rather than "Conduit": the panel can be opened
            // from a bar full of unlabelled glyphs, and the heading is the
            // only place that says what this one is for.
            Text("Conduit VPN")
                .font(.headline)
                .padding(.bottom, 10)

            if case .unavailable(let reason) = store.health {
                banner(reason)
            }

            if store.profiles.isEmpty {
                empty
            } else {
                ForEach(store.profiles, id: \.name) { profile in
                    ProfileRow(
                        profile: profile,
                        counters: store.counters[profile.name],
                        note: store.notes[profile.name],
                        isActing: store.isActing(on: profile.name),
                        isConfirming: confirming == profile.name,
                        onPrimary: { primaryAction(for: profile) },
                        onConfirm: {
                            confirming = nil
                            store.connect(profile: profile.name, confirmed: true)
                        },
                        onDismissConfirm: { confirming = nil },
                        onCancelAttempt: {
                            store.cancelAttempt(profile: profile.name)
                        }
                    )
                }
            }

            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 320)
        // The same surface the settings window sits on.
        //
        // Left alone, this panel is drawn on a system vibrancy material: it is
        // translucent, so it takes a tint from whatever happens to be behind
        // it and never quite matches a window of ours. Painting the semantic
        // window colour over it makes the two read as one piece of software,
        // and being semantic it resolves for light and dark without either
        // being named here.
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor { panelWindow = $0 })
        .onAppear {
            store.menuOpened()
            startWatchingForEscape()
        }
        .onDisappear {
            store.menuClosed()
            stopWatchingForEscape()
        }
    }

    /// Escape closes the panel, the same as it closes the settings window.
    ///
    /// Monitored rather than handled through the responder chain because the
    /// hosting view swallows the keystroke before it gets there — the same
    /// reason the settings window monitors for it.
    ///
    /// Torn down when the panel goes away, so this is never watching while
    /// there is nothing to close.
    private func startWatchingForEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }

            // Dismissed the way clicking the item dismisses it, rather than by
            // hiding the window underneath SwiftUI. Only that path updates
            // what SwiftUI believes about the panel, and the item's selected
            // state is drawn from that belief.
            if !MenuBarItem.dismissPanel() {
                // No status item found. The panel closing matters more than
                // the highlight, so fall back to hiding the window.
                panelWindow?.orderOut(nil)
            }
            return nil
        }
    }

    private func stopWatchingForEscape() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
    }

    /// A transitional profile disconnects rather than connects, because that is
    /// the only thing that reaches it: while an attempt is held, the client
    /// refuses a new one and says the profile is already connected. Offering
    /// Connect there would present the one action guaranteed to be refused.
    private func primaryAction(for profile: ProfileState) {
        if profile.isConnected || profile.isInFlight {
            store.disconnect(profile: profile.name)
        } else if profile.isSensitive {
            confirming = profile.name
        } else {
            store.connect(profile: profile.name, confirmed: false)
        }
    }

    private func banner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(reason).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 8)
    }

    // Conduit does not install profiles, so none is a legitimate state rather
    // than an error.
    private var empty: some View {
        Text("No profiles are installed.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    /// Glyphs rather than words. Every one of these is a verb the whole system
    /// already spells this way, and the row reads as a set of controls instead
    /// of a sentence competing with the profile names above it. Each keeps a
    /// tooltip and an accessibility label, because a bare symbol says nothing
    /// to anyone navigating by voice or by screen reader.
    ///
    /// Grouped by what they touch: the two that concern the application sit
    /// together on the left, and leaving it sits alone on the right, where a
    /// mis-click costs the least.
    private var footer: some View {
        HStack(spacing: 14) {
            glyph(
                "gearshape.fill",
                help: "Settings",
                shortcut: ",",
                action: { PreferencesWindowController.showPreferences() }
            )
            glyph(
                "arrow.clockwise",
                help: "Refresh now",
                action: { store.refreshNow() }
            )

            Spacer()

            glyph(
                "power",
                help: "Quit",
                shortcut: "q",
                action: { NSApplication.shared.terminate(nil) }
            )
        }
        .font(.callout)
    }

    @ViewBuilder
    private func glyph(
        _ symbol: String,
        help: String,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)

        if let shortcut {
            button.keyboardShortcut(shortcut)
        } else {
            button
        }
    }
}

/// The panel is the only surface that marks a sensitive row — the menu bar has
/// no glyph for it, having found none readable at that size — so the name lives
/// with the rule rather than with the icon states.
private let sensitiveSymbol = Sensitivity.markSymbolName

/// Both ends of a row are sized to the whole row — the name and the status
/// beneath it — rather than to the single line they happen to sit beside. It
/// makes the row read as one object with a state at each end, and it keeps the
/// two marks the same weight as each other, which they would not be if each
/// were sized to its own neighbour.
private let rowMarkSize: CGFloat = 22

private struct ProfileRow: View {
    let profile: ProfileState
    let counters: VPNByteCounters?
    let note: String?
    let isActing: Bool
    let isConfirming: Bool
    let onPrimary: () -> Void
    let onConfirm: () -> Void
    let onDismissConfirm: () -> Void
    let onCancelAttempt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: indicator)
                    .font(.system(size: rowMarkSize, weight: .regular))
                    .foregroundStyle(profile.isConnected ? .primary : .tertiary)
                    .frame(width: rowMarkSize + 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)

                    // Throughput sits with the status rather than off to the
                    // right, which leaves the trailing edge free for the mark
                    // and stops the two competing for the same space on a
                    // connected row.
                    HStack(spacing: 6) {
                        Text(profile.label)
                        if let counters {
                            Text(traffic(counters))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    // Kept on its own line rather than replacing the status.
                    // What the client reports and what Conduit has to say about
                    // it are different claims, and a browser waiting for a
                    // sign-in is not a substitute for knowing the tunnel is
                    // still down.
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                if profile.isSensitive {
                    // Sized to the whole row rather than to the name it
                    // follows. This is the one piece of information here that
                    // changes what a person is allowed to do without thinking,
                    // so it is the one thing that should be legible before the
                    // row is read.
                    Image(systemName: sensitiveSymbol)
                        .font(.system(size: rowMarkSize, weight: .regular))
                        .foregroundStyle(.secondary)
                        .help("Needs confirmation before connecting")
                }

                action
            }

            if isConfirming { confirmation }
        }
        .padding(.vertical, 8)
    }

    /// While Conduit is driving an attempt the only thing offered is stopping
    /// it. Starting a second one is not a thing the client can honour, and a
    /// button that exists to be refused teaches people to distrust the panel.
    @ViewBuilder private var action: some View {
        if isActing {
            Button("Cancel", action: onCancelAttempt)
                .controlSize(.small)
        } else if isConfirming {
            // The prompt below carries its own buttons; a third one up here
            // would leave two Connects on screen meaning different things.
            EmptyView()
        } else {
            Button(actionLabel, action: onPrimary)
                .controlSize(.small)
        }
    }

    private var actionLabel: String {
        profile.isConnected || profile.isInFlight ? "Disconnect" : "Connect"
    }

    /// Names the profile rather than saying "this one". The whole purpose of
    /// the question is to make the answer specific, and a confirmation that
    /// does not say what it is confirming is a button that gets pressed.
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect to \(profile.name)?")
                .font(.callout)
                .fontWeight(.medium)
            Text("This profile is marked as needing confirmation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Connect", action: onConfirm)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel", action: onDismissConfirm)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    // A dashed empty ring, then the bolt inside a ring, then the bolt inside
    // a filled disc. The two active marks carry the bolt, so a live or
    // settling row shows the same shape the menu bar is showing at that
    // moment and the eye can travel between them; the inactive one carries
    // nothing, which is the whole of what it has to say.
    //
    // The in-flight mark is taken from the icon state rather than named again
    // here, because it is literally the glyph the bar displays while an
    // attempt is running, and two places naming it separately is how they
    // come to disagree.
    private var indicator: String {
        // The same question the bar asks, so a row cannot claim a profile is
        // settling while the bar says nothing is happening.
        let configured = ConduitConfig.seconds("connect-timeout")
        if profile.isSettling(within: configured > 0 ? configured : 120) {
            return MenuIconState.connecting.symbolName
        }
        return profile.isConnected ? "bolt.horizontal.circle.fill" : "circle.dashed"
    }

    // Cumulative totals, which is all the client reports. Rates require
    // differencing successive samples and belong with the history that will
    // hold them.
    private func traffic(_ counters: VPNByteCounters) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return "↓\(formatter.string(fromByteCount: counters.tunnelIn))"
            + "  ↑\(formatter.string(fromByteCount: counters.tunnelOut))"
    }
}

/// The menu bar item, and the only handle there is on it.
///
/// Three attempts went at the selected state directly — clearing the button's
/// highlight, clearing its state, deactivating the application — and every one
/// of them failed for the same reason: the panel was being closed behind
/// SwiftUI's back, so SwiftUI went on believing it was presented and kept
/// drawing the item to match. The state was never the thing to fix.
///
/// Clicking the button is the path SwiftUI itself uses. It toggles the panel
/// shut and updates the item together, because to SwiftUI nothing unusual has
/// happened. Only ever sent while the panel is open, so the toggle can only
/// close it.
///
/// Measured, not assumed: the status item is reachable from this process as an
/// `NSStatusBarWindow` at window level 25, holding exactly one button.
///
/// Matched by class name because MenuBarExtra hands out no reference to the
/// status item it creates, which makes this the most fragile thing in the
/// file. It reports whether it found anything rather than failing silently, so
/// the caller can still close the panel the blunt way.
enum MenuBarItem {
    @MainActor
    @discardableResult
    static func dismissPanel() -> Bool {
        for window in NSApp.windows
        where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            if let button = firstButton(in: window.contentView) {
                button.performClick(nil)
                return true
            }
        }
        return false
    }

    @MainActor
    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for subview in view.subviews {
            if let found = firstButton(in: subview) { return found }
        }
        return nil
    }
}

/// Hands back the NSWindow hosting a SwiftUI view.
///
/// The menu bar panel is presented in a window macOS owns, and nothing in
/// SwiftUI's vocabulary dismisses it: there is no presentation binding for a
/// window-styled MenuBarExtra, and the dismiss action does not reach it. So the
/// window is taken from the view hierarchy and ordered out directly.
///
/// Reaching for the key window instead would be one line and wrong — the panel
/// is not always key, and closing whatever is would be its own bug.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    /// Resolved here as well as on creation, and that is the whole point.
    ///
    /// A view is not in a window when it is made, so the lookup has to wait —
    /// but waiting once is not enough either: if that first hop still finds no
    /// window, nothing ever asks again and the reference stays nil forever.
    /// Which is exactly what happened, silently, and left the code that
    /// depended on it doing nothing at all.
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
