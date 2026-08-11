import SwiftUI

/// The dropdown. Read-only for now: every profile's state is shown and none of
/// them can be changed from here.
struct MenuContent: View {
    @ObservedObject var store: VPNStore

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
                        counters: store.counters[profile.name]
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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: indicator)
                .font(.system(size: rowMarkSize, weight: .regular))
                .foregroundStyle(profile.isConnected ? .primary : .tertiary)
                .frame(width: rowMarkSize + 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)

                // Throughput sits with the status rather than off to the right,
                // which leaves the trailing edge free for the mark and stops
                // the two competing for the same space on a connected row.
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
            }

            Spacer(minLength: 8)

            if profile.isSensitive {
                // Sized to the whole row rather than to the name it follows.
                // This is the one piece of information here that changes what
                // a person is allowed to do without thinking, so it is the one
                // thing that should be legible before the row is read.
                Image(systemName: sensitiveSymbol)
                    .font(.system(size: rowMarkSize, weight: .regular))
                    .foregroundStyle(.secondary)
                    .help("Needs confirmation before connecting")
            }
        }
        .padding(.vertical, 8)
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
        if profile.isInFlight { return MenuIconState.connecting.symbolName }
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
