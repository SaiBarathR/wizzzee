import AppKit
import Foundation
import UniformTypeIdentifiers

/// Finder integration and destructive operations on scanned items.
enum FileActions {
    enum ActionError: LocalizedError {
        case systemProtected(String)
        /// A whole volume, a home folder, or the folder a scan was rooted at.
        case undeletableRoot(String)
        case failed(String, String)

        var errorDescription: String? {
            switch self {
            case .systemProtected(let path):
                return "“\((path as NSString).lastPathComponent)” is protected by macOS"
            case .undeletableRoot(let path):
                return "“\(path)” is a root folder"
            case .failed(let path, _):
                return "Couldn’t delete “\((path as NSString).lastPathComponent)”"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .systemProtected:
                return """
                    It lives on the sealed system volume, which System Integrity \
                    Protection makes read-only. Nothing can remove it — not even \
                    an administrator — so this space cannot be reclaimed.
                    """
            case .undeletableRoot:
                return """
                    Wizzzee won't delete a whole volume, a home folder, or the \
                    folder a scan was rooted at. Open it and remove what's \
                    inside instead.
                    """
            case .failed(_, let reason):
                return reason
            }
        }
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func openTerminal(at path: String) {
        var directory = path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
            !isDir.boolValue
        {
            directory = (path as NSString).deletingLastPathComponent
        }
        let url = URL(fileURLWithPath: directory)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Paths that System Integrity Protection makes read-only, so the app can
    /// explain up front rather than surfacing a bare EPERM.
    private static let protectedPrefixes = [
        "/System/", "/usr/", "/bin/", "/sbin/", "/private/var/db/",
    ]

    /// Writable locations that sit underneath a protected prefix.
    ///
    /// `/System/Volumes/Data` is the mount point of the writable APFS data
    /// volume, and a legitimate scan target — it is exactly what a scan of `/`
    /// skips to avoid double-counting firmlinks, so seeing inside it means
    /// scanning it directly. Without this, every path in such a scan begins
    /// `/System/` and every delete was refused with a flatly false claim that
    /// the user's own home directory was on the read-only system volume.
    private static let writableExceptions = ["/usr/local", "/System/Volumes/Data"]

    static func isSystemProtected(_ path: String) -> Bool {
        // Matched as whole path components — each prefix ends in "/", so a
        // sibling like /usr/locality or /Systemic isn't caught with them.
        for exception in writableExceptions {
            if path == exception || path.hasPrefix(exception + "/") { return false }
        }
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }

    /// True when the path names an entire volume or a whole home folder.
    ///
    /// A scan is normally rooted at one of these, and its root row is selected
    /// the moment the scan lands — so the very first "Delete Permanently…" a
    /// user reached for was aimed at everything they had just measured. None of
    /// the SIP prefixes cover `/` or `/Users/<name>`, so nothing else stops it.
    static func isUndeletableRoot(_ path: String) -> Bool {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.isEmpty || trimmed == "/" { return true }
        if trimmed == NSHomeDirectory() { return true }

        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        // /Volumes/<name>, the mount point of an external or secondary volume.
        if parts.count == 2 && parts[0] == "Volumes" { return true }
        // /Users/<name>, which is someone's home folder even when it isn't this
        // process's own — a scan run with Full Disk Access reaches all of them.
        if parts.count == 2 && parts[0] == "Users" { return true }
        return false
    }

    /// True when *any* of `refs` is protected. A bulk action that silently did
    /// part of what it offered would be worse than one that refuses outright, so
    /// the UI disables the whole thing on a single protected item.
    static func containsSystemProtected(_ refs: Set<NodeRef>) -> Bool {
        refs.contains { isSystemProtected($0.path) }
    }

    static func moveToTrash(_ path: String) throws {
        if isUndeletableRoot(path) { throw ActionError.undeletableRoot(path) }
        if isSystemProtected(path) { throw ActionError.systemProtected(path) }
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: path),
                resultingItemURL: nil
            )
        } catch {
            throw ActionError.failed(path, error.localizedDescription)
        }
    }

    static func deletePermanently(_ path: String) throws {
        if isUndeletableRoot(path) { throw ActionError.undeletableRoot(path) }
        if isSystemProtected(path) { throw ActionError.systemProtected(path) }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw ActionError.failed(path, error.localizedDescription)
        }
    }

    /// Icon for a scanned item. Uses the generic type icon rather than asking
    /// the filesystem for the real one, which would mean a disk hit per row.
    static func icon(for ref: NodeRef) -> NSImage {
        if ref.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (ref.name as NSString).pathExtension
        if ext.isEmpty { return NSWorkspace.shared.icon(for: .data) }
        return cachedIcon(forExtension: ext.lowercased())
    }

    private static var iconCache: [String: NSImage] = [:]
    private static let iconCacheLock = NSLock()

    private static func cachedIcon(forExtension ext: String) -> NSImage {
        iconCacheLock.lock()
        defer { iconCacheLock.unlock() }
        if let cached = iconCache[ext] { return cached }
        // An unrecognized extension has no content type; the generic data icon
        // is what the old file-type call fell back to for those.
        let type = UTType(filenameExtension: ext) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 16, height: 16)
        iconCache[ext] = icon
        return icon
    }
}
