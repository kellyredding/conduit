import SwiftUI

/// One setting, rendered from its key definition rather than hand-written.
///
/// The label is the key made readable and the tooltip is the key itself, so
/// what you see here is also what you would type at `conduit-vpn config set`.
/// The description is the same sentence the command line prints, which keeps
/// one explanation of each setting rather than two that drift.
struct SettingsField: View {
    let key: ConduitConfig.Key

    /// Called after a write so the window can re-read every value: setting one
    /// can change what another resolves to, and the reset affordance depends
    /// on whether a value came from the file or from a default.
    let onWrite: () -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A checkbox carries its own label, which is the macOS settings
            // convention and what the sibling applications use. A switch with
            // the label hidden and pushed to the trailing edge rendered as a
            // bare pill with no knob.
            if isFlag {
                Toggle(label, isOn: Binding(
                    get: { ConduitConfig.bool(key.name) },
                    set: { write($0 ? "true" : "false") }
                ))
                .toggleStyle(.checkbox)
            } else {
                SettingsRow(label: label) { control }
            }

            Text(key.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(key.name)
        .onAppear { text = ConduitConfig.get(key.name) }
    }

    @ViewBuilder private var control: some View {
        if !key.choices.isEmpty {
            // A fixed set of values is a choice, not a spelling test. Left at
            // the default pop-up style, which is what the sibling applications
            // use and what macOS shows for a settings choice everywhere else.
            Picker("", selection: Binding(
                get: { ConduitConfig.get(key.name) },
                set: { write($0) }
            )) {
                ForEach(key.choices, id: \.self) { choice in
                    if let icon = choiceIcon(choice) {
                        Label(choiceLabel(choice), systemImage: icon).tag(choice)
                    } else {
                        Text(choiceLabel(choice)).tag(choice)
                    }
                }
            }
            .labelsHidden()
            .frame(width: 160)
        } else {
            TextField(key.defaultValue(), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: isPath ? 260 : 90)
                .multilineTextAlignment(isPath ? .leading : .trailing)
                .focused($isFocused)
                // Committed when the field is left or return is pressed, never
                // per keystroke: the command line may read this file at any
                // moment, and rewriting it once per character typed into a
                // number would hand it a stream of half-finished values.
                .onSubmit { write(text) }
                .onChange(of: isFocused) { _, focused in
                    if !focused { write(text) }
                }
        }
    }

    /// Falls back to the raw value, so a setting that grows choices reads
    /// sensibly before anybody writes display names for them.
    private func choiceLabel(_ raw: String) -> String {
        ThemePreference(rawValue: raw)?.displayName ?? raw.capitalized
    }

    private func choiceIcon(_ raw: String) -> String? {
        ThemePreference(rawValue: raw)?.iconName
    }

    private var label: String {
        let words = key.name.replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private var isFlag: Bool {
        ["true", "false"].contains(key.defaultValue().lowercased())
    }

    /// Paths need room to be recognised; a number does not, and a wide field
    /// around a two-digit value reads as though something is missing.
    private var isPath: Bool { key.name.hasSuffix("-path") || key.name.hasSuffix("-home") }

    /// Choosing the default removes the setting rather than writing it.
    ///
    /// The file records only what differs from a default — that is what lets a
    /// default improve in code and take effect on a machine that has already
    /// been configured. Writing "system" into it because somebody picked
    /// "Match system" freezes today's answer and needs a second affordance to
    /// undo, which is what the Reset button was papering over.
    ///
    /// An emptied text field means the same thing, which is why the default is
    /// the placeholder rather than pre-filled text.
    ///
    /// The command line can still write a default explicitly; it is a direct
    /// instruction there rather than a side effect of looking at a form.
    private func write(_ value: String) {
        guard value != ConduitConfig.get(key.name) else { return }

        try? ConduitConfig.apply(key.name, value)
        text = ConduitConfig.get(key.name)
        onWrite()
    }
}
