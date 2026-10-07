import Foundation

/// How much of a file's length is really stored on the disk it was found on.
///
/// A file's length is whatever it says it is. A virtual machine or container
/// image is created at the size of the disk it pretends to be and filled in as
/// it is used, so one can be 995 GB long while occupying 42 GB — and be longer
/// than the volume it sits on. Summed into a folder, a length like that makes
/// the folder look bigger than the disk, which is why the two measures are kept
/// apart and why a file like this is pointed out rather than left to be found.
enum FileStorage: UInt8 {
    /// Every byte of its length is accounted for on disk.
    case whole
    /// Has stretches that were never written and take up no space.
    case sparse
    /// Its contents are with a cloud provider; only the name is here.
    case dataless

    /// `UF_COMPRESSED` and `SF_DATALESS` (sys/stat.h), as `st_flags` has them.
    private static let compressedFlag: UInt32 = 0x0000_0020
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// Tells the cases apart from what `getattrlistbulk` already returns.
    ///
    /// The filesystem has a flag of its own for a sparse file, but asking for
    /// it means a second attribute group on every entry of every scan. It is
    /// not needed: a regular file that is neither compressed nor dataless and
    /// still occupies less than its length has nowhere else to have lost the
    /// difference. Measured against that flag over the 3.1 million files of a
    /// home folder, the two picked out the same 85 files and no others.
    ///
    /// That measurement was on APFS, and the reasoning holds only where the
    /// allocation reported is the file's own and exact — which is what
    /// `shortfallMeansHoles` says. A network share can report no allocation at
    /// all, and a server that compresses behind its back reports less than the
    /// length for every file; called sparse, each of those would be described
    /// as mostly unwritten. Elsewhere a shortfall is left unexplained.
    ///
    /// A compressed file occupies less than its length as well, but all of it
    /// is there, so it counts as whole. A dataless one says so itself, on any
    /// filesystem.
    static func classify(
        isRegularFile: Bool,
        size: UInt64,
        alloc: UInt64,
        bsdFlags: UInt32,
        shortfallMeansHoles: Bool
    ) -> FileStorage {
        guard isRegularFile else { return .whole }
        if bsdFlags & datalessFlag != 0 { return .dataless }
        if bsdFlags & compressedFlag != 0 { return .whole }
        return shortfallMeansHoles && alloc < size ? .sparse : .whole
    }

    /// Whether, on a filesystem of this type, a file occupying less than its
    /// length can be taken to have holes in it. See `classify`.
    static func shortfallMeansHoles(onFilesystem type: String) -> Bool {
        type == "apfs"
    }
}

/// One file inside a `DirNode`.
///
/// Files are stored in a contiguous array on their parent rather than as
/// individual objects: on a full-disk scan there can be several million of
/// them, and per-object allocation overhead would dominate memory use.
struct FileEntry {
    var name: String
    var size: UInt64
    var alloc: UInt64
    var mtime: Double
    /// Index into `ScanResult.extensionStats`, or -1 before aggregation.
    var extIndex: Int32
    /// `isSymlink` and `isRemoved`, in the one byte the first used to have to
    /// itself. A second `Bool` would be the 57th byte of a 56-byte struct.
    private var flags: UInt8
    /// A hard link whose size was already counted under another path.
    var isDuplicateLink: Bool
    /// How many names this file's inode has on the volume, saturating at 255.
    ///
    /// Above 1, deleting this name frees nothing until the last of them goes.
    /// It drops as the other names are removed, so a file that ends up the sole
    /// survivor stops being treated as sharing its storage.
    ///
    /// A byte rather than the `UInt32` the filesystem reports: the value is only
    /// ever compared against 1, and a wider field would push this struct from 56
    /// bytes to 64 once `fileID` is added — 32 MB on a full-disk scan. A
    /// saturated count is never decremented, since the real number is unknown.
    var linkCount: UInt8 = 1

    /// True when this name shares its bytes with another, so removing it frees
    /// nothing on its own.
    var isHardLinked: Bool { linkCount > 1 || linkCount == UInt8.max }
    /// Whether the file's length is all on disk, and why not when it isn't.
    ///
    /// Declared here, ahead of `fileID`, because that is where the struct had
    /// a byte of padding going spare: anywhere else it would cost eight.
    var storage: FileStorage = .whole
    /// Inode number, used to pair the names of one hard-linked file.
    ///
    /// Unique per volume, and a scan never leaves the volume it started on, so
    /// within one `ScanResult` this identifies the storage a name points at.
    var fileID: UInt64 = 0

    private static let symlinkFlag: UInt8 = 1 << 0
    private static let removedFlag: UInt8 = 1 << 1

    init(
        name: String,
        size: UInt64,
        alloc: UInt64,
        mtime: Double,
        extIndex: Int32,
        isSymlink: Bool,
        isDuplicateLink: Bool,
        linkCount: UInt8 = 1,
        storage: FileStorage = .whole,
        fileID: UInt64 = 0
    ) {
        self.name = name
        self.size = size
        self.alloc = alloc
        self.mtime = mtime
        self.extIndex = extIndex
        self.flags = isSymlink ? Self.symlinkFlag : 0
        self.isDuplicateLink = isDuplicateLink
        self.linkCount = linkCount
        self.storage = storage
        self.fileID = fileID
    }

