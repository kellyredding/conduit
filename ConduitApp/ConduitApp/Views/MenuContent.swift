import SwiftUI

/// The dropdown. Read-only for now: every profile's state is shown and none of
/// them can be changed from here.
struct MenuContent: View {
    @ObservedObject var store: VPNStore

    private var anySensitive: Bool {
        store.profiles.contains(where: \.isSensitive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Conduit")
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

                // The mark is meaningless on its own, and a symbol nobody can
                // decode is worse than no symbol: it reads as a warning about
                // something unspecified. Same wording the command line uses,
                // so the two explanations cannot drift apart.
                if anySensitive {
                    HStack(spacing: 6) {
                        Image(systemName: sensitiveSymbol)
                            .font(.system(size: 11))
                        Text("needs confirmation to connect")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
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

/// Shared so the legend and the rows cannot fall out of step.
let sensitiveSymbol = "exclamationmark.shield.fill"

private struct ProfileRow: View {
    let profile: ProfileState
    let counters: VPNByteCounters?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: indicator)
                .font(.system(size: 11))
                .foregroundStyle(profile.isConnected ? .primary : .tertiary)
                .frame(width: 14)

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
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
                    .help("Needs confirmation before connecting")
            }
        }
        .padding(.vertical, 8)
    }

    private var indicator: String {
        if profile.isInFlight { return "circle.dotted" }
        return profile.isConnected ? "circle.fill" : "circle"
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
