import Foundation

/// Which profiles need saying yes out loud.
///
/// MIRROR: tools/conduit-vpn/src/conduit_vpn/sensitivity.cr
///
/// Both sides read the same setting from the same file, so a profile that the
/// CLI refuses without confirmation is the same one this application puts a
/// confirmation behind. Divergence here would be worse than having no rule:
/// it would teach that the mark in the menu means something it does not.
enum Sensitivity {
    /// An empty pattern disables the check. Handing an empty string to a
    /// regular expression would instead match every profile, turning "I do not
    /// want this" into "guard everything" — the opposite of what emptying a
    /// setting means.
    static func expression() -> NSRegularExpression? {
        let raw = ConduitConfig.get("sensitive-profile-pattern")
        guard !raw.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: raw)
    }

    /// Whether the pattern is present but unusable, which is distinct from
    /// being deliberately empty. A caller that cannot tell them apart would
    /// silently guard nothing after a typo.
    static func patternIsBroken() -> Bool {
        let raw = ConduitConfig.get("sensitive-profile-pattern")
        guard !raw.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: raw)) == nil
    }

    static func isSensitive(_ profile: String) -> Bool {
        guard let expression = expression() else { return false }
        let range = NSRange(profile.startIndex..., in: profile)
        return expression.firstMatch(in: profile, range: range) != nil
    }
}