    var isSymlink: Bool { flags & Self.symlinkFlag != 0 }

    /// True for the slot a deleted file leaves behind.
    ///
    /// A `NodeRef` names a file by its place in the folder's array, so taking
    /// an entry out renumbered every sibling after it: the table saw a list of
    /// new rows and redrew the lot, and whatever was selected, hovered or
    /// waiting on a confirmation named a different file from then on. The
    /// slot is kept instead and everything that walks files steps over it.
    var isRemoved: Bool { flags & Self.removedFlag != 0 }

    /// What a slot holds once its file has gone: nothing that can be added
    /// up, matched to an inode or filed under a type, so a walk that forgets
    /// to step over one still gets nothing from it.
    static let removed: FileEntry = {
        var entry = FileEntry(
            name: "",
            size: 0,
            alloc: 0,
            mtime: 0,
            extIndex: -1,
            isSymlink: false,
            isDuplicateLink: false
        )
        entry.flags = removedFlag
        return entry
    }()

    /// True when the bytes survive this name being removed, either because
    /// another name was already counted for them or because one still exists.
    var sharesStorage: Bool { isDuplicateLink || isHardLinked }

    func bytes(using metric: SizeMetric) -> UInt64 {
        metric == .logical ? size : alloc
    }

    /// The word shown beside a file's name when its length is not what it
    /// occupies, or nil when the two agree.
    var storageNote: String? {
        switch storage {
        case .whole: return nil
        case .sparse: return "sparse"
        case .dataless: return "online only"
        }
    }

    /// The sentence behind `storageNote`, for a tooltip.
    var storageExplanation: String? {
        switch storage {
        case .whole:
            return nil
        case .sparse:
            let both =
                "A sparse file: \(ByteFormat.decimal(size)) long, of which "
                + "\(ByteFormat.decimal(alloc)) has been written and takes up "
                + "space."
            // Not promised for a name that shares its storage: removing one
            // of those frees nothing while another still holds the file.
            return sharesStorage
                ? both : both + " Deleting it frees the smaller figure."
        case .dataless:
            return "Kept by a cloud provider and not downloaded: "
                + "\(ByteFormat.decimal(size)) long, with "
                + "\(ByteFormat.decimal(alloc)) of it on this disk."
        }
    }
}

/// Why a directory's contents are missing from the scan.
enum DirExclusion: UInt8 {
    case none
    /// `opendir`/`getattrlistbulk` failed — usually missing Full Disk Access.
    case permissionDenied
    /// A mount point belonging to a different volume.
    case otherVolume
    /// Already counted under a different path (an APFS firmlink).
    case alreadyCounted
    /// Enumeration started but stopped early, so the contents are incomplete.
    /// Distinct from `permissionDenied`: some of the folder *is* in the totals,
    /// which is the case most likely to be mistaken for a complete reading.
    case partiallyRead
}

/// A directory in the scanned tree.
final class DirNode {
    /// Stable identity for the lifetime of the process.
    ///
    /// `ObjectIdentifier` would be the obvious key for the Tree View's expansion
    /// set, but it is the object's address: once a delete unlinks a subtree and
    /// frees it, a later allocation can be handed the same address and inherit
    /// whatever state was filed under it. A counter is never reused.
    let id: UInt64 = DirNode.nextID.increment()
    private static let nextID = Counter()

