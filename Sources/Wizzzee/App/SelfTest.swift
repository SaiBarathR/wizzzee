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
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try buildFixture(at: root)
        } catch {
            print("couldn't build the fixture: \(error)")
            exit(1)
        }
        print("fixture: \(root.path)\n")

        testScanTotals(root)
        testHardLinks(root)
        testExtensionStats(root)
        testFilterAndRanking(root)
        testTrashUpdatesTree(root)
        testPermanentDeleteFolder(root)
        testSystemProtectionRefusal()
        testScanOutcomeReporting()

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
            model.selection == nil,
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
