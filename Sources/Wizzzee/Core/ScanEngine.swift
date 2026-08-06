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
    private var shards: [Set<ObjectKey>]
    private let locks: [UnfairLock]

    init() {
        shards = Array(repeating: Set<ObjectKey>(), count: Self.shardCount)
        locks = (0..<Self.shardCount).map { _ in UnfairLock() }
    }

    /// Inserts `key`, returning true if it was not already present.
    func insert(_ key: ObjectKey) -> Bool {
        // Taken unsigned rather than via abs(), which traps on Int.min.
        let shard = Int(UInt(bitPattern: key.ino.hashValue) % UInt(Self.shardCount))
        return locks[shard].withLock { shards[shard].insert(key).inserted }
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

    /// Whether `cancel()` was called. A nil result from `scanSynchronously`
    /// means either this or an unreadable root, and callers need to tell the
    /// two apart to report the right thing.
    var wasCancelled: Bool { checkCancelled }

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
            stopped = true
            items.removeAll()
            condition.broadcast()
            condition.unlock()
        }
    }

    // MARK: - Entry points

    /// Runs a scan on the calling thread. Returns nil if cancelled.
    func scanSynchronously(rootPath: String) -> ScanResult? {
        let started = Date()
        let normalized = Self.normalize(rootPath)

        var rootStat = stat()
        guard stat(normalized, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR
        else { return nil }

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

        if checkCancelled { return nil }

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

        return stateLock.withLock {
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
                            isDuplicateLink: isDuplicate
                        )
                    )
                }
            }
            close(fd)

            if err != 0 && files.isEmpty && node.subdirs.isEmpty {
                node.exclusion = .permissionDenied
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

    /// Sums sizes and counts bottom-up. Recursion depth is the tree's depth, not
    /// its size, so it stays shallow even for millions of files.
    private static func aggregate(
        _ node: DirNode,
        into builder: inout ExtensionStatsBuilder
    ) {
        var size: UInt64 = 0
        var alloc: UInt64 = 0
        var fileCount = 0
        var dirCount = 0

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
            fileCount += 1
        }

        for sub in node.subdirs {
            aggregate(sub, into: &builder)
            size += sub.totalSize
            alloc += sub.totalAlloc
            fileCount += sub.totalFiles
            dirCount += sub.totalDirs + 1
        }

        node.totalSize = size
        node.totalAlloc = alloc
        node.totalFiles = fileCount
        node.totalDirs = dirCount
    }

    /// Rewrites each file's `extIndex` from insertion order to the final
    /// size-sorted order used by `ScanResult.extensionStats`.
    private static func remapExtensionIndices(_ node: DirNode, using remap: [Int32]) {
        for i in node.files.indices {
            let old = Int(node.files[i].extIndex)
            if old >= 0 && old < remap.count {
                node.files[i].extIndex = remap[old]
            }
        }
        for sub in node.subdirs { remapExtensionIndices(sub, using: remap) }
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