    /// Monotonic across every thread that builds tree nodes — the scan workers
    /// all allocate concurrently.
    private final class Counter {
        private let lock = UnfairLock()
        private var value: UInt64 = 0
        func increment() -> UInt64 {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    let name: String
    /// Weak because the root retains the whole tree top-down; making this
    /// strong would create a reference cycle and leak the tree on rescan.
    ///
    /// It was `unowned(unsafe)`, on the understanding that anything holding a
    /// node would keep its ancestors alive too. Too much holds a node without
    /// being able to promise that: SwiftUI keeps a closed context menu's
    /// references and re-runs its body on every publish, long after a rescan
    /// or a delete has freed the folders above them. Each one of those was a
    /// read of freed memory waiting for the allocator to reuse it, and three
    /// separate crashes came from it. A parent that has gone now reads as nil.
    ///
    /// The cost is a side table per folder that has subfolders, and it does
    /// not show up in scan time. The places that pin the chain on purpose —
    /// `TreemapModel.ancestors`, the delete batch's own targets — still do, so
    /// they go on seeing full paths rather than truncated ones.
    weak var parent: DirNode?

    var subdirs: [DirNode] = []
    var files: [FileEntry] = []

    /// Logical size of this subtree, including all descendants.
    var totalSize: UInt64 = 0
    /// Size on disk of this subtree.
    var totalAlloc: UInt64 = 0
    var totalFiles: Int = 0
    var totalDirs: Int = 0
    var mtime: Double = 0
    var exclusion: DirExclusion = .none

    init(name: String, parent: DirNode?, mtime: Double = 0) {
        self.name = name
        self.parent = parent
        self.mtime = mtime
    }

    /// Total entries in this subtree, matching WizTree's "Items" column.
    var totalItems: Int { totalFiles + totalDirs }

    func bytes(using metric: SizeMetric) -> UInt64 {
        metric == .logical ? totalSize : totalAlloc
    }

    var isRoot: Bool { parent == nil }

    /// True when there is nothing in here to show: no folders, and no file
    /// that hasn't been deleted. `files.isEmpty` stops being that once a
    /// delete has left a slot behind.
    var isEmpty: Bool {
        subdirs.isEmpty && !files.contains { !$0.isRemoved }
    }

    /// Absolute filesystem path, rebuilt by walking up to the root (whose
    /// `name` holds the full path the scan started from).
    ///
    /// Empty when the walk doesn't end at a scan root — a node kept from a
    /// scan that has been replaced, whose folders above it are gone. What is
    /// left of the chain would otherwise come out as a relative path, and a
    /// delete handed one of those resolves it against the working directory.
    /// Only a root's name is absolute, so that is how a broken chain is told.
    var path: String {
        var parts: [String] = []
        var node: DirNode? = self
        while let current = node {
            parts.append(current.name)
            node = current.parent
        }
        guard parts[parts.count - 1].hasPrefix("/") else { return "" }
        var result = parts.removeLast()
        while let part = parts.popLast() {
            if !result.hasSuffix("/") { result += "/" }
            result += part
        }
        return result
    }

    /// True when the walk up from here no longer ends at a scan root: this
    /// folder outlived the scan it came from, and what was above it is gone.
    var isCutOff: Bool {
        var top = self
        while let above = top.parent { top = above }
        return !top.name.hasPrefix("/")
    }

    func path(ofFileAt index: Int) -> String {
        let base = path
        guard !base.isEmpty else { return "" }
        return base.hasSuffix("/")
            ? base + files[index].name : base + "/" + files[index].name
    }

    /// Fraction of the parent's size this node accounts for — WizTree's
    /// "% of Parent" column.
    var fractionOfParent: Double {
        guard let parent, parent.totalSize > 0 else { return 1 }
        return Double(totalSize) / Double(parent.totalSize)
    }

    func subdir(named name: String) -> DirNode? {
        subdirs.first { $0.name == name }
    }
}

/// Points at either a directory or a single file within one, so the tree table,
/// file list and treemap can all carry the same selection.
struct NodeRef: Hashable, Identifiable {
    let dir: DirNode
    /// -1 when the reference is the directory itself.
    let fileIndex: Int32

    init(_ dir: DirNode) {
        self.dir = dir
        self.fileIndex = -1
    }

    init(dir: DirNode, fileIndex: Int) {
        self.dir = dir
        self.fileIndex = Int32(fileIndex)
    }

    var isDirectory: Bool { fileIndex < 0 }

    /// True when this points at a file that has been deleted, or into a
    /// folder or a scan that is no longer part of the tree on show.
    ///
    /// A deleted file keeps its slot, so a reference to one of its siblings
    /// goes on naming the same file — but one to the file itself, or to
    /// anything under a folder that went, names nothing. Derived rows are
    /// rebuilt after a delete, but SwiftUI keeps a context menu's content alive
    /// and re-evaluates it once the sheet closes — by then the tree has already
    /// changed under it. Every accessor below therefore degrades to an empty
    /// value instead of trapping, and anything that acts on a reference checks
    /// this first.
    ///
    /// The same menu outlives a rescan too, holding references whose folder is
    /// still alive and whose scan is not. Those name nothing that is on show.
    var isStale: Bool {
        if fileIndex >= 0 {
            // Asked of the slot where it sits, without copying the entry out:
            // this is run over whole selections.
            let index = Int(fileIndex)
            if index >= dir.files.count || dir.files[index].isRemoved { return true }
        }
        return dir.isCutOff
    }

    /// Nil for a directory, and for a file that has been deleted.
    var file: FileEntry? {
        guard fileIndex >= 0, Int(fileIndex) < dir.files.count,
            !dir.files[Int(fileIndex)].isRemoved
        else { return nil }
        return dir.files[Int(fileIndex)]
    }

    var name: String {
        fileIndex < 0 ? dir.name : (file?.name ?? "")
    }

    var size: UInt64 {
        fileIndex < 0 ? dir.totalSize : (file?.size ?? 0)
    }

    var alloc: UInt64 {
        fileIndex < 0 ? dir.totalAlloc : (file?.alloc ?? 0)
    }

    /// `size` or `alloc`, whichever `metric` asks for.
    ///
    /// Anything that states how big an item is goes through here. Reading
    /// `size` directly is how the header came to report a scan as 1.7 TB on a
    /// 995 GB disk while the rest of the window was showing space on disk: one
    /// sparse image's length, added in as though it were occupied.
    func bytes(using metric: SizeMetric) -> UInt64 {
        metric == .logical ? size : alloc
    }

    var mtime: Double {
        fileIndex < 0 ? dir.mtime : (file?.mtime ?? 0)
    }

