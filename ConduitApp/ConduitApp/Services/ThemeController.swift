import AppKit
import SwiftUI

/// Applies the appearance setting to the windows this application owns.
///
/// Follows assist-ant and Galaxy: `system` is expressed as a nil NSAppearance,
/// which is what makes a window inherit whatever the OS is doing rather than
/// pinning it to whatever the OS happened to be doing at launch.
///
/// The setting lives in the same file as everything else rather than in user
/// defaults, so one file describes the whole configuration and the command
/// line can read it — even though the command line has no windows to theme.
@MainActor
final class ThemeController: ObservableObject {
    static let shared = ThemeController()

    @Published private(set) var theme: ThemePreference = .system

    /// Re-read after any settings write, and once at launch. Windows this
    /// application owns observe the published value rather than being pushed
    /// to, so one that does not exist yet needs no special case.
    func reload() {
        theme = ThemePreference.parse(ConduitConfig.get("theme"))
        applyApplicationWide()
    }

    /// The menu bar panel is the reason this exists.
    ///
    /// Its content is hosted in a window macOS owns, not one this application
    /// creates, so there is nothing to hand an NSAppearance to and the SwiftUI
    /// colour-scheme preference is overridden by the panel's own appearance —
    /// measured: the settings window went dark and the panel stayed light.
    ///
    /// Setting it on the application reaches every window it draws, including
    /// that one. Windows with an explicit appearance of their own still win,
    /// which is what keeps the settings window correct while it is being used
    /// to change this.
    ///
    /// Nil is deliberate rather than a missing case: it clears the override so
    /// everything goes back to following the OS, which is what matching the
    /// system means.
    private func applyApplicationWide() {
        NSApp.appearance = nsAppearance
    }

    var nsAppearance: NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// The SwiftUI equivalent, for the menu bar panel.
    ///
    /// The panel is presented in a window macOS owns rather than one this
    /// application creates, so it cannot be given an NSAppearance directly and
    /// the preference is expressed on the content instead.
    var colorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
