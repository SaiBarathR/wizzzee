import Foundation

/// Minimal `os_unfair_lock` wrapper — cheaper than `NSLock` for the very short
/// critical sections in the scan hot path.
final class UnfairLock {
    private let handle: UnsafeMutablePointer<os_unfair_lock>

    init() {
        handle = .allocate(capacity: 1)
        handle.initialize(to: os_unfair_lock())
    }

    deinit {
        handle.deinitialize(count: 1)
        handle.deallocate()
    }

    @inline(__always)
    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(handle)
        defer { os_unfair_lock_unlock(handle) }
        return body()
    }
}

/// Identifies a filesystem object across volumes.
private struct ObjectKey: Hashable {
    let dev: Int32
    let ino: UInt64
}

/// Lock-sharded set of `ObjectKey`s. Both the visited-directory set and the
/// hard-link set are hit for essentially every entry scanned, so a single lock
/// would serialize all the workers.
private final class ShardedKeySet {
    private static let shardCount = 32

    /// One lock and one set per shard, in an object of their own.
    ///
    /// Holding the sets in a single `[Set<ObjectKey>]` and mutating
    /// `shards[i]` under a per-shard lock touches disjoint memory, but every
    /// worker takes a `modify` access on the one array property to get there,
    /// which is exactly the overlapping access Swift's exclusivity rules
    /// forbid. Per-shard objects make each mutation local to its own storage,
    /// at the same cost.
    private final class Shard {
        let lock = UnfairLock()
        var keys = Set<ObjectKey>()
    }

    private let shards: [Shard]

    init() {
        shards = (0..<Self.shardCount).map { _ in Shard() }
    }

    /// Inserts `key`, returning true if it was not already present.
    func insert(_ key: ObjectKey) -> Bool {
        // Taken unsigned rather than via abs(), which traps on Int.min.
        let index = Int(UInt(bitPattern: key.ino.hashValue) % UInt(Self.shardCount))
        let shard = shards[index]
        return shard.lock.withLock { shard.keys.insert(key).inserted }
    }
}

/// Walks a directory tree in parallel and builds a `ScanResult`.
///
/// Enumeration uses `getattrlistbulk(2)` (see `BulkEnumerator`) across a pool of
/// worker threads that share a work stack of pending directories, so a fast SSD
/// stays saturated. Sizes are aggregated bottom-up in a single pass afterwards,
/// which keeps the parallel phase lock-free apart from progress counters.
final class ScanEngine {
    struct Progress {
        var items: Int = 0
        var bytes: UInt64 = 0
        var currentPath: String = ""
        var elapsed: TimeInterval = 0
    }

    /// Called on a background thread, a few times per second.
    var onProgress: ((Progress) -> Void)?

    private let stateLock = UnfairLock()
    private var isCancelled = false

    // Shared counters, updated in batches by the workers.
    private var itemsSeen = 0
    private var bytesSeen: UInt64 = 0
    private var deniedCount = 0
    private var hardLinkSavings: UInt64 = 0
    private var currentPath = ""

    func cancel() {
        let stack = stateLock.withLock { () -> WorkStack? in
            isCancelled = true
            return workStack
        }
        stack?.stop()
    }

    private var checkCancelled: Bool {
        stateLock.withLock { isCancelled }
    }

    /// Guarded by `stateLock`, because `cancel()` reaches for it from the main
    /// thread while the scan thread is setting it up.
    private var workStack: WorkStack?

    /// Publishes the stack so `cancel()` can reach it. A cancel that arrived
    /// before this point set only the flag and found nothing to stop, so the
    /// stack is stopped here instead — otherwise stopping a scan in its first
    /// instants would let the whole walk run to completion before the result
    /// was thrown away.
    private func install(_ stack: WorkStack) {
        let cancelledAlready = stateLock.withLock { () -> Bool in
            workStack = stack
            return isCancelled
        }
        if cancelledAlready { stack.stop() }
    }

    // MARK: - Work distribution

    private struct WorkItem {
        let node: DirNode
        let path: String
        /// Device of the volume this directory lives on.
        let dev: Int32
    }

    /// LIFO work stack with completion tracking: workers block in `next()` until
    /// either new work arrives or every worker has gone idle, which is what
    /// signals that the tree is fully walked.
    private final class WorkStack {
        private let condition = NSCondition()
        private var items: [WorkItem] = []
        private var activeWorkers = 0
        private var stopped = false
        /// True only when `stop()` is what ended the walk, rather than the work
        /// running out. A Stop that arrives after the tree is fully walked has
        /// nothing left to abandon, and the finished result is worth keeping.
        private var abandoned = false

