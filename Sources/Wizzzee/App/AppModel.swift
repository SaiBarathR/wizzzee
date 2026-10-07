import AppKit
import Combine
import SwiftUI

/// Which size a view should report: the logical file size, or the space it
/// actually occupies on disk. Sparse files and tiny files diverge sharply
/// between the two, so every size-bearing view honours this.
enum SizeMetric: String, CaseIterable, Hashable {
    case logical = "Size"
    case allocated = "Allocated"

    /// How a column holding `measure` is drawn while this one is on show: at
    /// full strength if it is the one, set back if it is the other.
    func emphasis(of measure: SizeMetric) -> HierarchicalShapeStyle {
        self == measure ? .primary : .secondary
    }

    /// The Tree View order that ranks rows by this measure.
    var sortKey: TreeSort.Key { self == .logical ? .size : .allocated }

    /// Where a File View row keeps this measure.
    var fileRowKeyPath: KeyPath<FileRow, UInt64> {
        self == .logical ? \FileRow.size : \FileRow.alloc
    }
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
        // `.percent` never gets this far in practice: `rebuildTreeRows` turns
        // it into whichever of the two size keys the column is drawn with.
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
    @Published var sizeMetric: SizeMetric = .allocated {
        didSet {
            if sizeMetric != oldValue { sizeMetricChanged(from: oldValue) }
        }
    }
    @Published var hasFullDiskAccess = true
    @Published var dismissedAccessPrompt = false
    /// True while the File View's filter has the keyboard.
    ///
    /// ⌘⌫ in a text field deletes back to the start of the line, and a menu
    /// item's key is matched before the field is offered it. So the delete
    /// keys stand down for as long as this is set, or clearing a filter would
    /// send whatever was selected behind it to the Trash.
    @Published var isEditingFilter = false

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
    /// The item the treemap is drawing its selection outline round, as the
    /// map last reported it. See `TreemapNSView.onOutline`.
    @Published var treemapOutline: NodeRef?
    /// Incremented whenever the tree is structurally changed, so the treemap
    /// knows to lay out again even though its root object is unchanged.
    @Published var treeRevision = 0

    // Errors surfaced as a sheet
    @Published var actionError: String?
    @Published var actionErrorDetail: String?
    /// Non-empty while awaiting confirmation of an irreversible delete.
    @Published var permanentDeleteTargets: Set<NodeRef> = []

    /// How far a running delete batch has got. Nil when none is running.
    @Published private(set) var deleteProgress: DeleteProgress?

    /// Progress of a delete batch, counted in top-level targets.
    ///
    /// Not in bytes: `FileManager.removeItem` recurses into a directory itself
    /// and reports nothing on the way, so the honest unit is the item, and a
    /// single huge tree is one long step.
    struct DeleteProgress: Equatable {
        var done: Int
        var total: Int
        /// The item about to be removed, for the status line.
        var currentName: String

        var fraction: Double {
            total > 0 ? Double(done) / Double(total) : 0
        }
    }

    /// What a folder holds that deleting it would not free.
    private struct SharedStorage {
        var size: UInt64 = 0
        var alloc: UInt64 = 0
        /// Names under the folder whose data has another name outside it.
        var names = 0
    }

    /// `sharedStorage(under:)` for each folder asked about, keyed on
    /// `DirNode.id`.
    ///
    /// `reclaimableSize` is read from view bodies — the header and the status
    /// line re-evaluate on every hover — and answering it for a folder means
    /// looking at every file underneath. The answer can only change when the
    /// tree does, so it is worked out once per folder and thrown away by a
    /// delete or a rescan.
    private var sharedStorageCache: [UInt64: SharedStorage] = [:]

    /// The scanned volume's capacity as read after the last delete batch, or
    /// nil when none has run since the scan.
    ///
    /// A scan records these figures once. A delete then moves every total in
    /// the tree and, when it really removes something, the free space on the
    /// volume — and the header went on quoting "Volume Free" from before it
    /// until the next full scan.
    @Published private var capacityAfterDelete: (total: UInt64, free: UInt64)?

    /// How the scanned volume's capacity is read back after a delete.
    ///
    /// A property so the self-test can supply readings of its own. Asserting on
    /// the real volume's free space would depend on everything else using the
    /// disk at that moment, and on when the filesystem gives the space back.
    var readCapacity: (String) -> (total: UInt64, free: UInt64) =
        VolumeInfo.capacity(of:)