    /// Empty for a stale reference rather than the containing folder's path —
    /// a delete resolves its targets through here, and falling back to the
    /// folder would aim it at the parent of what the user picked.
    var path: String {
        if fileIndex < 0 { return dir.path }
        guard !isStale else { return "" }
        return dir.path(ofFileAt: Int(fileIndex))
    }

    /// Size relative to the containing directory, for the "% of Parent" column.
    var fractionOfParent: Double {
        if fileIndex < 0 { return dir.fractionOfParent }
        guard dir.totalSize > 0, let file else { return 0 }
        return Double(file.size) / Double(dir.totalSize)
    }

    /// As `fractionOfParent`, but measured with the metric currently on show so
    /// the bars agree with the treemap.
    func fractionOfParent(using metric: SizeMetric) -> Double {
        guard metric == .allocated else { return fractionOfParent }
        if fileIndex < 0 {
            guard let parent = dir.parent, parent.totalAlloc > 0 else { return 1 }
            return Double(dir.totalAlloc) / Double(parent.totalAlloc)
        }
        guard dir.totalAlloc > 0, let file else { return 0 }
        return Double(file.alloc) / Double(dir.totalAlloc)
    }

    var id: Self { self }

    static func == (lhs: NodeRef, rhs: NodeRef) -> Bool {
        lhs.dir === rhs.dir && lhs.fileIndex == rhs.fileIndex
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(dir))
        hasher.combine(fileIndex)
    }
}

/// A flag a background tree walk checks so it can give up part-way.
///
/// The walk reads nodes that a delete is about to unlink, so the delete has to
/// know the walk has stopped touching them — cancelling the queued work item
/// only helps if it hasn't started. This lets one that has started notice and
/// return, which turns the delete's wait from a full pass over every file in the
/// scan into the gap between two checks.
final class WalkToken {
    private let lock = UnfairLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Aggregate totals for one file extension across the whole scan.
struct ExtensionStat: Identifiable, Hashable {
    /// Lowercased, without the leading dot. Empty means "no extension".
    let ext: String

    var id: String { ext }
    var size: UInt64 = 0
    var alloc: UInt64 = 0
    var count: Int = 0
    /// Index into `TreemapPalette`, assigned by descending total size.
    var colorIndex: Int = 0

    var displayName: String { ext.isEmpty ? "(no ext)" : "." + ext }

    /// Best-effort human name for the type, as WizTree's "File Type" column shows.
    var typeName: String {
        if ext.isEmpty { return "File" }
        return ext.uppercased() + " File"
    }
}

/// Everything one completed scan produced.
final class ScanResult {
    let root: DirNode
    let rootPath: String
    /// Sorted by total size, descending, as the scan found them.
    ///
    /// A delete lowers entries in place and never reorders them: a file's
    /// `extIndex` is its type's position in this array. A type whose last file
    /// has gone stays here with a count of zero, so anything listing types
    /// wants `topBySize`, `topByAllocated` or `typeCount` instead.
    private(set) var extensionStats: [ExtensionStat]
    /// The types that still have files, ranked by logical size and by space on
    /// disk, each capped at what the legend shows.
    ///
    /// Kept rather than computed, because the legend's body runs for anything
    /// the model publishes — hovering the treemap included — and ranking meant
    /// sorting every extension on the disk each time. They can only change
    /// when the tree does, so a delete re-ranks them once.
    private(set) var topBySize: [ExtensionStat] = []
    private(set) var topByAllocated: [ExtensionStat] = []
    /// The same two rankings uncut, for when the legend is asked to list
    /// every type and not only the ones that fit at a glance.
    private(set) var allBySize: [ExtensionStat] = []
    private(set) var allByAllocated: [ExtensionStat] = []
    /// How many types the legend lists until it is asked for all of them.
    static let legendLength = 40
    /// How many types still have at least one file.
    private(set) var typeCount = 0
    private let extensionIndex: [String: Int]

    let elapsed: TimeInterval
    let deniedCount: Int
    /// Bytes that would be double-counted if every name of a hard-linked file
    /// were counted in full. Falls as duplicates are promoted or removed, so the
    /// status line keeps describing the tree actually on show.
    private(set) var hardLinkSavings: UInt64
    /// The same, measured in space on disk rather than in length.
    ///
    /// Kept separately because the two are not a ratio apart: a second name for
    /// a sparse image saves the image's whole length by one measure and next to
    /// nothing by the other.
    private(set) var hardLinkAllocSavings: UInt64
    let volumeTotal: UInt64
    let volumeFree: UInt64
    let volumeUsed: UInt64
    /// True when the root spans an APFS system + data volume pair, whose
    /// container space is shared and so cannot be attributed to one volume.
    let isSharedContainer: Bool

