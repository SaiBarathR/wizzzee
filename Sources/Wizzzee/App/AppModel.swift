import AppKit
import Combine
import SwiftUI

/// Which size a view should report: the logical file size, or the space it
/// actually occupies on disk. Sparse files and tiny files diverge sharply
/// between the two, so every size-bearing view honours this.
enum SizeMetric: String, CaseIterable, Hashable {
    case logical = "Size"
    case allocated = "Allocated"
}

/// One row of the Tree View table.
struct TreeRow: Identifiable, Hashable {
    let ref: NodeRef
    let depth: Int
    let isExpandable: Bool
    let isExpanded: Bool
    /// True for the last child of its parent, used to draw the tree elbow.
    let isLastSibling: Bool

    var id: NodeRef { ref }
}

/// Sorts Tree View rows. Sorting is applied *within* each parent rather than
/// across the flattened list, so the hierarchy stays intact — the same way
/// WizTree behaves.
struct TreeSort: SortComparator, Hashable {
    typealias Compared = TreeRow

    enum Key: Hashable {
        case name, percent, size, allocated, items, files, folders, modified
    }

    var key: Key
    var order: SortOrder

    init(_ key: Key, order: SortOrder = .reverse) {
        self.key = key
        self.order = order
    }

    func compare(_ lhs: TreeRow, _ rhs: TreeRow) -> ComparisonResult {
        compare(lhs.ref, rhs.ref)
    }

    func compare(_ lhs: NodeRef, _ rhs: NodeRef) -> ComparisonResult {
        let result: ComparisonResult
        switch key {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name)
        case .size, .percent:
            result = numeric(lhs.size, rhs.size)
        case .allocated:
            result = numeric(lhs.alloc, rhs.alloc)
        case .items:
            result = numeric(itemCount(lhs), itemCount(rhs))
        case .files:
            result = numeric(fileCount(lhs), fileCount(rhs))
        case .folders:
            result = numeric(folderCount(lhs), folderCount(rhs))
        case .modified:
            result = numeric(lhs.mtime, rhs.mtime)
        }
        return order == .forward ? result : result.reversed
    }

    private func numeric<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    private func itemCount(_ ref: NodeRef) -> Int {
        ref.isDirectory ? ref.dir.totalItems : 0
    }
    private func fileCount(_ ref: NodeRef) -> Int {
        ref.isDirectory ? ref.dir.totalFiles : 0
    }
    private func folderCount(_ ref: NodeRef) -> Int {
        ref.isDirectory ? ref.dir.totalDirs : 0
    }
}

extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}

/// One row of the File View table. Values are stored rather than computed so the
/// table can sort with plain `KeyPathComparator`s.
struct FileRow: Identifiable, Hashable {
    let ref: NodeRef
    let name: String
    let directory: String
    let size: UInt64
    let alloc: UInt64
    let mtime: Double
    let fractionOfRoot: Double

    var id: NodeRef { ref }
}

enum MainTab: String, CaseIterable {
    case tree = "Tree View"
    case files = "File View"
    case about = "About"

    /// The name `--tab` accepts. The display titles make poor flag values —
    /// prefix-matching "File View" means the obvious `--tab files` misses and
    /// silently falls back to the tree.
    var cliName: String {
        switch self {
        case .tree: return "tree"
        case .files: return "files"
        case .about: return "about"
        }
    }

    /// Matches a `--tab` argument against either the short name or the display
    /// title, by prefix, so `files`, `file`, and `file view` all land here.
    init?(cliName: String) {
        let key = cliName.lowercased()
        guard !key.isEmpty,
            let match = MainTab.allCases.first(where: {
                $0.cliName.hasPrefix(key) || $0.rawValue.lowercased().hasPrefix(key)
            })
        else { return nil }
        self = match
    }
}