    /// Keeps `volumes` in step with disks being mounted, ejected and renamed.
    private var volumeWatch: AnyCancellable?

    /// True while the folder picker is up.
    private var isChoosingFolder = false

    private var engine: ScanEngine?
    private var deleteTask: Task<Void, Never>?
    private var fileFilterWork: DispatchWorkItem?
    /// Lets a walk already running on `treeQueue` give up part-way.
    ///
    /// Cancelling the work item only stops one that hasn't started. `detach`
    /// still has to wait out a walk that has, because it is about to unlink the
    /// nodes that walk is reading — but with this the wait is the few
    /// microseconds to the walk's next check rather than a full pass over every
    /// file in the scan.
    ///
    /// A newer walk and a rescan cancel it too, for a plainer reason: nobody is
    /// going to be shown its rows. It is also how a walk knows it is still the
    /// current one when it comes back with them.
    private(set) var fileWalkToken = WalkToken()
    /// Every background read of the scan tree runs here, so a delete can make
    /// itself exclusive by syncing against it. Serial by design: two concurrent
    /// walks would buy nothing, and the barrier below depends on the ordering.
    private let treeQueue = DispatchQueue(
        label: "com.wizzzee.tree-read",
        qos: .userInitiated
    )
    /// Where the treemap lays itself out.
    ///
    /// Its own queue rather than sharing `treeQueue`, which would put every
    /// layout behind a File View walk over the whole scan — the treemap would
    /// arrive a second late on a big disk. The two only read the tree, so they
    /// are free to run at the same time as each other; what they must not do is
    /// run while a delete unlinks nodes, which `detach` handles by fencing both.
    let treemapQueue = DispatchQueue(
        label: "com.wizzzee.treemap-layout",
        qos: .userInitiated
    )

    init() {
        volumes = VolumeInfo.current()
        selectedVolumePath = volumes.first?.path ?? "/"
        hasFullDiskAccess = FullDiskAccess.isGranted()

        // The list above is only what was mounted at launch. `refreshVolumes`
        // existed to bring it up to date and nothing ever called it, so a disk
        // plugged in later never reached the picker and an ejected one never
        // left it.
        let workspace = NSWorkspace.shared.notificationCenter
        volumeWatch = workspace.publisher(for: NSWorkspace.didMountNotification)
            .merge(
                with: workspace.publisher(for: NSWorkspace.didUnmountNotification),
                workspace.publisher(for: NSWorkspace.didRenameVolumeNotification)
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                self.selectedVolumePath = Self.selection(
                    self.selectedVolumePath,
                    following: note
                )
                self.refreshVolumes()
            }
    }

    /// Where a selection at `path` should point once `note` has happened: the
    /// volume's new mount point if it is the one that was just renamed, and
    /// wherever it already was otherwise.
    ///
    /// Renaming a volume moves its mount point. Left to `refreshVolumes`, the
    /// old path is simply missing from the list, the selected disk is taken for
    /// an ejected one, and the selection falls back to the boot volume — so the
    /// next Scan reads a different disk from the one that was picked.
    static func selection(_ path: String, following note: Notification) -> String {
        guard note.name == NSWorkspace.didRenameVolumeNotification,
            let old = note.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL,
            let new = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
            old.path == path
        else { return path }
        return new.path
    }

    /// The one selected item, when exactly one is selected. The treemap
    /// highlight and the status line describe a single thing, so they ask for
    /// this rather than picking arbitrarily out of a set.
    var primarySelection: NodeRef? { selection.count == 1 ? selection.first : nil }

    // MARK: - Figures on show
    //
    // Each of these used to be put together in a view from `totalSize` or
    // `size`, whatever the picker said. With On Disk showing — the default —
    // the treemap, the bars and the sort all measured space occupied while the
    // lines around them added up file lengths, and one sparse image was enough
    // to have the header report more scanned than the volume can hold.

    /// How much the scan found, in the measure on show. Zero with no scan.
    var scannedBytes: UInt64 { result?.root.bytes(using: sizeMetric) ?? 0 }

