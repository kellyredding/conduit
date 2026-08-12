import SwiftUI

/// One button in the horizontal tab strip. Icon over title; the selected one
/// gets a subtle filled background.
///
/// Adapted from the same component in assist-ant and Galaxy, so all three
/// applications' settings windows read as the same piece of software.
struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18))
                    .frame(height: 22)
                Text(tab.title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .primary : .secondary)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
        )
    }
}

/// Grouped section within a tab: title above, content in a rounded
/// control-background box below.
///
/// The box stretches to the full width so cards read as one left-justified
/// column regardless of how wide their content happens to be — without it, a
/// card holding a single narrow control shrinks to hug it and gets centred.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 12)
                    .padding(.bottom, 6)
            }

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }
}

/// One row inside a card: label on the left, control on the right, held apart
/// by a stretching spacer so every control lines up on the trailing edge.
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            content
        }
    }
}
