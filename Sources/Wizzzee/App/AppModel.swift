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

    /// The row for `ref`, a file or a folder a search turned up, as it
    /// stands now. `rootTotal` is the scan's total in `metric`.
    init(_ ref: NodeRef, metric: SizeMetric, rootTotal: UInt64) {
        self.ref = ref
        name = ref.name
        // The folder a thing is in, which for a folder is the one above it.
        directory =
            ref.isDirectory ? (ref.dir.parent?.path ?? "") : ref.dir.path
        size = ref.size
        alloc = ref.alloc
        mtime = ref.mtime
        fractionOfRoot =
            Double(ref.bytes(using: metric)) / Double(max(rootTotal, 1))
    }
}

/// How many things a search found, and what they come to.
struct SearchTally: Equatable {
    var matches: Int
    /// How many of them are folders: what they are called depends on it,
    /// and the rows on show are only the largest of them.
    var folders: Int = 0
    var bytes: UInt64
}

enum MainTab: String, CaseIterable {
    case tree = "Tree View"
    case files = "File View"
    case about = "About"

    /// The digit that, with ⌘, brings this tab to the front.
    var key: Character {
        switch self {
        case .tree: return "1"
        case .files: return "2"
        case .about: return "3"
        }
    }

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
    @Published var selection: Set<NodeRef> = [] {
        // Only when it has changed. It is assigned as it stands after every
        // delete, and a panel opened from the menu on some other row would be
        // pulled back to the selected one by an assignment that moved nothing.
        didSet { if selection != oldValue { previewFollowsSelection() } }
    }
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
    ///
    /// Each is held with the folder it is the id of, weakly, so that where
    /// the open folders are can be said without looking for them: a rescan
    /// asks, and going by ids alone it had to walk every folder in the scan
    /// to find the few that were open — all of them, whenever one of those
    /// had since been deleted and was not there to be found.
    private var expanded = OpenFolders()

    private struct OpenFolders {
        private struct Entry {
            weak var dir: DirNode?
        }
        private var entries: [UInt64: Entry] = [:]

        func contains(_ dir: DirNode) -> Bool { entries[dir.id] != nil }
        mutating func insert(_ dir: DirNode) { entries[dir.id] = Entry(dir: dir) }
        mutating func remove(_ dir: DirNode) { entries[dir.id] = nil }
        mutating func removeAll() { entries.removeAll() }

        /// Where each of them is, for those still in the tree.
        var paths: [String] {
            entries.values.compactMap { entry in
                entry.dir.flatMap { $0.isCutOff ? nil : $0.path }
            }
        }
    }
    /// The row the Tree View was last asked to bring into view, and a count
    /// that goes up with each asking, so that asking for the same row twice
    /// is still two requests.
    ///
    /// Selecting a row does not scroll a table to it. A row picked from
    /// somewhere else — "Show in Tree", the list of marks, an arrow key
    /// stepping out to the folder above — was selected wherever it sat, which
    /// in a long folder is nowhere near what the table was showing.
    @Published private(set) var revealTarget: NodeRef?
    @Published private(set) var revealCount = 0
    /// True from a row being asked for until the Tree View has scrolled to
    /// it. The asking can come while another tab is in front — "Show in
    /// Tree" is in the File View's menu — and the table is then not there to
    /// be told; it finds this waiting when it is next put on screen.
    private var revealIsWaiting = false

    // File View
    @Published private(set) var fileRows: [FileRow] = []
    /// The search and the type `fileRows` were found for. They stay on
    /// screen while the walk for another comes back, which on a big scan is
    /// long enough to act in: see `isOnShow`.
    private var fileRowsAnswer: (query: String, type: String?) = ("", nil)
    @Published var fileQuery: String = ""
    /// What the search in hand found, listed or not, once it has come back.
    /// Nil with nothing asked for: the list is then the largest files, and
    /// nothing was counted to make it.
    @Published private(set) var fileTally: SearchTally?
    /// Goes up each time the filter is asked to take the keyboard, by ⌘F.
    @Published private(set) var filterFocusCount = 0
    /// True from ⌘F until the filter has taken the keyboard. The File View
    /// may not be on screen when it is pressed, and has to be told when it
    /// gets there.
    private var filterWantsFocus = false
    @Published var fileSort: [KeyPathComparator<FileRow>] = [
        KeyPathComparator(\FileRow.alloc, order: .reverse)
    ]
    @Published var isFilteringFiles = false

    // Quick Look
    /// What the Quick Look panel is showing, or nil while it is shut. The
    /// panel sets it back to nil itself when it is closed.
    @Published var previewURL: URL? {
        didSet { if previewURL == nil { previewed = nil } }
    }
    /// The item that URL was made from, so a delete can tell that what is
    /// being looked at has gone.
    private(set) var previewed: NodeRef?

    // File type in focus
    /// The file type picked out in File Types, by its extension — empty for
    /// the files that have none — or nil when no type is.
    ///
    /// The legend said how much of the scan a type took and nothing about
    /// where. With one in focus the treemap sets every other tile back, so
    /// the type shows as lit patches across the disk, and the File View lists
    /// that type's largest files and no others.
    @Published private(set) var focusedType: String?
    /// Whether File Types lists every type in the scan, not only the
    /// largest. Here and not in the view: the tab it is on is thrown away at
    /// every change of tab, and came back at the short list with the type in
    /// focus nowhere in it.
    @Published var listsEveryType = false

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

    // Marks
    /// What has been picked out for removal. See the Marks section below.
    @Published private(set) var marks: Set<NodeRef> = []
    /// How many marks lie beneath each folder, keyed on `DirNode.id`, so a
    /// folder's row can say there is something marked inside it without
    /// looking through everything it holds.
    private var marksBeneath: [UInt64: Int] = [:]
    /// Whether the list of marks is open under the bar that counts them.
    @Published var showsMarks = false

    // The guide
    /// Whether the guide to the app is up, over the window.
    @Published var showsWelcome = false
    /// The page of it that is open, or that it will open at.
    @Published var welcomePage = WelcomePage.scan
    /// Whether this launch has had its chance to open with the guide.
    private var hasOfferedWelcome = false

    // Errors surfaced as a sheet
    @Published var actionError: String?
    @Published var actionErrorDetail: String?
    /// Non-empty while awaiting confirmation of an irreversible delete.
    @Published var permanentDeleteTargets: Set<NodeRef> = []

    /// How far a running delete batch has got. Nil when none is running.
    @Published private(set) var deleteProgress: DeleteProgress?

    /// Progress of a delete batch.
    ///
    /// Counted in files and folders removed, against what the scan found under
    /// the targets. It was counted in top-level targets, because
    /// `FileManager.removeItem` reported nothing on its way through a folder —
    /// so deleting one folder, which is the usual case, was a bar that sat at
    /// nothing until it was all over.
    ///
    /// The disk may have changed since the scan, so the totals are what was
    /// expected rather than a promise, and `fraction` stops at 1.
    struct DeleteProgress: Equatable {
        /// Top-level targets finished, and how many there are.
        var done: Int
        var total: Int
        /// The target in hand, for the status line.
        var currentName: String
        /// Files and folders removed so far, and what the scan counted.
        var items = 0
        var itemsTotal = 0
        /// The space they occupied, and what the scan counted.
        var bytes: UInt64 = 0
        var bytesTotal: UInt64 = 0

        var fraction: Double {
            guard itemsTotal > 0 else {
                return total > 0 ? Double(done) / Double(total) : 0
            }
            return min(1, Double(items) / Double(itemsTotal))
        }
    }

    /// The targets of the batch in hand, once it has run long enough to be
    /// worth showing: their rows are set back until they go.
    ///
    /// Not from the first instant. A move to the Trash is over in a frame or
    /// two, and a row that dimmed and then vanished would be the flicker this
    /// is here to avoid.
    @Published private(set) var removing: Set<NodeRef> = []

    /// How long a batch runs before its rows are set back, in nanoseconds.
    ///
    /// A property so the self-test can ask for none: a batch that outlasts a
    /// fifth of a second there would be one that depended on how fast the
    /// disk was that day.
    var removingGrace: UInt64 = 200_000_000

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

    /// One thing a batch moved to the Trash, with what it takes to bring it
    /// back: where it was, where in the Trash it went, and its place in the
    /// tree, which the tree itself forgets when it lets go of it.
    private struct Trashed {
        let ref: NodeRef
        let path: String
        /// Where in the Trash it is, and what it is: see `TrashReceipt`.
        let receipt: FileActions.TrashReceipt
        /// A file's entry as it stood. Its slot in the folder is emptied
        /// when it leaves, and is where it goes back.
        let entry: FileEntry?
        /// The folder a folder hung from. Detaching it cuts that link.
        let parent: DirNode?
        /// The space it took as the scan had it, for sharing out what the
        /// batch took off the totals among what it moved.
        let weight: UInt64
        /// The marks that went with it: its own, or for a folder those on
        /// what was inside it. Only the first was kept, and a folder that
        /// came back came back with everything in it unmarked.
        let marks: [NodeRef]
    }

    /// What the last move to the Trash moved, for as long as it can be
    /// undone: until something else is removed, or the folder is scanned
    /// again. Either changes the tree these would be put back into.
    private var lastTrash: [Trashed] = []
    /// What that move took off the scan's total.
    private var lastTrashTook: UInt64 = 0

    /// Whether there is a move to the Trash to undo.
    @Published private(set) var canUndoTrash = false

    /// Everything moved to the Trash since the app was opened and not
    /// brought back, and the space each would give back.
    private var sessionTrash: [(receipt: FileActions.TrashReceipt, bytes: UInt64)] = []

    /// What of that is still in the Trash, in space on disk.
    ///
    /// A trashed item's bytes come off every folder above it, and are still
    /// on the disk. Scanned fell, Volume Free stayed where it was, and
    /// nothing on screen said where the difference had gone.
    @Published private(set) var bytesInTrash: UInt64 = 0

