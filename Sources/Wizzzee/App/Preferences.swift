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
}