    /// The header's "Scanned" line, or nil when there is no scan to describe.
    ///
    /// It sits directly above the volume's capacity, so it is read against it.
    /// With Size showing it still leads with the combined length, since that is
    /// what was asked for, but says what that occupies in the same breath: a
    /// length is the one figure here that can exceed the disk. The file count
    /// goes last, so it is what a narrow header cuts short.
    var scannedSummary: String? {
        guard let result else { return nil }
        return figure(
            length: result.root.totalSize,
            onDisk: result.root.totalAlloc
        ) + "  (\(ByteFormat.counted(result.root.totalFiles, "file")))"
    }

    /// The line under the Scan button while a scan runs.
    var progressSummary: String {
        "Scanning… \(ByteFormat.count(progress.items)) items, "
            + figure(length: progress.bytes, onDisk: progress.allocated)
    }

    /// A total in the measure on show. A length never stands alone: it is
    /// followed by the space it takes.
    private func figure(length: UInt64, onDisk: UInt64) -> String {
        guard sizeMetric == .logical else { return ByteFormat.decimal(onDisk) }
        return "\(ByteFormat.decimal(length))  •  "
            + "\(ByteFormat.decimal(onDisk)) on disk"
    }

    /// The status line's description of a single selected item.
    func selectionSummary(_ ref: NodeRef) -> String {
        var parts = [ref.path, ByteFormat.decimal(ref.bytes(using: sizeMetric))]
        if ref.isDirectory {
            parts.append(ByteFormat.counted(ref.dir.totalItems, "item"))
        }
        return parts.joined(separator: "  •  ")
    }

    /// Brings the tables into line with a change of measure.
    ///
    /// An order that was by the old measure becomes an order by the new one:
    /// left alone, the rows stay ranked by the column that has just been set
    /// back while the bars beside them, redrawn from the new measure, run in
    /// no order at all. An order by anything else — a name, a date, the
    /// measure that was *not* on show — was chosen for its own sake and is
    /// kept.
    ///
    /// Here, not in a view's `onChange`, so the tables are right for anything
    /// that sets the measure, a view being on screen or not. The picker sets
    /// it from a click, which is an ordinary place to publish from.
    private func sizeMetricChanged(from old: SizeMetric) {
        if let first = treeSort.first, first.key == old.sortKey {
            treeSort = [TreeSort(sizeMetric.sortKey, order: first.order)]
        }
        if let first = fileSort.first, first.keyPath == old.fileRowKeyPath {
            fileSort = [
                KeyPathComparator(sizeMetric.fileRowKeyPath, order: first.order)
            ]
        }
        // The file list is the largest thousand by the measure on show, so it
        // is a different list now, not the same one reordered.
        refreshFileRows(immediately: true)
        rebuildTreeRows()
    }

    // MARK: - Scan target

    var scanTargetPath: String { customFolder ?? selectedVolumePath }

    var scanTargetLabel: String {
        if let folder = customFolder { return folder }
        return volumes.first { $0.path == selectedVolumePath }?.menuTitle
            ?? selectedVolumePath
    }

    /// Capacity of the volume the current target lives on.
    var targetCapacity: (total: UInt64, free: UInt64) {
        if let capacityAfterDelete { return capacityAfterDelete }
        if let result { return (result.volumeTotal, result.volumeFree) }
        return VolumeInfo.capacity(of: scanTargetPath)
    }

    /// Reads the scanned volume's capacity again once a delete batch has run.
    ///
    /// After every batch, not only one that removed something whole: a folder
    /// that failed part-way has still freed whatever went before the failure.
    private func rereadCapacity() {
        guard let result else { return }
        let now = readCapacity(result.rootPath)
        // A failed read comes back as zeros, which would look worse on show
        // than figures that are a little old.
        if now.total > 0 { capacityAfterDelete = now }
    }

    func refreshVolumes() {
        volumes = VolumeInfo.current()
        if !volumes.contains(where: { $0.path == selectedVolumePath }) {
            selectedVolumePath = volumes.first?.path ?? "/"
        }
    }