    init(
        root: DirNode,
        rootPath: String,
        extensionStats: [ExtensionStat],
        elapsed: TimeInterval,
        deniedCount: Int,
        hardLinkSavings: UInt64,
        hardLinkAllocSavings: UInt64,
        volumeTotal: UInt64,
        volumeFree: UInt64,
        volumeUsed: UInt64,
        isSharedContainer: Bool
    ) {
        self.root = root
        self.rootPath = rootPath
        self.extensionStats = extensionStats
        self.elapsed = elapsed
        self.deniedCount = deniedCount
        self.hardLinkSavings = hardLinkSavings
        self.hardLinkAllocSavings = hardLinkAllocSavings
        self.volumeTotal = volumeTotal
        self.volumeFree = volumeFree
        self.volumeUsed = volumeUsed
        self.isSharedContainer = isSharedContainer

        var index: [String: Int] = [:]
        index.reserveCapacity(extensionStats.count)
        for (i, stat) in extensionStats.enumerated() { index[stat.ext] = i }
        self.extensionIndex = index
        rankTypes()
    }

    /// Works the legend's two rankings out again from the per-type totals.
    func rankTypes() {
        let present = extensionStats.filter { $0.count > 0 }
        typeCount = present.count
        allBySize = present.sorted { $0.size > $1.size }
        allByAllocated = present.sorted { $0.alloc > $1.alloc }
        topBySize = Array(allBySize.prefix(Self.legendLength))
        topByAllocated = Array(allByAllocated.prefix(Self.legendLength))
    }

    /// Takes a file that has left the tree out of its type's totals.
    ///
    /// A duplicate hard link only ever added to its type's count: its bytes
    /// are under the name they were counted for, which may be another type.
    func forgetType(of file: FileEntry) {
        let i = Int(file.extIndex)
        guard i >= 0, i < extensionStats.count else { return }
        extensionStats[i].count = max(0, extensionStats[i].count - 1)
        guard !file.isDuplicateLink else { return }
        extensionStats[i].size -= min(extensionStats[i].size, file.size)
        extensionStats[i].alloc -= min(extensionStats[i].alloc, file.alloc)
    }

    /// As `forgetType(of:)`, for every file under folders that are leaving.
    func forgetTypes(under removed: [DirNode]) {
        var stack: [DirNode] = removed
        while let dir = stack.popLast() {
            for i in dir.files.indices { forgetType(of: dir.files[i]) }
            stack.append(contentsOf: dir.subdirs)
        }
    }

    /// Gives a type the bytes of a name that has just been promoted to carry
    /// them. The name was already in its type's count, at no size.
    private func creditType(of file: FileEntry) {
        let i = Int(file.extIndex)
        guard i >= 0, i < extensionStats.count else { return }
        extensionStats[i].size += file.size
        extensionStats[i].alloc += file.alloc
    }

    func stat(for ext: String) -> ExtensionStat? {
        extensionIndex[ext].map { extensionStats[$0] }
    }

    /// Where `ext` sits in `extensionStats`, which is the number a file of
    /// that type carries as its `extIndex` and a treemap tile as its colour.
    /// Nil for a type this scan never saw.
    func typeIndex(for ext: String) -> Int? { extensionIndex[ext] }

    /// Color index for a file, used by both the treemap and the legend.
    func colorIndex(for file: FileEntry) -> Int {
        let i = Int(file.extIndex)
        guard i >= 0, i < extensionStats.count else { return 0 }
        return extensionStats[i].colorIndex
    }

    /// The `limit` largest files whose name or path matches `query`, ranked by
    /// `metric`. `search` held to files, for the callers that want only them.
    func largestFiles(
        matching query: String = "",
        ofType typeIndex: Int? = nil,
        limit: Int = 1000,
        metric: SizeMetric = .allocated,
        token: WalkToken? = nil
    ) -> [NodeRef] {
        var files = SearchQuery(query)
        if files.kind == nil { files.kind = .file }
        return search(
            files,
            ofType: typeIndex,
            limit: limit,
            metric: metric,
            token: token
        ).rows
    }