    /// The window's undo manager, so that Edit ▸ Undo and ⌘Z offer the move
    /// back.
    ///
    /// A window that is shut and opened again has a stack of its own with
    /// nothing on it, so a move still waiting to be undone is put on that
    /// one too: the Undo button in the status bar offered it and ⌘Z did not.
    weak var undoManager: UndoManager? {
        didSet {
            if undoManager !== oldValue { registerUndo() }
        }
    }

    /// Brings the Trash line up to date when the app comes to the front: the
    /// Trash is emptied from Finder, not from here.
    private var activationWatch: AnyCancellable?

    /// Looks again every few seconds for as long as the line has something
    /// to say. Coming to the front is not notice enough: the Trash can be
    /// emptied from a script, or from the Dock's menu with this window still
    /// in front, and the line then went on quoting what was no longer there.
    private var trashWatch: AnyCancellable?

    /// How many looks in a row found some part of the Trash that could not
    /// be looked at. Past a few, the looking every few seconds stops: see
    /// `refreshTrashLine`.
    private var looksUnanswered = 0

    /// Whether the Trash is being looked at every few seconds.
    var isWatchingTrash: Bool { trashWatch != nil }

    /// How a batch moves one thing to the Trash. A property so the
    /// self-test can stand in a Trash that does not say where things went,
    /// and one that is inside the folder being scanned.
    var trashMover: @Sendable (String) throws -> FileActions.TrashReceipt? = {
        try FileActions.moveToTrash($0)
    }

    /// Asks the disk whether what is at a path is with a cloud provider.
    /// A property for the reason `readCapacity` is one: a file can't be
    /// made online only to order.
    var isOnlineOnlyNow: (String) -> Bool = FileActions.isOnlineOnly

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
    ///
    /// Published, so the delete commands are greyed for as long as it is and
    /// not merely refused when they arrive: a key that matches a greyed item
    /// goes on to the panel, which is where ⌘⌫ was aimed.
    @Published private(set) var isChoosingFolder = false

    /// Something in the tree by where it is on disk, which is all of it that
    /// outlasts the scan it was found in.
    private struct Spot {
        let path: String
        let isDirectory: Bool
        /// Its number on the volume, or zero where none was taken.
        let fileID: UInt64

        init(_ ref: NodeRef) {
            path = ref.path
            isDirectory = ref.isDirectory
            fileID = Self.number(of: ref)
        }

        private static func number(of ref: NodeRef) -> UInt64 {
            ref.isDirectory ? ref.dir.fileID : ref.file?.fileID ?? 0
        }

        /// What is there now, if it is the same thing. A file or a folder
        /// is known by its number as well as its name: another put in its
        /// place since is not what was marked, and the list of marks is
        /// moved to the Trash without asking.
        func find(in scan: ScanResult) -> NodeRef? {
            guard
                let found = isDirectory
                    ? scan.directory(at: path).map({ NodeRef($0) })
                    : scan.file(at: path)
            else { return nil }
            let now = Self.number(of: found)
            return fileID == 0 || now == 0 || now == fileID ? found : nil
        }
    }

    /// How the window stood when a folder was scanned again.
    ///
    /// A scan throws the tree away, and with it went everything that pointed
    /// into the tree: which folders were open, where the map was zoomed to,
    /// what was selected, and every mark. ⌘R is one keypress, and it emptied
    /// a list of marks that had taken ten minutes to gather, without asking.
    private struct Place {
        let rootPath: String
        var open: [String] = []
        var zoom: String?
        var selection: [Spot] = []
        var marks: [Spot] = []
        var focusedType: String?
        var showsMarks = false
    }

    /// Where things stood before the scan in hand, when it is a scan of the
    /// folder that was already on show. Put back when it lands.
    private var placeToRestore: Place?

    /// How many marks the last rescan could not put back: what they were on
    /// has gone, or can no longer be removed. Said beside "Scan complete",
    /// so a shorter list of marks is not taken for the whole of it.
    @Published private(set) var marksLostToRescan = 0

    /// The space in use on the volume being scanned, as read when the scan
    /// began, or zero when a folder is: how much is in a folder is what the
    /// scan is there to find out.
    private var scanGoal: UInt64 = 0

    private var engine: ScanEngine?
    private var deleteTask: Task<Void, Never>?
    /// Asks the removal in hand to stop at its next entry.
    private var deleteStop: Removal.Stop?
    /// Tells one batch's progress reports from the next one's: a report is
    /// sent from the thread doing the removing and can land after its batch
    /// has ended.
    private var deleteBatch = 0
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

