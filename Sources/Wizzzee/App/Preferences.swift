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

    private static let sizeMetricKey = "sizeMetric"

    /// The measure the window shows: space on disk until something else is
    /// chosen. Stored under the names `--metric` takes, so the value can be
    /// read and set from a script without knowing the app's own.
    static var sizeMetric: SizeMetric {
        get {
            store.string(forKey: sizeMetricKey).flatMap(CLI.metric(named:))
                ?? .allocated
        }
        set {
            store.set(newValue == .logical ? "size" : "disk", forKey: sizeMetricKey)
        }
    }

    static var sizeMetricIsStored: Bool { store.object(forKey: sizeMetricKey) != nil }

    private static let lastFolderKey = "lastFolder"
    private static let lastVolumeKey = "lastVolume"

    /// The folder last chosen with Folder…, when that and not a volume was
    /// the last thing scanned.
    static var lastFolder: String? {
        get { store.string(forKey: lastFolderKey) }
        set { set(newValue, forKey: lastFolderKey) }
    }

    /// The volume last picked in the Select list.
    static var lastVolume: String? {
        get { store.string(forKey: lastVolumeKey) }
        set { set(newValue, forKey: lastVolumeKey) }
    }

    /// Follows a volume to its new mount point, which is what renaming one
    /// in Finder moves: the volume remembered, and a folder remembered on it.
    static func volumeMoved(from old: String, to new: String) {
        if lastVolume == old { lastVolume = new }
        if let folder = lastFolder {
            let moved = path(folder, movedFrom: old, to: new)
            if moved != folder { lastFolder = moved }
        }
    }

    /// `path` as it is spelled once the volume that was at `old` is at
    /// `new`: unchanged, when it is not on that volume.
    static func path(_ path: String, movedFrom old: String, to new: String) -> String {
        if path == old { return new }
        if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
        return path
    }

    private static func set(_ value: String?, forKey key: String) {
        if let value {
            store.set(value, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
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
            sizeMetric: \(sizeMetric == .logical ? "size" : "disk") \
            (\(sizeMetricIsStored ? "stored" : "default"))
            lastFolder: \(lastFolder ?? "none")
            lastVolume: \(lastVolume ?? "none")
            """
    }
}