    /// The `limit` largest things `query` finds, ranked by `metric`, with a
    /// count of everything it found and what that comes to.
    ///
    /// Walks the tree with a bounded min-heap instead of keeping a flat sorted
    /// array of every file, which on a full disk would cost tens of megabytes.
    /// Comes back empty if `token` is cancelled part-way: a caller that gave
    /// up is about to change the tree this is reading, and a partial ranking
    /// of it is worth nothing.
    ///
    /// `typeIndex` holds the list to one file type, named as `typeIndex(for:)`
    /// gives it.
    ///
    /// With nothing asked for, nothing is counted, and a file too small to
    /// make the list is passed over without a look. Counting is what a query
    /// costs: every file is then held up to it, whether or not it could have
    /// been listed, because "how many, and how much" is half of what was
    /// asked.
    func search(
        _ query: SearchQuery,
        ofType typeIndex: Int? = nil,
        limit: Int = 1000,
        metric: SizeMetric = .allocated,
        token: WalkToken? = nil
    ) -> SearchResult {
        // A filter that could not be read finds nothing. Left out, it would
        // list everything, as though whatever it was meant to say had been met.
        guard query.unreadable.isEmpty else { return SearchResult(matches: 0) }

        var wantedType = typeIndex.map { Int32($0) }
        if let ext = query.ext {
            // A type this scan never saw, or one that is not the type in
            // focus, is a type no file here can be.
            guard let index = self.typeIndex(for: ext).map({ Int32($0) }),
                wantedType == nil || wantedType == index
            else { return SearchResult(matches: 0) }
            wantedType = index
        }
        let counts = !query.isEmpty
        let wantsFiles = query.finds(.file)
        // A folder is no one type, so a type asked for leaves folders out.
        let wantsFolders = query.finds(.folder) && wantedType == nil
        let needsPaths = query.needsPaths

        var heap = SizeHeap(limit: limit)
        var matches = 0
        var bytes: UInt64 = 0
        // Checked per directory rather than per file — the flag is behind a
        // lock, and a directory is a short enough unit to keep the wait small.
        var sinceCheck = 0

        // An explicit stack rather than recursion: nothing bounds how deep a
        // scanned tree goes, and this walk runs on a queue whose threads get a
        // 512 KB stack. Each entry carries its own path, so a path filter
        // extends the parent's string instead of rebuilding an absolute path
        // from the parent chain once per directory.
        //
        // `covered` is true beneath a folder that matched: what matches in
        // there is listed and counted, and adds nothing to the total, which
        // already has the folder it is in.
        var stack: [(dir: DirNode, path: String, covered: Bool)] = [
            (root, needsPaths ? root.path : "", false)
        ]
        while let (dir, dirPath, covered) = stack.popLast() {
            sinceCheck += 1
            if sinceCheck >= 64, let token {
                sinceCheck = 0
                if token.isCancelled { return SearchResult() }
            }
            if wantsFiles {
                for i in dir.files.indices {
                    let file = dir.files[i]
                    if file.isDuplicateLink || file.isRemoved { continue }
                    if let wantedType, file.extIndex != wantedType { continue }
                    let weight = metric == .logical ? file.size : file.alloc
                    if counts {
                        guard query.admits(bytes: weight, mtime: file.mtime),
                            query.matches(name: file.name),
                            !needsPaths
                                || query.matches(
                                    path: dirPath.hasSuffix("/")
                                        ? dirPath + file.name
                                        : dirPath + "/" + file.name
                                )
                        else { continue }
                        matches += 1
                        if !covered { bytes += weight }
                    } else if !heap.wouldAccept(weight) {
                        continue
                    }
                    heap.insert(NodeRef(dir: dir, fileIndex: i), size: weight)
                }
            }
            for sub in dir.subdirs {
                let subPath =
                    needsPaths
                    ? (dirPath.hasSuffix("/")
                        ? dirPath + sub.name : dirPath + "/" + sub.name)
                    : ""
                var found = false
                if wantsFolders {
                    let weight = sub.bytes(using: metric)
                    if query.admits(bytes: weight, mtime: sub.mtime),
                        query.matches(name: sub.name),
                        !needsPaths || query.matches(path: subPath)
                    {
                        found = true
                        matches += 1
                        if !covered { bytes += weight }
                        heap.insert(NodeRef(sub), size: weight)
                    }
                }
                stack.append((sub, subPath, covered || found))
            }
        }
        return SearchResult(
            rows: heap.sortedDescending(),
            matches: counts ? matches : nil,
            bytes: bytes
        )
    }

    /// Total across every file, ignoring hard-link duplicates.
    var fileCount: Int { root.totalFiles }

    /// Records that one name of a hard-linked file is being removed, and fixes
    /// up the names that remain.
    ///
    /// The scan counts such a file's bytes once, under whichever of its names a
    /// worker reached first, and marks the rest as duplicates worth nothing.
    /// Two things then have to happen when a name goes:
    ///
    /// - Every surviving name loses a link. One left as the last name stops
    ///   sharing its storage, so a delete can promise its bytes back again.
    ///   Only when `unlinking`, though: a name moved to the Trash is still a
    ///   name for the inode, and deleting a survivor frees nothing until the
    ///   Trash is emptied, so its count stands.
    /// - If the name leaving is the one carrying the bytes, a survivor takes
    ///   over the count — the bytes are still on disk under that other name,
    ///   and dropping them from the totals would have the tree disagree with
    ///   the disk until the next scan.
    ///
    /// One full walk, affordable because it only runs when a hard-linked file is
    /// actually removed. Returns the promoted name's folder and the bytes it now
    /// accounts for, or nil when there was nothing in the tree to promote.
    @discardableResult
    func releaseHardLink(
        at leaving: (dir: DirNode, index: Int),
        promoting wantsPromotion: Bool,
        unlinking: Bool
    ) -> (dir: DirNode, size: UInt64, alloc: UInt64)? {
        // Trashing a name that carried no bytes changes nothing for the rest.
        guard wantsPromotion || unlinking else { return nil }
        let fileID = leaving.dir.files[leaving.index].fileID
        var promoted: (dir: DirNode, size: UInt64, alloc: UInt64)?

        var stack: [DirNode] = [root]
        while let dir = stack.popLast() {
            for i in dir.files.indices where dir.files[i].fileID == fileID {
                if dir === leaving.dir && i == leaving.index { continue }

                // A saturated count is left alone: the real number of names is
                // unknown, so decrementing could wrongly reach 1.
                if unlinking, dir.files[i].linkCount > 1,
                    dir.files[i].linkCount < .max
                {
                    dir.files[i].linkCount -= 1
                }
                if wantsPromotion, promoted == nil, dir.files[i].isDuplicateLink {
                    dir.files[i].isDuplicateLink = false
                    promoted = (dir, dir.files[i].size, dir.files[i].alloc)
                    dropSavings(of: dir.files[i])
                    creditType(of: dir.files[i])
                }
            }
            stack.append(contentsOf: dir.subdirs)
        }
        return promoted
    }

