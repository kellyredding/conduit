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
        .onAppear { store.menuOpened() }
        .onDisappear { store.menuClosed() }
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

    private var footer: some View {
        HStack {
            // A glyph rather than a word: refreshing is the one thing here
            // that repeats, and the symbol is already understood everywhere
            // else it appears. The label survives for anyone navigating by
            // voice or by screen reader, where a bare arrow says nothing.
            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Refresh now")
            .accessibilityLabel("Refresh")

            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .font(.callout)
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