        /// Whether the walk was cut short. Read once the workers have joined.
        var wasAbandoned: Bool {
            condition.lock()
            defer { condition.unlock() }
            return abandoned
        }

        func seed(_ item: WorkItem) {
            condition.lock()
            items.append(item)
            condition.unlock()
        }

        func next() -> WorkItem? {
            condition.lock()
            defer { condition.unlock() }
            while true {
                if stopped { return nil }
                if let item = items.popLast() {
                    activeWorkers += 1
                    return item
                }
                if activeWorkers == 0 {
                    stopped = true
                    condition.broadcast()
                    return nil
                }
                condition.wait()
            }
        }

        func complete(pushing children: [WorkItem]) {
            condition.lock()
            items.append(contentsOf: children)
            activeWorkers -= 1
            if !children.isEmpty || activeWorkers == 0 { condition.broadcast() }
            condition.unlock()
        }

        func stop() {
            condition.lock()
            if !stopped {
                stopped = true
                abandoned = true
                items.removeAll()
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    // MARK: - Entry points

    /// How a scan ended.
    ///
    /// One `nil` for four different endings meant the caller had to read
    /// `wasCancelled` separately to tell them apart — two reads that a cancel
    /// arriving between them could land in, throwing away a finished result. It
    /// also collapsed "no such folder" and "not allowed to read it" into one
    /// message, when only the second has an action attached to it.
    enum Outcome {
        case completed(ScanResult)
        case cancelled
        case notADirectory(String)
        case unreadable(String, errno: Int32)

        /// The scan's result, or nil if it didn't produce one.
        var result: ScanResult? {
            if case .completed(let result) = self { return result }
            return nil
        }

        /// One line saying why there is no result, for the headless callers.
        /// Nil when the scan completed.
        var failureDescription: String? {
            switch self {
            case .completed:
                return nil
            case .cancelled:
                return "scan cancelled"
            case .notADirectory(let path):
                return "not a directory: \(path)"
            case .unreadable(let path, let code):
                return "can't read \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Runs a scan on the calling thread.
    func scanSynchronously(rootPath: String) -> Outcome {
        let started = Date()
        let normalized = Self.normalize(rootPath)

        var rootStat = stat()
        guard stat(normalized, &rootStat) == 0 else {
            return .unreadable(normalized, errno: errno)
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else {
            return .notADirectory(normalized)
        }

        let rootDev = rootStat.st_dev
        // On an APFS boot volume the sealed system volume and the data volume
        // report the same st_dev, so one allowed device covers both halves.
        let excluded = Self.excludedPaths(forRoot: normalized)

        let root = DirNode(
            name: normalized,
            parent: nil,
            mtime: Double(rootStat.st_mtimespec.tv_sec)
        )

        let stack = WorkStack()
        stack.seed(WorkItem(node: root, path: normalized, dev: rootDev))
        install(stack)

        let visitedDirs = ShardedKeySet()
        _ = visitedDirs.insert(ObjectKey(dev: rootDev, ino: rootStat.st_ino))
        let seenHardLinks = ShardedKeySet()

        let workerCount = min(ProcessInfo.processInfo.activeProcessorCount, 16)
        let group = DispatchGroup()
        let progressTimer = startProgressReporting(since: started)

        for _ in 0..<workerCount {
            group.enter()
            let thread = Thread { [weak self] in
                defer { group.leave() }
                self?.runWorker(
                    stack: stack,
                    allowedDev: rootDev,
                    excludedPaths: excluded,
                    visitedDirs: visitedDirs,
                    seenHardLinks: seenHardLinks
                )
            }
            thread.name = "wizzzee.scan"
            thread.stackSize = 1 << 19
            thread.start()
        }
        group.wait()
        progressTimer.cancel()
        stateLock.withLock { workStack = nil }

        // Asked of the stack, not of the cancel flag: a Stop pressed in the
        // instant a 90-second scan was landing set the flag but found a walk
        // that had already drained, and the finished result was thrown away.
        if stack.wasAbandoned { return .cancelled }

        // Bottom-up aggregation and extension statistics.
        var builder = ExtensionStatsBuilder()
        Self.aggregate(root, into: &builder)
        let (stats, remap) = builder.finish()
        Self.remapExtensionIndices(root, using: remap)

        var fsInfo = statfs()
        var total: UInt64 = 0
        var free: UInt64 = 0
        if statfs(normalized, &fsInfo) == 0 {
            let blockSize = UInt64(fsInfo.f_bsize)
            total = UInt64(fsInfo.f_blocks) * blockSize
            free = UInt64(fsInfo.f_bavail) * blockSize
        }

        return .completed(
            stateLock.withLock {
                ScanResult(
                    root: root,
                    rootPath: normalized,
                    extensionStats: stats,
                    elapsed: Date().timeIntervalSince(started),
                    deniedCount: deniedCount,
                    hardLinkSavings: hardLinkSavings,
                    volumeTotal: total,
                    volumeFree: free,
                    volumeUsed: total > free ? total - free : 0,
                    isSharedContainer: normalized == "/"
                )
            }
        )
    }

    private func startProgressReporting(since started: Date) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
        timer.setEventHandler { [weak self] in
            guard let self, let report = self.onProgress else { return }
            let snapshot = self.stateLock.withLock {
                Progress(
                    items: self.itemsSeen,
                    bytes: self.bytesSeen,
                    currentPath: self.currentPath,
                    elapsed: Date().timeIntervalSince(started)
                )
            }
            report(snapshot)
        }
        timer.resume()
        return timer
    }

    // MARK: - Worker

    private func runWorker(
        stack: WorkStack,
        allowedDev: Int32,
        excludedPaths: Set<String>,
        visitedDirs: ShardedKeySet,
        seenHardLinks: ShardedKeySet
    ) {
        let enumerator = BulkEnumerator()

        // Batched locally, flushed to the shared counters per directory.
        var localItems = 0
        var localBytes: UInt64 = 0
        var localDenied = 0
        var localSavings: UInt64 = 0
        var flushCountdown = 0

        while let item = stack.next() {
            var children: [WorkItem] = []

            let fd = open(item.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if fd < 0 {
                item.node.exclusion = .permissionDenied
                localDenied += 1
                stack.complete(pushing: [])
                continue
            }

            let node = item.node
            var files: [FileEntry] = []

            let err = enumerator.enumerate(fd: fd) { entry in
                if entry.name.isEmpty { return }
                localItems += 1

                if entry.isDir {
                    let child = DirNode(
                        name: entry.name,
                        parent: node,
                        mtime: entry.mtime
                    )
                    node.subdirs.append(child)

                    let childPath = Self.join(item.path, entry.name)
                    var childDev = item.dev

                    if excludedPaths.contains(childPath) {
                        child.exclusion = .alreadyCounted
                        return
                    }
                    if entry.isMountPoint {
                        // getattrlistbulk reports the mount point itself, not
                        // the volume mounted on it; stat resolves the volume so
                        // foreign devices (network shares, other disks) can be
                        // left out of a volume-scoped scan.
                        var st = stat()
                        guard stat(childPath, &st) == 0, st.st_dev == allowedDev
                        else {
                            child.exclusion = .otherVolume
                            return
                        }
                        childDev = st.st_dev
                    }
                    // APFS firmlinks make one directory reachable by two paths
                    // (/Users and /System/Volumes/Data/Users are the same
                    // inode); counting whichever is reached first keeps totals
                    // honest.
                    guard
                        visitedDirs.insert(
                            ObjectKey(dev: childDev, ino: entry.fileID)
                        )
                    else {
                        child.exclusion = .alreadyCounted
                        return
                    }
                    children.append(
                        WorkItem(node: child, path: childPath, dev: childDev)
                    )
                } else {
                    var isDuplicate = false
                    if entry.isHardLinked, entry.isRegularFile {
                        isDuplicate = !seenHardLinks.insert(
                            ObjectKey(dev: item.dev, ino: entry.fileID)
                        )
                        if isDuplicate { localSavings += entry.size }
                    }
                    if !isDuplicate { localBytes += entry.size }
                    files.append(
                        FileEntry(
                            name: entry.name,
                            size: entry.size,
                            alloc: entry.alloc,
                            mtime: entry.mtime,
                            extIndex: -1,
                            isSymlink: entry.isSymlink,
                            isDuplicateLink: isDuplicate,
                            linkCount: entry.linkCount
                        )
                    )
                }
            }
            close(fd)

            // Any non-zero errno means enumeration stopped early, so what was
            // collected is a prefix of the directory rather than all of it.
            // Flagged either way: a folder that yielded 3,000 of its 40,000
            // entries used to be reported as a complete reading, which for a
            // measuring tool is worse than being visibly incomplete.
            if err != 0 {
                node.exclusion =
                    files.isEmpty && node.subdirs.isEmpty
                    ? .permissionDenied : .partiallyRead
                localDenied += 1
            }
            node.files = files

            flushCountdown -= 1
            if flushCountdown <= 0 {
                flushCountdown = 16
                let path = item.path
                stateLock.withLock {
                    itemsSeen += localItems
                    bytesSeen += localBytes
                    deniedCount += localDenied
                    hardLinkSavings += localSavings
                    currentPath = path
                }
                localItems = 0
                localBytes = 0
                localDenied = 0
                localSavings = 0
            }

            stack.complete(pushing: children)
        }

        stateLock.withLock {
            itemsSeen += localItems
            bytesSeen += localBytes
            deniedCount += localDenied
            hardLinkSavings += localSavings
        }
    }

    // MARK: - Aggregation

    /// Sums sizes and counts bottom-up.
    ///
    /// Iterative rather than recursive, defensively. This runs on a
    /// `DispatchQueue.global` thread with a 512 KB stack, and a tree deep enough
    /// to exhaust it would take the app down with `EXC_BAD_ACCESS` and nothing
    /// to explain it.
    ///
    /// No such tree is reachable today: the workers `open` an absolute path per
    /// directory, so `PATH_MAX` caps the depth a scan can walk at roughly 460
    /// levels — measured — which costs well under 100 KB of stack. The bound is
    /// a side effect of how directories are opened rather than anything this
    /// code enforces, so it is not something to rely on; a future traversal
    /// built on `openat` would lift it and bring the crash back.
    ///
    /// Two phases per node: the first visits it and queues its children, the
    /// second folds the finished children into it, which is what the recursive
    /// version got from the call stack.
    private static func aggregate(
        _ root: DirNode,
        into builder: inout ExtensionStatsBuilder
    ) {
        enum Step {
            case visit(DirNode)
            case fold(DirNode)
        }

        var stack: [Step] = [.visit(root)]
        while let step = stack.popLast() {
            switch step {
            case .visit(let node):
                var size: UInt64 = 0
                var alloc: UInt64 = 0
                for i in node.files.indices {
                    let file = node.files[i]
                    let index = builder.index(forFileNamed: file.name)
                    node.files[i].extIndex = Int32(index)
                    if file.isDuplicateLink {
                        builder.add(index, size: 0, alloc: 0)
                    } else {
                        size += file.size
                        alloc += file.alloc
                        builder.add(index, size: file.size, alloc: file.alloc)
                    }
                }
                // Seeded with this node's own files; the fold below adds the
                // subtree totals once every child has been through both phases.
                node.totalSize = size
                node.totalAlloc = alloc
                node.totalFiles = node.files.count
                node.totalDirs = 0

                stack.append(.fold(node))
                for sub in node.subdirs { stack.append(.visit(sub)) }

            case .fold(let node):
                for sub in node.subdirs {
                    node.totalSize += sub.totalSize
                    node.totalAlloc += sub.totalAlloc
                    node.totalFiles += sub.totalFiles
                    node.totalDirs += sub.totalDirs + 1
                }
            }
        }
    }

    /// Rewrites each file's `extIndex` from insertion order to the final
    /// size-sorted order used by `ScanResult.extensionStats`. Iterative for the
    /// same reason as `aggregate`.
    private static func remapExtensionIndices(_ root: DirNode, using remap: [Int32]) {
        var stack: [DirNode] = [root]
        while let node = stack.popLast() {
            for i in node.files.indices {
                let old = Int(node.files[i].extIndex)
                if old >= 0 && old < remap.count {
                    node.files[i].extIndex = remap[old]
                }
            }
            stack.append(contentsOf: node.subdirs)
        }
    }

    // MARK: - Paths

    /// Resolves a scan root to a real, symlink-free absolute path.
    ///
    /// `realpath(3)` rather than `standardizingPath` because the workers open
    /// directories with `O_NOFOLLOW` — the right call for children, where a
    /// symlink would otherwise pull another subtree into the totals, but it
    /// refuses the root whenever its last component is a link. `/tmp`, `/etc` and
    /// `/var` are all links, and `standardizingPath` *creates* the problem for
    /// ordinary roots by rewriting `/private/tmp` back to `/tmp`. The scan then
    /// reported "complete" at zero bytes with the root marked unreadable.
    ///
    /// Resolving here also means the paths handed to the delete actions name the
    /// real files rather than running back through a link.
    static func normalize(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if !path.isEmpty, realpath(path, &buffer) != nil {
            let resolved = String(cString: buffer)
            if !resolved.isEmpty { return resolved }
        }
        // Nothing there to resolve — a nonexistent root has to survive to the
        // `stat` below, which is what reports it as unscannable.
        var result = (path as NSString).standardizingPath
        if result.isEmpty { result = "/" }
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// Paths to leave out of a scan rooted at `root`.
    ///
    /// On a boot volume the entire data volume is surfaced under `/` through
    /// firmlinks, so descending into `/System/Volumes/Data` as well would double
    /// every user file. Excluding it keeps the familiar `/Users`, `/Applications`
    /// layout rather than whichever path a worker happened to reach first.
    static func excludedPaths(forRoot root: String) -> Set<String> {
        guard root == "/" else { return [] }
        return [
            "/System/Volumes/Data",
            // The sealed system snapshot remounted during updates — the same
            // system files again.
            "/System/Volumes/Update/mnt1",
        ]
    }
}

/// Accumulates per-extension totals during aggregation.
private struct ExtensionStatsBuilder {
    private var extensions: [String] = []
    private var sizes: [UInt64] = []
    private var allocs: [UInt64] = []
    private var counts: [Int] = []
    private var lookup: [String: Int] = [:]

    // Files in one directory very often share an extension; memoizing the last
    // one avoids a dictionary probe per file.
    private var lastExt: String = "\u{0}"
    private var lastIndex: Int = -1

    mutating func index(forFileNamed name: String) -> Int {
        let ext = Self.extension(of: name)
        if ext == lastExt { return lastIndex }
        let index: Int
        if let existing = lookup[ext] {
            index = existing
        } else {
            index = extensions.count
            extensions.append(ext)
            sizes.append(0)
            allocs.append(0)
            counts.append(0)
            lookup[ext] = index
        }
        lastExt = ext
        lastIndex = index
        return index
    }

    mutating func add(_ index: Int, size: UInt64, alloc: UInt64) {
        sizes[index] += size
        allocs[index] += alloc
        counts[index] += 1
    }

    /// Returns the stats sorted by descending size, plus a map from insertion
    /// index to sorted index.
    mutating func finish() -> ([ExtensionStat], [Int32]) {
        var stats = (0..<extensions.count).map { i in
            ExtensionStat(
                ext: extensions[i],
                size: sizes[i],
                alloc: allocs[i],
                count: counts[i]
            )
        }
        let order = (0..<stats.count).sorted { stats[$0].size > stats[$1].size }
        var remap = [Int32](repeating: 0, count: stats.count)
        var sorted: [ExtensionStat] = []
        sorted.reserveCapacity(stats.count)
        for (newIndex, oldIndex) in order.enumerated() {
            remap[oldIndex] = Int32(newIndex)
            var stat = stats[oldIndex]
            stat.colorIndex = newIndex
            sorted.append(stat)
        }
        stats = sorted
        return (stats, remap)
    }

    /// Lowercased extension without the dot, or "" if there isn't a meaningful
    /// one. Dotfiles like `.zshrc` count as having no extension, matching how
    /// macOS treats them.
    static func `extension`(of name: String) -> String {
        let bytes = name.utf8
        guard bytes.count > 1 else { return "" }
        var dotOffset = -1
        var offset = 0
        for byte in bytes {
            if byte == UInt8(ascii: ".") { dotOffset = offset }
            offset += 1
        }
        // No dot, a leading dot (dotfile), or a trailing dot.
        guard dotOffset > 0, dotOffset < bytes.count - 1 else { return "" }
        let length = bytes.count - dotOffset - 1
        guard length <= 16 else { return "" }

        let start = name.utf8.index(name.utf8.startIndex, offsetBy: dotOffset + 1)
        var result = String(name[start...])
        // Extensions are compared case-insensitively; normalize once here.
        if result.contains(where: { $0.isUppercase }) { result = result.lowercased() }
        return result
    }
}
