import Foundation

/// The handful of settings that outlive a launch.
///
/// Everything else about a scan is derived and cheap to recompute, so this stays
/// deliberately small: only choices the user made from a menu belong here.
enum Preferences {
    /// Where preferences are read and written. The self-test swaps in a
    /// throwaway suite, so checking the round trip can't disturb real settings.
    static var store: UserDefaults = .standard

    private static let showsTreemapKey = "showsTreemap"

    /// Whether Tree View shows the treemap. Absent means shown: `bool(forKey:)`
    /// reports false for a key that was never written, which would hide the
    /// treemap on a first launch and look like the pane failed to draw.
    static var showsTreemap: Bool {
        get { store.object(forKey: showsTreemapKey) as? Bool ?? true }
        set { store.set(newValue, forKey: showsTreemapKey) }
    }

    /// Whether a value was ever written, as opposed to falling back to the
    /// default above. Worth reporting: "shown" on a machine that has never been
    /// touched means something different from "shown because that was chosen".
    static var showsTreemapIsStored: Bool {
        store.object(forKey: showsTreemapKey) != nil
    }

    /// What `--prefs` prints. Returned rather than printed so it can be checked
    /// without capturing stdout, and reads nothing it doesn't report — a
    /// diagnostic that created the key it was asked about would be worse than
    /// none at all.
    ///
    /// The domain leads because it is the usual surprise: preferences belong to
    /// the bundle identifier, so a binary run straight out of `.build` reads a
    /// different domain than `Wizzzee.app` and will disagree with it.
    static func summary() -> String {
        let domain =
            Bundle.main.bundleIdentifier
            ?? "none — not an app bundle, so these are not Wizzzee.app's preferences"
        return """
            domain: \(domain)
            showsTreemap: \(showsTreemap) (\(showsTreemapIsStored ? "stored" : "default"))
            """
    }
}
