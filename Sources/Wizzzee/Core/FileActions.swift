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

    /// Whether reading what is at `path` would download it: the file there,
    /// or the file a link there leads to, is one a cloud provider is
    /// holding.
    ///
    /// Asked of the disk, through any link: for a link the scan's own note
    /// is of the link and not of what it is to, and what reads a link reads
    /// what it is to.
    static func isOnlineOnly(_ path: String) -> Bool {
        var info = stat()
        // `SF_DATALESS`. Looking at the flags brings nothing down.
        return stat(path, &info) == 0 && info.st_flags & 0x4000_0000 != 0
    }

    /// Paths that System Integrity Protection makes read-only, so the app can
    /// explain up front rather than surfacing a bare EPERM.
    private static let protectedPrefixes = [
        "/System/", "/usr/", "/bin/", "/sbin/", "/private/var/db/",
    ]

    /// Mount point of the writable APFS data volume. `/` reaches the same
    /// folders through firmlinks, so everything under it has a second path.
    private static let dataVolumeMount = "/System/Volumes/Data"

    /// Writable locations that sit underneath a protected prefix.
    ///
    /// `/System/Volumes/Data` is the mount point of the writable APFS data
    /// volume, and a legitimate scan target — it is exactly what a scan of `/`
    /// skips to avoid double-counting firmlinks, so seeing inside it means
    /// scanning it directly. Without this, every path in such a scan begins
    /// `/System/` and every delete was refused with a flatly false claim that
    /// the user's own home directory was on the read-only system volume.
    private static let writableExceptions = ["/usr/local", dataVolumeMount]

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
        // A scan of the data volume's mount point spells every path through it,
        // so `/System/Volumes/Data/Users/<name>` is the same home folder as
        // `/Users/<name>`, and the mount point is the volume `/` stands for.
        // Judged as written it has five components and passes every check below.
        if trimmed == dataVolumeMount { return true }
        if trimmed.hasPrefix(dataVolumeMount + "/") {
            trimmed.removeFirst(dataVolumeMount.count)
        }
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

    /// What one thing on a volume is, whatever it is called and wherever it
    /// has been moved to: its volume and its number on it.
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        /// Of what is at `path` itself, a link there included; nil when
        /// nothing is.
        init?(atPath path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            self.init(info)
        }

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// What it takes to bring something back out of the Trash, taken down
    /// as it goes in.
    ///
    /// A place in the Trash is a name, and names there are used again:
    /// empty the Trash of `notes.txt`, throw another `notes.txt` away, and
    /// it is given the first one's place. So the thing itself is taken down,
    /// and the folder it came out of, and neither is gone by its path alone.
    struct TrashReceipt {
        /// Where in the Trash it went, which is not always under the name it
        /// had: the Trash renames what it already has one of.
        let inTrash: String
        /// The thing that was put there.
        let item: FileIdentity
        /// The folder it was taken out of.
        let folder: FileIdentity

        /// Whether it is still where it was put, and still it.
        var isStillInTrash: Bool { FileIdentity(atPath: inTrash) == item }

        /// What a look at its place in the Trash says.
        enum Presence {
            case there
            /// Nothing is at its place, or something else is.
            case gone
            /// Its place can't be looked at: a share that has dropped, a
            /// disk that does not answer. It may well be there.
            case unknown
        }

        var presence: Presence {
            var info = stat()
            if lstat(inTrash, &info) == 0 {
                return FileIdentity(info) == item ? .there : .gone
            }
            return errno == ENOENT || errno == ENOTDIR ? .gone : .unknown
        }

        /// Whether it is known to be there no longer. Not the reverse of
        /// `isStillInTrash`: a place that can't be looked at is neither.
        var hasLeftTrash: Bool { presence == .gone }
    }

    /// Moves the item at `path` to the Trash, and says where in the Trash it
    /// went and what it was — or nil, when it has gone there and there is
    /// nothing to bring it back by: the Trash did not say where it put it,
    /// or what is there now can't be seen to be the thing that was moved.
    /// (A volume with no Trash at all is an error, not a nil: nothing is
    /// removed.)
    ///
    /// That was thrown away, and with it any way of bringing the item back:
    /// ⌘⌫ asks nothing, on the understanding that the Trash is not the end,
    /// and from here it was.
    @discardableResult
    static func moveToTrash(_ path: String) throws -> TrashReceipt? {
        if isUndeletableRoot(path) { throw ActionError.undeletableRoot(path) }
        if isSystemProtected(path) { throw ActionError.systemProtected(path) }
        // Taken before it goes: where it ends up is then known to hold the
        // thing that went, and not something that was already there.
        let item = FileIdentity(atPath: path)
        let folder = FileIdentity(atPath: (path as NSString).deletingLastPathComponent)
        do {
            var answer: NSURL?
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: path),
                resultingItemURL: &answer
            )
            guard let inTrash = (answer as URL?)?.path, !inTrash.isEmpty,
                let item, let folder, FileIdentity(atPath: inTrash) == item
            else { return nil }
            return TrashReceipt(inTrash: inTrash, item: item, folder: folder)
        } catch {
            throw ActionError.failed(path, error.localizedDescription)
        }
    }

    /// Why something could not be brought back out of the Trash.
    enum PutBackError: LocalizedError {
        case notInTrash
        /// Its place in the Trash can't be looked at, so nothing is known
        /// of it: it may well be there.
        case unreachable
        case nameTaken(String)
        case folderGone(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInTrash:
                return "It is no longer in the Trash."
            case .unreachable:
                return "The Trash it is in can’t be reached just now."
            case .nameTaken(let path):
                return "Something else is at “\(path)” now."
            case .folderGone(let path):
                return "The folder it was in, “\(path)”, is no longer there."
            case .failed(let reason):
                return reason
            }
        }
    }

    /// `RENAME_EXCL` (sys/stdio.h): fail if the destination exists.
    private static let renameWithoutReplacing: UInt32 = 0x0000_0004

    /// Moves what `receipt` is for back to `path`.
    ///
    /// Only the thing that was put in the Trash, only into the folder it
    /// came out of, and never over anything:
    ///
    /// - What is at its place in the Trash now has to be it. Something else
    ///   that has since been given that place is not moved.
    /// - The folder at the other end has to be the one it left, and a folder:
    ///   one that has been replaced, by another or by a link to somewhere
    ///   else, is not written into.
    /// - The move is one that fails if anything is there. Looking first and
    ///   then moving would replace whatever arrived in between, and what
    ///   moves a file replaces a file, an empty folder, or a link that leads
    ///   nowhere without a word.
    ///
    /// It is a rename and nothing else. The Trash is on the volume the item
    /// came from, so there is never a copy to fall back on.
    static func putBack(_ receipt: TrashReceipt, to path: String) throws {
        guard receipt.isStillInTrash else {
            // Not seen there is not the same as gone from there.
            throw receipt.hasLeftTrash ? PutBackError.notInTrash : PutBackError.unreachable
        }
        let folder = (path as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            FileIdentity(info) == receipt.folder
        else { throw PutBackError.folderGone(folder) }

        if renamex_np(receipt.inTrash, path, renameWithoutReplacing) == 0 { return }
        switch errno {
        case EEXIST:
            throw PutBackError.nameTaken(path)
        case ENOTSUP:
            // A volume that can't be asked not to replace. Looked at and
            // then moved, which is the best there is on one of those.
            guard lstat(path, &info) != 0 else { throw PutBackError.nameTaken(path) }
            guard rename(receipt.inTrash, path) == 0 else {
                throw PutBackError.failed(String(cString: strerror(errno)))
            }
        default:
            throw PutBackError.failed(String(cString: strerror(errno)))
        }
    }

    /// Throws only for a path that may not be removed at all. One that could
    /// not be removed, or not all of it, comes back in the outcome: part of a
    /// folder may have gone by then, and the caller has to know which.
    @discardableResult
    static func deletePermanently(
        _ path: String,
        stop: Removal.Stop = Removal.Stop(),
        onProgress: (Removal.Tally) -> Void = { _ in }
    ) throws -> Removal.Outcome {
        if isUndeletableRoot(path) { throw ActionError.undeletableRoot(path) }
        if isSystemProtected(path) { throw ActionError.systemProtected(path) }
        return Removal.remove(path, stop: stop, onProgress: onProgress)
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
