import AppKit
import Foundation
import UniformTypeIdentifiers

/// Finder integration and destructive operations on scanned items.
enum FileActions {
    enum ActionError: LocalizedError {
        case systemProtected(String)
        case failed(String, String)

        var errorDescription: String? {
            switch self {
            case .systemProtected(let path):
                return "“\((path as NSString).lastPathComponent)” is protected by macOS"
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

    static func isSystemProtected(_ path: String) -> Bool {
        // /usr/local and /opt are writable exceptions carved out of SIP. Matched
        // as a whole component, so a sibling like /usr/locality isn't exempted
        // along with it.
        if path == "/usr/local" || path.hasPrefix("/usr/local/") { return false }
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }

    /// True when *any* of `refs` is protected. A bulk action that silently did
    /// part of what it offered would be worse than one that refuses outright, so
    /// the UI disables the whole thing on a single protected item.
    static func containsSystemProtected(_ refs: Set<NodeRef>) -> Bool {
        refs.contains { isSystemProtected($0.path) }
    }

    static func moveToTrash(_ path: String) throws {
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