    /// As `releaseHardLink`, for every name under folders that are being
    /// removed whole.
    ///
    /// A folder's totals come off in one step, so nothing looked at the files
    /// inside it: a counted name went with its folder and took the bytes out of
    /// the tree while another name still held them on disk, and a duplicate
    /// went without its partner ever losing a link.
    ///
    /// The names leaving are gathered first and the rest of the tree is walked
    /// once for all of them — every folder in the batch together, not one walk
    /// each. `releaseHardLink` per file would be a full walk per link, and a
    /// folder can hold hundreds of thousands; a walk per folder froze the
    /// window for seconds once a few hundred were deleted at a time.
    ///
    /// `removed` must not nest, which a delete batch never does, and has to
    /// still be attached, so it can be told apart from what survives it.
    /// Returns each promoted name's folder and the bytes it now accounts for.
    ///
    /// `unlinking` is as for `releaseHardLink`: a trashed folder's names still
    /// exist, so the survivors keep their link counts and only the promotion
    /// happens.
    func releaseHardLinks(
        under removed: [DirNode],
        unlinking: Bool
    ) -> [(dir: DirNode, size: UInt64, alloc: UInt64)] {
        // Per inode: how many of its names are leaving, and whether one of
        // them is the name its bytes are counted under.
        var leaving: [UInt64: (names: Int, counted: Bool)] = [:]
        var stack: [DirNode] = removed
        while let dir = stack.popLast() {
            for i in dir.files.indices where dir.files[i].sharesStorage {
                var going = leaving[dir.files[i].fileID] ?? (0, false)
                going.names += 1
                if dir.files[i].isDuplicateLink {
                    dropSavings(of: dir.files[i])
                } else {
                    going.counted = true
                }
                leaving[dir.files[i].fileID] = going
            }
            stack.append(contentsOf: dir.subdirs)
        }
        // Most folders hold no hard links at all, and the walk below is a pass
        // over everything else in the scan.
        guard !leaving.isEmpty else { return [] }
        // Nor is it needed with no count to lower and no bytes to hand on:
        // nothing outside the folder changes.
        guard unlinking || leaving.values.contains(where: \.counted) else {
            return []
        }

        let gone = Set(removed.map { ObjectIdentifier($0) })
        var promoted: [(dir: DirNode, size: UInt64, alloc: UInt64)] = []
        stack = [root]
        while let dir = stack.popLast() {
            if gone.contains(ObjectIdentifier(dir)) { continue }
            for i in dir.files.indices where dir.files[i].sharesStorage {
                guard let going = leaving[dir.files[i].fileID] else { continue }

                // A saturated count is left alone, as above.
                if unlinking, dir.files[i].linkCount < .max {
                    let left = Int(dir.files[i].linkCount) - going.names
                    dir.files[i].linkCount = UInt8(max(1, left))
                }
                if going.counted, dir.files[i].isDuplicateLink {
                    dir.files[i].isDuplicateLink = false
                    promoted.append((dir, dir.files[i].size, dir.files[i].alloc))
                    dropSavings(of: dir.files[i])
                    creditType(of: dir.files[i])
                    // Only the first survivor takes the bytes over.
                    leaving[dir.files[i].fileID]?.counted = false
                }
            }
            stack.append(contentsOf: dir.subdirs)
        }
        return promoted
    }

    /// Takes a duplicate name out of the double-counting statistic when it is
    /// removed outright rather than promoted.
    func forgetDuplicate(_ file: FileEntry) {
        dropSavings(of: file)
    }

    /// The double-counting statistic in the measure asked for.
    func hardLinkSavings(using metric: SizeMetric) -> UInt64 {
        metric == .logical ? hardLinkSavings : hardLinkAllocSavings
    }

    /// One duplicate name stops being a duplicate, by either route. Both
    /// measures move together, or the status line's two readings of the same
    /// tree drift apart with every delete.
    private func dropSavings(of file: FileEntry) {
        hardLinkSavings -= min(hardLinkSavings, file.size)
        hardLinkAllocSavings -= min(hardLinkAllocSavings, file.alloc)
    }
}

/// Bounded min-heap that keeps the `limit` largest items seen.
///
/// Of items the same size, the ones seen first are the ones kept, and they
/// come back out in the order they were seen. Which of them made the cut used
/// to depend on how the heap happened to be laid out, so removing one file
/// from a scan could change which of its equals were listed and in what
/// order — in a folder of small files, where most are the same few sizes, the
/// File View reshuffled on every delete. A walk visits what is left in the
/// same order as before, so with this the list is what it was, less what
/// went, with the next in line added at the end.
private struct SizeHeap {
    private var sizes: [UInt64] = []
    /// When each was seen: its place among everything offered.
    private var orders: [Int] = []
    private var refs: [NodeRef] = []
    private var seen = 0
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
        sizes.reserveCapacity(self.limit + 1)
        orders.reserveCapacity(self.limit + 1)
        refs.reserveCapacity(self.limit + 1)
    }