        activationWatch = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTrashLine() }

        // What was chosen last time. Each launch started over at space on
        // disk and the boot volume, whatever had been picked the launch
        // before; a folder or a disk that has since gone is not picked again.
        sizeMetric = Preferences.sizeMetric
        treeSort = [TreeSort(sizeMetric.sortKey)]
        fileSort = [KeyPathComparator(sizeMetric.fileRowKeyPath, order: .reverse)]
        var isFolder: ObjCBool = false
        if let folder = Preferences.lastFolder,
            FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder),
            isFolder.boolValue
        {
            customFolder = folder
        } else if let volume = Preferences.lastVolume,
            volumes.contains(where: { $0.path == volume })
        {
            selectedVolumePath = volume
        }

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
                // What is remembered for the next launch moves with it, or
                // that launch looks for the disk where it no longer is and
                // falls back to the boot volume.
                if note.name == NSWorkspace.didRenameVolumeNotification,
                    let old = note.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL,
                    let new = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                {
                    Preferences.volumeMoved(from: old.path, to: new.path)
                    // And the folder this session is set to scan, or the
                    // next Scan throws the tree away and then fails at a
                    // path that is no longer there.
                    if let folder = self.customFolder {
                        self.customFolder = Preferences.path(
                            folder,
                            movedFrom: old.path,
                            to: new.path
                        )
                    }
                }
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

    /// How far a scan of a whole volume has got, from 0 to 1. Nil when there
    /// is nothing to measure it against, and the bar can only say that
    /// something is happening.
    ///
    /// The bar said only that for every scan, though what has been read so
    /// far and what the volume holds were both known. It will not always
    /// reach the end: what a volume has in use includes snapshots, folders
    /// that can't be read and other volumes sharing its space, none of
    /// which a scan counts. That it stops short of full is still more to go
    /// on than a bar that never moves.
    var scanFraction: Double? {
        guard phase == .scanning else { return nil }
        return Self.fraction(read: progress.allocated, of: scanGoal)
    }

    /// `read` as a share of `goal`, or nil with no goal to be a share of.
    static func fraction(read: UInt64, of goal: UInt64) -> Double? {
        goal > 0 ? min(1, Double(read) / Double(goal)) : nil
    }

    /// The folder a running scan is in, for the line under the bar.
    var scanningIn: String { phase == .scanning ? progress.currentPath : "" }

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

    // MARK: - Quick Look
    //
    // The tables say how big a thing is and nothing about what it is. Finding
    // out meant Reveal in Finder, a look there, and the way back — for every
    // file someone was not sure about, which before deleting is most of them.

    /// The one item selected and on show, which is what ⌘Y looks at. With
    /// several selected there is no one of them to show.
    private var previewCandidate: NodeRef? {
        let shown = selectionOnShow
        return shown.count == 1 ? shown.first : nil
    }

    /// Whether ⌘Y has anything to do: a panel to shut, or something to look
    /// at and nothing in the way of looking — the folder picker, a question
    /// waiting for an answer. A key reaches the menu from under those, and
    /// would put a panel up over them.
    var canTogglePreview: Bool {
        if previewURL != nil { return true }
        return previewCandidate != nil && !isChoosingFolder
            && permanentDeleteTargets.isEmpty && actionError == nil
            && !showsWelcome
    }

    /// ⌘Y, as in Finder: opens Quick Look on the selected item, and shuts it
    /// if it is open.
    func togglePreview() {
        if previewURL != nil {
            previewURL = nil
        } else if let ref = previewCandidate {
            preview(ref)
        }
    }

    /// Opens Quick Look on `ref`.
    ///
    /// Not on a file a cloud provider is holding. Reading one is what brings
    /// its contents down, and Quick Look reads it: a look at a 4 GB file
    /// that was taking no space would put 4 GB on a disk someone is in the
    /// middle of emptying.
    ///
    /// What is looked at becomes what is selected. The right-click menu acts
    /// on the row that was clicked, which need not be the selected one, and
    /// the delete keys act on the selection: a panel showing one file beside
    /// a highlight on another had ⌘⌫ remove the one that was not being
    /// looked at.
    func preview(_ ref: NodeRef) {
        guard !ref.isStale else { return }
        if isOnlineOnly(ref, askingTheDisk: true) {
            actionError = "“\(ref.name)” is online only"
            actionErrorDetail =
                "Its contents are with a cloud provider and not on this disk. "
                + "Looking at it would download all "
                + "\(ByteFormat.decimal(ref.size)) of it."
            return
        }
        if selection != [ref] { selection = [ref] }
        show(inPreview: ref)
    }

    /// Whether Quick Look would have to download `ref` to show it. A folder
    /// is shown as its icon and is not read.
    ///
    /// The scan's own note of it, for a file. A link always has the disk
    /// asked as well, since the note is of the link and what reads a link
    /// reads what it is to. Asking for every file would be a look at the
    /// disk, on the main thread, for each row the selection passes over
    /// with the panel up — and a disk that is slow to answer, one spinning
    /// up or a share that has dropped, would hold the window until it did.
    ///
    /// `askingTheDisk` is for the one look that was asked for by name. The
    /// note is as old as the scan, and a file sent back to the cloud since —
    /// Remove Download, to make room — was still down in it as all here.
    private func isOnlineOnly(_ ref: NodeRef, askingTheDisk: Bool = false) -> Bool {
        guard let file = ref.file else { return false }
        if file.storage == .dataless { return true }
        return (askingTheDisk || file.isSymlink) && isOnlineOnlyNow(ref.path)
    }

    /// Points the panel at `ref`, or shuts it if `ref` is not something it
    /// may show. For the times nothing was asked for by name — the selection
    /// moved, or what was on show was deleted — when an alert about a file
    /// someone only passed over would be an interruption.
    private func show(inPreview ref: NodeRef) {
        guard !ref.isStale, !isOnlineOnly(ref) else {
            previewURL = nil
            return
        }
        previewed = ref
        previewURL = URL(fileURLWithPath: ref.path)
    }

    /// With the panel open, a change of selection is a change of what is
    /// being looked at, as it is in Finder — and a selection of several, or
    /// of nothing, is no one thing to look at, so the panel shuts. While it
    /// is up it is always showing the one thing that is selected.
    private func previewFollowsSelection() {
        guard previewURL != nil else { return }
        guard selection.count == 1, let ref = selection.first else {
            previewURL = nil
            return
        }
        if ref != previewed { show(inPreview: ref) }
    }

    // MARK: - The guide

    /// False while something else is over the window waiting for an answer:
    /// two sheets on one window are shown one after the other, and the guide
    /// would come up when the question under it had been answered.
    ///
    /// And while a removal is running. Its Stop is in the status bar, which
    /// the guide would cover, and what it has to say if it fails would wait
    /// behind the guide to be said.
    var canShowWelcome: Bool {
        permanentDeleteTargets.isEmpty && actionError == nil && !isChoosingFolder
            && !isDeleting
    }

    /// Puts the guide up, at `page`. Already up, it turns to that page.
    ///
    /// Quick Look is shut first. Its panel floats over the guide, and ⌘Y,
    /// which would shut it, is off for as long as the guide is up.
    func showWelcome(at page: WelcomePage = .scan) {
        guard showsWelcome || canShowWelcome else { return }
        if previewURL != nil { previewURL = nil }
        welcomePage = page
        showsWelcome = true
    }

    /// Opens with the guide, the first time the window is put up in a launch
    /// and for as long as it has not been asked to stay away. Once: a window
    /// that is closed and opened again is not a launch.
    func offerWelcome() {
        guard !hasOfferedWelcome else { return }
        hasOfferedWelcome = true
        if Preferences.showsWelcome { showWelcome() }
    }

    // MARK: - Tabs

    /// Brings `tab` to the front, from the tab strip or from its key.
    func show(_ tab: MainTab) {
        self.tab = tab
        if tab == .files && fileRows.isEmpty {
            refreshFileRows(immediately: true)
        }
    }

    // MARK: - Search

    /// What the filter was read as, for the File View to say what it made of
    /// it.
    var fileSearch: SearchQuery { SearchQuery(fileQuery) }

    /// ⌘F: brings the File View to the front with the keyboard in its filter.
    func beginSearch() {
        show(.files)
        filterWantsFocus = true
        filterFocusCount += 1
    }

    /// Whether the filter has been asked to take the keyboard since it last
    /// did. Asking is answering: the next call says no.
    func takeFilterFocus() -> Bool {
        defer { filterWantsFocus = false }
        return filterWantsFocus
    }

    /// Empties the filter, and the list goes back to what it was without it.
    func clearSearch() {
        guard !fileQuery.isEmpty else { return }
        fileQuery = ""
        refreshFileRows(immediately: true)
    }

    // MARK: - File type in focus

    /// `focusedType` as the number a file of that type carries, which is what
    /// the treemap and the File View's walk compare against.
    var focusedTypeIndex: Int? {
        focusedType.flatMap { result?.typeIndex(for: $0) }
    }

    /// The focused type's totals, for whatever names it on screen.
    var focusedTypeStat: ExtensionStat? {
        focusedType.flatMap { result?.stat(for: $0) }
    }

    /// The types the legend lists: the largest by the measure on show, or
    /// all of them, and in either case the one in focus.
    ///
    /// The one in focus is kept in the list wherever it ranks. It can be
    /// outside the largest few — picked from the full list, or ranked there
    /// by the other measure — and a list without it had nothing selected
    /// while the map stayed dim and the File View stayed narrowed.
    var legendTypes: [ExtensionStat] {
        guard let result else { return [] }
        let logical = sizeMetric == .logical
        if listsEveryType {
            return logical ? result.allBySize : result.allByAllocated
        }
        let top = logical ? result.topBySize : result.topByAllocated
        guard let focused = focusedTypeStat,
            !top.contains(where: { $0.ext == focused.ext })
        else { return top }
        return top + [focused]
    }

    /// Whether a type has anything to put in focus.
    ///
    /// Not whether it has files. A second name for a hard-linked file is
    /// counted under its own type and takes no space there: its bytes are
    /// with the name the scan reached first, which may be another type. A
    /// type made of nothing else has no tile on the map and no row in the
    /// File View, and in focus would turn the one dark and the other empty.
    private func canFocus(on ext: String) -> Bool {
        guard let stat = result?.stat(for: ext), stat.count > 0 else { return false }
        return stat.size > 0 || stat.alloc > 0
    }

    /// Puts `ext` in focus, or takes the focus off with nil.
    ///
    /// A type with nothing to show can't be focused on: the map would go
    /// dark all over and the File View would empty, with nothing in the
    /// legend to say which row had done it.
    func focusType(_ ext: String?) {
        let next = ext.flatMap { canFocus(on: $0) ? $0 : nil }
        guard next != focusedType else { return }
        focusedType = next
        // A different list, not the same one filtered: the largest thousand
        // of one type are mostly files the whole scan's thousand left out.
        refreshFileRows(immediately: true)
    }

    // MARK: - Choices that outlast a launch
    //
    // Recorded by these and not by assigning the properties, as with the
    // treemap: the headless renderer sets a measure and a folder for one
    // picture, and that must not rewrite what was chosen in the app.

    /// The Size / On Disk control.
    func chooseMetric(_ metric: SizeMetric) {
        sizeMetric = metric
        Preferences.sizeMetric = metric
    }

    /// A volume picked in the Select list, in place of whatever folder was
    /// being scanned.
    func chooseVolume(_ path: String) {
        customFolder = nil
        selectedVolumePath = path
        Preferences.lastVolume = path
        Preferences.lastFolder = nil
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

    /// Whether the folder picker can be put up: not during a scan or a
    /// delete, not over a question that is waiting for an answer, and not
    /// while it is already up.
    ///
    /// It has a key now, and a key reaches the menu from under a panel. A
    /// second ⌘O put a second panel over the first, and cancelling that one
    /// took the guard below off while the first was still up — which is what
    /// keeps ⌘⌫ in the panel from trashing the selection behind it.
    var canChooseFolder: Bool {
        canStartScan && !isChoosingFolder && permanentDeleteTargets.isEmpty
            && actionError == nil && !showsWelcome
    }

    func chooseFolder() {
        guard canChooseFolder else { return }
        // The panel has a ⌘⌫ of its own, for the file selected in it.
        isChoosingFolder = true
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to analyze"
        let answer = panel.runModal()
        // Before the scan is asked for, which is refused while this is set.
        isChoosingFolder = false
        guard answer == .OK, let url = panel.url else { return }
        scanFolder(url.path)
    }

    /// Makes `path` the folder to scan, remembers it for the next launch,
    /// and scans it: what choosing one in the panel comes to.
    func scanFolder(_ path: String) {
        customFolder = path
        Preferences.lastFolder = path
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
    ///
    /// Nor with the folder picker up. A key reaches the menu from under it,
    /// and ⌘R there scanned what was being left: the folder then chosen
    /// was named in the header over a tree that was not of it.
    var canStartScan: Bool { phase != .scanning && !isDeleting && !isChoosingFolder }

    func startScan() {
        guard canStartScan else { return }
        let path = scanTargetPath

        // The tree a move to the Trash would be put back into is about to go.
        forgetUndo()
        // Taken before anything below lets go of the tree it describes.
        // With no tree to take it from — the last scan of this folder was
        // stopped, or failed — what that scan was to put back still stands.
        let held = placeToRestore.flatMap {
            $0.rootPath == ScanEngine.normalize(path) ? $0 : nil
        }
        placeToRestore = place(forScanOf: path) ?? held
        marksLostToRescan = 0

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
        fileTally = nil
        selection = []
        // A delete still awaiting confirmation names items in the tree being
        // thrown away, so it goes with the selection. So do the marks.
        permanentDeleteTargets = []
        setMarks([])
        // A type is a row of the scan being thrown away; the next scan may
        // not have it at all.
        focusedType = nil
        previewURL = nil
        sharedStorageCache = [:]
        capacityAfterDelete = nil
        treemapRoot = nil
        treemapOutline = nil
        revealTarget = nil
        revealIsWaiting = false
        expanded.removeAll()
        progress = ScanEngine.Progress()
        // A volume's own root is the one target whose size is known ahead.
        scanGoal = 0
        if customFolder == nil {
            let capacity = VolumeInfo.capacity(of: path)
            if capacity.total > capacity.free {
                scanGoal = capacity.total - capacity.free
            }
        }
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

        // Kept when the scan did not land. It is paths and no part of any
        // tree, so it is as good for the next scan of the same folder: let
        // go of here, ⌘R and then Stop emptied the marks for good, which is
        // what keeping a place across a rescan was to put an end to.
        let place = placeToRestore
        if case .completed = outcome { placeToRestore = nil }

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
        // What this scan found in the Trash is in its totals, and is no
        // longer space that has left them: a scan of a home folder reads
        // its Trash, and the line went on counting it a second time.
        if !sessionTrash.isEmpty {
            sessionTrash.removeAll { entry in
                // Spelled as the scan spells it: with every link in the
                // folders above it followed, and it itself left as it is.
                let inTrash = entry.receipt.inTrash as NSString
                let path = ScanEngine.join(
                    ScanEngine.normalize(inTrash.deletingLastPathComponent),
                    inTrash.lastPathComponent
                )
                // Counted, and not merely found: a folder the scan could
                // not read, or read part of, is in the tree with what it
                // holds still missing from the totals.
                return scanned.hasCounted(at: path)
            }
            refreshTrashLine()
        }
        treemapRoot = scanned.root
        selection = [NodeRef(scanned.root)]
        // Open the root so the biggest folders are visible immediately.
        expanded.removeAll()
        expanded.insert(scanned.root)
        if let place, place.rootPath == scanned.rootPath {
            restore(place, in: scanned)
        }
        rebuildTreeRows()
        refreshFileRows(immediately: true)
    }

    /// How the window stands now, if `path` is the folder already on show.
    /// Nil for a scan of anywhere else, which starts afresh.
    private func place(forScanOf path: String) -> Place? {
        guard let result, result.rootPath == ScanEngine.normalize(path) else {
            return nil
        }
        var place = Place(rootPath: result.rootPath)
        place.open = expanded.paths
        place.zoom = treemapRoot.flatMap { $0.isCutOff ? nil : $0.path }
        place.selection = selection.filter { !$0.isStale }.map { Spot($0) }
        place.marks = marks.filter { !$0.isStale }.map { Spot($0) }
        place.focusedType = focusedType
        place.showsMarks = showsMarks
        return place
    }

    /// Puts back what `place` holds of it that the new scan still has.
    private func restore(_ place: Place, in scan: ScanResult) {
        // Only what was open, the root included: one that had been shut
        // comes back shut, and not opened for being the root of a new scan.
        expanded.removeAll()
        for path in place.open {
            if let dir = scan.directory(at: path) { expanded.insert(dir) }
        }
        if let zoom = place.zoom, let dir = scan.directory(at: zoom), !dir.isEmpty {
            treemapRoot = dir
        }
        let selected = place.selection.compactMap { $0.find(in: scan) }
        if !selected.isEmpty { selection = Set(selected) }

        // Through `setMarked`, so one whose item can no longer be removed is
        // refused as it would be for a click.
        setMarked(Set(place.marks.compactMap { $0.find(in: scan) }), true)
        marksLostToRescan = place.marks.count - marks.count
        showsMarks = place.showsMarks && !marks.isEmpty

        if let type = place.focusedType, canFocus(on: type) { focusedType = type }
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
        expanded.contains(dir)
    }

    func toggleExpansion(_ dir: DirNode) {
        if expanded.contains(dir) {
            expanded.remove(dir)
        } else {
            expanded.insert(dir)
        }
        rebuildTreeRows()
    }

    func setExpanded(_ dir: DirNode, _ isOpen: Bool) {
        if isOpen { expanded.insert(dir) } else { expanded.remove(dir) }
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
        for dir in chain { expanded.insert(dir) }
        selection = [ref]
        rebuildTreeRows()
        scrollTree(to: ref)
    }

    /// Asks the Tree View to bring `ref`'s row into view.
    private func scrollTree(to ref: NodeRef) {
        revealTarget = ref
        revealIsWaiting = true
        revealCount += 1
    }

    /// Whether `ref` is still the row last asked for, and still selected:
    /// the test a scroll that was put off has to pass when its time comes.
    /// A rescan, a delete of the row, another reveal or a click elsewhere
    /// all fail it. Selected, not all that is: several things put back at
    /// once are all selected, and one of them is scrolled to.
    func isStillRevealing(_ ref: NodeRef) -> Bool {
        revealTarget == ref && selection.contains(ref) && !ref.isStale
    }

    /// The row waiting to be scrolled to, if one is. Asking is answering: it
    /// stops waiting.
    ///
    /// Put to the same test as a scroll that was put off. One asked for
    /// with the Tree View out of sight waits for it to come back, which can
    /// be many clicks later, and the tree then opened scrolled to a row
    /// that was no longer what was selected.
    func takeRevealTarget() -> NodeRef? {
        guard revealIsWaiting else { return nil }
        revealIsWaiting = false
        guard let ref = revealTarget, isStillRevealing(ref) else { return nil }
        return ref
    }

    /// Selects a tile clicked on the treemap, and brings its row into view
    /// when it has one.
    ///
    /// Folders are not opened to give it one: a click on the map is a look
    /// at something, and a tree that unfolded a level with every look would
    /// soon be all unfolded.
    func select(fromMap ref: NodeRef) {
        selection = [ref]
        if isTreeRow(ref) { scrollTree(to: ref) }
    }

    // MARK: - Tree keys
    //
    // → and ←, as an outline answers them everywhere else on the Mac. The
    // tree is a flat table of rows with a chevron drawn in each, so a folder
    // opened only to a click on that chevron or a double-click on its row,
    // and someone working down the list with ↑ and ↓ had to reach for the
    // mouse at every folder.

    /// The selected rows the Tree View has on show.
    private var selectedTreeRows: [NodeRef] {
        selection.filter { !$0.isStale && isTreeRow($0) }
    }

    /// →: opens every selected folder that is shut. With one folder selected
    /// and already open, steps down to the first thing in it. False when
    /// there was nothing to do, so the key can go on to whatever wants it.
    @discardableResult
    func expandSelection() -> Bool {
        let rows = selectedTreeRows
        let shut = rows.filter {
            $0.isDirectory && !$0.dir.isEmpty && !expanded.contains($0.dir)
        }
        if !shut.isEmpty {
            for ref in shut { expanded.insert(ref.dir) }
            rebuildTreeRows()
            return true
        }
        guard rows.count == 1, let only = rows.first, only.isDirectory,
            let at = treeRows.firstIndex(where: { $0.ref == only }),
            at + 1 < treeRows.count, treeRows[at + 1].depth > treeRows[at].depth
        else { return false }
        let first = treeRows[at + 1].ref
        selection = [first]
        scrollTree(to: first)
        return true
    }

    /// ←: shuts every selected folder that is open. With one row selected
    /// that is not an open folder, steps out to the folder it is in.
    @discardableResult
    func collapseSelection() -> Bool {
        let rows = selectedTreeRows
        let open = rows.filter { $0.isDirectory && expanded.contains($0.dir) }
        if !open.isEmpty {
            for ref in open { expanded.remove(ref.dir) }
            rebuildTreeRows()
            return true
        }
        guard rows.count == 1, let only = rows.first, let parent = rowParent(only)
        else { return false }
        selection = [NodeRef(parent)]
        scrollTree(to: NodeRef(parent))
        return true
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
        let hasChildren = !dir.isEmpty
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
        for index in dir.files.indices where !dir.files[index].isRemoved {
            children.append(NodeRef(dir: dir, fileIndex: index))
        }
        // Rows the order can't tell apart stay as they were listed. Left to
        // the sort, which promises nothing about them, a delete elsewhere in
        // the folder could swap two files of one size.
        children = children.enumerated().sorted { a, b in
            switch sort.compare(a.element, b.element) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }.map(\.element)

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
            fileTally = nil
            return
        }
        let query = fileQuery
        let search = SearchQuery(query)
        let metric = sizeMetric
        let type = focusedType
        let typeIndex = focusedTypeIndex
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
            let found = result.search(
                search,
                ofType: typeIndex,
                limit: 1000,
                metric: metric,
                token: token
            )
            let rootTotal = result.root.bytes(using: metric)
            let rows = found.rows.map {
                FileRow($0, metric: metric, rootTotal: rootTotal)
            }
            let tally = found.matches.map {
                SearchTally(matches: $0, folders: found.folders, bytes: found.bytes)
            }
            DispatchQueue.main.async {
                // Only the newest walk delivers. One that had finished its pass
                // before being replaced would otherwise land first, with rows
                // built for a metric no longer on show, and stop the spinner
                // while the real answer was still on its way.
                guard let self, self.fileWalkToken === token,
                    self.fileQuery == query, self.focusedType == type,
                    self.treeRevision == revision, self.result === source
                else { return }
                self.fileRowsAnswer = (query, type)
                self.fileRows = self.inFileOrder(rows)
                self.fileTally = tally
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
        fileRows = inFileOrder(fileRows)
    }

    /// `rows` in the order the File View is sorted by, with those it can't
    /// tell apart left in the order they came in — which, fresh from a walk,
    /// is the order the walk found them in. The sort alone promises nothing
    /// about rows that compare equal, and files of one size are common.
    private func inFileOrder(_ rows: [FileRow]) -> [FileRow] {
        let comparators = fileSort
        return rows.enumerated().sorted { a, b in
            for comparator in comparators {
                switch comparator.compare(a.element, b.element) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return a.offset < b.offset
        }.map(\.element)
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

    /// The folders from the scan's root down to the one the map is zoomed
    /// to, for the path above the map: each is somewhere to zoom back out to.
    var zoomTrail: [DirNode] {
        var chain: [DirNode] = []
        var node = treemapRoot
        while let current = node {
            chain.append(current)
            node = current.parent
        }
        return chain.reversed()
    }

    func zoom(into dir: DirNode) {
        guard !dir.isEmpty else { return }
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

    /// Stops a running batch: at the next file for a delete, which can be
    /// part-way through a folder, and after the item in hand for a move to
    /// the Trash, which is a single step.
    func cancelDelete() {
        deleteTask?.cancel()
        deleteStop?.request()
    }

    func moveToTrash(_ ref: NodeRef) { moveToTrash([ref]) }

    func moveToTrash(_ refs: Set<NodeRef>) { performBatch(on: refs, as: .trash) }

    func deletePermanently(_ ref: NodeRef) { deletePermanently([ref]) }

    func deletePermanently(_ refs: Set<NodeRef>) {
        performBatch(on: refs, as: .delete)
    }

    /// Whether `ref` is on its way out with the batch in hand, itself or
    /// inside a folder that is.
    func isBeingRemoved(_ ref: NodeRef) -> Bool {
        guard !removing.isEmpty else { return false }
        if removing.contains(ref) { return true }
        var above: DirNode? = ref.isDirectory ? ref.dir.parent : ref.dir
        while let step = above {
            if removing.contains(NodeRef(step)) { return true }
            above = step.parent
        }
        return false
    }

    /// The status line's figures for a batch in hand: how many of the files
    /// and folders the scan counted have gone, and the space they held.
    ///
    /// The space stops at what the scan counted. A hard link's bytes are
    /// counted under one of its names and removing any of them reports the
    /// lot, so the running figure can pass a total it was never part of.
    func deleteSummary(_ progress: DeleteProgress) -> String {
        let items =
            "\(ByteFormat.count(min(progress.items, progress.itemsTotal))) of "
            + ByteFormat.counted(progress.itemsTotal, "item")
        // Nothing to say about space when what is going takes none: a folder
        // of empty files read "0 bytes of 0 bytes" the whole way through.
        guard progress.bytesTotal > 0 else { return items }
        return items + "  •  "
            + "\(ByteFormat.decimal(min(progress.bytes, progress.bytesTotal))) of "
            + ByteFormat.decimal(progress.bytesTotal)
    }

    // MARK: - Marks
    //
    // What has been picked out for removal, kept apart from the selection.
    // The selection is what is being looked at: one plain click replaces it,
    // and a collapsed folder or a change of tab takes it off the screen. A
    // mark stays where it was put until it is taken off or acted on, so items
    // from different folders can be gathered up, looked over, and removed
    // together.

    /// How an item stands with the marks.
    enum MarkState {
        /// Not marked, and holding nothing that is.
        case none
        /// Marked itself.
        case marked
        /// Inside a folder that is marked, and so going with it.
        case covered
        /// A folder with something marked inside it.
        case partial
    }

    func markState(_ ref: NodeRef) -> MarkState {
        guard !marks.isEmpty else { return .none }
        if marks.contains(ref) { return .marked }
        var above: DirNode? = ref.isDirectory ? ref.dir.parent : ref.dir
        while let step = above {
            if marks.contains(NodeRef(step)) { return .covered }
            above = step.parent
        }
        if ref.isDirectory, marksBeneath[ref.dir.id, default: 0] > 0 {
            return .partial
        }
        return .none
    }

    /// False for what may not be removed at all — a scan's root, a volume or
    /// home folder, the sealed system volume. A mark there would be a promise
    /// the delete then broke.
    func canMark(_ ref: NodeRef) -> Bool {
        !ref.isStale && deletionRefusal(for: ref) == nil
    }

    /// Marks `refs`, or takes their marks off when every one of them that can
    /// carry a mark already does — what a checkbox over several rows does.
    func toggleMarks(_ refs: Set<NodeRef>) {
        let eligible = refs.filter { canMark($0) && markState($0) != .covered }
        guard !eligible.isEmpty else { return }
        setMarked(eligible, !eligible.allSatisfy(marks.contains))
    }

    /// Puts marks on `refs` or takes them off.
    ///
    /// A folder's mark stands for everything in it. So a mark on something
    /// already inside a marked folder is not added, marks beneath a folder
    /// that is being marked are dropped, and a folder given together with its
    /// own contents is marked once — which keeps the marks from ever nesting,
    /// and the list of them from counting anything twice.
    ///
    /// Not while a batch runs. One started from the marks took them as they
    /// stood, and a mark taken off after that would leave the list one short
    /// of what is being removed.
    func setMarked(_ refs: Set<NodeRef>, _ marked: Bool) {
        guard !isDeleting else { return }
        var next = marks
        if marked {
            for ref in distinctTargets(refs)
            where canMark(ref) && markState(ref) != .covered {
                if ref.isDirectory {
                    next = next.filter { !Self.isWithin($0, ref.dir) }
                }
                next.insert(ref)
            }
        } else {
            next.subtract(refs)
        }
        setMarks(next)
    }

    /// Takes every mark off — again, not while a batch runs.
    func clearMarks() {
        guard !isDeleting else { return }
        setMarks([])
    }

    /// Whether Space and the menu have anything to mark: what is selected and
    /// on show, as for the delete keys, less whatever can't carry a mark.
    var canMarkSelection: Bool {
        guard !isEditingFilter, !isDeleting, !showsWelcome else { return false }
        let onShow = isOnShow
        // Cheapest first: `canMark` builds a path, and this is asked on
        // every publish.
        return selection.contains { ref in
            onShow(ref) && markState(ref) != .covered && canMark(ref)
        }
    }

    /// True when marking the selection would take marks off: every part of
    /// it that is on show and can carry a mark already does. For the menu's
    /// wording.
    var selectionIsMarked: Bool {
        let onShow = isOnShow
        guard selection.contains(where: { marks.contains($0) && onShow($0) })
        else { return false }
        return !selection.contains { ref in
            onShow(ref) && !marks.contains(ref) && markState(ref) != .covered
                && canMark(ref)
        }
    }

    /// Marks what is selected and on show, or takes those marks off. False
    /// when there was nothing to act on, so the key can go on to something
    /// else that wants it.
    @discardableResult
    func markSelection() -> Bool {
        guard canMarkSelection else { return false }
        toggleMarks(selectionOnShow)
        return true
    }

    /// The one place the marks are assigned, so the count kept beneath each
    /// folder can't fall out of step with them.
    private func setMarks(_ next: Set<NodeRef>) {
        guard next != marks else { return }
        marks = next
        var beneath: [UInt64: Int] = [:]
        for ref in next {
            var above: DirNode? = ref.isDirectory ? ref.dir.parent : ref.dir
            while let step = above {
                beneath[step.id, default: 0] += 1
                above = step.parent
            }
        }
        marksBeneath = beneath
        // Nothing left to list, so the list is put away and starts shut the
        // next time something is marked.
        if next.isEmpty { showsMarks = false }
    }

    /// Whether `ref` is somewhere inside `dir`.
    private static func isWithin(_ ref: NodeRef, _ dir: DirNode) -> Bool {
        var above: DirNode? = ref.isDirectory ? ref.dir.parent : ref.dir
        while let step = above {
            if step === dir { return true }
            above = step.parent
        }
        return false
    }

    /// The marks as the list shows them: biggest first by the measure on
    /// show, and by name where that ties.
    var markedItems: [NodeRef] {
        marks.sorted { a, b in
            let (left, right) = (a.bytes(using: sizeMetric), b.bytes(using: sizeMetric))
            if left != right { return left > right }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// What removing every mark would give back: space on disk, whatever
    /// measure is on show, with a hard link's bytes left out where another
    /// name would keep them there.
    ///
    /// The same figure the delete confirmation gives, and for the same
    /// reason. It sits beside a button that removes without asking again, and
    /// in lengths it would promise back the whole of a sparse image that
    /// occupies a fraction of it.
    var markedBytes: UInt64 { reclaimableSpace(marks) }

    /// How many are marked, as the bar beside the tabs says it.
    var marksHeadline: String {
        ByteFormat.counted(marks.count, "item") + " marked for removal"
    }

    /// Moves every marked item to the Trash. Unasked, like ⌘⌫: each was
    /// marked by hand, the bar beside the button says how many and how much,
    /// and ⌘Z brings them back.
    func trashMarked() {
        guard !isDeleting, !marks.isEmpty else { return }
        moveToTrash(marks)
    }

    /// Asks before deleting every marked item for good.
    func confirmDeletingMarked() {
        guard !isDeleting, !marks.isEmpty else { return }
        permanentDeleteTargets = marks
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
            // Rows left over from the search before, or from another type,
            // are on screen and are not what the bar above them says is
            // listed: the chip already read ".dmg only" over a folder a
            // search had found, still selected, and ⌘⌫ took the folder.
            // Until the walk comes back there is nothing on show to act on.
            guard fileRowsAnswer.query == fileQuery,
                fileRowsAnswer.type == focusedType
            else { return { _ in false } }
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
            guard expanded.contains(step) else { return false }
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
    /// filter or the folder picker holding the keyboard, the guide over the
    /// window — which names these keys, to someone who cannot see what is
    /// selected behind it.
    var canUseDeleteKeys: Bool {
        !isDeleting && !isEditingFilter && !isChoosingFolder
            && permanentDeleteTargets.isEmpty && actionError == nil
            && !showsWelcome
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
        // A reference to something that has since been deleted, or that was
        // in a folder that has, names nothing, so it is dropped rather than
        // acted on.
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

    /// What a batch does with each of its targets.
    private enum Disposal {
        /// Moved to the Trash. The name leaves the tree and is still a name
        /// for its inode, so whatever shared storage with it still does.
        case trash
        /// Removed outright.
        case delete

        var unlinks: Bool { self == .delete }
    }

    /// A target of a batch, as the thread doing the removing is handed it.
    ///
    /// Sent across on the batch's say-so. Nothing changes the tree while a
    /// batch runs — the batch itself only does once it is back on the main
    /// actor, and a scan can't start until then — so it is safe to read from
    /// there, and reading is all the removal does with it.
    private struct Target: @unchecked Sendable {
        let ref: NodeRef
        let path: String
    }

    /// How one target came out.
    private struct Disposed: @unchecked Sendable {
        /// What has left the disk: the target, or, where only part of a
        /// folder went, the files and folders in it that did.
        var gone: [NodeRef] = []
        var failure: (title: String, detail: String)?
        var tally = Removal.Tally()
        /// What it takes to bring the target back, when it went to the
        /// Trash and the Trash said where.
        var receipt: FileActions.TrashReceipt?
    }

    /// Runs a delete batch off the main actor, reporting progress as it goes.
    ///
    /// Removing a large tree is tens of seconds to minutes of `unlink(2)`.
    /// Run on the main actor — which is where every caller of this is — it
    /// stopped the run loop for the whole of that: no spinner, no progress, no
    /// cancel, and long enough that the responsiveness watchdog could kill the
    /// app part-way and leave a half-removed tree behind totals that were never
    /// updated.
    ///
    /// One target at a time rather than concurrently: the batch is already
    /// deduplicated to non-overlapping subtrees, and deleting several huge trees
    /// at once only makes the disk seek more.
    private func performBatch(on refs: Set<NodeRef>, as disposal: Disposal) {
        // One batch at a time. A second started mid-flight would resolve its
        // paths against a tree the first is still changing.
        guard deleteTask == nil else { return }

        // Paths are resolved up front, on the main actor, where the folders
        // above each target are known to be alive.
        let targets = distinctTargets(refs).map { Target(ref: $0, path: $0.path) }
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

        deleteBatch += 1
        let batch = deleteBatch
        let stop = Removal.Stop()
        deleteStop = stop
        deleteProgress = DeleteProgress(
            done: 0,
            total: allowed.count,
            currentName: (allowed[0].path as NSString).lastPathComponent,
            itemsTotal: allowed.reduce(0) { $0 + Self.scanned($1.ref).items },
            bytesTotal: allowed.reduce(0) { $0 + Self.scanned($1.ref).bytes }
        )
        let attempted = targets.count
        let onTheirWayOut = Set(allowed.map(\.ref))
        let mover = trashMover

        deleteTask = Task { [weak self] in
            // The rows are set back only once the batch has outlasted a
            // glance, so the quick ones go without a flash of grey first.
            let grace = self?.removingGrace ?? 0
            let dimming = Task { [weak self] in
                try? await Task.sleep(nanoseconds: grace)
                guard let self, !Task.isCancelled, self.deleteBatch == batch,
                    self.isDeleting
                else { return }
                self.removing = onTheirWayOut
            }

            var gone: [NodeRef] = []
            var failures: [(title: String, detail: String)] = []
            var finished = Removal.Tally()
            var trashed: [(target: Target, receipt: FileActions.TrashReceipt)] = []
            var beyondUndo: [String] = []

            for (index, target) in allowed.enumerated() {
                // Checked between items as well as inside one: a move to the
                // Trash is a single step with nowhere to stop in the middle.
                if Task.isCancelled { break }

                let before = finished
                let disposed = await Task.detached(priority: .userInitiated) {
                    Self.dispose(of: target, as: disposal, by: mover, stop: stop) { tally in
                        let total = Removal.Tally(
                            items: before.items + tally.items,
                            bytes: before.bytes + tally.bytes
                        )
                        DispatchQueue.main.async { [weak self] in
                            self?.noteProgress(total, of: batch)
                        }
                    }
                }.value

                gone.append(contentsOf: disposed.gone)
                if let receipt = disposed.receipt {
                    trashed.append((target, receipt))
                } else if disposal == .trash, !disposed.gone.isEmpty {
                    beyondUndo.append((target.path as NSString).lastPathComponent)
                }
                if let failure = disposed.failure { failures.append(failure) }
                finished.items += disposed.tally.items
                finished.bytes += disposed.tally.bytes

                guard let self else { return }
                if var progress = self.deleteProgress {
                    progress.done = index + 1
                    progress.currentName =
                        index + 1 < allowed.count
                        ? (allowed[index + 1].path as NSString).lastPathComponent
                        : ""
                    progress.items = finished.items
                    progress.bytes = finished.bytes
                    self.deleteProgress = progress
                }
            }

            dimming.cancel()
            guard let self else { return }
            self.deleteTask = nil
            self.deleteStop = nil
            self.deleteProgress = nil
            self.removing = []
            // What went is applied even when part of the batch failed or was
            // stopped, so the tree never claims space that is already gone.
            //
            // Noted first, while the tree still holds what is leaving it.
            let moved = self.note(trashed)
            let weight = gone.reduce(UInt64(0)) { $0 + $1.alloc }
            let before = self.result?.root.totalAlloc ?? 0
            // Whatever was last moved to the Trash can no longer be put back
            // as it was once the tree around it has changed — which is now,
            // and only if this batch removed something. One that removed
            // nothing leaves the move before it as undoable as it was.
            if !gone.isEmpty { self.forgetUndo() }
            self.detach(gone, unlinked: disposal.unlinks)
            let after = self.result?.root.totalAlloc ?? 0
            self.offerUndo(of: moved, taking: before - min(before, after), of: weight)
            self.rereadCapacity()
            self.report(
                failures: failures,
                refusals: refusals,
                attempted: attempted
            )
            self.report(beyondUndo: beyondUndo)
        }
    }

    /// Says so when something has gone to the Trash and can't be brought
    /// back from here: the Trash did not say where it went, or what is there
    /// can't be seen to be it. ⌘⌫ asks nothing on the understanding that it
    /// can be undone, and these went with no Undo offered and not a word
    /// said.
    private func report(beyondUndo names: [String]) {
        guard let first = names.first else { return }
        let title =
            names.count == 1
            ? "Undo can’t bring back “\(first)”"
            : "Undo can’t bring back \(ByteFormat.count(names.count)) items"
        let detail =
            "The move to the Trash went through, but where in the Trash "
            + "could not be confirmed, so Undo is not offered for it. What "
            + "was moved can still be taken back out of the Trash by hand."
        guard actionError != nil else {
            actionError = title
            actionErrorDetail = detail
            return
        }
        // Under whatever else the batch had to say, not in place of it.
        actionErrorDetail = [actionErrorDetail, "\(title). \(detail)"]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    // MARK: - Undoing a move to the Trash
    //
    // ⌘⌫ and the list of marks both move to the Trash without asking, on the
    // understanding that the Trash is not the end. From here it was: the app
    // threw away where each item went, and nothing could bring it back.

    /// Takes down what it will take to bring `trashed` back, before the tree
    /// lets go of it.
    private func note(
        _ trashed: [(target: Target, receipt: FileActions.TrashReceipt)]
    ) -> [Trashed] {
        trashed.map { item in
            let ref = item.target.ref
            var held: [NodeRef] = []
            if marks.contains(ref) {
                held = [ref]
            } else if ref.isDirectory, marksBeneath[ref.dir.id, default: 0] > 0 {
                held = marks.filter { Self.isWithin($0, ref.dir) }
            }
            return Trashed(
                ref: ref,
                path: item.target.path,
                receipt: item.receipt,
                entry: ref.file,
                parent: ref.isDirectory ? ref.dir.parent : nil,
                weight: ref.alloc,
                marks: held
            )
        }
    }

    /// Makes `moved` the move that Undo undoes, and adds it to what the
    /// Trash is holding.
    ///
    /// `left` is what the batch took off the scan's total, and `weight` what
    /// everything it removed weighed. What the Trash is said to hold is what
    /// left the totals — worked out from the totals, and shared out among
    /// what was moved. Asked of each item on its own it came out wrong for
    /// hard links: both names of a file moved together are each a name that
    /// frees nothing, and between them were all of it.
    private func offerUndo(of moved: [Trashed], taking left: UInt64, of weight: UInt64) {
        guard !moved.isEmpty else { return }
        // What was already there is looked at before this move joins it. A
        // name that has gone hands what it was down for to another name of
        // the same file, and that is told by number: something new must not
        // arrive holding the number of something that has just gone.
        refreshTrashLine()
        lastTrash = moved
        lastTrashTook = left
        canUndoTrash = true
        sessionTrash += Self.shares(of: left, among: moved, weighing: weight)
        refreshTrashLine()
        registerUndo()
    }

    /// `bytes` shared out among `items` by what each weighed, out of
    /// `weight` in all — or evenly, where nothing weighed anything.
    private static func shares(
        of bytes: UInt64,
        among items: [Trashed],
        weighing weight: UInt64
    ) -> [(receipt: FileActions.TrashReceipt, bytes: UInt64)] {
        items.map { item in
            let share =
                weight > 0
                ? Double(item.weight) / Double(weight) : 1 / Double(items.count)
            return (item.receipt, UInt64((Double(bytes) * share).rounded()))
        }
    }

    /// Puts the move back on the window's undo stack, as "Move to Trash".
    private func registerUndo() {
        guard canUndoTrash, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.undoFromTheMenu() }
        }
        undoManager.setActionName("Move to Trash")
    }

    /// Edit ▸ Undo, which takes the move off its stack as it asks. While a
    /// scan or a removal is running the answer is not now, and the move is
    /// put back to be asked for again — on the next turn of the loop, since
    /// anything registered while an undo is under way is taken for a redo.
    private func undoFromTheMenu() {
        guard canUndoTrash else { return }
        guard !isDeleting, phase != .scanning else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canUndoTrash else { return }
                self.registerUndo()
            }
            return
        }
        undoTrash()
    }

    /// Lets go of the move that could have been undone.
    private func forgetUndo() {
        lastTrash = []
        lastTrashTook = 0
        if canUndoTrash { canUndoTrash = false }
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Adds up what is still where it was put in the Trash. Something that
    /// is not has been put back or emptied out, and is forgotten.
    func refreshTrashLine() {
        var held: [(receipt: FileActions.TrashReceipt, bytes: UInt64)] = []
        var left: [(item: FileActions.FileIdentity, bytes: UInt64)] = []
        var unanswered = false
        for entry in sessionTrash {
            // Kept unless it is known to have gone. A disk that does not
            // answer has not said so, and letting go here lets go of the
            // Undo below as well.
            switch entry.receipt.presence {
            case .there:
                held.append(entry)
            case .unknown:
                held.append(entry)
                unanswered = true
            case .gone:
                if entry.bytes > 0 { left.append((entry.receipt.item, entry.bytes)) }
            }
        }
        looksUnanswered = unanswered ? looksUnanswered + 1 : 0
        // Another name of the same file that is still in the Trash holds
        // all of it. Two names moved together were each put down for half,
        // and deleting one of them there took its half off the line with
        // every byte still on the disk under the other.
        for gone in left {
            if let other = held.firstIndex(where: { $0.receipt.item == gone.item }) {
                held[other].bytes += gone.bytes
            }
        }
        sessionTrash = held
        let total = sessionTrash.reduce(UInt64(0)) { $0 + $1.bytes }
        if total != bytesInTrash { bytesInTrash = total }

        // With none of the last move left in the Trash there is nothing for
        // Undo to bring back, and the button went on offering to.
        if canUndoTrash {
            let places = Set(held.map(\.receipt.inTrash))
            if !lastTrash.contains(where: { places.contains($0.receipt.inTrash) }) {
                forgetUndo()
            }
        }

        // A look at a handful of paths, and only while there are any. Not
        // while part of the Trash goes on not answering, either: each look
        // at a share that has dropped can wait out its timeout, on the main
        // thread, and kept waiting it out every three seconds. After a few
        // it is left to coming to the front, and to Undo, to look again.
        if sessionTrash.isEmpty || looksUnanswered >= 3 {
            trashWatch = nil
        } else if trashWatch == nil {
            trashWatch = Timer.publish(every: 3, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.refreshTrashLine() }
        }
    }

    /// Where in the Trash each of those is, for a check to empty it from.
    var trashedLocations: [URL] {
        sessionTrash.map { URL(fileURLWithPath: $0.receipt.inTrash) }
    }

    /// The status bar's line for it.
    var trashLine: String { "In the Trash \(ByteFormat.decimal(bytesInTrash))" }

    /// ⌘Z: brings back what the last move to the Trash moved, on disk and in
    /// the tree.
    ///
    /// Each item goes back on its own. One that can't — its place has been
    /// taken, or the Trash has been emptied — stays where it is and is
    /// named; the rest come back.
    func undoTrash() {
        guard canUndoTrash, !isDeleting, phase != .scanning else { return }
        let batch = lastTrash
        let took = lastTrashTook
        forgetUndo()

        var back: [Trashed] = []
        var failures: [(name: String, reason: String)] = []
        var unreached = 0
        for item in batch {
            do {
                try FileActions.putBack(item.receipt, to: item.path)
                back.append(item)
            } catch {
                if case FileActions.PutBackError.unreachable = error { unreached += 1 }
                failures.append(
                    ((item.path as NSString).lastPathComponent, error.localizedDescription)
                )
            }
        }
        let before = result?.root.totalAlloc ?? 0
        reattach(back)
        let returned = (result?.root.totalAlloc ?? 0) - min(before, result?.root.totalAlloc ?? 0)

        // What stayed in the Trash holds what the move took off the totals
        // less what has just come back onto them, shared among what stayed.
        // Not each one's share from before: a second name for a file that
        // has come back under its other name holds nothing that is missing.
        let stayed = batch.filter { item in
            !back.contains { $0.receipt.inTrash == item.receipt.inTrash }
        }
        sessionTrash.removeAll { entry in
            batch.contains { $0.receipt.inTrash == entry.receipt.inTrash }
        }
        sessionTrash += Self.shares(
            of: took - min(took, returned),
            among: stayed,
            weighing: stayed.reduce(0) { $0 + $1.weight }
        )
        refreshTrashLine()
        rereadCapacity()

        // None of it could be reached, which is neither a move undone nor
        // one that can't be: it is still the move to undo, once the disk
        // answers. Put back on the stack a turn later, since anything
        // registered while an undo is under way is taken for a redo.
        if unreached == batch.count {
            lastTrash = batch
            lastTrashTook = took
            canUndoTrash = true
            DispatchQueue.main.async { [weak self] in self?.registerUndo() }
        }

        guard let first = failures.first else { return }
        actionError =
            failures.count == 1
            ? "Couldn’t put back “\(first.name)”"
            : "\(ByteFormat.count(failures.count)) of "
                + "\(ByteFormat.count(batch.count)) items couldn’t be put back"
        actionErrorDetail =
            failures.count == 1
            ? first.reason : "“\(first.name)”: \(first.reason)"
    }

    /// Puts what has come back out of the Trash back into the tree.
    ///
    /// The reverse of `detach`, one item at a time. What makes it more than
    /// that is hard links. Taking a name out can have handed its bytes to
    /// another name of the same file, and the name coming back is then the
    /// second one, not the one that carries them: so each hard-linked name
    /// is told which it is from the tree as it stands when it returns, and
    /// not from what it was when it left.
    private func reattach(_ items: [Trashed]) {
        guard !items.isEmpty, let result else { return }

        // As for a delete: nothing may be reading the tree while it changes.
        fileFilterWork?.cancel()
        fileFilterWork = nil
        fileWalkToken.cancel()
        treeQueue.sync {}
        treemapQueue.sync {}

        // The files coming back that share their storage with another name.
        var shared: Set<UInt64> = []
        for item in items {
            if let entry = item.entry {
                if entry.sharesStorage { shared.insert(entry.fileID) }
                continue
            }
            var stack: [DirNode] = [item.ref.dir]
            while let dir = stack.popLast() {
                for file in dir.files where !file.isRemoved && file.sharesStorage {
                    shared.insert(file.fileID)
                }
                stack.append(contentsOf: dir.subdirs)
            }
        }
        // Which of those already have a name in the tree carrying their
        // bytes, added to as each one coming back takes that part.
        var counted = result.countedNames(among: shared)

        var restored: [Trashed] = []
        for item in items {
            if let entry = item.entry {
                let dir = item.ref.dir
                let index = Int(item.ref.fileIndex)
                // The slot it left is where it goes. A folder that has gone
                // from the tree since has nowhere to put it.
                guard !dir.isCutOff, index < dir.files.count,
                    dir.files[index].isRemoved
                else { continue }
                var file = entry
                if file.sharesStorage {
                    file.isDuplicateLink = !counted.insert(file.fileID).inserted
                }
                dir.files[index] = file
                result.restoreType(of: file)
                addBack(
                    size: file.isDuplicateLink ? 0 : file.size,
                    alloc: file.isDuplicateLink ? 0 : file.alloc,
                    files: 1,
                    dirs: 0,
                    to: dir
                )
                restored.append(item)
            } else if let parent = item.parent {
                let node = item.ref.dir
                guard node.parent == nil, !parent.isCutOff else { continue }
                settleHardLinks(under: node, counted: &counted, in: result)
                parent.subdirs.append(node)
                node.parent = parent
                addBack(
                    size: node.totalSize,
                    alloc: node.totalAlloc,
                    files: node.totalFiles,
                    dirs: node.totalDirs + 1,
                    to: parent
                )
                restored.append(item)
            }
        }
        result.rankTypes()

        sharedStorageCache = [:]
        treeRevision += 1
        bringFolderRowsUpToDate()
        rebuildTreeRows()
        // What came back is what is selected, so it can be seen to be back,
        // and it has the marks it left with.
        let refs = Set(restored.map(\.ref))
        setMarked(Set(restored.flatMap(\.marks)), true)
        if !refs.isEmpty {
            selection = refs
            if let shown = restored.map(\.ref).first(where: isTreeRow) {
                scrollTree(to: shown)
            }
        }
        refreshFileRows(immediately: true)
    }

    /// Tells every hard-linked name under a folder coming back whether it is
    /// the one its file's bytes are counted under, puts the folder's own
    /// totals right where that has changed since it left, and puts its files
    /// back into their types.
    private func settleHardLinks(
        under node: DirNode,
        counted: inout Set<UInt64>,
        in result: ScanResult
    ) {
        var stack: [DirNode] = [node]
        while let dir = stack.popLast() {
            for index in dir.files.indices where !dir.files[index].isRemoved {
                var file = dir.files[index]
                if file.sharesStorage {
                    let isSecond = !counted.insert(file.fileID).inserted
                    if isSecond != file.isDuplicateLink {
                        file.isDuplicateLink = isSecond
                        dir.files[index] = file
                        // Up to the folder coming back and no further: it is
                        // not attached yet, and is added whole when it is.
                        var step: DirNode? = dir
                        while let folder = step {
                            if isSecond {
                                folder.totalSize -= min(folder.totalSize, file.size)
                                folder.totalAlloc -= min(folder.totalAlloc, file.alloc)
                            } else {
                                folder.totalSize += file.size
                                folder.totalAlloc += file.alloc
                            }
                            step = folder === node ? nil : folder.parent
                        }
                    }
                }
                result.restoreType(of: file)
            }
            stack.append(contentsOf: dir.subdirs)
        }
    }

    /// Walks what has come back up to the root: the reverse of `subtract`.
    private func addBack(
        size: UInt64,
        alloc: UInt64,
        files: Int,
        dirs: Int,
        to node: DirNode
    ) {
        var current: DirNode? = node
        while let step = current {
            step.totalSize += size
            step.totalAlloc += alloc
            step.totalFiles += files
            step.totalDirs += dirs
            current = step.parent
        }
    }

    /// What the scan counted `ref` as: itself and everything under it, and
    /// the space that takes.
    private nonisolated static func scanned(_ ref: NodeRef) -> Removal.Tally {
        Removal.Tally(
            items: ref.isDirectory ? ref.dir.totalItems + 1 : 1,
            bytes: ref.alloc
        )
    }

    /// Takes a progress report from the thread doing the removing.
    ///
    /// Reports are sent, not awaited, so one can arrive after its batch has
    /// ended or after a later one has overtaken it. Either would walk the bar
    /// backwards.
    private func noteProgress(_ tally: Removal.Tally, of batch: Int) {
        guard batch == deleteBatch, var progress = deleteProgress,
            tally.items >= progress.items
        else { return }
        progress.items = tally.items
        progress.bytes = tally.bytes
        deleteProgress = progress
    }

    /// Removes one target and says what became of it. Off the main actor.
    private nonisolated static func dispose(
        of target: Target,
        as disposal: Disposal,
        by mover: (String) throws -> FileActions.TrashReceipt?,
        stop: Removal.Stop,
        onProgress: (Removal.Tally) -> Void
    ) -> Disposed {
        var disposed = Disposed()
        let name = (target.path as NSString).lastPathComponent
        do {
            switch disposal {
            case .trash:
                disposed.receipt = try mover(target.path)
                disposed.gone = [target.ref]
                // A move is one step, so it counts for all of it at once.
                disposed.tally = scanned(target.ref)
            case .delete:
                let outcome = try FileActions.deletePermanently(
                    target.path,
                    stop: stop,
                    onProgress: onProgress
                )
                disposed.tally = outcome.tally
                if outcome.isGone {
                    disposed.gone = [target.ref]
                    break
                }
                // Part of a folder can have gone before a Stop or a file that
                // wouldn't budge. The disk is asked which part, not the
                // callbacks: what is still there is what the tree has to show.
                if target.ref.isDirectory {
                    disposed.gone = missing(under: target.ref.dir, at: target.path)
                }
                // Being stopped is what was asked for, and nothing to report.
                if outcome.failures > 0 || !outcome.wasStopped {
                    disposed.failure = failure(outcome, removing: name)
                }
            }
        } catch let error as FileActions.ActionError {
            disposed.failure = (
                error.errorDescription ?? "Couldn’t delete an item",
                error.recoverySuggestion ?? ""
            )
        } catch {
            disposed.failure = ("Couldn’t delete “\(name)”", error.localizedDescription)
        }
        return disposed
    }

    /// The alert for a delete that left something behind.
    private nonisolated static func failure(
        _ outcome: Removal.Outcome,
        removing name: String
    ) -> (title: String, detail: String) {
        let title =
            outcome.tally.items > 0
            ? "Couldn’t delete all of “\(name)”" : "Couldn’t delete “\(name)”"
        guard let first = outcome.firstFailure else { return (title, "") }
        let reason = String(cString: strerror(first.code))
        let leaf = (first.path as NSString).lastPathComponent
        var detail = leaf == name ? "\(reason)." : "“\(leaf)”: \(reason)."
        if outcome.failures > 1 {
            detail +=
                " \(ByteFormat.counted(outcome.failures - 1, "other item")) "
                + "couldn’t be removed either."
        }
        return (title, detail)
    }

    /// The files and folders the scan found under `dir` that are no longer on
    /// disk. A folder that has gone is named once, not entry by entry.
    ///
    /// Asked by path, and where a path is too long to ask by, of the folder
    /// the entry is in. A scan opens folders by path and so reaches down to
    /// `PATH_MAX`, which leaves it holding one level of entries whose own
    /// paths are past it — and a removal that had to change directory to get
    /// that deep removes exactly those. Taken for still there, they stayed in
    /// the tree, and could not be deleted from it either.
    ///
    /// Anything that still can't be looked at — a folder that can't be opened
    /// — is taken to be there. Wrongly kept, it overstates a total until the
    /// next scan; wrongly dropped, it would be a file the tree says has gone
    /// that has not.
    private nonisolated static func missing(
        under dir: DirNode,
        at path: String
    ) -> [NodeRef] {
        var gone: [NodeRef] = []
        var pending: [(dir: DirNode, path: String)] = [(dir, path)]
        while let (dir, path) = pending.popLast() {
            // Opened only for a name in here that is past `PATH_MAX`.
            var folder: Int32 = -1
            defer { if folder >= 0 { close(folder) } }
            func isMissing(_ name: String) -> Bool {
                var info = stat()
                if lstat(path + "/" + name, &info) == 0 { return false }
                if errno == ENOENT { return true }
                guard errno == ENAMETOOLONG else { return false }
                if folder < 0 { folder = open(path, O_RDONLY | O_DIRECTORY) }
                guard folder >= 0 else { return false }
                return fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) != 0
                    && errno == ENOENT
            }

            for index in dir.files.indices where !dir.files[index].isRemoved {
                if isMissing(dir.files[index].name) {
                    gone.append(NodeRef(dir: dir, fileIndex: index))
                }
            }
            for sub in dir.subdirs {
                if isMissing(sub.name) {
                    gone.append(NodeRef(sub))
                } else {
                    pending.append((sub, path + "/" + sub.name))
                }
            }
        }
        return gone
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

        // Worked out while the rows still hold what is leaving.
        let anchor = selectionAnchor(for: Set(refs))

        // A file's slot is kept, so its siblings keep their indices and the
        // order these come off in doesn't matter.
        for ref in refs where !ref.isDirectory { detachFile(ref, unlinked: unlinked) }

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
        // The last file of the type in focus that took any space has gone:
        // left in focus, it would hold the map dark and the File View empty.
        if let focusedType, !canFocus(on: focusedType) {
            self.focusedType = nil
        }
        for folder in folders { detachDirectory(folder) }

        // Everything that outlived the delete goes on naming what it named:
        // a file's siblings were not renumbered, and a folder's were never
        // numbered. So the selection, the rows and the pointer are only
        // relieved of what has actually gone, and the table is handed the
        // same rows less those — which it can take out without redrawing the
        // rest.
        // Asked before the selection is relieved of what went: a panel that
        // was showing the selected row shuts as that row leaves the
        // selection, and is then no longer showing anything to ask about.
        let wasShowingWhatWent = previewed?.isStale == true
        selection = selection.filter { !$0.isStale }
        // A mark on something that went has done its job; one on something
        // that could not be removed stays, to be tried again or taken off.
        setMarks(marks.filter { !$0.isStale })
        // A delete still awaiting confirmation quoted what it would free
        // before this one changed that, so it is asked for again.
        permanentDeleteTargets = []
        if hoveredRef?.isStale == true { hoveredRef = nil }
        // What Quick Look was showing has gone from under it. The panel is
        // put back up below, on whatever the selection moves to: working
        // down a list with it open, looking and then removing, is what it is
        // for.
        if wasShowingWhatWent { previewURL = nil }
        sharedStorageCache = [:]
        treeRevision += 1
        // Now, not when the walk below returns: a row for a file that has
        // gone would otherwise sit in the list until it did.
        fileRows.removeAll { $0.ref.isStale }
        bringFolderRowsUpToDate()
        rebuildTreeRows()
        if selection.isEmpty, let anchor, let next = row(at: anchor) {
            selection = [next]
            if wasShowingWhatWent { show(inPreview: next) }
        }
        refreshFileRows(immediately: true)
    }

    /// A folder a search listed holds what it holds now. Its row keeps its
    /// own copy of the figures, and went on showing what the folder had been
    /// before something inside it was removed, or put back, for as long as
    /// the walk that follows took to come back.
    private func bringFolderRowsUpToDate() {
        guard let result, fileRows.contains(where: { $0.ref.isDirectory }) else { return }
        let total = result.root.bytes(using: sizeMetric)
        fileRows = fileRows.map { row in
            row.ref.isDirectory
                ? FileRow(row.ref, metric: sizeMetric, rootTotal: total) : row
        }
    }

    /// Where in the tab in front the selection was, when all of it is leaving.
    private enum SelectionAnchor {
        /// The place among `parent`'s rows in the Tree View.
        case treeRow(parent: DirNode, ordinal: Int)
        /// The place in the File View's list.
        case fileRow(Int)
    }

    /// The folder a row hangs off in the Tree View.
    private func rowParent(_ ref: NodeRef) -> DirNode? {
        ref.isDirectory ? ref.dir.parent : ref.dir
    }

    /// Notes where the selection is, if `leaving` is about to take all of it.
    ///
    /// Left empty, the next press of an arrow key starts again from the top of
    /// the table, which in a long list is nowhere near what was being worked
    /// through. Nil when any of the selection is staying — that is then what
    /// is selected — or when it was never a row: a tile picked on the treemap
    /// has no neighbours to move to.
    private func selectionAnchor(for leaving: Set<NodeRef>) -> SelectionAnchor? {
        func isLeaving(_ ref: NodeRef) -> Bool {
            if leaving.contains(ref) { return true }
            var above = rowParent(ref)
            while let step = above {
                if leaving.contains(NodeRef(step)) { return true }
                above = step.parent
            }
            return false
        }
        guard !selection.isEmpty, selection.allSatisfy(isLeaving) else { return nil }

        switch tab {
        case .files:
            // Where the first row being removed sits among the rows that
            // are staying. A search lists a folder and things inside it as
            // rows of their own, and those go with it: counted from the
            // first row that is going at all, one of them sorted above its
            // folder put the selection back at its place and not the
            // folder's, rows away from what had been selected.
            guard let first = fileRows.firstIndex(where: { leaving.contains($0.ref) })
            else { return nil }
            return .fileRow(fileRows[..<first].filter { !isLeaving($0.ref) }.count)
        case .tree:
            guard let first = treeRows.firstIndex(where: { leaving.contains($0.ref) }),
                selection.contains(where: { isTreeRow($0) }),
                let parent = rowParent(treeRows[first].ref)
            else { return nil }
            var ordinal = 0
            for row in treeRows[..<first].reversed() {
                if row.ref == NodeRef(parent) { break }
                if rowParent(row.ref) === parent { ordinal += 1 }
            }
            return .treeRow(parent: parent, ordinal: ordinal)
        case .about:
            return nil
        }
    }

    /// The row now at `anchor`: what moved up into the place of what left,
    /// or the last of its neighbours when it was at the end. With none left
    /// in the Tree View it is the folder they were in, which is then empty.
    private func row(at anchor: SelectionAnchor) -> NodeRef? {
        switch anchor {
        case .fileRow(let index):
            guard !fileRows.isEmpty else { return nil }
            return fileRows[min(index, fileRows.count - 1)].ref
        case .treeRow(let parent, let ordinal):
            guard isTreeRow(NodeRef(parent)), !NodeRef(parent).isStale else {
                return nil
            }
            var seen = 0
            var last: NodeRef?
            for row in treeRows where rowParent(row.ref) === parent {
                if seen == ordinal { return row.ref }
                seen += 1
                last = row.ref
            }
            return last ?? NodeRef(parent)
        }
    }

    private func detachFile(_ ref: NodeRef, unlinked: Bool) {
        let dir = ref.dir
        let index = Int(ref.fileIndex)
        guard index < dir.files.count, !dir.files[index].isRemoved else { return }
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
            dir.files[index] = .removed
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
        // The slot stays, so no sibling is renumbered. See `FileEntry.isRemoved`.
        dir.files[index] = .removed
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
        // Cut off, so that a reference to it or to anything under it reads as
        // stale. Left pointing at a parent that no longer lists it, the
        // selection would go on naming a folder that is not in the tree.
        node.parent = nil
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