/// Central app state: owns the current scan, the derived table rows, and the
/// treemap's zoom and selection.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case complete
        case cancelled
        case failed(String)
    }

    // Scan state
    @Published var phase: Phase = .idle
    @Published var progress = ScanEngine.Progress()
    @Published private(set) var result: ScanResult?

    // Targets
    @Published var volumes: [VolumeInfo] = []
    @Published var selectedVolumePath: String = "/"
    /// Set when the user picks an arbitrary folder instead of a whole volume.
    @Published var customFolder: String?

    // View state
    @Published var tab: MainTab = .tree
    /// A set rather than one item, so the tables get macOS's native ⌘-click and
    /// ⇧-arrow multi-select and the destructive actions can work on a batch.
    @Published var selection: Set<NodeRef> = []
    /// Defaults to space actually occupied. Logical size is badly misleading on
    /// macOS, where sparse container and VM images routinely report hundreds of
    /// gigabytes they don't occupy — and reclaimable space is the whole point.
    @Published var sizeMetric: SizeMetric = .allocated
    @Published var hasFullDiskAccess = true
    @Published var dismissedAccessPrompt = false

    // Tree View
    @Published private(set) var treeRows: [TreeRow] = []
    @Published var treeSort: [TreeSort] = [TreeSort(.allocated)]
    /// Keyed on `DirNode.id` rather than `ObjectIdentifier`, which is the
    /// object's address and can be handed to a different node once a delete has
    /// freed the one it belonged to.
    private var expanded: Set<UInt64> = []

    // File View
    @Published private(set) var fileRows: [FileRow] = []
    @Published var fileQuery: String = ""
    @Published var fileSort: [KeyPathComparator<FileRow>] = [
        KeyPathComparator(\FileRow.alloc, order: .reverse)
    ]
    @Published var isFilteringFiles = false

    // Treemap
    /// Whether Tree View shows the treemap under the table. Hiding it hands the
    /// whole tab to the table, for the times a long folder list is what you're
    /// reading; the zoom and the map's own root are left alone so showing it
    /// again picks up exactly where it left off.
    ///
    /// Assigning this does not persist — `toggleTreemap()` is what records the
    /// user's choice, so the headless renderer can set a layout for one image
    /// without rewriting a real preference.
    @Published var showsTreemap = Preferences.showsTreemap
    @Published var treemapRoot: DirNode?
    @Published var hoveredRef: NodeRef?
    /// Incremented whenever the tree is structurally changed, so the treemap
    /// knows to lay out again even though its root object is unchanged.
    @Published var treeRevision = 0

    // Errors surfaced as a sheet
    @Published var actionError: String?
    @Published var actionErrorDetail: String?
    /// Non-empty while awaiting confirmation of an irreversible delete.
    @Published var permanentDeleteTargets: Set<NodeRef> = []

    private var engine: ScanEngine?
    private var fileFilterWork: DispatchWorkItem?
    /// Every background read of the scan tree runs here, so a delete can make
    /// itself exclusive by syncing against it. Serial by design: two concurrent
    /// walks would buy nothing, and the barrier below depends on the ordering.
    private let treeQueue = DispatchQueue(
        label: "com.wizzzee.tree-read",
        qos: .userInitiated
    )

    init() {
        volumes = VolumeInfo.current()
        selectedVolumePath = volumes.first?.path ?? "/"
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    /// The one selected item, when exactly one is selected. The treemap
    /// highlight and the status line describe a single thing, so they ask for
    /// this rather than picking arbitrarily out of a set.
    var primarySelection: NodeRef? { selection.count == 1 ? selection.first : nil }

    // MARK: - Scan target

    var scanTargetPath: String { customFolder ?? selectedVolumePath }

    var scanTargetLabel: String {
        if let folder = customFolder { return folder }
        return volumes.first { $0.path == selectedVolumePath }?.menuTitle
            ?? selectedVolumePath
    }

    /// Capacity of the volume the current target lives on.
    var targetCapacity: (total: UInt64, free: UInt64) {
        if let result { return (result.volumeTotal, result.volumeFree) }
        return VolumeInfo.capacity(of: scanTargetPath)
    }

    func refreshVolumes() {
        volumes = VolumeInfo.current()
        if !volumes.contains(where: { $0.path == selectedVolumePath }) {
            selectedVolumePath = volumes.first?.path ?? "/"
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customFolder = url.path
        startScan()
    }

    // MARK: - Scanning

    func startScan() {
        guard phase != .scanning else { return }
        let path = scanTargetPath

        result = nil
        treeRows = []
        // Dropped along with the rows it would have replaced: a walk still going
        // describes the scan being thrown away.
        fileFilterWork?.cancel()
        fileFilterWork = nil
        isFilteringFiles = false
        fileRows = []
        selection = []
        treemapRoot = nil
        expanded = []
        progress = ScanEngine.Progress()
        phase = .scanning
        hasFullDiskAccess = FullDiskAccess.isGranted()

        let engine = ScanEngine()
        self.engine = engine
        engine.onProgress = { [weak self] snapshot in
            DispatchQueue.main.async {
                // Cancelling the timer doesn't wait for a handler already
                // running, so a tick can still be on its way here after the
                // scan has ended. Applying it then would leave a mid-scan item
                // count and path sitting behind a finished scan.
                guard let self, self.phase == .scanning else { return }
                self.progress = snapshot
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = engine.scanSynchronously(rootPath: path)
            DispatchQueue.main.async { self?.scanFinished(outcome) }
        }
    }

    func cancelScan() {
        engine?.cancel()
    }

    private func scanFinished(_ outcome: ScanEngine.Outcome) {
        engine = nil
        // A late progress tick can still be in flight on the main queue behind
        // this; leaving a mid-scan snapshot behind would have anything reading
        // `progress` outside `.scanning` describing a scan that has ended.
        progress = ScanEngine.Progress()

        let scanned: ScanResult
        switch outcome {
        case .completed(let result):
            scanned = result
        case .cancelled:
            phase = .cancelled
            return
        case .notADirectory(let path):
            phase = .failed("“\(path)” isn’t a folder.")
            return
        case .unreadable(let path, let code):
            phase = .failed(Self.unreadableMessage(path: path, errno: code))
            return
        }

        result = scanned
        phase = .complete
        treemapRoot = scanned.root
        selection = [NodeRef(scanned.root)]
        // Open the root so the biggest folders are visible immediately.
        expanded = [scanned.root.id]
        rebuildTreeRows()
        refreshFileRows(immediately: true)
    }

    /// Says which of the three ways a root can be unreadable happened. "Couldn’t
    /// scan it" covered all of them equally and left the most common cause —
    /// Full Disk Access, which the app has a whole banner for — unnamed.
    private static func unreadableMessage(path: String, errno code: Int32) -> String {
        switch code {
        case ENOENT, ENOTDIR:
            return "There’s nothing at “\(path)”."
        case EACCES, EPERM:
            return "Wizzzee isn’t allowed to read “\(path)”. "
                + "Granting Full Disk Access in System Settings usually fixes this."
        default:
            return "Couldn’t scan “\(path)” (\(String(cString: strerror(code))))."
        }
    }

    // MARK: - Tree View rows

    func isExpanded(_ dir: DirNode) -> Bool {
        expanded.contains(dir.id)
    }

    func toggleExpansion(_ dir: DirNode) {
        if expanded.contains(dir.id) {
            expanded.remove(dir.id)
        } else {
            expanded.insert(dir.id)
        }
        rebuildTreeRows()
    }

    func setExpanded(_ dir: DirNode, _ isOpen: Bool) {
        if isOpen { expanded.insert(dir.id) } else { expanded.remove(dir.id) }
        rebuildTreeRows()
    }

    /// Expands every ancestor of `ref` and scrolls it into the row list, so
    /// clicking a treemap tile reveals the matching row.
    func revealInTree(_ ref: NodeRef) {
        var chain: [DirNode] = []
        var node: DirNode? = ref.isDirectory ? ref.dir.parent : ref.dir
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        for dir in chain { expanded.insert(dir.id) }
        selection = [ref]
        rebuildTreeRows()
    }

    func rebuildTreeRows() {
        guard let root = result?.root else {
            treeRows = []
            return
        }
        let sort = treeSort.first ?? TreeSort(.size)
        var rows: [TreeRow] = []
        rows.reserveCapacity(min(4096, root.subdirs.count * 4 + 16))
        appendRows(for: root, depth: 0, isLast: true, sort: sort, into: &rows)
        treeRows = rows
    }

    private func appendRows(
        for dir: DirNode,
        depth: Int,
        isLast: Bool,
        sort: TreeSort,
        into rows: inout [TreeRow]
    ) {
        let isOpen = isExpanded(dir)
        let hasChildren = !dir.subdirs.isEmpty || !dir.files.isEmpty
        rows.append(
            TreeRow(
                ref: NodeRef(dir),
                depth: depth,
                isExpandable: hasChildren,
                isExpanded: isOpen,
                isLastSibling: isLast
            )
        )
        guard isOpen else { return }

        // Folders and files are ranked together, matching WizTree.
        var children: [NodeRef] = []
        children.reserveCapacity(dir.subdirs.count + dir.files.count)
        for sub in dir.subdirs { children.append(NodeRef(sub)) }
        for index in dir.files.indices {
            children.append(NodeRef(dir: dir, fileIndex: index))
        }
        children.sort { sort.compare($0, $1) == .orderedAscending }

        for (offset, child) in children.enumerated() {
            let last = offset == children.count - 1
            if child.isDirectory {
                appendRows(
                    for: child.dir,
                    depth: depth + 1,
                    isLast: last,
                    sort: sort,
                    into: &rows
                )
            } else {
                rows.append(
                    TreeRow(
                        ref: child,
                        depth: depth + 1,
                        isExpandable: false,
                        isExpanded: false,
                        isLastSibling: last
                    )
                )
            }
        }
    }

    // MARK: - File View rows

    /// Recomputes the largest-files list. Filtering walks every file in the
    /// tree, so it runs off the main thread and coalesces keystrokes.
    func refreshFileRows(immediately: Bool = false) {
        fileFilterWork?.cancel()
        guard let result else {
            fileRows = []
            return
        }
        let query = fileQuery
        let metric = sizeMetric
        // Both captured so a walk that was already under way when the tree
        // changed under it can be thrown away. Its rows describe the tree as it
        // was: after a delete their file indices no longer name the same files,
        // and after a rescan they belong to a scan that has been discarded.
        let revision = treeRevision
        let source = result
        isFilteringFiles = true

        let work = DispatchWorkItem { [weak self] in
            let refs = result.largestFiles(
                matching: query,
                limit: 1000,
                metric: metric
            )
            let rootTotal = max(
                metric == .logical ? result.root.totalSize : result.root.totalAlloc,
                1
            )
            let rows = refs.map { ref -> FileRow in
                let file = ref.dir.files[Int(ref.fileIndex)]
                let weight = metric == .logical ? file.size : file.alloc
                return FileRow(
                    ref: ref,
                    name: file.name,
                    directory: ref.dir.path,
                    size: file.size,
                    alloc: file.alloc,
                    mtime: file.mtime,
                    fractionOfRoot: Double(weight) / Double(rootTotal)
                )
            }
            DispatchQueue.main.async {
                guard let self, self.fileQuery == query,
                    self.treeRevision == revision, self.result === source
                else { return }
                self.fileRows = rows.sorted(using: self.fileSort)
                self.isFilteringFiles = false
            }
        }
        fileFilterWork = work
        treeQueue.asyncAfter(
            deadline: .now() + (immediately ? 0 : 0.25),
            execute: work
        )
    }

    func resortFileRows() {
        fileRows = fileRows.sorted(using: fileSort)
    }

    // MARK: - Treemap visibility

    /// Shows or hides the treemap and remembers which, so the layout a user
    /// settled on is the one they get next launch.
    func toggleTreemap() {
        showsTreemap.toggle()
        Preferences.showsTreemap = showsTreemap
    }

    // MARK: - Treemap zoom

    var canZoomOut: Bool { treemapRoot?.parent != nil }

    func zoom(into dir: DirNode) {
        guard !dir.subdirs.isEmpty || !dir.files.isEmpty else { return }
        treemapRoot = dir
    }

    func zoomOut() {
        if let parent = treemapRoot?.parent { treemapRoot = parent }
    }

    func resetZoom() {
        treemapRoot = result?.root
    }

    // MARK: - Destructive actions

    func moveToTrash(_ ref: NodeRef) { moveToTrash([ref]) }

    func moveToTrash(_ refs: Set<NodeRef>) {
        performBatch(on: refs) { try FileActions.moveToTrash($0) }
    }

    func deletePermanently(_ ref: NodeRef) { deletePermanently([ref]) }

    func deletePermanently(_ refs: Set<NodeRef>) {
        performBatch(on: refs) { try FileActions.deletePermanently($0) }
    }

    /// `refs` with anything already covered by a selected ancestor dropped.
    /// Deleting a folder takes its contents with it, so a nested selection would
    /// otherwise be deleted twice — the second attempt failing on a path that no
    /// longer exists, and its bytes being subtracted from the totals twice over.
    func distinctTargets(_ refs: Set<NodeRef>) -> [NodeRef] {
        let selectedDirs = Set(
            refs.lazy.filter(\.isDirectory).map { ObjectIdentifier($0.dir) }
        )
        // A reference whose folder has since been renumbered names either
        // nothing or the wrong file, so it is dropped rather than acted on.
        return refs.filter { !$0.isStale }.filter { ref in
            // A file's containing directory counts as an ancestor; a directory's
            // does not, or every folder would exclude itself.
            var ancestor: DirNode? = ref.isDirectory ? ref.dir.parent : ref.dir
            while let step = ancestor {
                if selectedDirs.contains(ObjectIdentifier(step)) { return false }
                ancestor = step.parent
            }
            return true
        }
    }

    /// Why `ref` can't be removed, or nil when it can.
    ///
    /// The scan root is checked here as well as in `FileActions`, because only
    /// the model knows what the scan was rooted at: a scan of `~/Projects` makes
    /// that folder the root, and it is selected the instant the scan lands.
    func deletionRefusal(for ref: NodeRef) -> FileActions.ActionError? {
        if ref.isDirectory, ref.dir.isRoot {
            return .undeletableRoot(ref.path)
        }
        if FileActions.isUndeletableRoot(ref.path) {
            return .undeletableRoot(ref.path)
        }
        if FileActions.isSystemProtected(ref.path) {
            return .systemProtected(ref.path)
        }
        return nil
    }

    /// True when anything in `refs` may not be removed, so the menu can offer an
    /// explanation in place of actions that would only fail.
    func isDeletionRefused(_ refs: Set<NodeRef>) -> Bool {
        refs.contains { deletionRefusal(for: $0) != nil }
    }

    /// Space deleting `refs` would actually reclaim: a folder's contents counted
    /// once rather than once per nested selection, measured with the metric on
    /// show, and hard-linked files counted as freeing nothing.
    ///
    /// This number is the last thing a user reads before an irreversible delete,
    /// so it errs low. Counting logical size while the whole UI defaults to
    /// allocated promised 200 GB back from a sparse image that occupies 8 GB;
    /// counting a hard link's bytes promised space that deleting one of its
    /// names never frees.
    func reclaimableSize(_ refs: Set<NodeRef>) -> UInt64 {
        distinctTargets(refs).reduce(0) { total, ref in
            if let file = ref.file, file.sharesStorage { return total }
            return total + (sizeMetric == .logical ? ref.size : ref.alloc)
        }
    }

    /// Whether any target's bytes live under more than one name, which makes the
    /// reclaimable figure a ceiling rather than a promise.
    func selectionSharesStorage(_ refs: Set<NodeRef>) -> Bool {
        distinctTargets(refs).contains { $0.file?.sharesStorage == true }
    }

    private func performBatch(
        on refs: Set<NodeRef>,
        _ body: (String) throws -> Void
    ) {
        // Paths are resolved up front: removing one file renumbers its siblings,
        // so a NodeRef read after the first deletion would name the wrong path.
        let targets = distinctTargets(refs).map { (ref: $0, path: $0.path) }
        guard !targets.isEmpty else { return }

        let refusals = targets.compactMap { deletionRefusal(for: $0.ref) }
        let allowed = targets.filter { deletionRefusal(for: $0.ref) == nil }
        guard !allowed.isEmpty else {
            // Nothing worth attempting: the refusal itself is the only useful
            // thing to say, and it explains why the space can't be reclaimed.
            let error = refusals[0]
            actionError = error.errorDescription
            actionErrorDetail = error.recoverySuggestion
            return
        }

        var deleted: [NodeRef] = []
        var failures: [(title: String, detail: String)] = []
        for target in allowed {
            do {
                try body(target.path)
                deleted.append(target.ref)
            } catch let error as FileActions.ActionError {
                failures.append(
                    (
                        error.errorDescription ?? "Couldn’t delete an item",
                        error.recoverySuggestion ?? ""
                    )
                )
            } catch {
                let name = (target.path as NSString).lastPathComponent
                failures.append(
                    ("Couldn’t delete “\(name)”", error.localizedDescription)
                )
            }
        }

        // Successes are applied even when part of the batch failed, so the tree
        // never claims space that is already gone.
        detach(deleted)
        report(failures: failures, refusals: refusals, attempted: targets.count)
    }

    /// Surfaces the first failure — a wall of alerts helps nobody — but says how
    /// many items were affected, so a partial result isn't taken for a complete
    /// one.
    private func report(
        failures: [(title: String, detail: String)],
        refusals: [FileActions.ActionError],
        attempted: Int
    ) {
        let unfinished = failures.count + refusals.count
        guard unfinished > 0 else { return }
        if unfinished == 1 {
            let only =
                failures.first
                ?? (
                    refusals[0].errorDescription ?? "Couldn’t remove an item",
                    refusals[0].recoverySuggestion ?? ""
                )
            actionError = only.title
            actionErrorDetail = only.detail.isEmpty ? nil : only.detail
            return
        }
        actionError = "\(ByteFormat.count(unfinished)) of "
            + "\(ByteFormat.count(attempted)) items couldn’t be removed"
        // The refusals carry their own explanation — one names the sealed system
        // volume, the other a volume or home root — so the first of each kind is
        // quoted rather than assuming they were all the same thing.
        var detail: [String] = []
        var seen = Set<String>()
        for reason in refusals {
            guard let suggestion = reason.recoverySuggestion,
                seen.insert(suggestion).inserted
            else { continue }
            detail.append(suggestion)
        }
        if let first = failures.first {
            detail.append("\(first.title). \(first.detail)")
        }
        actionErrorDetail = detail.joined(separator: "\n\n")
    }

    /// Drops deleted items from the tree and walks the size change up to the
    /// root, so the whole UI updates without rescanning.
    private func detach(_ refs: [NodeRef]) {
        guard !refs.isEmpty else { return }

        // The File View walk reads this tree on `treeQueue`. Drop any walk that
        // hasn't started, then wait out one that has, so nothing is traversing
        // the nodes about to be unlinked.
        fileFilterWork?.cancel()
        fileFilterWork = nil
        treeQueue.sync {}

        // Files come off first, highest index first: removing an entry shifts
        // every sibling after it, so any other order unlinks the wrong ones.
        // Sorting the whole batch at once is safe because entries in different
        // folders can't disturb each other's indices.
        let files = refs.lazy.filter { !$0.isDirectory }
            .sorted { $0.fileIndex > $1.fileIndex }
        for ref in files { detachFile(ref) }
        for ref in refs where ref.isDirectory { detachDirectory(ref.dir) }

        // Removing a file shifts the indices of its siblings, invalidating any
        // NodeRef held elsewhere, so all derived rows are rebuilt and the
        // selection is dropped.
        selection = []
        hoveredRef = nil
        treeRevision += 1
        // Dropped here and now, not when the walk below returns with fresh ones.
        // A row names its file by index, so the rows already on screen name
        // whatever shifted into their place — and double-clicking one, or
        // deleting it, would act on that instead. They also hold a folder
        // without holding its ancestors, so a row inside a deleted subtree
        // outlives its own parent chain.
        fileRows = []
        rebuildTreeRows()
        refreshFileRows(immediately: true)
    }

    private func detachFile(_ ref: NodeRef) {
        let dir = ref.dir
        let index = Int(ref.fileIndex)
        guard index < dir.files.count else { return }
        let file = dir.files[index]
        subtract(
            size: file.isDuplicateLink ? 0 : file.size,
            alloc: file.isDuplicateLink ? 0 : file.alloc,
            files: 1,
            dirs: 0,
            from: dir
        )
        dir.files.remove(at: index)
    }

    private func detachDirectory(_ node: DirNode) {
        guard let parent = node.parent else { return }
        subtract(
            size: node.totalSize,
            alloc: node.totalAlloc,
            files: node.totalFiles,
            dirs: node.totalDirs + 1,
            from: parent
        )
        parent.subdirs.removeAll { $0 === node }
        if treemapRoot === node || isDescendant(treemapRoot, of: node) {
            treemapRoot = parent
        }
    }

    private func isDescendant(_ node: DirNode?, of ancestor: DirNode) -> Bool {
        var current = node?.parent
        while let step = current {
            if step === ancestor { return true }
            current = step.parent
        }
        return false
    }

    private func subtract(
        size: UInt64,
        alloc: UInt64,
        files: Int,
        dirs: Int,
        from node: DirNode
    ) {
        var current: DirNode? = node
        while let step = current {
            step.totalSize -= min(step.totalSize, size)
            step.totalAlloc -= min(step.totalAlloc, alloc)
            step.totalFiles = max(0, step.totalFiles - files)
            step.totalDirs = max(0, step.totalDirs - dirs)
            current = step.parent
        }
    }
}