    /// Cheap pre-filter: skip work for items that cannot displace the minimum.
    /// One the same size as the minimum can't: it was seen later.
    func wouldAccept(_ size: UInt64) -> Bool {
        sizes.count < limit || size > sizes[0]
    }

    mutating func insert(_ ref: NodeRef, size: UInt64) {
        seen += 1
        if sizes.count < limit {
            sizes.append(size)
            orders.append(seen)
            refs.append(ref)
            siftUp(from: sizes.count - 1)
        } else if size > sizes[0] {
            sizes[0] = size
            orders[0] = seen
            refs[0] = ref
            siftDown(from: 0)
        }
    }

    func sortedDescending() -> [NodeRef] {
        sizes.indices
            .sorted { isBehind($1, $0) }
            .map { refs[$0] }
    }

    /// Whether the item at `a` ranks behind the one at `b`: smaller, or the
    /// same size and seen later. The root is the one behind all the rest,
    /// which is the one to go when something bigger turns up.
    private func isBehind(_ a: Int, _ b: Int) -> Bool {
        sizes[a] != sizes[b] ? sizes[a] < sizes[b] : orders[a] > orders[b]
    }

    private mutating func swapAt(_ a: Int, _ b: Int) {
        sizes.swapAt(a, b)
        orders.swapAt(a, b)
        refs.swapAt(a, b)
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            if !isBehind(child, parent) { break }
            swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var last = parent
            if left < sizes.count, isBehind(left, last) { last = left }
            if right < sizes.count, isBehind(right, last) { last = right }
            if last == parent { return }
            swapAt(parent, last)
            parent = last
        }
    }
}

extension String {
    /// Reads this string's UTF-8 as a contiguous buffer without copying it,
    /// which is what every natively created Swift string can offer. Only a
    /// string bridged from `NSString` takes the copying fallback.
    @inline(__always)
    func withUTF8Bytes<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        if let result = utf8.withContiguousStorageIfAvailable(body) { return result }
        var copy = self
        return copy.withUTF8(body)
    }

    /// Case-folded and canonically decomposed, so two spellings of the same
    /// text come out byte for byte the same: `É` and `é`, and either of them
    /// whether it is one precomposed scalar or a letter plus a combining mark.
    ///
    /// The second half matters as much as the first. Most of macOS writes an
    /// accented name to disk decomposed, a text field types it precomposed, and
    /// without this the two never meet.
    var foldedForSearch: String {
        var folded = folding(options: .caseInsensitive, locale: nil)
            .decomposedStringWithCanonicalMapping
        // Both steps hand back a bridged `NSString`. `withUTF8Bytes` can only
        // read one of those by copying it, and for the needle that would be
        // once per name it is compared against.
        folded.makeContiguousUTF8()
        return folded
    }

    /// As `containsCaseInsensitive`, for a filter typed with anything beyond
    /// ASCII in it; `needle` is expected to be `foldedForSearch` already.
    ///
    /// Folding allocates, which is what `containsCaseInsensitive` exists to
    /// avoid, so it is kept off the common path twice over: only such a filter
    /// comes here, and a name that is pure ASCII — which is most names — folds
    /// to itself give or take case, so it is compared as it stands.
    func containsFolded(_ needle: String) -> Bool {
        guard utf8.contains(where: { $0 >= 0x80 }) else {
            return containsCaseInsensitive(needle)
        }
        return foldedForSearch.containsCaseInsensitive(needle)
    }

    /// ASCII-focused case-insensitive substring test. `localizedCaseInsensitive`
    /// variants are far too slow to run across millions of filenames per
    /// keystroke; `needle` is expected to be already lowercased.
    ///
    /// Both sides are read in place. Materializing `[UInt8]` arrays here instead
    /// put two heap allocations inside a loop that runs over every file in the
    /// scan that clears the size prefilter, on each keystroke.
    func containsCaseInsensitive(_ needle: String) -> Bool {
        if needle.isEmpty { return true }
        return withUTF8Bytes { hay in
            needle.withUTF8Bytes { pin in
                String.contains(hay: hay, pin: pin)
            }
        }
    }

    private static func contains(
        hay: UnsafeBufferPointer<UInt8>,
        pin: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        if pin.isEmpty { return true }
        if pin.count > hay.count { return false }

        @inline(__always) func lower(_ c: UInt8) -> UInt8 {
            (c >= 65 && c <= 90) ? c + 32 : c
        }

        let first = lower(pin[0])
        let last = hay.count - pin.count
        var i = 0
        while i <= last {
            if lower(hay[i]) == first {
                var j = 1
                while j < pin.count, lower(hay[i + j]) == lower(pin[j]) { j += 1 }
                if j == pin.count { return true }
            }
            i += 1
        }
        return false
    }
}
