import AppKit
import Foundation

/// Exercises the scan engine and the destructive file actions against a
/// throwaway tree with known contents.
///
/// The delete path is the one place a bug does real damage — it removes user
/// files and then adjusts every ancestor's totals in place instead of
/// rescanning — so it gets checked against ground truth rather than by eye.
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    @MainActor
    static func run() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-\(getpid())")
        // The batch tests need folders of their own: the checks above delete
        // parts of the main fixture, which would leave them too little to work
        // with and make their expected totals depend on test order.
        let batchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-batch-\(getpid())")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: batchRoot)
        }

        do {
            try buildFixture(at: root)
            try buildBatchFixture(at: batchRoot)
        } catch {
            print("couldn't build the fixture: \(error)")
            exit(1)
        }
        print("fixture: \(root.path)\n")

        testScanTotals(root)
        testSymlinkedRootIsScanned(root)
        testHardLinks(root)
        testExtensionStats(root)
        testFilterAndRanking(root)
        testTrashUpdatesTree(root)
        testPermanentDeleteFolder(root)
        testStaleReferencesSurviveADelete(batchRoot)
        testAncestorDedupe(batchRoot)
        testBatchTrashOfSiblings(batchRoot)
        testBatchDeleteOfNestedSelection(batchRoot)
        testSystemProtectionRefusal()
        testScanOutcomeReporting()
        testNativeWindowTabbingIsOff()
        testTreemapVisibilityPersists()
        testPreferenceSummary()

        print("")
        if failures == 0 {
            print("all \(checks) checks passed")
            exit(0)
        }
        print("\(failures) of \(checks) checks FAILED")
        exit(1)
    }

    // MARK: - Fixture
    //
    // a/one.dat      10,000 bytes
    // a/two.log       5,000
    // a/b/three.dat  20,000
    // a/b/four.txt    1,000
    // c/five.dat     40,000
    // c/link.dat     hard link to c/five.dat (counted once)
    // c/alias.dat    symlink to five.dat
    private static func buildFixture(at root: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: root.appendingPathComponent("a/b"),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: root.appendingPathComponent("c"),
            withIntermediateDirectories: true
        )
        try write(root.appendingPathComponent("a/one.dat"), bytes: 10_000)
        try write(root.appendingPathComponent("a/two.log"), bytes: 5_000)
        try write(root.appendingPathComponent("a/b/three.dat"), bytes: 20_000)
        try write(root.appendingPathComponent("a/b/four.txt"), bytes: 1_000)
        try write(root.appendingPathComponent("c/five.dat"), bytes: 40_000)
        try manager.linkItem(
            at: root.appendingPathComponent("c/five.dat"),
            to: root.appendingPathComponent("c/link.dat")
        )
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("c/alias.dat"),
            withDestinationURL: root.appendingPathComponent("c/five.dat")
        )
    }

    // Each check below deletes from the batch fixture, so every one gets its own
    // folder rather than sharing — otherwise they only pass in a fixed order.
    //
    // siblings/one.dat    3,000 bytes
    // siblings/two.dat    4,000
    // siblings/three.dat  5,000
    // stale/{a,b,c}.dat   2,000 each
    // nest/top.dat        7,000
    // nest/inner/deep.dat 6,000
    private static func buildBatchFixture(at root: URL) throws {
        let manager = FileManager.default
        for folder in ["siblings", "stale", "nest/inner"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(folder),
                withIntermediateDirectories: true
            )
        }
        try write(root.appendingPathComponent("siblings/one.dat"), bytes: 3_000)
        try write(root.appendingPathComponent("siblings/two.dat"), bytes: 4_000)
        try write(root.appendingPathComponent("siblings/three.dat"), bytes: 5_000)
        try write(root.appendingPathComponent("stale/a.dat"), bytes: 2_000)
        try write(root.appendingPathComponent("stale/b.dat"), bytes: 2_000)
        try write(root.appendingPathComponent("stale/c.dat"), bytes: 2_000)
        try write(root.appendingPathComponent("nest/top.dat"), bytes: 7_000)
        try write(root.appendingPathComponent("nest/inner/deep.dat"), bytes: 6_000)
    }

    private static func write(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private static func scan(_ root: URL) -> ScanResult {
        guard let result = ScanEngine().scanSynchronously(rootPath: root.path) else {
            print("scan failed outright")
            exit(1)
        }
        return result
    }

    // MARK: - Checks

    private static func testScanTotals(_ root: URL) {
        let result = scan(root)
        // 10,000 + 5,000 + 20,000 + 1,000 + 40,000. The hard link adds nothing,
        // and the symlink contributes only its target-path length.
        let expected: UInt64 = 76_000
        let symlinkSlack: UInt64 = 512
        check(
            "logical total counts each file once",
            result.root.totalSize >= expected
                && result.root.totalSize <= expected + symlinkSlack,
            "got \(result.root.totalSize), expected ~\(expected)"
        )
        check(
            "file count includes the link and the alias",
            result.root.totalFiles == 7,
            "got \(result.root.totalFiles), expected 7"
        )
        check(
            "folder count excludes the root itself",
            result.root.totalDirs == 3,
            "got \(result.root.totalDirs), expected 3 (a, a/b, c)"
        )
    }

    /// A scan root whose last component is a symlink.
    ///
    /// The workers open directories with `O_NOFOLLOW` so a symlinked child can't
    /// smuggle another subtree into the totals, but that also refuses the root
    /// when the user names one — and `standardizingPath` puts perfectly ordinary
    /// roots in that position, rewriting `/private/tmp` to `/tmp`. The scan then
    /// reported "complete" with zero bytes and one unreadable directory, which is
    /// the worst way for a measuring tool to be wrong.
    private static func testSymlinkedRootIsScanned(_ root: URL) {
        let link = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-link-\(getpid())")
        try? FileManager.default.removeItem(at: link)
        do {
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: root
            )
        } catch {
            check("a symlink to the fixture can be made", false, "\(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: link) }

        let direct = scan(root)
        let through = scan(link)
        check(
            "a symlinked root scans the directory it points at",
            through.root.totalSize == direct.root.totalSize
                && through.root.totalFiles == direct.root.totalFiles,
            "got \(through.root.totalSize) bytes / \(through.root.totalFiles) files, "
                + "expected \(direct.root.totalSize) / \(direct.root.totalFiles)"
        )
        check(
            "it reports no unreadable directories",
            through.deniedCount == 0,
            "got \(through.deniedCount)"
        )
        // Reported as the real directory, so the paths the delete actions resolve
        // don't run back through the link.
        check(
            "the root path is reported resolved",
            through.rootPath == direct.rootPath,
            "got \(through.rootPath), expected \(direct.rootPath)"
        )
    }

    private static func testHardLinks(_ root: URL) {
        let result = scan(root)
        check(
            "hard-link savings are reported",
            result.hardLinkSavings == 40_000,
            "got \(result.hardLinkSavings), expected 40000"
        )
        let c = result.root.subdir(named: "c")
        let duplicates = c?.files.filter(\.isDuplicateLink).count ?? -1
        check(
            "exactly one of the two hard links is marked duplicate",
            duplicates == 1,
            "got \(duplicates)"
        )
        check(
            "c/ totals count the linked bytes once",
            c?.totalSize ?? 0 < 41_000,
            "got \(c?.totalSize ?? 0)"
        )
    }

    private static func testExtensionStats(_ root: URL) {
        let result = scan(root)
        let dat = result.stat(for: "dat")
        // one.dat, three.dat, five.dat, link.dat, alias.dat
        check(
            ".dat is counted across the tree",
            dat?.count == 5,
            "got \(dat?.count.description ?? "nil"), expected 5"
        )
        // 10,000 + 20,000 + 40,000, counting the hard link once. alias.dat is a
        // symlink and also ends in .dat, so it adds its target-path length.
        let datSize = dat?.size ?? 0
        check(
            ".dat size excludes the duplicate link",
            datSize >= 70_000 && datSize < 70_500,
            "got \(datSize), expected ~70000"
        )
        check(
            "extensions are ranked by size",
            result.extensionStats.first?.ext == "dat",
            "got \(result.extensionStats.first?.ext ?? "nil")"
        )
    }

    private static func testFilterAndRanking(_ root: URL) {
        let result = scan(root)
        let biggest = result.largestFiles(limit: 10, metric: .logical)
        // Which name of a hard-linked pair survives is arbitrary — the scanner
        // keeps whichever it reaches first — so the invariant is that the bytes
        // are listed exactly once, not that a particular name wins.
        let linkPair = biggest.filter {
            $0.name == "five.dat" || $0.name == "link.dat"
        }
        check(
            "the largest file is the 40 KB hard-linked one",
            biggest.first?.size == 40_000,
            "got \(biggest.first?.name ?? "nil") at \(biggest.first?.size ?? 0)"
        )
        check(
            "a hard-linked pair is listed once, not twice",
            linkPair.count == 1,
            "got \(linkPair.map(\.name))"
        )
        let logs = result.largestFiles(matching: "log", limit: 10)
        check(
            "name filter matches two.log only",
            logs.count == 1 && logs.first?.name == "two.log",
            "got \(logs.map(\.name))"
        )
        let byPath = result.largestFiles(matching: "a/b/", limit: 10)
        check(
            "a path filter matches only that subtree",
            byPath.count == 2,
            "got \(byPath.map(\.path))"
        )
        let caseInsensitive = result.largestFiles(matching: "TWO.LOG", limit: 10)
        check(
            "filtering ignores case",
            caseInsensitive.first?.name == "two.log",
            "got \(caseInsensitive.first?.name ?? "nil")"
        )
        let mixedCase = result.largestFiles(matching: "ThReE", limit: 10)
        check(
            "filtering ignores mixed case mid-word",
            mixedCase.first?.name == "three.dat",
            "got \(mixedCase.first?.name ?? "nil")"
        )
    }

    @MainActor
    private static func testTrashUpdatesTree(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }

        let before = result.root.totalSize
        let beforeFiles = result.root.totalFiles
        let a = result.root.subdir(named: "a")!
        let aBefore = a.totalSize
        guard let index = a.files.firstIndex(where: { $0.name == "one.dat" }) else {
            check("fixture has a/one.dat", false, "missing")
            return
        }
        let ref = NodeRef(dir: a, fileIndex: index)
        let size = a.files[index].size

        model.moveToTrash(ref)

        check(
            "trashing reports no error",
            model.actionError == nil,
            model.actionError ?? ""
        )
        check(
            "the file is gone from disk",
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("a/one.dat").path
            ),
            "still present"
        )
        check(
            "it is dropped from its folder",
            !a.files.contains { $0.name == "one.dat" },
            "still in the model"
        )
        check(
            "the folder's total shrinks by exactly its size",
            a.totalSize == aBefore - size,
            "a/ is \(a.totalSize), expected \(aBefore - size)"
        )
        check(
            "the change propagates to the root",
            result.root.totalSize == before - size,
            "root is \(result.root.totalSize), expected \(before - size)"
        )
        check(
            "the root's file count drops by one",
            result.root.totalFiles == beforeFiles - 1,
            "got \(result.root.totalFiles), expected \(beforeFiles - 1)"
        )
        check(
            "the selection is cleared, since file indices shifted",
            model.selection.isEmpty,
            "selection survived"
        )
    }

    /// A `NodeRef` names a file by its index in the folder's array, so deleting
    /// anything ahead of it leaves the reference pointing past the end. SwiftUI
    /// keeps a context menu's content alive and re-runs its body once the sheet
    /// closes — after the delete — so reading a stale reference has to degrade
    /// quietly. Reading one used to trap and take the whole app down.
    @MainActor
    private static func testStaleReferencesSurviveADelete(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }
        let dir = result.root.subdir(named: "stale")!
        guard dir.files.count == 3 else {
            check("the stale-ref fixture has three files", false, "\(dir.files.count)")
            return
        }

        // Captured while all three exist, then read once only one remains —
        // exactly what the menu holds across a delete.
        let last = NodeRef(dir: dir, fileIndex: 2)
        model.moveToTrash([
            NodeRef(dir: dir, fileIndex: 0), NodeRef(dir: dir, fileIndex: 1),
        ])
        check(
            "the fixture is down to one file",
            dir.files.count == 1,
            "got \(dir.files.count)"
        )
        check("a reference past the end reports itself stale", last.isStale, "")
        check("its path reads empty rather than trapping", last.path.isEmpty, last.path)
        check("its name reads empty", last.name.isEmpty, last.name)
        check("its size reads zero", last.size == 0, "\(last.size)")
        check("its file entry is nil", last.file == nil, "got one")
        check(
            "its percentage reads zero",
            last.fractionOfParent == 0 && last.fractionOfParent(using: .allocated) == 0,
            "\(last.fractionOfParent)"
        )
        // The protection check is what the crash came through: the menu asks it
        // for every captured reference each time its body re-runs.
        check(
            "the menu's protection check tolerates a stale reference",
            !FileActions.containsSystemProtected([last]),
            "reported protected"
        )
        check(
            "a stale reference is never a delete target",
            model.distinctTargets([last]).isEmpty,
            "it survived the filter"
        )
        // Aiming a stale reference at its parent folder would delete the wrong
        // thing entirely, so the surviving file must still be here afterwards.
        model.deletePermanently([last])
        check(
            "acting on a stale reference is a no-op, not a parent delete",
            FileManager.default.fileExists(atPath: dir.path)
                && dir.files.count == 1,
            "the folder or its contents were removed"
        )
    }

    /// A folder and something inside it can both be selected. Only the folder
    /// should be acted on — deleting it takes the rest with it, so a second
    /// attempt would fail on a path that no longer exists and, worse, subtract
    /// the same bytes from the totals twice.
    @MainActor
    private static func testAncestorDedupe(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }
        let nest = result.root.subdir(named: "nest")!
        let inner = nest.subdir(named: "inner")!
        let topIndex = nest.files.firstIndex { $0.name == "top.dat" }!
        let deepIndex = inner.files.firstIndex { $0.name == "deep.dat" }!

        let nested: Set<NodeRef> = [
            NodeRef(nest),
            NodeRef(inner),
            NodeRef(dir: nest, fileIndex: topIndex),
            NodeRef(dir: inner, fileIndex: deepIndex),
        ]
        let targets = model.distinctTargets(nested)
        check(
            "a folder swallows every selected descendant",
            targets.count == 1 && targets.first?.dir === nest,
            "got \(targets.map(\.name))"
        )

        let siblings = result.root.subdir(named: "siblings")!
        let unrelated: Set<NodeRef> = [
            NodeRef(dir: siblings, fileIndex: 0),
            NodeRef(dir: siblings, fileIndex: 1),
            NodeRef(inner),
        ]
        check(
            "unrelated selections are all kept",
            model.distinctTargets(unrelated).count == 3,
            "got \(model.distinctTargets(unrelated).map(\.name))"
        )
        check(
            "reclaimable size counts a nested selection once",
            model.reclaimableSize(nested) == nest.totalSize,
            "got \(model.reclaimableSize(nested)), expected \(nest.totalSize)"
        )
    }

    /// Two files in one folder, trashed together. Removing an entry renumbers
    /// every sibling after it, so the batch has to unlink from the back — done
    /// front-to-back this drops the wrong rows from the model while deleting the
    /// right files from disk, which no error would ever reveal.
    @MainActor
    private static func testBatchTrashOfSiblings(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }

        let dir = result.root.subdir(named: "siblings")!
        guard dir.files.count == 3 else {
            check("the batch fixture has three siblings", false, "\(dir.files.count)")
            return
        }
        // Indices, not names: which name lands at which index depends on the
        // order the filesystem enumerated them, and it's the indices that the
        // removal order has to get right.
        let names = dir.files.map(\.name)
        let paths = (0..<3).map { dir.path(ofFileAt: $0) }
        let removedBytes = dir.files[0].size + dir.files[2].size
        let before = result.root.totalSize
        let beforeFiles = result.root.totalFiles

        model.moveToTrash([
            NodeRef(dir: dir, fileIndex: 0), NodeRef(dir: dir, fileIndex: 2),
        ])

        check(
            "trashing two at once reports no error",
            model.actionError == nil,
            model.actionError ?? ""
        )
        check(
            "both files are gone from disk",
            !FileManager.default.fileExists(atPath: paths[0])
                && !FileManager.default.fileExists(atPath: paths[2]),
            "still present"
        )
        check(
            "the untouched sibling is still on disk",
            FileManager.default.fileExists(atPath: paths[1]),
            "\(names[1]) was deleted too"
        )
        check(
            "the model keeps exactly the sibling that survived",
            dir.files.map(\.name) == [names[1]],
            "got \(dir.files.map(\.name)), expected [\(names[1])]"
        )
        check(
            "the root's total drops by both files' sizes",
            result.root.totalSize == before - removedBytes,
            "root is \(result.root.totalSize), expected \(before - removedBytes)"
        )
        check(
            "the root's file count drops by two",
            result.root.totalFiles == beforeFiles - 2,
            "got \(result.root.totalFiles), expected \(beforeFiles - 2)"
        )
        check(
            "a batch clears the selection",
            model.selection.isEmpty,
            "selection survived"
        )
    }

    /// A folder selected together with its own contents, deleted permanently.
    @MainActor
    private static func testBatchDeleteOfNestedSelection(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }

        let nest = result.root.subdir(named: "nest")!
        let inner = nest.subdir(named: "inner")!
        let topIndex = nest.files.firstIndex { $0.name == "top.dat" }!
        let nestSize = nest.totalSize
        let nestFiles = nest.totalFiles
        let before = result.root.totalSize
        let beforeFiles = result.root.totalFiles
        let beforeDirs = result.root.totalDirs

        model.selection = [NodeRef(nest)]
        model.deletePermanently([
            NodeRef(nest), NodeRef(inner), NodeRef(dir: nest, fileIndex: topIndex),
        ])

        check(
            "deleting a folder alongside its contents reports no error",
            model.actionError == nil,
            model.actionError ?? ""
        )
        check(
            "the folder is gone from disk",
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("nest").path
            ),
            "still present"
        )
        check(
            "it is detached from the root",
            result.root.subdir(named: "nest") == nil,
            "still attached"
        )
        check(
            "its bytes come off the root exactly once",
            result.root.totalSize == before - nestSize,
            "root is \(result.root.totalSize), expected \(before - nestSize)"
        )
        check(
            "both of its files come off the root's file count",
            result.root.totalFiles == beforeFiles - nestFiles,
            "got \(result.root.totalFiles), expected \(beforeFiles - nestFiles)"
        )
        check(
            "the folder and its subfolder both come off the folder count",
            result.root.totalDirs == beforeDirs - 2,
            "got \(result.root.totalDirs), expected \(beforeDirs - 2)"
        )
        check(
            "the selection is cleared after a nested batch",
            model.selection.isEmpty,
            "selection survived"
        )
    }

    @MainActor
    private static func testPermanentDeleteFolder(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }

        let before = result.root.totalSize
        let beforeDirs = result.root.totalDirs
        let beforeFiles = result.root.totalFiles
        let a = result.root.subdir(named: "a")!
        let b = a.subdir(named: "b")!
        let bSize = b.totalSize
        let bFiles = b.totalFiles

        model.deletePermanently(NodeRef(b))

        check(
            "deleting a folder reports no error",
            model.actionError == nil,
            model.actionError ?? ""
        )
        check(
            "the folder is gone from disk",
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("a/b").path
            ),
            "still present"
        )
        check(
            "it is detached from its parent",
            a.subdir(named: "b") == nil,
            "still attached"
        )
        check(
            "the whole subtree's bytes come off the root",
            result.root.totalSize == before - bSize,
            "root is \(result.root.totalSize), expected \(before - bSize)"
        )
        check(
            "its files come off the root's file count",
            result.root.totalFiles == beforeFiles - bFiles,
            "got \(result.root.totalFiles), expected \(beforeFiles - bFiles)"
        )
        check(
            "the folder itself is subtracted from the folder count",
            result.root.totalDirs == beforeDirs - 1,
            "got \(result.root.totalDirs), expected \(beforeDirs - 1)"
        )
    }

    private static func testSystemProtectionRefusal() {
        check(
            "/System is recognized as protected",
            FileActions.isSystemProtected("/System/Library/CoreServices/Finder.app"),
            "not flagged"
        )
        check(
            "/usr/local is not treated as protected",
            !FileActions.isSystemProtected("/usr/local/bin/thing"),
            "wrongly flagged"
        )
        check(
            "a home path is not treated as protected",
            !FileActions.isSystemProtected(NSHomeDirectory() + "/Downloads/x.zip"),
            "wrongly flagged"
        )
        do {
            try FileActions.moveToTrash("/System/Library/CoreServices/Finder.app")
            check("trashing a SIP path is refused", false, "it went ahead")
        } catch {
            check("trashing a SIP path is refused", true, "")
        }
    }

    /// A nil scan result means one of two things — the user stopped it, or the
    /// root couldn't be read — and they have to reach the UI as different
    /// phases, since only one of them is worth an error message.
    @MainActor
    private static func testScanOutcomeReporting() {
        let model = AppModel()
        model.customFolder = NSTemporaryDirectory()
            + "wizzzee-nonexistent-\(getpid())"
        model.startScan()
        pumpUntilSettled(model)
        var failedProperly = false
        if case .failed = model.phase { failedProperly = true }
        check(
            "an unreadable root reports failure, not cancellation",
            failedProperly,
            "phase was \(model.phase)"
        )

        // Stopped before the workers exist. This used to let the entire walk run
        // to completion and only then discard it, so the elapsed time is checked
        // as well as the phase.
        let early = AppModel()
        early.customFolder = NSHomeDirectory()
        let earlyStart = Date()
        early.startScan()
        early.cancelScan()
        pumpUntilSettled(early)
        let earlyElapsed = Date().timeIntervalSince(earlyStart)
        check(
            "a scan stopped immediately reports cancellation, not failure",
            early.phase == .cancelled,
            "phase was \(early.phase)"
        )
        check(
            "stopping before the workers start abandons the walk at once",
            earlyElapsed < 1,
            "took \(String(format: "%.1f", earlyElapsed))s and saw "
                + "\(early.progress.items) items"
        )

        // Stopped once the walk is genuinely under way.
        let midScan = AppModel()
        midScan.customFolder = NSHomeDirectory()
        midScan.startScan()
        let spinUp = Date().addingTimeInterval(10)
        while midScan.progress.items == 0 && midScan.phase == .scanning,
            Date() < spinUp
        {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let midStart = Date()
        midScan.cancelScan()
        pumpUntilSettled(midScan)
        check(
            "a scan stopped mid-walk reports cancellation",
            midScan.phase == .cancelled,
            "phase was \(midScan.phase)"
        )
        check(
            "stopping mid-walk unwinds promptly",
            Date().timeIntervalSince(midStart) < 2,
            "took \(String(format: "%.1f", Date().timeIntervalSince(midStart)))s"
        )
    }

    /// Native window tabbing has to be off before the first window exists, so
    /// this asserts that building the app is what turns it off — deleting the
    /// call would otherwise bring Show Tab Bar, Show All Tabs and the tab bar's
    /// "+" back with nothing to notice it.
    @MainActor
    private static func testNativeWindowTabbingIsOff() {
        NSWindow.allowsAutomaticWindowTabbing = true
        _ = WizzzeeApp()
        check(
            "creating the app turns native window tabbing off",
            !NSWindow.allowsAutomaticWindowTabbing,
            "still on, so the tab bar and its menu items would come back"
        )
    }

    /// The treemap's visibility outlives a launch, which means a fresh model has
    /// to read it back rather than assume shown. Run against a throwaway suite:
    /// writing to the real domain would change the tester's own setting, and a
    /// leftover value would make the first check pass or fail by history.
    @MainActor
    private static func testTreemapVisibilityPersists() {
        let suite = "wizzzee-selftest-prefs-\(getpid())"
        guard let scratch = UserDefaults(suiteName: suite) else {
            check("a throwaway preference suite is available", false, suite)
            return
        }
        let real = Preferences.store
        Preferences.store = scratch
        defer {
            Preferences.store = real
            scratch.removePersistentDomain(forName: suite)
        }

        check(
            "a first launch shows the treemap, with nothing stored",
            Preferences.showsTreemap && AppModel().showsTreemap,
            "started hidden"
        )

        let model = AppModel()
        model.toggleTreemap()
        check(
            "hiding it is recorded",
            !model.showsTreemap && !Preferences.showsTreemap,
            "model \(model.showsTreemap), stored \(Preferences.showsTreemap)"
        )
        check(
            "the next launch starts hidden",
            !AppModel().showsTreemap,
            "came back shown"
        )

        model.toggleTreemap()
        check(
            "showing it again is recorded too",
            model.showsTreemap && Preferences.showsTreemap,
            "model \(model.showsTreemap), stored \(Preferences.showsTreemap)"
        )
        check(
            "the next launch starts shown",
            AppModel().showsTreemap,
            "came back hidden"
        )

        // The headless renderer sets a layout for one image; that must not
        // rewrite what the user chose.
        let previous = Preferences.showsTreemap
        let render = AppModel()
        render.showsTreemap = false
        check(
            "assigning the property leaves the stored preference alone",
            Preferences.showsTreemap == previous,
            "a plain assignment was persisted"
        )
    }

    /// What `--prefs` reports. The point of the flag is checking a UI-only
    /// setting from a script, so the exact words are the contract and are
    /// asserted here rather than eyeballed.
    @MainActor
    private static func testPreferenceSummary() {
        let suite = "wizzzee-selftest-summary-\(getpid())"
        guard let scratch = UserDefaults(suiteName: suite) else {
            check("a throwaway preference suite is available", false, suite)
            return
        }
        let real = Preferences.store
        Preferences.store = scratch
        defer {
            Preferences.store = real
            scratch.removePersistentDomain(forName: suite)
        }

        let untouched = Preferences.summary()
        check(
            "an untouched setting reports the default it fell back to",
            untouched.contains("showsTreemap: true (default)"),
            untouched
        )
        // A diagnostic that wrote the key it was asked about would turn every
        // later "default" into "stored" and quietly answer its own question.
        check(
            "printing the summary stores nothing",
            !Preferences.showsTreemapIsStored,
            "the key exists after only reading it"
        )
        check(
            "the summary names the domain the values came from",
            untouched.contains("domain: "),
            untouched
        )

        let model = AppModel()
        model.toggleTreemap()
        let hidden = Preferences.summary()
        check(
            "a chosen setting is reported as stored, not defaulted",
            hidden.contains("showsTreemap: false (stored)"),
            hidden
        )

        model.toggleTreemap()
        let shown = Preferences.summary()
        check(
            "choosing the default value still counts as stored",
            shown.contains("showsTreemap: true (stored)"),
            shown
        )
    }

    /// Runs the main run loop until the model leaves `.scanning`.
    @MainActor
    private static func pumpUntilSettled(_ model: AppModel) {
        let deadline = Date().addingTimeInterval(60)
        while model.phase == .scanning && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Drives `AppModel.startScan` to completion by pumping the run loop, so the
    /// real published-state path is what gets tested.
    @MainActor
    private static func loadSynchronously(into model: AppModel) -> ScanResult? {
        model.startScan()
        pumpUntilSettled(model)
        guard let result = model.result else {
            check("scan completed for the model", false, "phase \(model.phase)")
            return nil
        }
        return result
    }

    private static func check(_ what: String, _ passed: Bool, _ detail: String) {
        checks += 1
        if passed {
            print("  ok    \(what)")
        } else {
            failures += 1
            print("  FAIL  \(what)\n          \(detail)")
        }
    }
}