    func chooseFolder() {
        // The panel has a ⌘⌫ of its own, for the file selected in it.
        isChoosingFolder = true
        defer { isChoosingFolder = false }
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

    /// False while a scan or a delete batch is running.
    ///
    /// A scan started mid-delete throws away the tree the batch's references
    /// point into, and the batch then applies them to whatever replaced it:
    /// hard-link counts matched by inode in a tree it never touched, and totals
    /// subtracted along a parent chain the rescan has freed. The scan itself
    /// would be reading folders in the middle of being removed.
    var canStartScan: Bool { phase != .scanning && !isDeleting }

    func startScan() {
        guard canStartScan else { return }
        let path = scanTargetPath

        result = nil
        treeRows = []
        // Dropped along with the rows it would have replaced: a walk still going
        // describes the scan being thrown away.
        fileFilterWork?.cancel()
        fileFilterWork = nil
        // One already under way is told to stop as well, rather than finishing
        // its pass and keeping the old scan in memory until it has.
        fileWalkToken.cancel()
        isFilteringFiles = false
        fileRows = []
        selection = []
        // A delete still awaiting confirmation names items in the tree being
        // thrown away, so it goes with the selection.
        permanentDeleteTargets = []
        sharedStorageCache = [:]
        capacityAfterDelete = nil
        treemapRoot = nil
        treemapOutline = nil
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
        var sort = treeSort.first ?? TreeSort(.size)
        // "% of Parent" is drawn with the metric on show, and rows are only
        // ever ranked against their siblings, which share a parent — so
        // ordering by the percentage is ordering by that metric's bytes. Ranked
        // by logical size regardless, a sparse image sorted above a file that
        // visibly took far more of the folder.
        if sort.key == .percent { sort.key = sizeMetric.sortKey }
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
        // That only stops a walk that hasn't started. One already running is
        // told through its token, or it finishes a pass over every file in the
        // scan for rows nobody will see — with the walk replacing it waiting
        // behind it on the same serial queue.
        fileWalkToken.cancel()
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
        // A fresh token per walk: the previous one may already be cancelled, and
        // this walk is entitled to run.
        let token = WalkToken()
        fileWalkToken = token

        let work = DispatchWorkItem { [weak self] in
            let refs = result.largestFiles(
                matching: query,
                limit: 1000,
                metric: metric,
                token: token
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
                // Only the newest walk delivers. One that had finished its pass
                // before being replaced would otherwise land first, with rows
                // built for a metric no longer on show, and stop the spinner
                // while the real answer was still on its way.
                guard let self, self.fileWalkToken === token,
                    self.fileQuery == query,
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

    /// True while a delete batch is running, so the UI can offer a Stop and
    /// refuse to start another.
    var isDeleting: Bool { deleteProgress != nil }

    /// Stops a running batch after the item currently being removed.
    func cancelDelete() { deleteTask?.cancel() }

    func moveToTrash(_ ref: NodeRef) { moveToTrash([ref]) }

    func moveToTrash(_ refs: Set<NodeRef>) {
        // A name in the Trash is moved, not removed: it is still a name for its
        // inode, so whatever shared storage with it still does.
        performBatch(on: refs, unlinks: false) { try FileActions.moveToTrash($0) }
    }

    func deletePermanently(_ ref: NodeRef) { deletePermanently([ref]) }

    func deletePermanently(_ refs: Set<NodeRef>) {
        performBatch(on: refs, unlinks: true) {
            try FileActions.deletePermanently($0)
        }
    }

    // MARK: - Delete keys
    //
    // ⌘⌫ and ⌥⌘⌫, on the keys Finder has them on. The first moves to the Trash
    // without asking, so both are held to what can be seen: the selection is
    // one set shared by every tab, and it keeps a row that a collapsed folder
    // or a change of tab has taken off the screen.

    /// The part of the selection the current tab has on show.
    var selectionOnShow: Set<NodeRef> { selection.filter(isOnShow) }

    /// Whether the current tab has `ref` on show, as a test to run over the
    /// selection.
    private var isOnShow: (NodeRef) -> Bool {
        switch tab {
        case .tree:
            // Staleness last: it walks to the root, and for a selection a
            // collapsed folder has hidden the first test fails one step up.
            return { ref in
                (self.isTreeRow(ref) || self.isOutlinedInTreemap(ref))
                    && !ref.isStale
            }
        case .files:
            let rows = Set(fileRows.lazy.map(\.ref))
            return { ref in !ref.isStale && rows.contains(ref) }
        case .about:
            return { _ in false }
        }
    }

    /// Whether `rebuildTreeRows` gives `ref` a row: every folder above it has
    /// to be open, and the root always has one.
    ///
    /// Asked of the folders rather than of `treeRows`, which is an array as
    /// long as everything expanded: the menu asks this on every publish.
    private func isTreeRow(_ ref: NodeRef) -> Bool {
        var above: DirNode? = ref.isDirectory ? ref.dir.parent : ref.dir
        while let step = above {
            guard expanded.contains(step.id) else { return false }
            above = step.parent
        }
        return true
    }

    /// Whether the treemap is showing and `ref` is the one item it outlines.
    /// A tile clicked on the map is selected without being given a row.
    ///
    /// Asked of the map, not worked out from where `ref` sits under the map's
    /// root: plenty under there is never drawn, and stays selected all the
    /// same.
    private func isOutlinedInTreemap(_ ref: NodeRef) -> Bool {
        showsTreemap && treemapOutline == ref && primarySelection == ref
    }

    /// False when the delete keys have nothing to act on or something is in
    /// the way: a batch already running, a sheet waiting for an answer, the
    /// filter or the folder picker holding the keyboard.
    var canUseDeleteKeys: Bool {
        !isDeleting && !isEditingFilter && !isChoosingFolder
            && permanentDeleteTargets.isEmpty && actionError == nil
            && selection.contains(where: isOnShow)
    }

    /// ⌘⌫: moves what is selected and on show to the Trash.
    func trashSelection() {
        guard let targets = deleteKeyTargets() else { return }
        moveToTrash(targets)
    }

    /// ⌥⌘⌫: asks before deleting what is selected and on show for good.
    func confirmDeletingSelection() {
        guard let targets = deleteKeyTargets() else { return }
        permanentDeleteTargets = targets
    }

    /// What a delete key acts on, or nil when it should do nothing.
    ///
    /// One item that can't be removed stops the lot, as it does in the context
    /// menu — but with the reason on show, since a key that did nothing at all
    /// is what a scan's root, selected the moment the scan lands, would give.
    private func deleteKeyTargets() -> Set<NodeRef>? {
        guard canUseDeleteKeys else { return nil }
        let targets = selectionOnShow
        if let refusal = targets.lazy
            .compactMap({ self.deletionRefusal(for: $0) }).first
        {
            actionError = refusal.errorDescription
            actionErrorDetail = refusal.recoverySuggestion
            return nil
        }
        return targets
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

    /// True when nothing in `refs` may be removed, so the menu can offer an
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
    ///
    /// That holds inside a folder too. Its total counts every hard-linked file
    /// in it in full, so the ones with a name left over outside the folder are
    /// taken back off.
    func reclaimableSize(_ refs: Set<NodeRef>) -> UInt64 {
        reclaimable(refs, using: sizeMetric)
    }

    /// The space deleting `refs` gives back, whatever measure is on show.
    ///
    /// For the sentence in the delete confirmation, which says the figure
    /// "will be reclaimed". That is a statement about the disk, and with Size
    /// showing it was made in lengths: 995 GB promised back from a sparse
    /// image whose removal frees the 42 GB it occupies.
    func reclaimableSpace(_ refs: Set<NodeRef>) -> UInt64 {
        reclaimable(refs, using: .allocated)
    }

    private func reclaimable(_ refs: Set<NodeRef>, using metric: SizeMetric) -> UInt64 {
        distinctTargets(refs).reduce(0) { total, ref in
            if let file = ref.file, file.sharesStorage { return total }
            let weight = ref.bytes(using: metric)
            guard ref.isDirectory else { return total + weight }
            let shared = sharedStorage(under: ref.dir)
            let staying = metric == .logical ? shared.size : shared.alloc
            return total + weight - min(weight, staying)
        }
    }

    /// Whether any target's bytes live under more than one name, which makes the
    /// reclaimable figure a ceiling rather than a promise.
    func selectionSharesStorage(_ refs: Set<NodeRef>) -> Bool {
        distinctTargets(refs).contains { ref in
            ref.isDirectory
                ? sharedStorage(under: ref.dir).names > 0
                : ref.file?.sharesStorage == true
        }
    }

    /// The bytes under `dir` that would still be on disk once it was deleted.
    ///
    /// An inode goes with the folder only if every one of its names is in
    /// there. One with a name left over anywhere else — elsewhere in the scan,
    /// or outside it altogether, which only the link count can say — stays, and
    /// so does not count towards what the delete frees.
    ///
    /// Judged one folder at a time: a pair split across two folders that are
    /// both selected is counted as staying for each. That errs low, which is
    /// the side this figure is meant to err on.
    private func sharedStorage(under dir: DirNode) -> SharedStorage {
        if let known = sharedStorageCache[dir.id] { return known }

        // Per inode: the names found under `dir`, the most names it was ever
        // seen to have, and the bytes its counted name carries.
        var inodes: [UInt64: (names: Int, links: UInt8, size: UInt64, alloc: UInt64)] =
            [:]
        var stack: [DirNode] = [dir]
        while let step = stack.popLast() {
            for i in step.files.indices where step.files[i].sharesStorage {
                var seen = inodes[step.files[i].fileID] ?? (0, 0, 0, 0)
                seen.names += 1
                seen.links = max(seen.links, step.files[i].linkCount)
                if !step.files[i].isDuplicateLink {
                    seen.size = step.files[i].size
                    seen.alloc = step.files[i].alloc
                }
                inodes[step.files[i].fileID] = seen
            }
            stack.append(contentsOf: step.subdirs)
        }

        var shared = SharedStorage()
        // A saturated count hides how many names there really are, so it is
        // taken to mean there is always one more.
        for seen in inodes.values
        where seen.links == .max || seen.names < Int(seen.links) {
            shared.size += seen.size
            shared.alloc += seen.alloc
            shared.names += seen.names
        }
        sharedStorageCache[dir.id] = shared
        return shared
    }

    /// Runs a delete batch off the main actor, reporting progress as it goes.
    ///
    /// `removeItem` on a large tree is tens of seconds to minutes of `unlink(2)`.
    /// Run on the main actor — which is where every caller of this is — it
    /// stopped the run loop for the whole of that: no spinner, no progress, no
    /// cancel, and long enough that the responsiveness watchdog could kill the
    /// app part-way and leave a half-removed tree behind totals that were never
    /// updated.
    ///
    /// One target at a time rather than concurrently: the batch is already
    /// deduplicated to non-overlapping subtrees, and deleting several huge trees
    /// at once only makes the disk seek more.
    ///
    /// `unlinks` says whether `body` removes a name outright or only moves it
    /// out of the tree, which decides what its hard-linked partners are told.
    private func performBatch(
        on refs: Set<NodeRef>,
        unlinks: Bool,
        _ body: @escaping @Sendable (String) throws -> Void
    ) {
        // One batch at a time. A second started mid-flight would resolve its
        // paths against a tree the first is still changing.
        guard deleteTask == nil else { return }

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

        let paths = allowed.map(\.path)
        deleteProgress = DeleteProgress(
            done: 0,
            total: paths.count,
            currentName: (paths[0] as NSString).lastPathComponent
        )

        deleteTask = Task { [weak self] in
            var deleted: [NodeRef] = []
            var failures: [(title: String, detail: String)] = []

            for (index, path) in paths.enumerated() {
                // Checked between items. `removeItem` itself can't be
                // interrupted, so Stop takes effect at the next target rather
                // than part-way through the one in hand.
                if Task.isCancelled { break }

                let failure = await Task.detached(priority: .userInitiated) {
                    () -> (title: String, detail: String)? in
                    do {
                        try body(path)
                        return nil
                    } catch let error as FileActions.ActionError {
                        return (
                            error.errorDescription ?? "Couldn’t delete an item",
                            error.recoverySuggestion ?? ""
                        )
                    } catch {
                        let name = (path as NSString).lastPathComponent
                        return (
                            "Couldn’t delete “\(name)”", error.localizedDescription
                        )
                    }
                }.value

                if let failure {
                    failures.append(failure)
                } else {
                    deleted.append(allowed[index].ref)
                }

                guard let self else { return }
                self.deleteProgress = DeleteProgress(
                    done: index + 1,
                    total: paths.count,
                    currentName: index + 1 < paths.count
                        ? (paths[index + 1] as NSString).lastPathComponent : ""
                )
            }

            guard let self else { return }
            self.deleteTask = nil
            self.deleteProgress = nil
            // Successes are applied even when part of the batch failed or was
            // stopped, so the tree never claims space that is already gone.
            self.detach(deleted, unlinked: unlinks)
            self.rereadCapacity()
            self.report(
                failures: failures,
                refusals: refusals,
                attempted: targets.count
            )
        }
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
    ///
    /// `unlinked` is false when the items went to the Trash. They leave the
    /// tree either way, but a trashed name still holds its inode, so the names
    /// that share storage with it keep their link counts.
    private func detach(_ refs: [NodeRef], unlinked: Bool) {
        guard !refs.isEmpty else { return }

        // The File View walk reads this tree on `treeQueue`. Drop any walk that
        // hasn't started, tell one that has to give up, then wait out whatever
        // is left, so nothing is traversing the nodes about to be unlinked.
        //
        // The barrier stays: it is what makes the unlink safe, since a walk
        // mid-traversal is reading the very arrays about to be mutated. The
        // token is what makes it short — without it this waited out a full pass
        // over every file in the scan.
        fileFilterWork?.cancel()
        fileFilterWork = nil
        fileWalkToken.cancel()
        treeQueue.sync {}
        // The treemap reads the same tree, on its own queue, so it is fenced
        // too. A layout in flight is short — tens of milliseconds — and only
        // this makes it safe to run it off the main thread at all.
        treemapQueue.sync {}

        // Files come off first, highest index first: removing an entry shifts
        // every sibling after it, so any other order unlinks the wrong ones.
        // Sorting the whole batch at once is safe because entries in different
        // folders can't disturb each other's indices.
        let files = refs.lazy.filter { !$0.isDirectory }
            .sorted { $0.fileIndex > $1.fileIndex }
        for ref in files { detachFile(ref, unlinked: unlinked) }

        // Hard links before the folders themselves, while they are still
        // attached, and for the whole batch in one go. A name under a folder
        // that carried an inode's bytes hands them to a name outside every
        // folder that is going, as a single file does — otherwise they leave
        // the totals with the folder while still on disk — and, if the folders
        // were really removed, every surviving name loses the links that went.
        let folders = refs.filter { $0.isDirectory && !$0.dir.isRoot }.map(\.dir)
        let promotions =
            result?.releaseHardLinks(under: folders, unlinking: unlinked) ?? []
        for promoted in promotions {
            add(size: promoted.size, alloc: promoted.alloc, to: promoted.dir)
        }
        // The File Types panel is totalled per type at scan time, so what is
        // leaving has to come off those totals too, or it goes on listing
        // files that are gone against a total that no longer includes them.
        result?.forgetTypes(under: folders)
        result?.rankTypes()
        for folder in folders { detachDirectory(folder) }

        // Removing a file shifts the indices of its siblings, invalidating any
        // NodeRef held elsewhere, so all derived rows are rebuilt and the
        // selection is dropped — along with a delete still awaiting
        // confirmation, which would otherwise be confirmed against whatever
        // shifted into its place.
        selection = []
        permanentDeleteTargets = []
        hoveredRef = nil
        sharedStorageCache = [:]
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

    private func detachFile(_ ref: NodeRef, unlinked: Bool) {
        let dir = ref.dir
        let index = Int(ref.fileIndex)
        guard index < dir.files.count else { return }
        let file = dir.files[index]

        if file.isDuplicateLink {
            // Its bytes were never in the totals — they are counted under the
            // name the scan reached first, which is still there. If the name
            // was really removed the survivors still lose a link, so one left
            // alone can promise its bytes again.
            result?.releaseHardLink(
                at: (dir, index),
                promoting: false,
                unlinking: unlinked
            )
            result?.forgetDuplicate(file)
            result?.forgetType(of: file)
            subtract(size: 0, alloc: 0, files: 1, dirs: 0, from: dir)
            dir.files.remove(at: index)
            return
        }

        // This name is the one carrying the inode's bytes. If another name for
        // it is still in the tree, those bytes have not gone anywhere: the
        // survivor takes over the count, so the folder holding it stops
        // reporting the file as free and the totals keep matching the disk.
        //
        // Both chains are walked, not just the common part, because the two
        // names can be in different folders — and if there is no survivor in
        // the tree, the bytes really do leave it and only the subtraction runs.
        if file.isHardLinked,
            let promoted = result?.releaseHardLink(
                at: (dir, index),
                promoting: true,
                unlinking: unlinked
            )
        {
            add(size: promoted.size, alloc: promoted.alloc, to: promoted.dir)
        }

        result?.forgetType(of: file)
        subtract(size: file.size, alloc: file.alloc, files: 1, dirs: 0, from: dir)
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

    /// Walks a size back *up* to the root, for a hard link's surviving name
    /// taking over bytes the deleted name used to account for. Counts are
    /// untouched: the survivor was always in them, at zero size.
    private func add(size: UInt64, alloc: UInt64, to node: DirNode) {
        var current: DirNode? = node
        while let step = current {
            step.totalSize += size
            step.totalAlloc += alloc
            current = step.parent
        }
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
