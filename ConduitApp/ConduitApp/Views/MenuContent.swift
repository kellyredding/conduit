import SwiftUI

/// The dropdown. Read-only for now: every profile's state is shown and none of
/// them can be changed from here.
struct MenuContent: View {
    @ObservedObject var store: VPNStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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

            Divider().padding(.vertical, 6)
            footer
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { store.menuOpened() }
        .onDisappear { store.menuClosed() }
    }

    private var header: some View {
        HStack {
            Text("Conduit").font(.headline)
            Spacer()
            if let updated = store.lastUpdated {
                Text(updated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 8)
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
    // than an error — and saying where they come from is more use than saying
    // there are none.
    private var empty: some View {
        Text("No profiles are installed.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { store.refreshNow() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .font(.callout)
    }
}

private struct ProfileRow: View {
    let profile: ProfileState
    let counters: VPNByteCounters?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: indicator)
                .font(.caption)
                .foregroundStyle(profile.isConnected ? .primary : .tertiary)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(profile.name)
                    if profile.isSensitive {
                        // The same rule the CLI enforces, from the same
                        // setting. A mark that meant something different here
                        // would be worse than no mark.
                        Image(systemName: "exclamationmark.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Needs confirmation before connecting")
                    }
                }
                Text(profile.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let counters {
                Text(traffic(counters))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var indicator: String {
        if profile.isInFlight { return "circle.dotted" }
        return profile.isConnected ? "circle.fill" : "circle"
    }

    // Cumulative totals, which is all the client reports. Rates require
    // differencing successive samples and belong with the history that will
    // hold them, not here.
    private func traffic(_ counters: VPNByteCounters) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        let down = formatter.string(fromByteCount: counters.tunnelIn)
        let up = formatter.string(fromByteCount: counters.tunnelOut)
        return "↓\(down)  ↑\(up)"
    }
}
