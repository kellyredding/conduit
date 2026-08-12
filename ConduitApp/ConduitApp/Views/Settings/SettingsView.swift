import AppKit
import SwiftUI

/// Root view of the settings window: horizontal icon tab strip, divider, then
/// the selected tab's cards below.
///
/// Layout follows assist-ant and Galaxy so all three read as the same piece of
/// software. What differs is where the content comes from — those applications
/// hand-write their fields, and this one generates them from the settings key
/// list, because that list is already the contract the command line shares and
/// a second hand-maintained copy of it would drift.
struct SettingsView: View {
    @State private var selected: SettingsTab = .general

    /// Bumped after any write to force every field to re-read. Setting one
    /// value can change what another resolves to, and whether a reset button
    /// belongs on a row depends on where its value came from.
    @State private var revision = 0
    @State private var confirmingReset = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    SettingsTabButton(tab: tab, isSelected: selected == tab) {
                        selected = tab
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                    if selected == .general { startup }

                    ForEach(Array(selected.groups.enumerated()), id: \.offset) { _, group in
                        SettingsCard(title: group.title) {
                            ForEach(group.keys, id: \.self) { name in
                                if let key = ConduitConfig.key(named: name) {
                                    SettingsField(key: key) {
                                        revision += 1
                                        ThemeController.shared.reload()
                                    }
                                        .id("\(name)-\(revision)")
                                }
                            }
                        }
                    }

                footer
            }
            .padding(18)
        }
        .frame(width: 560)
        // Painted rather than left to the window.
        //
        // The panel names this colour explicitly, so this does too: relying on
        // a window's implicit background to resolve to the same thing is how
        // the two came to differ, and a hosting view can put its own material
        // between the window and the content. One expression in both places
        // cannot disagree with itself.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Not a setting in the file, so it cannot be generated with the rest.
    /// It lives here rather than in the menu because it is configuration
    /// rather than an action, and because restoring a connection after a wake
    /// only works for tunnels Conduit was running to observe — which makes
    /// this the setting the one above it depends on.
    private var startup: some View {
        SettingsCard(title: "Startup") {
            Toggle("Start Conduit at login", isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { LaunchAtLogin.set($0); revision += 1 }
            ))
            .toggleStyle(.checkbox)

            if LaunchAtLogin.requiresApproval {
                Text("Waiting for approval in System Settings › General › Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    """
                    Connections are only restored after sleep if Conduit was \
                    running to see them go down.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(alignment: .top) {
                Text(
                    """
                    Stored in \(ConduitPaths.configFile.path), the same file \
                    the conduit-vpn command reads. Settings left at their \
                    default are not written to it.
                    """
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Button("Restore Defaults…") { confirmingReset = true }
                    .controlSize(.small)
            }
        }
        // Asked before doing it because it cannot be undone from here: the
        // previous values are in the file being removed, and nothing else
        // holds a copy.
        .confirmationDialog(
            "Restore all settings to their defaults?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) { restoreDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                Every setting returns to the value Conduit ships with, \
                including any changed from the command line.
                """
            )
        }
    }

    /// One operation rather than a walk over the keys: the file holds only
    /// what differs from a default, so removing it is the reset, and there is
    /// no way for it to half-succeed and leave settings inconsistent.
    private func restoreDefaults() {
        try? ConduitConfig.resetAll()
        revision += 1
        ThemeController.shared.reload()
    }
}
