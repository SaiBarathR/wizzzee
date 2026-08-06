import Foundation

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
    var isSymlink: Bool
    /// A hard link whose size was already counted under another path.
    var isDuplicateLink: Bool
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
}

/// A directory in the scanned tree.
final class DirNode {
    let name: String
    /// Unowned because the root retains the whole tree top-down; making this
    /// strong would create a reference cycle and leak the tree on rescan.
    unowned(unsafe) var parent: DirNode?

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

    var isRoot: Bool { parent == nil }

    /// Absolute filesystem path, rebuilt by walking up to the root (whose
    /// `name` holds the full path the scan started from).
    var path: String {
        var parts: [String] = []
        var node: DirNode? = self
        while let current = node {
            parts.append(current.name)
            node = current.parent
        }
        var result = parts.removeLast()
        while let part = parts.popLast() {
            if !result.hasSuffix("/") { result += "/" }
            result += part
        }
        return result
    }

    func path(ofFileAt index: Int) -> String {
        let base = path
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

    /// True when this points at a file index its folder no longer has.
    ///
    /// Deleting a file renumbers every sibling after it, which invalidates any
    /// reference captured beforehand. Derived rows are rebuilt after a delete,
    /// but SwiftUI keeps a context menu's content alive and re-evaluates it once
    /// the sheet closes — by then the tree has already changed under it. Every
    /// accessor below therefore degrades to an empty value instead of trapping,
    /// and anything that acts on a reference checks this first.
    var isStale: Bool { fileIndex >= 0 && Int(fileIndex) >= dir.files.count }

    var file: FileEntry? {
        guard fileIndex >= 0, Int(fileIndex) < dir.files.count else { return nil }
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
    /// Sorted by total size, descending.
    let extensionStats: [ExtensionStat]
    private let extensionIndex: [String: Int]

    let elapsed: TimeInterval
    let deniedCount: Int
    let hardLinkSavings: UInt64
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
        self.volumeTotal = volumeTotal
        self.volumeFree = volumeFree
        self.volumeUsed = volumeUsed
        self.isSharedContainer = isSharedContainer

        var index: [String: Int] = [:]
        index.reserveCapacity(extensionStats.count)
        for (i, stat) in extensionStats.enumerated() { index[stat.ext] = i }
        self.extensionIndex = index
    }

    func stat(for ext: String) -> ExtensionStat? {
        extensionIndex[ext].map { extensionStats[$0] }
    }

    /// Color index for a file, used by both the treemap and the legend.
    func colorIndex(for file: FileEntry) -> Int {
        let i = Int(file.extIndex)
        guard i >= 0, i < extensionStats.count else { return 0 }
        return extensionStats[i].colorIndex
    }

    /// The `limit` largest files whose name or path matches `query`, ranked by
    /// `metric`.
    ///
    /// Walks the tree with a bounded min-heap instead of keeping a flat sorted
    /// array of every file, which on a full disk would cost tens of megabytes.
    func largestFiles(
        matching query: String = "",
        limit: Int = 1000,
        metric: SizeMetric = .allocated
    ) -> [NodeRef] {
        let needle = query.lowercased()
        let matchPath = needle.contains("/")
        var heap = SizeHeap(limit: limit)

        func walk(_ dir: DirNode) {
            if !dir.files.isEmpty {
                // Only build the (expensive) full path string when the filter
                // actually needs it and the file is big enough to make the cut.
                let dirPath = matchPath && !needle.isEmpty ? dir.path : ""
                for i in dir.files.indices {
                    let file = dir.files[i]
                    if file.isDuplicateLink { continue }
                    let weight = metric == .logical ? file.size : file.alloc
                    if !heap.wouldAccept(weight) { continue }
                    if !needle.isEmpty {
                        let haystack =
                            matchPath
                            ? (dirPath + "/" + file.name) : file.name
                        if !haystack.containsCaseInsensitive(needle) { continue }
                    }
                    heap.insert(NodeRef(dir: dir, fileIndex: i), size: weight)
                }
            }
            for sub in dir.subdirs { walk(sub) }
        }
        walk(root)
        return heap.sortedDescending()
    }

    /// Total across every file, ignoring hard-link duplicates.
    var fileCount: Int { root.totalFiles }
}

/// Bounded min-heap that keeps the `limit` largest items seen.
private struct SizeHeap {
    private var sizes: [UInt64] = []
    private var refs: [NodeRef] = []
    private let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
        sizes.reserveCapacity(self.limit + 1)
        refs.reserveCapacity(self.limit + 1)
    }

    /// Cheap pre-filter: skip work for items that cannot displace the minimum.
    func wouldAccept(_ size: UInt64) -> Bool {
        sizes.count < limit || size > sizes[0]
    }

    mutating func insert(_ ref: NodeRef, size: UInt64) {
        if sizes.count < limit {
            sizes.append(size)
            refs.append(ref)
            siftUp(from: sizes.count - 1)
        } else if size > sizes[0] {
            sizes[0] = size
            refs[0] = ref
            siftDown(from: 0)
        }
    }

    func sortedDescending() -> [NodeRef] {
        zip(sizes, refs)
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }

    private mutating func siftUp(from start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            if sizes[child] >= sizes[parent] { break }
            sizes.swapAt(child, parent)
            refs.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from start: Int) {
        var parent = start
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < sizes.count, sizes[left] < sizes[smallest] { smallest = left }
            if right < sizes.count, sizes[right] < sizes[smallest] { smallest = right }
            if smallest == parent { return }
            sizes.swapAt(parent, smallest)
            refs.swapAt(parent, smallest)
            parent = smallest
        }
    }
}

extension String {
    /// ASCII-focused case-insensitive substring test. `localizedCaseInsensitive`
    /// variants are far too slow to run across millions of filenames per
    /// keystroke; `needle` is expected to be already lowercased.
    func containsCaseInsensitive(_ needle: String) -> Bool {
        if needle.isEmpty { return true }
        let hay = Array(utf8)
        let pin = Array(needle.utf8)
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
