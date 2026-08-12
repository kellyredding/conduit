import Foundation

/// User-selectable appearance. `system` means inherit whatever the OS is
/// doing, which is expressed as a nil NSAppearance by the controllers that
/// apply it.
///
/// Adapted from assist-ant's ThemePreference, itself adapted from Galaxy's,
/// so the three applications offer the same choice under the same names.
///
/// Foundation-only, living in the model layer so the sandboxed check target
/// can compile it alongside the settings key it is stored under.
enum ThemePreference: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// Anything unrecognized reads as matching the system.
    ///
    /// The setting is stored in a file a person can edit by hand and the
    /// command line will write any string into it, so an unknown value is
    /// reachable. Falling back beats refusing to draw.
    static func parse(_ raw: String) -> ThemePreference {
        ThemePreference(rawValue: raw.lowercased()) ?? .system
    }
}
