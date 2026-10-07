import AppKit
import Combine
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

        testFileEntryStaysNarrow()
        testCountsAreWordedInTheSingular()
        testScanTotals(root)
        testSymlinkedRootIsScanned(root)
        testHardLinks(root)
        testHardLinkPromisesNoSpace(root)
        testExtensionStats(root)
        testFilterAndRanking(root)
        testFilteringFoldsCaseBeyondASCII()
        testPercentOfParentSortsByTheMetricOnShow()
        testStorageIsClassified()
        testAScanIsReportedInTheSpaceItOccupies()
        testTheRunningCountEndsAtTheScansTotals()
        testTheTablesAreRankedByTheMeasureOnShow()
        testHardLinkSavingsAreKeptInBothMeasures()
        testASupersededWalkNeverDelivers()
        testDeepestReachableTreeIsWalked()
        // Runs before anything that deletes from the fixture: it asserts the
        // fixture is *still there* afterwards, which a later check couldn't
        // distinguish from an earlier one having removed part of it.
        testScanRootIsNeverDeletable(root)
        testVolumeAndHomeRootsAreRefused()
        testDeleteReturnsBeforeItHasFinished()
        testDeleteCanBeStopped()
        testARemovalCountsWhatItRemoves()
        testARemovalStopsWhereItIsAsked()
        testARemovalCarriesOnPastWhatItCannotRemove()
        testARemovalReachesPastPathMax()
        testADeleteThatLeavesSomethingShowsWhatIsLeft()
        testAPartialDeletePastPathMaxShowsWhatIsLeft()
        testADeleteCanBeStoppedPartWay()
        testRowsKeepTheirPlacesAcrossADelete()
        testEqualFilesKeepTheirOrderAcrossADelete()
        testTheFileListKeepsItsPlaceAcrossADelete()
        testTheDeleteLineStaysWithinWhatWasCounted()
        testAScanCannotStartDuringADelete()
        testAPendingDeleteDoesNotOutliveTheTree()
        testTheDeleteKeysActOnWhatIsOnShow()
        testTrashUpdatesTree(root)
        testPermanentDeleteFolder(root)
        testStaleReferencesSurviveADelete(batchRoot)
        testFileRowsNeverOutliveADelete(batchRoot)
        testFileRowsDontOutliveTheirScan(batchRoot)
        testARefFromAReplacedScanIsInert(batchRoot)
        testAncestorDedupe(batchRoot)
        testDeletingTheCountedNameOfAPairPromotesTheOther()
        testDeletingTheDuplicateNameFreesTheOther()
        testDeletingAFolderHandsItsHardLinksOn()
        testAFolderPromisesOnlyWhatDeletingItFrees()
        testATrashedNameStillSharesItsStorage()
        testFileTypesFollowADelete()
        testDeletingALinkWithNoPartnerInTreeSubtracts()
        testTreemapLayoutIsFencedAgainstDeletes()
        testAQueuedLayoutPinsTheFoldersAboveItsRoot()
        testAStaleMapAnswersNoClicks()
        testBatchTrashOfSiblings(batchRoot)
        testBatchDeleteOfNestedSelection(batchRoot)
        testSystemProtectionRefusal()
        testScanOutcomeReporting()
        testVolumeFreeSpaceFollowsADelete()
        testTheVolumeListFollowsMountsAndUnmounts()
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
    // rows/{r1,r2,r3}.dat 1,100 / 1,200 / 1,300
    private static func buildBatchFixture(at root: URL) throws {
        let manager = FileManager.default
        for folder in ["siblings", "stale", "nest/inner", "rows"] {
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
        try write(root.appendingPathComponent("rows/r1.dat"), bytes: 1_100)
        try write(root.appendingPathComponent("rows/r2.dat"), bytes: 1_200)
        try write(root.appendingPathComponent("rows/r3.dat"), bytes: 1_300)
    }

    /// A hard-linked pair whose two names sit in *different* folders, so the
    /// promotion has to move bytes between two chains rather than cancel out
    /// inside one.
    ///
    /// Its own root rather than part of the batch fixture: three of the File
    /// View checks there assert a row per file, and `largestFiles` skips
    /// duplicate links, so a hard link anywhere in that tree breaks them.
    private static func buildLinkedPair(at root: URL) throws {
        let manager = FileManager.default
        for folder in ["left", "right"] {
            try manager.createDirectory(
                at: root.appendingPathComponent(folder),
                withIntermediateDirectories: true
            )
        }
        try write(root.appendingPathComponent("left/shared.dat"), bytes: 9_000)
        try manager.linkItem(
            at: root.appendingPathComponent("left/shared.dat"),
            to: root.appendingPathComponent("right/mirror.dat")
        )
    }

    /// A file inside the scan hard-linked to one outside it.
    ///
    /// The scan sees only one of its names, so nothing is marked duplicate and
    /// there is no survivor to promote — deleting it really does take those
    /// bytes out of the tree, and the totals have to drop.
    private static func buildOutsideLink(at root: URL, outside: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(
            at: outside.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write(outside, bytes: 11_000)
        try manager.linkItem(at: outside, to: root.appendingPathComponent("inside.dat"))
    }

    /// Hard links in every arrangement a folder delete has to get right.
    ///
    /// plain/p.dat        5,000
    /// left/shared.dat    9,000  one inode, a name in each of two folders
    /// right/mirror.dat
    /// both/x.dat         7,000  one inode, both names under one folder
    /// both/inner/y.dat
    /// trio/{a,b,c}/t.dat 2,000  one inode, three names in three folders
    /// mixed/m.dat        3,000
    /// mixed/out.dat     11,000  its other name is outside the scan
    private static func buildLinkFarm(at root: URL, outside: URL) throws {
        let manager = FileManager.default
        for folder in [
            "plain", "left", "right", "both/inner", "trio/a", "trio/b", "trio/c",
            "mixed",
        ] {
            try manager.createDirectory(
                at: root.appendingPathComponent(folder),
                withIntermediateDirectories: true
            )
        }
        try manager.createDirectory(
            at: outside.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        func link(_ from: String, _ to: String) throws {
            try manager.linkItem(
                at: root.appendingPathComponent(from),
                to: root.appendingPathComponent(to)
            )
        }
        try write(root.appendingPathComponent("plain/p.dat"), bytes: 5_000)
        try write(root.appendingPathComponent("left/shared.dat"), bytes: 9_000)
        try link("left/shared.dat", "right/mirror.dat")
        try write(root.appendingPathComponent("both/x.dat"), bytes: 7_000)
        try link("both/x.dat", "both/inner/y.dat")
        try write(root.appendingPathComponent("trio/a/t.dat"), bytes: 2_000)
        try link("trio/a/t.dat", "trio/b/t.dat")
        try link("trio/a/t.dat", "trio/c/t.dat")
        try write(root.appendingPathComponent("mixed/m.dat"), bytes: 3_000)
        try write(outside, bytes: 11_000)
        try manager.linkItem(
            at: outside,
            to: root.appendingPathComponent("mixed/out.dat")
        )
    }

    /// Builds a link farm of its own, scans it through a model, and hands both
    /// to `body`. Every check that deletes from one gets a fresh copy, so none
    /// of their expected totals depend on what ran before.
    @MainActor
    private static func withLinkFarm(
        _ tag: String,
        _ body: (AppModel, ScanResult) -> Void
    ) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-farm-\(tag)-\(getpid())")
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-farm-\(tag)-outside-\(getpid())")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: outside)
        }
        do {
            try buildLinkFarm(
                at: base,
                outside: outside.appendingPathComponent("target.dat")
            )
        } catch {
            check("the link farm (\(tag)) can be built", false, "\(error)")
            return
        }
        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        body(model, result)
    }

    /// Which of two folders holds a pair's counted name and which its
    /// duplicate. The scan counts whichever a worker reaches first, so the
    /// roles are looked up rather than assumed.
    private static func roles(
        _ a: DirNode?,
        _ b: DirNode?
    ) -> (counted: DirNode, duplicate: DirNode)? {
        guard let a, let b else { return nil }
        if a.files.contains(where: \.isDuplicateLink) { return (b, a) }
        if b.files.contains(where: \.isDuplicateLink) { return (a, b) }
        return nil
    }

    private static func write(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    private static func scan(_ root: URL) -> ScanResult {
        guard case .completed(let result) =
            ScanEngine().scanSynchronously(rootPath: root.path)
        else {
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

    /// The File View filter lowercased what was typed with full Unicode rules
    /// and then compared it against file names folding only A–Z, so a name with
    /// an accented capital could not be found by typing it — in either case.
    /// Normalization hid more than that: most of macOS writes `é` as `e` plus a
    /// combining accent, and a text field types the single precomposed scalar,
    /// so an accent typed into the filter matched almost nothing at all.
    ///
    /// The names are created through `open(2)` rather than `FileManager`, which
    /// would decompose them all on the way to disk; this needs one of each.
    private static func testFilteringFoldsCaseBeyondASCII() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-fold-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }

        let precomposed = "\u{C9}lan.MOV"  // É as one scalar
        let decomposed = "RE\u{301}SUME\u{301}.pdf"  // É as E + combining acute
        let umlaut = "\u{DC}BUNG.pdf"  // Ü as one scalar
        let cyrillic = "\u{414}\u{41E}\u{41A}\u{41B}\u{410}\u{414}.txt"  // ДОКЛАД
        // Both fold to plain ASCII — ß to "ss", the ligature to "ff" — which is
        // what makes them a trap: the folded filter has nothing non-ASCII left
        // in it, and the names still do.
        let eszett = "Stra\u{DF}e.txt"  // Straße
        let ligature = "o\u{FB00}ice.txt"  // oﬀice
        let names = [
            precomposed, decomposed, umlaut, cyrillic, eszett, ligature, "plain.txt",
        ]
        do {
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
            for (i, name) in names.enumerated() {
                let fd = (base.path + "/" + name).withCString {
                    open($0, O_CREAT | O_WRONLY, 0o644)
                }
                guard fd >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let bytes = [UInt8](repeating: 0x41, count: 1_000 + i * 100)
                _ = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
        } catch {
            check("the folding fixture can be built", false, "\(error)")
            return
        }

        let result = scan(base)
        check(
            "the folding fixture scanned",
            result.root.files.count == names.count,
            "got \(result.root.files.map(\.name))"
        )
        func found(_ query: String) -> [String] {
            result.largestFiles(matching: query, limit: 10).map(\.name)
        }
        func finds(_ query: String, _ name: String) -> Bool {
            // String equality is canonical equivalence, so this holds however
            // the filesystem chose to store the name.
            found(query).count == 1 && found(query).first == name
        }

        // The floor under everything below: whatever folding does, a file has
        // to be findable by typing its own name.
        let lost = names.filter { !found($0).contains($0) }
        check(
            "every name is found by typing it exactly",
            lost.isEmpty,
            "not found by their own names: \(lost)"
        )
        check(
            "including ones whose letters fold to plain ASCII",
            finds("stra\u{DF}e", eszett) && finds("O\u{FB00}ICE", ligature),
            "got \(found("stra\u{DF}e")) and \(found("O\u{FB00}ICE"))"
        )
        check(
            "an accented capital is found by typing it",
            finds("\u{C9}lan", precomposed),
            "got \(found("\u{C9}lan"))"
        )
        check(
            "and by typing it in lower case",
            finds("\u{E9}lan", precomposed),
            "got \(found("\u{E9}lan"))"
        )
        check(
            "an upper-case umlaut is found either way too",
            finds("\u{DC}BUNG", umlaut) && finds("\u{FC}bung", umlaut),
            "got \(found("\u{DC}BUNG")) and \(found("\u{FC}bung"))"
        )
        check(
            "a typed accent finds a name stored as a letter plus a combining mark",
            finds("r\u{E9}sum\u{E9}", decomposed),
            "got \(found("r\u{E9}sum\u{E9}"))"
        )
        check(
            "and a combining mark in the filter finds a name stored precomposed",
            finds("e\u{301}lan", precomposed),
            "got \(found("e\u{301}lan"))"
        )
        check(
            "capitals with no ASCII letter under them fold as well",
            finds("\u{434}\u{43E}\u{43A}\u{43B}\u{430}\u{434}", cyrillic),
            "got \(found("\u{434}\u{43E}\u{43A}\u{43B}\u{430}\u{434}"))"
        )
        check(
            "a path filter folds the same way",
            finds("/\u{E9}lan", precomposed),
            "got \(found("/\u{E9}lan"))"
        )
        // A pure-ASCII name is compared as it stands, which has to give the
        // answer folding it would have: the ß typed here folds to "ss".
        check(
            "a folded filter still reaches names with nothing to fold",
            "CLASSES.txt".containsFolded("cla\u{DF}es".foldedForSearch)
                && !"plain.txt".containsFolded("\u{E9}".foldedForSearch),
            "an ASCII name was compared differently from a folded one"
        )
        check(
            "a letter that is in none of the names matches none of them",
            found("\u{F1}").isEmpty,
            "got \(found("\u{F1}"))"
        )
        // The byte-for-byte path most filters take is untouched.
        check(
            "plain ASCII filters still match, across an accented name too",
            finds("PLAIN", "plain.txt") && finds("lan.mov", precomposed),
            "got \(found("PLAIN")) and \(found("lan.mov"))"
        )
    }

    /// A sparse file and a smaller one that is fully allocated, so the two size
    /// metrics rank them in opposite orders.
    ///
    /// sparse.img  8,000,000 bytes long, next to nothing on disk
    /// solid.dat     200,000 bytes, all of them written
    private static func buildSparseFixture(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let sparse = root.appendingPathComponent("sparse.img")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 8_000_000)
        try handle.close()
        try write(root.appendingPathComponent("solid.dat"), bytes: 200_000)
    }

    /// "% of Parent" is drawn with the metric on show, but sorting by it ranked
    /// rows by logical size whatever that metric was. With On Disk showing —
    /// the default — a sparse image sorted above a file that visibly took far
    /// more of the folder, and the column read out of order.
    @MainActor
    private static func testPercentOfParentSortsByTheMetricOnShow() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-percent-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildSparseFixture(at: base)
        } catch {
            check("the sparse fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let sparse = result.root.files.first(where: { $0.name == "sparse.img" }),
            let solid = result.root.files.first(where: { $0.name == "solid.dat" }),
            sparse.size > solid.size, sparse.alloc < solid.alloc
        else {
            check(
                "the sparse fixture ranks differently by size and on disk",
                false,
                "\(result.root.files.map { "\($0.name) \($0.size)/\($0.alloc)" })"
            )
            return
        }

        func order() -> [String] {
            model.treeRows.filter { !$0.ref.isDirectory }.map(\.ref.name)
        }
        func percentages() -> [Double] {
            model.treeRows.filter { !$0.ref.isDirectory }
                .map { $0.ref.fractionOfParent(using: model.sizeMetric) }
        }

        model.treeSort = [TreeSort(.percent)]
        model.rebuildTreeRows()
        check(
            "sorted by % of Parent with On Disk showing, the fuller file leads",
            order() == ["solid.dat", "sparse.img"],
            "got \(order())"
        )
        check(
            "so the percentages on show run in order",
            percentages() == percentages().sorted(by: >),
            "got \(percentages())"
        )

        model.sizeMetric = .logical
        model.rebuildTreeRows()
        check(
            "and with Size showing, the longer one does",
            order() == ["sparse.img", "solid.dat"]
                && percentages() == percentages().sorted(by: >),
            "got \(order()) at \(percentages())"
        )

        model.treeSort = [TreeSort(.percent, order: .forward)]
        model.rebuildTreeRows()
        check(
            "ascending reverses it rather than falling back to another column",
            order() == ["solid.dat", "sparse.img"],
            "got \(order())"
        )
    }

    // MARK: - Length against space occupied
    //
    // A file's length and the space it takes are two different numbers, and a
    // sparse image can put them a thousandfold apart. Everything on screen is
    // supposed to pick whichever the Size / On Disk control says; the lines
    // that summarise the scan didn't, and quoted lengths regardless.

    /// Which files have a length that isn't all on disk, and why.
    ///
    /// Told apart from attributes the scan already reads, so the cases that
    /// can't be made in a temporary folder — a file a cloud provider holds, a
    /// compressed system binary — are put to the rule directly, and the ones
    /// that can are scanned for real.
    private static func testStorageIsClassified() {
        let compressed: UInt32 = 0x20
        let dataless: UInt32 = 0x4000_0000
        func kind(
            _ size: UInt64,
            _ alloc: UInt64,
            _ flags: UInt32 = 0,
            regular: Bool = true,
            holes: Bool = true
        ) -> FileStorage {
            FileStorage.classify(
                isRegularFile: regular,
                size: size,
                alloc: alloc,
                bsdFlags: flags,
                shortfallMeansHoles: holes
            )
        }

        check(
            "a file occupying less than its length is sparse",
            kind(8_000_000, 0) == .sparse && kind(50_065_536, 147_456) == .sparse,
            "got \(kind(8_000_000, 0)) and \(kind(50_065_536, 147_456))"
        )
        check(
            "one rounded up to whole blocks, or exactly filling them, is not",
            kind(5_000, 8_192) == .whole && kind(4_096, 4_096) == .whole
                && kind(0, 0) == .whole,
            "got \(kind(5_000, 8_192)), \(kind(4_096, 4_096)), \(kind(0, 0))"
        )
        check(
            "a compressed file is all there, however little it occupies",
            kind(184_336, 24_576, compressed) == .whole,
            "got \(kind(184_336, 24_576, compressed))"
        )
        check(
            "a file a cloud provider is holding is dataless, compressed or not",
            kind(2_000_000_000, 0, dataless) == .dataless
                && kind(2_000_000_000, 0, dataless | compressed) == .dataless,
            "got \(kind(2_000_000_000, 0, dataless))"
        )
        check(
            "a symlink is its target's path and nothing else",
            kind(9, 0, regular: false) == .whole,
            "got \(kind(9, 0, regular: false))"
        )
        // A share that reports no allocation, or less than the length for
        // every file it compresses, would have each of them called mostly
        // unwritten. Only a filesystem the rule was measured on is trusted.
        check(
            "where allocation can't be taken at its word, a shortfall isn't holes",
            kind(8_000_000, 0, holes: false) == .whole
                && kind(50_065_536, 147_456, holes: false) == .whole,
            "got \(kind(8_000_000, 0, holes: false))"
        )
        check(
            "a dataless file still says so itself there",
            kind(2_000_000_000, 0, dataless, holes: false) == .dataless,
            "got \(kind(2_000_000_000, 0, dataless, holes: false))"
        )
        check(
            "that trust is given to APFS and nothing else",
            FileStorage.shortfallMeansHoles(onFilesystem: "apfs")
                && !["hfs", "smbfs", "nfs", "exfat", "msdos", "ntfs", ""]
                    .contains(where: FileStorage.shortfallMeansHoles(onFilesystem:)),
            "apfs: \(FileStorage.shortfallMeansHoles(onFilesystem: "apfs"))"
        )
        check(
            "the startup volume's filesystem can be named",
            VolumeInfo.filesystemType(of: "/") == "apfs"
                && VolumeInfo.filesystemType(
                    of: NSTemporaryDirectory() + "wizzzee-nowhere-\(getpid())"
                ).isEmpty,
            "got “\(VolumeInfo.filesystemType(of: "/"))”"
        )

        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-storage-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildSparseFixture(at: base)
            try FileManager.default.createSymbolicLink(
                at: base.appendingPathComponent("alias.img"),
                withDestinationURL: base.appendingPathComponent("sparse.img")
            )
        } catch {
            check("the storage fixture can be built", false, "\(error)")
            return
        }
        let result = scan(base)
        func found(_ name: String) -> FileEntry? {
            result.root.files.first { $0.name == name }
        }
        check(
            "a scan marks the sparse file",
            found("sparse.img")?.storage == .sparse
                && found("sparse.img")?.storageNote == "sparse",
            "got \(String(describing: found("sparse.img")?.storage))"
        )
        check(
            "and leaves the file beside it, and the link to it, unmarked",
            found("solid.dat")?.storage == .whole
                && found("solid.dat")?.storageNote == nil
                && found("alias.img")?.storage == .whole,
            "solid \(String(describing: found("solid.dat")?.storage)), "
                + "alias \(String(describing: found("alias.img")?.storage))"
        )
        check(
            "the note's explanation gives both figures",
            found("sparse.img")?.storageExplanation?.contains(
                ByteFormat.decimal(8_000_000)
            ) == true,
            "got \(String(describing: found("sparse.img")?.storageExplanation))"
        )

        // Compressed and dataless files are told from their flags, which come
        // out of the same reply buffer as the sizes. A flag read from the
        // wrong place would leave every size right and every other check
        // green while each compressed file on the disk was called sparse, so
        // one is set here where it can be looked for.
        let flagged = base.appendingPathComponent("solid.dat").path
        let wasSet = chflags(flagged, UInt32(UF_NODUMP)) == 0
        var flagsRead: [String: UInt32] = [:]
        let fixtureFD = open(base.path, O_RDONLY | O_DIRECTORY)
        if fixtureFD >= 0 {
            _ = BulkEnumerator().enumerate(fd: fixtureFD) { entry in
                flagsRead[entry.name] = entry.bsdFlags
            }
            close(fixtureFD)
        }
        check(
            "a file's flags are read from where the filesystem puts them",
            wasSet
                && flagsRead["solid.dat"].map { $0 & UInt32(UF_NODUMP) != 0 } == true
                && flagsRead["sparse.img"].map { $0 & UInt32(UF_NODUMP) == 0 } == true,
            "set: \(wasSet); read back "
                + "\(flagsRead.mapValues { String($0, radix: 16) })"
        )

        // The system's own binaries are stored compressed, so they occupy a
        // fraction of their length without a byte of them being missing. Only
        // entries the filesystem itself says are compressed are judged, so
        // what a machine happens to keep in `/bin` can't fail this — and where
        // it keeps nothing compressed there, the check above is what stands.
        var compressedEntries: [BulkEntry] = []
        let fd = open("/bin", O_RDONLY | O_DIRECTORY)
        if fd >= 0 {
            _ = BulkEnumerator().enumerate(fd: fd) { entry in
                if entry.bsdFlags & compressed != 0 { compressedEntries.append(entry) }
            }
            close(fd)
        }
        let mistaken = compressedEntries.filter {
            $0.storage(shortfallMeansHoles: true) != .whole
        }
        let shorter = compressedEntries.filter { $0.alloc < $0.size }.count
        check(
            "the system's compressed binaries are not taken for sparse files",
            mistaken.isEmpty,
            "\(compressedEntries.count) compressed, \(shorter) of them occupying "
                + "less than their length; marked: "
                + "\(mistaken.map { "\($0.name) \($0.size)/\($0.alloc)" })"
        )
    }

    /// A sparse image longer than the volume it sits on, beside an ordinary
    /// file — the shape of a container runtime's disk image.
    ///
    /// image.raw   twice the volume's capacity long, 300,000 bytes written
    /// solid.dat   200,000 bytes, all of them written
    ///
    /// Returns nil where the filesystem would not keep the image sparse: the
    /// length is only safe to ask for where it costs nothing.
    private static func buildOversizedImage(at root: URL) throws -> UInt64? {
        try buildSparseFixture(at: root)
        var probe = stat()
        guard stat(root.appendingPathComponent("sparse.img").path, &probe) == 0,
            UInt64(probe.st_blocks) * 512 < UInt64(probe.st_size)
        else { return nil }
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("sparse.img")
        )

        let capacity = VolumeInfo.capacity(of: root.path).total
        guard capacity > 0, capacity < UInt64.max / 4 else { return nil }
        let image = root.appendingPathComponent("image.raw")
        try write(image, bytes: 300_000)
        let handle = try FileHandle(forWritingTo: image)
        try handle.truncate(atOffset: capacity * 2)
        try handle.close()
        return capacity
    }

    /// The header reported a scan of a 995 GB disk as 1.7 TB.
    ///
    /// One file did it: a container runtime's disk image, 995 GB long and
    /// occupying 42 GB. With On Disk showing — the default — the treemap, the
    /// bars and the sort all measured the 42 GB, while the header's "Scanned"
    /// line, the status line and the tooltip strip added up lengths whatever
    /// the control said. The result was a scan that claimed to have found more
    /// than the volume holds, directly above the line giving its capacity.
    @MainActor
    private static func testAScanIsReportedInTheSpaceItOccupies() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-oversized-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        let capacity: UInt64
        do {
            guard let total = try buildOversizedImage(at: base) else {
                check(
                    "an image longer than its volume can be made",
                    false,
                    "the temporary folder's filesystem doesn't keep files sparse"
                )
                return
            }
            capacity = total
        } catch {
            check("the oversized image can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        let root = result.root
        guard let index = root.files.firstIndex(where: { $0.name == "image.raw" })
        else {
            check("the image was scanned", false, "\(root.files.map(\.name))")
            return
        }
        let image = NodeRef(dir: root, fileIndex: index)
        let length = ByteFormat.decimal(root.totalSize)
        let occupied = ByteFormat.decimal(root.totalAlloc)

        check(
            "the fixture's files are longer than the volume they are on",
            root.totalSize > capacity && root.totalAlloc < capacity
                && model.targetCapacity.total == capacity,
            "length \(root.totalSize), on disk \(root.totalAlloc), "
                + "volume \(capacity)"
        )
        check(
            "what the scan says it found fits on the volume it found it on",
            model.sizeMetric == .allocated
                && model.scannedBytes == root.totalAlloc
                && model.scannedBytes <= capacity,
            "reported \(model.scannedBytes) on a volume of \(capacity)"
        )
        check(
            "the header's Scanned line quotes that, and not the files' length",
            model.scannedSummary == "\(occupied)  (2 files)",
            "got \(String(describing: model.scannedSummary))"
        )
        check(
            "the status line sizes a selected folder the same way",
            model.selectionSummary(NodeRef(root)).contains("  •  \(occupied)  •  ")
                && !model.selectionSummary(NodeRef(root)).contains(length),
            "got \(model.selectionSummary(NodeRef(root)))"
        )
        check(
            "and a selected file, where the two are furthest apart",
            model.selectionSummary(image).hasSuffix(
                ByteFormat.decimal(root.files[index].alloc)
            ),
            "got \(model.selectionSummary(image))"
        )
        check(
            "the image is marked, so the gap between its two sizes explains itself",
            root.files[index].storage == .sparse
                && root.files[index].storageExplanation?
                    .hasSuffix("Deleting it frees the smaller figure.") == true,
            "got \(root.files[index].storage): "
                + "\(root.files[index].storageExplanation ?? "no explanation")"
        )

        // A scan still running has no totals yet, only what it has passed.
        var running = ScanEngine.Progress()
        running.items = 3
        running.bytes = capacity * 2
        running.allocated = 500_000
        model.progress = running
        check(
            "a scan under way is counted in space on disk too",
            model.progressSummary.hasSuffix("items, \(ByteFormat.decimal(500_000))"),
            "got \(model.progressSummary)"
        )

        model.sizeMetric = .logical
        check(
            "with Size showing, the line leads with the length that was asked for",
            model.scannedBytes == root.totalSize
                && model.scannedSummary?.hasPrefix("\(length)  •  ") == true,
            "got \(String(describing: model.scannedSummary))"
        )
        // Ahead of the file count, which is what a narrow header cuts short.
        check(
            "and says what that occupies straight after, since a length can exceed the disk",
            model.scannedSummary == "\(length)  •  \(occupied) on disk  (2 files)",
            "got \(String(describing: model.scannedSummary))"
        )
        check(
            "the status line follows the control",
            model.selectionSummary(NodeRef(root)).contains("  •  \(length)  •  "),
            "got \(model.selectionSummary(NodeRef(root)))"
        )
        check(
            "so does the running count, with the space it takes beside it",
            model.progressSummary.hasSuffix(
                "items, \(ByteFormat.decimal(capacity * 2))  •  "
                    + "\(ByteFormat.decimal(500_000)) on disk"
            ),
            "got \(model.progressSummary)"
        )
        model.progress = ScanEngine.Progress()

        // Still with Size showing: what a delete gives back is space, and the
        // confirmation that says so can't quote the length the list is in.
        check(
            "a delete promises back what the image occupies, not how long it is",
            model.reclaimableSpace([image]) == root.files[index].alloc
                && model.reclaimableSize([image]) == root.files[index].size,
            "promised \(model.reclaimableSpace([image])) for a file occupying "
                + "\(root.files[index].alloc); the selection reads "
                + "\(model.reclaimableSize([image]))"
        )
        check(
            "the treemap's tooltip leads with the measure its tiles are drawn from",
            TreemapNSView.tooltipDetail(for: image, metric: .logical)
                .hasPrefix("\(ByteFormat.decimal(root.files[index].size))  •  on disk ")
                && TreemapNSView.tooltipDetail(for: image, metric: .allocated)
                    .hasPrefix("\(ByteFormat.decimal(root.files[index].alloc)) on disk"),
            "got “\(TreemapNSView.tooltipDetail(for: image, metric: .logical))” "
                + "and “\(TreemapNSView.tooltipDetail(for: image, metric: .allocated))”"
        )

        // Deleting the image has to take the right figure out of each.
        model.sizeMetric = .allocated
        let solid = root.files.first { $0.name == "solid.dat" }?.alloc ?? 0
        deletePermanently(model, [image])
        check(
            "deleting the image leaves both measures describing what is left",
            model.actionError == nil && root.totalAlloc == solid
                && root.totalSize == 200_000
                && model.scannedSummary
                    == "\(ByteFormat.decimal(solid))  (1 file)",
            "error \(model.actionError ?? "none"); on disk \(root.totalAlloc) "
                + "of \(solid), length \(root.totalSize); "
                + "line \(String(describing: model.scannedSummary))"
        )
    }

    /// The count shown while a scan runs is kept by the workers as they go, in
    /// both measures, apart from the totals worked out once they finish. The
    /// two have to end in the same place, or the line under the Scan button
    /// stops on one number and the header opens on another.
    private static func testTheRunningCountEndsAtTheScansTotals() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-running-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildSparseFixture(at: base)
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("inner"),
                withIntermediateDirectories: true
            )
            try write(base.appendingPathComponent("inner/more.dat"), bytes: 30_000)
            try FileManager.default.linkItem(
                at: base.appendingPathComponent("inner/more.dat"),
                to: base.appendingPathComponent("inner/again.dat")
            )
        } catch {
            check("the running-count fixture can be built", false, "\(error)")
            return
        }

        let engine = ScanEngine()
        guard case .completed(let result) =
            engine.scanSynchronously(rootPath: base.path)
        else {
            check("the running-count fixture scans", false, "no result")
            return
        }
        let counted = engine.counters()
        check(
            "the running count of space on disk ends at the scan's total",
            counted.allocated == result.root.totalAlloc,
            "counted \(counted.allocated), total \(result.root.totalAlloc)"
        )
        check(
            "so does the running length, with a hard link's bytes counted once",
            counted.bytes == result.root.totalSize
                && counted.items == result.root.totalItems,
            "counted \(counted.bytes) in \(counted.items) items, total "
                + "\(result.root.totalSize) in \(result.root.totalItems)"
        )
        check(
            "the two measures are far apart here, so neither stood in for the other",
            counted.bytes > counted.allocated * 10,
            "length \(counted.bytes), on disk \(counted.allocated)"
        )
    }

    /// An order that was by the measure on show becomes an order by the new
    /// one when the measure changes.
    ///
    /// Changing it used to leave both tables ranked by the measure just
    /// switched away from, under bars — redrawn from the new one — that no
    /// longer ran in any order.
    @MainActor
    private static func testTheTablesAreRankedByTheMeasureOnShow() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-leading-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildSparseFixture(at: base)
        } catch {
            check("the leading-column fixture can be built", false, "\(error)")
            return
        }
        let model = AppModel()
        model.customFolder = base.path
        guard loadSynchronously(into: model) != nil else { return }
        pumpUntilFileRowsSettle(model, expecting: 2)

        func tree() -> [String] {
            model.treeRows.filter { !$0.ref.isDirectory }.map(\.ref.name)
        }
        func files() -> [String] { model.fileRows.map(\.name) }
        func settle() {
            let deadline = Date().addingTimeInterval(10)
            // One turn first: the walk is queued, not yet marked as running.
            repeat {
                RunLoop.main.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.02)
                )
            } while model.isFilteringFiles && Date() < deadline
        }

        check(
            "to begin with both tables are ranked by space on disk",
            model.sizeMetric == .allocated
                && model.treeSort.first?.key == SizeMetric.allocated.sortKey
                && model.fileSort.first?.keyPath == \FileRow.alloc
                && tree() == ["solid.dat", "sparse.img"]
                && files() == ["solid.dat", "sparse.img"],
            "tree \(tree()), files \(files())"
        )

        model.sizeMetric = .logical
        settle()
        check(
            "switching to Size ranks the tree by length without another click",
            model.treeSort.first?.key == .size
                && tree() == ["sparse.img", "solid.dat"],
            "sorted by \(String(describing: model.treeSort.first?.key)): \(tree())"
        )
        check(
            "and the file list with it",
            model.fileSort.first?.keyPath == \FileRow.size
                && files() == ["sparse.img", "solid.dat"],
            "got \(files())"
        )

        model.treeSort = [TreeSort(.size, order: .forward)]
        model.fileSort = [KeyPathComparator(\FileRow.size, order: .forward)]
        model.sizeMetric = .allocated
        settle()
        check(
            "an ascending order stays ascending across the change",
            model.treeSort.first == TreeSort(.allocated, order: .forward)
                && model.fileSort.first?.order == .forward
                && model.fileSort.first?.keyPath == \FileRow.alloc
                && tree() == ["sparse.img", "solid.dat"]
                && files() == ["sparse.img", "solid.dat"],
            "tree \(tree()), files \(files())"
        )

        model.treeSort = [TreeSort(.name, order: .forward)]
        model.fileSort = [KeyPathComparator(\FileRow.name, order: .forward)]
        model.sizeMetric = .logical
        settle()
        check(
            "an order by something else is left as it was chosen",
            model.treeSort.first == TreeSort(.name, order: .forward)
                && model.fileSort.first?.keyPath == \FileRow.name
                && tree() == ["solid.dat", "sparse.img"],
            "sorted by \(String(describing: model.treeSort.first?.key)): \(tree())"
        )

        // Ranked by the measure that is *not* on show: picked on purpose.
        model.treeSort = [TreeSort(.allocated)]
        model.fileSort = [KeyPathComparator(\FileRow.alloc, order: .reverse)]
        model.sizeMetric = .allocated
        settle()
        check(
            "so is an order by the measure that was not the one on show",
            model.treeSort.first?.key == .allocated
                && model.fileSort.first?.keyPath == \FileRow.alloc
                && tree() == ["solid.dat", "sparse.img"],
            "sorted by \(String(describing: model.treeSort.first?.key)): \(tree())"
        )
    }

    /// Every duplicate name still in the tree, added up in both measures —
    /// what the double-counting figures ought to read at any moment.
    private static func duplicateNames(
        under root: DirNode
    ) -> (size: UInt64, alloc: UInt64) {
        var size: UInt64 = 0
        var alloc: UInt64 = 0
        var stack: [DirNode] = [root]
        while let dir = stack.popLast() {
            for file in dir.files where file.isDuplicateLink {
                size += file.size
                alloc += file.alloc
            }
            stack.append(contentsOf: dir.subdirs)
        }
        return (size, alloc)
    }

    /// The status line's "Hard links" figure was a sum of lengths, quoted next
    /// to a total of space on disk.
    ///
    /// For ordinary files the two are a block's rounding apart and nobody
    /// could tell. A second name for a sparse image is the other extreme: it
    /// saves the image's whole length by one measure and almost nothing by the
    /// other. The figure is now kept in both, and both have to stay right
    /// through every way a name can leave the tree.
    @MainActor
    private static func testHardLinkSavingsAreKeptInBothMeasures() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-sparselink-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            let manager = FileManager.default
            // The plain file gets a folder to itself. Which of the pair's two
            // names the scan counts is down to which worker gets there first,
            // so neither of their folders can hold anything else: deleting
            // the counted one has to remove a name and nothing more.
            for folder in ["one", "two", "three"] {
                try manager.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            let image = base.appendingPathComponent("one/image.raw")
            try write(image, bytes: 100_000)
            let handle = try FileHandle(forWritingTo: image)
            try handle.truncate(atOffset: 8_000_000)
            try handle.close()
            try manager.linkItem(
                at: image,
                to: base.appendingPathComponent("two/second.raw")
            )
            try write(base.appendingPathComponent("three/plain.dat"), bytes: 50_000)
        } catch {
            check("the sparse hard link can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard
            let pair = roles(
                result.root.subdir(named: "one"),
                result.root.subdir(named: "two")
            ),
            let duplicate = pair.duplicate.files.first(where: \.isDuplicateLink)
        else {
            check("the sparse pair scanned as a pair", false, "no duplicate")
            return
        }

        check(
            "a second name for a sparse image saves its length by one measure",
            result.hardLinkSavings(using: .logical) == 8_000_000,
            "got \(result.hardLinkSavings(using: .logical))"
        )
        check(
            "and only what it occupies by the other",
            result.hardLinkSavings(using: .allocated) == duplicate.alloc
                && duplicate.alloc > 0 && duplicate.alloc < 800_000,
            "got \(result.hardLinkSavings(using: .allocated)), "
                + "the file occupies \(duplicate.alloc)"
        )
        // Both names are the same sparse file, and are marked as one. Neither
        // is told that deleting it frees anything: the other name holds it.
        let names = pair.counted.files + pair.duplicate.files
        check(
            "each name of the pair is marked sparse, without a promise of space",
            names.count == 2 && names.allSatisfy { $0.storage == .sparse }
                && names.allSatisfy {
                    $0.storageExplanation?.contains("Deleting it frees") == false
                },
            "\(names.map { "\($0.name): \($0.storageExplanation ?? "nothing")" })"
        )
        check(
            "the bytes are in the totals once, in both",
            result.root.totalSize == 8_050_000
                && result.root.totalAlloc
                    == result.root.subdirs.reduce(0) { $0 + $1.totalAlloc },
            "length \(result.root.totalSize), on disk \(result.root.totalAlloc)"
        )

        // The counted name goes; the duplicate takes the bytes over and stops
        // being a duplicate, so there is nothing left to have double-counted.
        let allocBefore = result.root.totalAlloc
        deletePermanently(model, [NodeRef(pair.counted)])
        check(
            "once the other name is promoted, neither measure saves anything",
            model.actionError == nil
                && result.hardLinkSavings(using: .logical) == 0
                && result.hardLinkSavings(using: .allocated) == 0,
            "error \(model.actionError ?? "none"); length "
                + "\(result.hardLinkSavings(using: .logical)), on disk "
                + "\(result.hardLinkSavings(using: .allocated))"
        )
        check(
            "and the space on disk is where it was, under the name that is left",
            result.root.totalAlloc == allocBefore
                && result.root.totalSize == 8_050_000,
            "on disk \(result.root.totalAlloc) of \(allocBefore), "
                + "length \(result.root.totalSize)"
        )

        // Every way a name leaves, on a tree with links in each arrangement.
        func agrees(_ result: ScanResult) -> (Bool, String) {
            let names = duplicateNames(under: result.root)
            let size = result.hardLinkSavings(using: .logical)
            let alloc = result.hardLinkSavings(using: .allocated)
            return (
                size == names.size && alloc == names.alloc,
                "length \(size) against \(names.size) in the tree, "
                    + "on disk \(alloc) against \(names.alloc)"
            )
        }
        withLinkFarm("measures") { model, result in
            let start = agrees(result)
            check(
                "on a tree full of links, both figures are the duplicates' sum",
                start.0 && result.hardLinkSavings(using: .allocated) > 0,
                start.1
            )

            // A whole folder holding one name of a pair.
            if let left = result.root.subdir(named: "left") {
                deletePermanently(model, [NodeRef(left)])
            }
            let afterFolder = agrees(result)
            check(
                "they still are once a folder holding one name is deleted",
                model.actionError == nil && afterFolder.0,
                afterFolder.1
            )

            // One name of three, by itself.
            if let a = result.root.subdir(named: "trio")?.subdir(named: "a"),
                !a.files.isEmpty
            {
                deletePermanently(model, [NodeRef(dir: a, fileIndex: 0)])
            }
            let afterFile = agrees(result)
            check(
                "and once a single name of three is",
                model.actionError == nil && afterFile.0,
                afterFile.1
            )

            // A trashed name leaves the tree but not the disk.
            if let b = result.root.subdir(named: "trio")?.subdir(named: "b") {
                trash(model, [NodeRef(b)])
            }
            let afterTrash = agrees(result)
            check(
                "and once a folder is moved to the Trash",
                model.actionError == nil && afterTrash.0,
                afterTrash.1
            )

            // A folder with both names of a pair in it.
            if let both = result.root.subdir(named: "both") {
                deletePermanently(model, [NodeRef(both)])
            }
            let afterBoth = agrees(result)
            check(
                "and once a folder holding both names of a pair is deleted",
                model.actionError == nil && afterBoth.0,
                afterBoth.1
            )
        }
    }

    /// A newer File View walk replaced the older one's token without cancelling
    /// it, so a walk already under way ran its full pass over the scan for rows
    /// nobody would be shown, with its replacement queued behind it. Worse, a
    /// walk that had already finished still delivered: its rows — ranked by a
    /// metric no longer on show — landed first and stopped the spinner while
    /// the real answer was still on its way.
    @MainActor
    private static func testASupersededWalkNeverDelivers() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-supersede-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildSparseFixture(at: base)
        } catch {
            check("the supersede fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard loadSynchronously(into: model) != nil else { return }
        pumpUntilFileRowsSettle(model, expecting: 2)

        // The first walk is given time to finish its pass, so its rows are
        // sitting on the main queue when the metric changes under them.
        model.refreshFileRows(immediately: true)
        let first = model.fileWalkToken
        usleep(300_000)
        model.sizeMetric = .logical
        model.refreshFileRows(immediately: true)
        let second = model.fileWalkToken

        check(
            "a walk that has been replaced is told to stop",
            first !== second && first.isCancelled,
            "it was left to run its full pass"
        )
        check(
            "the walk that replaced it is not",
            !second.isCancelled,
            "the new walk was cancelled along with the old"
        )

        // Caught at the first moment the spinner stops, not once everything
        // has settled: the list keeps its old rows while a walk is running, so
        // what matters is which walk is allowed to say it has finished — and
        // the replacement would paper over a wrong answer a moment later.
        let deadline = Date().addingTimeInterval(10)
        while model.isFilteringFiles && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // The sparse file is nearly all of the scan by length and almost none
        // of it on disk, so its share says which metric the rows were built
        // for. The table's own sort column decides their order, not this.
        let share = model.fileRows.first { $0.name == "sparse.img" }?.fractionOfRoot
        check(
            "its rows never reach the list",
            (share ?? 0) > 0.9,
            "the spinner stopped on rows built for the metric just switched "
                + "away from: sparse.img at \(String(describing: share)) of the scan"
        )
        check(
            "and the replacement's rows do",
            !model.isFilteringFiles && model.fileRows.count == 2,
            "filtering=\(model.isFilteringFiles), rows \(model.fileRows.map(\.name))"
        )

        model.refreshFileRows(immediately: true)
        let third = model.fileWalkToken
        model.startScan()
        check(
            "a rescan stops a walk over the tree it is throwing away",
            third.isCancelled,
            "it was left to finish, holding the old scan in memory"
        )
        pumpUntilSettled(model)
    }

    /// Aggregation, the extension remap and the File View's walk each descend
    /// once per directory level, on threads with a 512 KB stack.
    ///
    /// How deep that can go is bounded by `PATH_MAX`, not by the tree: the
    /// workers `open` an absolute path per directory, so anything past ~1024
    /// bytes of path is unreachable however deep it was built. This walks the
    /// deepest tree the scanner can actually enter and checks that all three
    /// traversals reach the bottom of it and come back with the right totals.
    private static func testDeepestReachableTreeIsWalked() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-deep-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }

        // Two bytes of path per level ("/d"), leaving room for the file name at
        // the bottom and whatever the temporary directory itself costs.
        let depth = (Int(PATH_MAX) - base.path.utf8.count - 64) / 2
        guard depth > 100 else {
            check("there is room for a deep fixture", false, "depth \(depth)")
            return
        }

        var deepest = base
        for _ in 0..<depth { deepest.appendPathComponent("d") }
        do {
            try FileManager.default.createDirectory(
                at: deepest,
                withIntermediateDirectories: true
            )
            try write(deepest.appendingPathComponent("bottom.dat"), bytes: 1_234)
        } catch {
            check("a \(depth)-level fixture can be built", false, "\(error)")
            return
        }

        let result = scan(base)
        check(
            "a \(depth)-level tree aggregates to the bottom",
            result.root.totalSize == 1_234 && result.root.totalDirs == depth,
            "got \(result.root.totalSize) bytes over \(result.root.totalDirs) "
                + "folders, expected 1234 over \(depth)"
        )
        check(
            "it reports no unreadable directories",
            result.deniedCount == 0,
            "got \(result.deniedCount)"
        )
        check(
            "the File View's walk reaches the bottom of it",
            result.largestFiles(limit: 10, metric: .logical).first?.name
                == "bottom.dat",
            "got \(result.largestFiles(limit: 10, metric: .logical).map(\.name))"
        )
        check(
            "a path filter reaches the bottom of it too",
            result.largestFiles(matching: "/d/", limit: 10).count == 1,
            "got \(result.largestFiles(matching: "/d/", limit: 10).count)"
        )
    }


    /// The delete batch runs off the main actor, so the call has to come back to
    /// the run loop before the work is done. Run on the main actor — where every
    /// caller of it is — removing a large tree stopped the run loop for minutes:
    /// no spinner, no progress, no cancel, and long enough that the system's
    /// responsiveness watchdog could kill the app part-way through.
    ///
    /// Deterministic despite being about timing: the batch's task body only runs
    /// once the main actor is yielded, so nothing can have been removed by the
    /// time the call returns.
    @MainActor
    private static func testDeleteReturnsBeforeItHasFinished() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-async-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            for folder in ["bulk", "spare"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            for i in 0..<60 {
                try write(base.appendingPathComponent("bulk/f\(i).dat"), bytes: 900)
            }
            try write(base.appendingPathComponent("spare/keep.dat"), bytes: 700)
        } catch {
            check("the async fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let bulk = result.root.subdir(named: "bulk"),
            let spare = result.root.subdir(named: "spare")
        else {
            check("the async fixture scanned", false, "missing folders")
            return
        }
        let bulkPath = bulk.path
        let sparePath = spare.path

        model.moveToTrash([NodeRef(bulk)])

        check(
            "the call returns while the batch is still running",
            model.isDeleting,
            "it had already finished, so the run loop was blocked for it"
        )
        check(
            "nothing has been removed by the time it returns",
            FileManager.default.fileExists(atPath: bulkPath),
            "the delete ran synchronously on the main thread"
        )
        check(
            "progress starts at nothing done",
            model.deleteProgress?.done == 0
                && model.deleteProgress?.total == 1,
            "got \(String(describing: model.deleteProgress))"
        )

        // A second batch started mid-flight would resolve its paths against a
        // tree the first is still changing.
        model.moveToTrash([NodeRef(spare)])
        check(
            "a second batch is refused while one is running",
            model.deleteProgress?.total == 1,
            "the second batch replaced the first"
        )

        pumpUntilDeleteSettles(model)

        check(
            "the batch finishes and clears its progress",
            !model.isDeleting && model.deleteProgress == nil,
            "still reporting \(String(describing: model.deleteProgress))"
        )
        check(
            "the folder is gone once it settles",
            !FileManager.default.fileExists(atPath: bulkPath),
            "still present"
        )
        check(
            "the refused second batch never ran",
            FileManager.default.fileExists(atPath: sparePath),
            "it was deleted after all"
        )
        check(
            "the tree is updated for the batch that did run",
            result.root.subdir(named: "bulk") == nil
                && result.root.totalFiles == 1,
            "got \(result.root.totalFiles) files"
        )
    }

    /// Stop has to be honoured before the next item is started. Cancelling
    /// before the task body has had a chance to run means nothing is removed at
    /// all, which is the one outcome that can be asserted without a race.
    @MainActor
    private static func testDeleteCanBeStopped() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-stop-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("doomed"),
                withIntermediateDirectories: true
            )
            try write(base.appendingPathComponent("doomed/a.dat"), bytes: 1_000)
        } catch {
            check("the stop fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let doomed = result.root.subdir(named: "doomed") else {
            check("the stop fixture scanned", false, "missing folder")
            return
        }
        let path = doomed.path
        let before = result.root.totalSize

        model.moveToTrash([NodeRef(doomed)])
        model.cancelDelete()
        pumpUntilDeleteSettles(model)

        check(
            "stopping before the first item leaves it on disk",
            FileManager.default.fileExists(atPath: path),
            "it was removed anyway"
        )
        check(
            "a stopped batch leaves the totals alone",
            result.root.totalSize == before,
            "root is \(result.root.totalSize), expected \(before)"
        )
        check(
            "a stopped batch clears its progress",
            !model.isDeleting,
            "still reporting itself as running"
        )
        // The model has to be usable again afterwards, not stuck refusing every
        // later batch because the cancelled one never released its slot.
        model.moveToTrash([NodeRef(doomed)])
        pumpUntilDeleteSettles(model)
        check(
            "a batch can be started again after a stop",
            !FileManager.default.fileExists(atPath: path),
            "the model stayed wedged after the cancelled batch"
        )
    }

    /// A scan started while a delete batch is running throws away the tree the
    /// batch's references point into. When the batch then finishes it applies
    /// them to whatever replaced it: hard-link counts matched by inode in a tree
    /// it never touched, and totals subtracted along a parent chain that the
    /// rescan has freed. The scan is refused instead, the same way a second
    /// batch is.
    @MainActor
    private static func testAScanCannotStartDuringADelete() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-rescan-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            for folder in ["bulk", "spare"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            for i in 0..<60 {
                try write(base.appendingPathComponent("bulk/f\(i).dat"), bytes: 900)
            }
            try write(base.appendingPathComponent("spare/keep.dat"), bytes: 700)
        } catch {
            check("the rescan fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let bulk = result.root.subdir(named: "bulk") else {
            check("the rescan fixture scanned", false, "missing folder")
            return
        }

        model.deletePermanently([NodeRef(bulk)])
        check(
            "a scan can't be started while a delete is running",
            model.isDeleting && !model.canStartScan,
            "deleting=\(model.isDeleting), canStartScan=\(model.canStartScan)"
        )
        model.startScan()
        check(
            "asking for one anyway leaves the tree the batch is working on",
            model.phase == .complete && model.result === result,
            "phase \(model.phase), same result: \(model.result === result)"
        )

        pumpUntilDeleteSettles(model)
        check(
            "the batch then lands on the tree it was started against",
            model.result === result
                && result.root.subdir(named: "bulk") == nil
                && result.root.totalFiles == 1,
            "same result: \(model.result === result), "
                + "\(result.root.totalFiles) files"
        )

        // Refusing must not outlast the batch, or the app could never rescan.
        check(
            "a scan can be started again once it settles",
            model.canStartScan,
            "still refused"
        )
        guard let rescanned = loadSynchronously(into: model) else { return }
        check(
            "and the rescan sees what the delete left",
            rescanned !== result && rescanned.root.totalFiles == 1,
            "\(rescanned.root.totalFiles) files"
        )
    }

    /// A delete awaiting confirmation was raised against the tree as it was.
    /// A batch that finishes while the dialog is up used to renumber the files
    /// it named, so confirming would have permanently deleted whatever shifted
    /// into those slots. A deleted file now keeps its slot and they go on
    /// naming what they named — but what the dialog said would be freed is
    /// from before that batch, so it is dropped and asked for again. A rescan
    /// drops it too: its references point into a tree that no longer exists.
    @MainActor
    private static func testAPendingDeleteDoesNotOutliveTheTree() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-pending-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("pending"),
                withIntermediateDirectories: true
            )
            for (i, name) in ["a", "b", "c", "d"].enumerated() {
                try write(
                    base.appendingPathComponent("pending/\(name).dat"),
                    bytes: 1_000 + i * 100
                )
            }
        } catch {
            check("the pending fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let dir = result.root.subdir(named: "pending"), dir.files.count == 4
        else {
            check("the pending fixture scanned", false, "missing files")
            return
        }

        // The first file is on its way out; the dialog is raised for two of the
        // files after it while that batch is still running.
        let pending: Set<NodeRef> = [
            NodeRef(dir: dir, fileIndex: 1), NodeRef(dir: dir, fileIndex: 2),
        ]
        let named = Set(pending.map(\.name))
        model.deletePermanently([NodeRef(dir: dir, fileIndex: 0)])
        model.permanentDeleteTargets = pending
        pumpUntilDeleteSettles(model)

        check(
            "the batch left the files the dialog was raised for as they were",
            live(dir).count == 3 && pending.allSatisfy { !$0.isStale }
                && Set(pending.map(\.name)) == named,
            "names now \(pending.map(\.name).sorted()), were \(named.sorted())"
        )
        check(
            "the pending confirmation is dropped all the same",
            model.permanentDeleteTargets.isEmpty,
            "still aimed at \(model.permanentDeleteTargets.map(\.name).sorted())"
        )

        model.permanentDeleteTargets = [NodeRef(dir: dir, fileIndex: 0)]
        model.startScan()
        check(
            "a rescan drops a pending confirmation too",
            model.permanentDeleteTargets.isEmpty,
            "still aimed at the scan that was thrown away"
        )
        pumpUntilSettled(model)
    }

    /// ⌘⌫ sends the selection to the Trash without asking, and the selection
    /// is one set shared by every tab: it keeps a row that a collapsed folder
    /// has hidden, and a folder picked in Tree View stays in it under a File
    /// View that has no row for it. So the keys act only on what the tab in
    /// front has on show, and on nothing while something else holds the
    /// keyboard or a sheet is waiting.
    //
    // shown/a.dat            3,000 bytes
    // shown/b.dat            4,000
    // deep/inner/c.dat       5,000
    // deep/inner/empty.dat   nothing, so the treemap has no tile for it
    @MainActor
    private static func testTheDeleteKeysActOnWhatIsOnShow() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-keys-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            for folder in ["shown", "deep/inner"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            try write(base.appendingPathComponent("shown/a.dat"), bytes: 3_000)
            try write(base.appendingPathComponent("shown/b.dat"), bytes: 4_000)
            try write(base.appendingPathComponent("deep/inner/c.dat"), bytes: 5_000)
            try write(base.appendingPathComponent("deep/inner/empty.dat"), bytes: 0)
        } catch {
            check("the delete-key fixture can be built", false, "\(error)")
            return
        }
        func onDisk(_ path: String) -> Bool {
            FileManager.default.fileExists(
                atPath: base.appendingPathComponent(path).path
            )
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let shown = result.root.subdir(named: "shown"),
            let deep = result.root.subdir(named: "deep"),
            let inner = deep.subdir(named: "inner"),
            let a = shown.files.firstIndex(where: { $0.name == "a.dat" }),
            let b = shown.files.firstIndex(where: { $0.name == "b.dat" }),
            let c = inner.files.firstIndex(where: { $0.name == "c.dat" }),
            let empty = inner.files.firstIndex(where: { $0.name == "empty.dat" })
        else {
            check("the delete-key fixture scanned", false, "missing entries")
            return
        }
        let aRef = NodeRef(dir: shown, fileIndex: a)
        let bRef = NodeRef(dir: shown, fileIndex: b)
        let cRef = NodeRef(dir: inner, fileIndex: c)
        let emptyRef = NodeRef(dir: inner, fileIndex: empty)
        // The treemap counts as on show for one clicked tile, so it is put
        // away until the checks that are about it.
        model.showsTreemap = false

        // A scan lands with its root selected, which is the first thing the
        // keys are ever pressed on.
        model.trashSelection()
        check(
            "⌘⌫ on the scan root explains itself instead of doing nothing",
            model.actionError != nil && !model.isDeleting && onDisk("shown/a.dat"),
            "error \(model.actionError ?? "none"), deleting \(model.isDeleting)"
        )
        check(
            "and the keys wait for that alert to be answered",
            !model.canUseDeleteKeys,
            "still live behind the alert"
        )
        model.actionError = nil
        model.actionErrorDetail = nil

        // What is on show is worked out from which folders are open, so it is
        // held to the rows the table was actually given.
        var everything: Set<NodeRef> = []
        var pending = [result.root]
        while let dir = pending.popLast() {
            everything.insert(NodeRef(dir))
            for index in dir.files.indices {
                everything.insert(NodeRef(dir: dir, fileIndex: index))
            }
            pending.append(contentsOf: dir.subdirs)
        }
        model.selection = everything
        var agreed = true
        for (dir, open) in [
            (shown, true), (inner, true), (deep, true), (deep, false),
            (shown, false),
        ] {
            model.setExpanded(dir, open)
            agreed = agreed
                && model.selectionOnShow == Set(model.treeRows.map(\.ref))
        }
        check(
            "what is on show in Tree View is exactly the table's rows",
            agreed,
            "the two disagreed as folders were opened and closed"
        )

        model.setExpanded(shown, true)
        model.selection = [aRef]
        check(
            "a selected row can be acted on",
            model.canUseDeleteKeys && model.selectionOnShow == [aRef],
            "on show: \(model.selectionOnShow.map(\.name))"
        )
        model.setExpanded(shown, false)
        model.trashSelection()
        check(
            "a row hidden by collapsing its folder is left alone",
            !model.canUseDeleteKeys && !model.isDeleting && onDisk("shown/a.dat"),
            "it was acted on"
        )

        // A tile clicked on the map is selected without being given a row, so
        // the map is asked what it is outlining. Being selected somewhere
        // under the map's root is not that: plenty under there is never
        // drawn, and ⌘⌫ went on reaching it.
        model.selection = [cRef]
        check(
            "with the treemap hidden, a file in a closed folder is not on show",
            model.selectionOnShow.isEmpty,
            "on show: \(model.selectionOnShow.map(\.name))"
        )
        model.showsTreemap = true
        check(
            "nor with it showing, until the map says it has outlined it",
            model.selectionOnShow.isEmpty && !model.canUseDeleteKeys,
            "on show: \(model.selectionOnShow.map(\.name))"
        )

        // A map wired to the model as `TreemapPane` wires it, and handed what
        // `TreemapCanvas` would hand it.
        let layouts = DispatchQueue(label: "com.wizzzee.selftest.outline")
        func makeMap() -> TreemapNSView {
            let map = TreemapNSView(
                frame: NSRect(x: 0, y: 0, width: 400, height: 300)
            )
            map.layoutQueue = layouts
            map.liveRevision = { model.treeRevision }
            map.onOutline = { model.treemapOutline = $0 }
            return map
        }
        var map = makeMap()
        func redraw() {
            map.selection = model.primarySelection
            map.apply(
                root: model.treemapRoot,
                metric: model.sizeMetric,
                revision: model.treeRevision
            )
            // The layout lands on the main queue and the outline is reported
            // on the turn after that.
            layouts.sync {}
            for _ in 0..<3 {
                RunLoop.main.run(
                    mode: .default,
                    before: Date().addingTimeInterval(0.05)
                )
            }
        }
        redraw()
        check(
            "once the map has drawn it, the one outlined tile is on show",
            model.treemapOutline == cRef && model.selectionOnShow == [cRef]
                && model.canUseDeleteKeys,
            "outlined \(model.treemapOutline?.name ?? "nothing"), "
                + "on show: \(model.selectionOnShow.map(\.name))"
        )
        model.selection = [emptyRef]
        redraw()
        model.trashSelection()
        check(
            "a file the map has no tile for is selected and left alone",
            model.treemapOutline == nil && !model.canUseDeleteKeys
                && !model.isDeleting && onDisk("deep/inner/empty.dat"),
            "outlined \(model.treemapOutline?.name ?? "nothing"), "
                + "deleting \(model.isDeleting)"
        )
        model.selection = [cRef]
        redraw()
        model.zoom(into: shown)
        redraw()
        check(
            "so is one the map is zoomed away from",
            model.treemapOutline == nil && model.selectionOnShow.isEmpty,
            "outlined \(model.treemapOutline?.name ?? "nothing")"
        )
        model.resetZoom()
        redraw()
        model.showsTreemap = false
        check(
            "and an outline counts for nothing once the map is put away",
            model.treemapOutline == cRef && model.selectionOnShow.isEmpty,
            "on show: \(model.selectionOnShow.map(\.name))"
        )
        // Putting the map away clears what it reported, and showing it again
        // makes a new one. Nothing else puts the outline back, so the new map
        // has to say so itself once it has drawn.
        model.treemapOutline = nil
        model.showsTreemap = true
        map = makeMap()
        redraw()
        check(
            "a map shown again outlines the selection again, back within reach",
            model.treemapOutline == cRef && model.canUseDeleteKeys,
            "outlined \(model.treemapOutline?.name ?? "nothing")"
        )
        model.showsTreemap = false

        // File View lists files only, so a folder picked in the tree has no
        // row there however selected it still is.
        model.tab = .files
        pumpUntilFileRowsSettle(model, expecting: 4)
        model.selection = [NodeRef(shown)]
        check(
            "a folder selected in the tree is not on show in File View",
            !model.canUseDeleteKeys,
            "on show: \(model.selectionOnShow.map(\.name))"
        )
        model.selection = [aRef]
        check(
            "a file listed there is",
            model.canUseDeleteKeys && model.selectionOnShow == [aRef],
            "on show: \(model.selectionOnShow.map(\.name))"
        )
        model.isEditingFilter = true
        model.trashSelection()
        check(
            "⌘⌫ is left to the filter while it is being typed in",
            !model.canUseDeleteKeys && !model.isDeleting && onDisk("shown/a.dat"),
            "it reached the selection"
        )
        model.isEditingFilter = false
        model.tab = .about
        check(
            "nothing is on show in About",
            !model.canUseDeleteKeys,
            "on show: \(model.selectionOnShow.map(\.name))"
        )

        model.tab = .tree
        model.setExpanded(shown, true)
        model.confirmDeletingSelection()
        check(
            "⌥⌘⌫ asks first, and removes nothing until it is answered",
            model.permanentDeleteTargets == [aRef] && !model.isDeleting
                && onDisk("shown/a.dat"),
            "pending \(model.permanentDeleteTargets.map(\.name))"
        )
        model.trashSelection()
        check(
            "and the keys wait for that answer too",
            !model.canUseDeleteKeys && !model.isDeleting && onDisk("shown/a.dat"),
            "a second action started behind the confirmation"
        )
        model.permanentDeleteTargets = []

        model.selection = [bRef]
        model.trashSelection()
        check(
            "the keys are off while a batch runs",
            model.isDeleting && !model.canUseDeleteKeys,
            "deleting \(model.isDeleting)"
        )
        pumpUntilDeleteSettles(model)
        check(
            "⌘⌫ moves the selected row to the Trash, and only that",
            !onDisk("shown/b.dat") && onDisk("shown/a.dat")
                && live(shown).map(\.name) == ["a.dat"]
                && model.actionError == nil,
            "left \(live(shown).map(\.name)), error \(model.actionError ?? "none")"
        )
    }

    // MARK: - Removal
    //
    // `Removal` deletes for good, a folder at a time, where a mistake is not
    // one that can be taken back. Each of these builds its own tree in the
    // temporary directory and checks the disk afterwards, not what the
    // removal said about itself.

    /// Every entry at and under `url`, itself included, and the space the
    /// ones that are not folders occupy — what a removal of it should count.
    private static func census(_ url: URL) -> (items: Int, bytes: UInt64) {
        var items = 0
        var bytes: UInt64 = 0
        var pending = [url.path]
        while let path = pending.popLast() {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            items += 1
            if info.st_mode & S_IFMT == S_IFDIR {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                pending.append(contentsOf: names.map { path + "/" + $0 })
            } else {
                bytes += UInt64(max(0, info.st_blocks)) * 512
            }
        }
        return (items, bytes)
    }

    private static func scratch(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-\(name)-\(getpid())")
    }

    /// The count is what the status line shows and what the bar is drawn
    /// from, so it is held to a census of the tree taken beforehand.
    private static func testARemovalCountsWhatItRemoves() {
        let base = scratch("removal")
        defer { try? FileManager.default.removeItem(at: base) }
        let tree = base.appendingPathComponent("tree")
        let outside = base.appendingPathComponent("outside")
        do {
            for folder in ["tree/one/two", "tree/hollow", "outside"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            for i in 0..<12 {
                try write(tree.appendingPathComponent("f\(i).dat"), bytes: 700 * i)
                try write(
                    tree.appendingPathComponent("one/two/g\(i).dat"),
                    bytes: 9_000 + i
                )
            }
            try write(outside.appendingPathComponent("spared.dat"), bytes: 5_000)
            // A removal that followed these would empty a folder it was never
            // pointed at.
            try FileManager.default.createSymbolicLink(
                at: tree.appendingPathComponent("one/way-out"),
                withDestinationURL: outside
            )
            try FileManager.default.createSymbolicLink(
                at: tree.appendingPathComponent("to-a-file"),
                withDestinationURL: outside.appendingPathComponent("spared.dat")
            )
        } catch {
            check("the removal fixture can be built", false, "\(error)")
            return
        }

        let expected = census(tree)
        var reports: [Removal.Tally] = []
        let outcome = Removal.remove(tree.path) { reports.append($0) }

        check(
            "a removal takes the whole tree",
            outcome.isGone && !FileManager.default.fileExists(atPath: tree.path)
                && outcome.failures == 0 && !outcome.wasStopped,
            "gone \(outcome.isGone), failures \(outcome.failures)"
        )
        check(
            "it counts every file and folder it removed",
            outcome.tally.items == expected.items,
            "counted \(outcome.tally.items), there were \(expected.items)"
        )
        check(
            "and the space the files occupied",
            outcome.tally.bytes == expected.bytes && expected.bytes > 0,
            "counted \(outcome.tally.bytes), they held \(expected.bytes)"
        )
        check(
            "the last thing it reports is where it ended up",
            reports.last == outcome.tally
                && zip(reports, reports.dropFirst()).allSatisfy {
                    $0.items <= $1.items && $0.bytes <= $1.bytes
                },
            "reported \(reports.map(\.items)), ended at \(outcome.tally.items)"
        )
        check(
            "a link is removed and what it points at is left alone",
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("spared.dat").path
            ),
            "the removal followed a link out of the tree"
        )

        let again = Removal.remove(tree.path)
        check(
            "removing what is already gone is no failure",
            again.isGone && again.failures == 0 && again.tally.items == 0,
            "failures \(again.failures), counted \(again.tally.items)"
        )

        // The scan lists a link to a folder as a file, so this is what
        // deleting one from the table asks for. With a slash on the end of
        // the path the link is resolved first, and `removefile` empties the
        // folder it points at.
        let link = base.appendingPathComponent("link")
        var spared = true
        for suffix in ["", "/"] {
            try? FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: outside
            )
            let outcome = Removal.remove(link.path + suffix)
            spared =
                spared && outcome.isGone && outcome.tally.items == 1
                && (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: link.path
                )) == nil
                && FileManager.default.fileExists(
                    atPath: outside.appendingPathComponent("spared.dat").path
                )
        }
        check(
            "a link to a folder goes alone, however its path is written",
            spared,
            "the folder the link pointed at was emptied, or the link stayed"
        )
    }

    /// Stop has to mean stop: at the next entry, with the rest untouched. It
    /// used to take effect only between top-level items, so stopping the
    /// removal of one large folder did nothing until the folder was gone.
    private static func testARemovalStopsWhereItIsAsked() {
        let base = scratch("removal-stop")
        defer { try? FileManager.default.removeItem(at: base) }
        let tree = base.appendingPathComponent("tree")
        do {
            try FileManager.default.createDirectory(
                at: tree,
                withIntermediateDirectories: true
            )
            for i in 0..<40 {
                try write(tree.appendingPathComponent("f\(i).dat"), bytes: 100)
            }
        } catch {
            check("the stop fixture can be built", false, "\(error)")
            return
        }

        let stop = Removal.Stop()
        stop.request()
        let outcome = Removal.remove(tree.path, stop: stop)
        let left = census(tree).items - 1

        check(
            "a removal asked to stop does so at the entry in hand",
            outcome.wasStopped && outcome.tally.items == 1 && left == 39,
            "removed \(outcome.tally.items), \(left) of 40 left"
        )
        check(
            "and says the tree is still there, with nothing having failed",
            !outcome.isGone && outcome.failures == 0,
            "gone \(outcome.isGone), failures \(outcome.failures)"
        )
        let finished = Removal.remove(tree.path)
        check(
            "it can be taken up again and finished",
            finished.isGone && finished.tally.items == 40,
            "gone \(finished.isGone), removed \(finished.tally.items)"
        )
    }

    /// One file that won't go should cost that file, not the rest of the
    /// folder — and the caller has to hear which it was.
    private static func testARemovalCarriesOnPastWhatItCannotRemove() {
        let base = scratch("removal-locked")
        let locked = base.appendingPathComponent("tree/keep/locked.dat")
        defer {
            chflags(locked.path, 0)
            try? FileManager.default.removeItem(at: base)
        }
        do {
            for folder in ["tree/keep", "tree/other"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            try write(locked, bytes: 1_000)
            try write(base.appendingPathComponent("tree/keep/free.dat"), bytes: 2_000)
            for i in 0..<3 {
                try write(base.appendingPathComponent("tree/other/x\(i).dat"), bytes: 500)
            }
        } catch {
            check("the locked fixture can be built", false, "\(error)")
            return
        }
        guard chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0 else {
            check("a file can be made immutable here", false, "errno \(errno)")
            return
        }

        let tree = base.appendingPathComponent("tree")
        let outcome = Removal.remove(tree.path)
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: tree.path))?
            .sorted()

        check(
            "everything else in the folder goes",
            left == ["keep", "keep/locked.dat"],
            "left \(left ?? [])"
        )
        check(
            "the one that stayed is the one failure counted",
            !outcome.isGone && !outcome.wasStopped && outcome.failures == 1,
            "gone \(outcome.isGone), failures \(outcome.failures)"
        )
        check(
            "and it is named, with why",
            outcome.firstFailure?.path.hasSuffix("/keep/locked.dat") == true
                && outcome.firstFailure?.code == EPERM,
            "reported \(String(describing: outcome.firstFailure))"
        )
    }

    /// `FileManager.removeItem` refuses a tree deeper than `PATH_MAX` outright,
    /// and `removefile` stops where the path runs out unless told to change
    /// directory as it goes — which it does for the whole process, so the
    /// working directory is checked afterwards.
    private static func testARemovalReachesPastPathMax() {
        let base = scratch("removal-deep")
        // Built relative to an open folder, one level at a time: nothing that
        // takes a whole path could name the bottom of this.
        let levels = Int(PATH_MAX) / 16 + 40
        mkdir(base.path, 0o755)
        var folder = open(base.path, O_RDONLY | O_DIRECTORY)
        for _ in 0..<levels {
            mkdirat(folder, "level-of-fifteen", 0o755)
            let next = openat(folder, "level-of-fifteen", O_RDONLY | O_DIRECTORY)
            let file = openat(next, "f.dat", O_CREAT | O_WRONLY, 0o644)
            close(file)
            close(folder)
            folder = next
        }
        close(folder)

        let before = FileManager.default.currentDirectoryPath
        let outcome = Removal.remove(base.path)
        var info = stat()
        let gone = lstat(base.path, &info) != 0

        check(
            "a tree \(levels) levels deep, past PATH_MAX, is removed whole",
            gone && outcome.isGone && outcome.failures == 0,
            "gone \(gone), failures \(outcome.failures), "
                + "first \(String(describing: outcome.firstFailure?.code))"
        )
        check(
            "with every level counted once",
            outcome.tally.items == levels * 2 + 1,
            "counted \(outcome.tally.items), expected \(levels * 2 + 1)"
        )
        check(
            "and the working directory back where it was",
            FileManager.default.currentDirectoryPath == before,
            "left in \(FileManager.default.currentDirectoryPath)"
        )
    }

    /// The model's side of the same thing. Part of a folder gone and part
    /// not is a state `FileManager.removeItem` could leave and the tree could
    /// not show: the folder stayed whole in every total. What is left is now
    /// read back from the disk, so it is held to a fresh scan of it.
    @MainActor
    private static func testADeleteThatLeavesSomethingShowsWhatIsLeft() {
        let base = scratch("partial")
        let locked = base.appendingPathComponent("part/keep/locked.dat")
        defer {
            chflags(locked.path, 0)
            try? FileManager.default.removeItem(at: base)
        }
        do {
            for folder in ["part/keep", "part/other"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            try write(locked, bytes: 1_000)
            try write(base.appendingPathComponent("part/keep/free.dat"), bytes: 2_000)
            for i in 0..<3 {
                try write(base.appendingPathComponent("part/other/x\(i).dat"), bytes: 500)
            }
            try write(base.appendingPathComponent("spare.dat"), bytes: 4_000)
        } catch {
            check("the partial fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let part = result.root.subdir(named: "part"),
            let keep = part.subdir(named: "keep"),
            chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0
        else {
            check("the partial fixture scanned", false, "missing folders")
            return
        }
        let partRef = NodeRef(part)
        model.selection = [partRef]

        deletePermanently(model, [partRef])

        check(
            "a delete that left something behind says what and why",
            model.actionError?.contains("part") == true
                && model.actionErrorDetail?.contains("locked.dat") == true,
            "said \(model.actionError ?? "nothing"): "
                + (model.actionErrorDetail ?? "nothing")
        )
        check(
            "the folder is still in the tree, holding only what stayed",
            result.root.subdir(named: "part") === part
                && part.subdirs.map(\.name) == ["keep"]
                && live(keep).map(\.name) == ["locked.dat"],
            "folders \(part.subdirs.map(\.name)), files \(live(keep).map(\.name))"
        )
        let fresh = scan(base)
        check(
            "every total is what a fresh scan of the disk finds",
            result.root.totalSize == fresh.root.totalSize
                && result.root.totalAlloc == fresh.root.totalAlloc
                && result.root.totalFiles == fresh.root.totalFiles
                && result.root.totalDirs == fresh.root.totalDirs,
            "tree \(result.root.totalSize) bytes in \(result.root.totalFiles) "
                + "files and \(result.root.totalDirs) folders, disk "
                + "\(fresh.root.totalSize) in \(fresh.root.totalFiles) and "
                + "\(fresh.root.totalDirs)"
        )
        check(
            "and the folder stays selected, since it is still there",
            model.selection == [partRef] && !partRef.isStale,
            "selection is \(model.selection.map(\.name))"
        )
    }

    /// A scan opens folders by path, so it reaches down to `PATH_MAX` and is
    /// left holding one level of entries whose own paths are past it. A
    /// removal that has to change directory to get that deep removes those —
    /// and when it leaves the folder standing, the tree has to find out they
    /// went without being able to ask for them by path.
    //
    // part/<level>/<level>/…  past PATH_MAX, a long-named file at every level,
    //                         and one that can't be removed at the bottom
    @MainActor
    private static func testAPartialDeletePastPathMaxShowsWhatIsLeft() {
        let base = scratch("partial-deep")
        let level = "level-of-fifteen"
        let long = "a-file-with-a-name-long-enough-to-matter.dat"
        let levels = Int(PATH_MAX) / 16 + 40
        // Down to the bottom by way of each folder in turn, which is the only
        // way there is to name anything in it.
        func bottom() -> Int32 {
            var folder = open(base.path + "/part", O_RDONLY | O_DIRECTORY)
            for _ in 0..<levels where folder >= 0 {
                let next = openat(folder, level, O_RDONLY | O_DIRECTORY)
                close(folder)
                folder = next
            }
            return folder
        }
        defer {
            let folder = bottom()
            if folder >= 0 {
                let locked = openat(folder, "locked.dat", O_RDONLY)
                if locked >= 0 {
                    fchflags(locked, 0)
                    close(locked)
                }
                close(folder)
            }
            _ = Removal.remove(base.path)
        }
        mkdir(base.path, 0o755)
        mkdir(base.path + "/part", 0o755)
        var folder = open(base.path + "/part", O_RDONLY | O_DIRECTORY)
        for _ in 0..<levels {
            mkdirat(folder, level, 0o755)
            let next = openat(folder, level, O_RDONLY | O_DIRECTORY)
            close(openat(next, long, O_CREAT | O_WRONLY, 0o644))
            close(folder)
            folder = next
        }
        let locked = openat(folder, "locked.dat", O_CREAT | O_WRONLY, 0o644)
        let isLocked = locked >= 0 && fchflags(locked, UInt32(UF_IMMUTABLE)) == 0
        close(locked)
        close(folder)
        guard isLocked else {
            check("the deep partial fixture can be built", false, "errno \(errno)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let part = result.root.subdir(named: "part") else {
            check("the deep partial fixture scanned", false, "missing folder")
            return
        }
        // What the scan could reach, and how much of it is past the point a
        // path can name: the last few levels' files.
        let scannedFiles = part.totalFiles
        let scannedDirs = part.totalDirs
        var beyond = 0
        var pending = [(dir: part, path: part.path)]
        while let (dir, path) = pending.popLast() {
            for file in dir.files where path.utf8.count + 1 + file.name.utf8.count
                >= Int(PATH_MAX)
            {
                beyond += 1
            }
            pending.append(contentsOf: dir.subdirs.map { ($0, path + "/" + $0.name) })
        }
        check(
            "the scan holds files it can't name by path",
            scannedFiles > beyond && beyond > 0,
            "\(beyond) of \(scannedFiles) scanned files are past PATH_MAX"
        )

        deletePermanently(model, [NodeRef(part)])

        check(
            "the folder is left standing by the one file that would not go",
            model.actionError != nil && result.root.subdir(named: "part") === part,
            "error \(model.actionError ?? "none")"
        )
        check(
            "every file that went is out of the tree, past PATH_MAX or not",
            part.totalFiles == 0,
            "\(part.totalFiles) of \(scannedFiles) still listed"
        )
        check(
            "and every folder, which all still stand, is still in it",
            part.totalDirs == scannedDirs,
            "\(part.totalDirs) folders listed, \(scannedDirs) scanned"
        )
    }

    /// Stop, part-way through one folder, through the model: the count the
    /// bar is drawn from, the Stop itself, and the tree left agreeing with a
    /// disk that has lost an arbitrary part of the folder.
    ///
    /// Nothing here waits on how fast the disk is. Stop is pressed the moment
    /// the rows are set back, which with no grace asked for is as soon as the
    /// batch has handed the removal off — a millisecond or two into eight
    /// thousand files, wherever they are. And that the bar moved is read from
    /// what was published, which includes where the removal ended.
    @MainActor
    private static func testADeleteCanBeStoppedPartWay() {
        let base = scratch("partway")
        defer { try? FileManager.default.removeItem(at: base) }
        let folders = 8
        let each = 1_000
        do {
            for d in 0..<folders {
                let dir = base.appendingPathComponent("big/d\(d)")
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                for f in 0..<each {
                    FileManager.default.createFile(
                        atPath: dir.appendingPathComponent("f\(f).dat").path,
                        contents: nil
                    )
                }
            }
            try write(base.appendingPathComponent("spare.dat"), bytes: 4_000)
        } catch {
            check("the part-way fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.removingGrace = 0
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let big = result.root.subdir(named: "big"),
            let spare = result.root.files.firstIndex(where: { $0.name == "spare.dat" }),
            let inside = big.subdirs.first
        else {
            check("the part-way fixture scanned", false, "missing entries")
            return
        }
        let bigPath = big.path
        let expected = folders * each + folders + 1

        model.deletePermanently([NodeRef(big)])
        check(
            "the bar starts out knowing how much there is to remove",
            model.deleteProgress?.itemsTotal == expected
                && model.deleteProgress?.items == 0
                && model.deleteProgress?.bytesTotal == big.totalAlloc,
            "got \(String(describing: model.deleteProgress)), expected \(expected)"
        )

        var published: [AppModel.DeleteProgress] = []
        let watch = model.$deleteProgress.sink { progress in
            if let progress { published.append(progress) }
        }
        let deadline = Date().addingTimeInterval(20)
        while model.isDeleting, model.removing.isEmpty, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        let dimmed =
            model.isBeingRemoved(NodeRef(big))
            && model.isBeingRemoved(NodeRef(dir: inside, fileIndex: 0))
            && !model.isBeingRemoved(NodeRef(dir: result.root, fileIndex: spare))
        model.cancelDelete()
        pumpUntilDeleteSettles(model)
        watch.cancel()

        let left = census(URL(fileURLWithPath: bigPath)).items
        check(
            "the rows on their way out are set back, and no others",
            dimmed && model.removing.isEmpty,
            "dimmed \(dimmed), still marked \(model.removing.count)"
        )
        check(
            "the bar moves while one folder is being removed, and stops short",
            published.contains { $0.items > 0 && $0.items < expected }
                && published.allSatisfy {
                    $0.itemsTotal == expected && $0.fraction < 1
                },
            "published \(published.map(\.items)) of \(expected)"
        )
        check(
            "Stop takes effect part-way through the folder",
            left > 0 && left < expected,
            "\(left) of \(expected) entries left on disk"
        )
        check(
            "being stopped is not reported as a failure",
            model.actionError == nil && !model.isDeleting,
            model.actionError ?? "still deleting"
        )
        let fresh = scan(base)
        check(
            "the tree is left showing exactly what is still on disk",
            result.root.subdir(named: "big") === big
                && result.root.totalFiles == fresh.root.totalFiles
                && result.root.totalDirs == fresh.root.totalDirs
                && result.root.totalAlloc == fresh.root.totalAlloc,
            "tree \(result.root.totalFiles) files and \(result.root.totalDirs) "
                + "folders, disk \(fresh.root.totalFiles) and \(fresh.root.totalDirs)"
        )

        deletePermanently(model, [NodeRef(big)])
        check(
            "what was left can be removed afterwards",
            !FileManager.default.fileExists(atPath: bigPath)
                && result.root.subdir(named: "big") == nil
                && result.root.totalFiles == 1,
            "\(result.root.totalFiles) files left in the tree"
        )
    }

    /// The flicker. A file was named by its place in the folder's array, so
    /// deleting one renumbered every sibling after it: the table was handed a
    /// list of rows it had never seen and redrew the lot, the File View was
    /// emptied until a walk refilled it, and the selection was thrown away.
    ///
    /// Every row left has to be the row it was, naming what it named — and
    /// the lists are watched on the way, not just compared afterwards, since
    /// an empty list for one frame is the thing being ruled out.
    //
    // list/a.dat … e.dat   50,000 bytes down to 10,000
    // other/z.dat          7,000
    @MainActor
    private static func testRowsKeepTheirPlacesAcrossADelete() {
        let base = scratch("rows")
        defer { try? FileManager.default.removeItem(at: base) }
        let names = ["a", "b", "c", "d", "e"].map { $0 + ".dat" }
        do {
            for folder in ["list", "other"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            for (i, name) in names.enumerated() {
                try write(
                    base.appendingPathComponent("list/\(name)"),
                    bytes: 50_000 - i * 10_000
                )
            }
            try write(base.appendingPathComponent("other/z.dat"), bytes: 7_000)
        } catch {
            check("the rows fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let list = result.root.subdir(named: "list"),
            let other = result.root.subdir(named: "other"),
            list.files.count == 5
        else {
            check("the rows fixture scanned", false, "missing entries")
            return
        }
        func ref(_ name: String) -> NodeRef {
            NodeRef(dir: list, fileIndex: list.files.firstIndex { $0.name == name }!)
        }
        model.setExpanded(list, true)
        model.setExpanded(other, true)
        model.tab = .files
        pumpUntilFileRowsSettle(model, expecting: 6)
        model.tab = .tree

        let treeBefore = Dictionary(
            uniqueKeysWithValues: model.treeRows.map { ($0.ref, $0.ref.name) }
        )
        let filesBefore = Dictionary(
            uniqueKeysWithValues: model.fileRows.map { ($0.ref, $0.name) }
        )
        var emptied = false
        let watch = model.$fileRows.dropFirst().sink { if $0.isEmpty { emptied = true } }
        defer { watch.cancel() }

        let b = ref("b.dat")
        model.selection = [ref("c.dat")]
        trash(model, [b])
        pumpUntilFileRowsSettle(model, expecting: 5)

        check(
            "deleting a file takes exactly its row out of the tree table",
            Set(treeBefore.keys).subtracting(model.treeRows.map(\.ref)) == [b]
                && model.treeRows.count == treeBefore.count - 1,
            "\(model.treeRows.count) rows, were \(treeBefore.count)"
        )
        check(
            "every row left is the row it was, naming what it named",
            model.treeRows.allSatisfy { treeBefore[$0.ref] == $0.ref.name }
                && model.fileRows.allSatisfy {
                    filesBefore[$0.ref] == $0.name && $0.ref.name == $0.name
                },
            "tree \(model.treeRows.map(\.ref.name)), files \(model.fileRows.map(\.name))"
        )
        check(
            "the file list is never emptied on the way",
            !emptied && model.fileRows.count == 5,
            "it was blank for a time, or ended at \(model.fileRows.count) rows"
        )
        check(
            "a selection that was not deleted is left alone",
            model.selection == [ref("c.dat")],
            "selection is \(model.selection.map(\.name))"
        )
        check(
            "the deleted file is in none of the places files are listed",
            !result.largestFiles().contains { $0.isStale }
                && result.largestFiles().count == 5
                && !TreemapLayout.build(
                    root: result.root,
                    ancestors: [],
                    size: CGSize(width: 400, height: 300),
                    metric: .allocated
                ).cells.contains { $0.ref.isStale || $0.ref.name.isEmpty },
            "a slot left by a deleted file was listed or drawn"
        )

        // Where the selection goes when it is what was deleted: to whatever
        // moves up into its place, so the next arrow key carries on from
        // there and not from the top of the table.
        trash(model, [ref("c.dat")])
        check(
            "deleting the selected row selects the one that takes its place",
            model.selection == [ref("d.dat")],
            "selection is \(model.selection.map(\.name))"
        )
        model.selection = [ref("e.dat")]
        trash(model, [ref("e.dat")])
        check(
            "deleting the last row selects the one before it",
            model.selection == [ref("d.dat")],
            "selection is \(model.selection.map(\.name))"
        )
        let rest: Set<NodeRef> = [ref("a.dat"), ref("d.dat")]
        model.selection = rest
        trash(model, rest)
        check(
            "deleting all that is left selects the folder, now empty",
            model.selection == [NodeRef(list)] && list.isEmpty
                && model.treeRows.first { $0.ref == NodeRef(list) }?.isExpandable
                    == false,
            "selection is \(model.selection.map(\.name)), "
                + "\(live(list).count) files left"
        )

        // A tile picked on the treemap has no row, so no neighbour: moving to
        // the folder it was in would put a second ⌘⌫ on everything else there.
        let z = NodeRef(dir: other, fileIndex: 0)
        model.setExpanded(other, false)
        model.selection = [z]
        trash(model, [z])
        check(
            "deleting a selection that had no row selects nothing",
            model.selection.isEmpty,
            "selection is \(model.selection.map(\.name))"
        )

        // A folder that has gone is cut off, so what was held of it or of
        // anything inside reads as gone too.
        let otherRef = NodeRef(other)
        model.selection = [otherRef]
        trash(model, [otherRef])
        check(
            "a deleted folder, and anything that was in it, reads as stale",
            otherRef.isStale && z.isStale && otherRef.path.isEmpty
                && model.distinctTargets([otherRef, z]).isEmpty,
            "path \(otherRef.path)"
        )
    }

    /// Files of one size, which is most files in a folder of small ones. The
    /// File View lists the largest thousand, and which of a run of equals made
    /// the cut — and in what order — used to depend on how the heap that picks
    /// them happened to be laid out. Deleting one file anywhere reshuffled
    /// the rest. They are taken in the order the walk meets them, so the list
    /// after a delete is the list before, less what went, with the next in
    /// line at the end.
    //
    // 1,100 files of 100 bytes at the top, met first; big/ holds fifty larger
    // ones, each a different size, met after them and pushing equals out.
    @MainActor
    private static func testEqualFilesKeepTheirOrderAcrossADelete() {
        let base = scratch("equals")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("big"),
                withIntermediateDirectories: true
            )
            for i in 0..<1_100 {
                try write(base.appendingPathComponent("same\(i).dat"), bytes: 100)
            }
            for i in 0..<50 {
                try write(
                    base.appendingPathComponent("big/b\(i).dat"),
                    bytes: 100_000 + i * 10_000
                )
            }
        } catch {
            check("the equal-files fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let big = result.root.subdir(named: "big") else {
            check("the equal-files fixture scanned", false, "missing folder")
            return
        }
        model.tab = .files
        pumpUntilFileRowsSettle(model, expecting: 1_000)
        let filesBefore = model.fileRows.map(\.ref)
        let treeBefore = model.treeRows.map(\.ref)
        guard filesBefore.count == 1_000,
            filesBefore.prefix(50).allSatisfy({ $0.dir === big })
        else {
            check("the list leads with the fifty larger files", false,
                "\(filesBefore.count) rows")
            return
        }

        // One of the larger ones goes, which lets one more equal in.
        let gone = filesBefore[10]
        trash(model, [gone])
        pumpUntilFileRowsSettle(model, expecting: 1_000)
        let filesAfter = model.fileRows.map(\.ref)

        check(
            "the list after is the list before, less the file that went",
            filesAfter.count == 1_000
                && Array(filesAfter.dropLast()) == filesBefore.filter { $0 != gone },
            "\(zip(filesAfter, filesBefore.filter { $0 != gone }).prefix { $0 == $1 }.count)"
                + " rows in from the top before the two part company"
        )
        check(
            "with the next equal in line added at the end",
            filesAfter.last.map { !filesBefore.contains($0) && $0.dir === result.root }
                == true,
            "last row is \(filesAfter.last?.name ?? "missing")"
        )
        check(
            "and the tree table's rows, all one size, are in the order they were",
            model.treeRows.map(\.ref) == treeBefore.filter { $0 != gone },
            "the rows changed places"
        )
        // That file had no row in the tree. One of the equals does, in the
        // middle of the run of them.
        let middle = treeBefore[treeBefore.count / 2]
        trash(model, [middle])
        check(
            "taking one out of a run of equal rows leaves the rest in order",
            !middle.isDirectory && middle.dir === result.root
                && model.treeRows.map(\.ref)
                    == treeBefore.filter { $0 != gone && $0 != middle },
            "the rows changed places"
        )
    }

    /// The same in File View, which is a flat list with no folder to fall
    /// back on.
    @MainActor
    private static func testTheFileListKeepsItsPlaceAcrossADelete() {
        let base = scratch("filerows")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
            for i in 0..<4 {
                try write(
                    base.appendingPathComponent("f\(i).dat"),
                    bytes: 40_000 - i * 10_000
                )
            }
        } catch {
            check("the file-list fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard loadSynchronously(into: model) != nil else { return }
        model.tab = .files
        pumpUntilFileRowsSettle(model, expecting: 4)
        guard model.fileRows.map(\.name) == ["f0.dat", "f1.dat", "f2.dat", "f3.dat"]
        else {
            check("the file list is ranked largest first", false,
                "\(model.fileRows.map(\.name))")
            return
        }

        model.selection = [model.fileRows[1].ref]
        trash(model, model.selection)
        check(
            "deleting a listed file selects the one that moves up",
            model.selection.map(\.name) == ["f2.dat"],
            "selection is \(model.selection.map(\.name))"
        )
        model.selection = [model.fileRows[2].ref]
        trash(model, model.selection)
        check(
            "deleting the last one selects the one before it",
            model.selection.map(\.name) == ["f2.dat"],
            "selection is \(model.selection.map(\.name))"
        )
    }

    /// The status line's figures, which are put together in the model so they
    /// can be held to here.
    @MainActor
    private static func testTheDeleteLineStaysWithinWhatWasCounted() {
        let model = AppModel()
        var progress = AppModel.DeleteProgress(
            done: 0,
            total: 1,
            currentName: "cache",
            items: 1_200,
            itemsTotal: 5_000,
            bytes: 2_000_000,
            bytesTotal: 6_400_000
        )
        check(
            "the bar is drawn from items removed, not targets finished",
            abs(progress.fraction - 0.24) < 0.0001,
            "got \(progress.fraction)"
        )
        check(
            "the line gives both, each against what the scan counted",
            model.deleteSummary(progress)
                == "\(ByteFormat.count(1_200)) of "
                + "\(ByteFormat.counted(5_000, "item"))  •  "
                + "\(ByteFormat.decimal(2_000_000)) of "
                + ByteFormat.decimal(6_400_000),
            model.deleteSummary(progress)
        )
        // The disk can hold more than the scan found, and a hard link's
        // bytes are reported by whichever name goes first.
        progress.items = 5_400
        progress.bytes = 9_000_000
        check(
            "neither runs past its total",
            progress.fraction == 1
                && model.deleteSummary(progress)
                    == "\(ByteFormat.count(5_000)) of "
                    + "\(ByteFormat.counted(5_000, "item"))  •  "
                    + "\(ByteFormat.decimal(6_400_000)) of "
                    + ByteFormat.decimal(6_400_000),
            model.deleteSummary(progress)
        )
        let trash = AppModel.DeleteProgress(done: 1, total: 4, currentName: "")
        check(
            "with nothing counted, it falls back to targets finished",
            trash.fraction == 0.25,
            "got \(trash.fraction)"
        )
        // A folder of empty files, as seen clicking through: eight hundred
        // thousand of them, and "0 bytes of 0 bytes" beside the count.
        let empties = AppModel.DeleteProgress(
            done: 0,
            total: 1,
            currentName: "bulk",
            items: 300,
            itemsTotal: 900
        )
        check(
            "with no space to count, the line gives the items alone",
            model.deleteSummary(empties)
                == "\(ByteFormat.count(300)) of \(ByteFormat.counted(900, "item"))",
            model.deleteSummary(empties)
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

        trash(model, [ref])

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
            "the selection stays where it was, on something still there",
            model.selection == [NodeRef(result.root)],
            "selection is \(model.selection.map(\.name))"
        )
    }

    /// A `NodeRef` names a file by its index in the folder's array. Deleting a
    /// file used to take its entry out, which left a reference to anything
    /// after it pointing at a different file or past the end; SwiftUI keeps a
    /// context menu's content alive and re-runs its body once the sheet closes
    /// — after the delete — and reading one of those trapped and took the
    /// whole app down.
    ///
    /// A deleted file now keeps its slot. A reference to it reads as stale and
    /// degrades quietly, and a reference to a sibling goes on naming the
    /// sibling, which is what lets the selection and the rows survive.
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
        let gone = NodeRef(dir: dir, fileIndex: 0)
        let last = NodeRef(dir: dir, fileIndex: 2)
        let lastName = last.name
        let lastPath = last.path
        trash(model, [gone, NodeRef(dir: dir, fileIndex: 1)])
        check(
            "the fixture is down to one file",
            live(dir).count == 1 && dir.totalFiles == 1,
            "got \(live(dir).count), counted as \(dir.totalFiles)"
        )
        check(
            "a reference to the file that stayed still names it",
            !last.isStale && last.name == lastName && last.path == lastPath
                && FileManager.default.fileExists(atPath: last.path),
            "now \(last.name) at \(last.path), was \(lastName)"
        )
        check("a reference to a deleted file reports itself stale", gone.isStale, "")
        check("its path reads empty rather than trapping", gone.path.isEmpty, gone.path)
        check("its name reads empty", gone.name.isEmpty, gone.name)
        check("its size reads zero", gone.size == 0, "\(gone.size)")
        check("its file entry is nil", gone.file == nil, "got one")
        check(
            "its percentage reads zero",
            gone.fractionOfParent == 0 && gone.fractionOfParent(using: .allocated) == 0,
            "\(gone.fractionOfParent)"
        )
        // The protection check is what the crash came through: the menu asks it
        // for every captured reference each time its body re-runs.
        check(
            "the menu's protection check tolerates a stale reference",
            !FileActions.containsSystemProtected([gone]),
            "reported protected"
        )
        check(
            "a stale reference is never a delete target",
            model.distinctTargets([gone]).isEmpty,
            "it survived the filter"
        )
        // Aiming a stale reference at its parent folder would delete the wrong
        // thing entirely, so the surviving file must still be here afterwards.
        deletePermanently(model, [gone])
        check(
            "acting on a stale reference is a no-op, not a parent delete",
            FileManager.default.fileExists(atPath: dir.path)
                && live(dir).count == 1,
            "the folder or its contents were removed"
        )
    }

    /// The File View's rows are built off the main thread from a walk of the whole
    /// tree, and each row names its file by index. A delete used to renumber
    /// every sibling after the one removed, so any row published from before it
    /// named a *different* file — and acting on one would trash the wrong thing
    /// with nothing to reveal it. A deleted file now keeps its slot, so the
    /// rows for the others are still right and stay; what has to hold is that
    /// none of them ever names anything but its own file, and that a row for
    /// the file that went never reaches the table. Two ways in: the rows
    /// already on screen, and a walk that was in flight when the delete landed.
    @MainActor
    private static func testFileRowsNeverOutliveADelete(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }
        let dir = result.root.subdir(named: "rows")!
        guard dir.files.count == 3 else {
            check("the row fixture has three files", false, "\(dir.files.count)")
            return
        }
        // The rows arrive from a background walk, so a completed scan doesn't
        // mean they are on screen yet.
        pumpUntilFileRowsSettle(model, expecting: result.root.totalFiles)
        check(
            "the scan's rows are on screen to begin with",
            model.fileRows.count == result.root.totalFiles,
            "got \(model.fileRows.count), expected \(result.root.totalFiles)"
        )

        // Start a walk and let it finish on the tree queue *without* pumping the
        // run loop, so its result is queued for the main thread but not yet
        // delivered — the in-flight case, which a delete has to discard.
        model.refreshFileRows(immediately: true)
        usleep(300_000)

        trash(model, [NodeRef(dir: dir, fileIndex: 0)])

        // Every row the model publishes, at every step, has to still name the
        // file it was built for.
        var mismatch: String?
        var sawStale = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            for row in model.fileRows {
                if row.ref.isStale {
                    sawStale = true
                } else if row.ref.name != row.name {
                    mismatch = "a row for “\(row.name)” now names “\(row.ref.name)”"
                }
            }
            if mismatch != nil || sawStale { break }
            if !model.isFilteringFiles
                && model.fileRows.count == result.root.totalFiles
            {
                break
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        check(
            "no published row ever names a file other than its own",
            mismatch == nil,
            mismatch ?? ""
        )
        check(
            "no published row is for a file that has gone",
            !sawStale,
            "a stale row reached the table"
        )
        check(
            "the rows settle on the tree as it is after the delete",
            !model.isFilteringFiles
                && model.fileRows.count == result.root.totalFiles
                && !model.fileRows.contains { $0.ref.isStale },
            "got \(model.fileRows.count) rows, expected \(result.root.totalFiles), "
                + "filtering=\(model.isFilteringFiles)"
        )
    }

    /// A rescan throws the old tree away, and a walk that was already running
    /// describes it. Letting one land afterwards puts rows from a discarded scan
    /// into the table — holding folders whose parents that scan's root was the
    /// only thing keeping alive.
    @MainActor
    private static func testFileRowsDontOutliveTheirScan(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let first = loadSynchronously(into: model) else { return }
        pumpUntilFileRowsSettle(model, expecting: first.root.totalFiles)
        guard !model.fileRows.isEmpty else {
            check("the first scan produced rows", false, "none")
            return
        }

        // In flight, delivered to nobody yet — then the scan it describes is
        // replaced.
        model.refreshFileRows(immediately: true)
        usleep(300_000)
        model.startScan()
        check(
            "starting a scan clears the rows and the spinner",
            model.fileRows.isEmpty && !model.isFilteringFiles,
            "\(model.fileRows.count) rows, filtering=\(model.isFilteringFiles)"
        )
        // Checked at every step, not just once it settles: the old walk's rows
        // land while the replacement scan is still running, and the scan's own
        // refresh would paper over them a moment later.
        var foreign: String?
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let current = model.result {
                for row in model.fileRows
                where !isWithin(row.ref.dir, current.root) {
                    foreign = "a row for “\(row.name)” is not in the scan on show"
                    break
                }
            } else if let row = model.fileRows.first {
                foreign = "a row for “\(row.name)” is on show with no scan at all"
            }
            if foreign != nil { break }
            if model.phase == .complete, !model.isFilteringFiles,
                model.fileRows.count == model.result?.root.totalFiles
            {
                break
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        check(
            "no row from the replaced scan is ever on show",
            foreign == nil,
            foreign ?? ""
        )
        check(
            "the rescan's own rows arrive",
            model.phase == .complete
                && model.fileRows.count == model.result?.root.totalFiles,
            "phase \(model.phase), \(model.fileRows.count) rows"
        )
    }

    /// SwiftUI keeps a context menu's content after the menu has closed and
    /// re-runs its body whenever the model publishes. The references in it can
    /// be from a scan that has since been replaced: they keep their own folder
    /// alive and nothing above it. Asking one for its path walked up through
    /// folders that had been freed — found in the released 0.3.2 as a crash a
    /// few clicks after a rescan, once the allocator had reused that memory.
    ///
    /// A folder's link to its parent is weak now, so a parent that has gone
    /// reads as gone, and a reference cut off from its scan's root resolves to
    /// no path at all rather than to a fragment of one.
    @MainActor
    private static func testARefFromAReplacedScanIsInert(_ root: URL) {
        final class Watch { weak var node: DirNode? }
        let model = AppModel()
        model.customFolder = root.path
        let replaced = Watch()
        // Only what a closed context menu holds on to leaves this scope: a
        // folder two levels down, and a file in it.
        func kept() -> (folder: NodeRef, file: NodeRef)? {
            guard let first = loadSynchronously(into: model),
                let inner = first.root.subdir(named: "nest")?.subdir(named: "inner"),
                !inner.files.isEmpty
            else { return nil }
            replaced.node = first.root
            return (NodeRef(inner), NodeRef(dir: inner, fileIndex: 0))
        }
        guard let refs = kept() else {
            check("the replaced-scan fixture scanned", false, "missing nest/inner")
            return
        }
        check(
            "a reference into a live scan resolves to its full path",
            refs.folder.path.hasSuffix("/nest/inner")
                && refs.file.path.hasSuffix("/nest/inner/deep.dat"),
            "got “\(refs.folder.path)” and “\(refs.file.path)”"
        )

        guard let second = loadSynchronously(into: model) else { return }
        pumpUntilFileRowsSettle(model, expecting: second.root.totalFiles)
        // The premise: nothing else is holding the old tree up.
        check(
            "the scan that was replaced has been let go",
            replaced.node == nil,
            "something still holds it, so the checks below prove nothing"
        )
        check(
            "a folder kept from it reads the folder above it as gone",
            refs.folder.dir.parent == nil,
            "it still points at where its parent used to be"
        )
        check(
            "and resolves to no path, rather than to a fragment of one",
            refs.folder.path.isEmpty && refs.file.path.isEmpty,
            "got “\(refs.folder.path)” and “\(refs.file.path)”"
        )
        check(
            "so nothing offers to delete it",
            model.deletionRefusal(for: refs.folder) != nil
                && model.deletionRefusal(for: refs.file) != nil
                && model.distinctTargets([refs.folder, refs.file]).isEmpty,
            "a reference into a discarded scan was accepted as a target"
        )
    }

    /// Whether `node` is `ancestor` or sits beneath it. Walks down rather than up,
    /// so it never reads a `parent` that a discarded scan may have left dangling.
    private static func isWithin(_ node: DirNode, _ ancestor: DirNode) -> Bool {
        if node === ancestor { return true }
        for sub in ancestor.subdirs where isWithin(node, sub) { return true }
        return false
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
        // Measured with the metric on show, which defaults to allocated. Quoting
        // logical size here promised a sparse image's full 200 GB back from a
        // delete that frees the 8 GB it actually occupies.
        check(
            "reclaimable size counts a nested selection once",
            model.reclaimableSize(nested) == nest.totalAlloc,
            "got \(model.reclaimableSize(nested)), expected \(nest.totalAlloc)"
        )
        model.sizeMetric = .logical
        check(
            "reclaimable size follows the metric on show",
            model.reclaimableSize(nested) == nest.totalSize,
            "got \(model.reclaimableSize(nested)), expected \(nest.totalSize)"
        )
    }

    /// The scan root is selected the moment a scan lands, and the context menu
    /// used to offer it "Delete Permanently…" like any other row — so the first
    /// one a user reached for was aimed at everything they had just measured.
    /// Nothing else stopped it: none of the SIP prefixes cover `/` or a home
    /// folder.
    @MainActor
    private static func testScanRootIsNeverDeletable(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }
        let rootRef = NodeRef(result.root)

        check(
            "a completed scan leaves its root selected",
            model.selection == [rootRef],
            "got \(model.selection.map(\.name))"
        )
        check(
            "the scan root is refused as a delete target",
            model.deletionRefusal(for: rootRef) != nil,
            "it was accepted"
        )

        let before = result.root.totalSize
        let beforeFiles = result.root.totalFiles
        deletePermanently(model, [rootRef])

        check(
            "deleting the scan root leaves it on disk",
            FileManager.default.fileExists(atPath: root.path),
            "the fixture was removed"
        )
        check(
            "and leaves its contents entirely alone",
            result.root.totalSize == before
                && result.root.totalFiles == beforeFiles,
            "totals moved: \(result.root.totalSize) of \(before)"
        )
        check(
            "the refusal is explained rather than silent",
            model.actionError != nil,
            "nothing was reported"
        )

        model.actionError = nil
        trash(model, [rootRef])
        check(
            "trashing the scan root is refused too",
            FileManager.default.fileExists(atPath: root.path)
                && model.actionError != nil,
            "it went ahead"
        )
    }

    /// Volume and home roots, checked below the model so the guard holds for any
    /// caller. `FileActions` can't know what a scan was rooted at, so it covers
    /// the paths that are roots no matter how they were reached.
    private static func testVolumeAndHomeRootsAreRefused() {
        check("/ is refused", FileActions.isUndeletableRoot("/"), "accepted")
        check(
            "a trailing slash doesn't slip past it",
            FileActions.isUndeletableRoot("/Volumes/Backup/"),
            "accepted"
        )
        check(
            "this user's home folder is refused",
            FileActions.isUndeletableRoot(NSHomeDirectory()),
            "accepted"
        )
        check(
            "another user's home folder is refused",
            FileActions.isUndeletableRoot("/Users/someoneelse"),
            "accepted"
        )
        check(
            "a volume mount point is refused",
            FileActions.isUndeletableRoot("/Volumes/Backup"),
            "accepted"
        )
        check(
            "something inside a home folder is still deletable",
            !FileActions.isUndeletableRoot(NSHomeDirectory() + "/Downloads/x.zip"),
            "wrongly refused"
        )
        check(
            "a folder inside a volume is still deletable",
            !FileActions.isUndeletableRoot("/Volumes/Backup/old"),
            "wrongly refused"
        )

        // A scan of the data volume's own mount point spells every path through
        // it. Counted as written, a home folder there has five components and
        // isn't `NSHomeDirectory()`, so every check above waved it through.
        let dataVolume = "/System/Volumes/Data"
        check(
            "the data volume's mount point is refused",
            FileActions.isUndeletableRoot(dataVolume),
            "accepted"
        )
        check(
            "this user's home folder is refused through the data volume",
            FileActions.isUndeletableRoot(dataVolume + NSHomeDirectory()),
            "accepted"
        )
        check(
            "another user's home folder is refused through it too",
            FileActions.isUndeletableRoot(dataVolume + "/Users/someoneelse/"),
            "accepted"
        )
        check(
            "something inside a home folder there is still deletable",
            !FileActions.isUndeletableRoot(
                dataVolume + NSHomeDirectory() + "/Downloads/x.zip"
            ),
            "wrongly refused"
        )
        check(
            "a folder that merely starts with the mount point's name isn't caught",
            !FileActions.isUndeletableRoot(dataVolume + "base/Users/someone"),
            "wrongly refused"
        )
        // Refused before the filesystem is touched, so this is safe to call.
        do {
            try FileActions.deletePermanently(dataVolume + "/Users/someoneelse")
            check("deleting a home folder through it is refused", false, "it went ahead")
        } catch FileActions.ActionError.undeletableRoot {
            check("deleting a home folder through it is refused", true, "")
        } catch {
            check(
                "deleting a home folder through it is refused",
                false,
                "it got as far as the filesystem: \(error)"
            )
        }
    }

    /// Deleting one name of a hard-linked pair frees nothing while the other
    /// name is still there, so the confirmation dialog must not promise the
    /// file's size back. It quoted the full size for both members of a pair
    /// while the tree subtracted nothing for one of them.
    @MainActor
    private static func testHardLinkPromisesNoSpace(_ root: URL) {
        let model = AppModel()
        model.customFolder = root.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let c = result.root.subdir(named: "c"),
            let duplicate = c.files.firstIndex(where: \.isDuplicateLink),
            let original = c.files.firstIndex(where: {
                !$0.isDuplicateLink && $0.isHardLinked
            })
        else {
            check("the fixture still has its hard-linked pair", false, "missing")
            return
        }

        let linked = NodeRef(dir: c, fileIndex: duplicate)
        let survivor = NodeRef(dir: c, fileIndex: original)
        check(
            "the already-counted name promises nothing",
            model.reclaimableSize([linked]) == 0,
            "got \(model.reclaimableSize([linked]))"
        )
        // The scanner marks only the second name it reaches as a duplicate, so
        // without the link count the first one looked like an ordinary 40 KB
        // file whose deletion would free 40 KB. It would free nothing.
        check(
            "the other name of the pair promises nothing either",
            model.reclaimableSize([survivor]) == 0,
            "got \(model.reclaimableSize([survivor]))"
        )
        check(
            "the dialog is told the space is shared",
            model.selectionSharesStorage([linked, survivor]),
            "it would have quoted a plain figure"
        )

        let plain = c.files.firstIndex { !$0.isHardLinked && !$0.isSymlink }
        if let plain {
            let ref = NodeRef(dir: c, fileIndex: plain)
            check(
                "an ordinary file still promises its own size",
                model.reclaimableSize([ref]) == ref.alloc && ref.alloc > 0,
                "got \(model.reclaimableSize([ref])), expected \(ref.alloc)"
            )
        }
    }

    /// Deleting the name a hard-linked file was counted under must not take its
    /// bytes out of the totals while another name still holds them.
    ///
    /// The scan counts those bytes once, under whichever name a worker reached
    /// first, and marks the rest as duplicates worth nothing. Removing the
    /// counted name used to subtract the full size anyway, so the tree reported
    /// a folder as empty while the survivor still occupied the disk — and the
    /// two disagreed until a rescan. The survivor takes over the count now.
    @MainActor
    private static func testDeletingTheCountedNameOfAPairPromotesTheOther() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-pair-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildLinkedPair(at: base)
        } catch {
            check("the cross-folder link fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        let links = result.root
        guard let left = links.subdir(named: "left"),
            let right = links.subdir(named: "right")
        else {
            check("the cross-folder link fixture scanned", false, "missing folders")
            return
        }

        // Which side the scan counted is arbitrary, so the roles are looked up
        // rather than assumed.
        let counted: (dir: DirNode, index: Int)
        let duplicate: (dir: DirNode, index: Int)
        if let i = left.files.firstIndex(where: { !$0.isDuplicateLink }),
            let j = right.files.firstIndex(where: \.isDuplicateLink)
        {
            counted = (left, i)
            duplicate = (right, j)
        } else if let i = right.files.firstIndex(where: { !$0.isDuplicateLink }),
            let j = left.files.firstIndex(where: \.isDuplicateLink)
        {
            counted = (right, i)
            duplicate = (left, j)
        } else {
            check(
                "exactly one name of the pair is counted",
                false,
                "left=\(left.files.map(\.isDuplicateLink)) "
                    + "right=\(right.files.map(\.isDuplicateLink))"
            )
            return
        }

        let size = counted.dir.files[counted.index].size
        check(
            "the pair is scanned as one counted name and one duplicate",
            size == 9_000 && counted.dir.files[counted.index].isHardLinked,
            "got \(size) bytes, hardLinked="
                + "\(counted.dir.files[counted.index].isHardLinked)"
        )

        let rootBefore = result.root.totalSize
        let linksBefore = links.totalSize
        let survivorFolder = duplicate.dir
        let survivorBefore = survivorFolder.totalSize

        // Removed outright rather than trashed: a name in the Trash would still
        // be a second name for these bytes, and the survivor would go on
        // sharing them.
        deletePermanently(
            model,
            [NodeRef(dir: counted.dir, fileIndex: counted.index)]
        )

        check(
            "deleting the counted name reports no error",
            model.actionError == nil,
            model.actionError ?? ""
        )
        // The bytes never left the disk, so they must not leave the tree.
        check(
            "the bytes stay in the root's total",
            result.root.totalSize == rootBefore,
            "root is \(result.root.totalSize), expected \(rootBefore)"
        )
        check(
            "and in the folder holding both names",
            links.totalSize == linksBefore,
            "links/ is \(links.totalSize), expected \(linksBefore)"
        )
        // They move, though: the surviving name now accounts for them.
        check(
            "the surviving name's folder gains them",
            survivorFolder.totalSize == survivorBefore + size,
            "got \(survivorFolder.totalSize), expected \(survivorBefore + size)"
        )
        check(
            "the survivor stops being reported as a duplicate",
            survivorFolder.files.first?.isDuplicateLink == false,
            "still flagged"
        )
        check(
            "the double-counting figure drops with it",
            result.hardLinkSavings == 0,
            "got \(result.hardLinkSavings), expected 0"
        )
        // Nothing is now hidden: the folder totals add up to the root again.
        check(
            "the root's total is the sum of its folders once more",
            result.root.totalSize
                == result.root.subdirs.reduce(0) { $0 + $1.totalSize }
                    + result.root.files.reduce(0) { $0 + $1.size },
            "root \(result.root.totalSize) vs children "
                + "\(result.root.subdirs.reduce(0) { $0 + $1.totalSize })"
        )

        // The survivor is now the only name, so it no longer shares its storage
        // and a delete can promise its bytes back. Left as-is, the dialog would
        // offer 0 for a file the tree had just credited with 9,000 bytes.
        let survivorRef = NodeRef(dir: survivorFolder, fileIndex: 0)
        check(
            "the last name left stops counting as shared",
            survivorFolder.files[0].linkCount == 1
                && !survivorFolder.files[0].sharesStorage,
            "linkCount=\(survivorFolder.files[0].linkCount), "
                + "sharesStorage=\(survivorFolder.files[0].sharesStorage)"
        )
        check(
            "so deleting it promises its bytes back",
            model.reclaimableSize([survivorRef]) == survivorRef.alloc
                && survivorRef.alloc > 0,
            "got \(model.reclaimableSize([survivorRef])), expected \(survivorRef.alloc)"
        )

        // And removing that last name does take the bytes with it.
        trash(model, [survivorRef])
        check(
            "removing the last name finally drops the bytes",
            result.root.totalSize == rootBefore - size,
            "root is \(result.root.totalSize), expected \(rootBefore - size)"
        )
    }

    /// `FileEntry` is allocated once per file, several million times on a
    /// full-disk scan, so its width is a real memory budget rather than a
    /// detail. `fileID` was added to it by narrowing the link count to a byte,
    /// which kept the struct at 56; a field added carelessly would round it to
    /// 64 and cost 32 MB with nothing to show that it had.
    private static func testFileEntryStaysNarrow() {
        check(
            "FileEntry is still 56 bytes per file",
            MemoryLayout<FileEntry>.stride == 56,
            "got \(MemoryLayout<FileEntry>.stride), which is "
                + "\((MemoryLayout<FileEntry>.stride - 56) * 4_000_000 / 1_000_000)"
                + " MB more on a 4M-file scan"
        )
    }

    /// A folder holding one file was offered for deletion as "… and 1 items
    /// inside it?", and a scan of one file reported "1 files, 1 folders".
    private static func testCountsAreWordedInTheSingular() {
        check(
            "exactly one of something is worded in the singular",
            ByteFormat.counted(1, "item") == "1 item"
                && ByteFormat.counted(1, "folder") == "1 folder",
            "got “\(ByteFormat.counted(1, "item"))” and "
                + "“\(ByteFormat.counted(1, "folder"))”"
        )
        check(
            "none, and more than one, in the plural",
            ByteFormat.counted(0, "item") == "0 items"
                && ByteFormat.counted(2, "file") == "2 files",
            "got “\(ByteFormat.counted(0, "item"))” and "
                + "“\(ByteFormat.counted(2, "file"))”"
        )
    }

    /// The treemap lays itself out on a background queue, reading the very tree
    /// a delete unlinks nodes from. `AppModel.detach` fences that queue before
    /// it touches anything, and this is what checks the fence holds: layouts are
    /// left in flight while a folder is removed, and the totals afterwards have
    /// to be exactly what a quiet delete would have produced.
    ///
    /// Without the fence this is a read of freed memory — usually a crash, and
    /// otherwise silently wrong numbers.
    @MainActor
    private static func testTreemapLayoutIsFencedAgainstDeletes() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-fence-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            // Enough folders and files that a layout takes long enough to still
            // be running when the delete lands.
            for folder in 0..<12 {
                let dir = base.appendingPathComponent("d\(folder)/inner")
                try FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
                for file in 0..<40 {
                    try write(dir.appendingPathComponent("f\(file).dat"), bytes: 500 + file)
                }
            }
        } catch {
            check("the fence fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let doomed = result.root.subdir(named: "d0") else {
            check("the fence fixture scanned", false, "missing d0")
            return
        }
        let before = result.root.totalSize
        let doomedSize = doomed.totalSize
        let doomedFiles = doomed.totalFiles

        // Queued straight onto the model's treemap queue, exactly as the view
        // does, and deliberately not waited for.
        let root = result.root
        for _ in 0..<24 {
            model.treemapQueue.async {
                _ = TreemapLayout.build(
                    root: root,
                    ancestors: [],
                    size: CGSize(width: 1400, height: 500),
                    metric: .allocated
                )
            }
        }

        trash(model, [NodeRef(doomed)])

        check(
            "a delete during a layout reports no error",
            model.actionError == nil,
            model.actionError ?? ""
        )
        check(
            "the folder goes, with the layouts still queued behind it",
            result.root.subdir(named: "d0") == nil,
            "still attached"
        )
        check(
            "and the totals are exactly what a quiet delete would give",
            result.root.totalSize == before - doomedSize
                && result.root.totalFiles == doomedFiles * 11,
            "root is \(result.root.totalSize), expected \(before - doomedSize); "
                + "\(result.root.totalFiles) files, expected \(doomedFiles * 11)"
        )

        // Let the remaining layouts drain against the mutated tree before the
        // fixture is torn down, so a late one can't read a half-freed folder.
        model.treemapQueue.sync {}
        check(
            "layouts queued before the delete all finish cleanly",
            true,
            ""
        )
    }

    /// A rescan lets go of the tree without waiting for the treemap's queue the
    /// way a delete does, so a layout still waiting its turn has to hold
    /// everything it is going to read. It held the folder it was zoomed to and
    /// nothing above it — then walked that folder's unowned parent chain once it
    /// ran, through folders the rescan had already freed.
    ///
    /// The tree is built by hand so this owns every other reference to it, and
    /// the layout queue is held shut so the layout is still queued when the
    /// tree is dropped.
    @MainActor
    private static func testAQueuedLayoutPinsTheFoldersAboveItsRoot() {
        func entry(_ name: String, _ bytes: UInt64) -> FileEntry {
            FileEntry(
                name: name,
                size: bytes,
                alloc: bytes,
                mtime: 0,
                extIndex: -1,
                isSymlink: false,
                isDuplicateLink: false
            )
        }
        // scan root → middle → zoomed, the last being what the map is showing.
        func plant() -> (root: DirNode, zoomed: DirNode) {
            let root = DirNode(name: "/wizzzee-selftest-pin", parent: nil)
            let middle = DirNode(name: "middle", parent: root)
            let zoomed = DirNode(name: "zoomed", parent: middle)
            zoomed.files = [entry("a.dat", 6_000), entry("b.dat", 3_000)]
            for dir in [zoomed, middle, root] {
                dir.totalSize = 9_000
                dir.totalAlloc = 9_000
                dir.totalFiles = 2
            }
            middle.subdirs = [zoomed]
            middle.totalDirs = 1
            root.subdirs = [middle]
            root.totalDirs = 2
            return (root, zoomed)
        }

        // Watches the scan root without holding it.
        final class Watch { weak var node: DirNode? }

        var tree: (root: DirNode, zoomed: DirNode)? = plant()
        let scanRoot = Watch()
        scanRoot.node = tree?.root
        guard let zoomed = tree?.zoomed else { return }

        let queue = DispatchQueue(label: "com.wizzzee.selftest.layout")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }

        let view = TreemapNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.layoutQueue = queue
        view.apply(root: zoomed, metric: .allocated, revision: 0)

        // What a rescan does: the scan is dropped, and the view is handed
        // nothing in its place.
        tree = nil
        view.apply(root: nil, metric: .allocated, revision: 0)

        let pinned = scanRoot.node != nil
        check(
            "a queued layout keeps the folders above its root alive",
            pinned,
            "freed while the layout was still waiting to read them"
        )
        // Reading them now would be the very fault this is about, so a layout
        // that didn't pin its chain is cut loose from it before being let run.
        if !pinned { zoomed.parent = nil }

        gate.signal()
        queue.sync {}
        check(
            "and runs to the end against a scan that has been thrown away",
            true,
            ""
        )

        // The other half of pinning: holding on after the layout is done would
        // keep every folder of a discarded scan in memory.
        let deadline = Date().addingTimeInterval(5)
        while scanRoot.node != nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        check(
            "then lets go of them once it has finished",
            scanRoot.node == nil,
            "the discarded scan is still held"
        )
    }

    /// Laying the treemap out is asynchronous, so for a moment after a delete
    /// the tiles on show are the old ones — tiles for folders that have just
    /// been unlinked among them. A click on one handed the model a node that
    /// only the outgoing layout was keeping alive. The model kept it as its
    /// selection or zoom root, the new layout replaced the old, the folders
    /// above the node were freed, and the next thing to ask for its path read
    /// them.
    ///
    /// The map answers nothing until it shows the tree as it now is. Events are
    /// sent straight to the view here, and the layout queue is held shut to
    /// keep the stale layout on show for as long as the checks need it.
    @MainActor
    private static func testAStaleMapAnswersNoClicks() {
        func entry(_ name: String, _ bytes: UInt64) -> FileEntry {
            FileEntry(
                name: name,
                size: bytes,
                alloc: bytes,
                mtime: 0,
                extIndex: -1,
                isSymlink: false,
                isDuplicateLink: false
            )
        }
        func total(_ dir: DirNode, _ bytes: UInt64, files: Int, dirs: Int) {
            dir.totalSize = bytes
            dir.totalAlloc = bytes
            dir.totalFiles = files
            dir.totalDirs = dirs
        }
        // One folder taking nearly the whole map and one taking a sliver, so
        // the middle of the view is the first before the delete and the second
        // after it.
        let root = DirNode(name: "/wizzzee-selftest-stale", parent: nil)
        let doomed = DirNode(name: "doomed", parent: root)
        doomed.files = [entry("a.dat", 6_000), entry("b.dat", 3_000)]
        total(doomed, 9_000, files: 2, dirs: 0)
        let kept = DirNode(name: "kept", parent: root)
        kept.files = [entry("k.dat", 100)]
        total(kept, 100, files: 1, dirs: 0)
        root.subdirs = [doomed, kept]
        total(root, 9_100, files: 3, dirs: 2)

        let queue = DispatchQueue(label: "com.wizzzee.selftest.stale")
        var revision = 0
        var picked: [NodeRef] = []
        var hovered: [NodeRef] = []
        let view = TreemapNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.layoutQueue = queue
        view.liveRevision = { revision }
        view.onSelect = { picked.append($0) }
        view.onHover = { if let ref = $0 { hovered.append(ref) } }

        // The middle of the view, which reads the same flipped or not.
        func send(_ type: NSEvent.EventType) {
            guard
                let event = NSEvent.mouseEvent(
                    with: type,
                    location: NSPoint(x: 200, y: 150),
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            else { return }
            if type == .mouseMoved {
                view.mouseMoved(with: event)
            } else {
                view.mouseDown(with: event)
            }
        }
        // Lets a queued layout run and its result land on the main queue.
        func settle() {
            queue.sync {}
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        view.apply(root: root, metric: .allocated, revision: revision)
        settle()
        send(.leftMouseDown)
        send(.mouseMoved)
        // Without this the rest would pass for a view that ignored every click.
        check(
            "a click on the map picks the tile under it",
            picked.last?.dir === doomed && hovered.last?.dir === doomed,
            "picked \(picked.map(\.name)), hovered \(hovered.map(\.name))"
        )

        // What a delete does to the tree: the folder is unlinked, its bytes come
        // off the totals, and the revision moves on.
        root.subdirs.removeAll { $0 === doomed }
        total(root, 100, files: 1, dirs: 1)
        revision = 1
        picked = []
        hovered = []

        // SwiftUI has not told the view yet. A click can arrive first.
        send(.leftMouseDown)
        send(.mouseMoved)
        check(
            "a click that beats the view's own update picks nothing",
            picked.isEmpty && hovered.isEmpty,
            "picked \(picked.map(\.name)), hovered \(hovered.map(\.name)) "
                + "from a layout of the tree before the delete"
        )

        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        view.apply(root: root, metric: .allocated, revision: revision)
        send(.leftMouseDown)
        send(.mouseMoved)
        check(
            "nor does one while the new layout is still on its way",
            picked.isEmpty && hovered.isEmpty,
            "picked \(picked.map(\.name)), hovered \(hovered.map(\.name)) "
                + "from a layout of the tree before the delete"
        )

        gate.signal()
        settle()
        send(.leftMouseDown)
        check(
            "once the map shows the tree as it is, a click picks what is there",
            picked.count == 1 && picked.last?.dir === kept,
            "picked \(picked.map(\.name))"
        )
    }

    /// The mirror of the above: deleting the *duplicate* name first.
    ///
    /// Nothing moves in the totals — the duplicate was never counted — but the
    /// name still carrying the bytes loses a link, so it becomes the sole name
    /// and can promise its space again.
    @MainActor
    private static func testDeletingTheDuplicateNameFreesTheOther() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-pair2-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildLinkedPair(at: base)
        } catch {
            check("the second link fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let left = result.root.subdir(named: "left"),
            let right = result.root.subdir(named: "right")
        else {
            check("the second link fixture scanned", false, "missing folders")
            return
        }

        let duplicate: (dir: DirNode, index: Int)
        let counted: DirNode
        if let i = left.files.firstIndex(where: \.isDuplicateLink) {
            duplicate = (left, i)
            counted = right
        } else if let i = right.files.firstIndex(where: \.isDuplicateLink) {
            duplicate = (right, i)
            counted = left
        } else {
            check("one name of the pair is a duplicate", false, "neither is")
            return
        }

        let rootBefore = result.root.totalSize
        let countedBefore = counted.totalSize

        deletePermanently(
            model,
            [NodeRef(dir: duplicate.dir, fileIndex: duplicate.index)]
        )

        check(
            "removing the uncounted name moves nothing",
            result.root.totalSize == rootBefore
                && counted.totalSize == countedBefore,
            "root \(result.root.totalSize) of \(rootBefore), "
                + "counted \(counted.totalSize) of \(countedBefore)"
        )
        check(
            "the name still holding the bytes stops counting as shared",
            counted.files[0].linkCount == 1 && !counted.files[0].sharesStorage,
            "linkCount=\(counted.files[0].linkCount)"
        )
        check(
            "the double-counting figure goes to nothing",
            result.hardLinkSavings == 0,
            "got \(result.hardLinkSavings)"
        )
        check(
            "and deleting it now promises its bytes",
            model.reclaimableSize([NodeRef(dir: counted, fileIndex: 0)])
                == counted.files[0].alloc,
            "got \(model.reclaimableSize([NodeRef(dir: counted, fileIndex: 0)]))"
        )
    }

    /// The other direction: a hard link whose partner is outside the scan.
    ///
    /// Nothing is marked duplicate, so there is no survivor to promote, and the
    /// bytes genuinely leave the tree when the name does. The promotion must not
    /// fire and swallow the subtraction.
    @MainActor
    private static func testDeletingALinkWithNoPartnerInTreeSubtracts() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-outside-\(getpid())")
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-outside-target-\(getpid())")
            .appendingPathComponent("target.dat")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: outside.deletingLastPathComponent())
        }
        do {
            try buildOutsideLink(at: base, outside: outside)
        } catch {
            check("the outside-link fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard let index = result.root.files.firstIndex(where: {
            $0.name == "inside.dat"
        }) else {
            check("the outside-link fixture scanned", false, "missing file")
            return
        }
        check(
            "a link with its partner outside the scan isn't a duplicate",
            result.root.files[index].isHardLinked
                && !result.root.files[index].isDuplicateLink,
            "hardLinked=\(result.root.files[index].isHardLinked) "
                + "duplicate=\(result.root.files[index].isDuplicateLink)"
        )

        let before = result.root.totalSize
        let size = result.root.files[index].size
        trash(model, [NodeRef(dir: result.root, fileIndex: index)])

        check(
            "its bytes leave the tree, since no other name of it is in the tree",
            result.root.totalSize == before - size,
            "root is \(result.root.totalSize), expected \(before - size)"
        )
        check(
            "the file it was linked to is untouched",
            FileManager.default.fileExists(atPath: outside.path),
            "the partner outside the scan was removed too"
        )
    }

    /// Removing a folder subtracts its totals in one step, so nothing looked at
    /// the files inside it. A counted name went with its folder and took the
    /// bytes out of the tree while another name still held them on disk, and a
    /// duplicate went without its partner ever losing a link — the same two
    /// faults the single-file path was fixed for, reached by deleting the
    /// folder instead of the file.
    @MainActor
    private static func testDeletingAFolderHandsItsHardLinksOn() {
        // The folder holding the counted name of a cross-folder pair.
        withLinkFarm("counted") { model, result in
            guard
                let pair = roles(
                    result.root.subdir(named: "left"),
                    result.root.subdir(named: "right")
                )
            else {
                check("the farm's cross-folder pair scanned", false, "no duplicate")
                return
            }
            check(
                "the farm starts with every duplicate name set aside",
                result.hardLinkSavings == 20_000,
                "got \(result.hardLinkSavings), expected 20000"
            )
            let rootBefore = result.root.totalSize
            let survivorBefore = pair.duplicate.totalSize
            let filesBefore = result.root.totalFiles

            deletePermanently(model, [NodeRef(pair.counted)])

            check(
                "deleting the counted name's folder reports no error",
                model.actionError == nil,
                model.actionError ?? ""
            )
            check(
                "the bytes stay in the root's total, since they are still on disk",
                result.root.totalSize == rootBefore,
                "root is \(result.root.totalSize), expected \(rootBefore)"
            )
            check(
                "the surviving name's folder takes them over",
                pair.duplicate.totalSize == survivorBefore + 9_000,
                "got \(pair.duplicate.totalSize), "
                    + "expected \(survivorBefore + 9_000)"
            )
            check(
                "the survivor stops being a duplicate, and stops sharing",
                pair.duplicate.files.first?.isDuplicateLink == false
                    && pair.duplicate.files.first?.sharesStorage == false,
                "duplicate=\(String(describing: pair.duplicate.files.first?.isDuplicateLink)), "
                    + "linkCount=\(String(describing: pair.duplicate.files.first?.linkCount))"
            )
            check(
                "the double-counting figure drops by that one file",
                result.hardLinkSavings == 11_000,
                "got \(result.hardLinkSavings), expected 11000"
            )
            check(
                "the counts lose the folder and the one name in it",
                result.root.totalFiles == filesBefore - 1,
                "\(result.root.totalFiles) files, expected \(filesBefore - 1)"
            )
            check(
                "the root's total is still the sum of its folders",
                result.root.totalSize
                    == result.root.subdirs.reduce(0) { $0 + $1.totalSize },
                "root \(result.root.totalSize) vs folders "
                    + "\(result.root.subdirs.reduce(0) { $0 + $1.totalSize })"
            )
        }

        // The mirror: the folder holding the duplicate. Nothing moves, but the
        // name left behind is now the only one.
        withLinkFarm("duplicate") { model, result in
            guard
                let pair = roles(
                    result.root.subdir(named: "left"),
                    result.root.subdir(named: "right")
                )
            else {
                check("the second farm's pair scanned", false, "no duplicate")
                return
            }
            let rootBefore = result.root.totalSize
            let countedBefore = pair.counted.totalSize

            deletePermanently(model, [NodeRef(pair.duplicate)])

            check(
                "removing the duplicate's folder moves nothing",
                result.root.totalSize == rootBefore
                    && pair.counted.totalSize == countedBefore,
                "root \(result.root.totalSize) of \(rootBefore), "
                    + "counted \(pair.counted.totalSize) of \(countedBefore)"
            )
            check(
                "the name still holding the bytes stops counting as shared",
                pair.counted.files.first?.linkCount == 1
                    && pair.counted.files.first?.sharesStorage == false,
                "linkCount=\(String(describing: pair.counted.files.first?.linkCount))"
            )
            check(
                "and the double-counting figure forgets the name that went",
                result.hardLinkSavings == 11_000,
                "got \(result.hardLinkSavings), expected 11000"
            )
        }

        // Both names under the folder being removed, then three names removed
        // a folder at a time.
        withLinkFarm("inside") { model, result in
            guard let both = result.root.subdir(named: "both"),
                let trio = result.root.subdir(named: "trio")
            else {
                check("the third farm scanned", false, "missing folders")
                return
            }
            let rootBefore = result.root.totalSize

            deletePermanently(model, [NodeRef(both)])
            check(
                "a pair wholly inside the folder leaves with it, once",
                result.root.totalSize == rootBefore - 7_000
                    && result.hardLinkSavings == 13_000,
                "root \(result.root.totalSize), expected \(rootBefore - 7_000); "
                    + "savings \(result.hardLinkSavings), expected 13000"
            )

            let trioBefore = trio.totalSize
            guard
                let counted = trio.subdirs.first(where: {
                    $0.files.first?.isDuplicateLink == false
                })
            else {
                check("one of the three names is counted", false, "none is")
                return
            }
            deletePermanently(model, [NodeRef(counted)])
            let promoted = trio.subdirs.filter {
                $0.files.first?.isDuplicateLink == false
            }
            check(
                "exactly one of the two names left takes the bytes over",
                trio.subdirs.count == 2 && promoted.count == 1
                    && trio.totalSize == trioBefore,
                "\(promoted.count) promoted of \(trio.subdirs.count), "
                    + "trio is \(trio.totalSize), expected \(trioBefore)"
            )
            check(
                "both still share their storage, with one link fewer each",
                trio.subdirs.allSatisfy { $0.files.first?.linkCount == 2 },
                "link counts \(trio.subdirs.map { $0.files.first?.linkCount ?? 0 })"
            )
            check(
                "and only one of them is still set aside as a duplicate",
                result.hardLinkSavings == 11_000,
                "got \(result.hardLinkSavings), expected 11000"
            )

            guard let next = promoted.first else { return }
            deletePermanently(model, [NodeRef(next)])
            check(
                "the last name of the three ends up alone holding the bytes",
                trio.subdirs.count == 1
                    && trio.subdirs.first?.files.first?.sharesStorage == false
                    && trio.totalSize == trioBefore
                    && result.hardLinkSavings == 9_000,
                "trio is \(trio.totalSize), expected \(trioBefore); "
                    + "savings \(result.hardLinkSavings), expected 9000"
            )
        }

        // Two of three names in one batch, whichever of them the scan counted:
        // the one left ends up alone holding the bytes.
        withLinkFarm("batch-trio") { model, result in
            guard let trio = result.root.subdir(named: "trio"),
                let a = trio.subdir(named: "a"),
                let b = trio.subdir(named: "b"),
                let c = trio.subdir(named: "c")
            else {
                check("the trio farm scanned", false, "missing folders")
                return
            }
            let trioBefore = trio.totalSize
            deletePermanently(model, [NodeRef(a), NodeRef(b)])
            check(
                "two names of three gone in one batch leave the third alone with the bytes",
                trio.subdirs.count == 1 && trio.totalSize == trioBefore
                    && c.totalSize == 2_000
                    && c.files.first?.isDuplicateLink == false
                    && c.files.first?.linkCount == 1
                    && result.hardLinkSavings == 16_000,
                "trio \(trio.totalSize) of \(trioBefore), c \(c.totalSize), "
                    + "linkCount \(String(describing: c.files.first?.linkCount)), "
                    + "savings \(result.hardLinkSavings), expected 16000"
            )
        }

        // Both folders of the pair in one batch: the bytes move to the second
        // when the first goes, and must then leave with it — once.
        withLinkFarm("batch") { model, result in
            guard let left = result.root.subdir(named: "left"),
                let right = result.root.subdir(named: "right")
            else {
                check("the fourth farm scanned", false, "missing folders")
                return
            }
            let rootBefore = result.root.totalSize
            deletePermanently(model, [NodeRef(left), NodeRef(right)])
            check(
                "deleting both folders of a pair drops its bytes exactly once",
                result.root.totalSize == rootBefore - 9_000
                    && result.hardLinkSavings == 11_000,
                "root \(result.root.totalSize), expected \(rootBefore - 9_000); "
                    + "savings \(result.hardLinkSavings), expected 11000"
            )
        }
    }

    /// The figure in the delete confirmation is the last thing read before an
    /// irreversible delete, and for a folder it was the folder's whole total —
    /// including every hard-linked file in it whose data has another name
    /// somewhere else. Deleting the folder frees none of those, so the dialog
    /// promised space that never came back, with no hard-link caveat either.
    @MainActor
    private static func testAFolderPromisesOnlyWhatDeletingItFrees() {
        withLinkFarm("promise") { model, result in
            guard
                let pair = roles(
                    result.root.subdir(named: "left"),
                    result.root.subdir(named: "right")
                ),
                let plain = result.root.subdir(named: "plain"),
                let both = result.root.subdir(named: "both"),
                let trio = result.root.subdir(named: "trio"),
                let mixed = result.root.subdir(named: "mixed"),
                let ordinary = mixed.files.first(where: { $0.name == "m.dat" })
            else {
                check("the promise farm scanned", false, "missing folders")
                return
            }

            check(
                "a folder of ordinary files promises all of it",
                model.reclaimableSize([NodeRef(plain)]) == plain.totalAlloc
                    && plain.totalAlloc > 0
                    && !model.selectionSharesStorage([NodeRef(plain)]),
                "got \(model.reclaimableSize([NodeRef(plain)])) "
                    + "of \(plain.totalAlloc)"
            )
            check(
                "a folder whose only file has another name elsewhere promises nothing",
                model.reclaimableSize([NodeRef(pair.counted)]) == 0
                    && pair.counted.totalAlloc > 0,
                "got \(model.reclaimableSize([NodeRef(pair.counted)])) for a "
                    + "folder of \(pair.counted.totalAlloc)"
            )
            check(
                "and the dialog is told why",
                model.selectionSharesStorage([NodeRef(pair.counted)])
                    && model.selectionSharesStorage([NodeRef(pair.duplicate)]),
                "it would have quoted a plain figure"
            )
            check(
                "a folder holding every name of a file still promises it",
                model.reclaimableSize([NodeRef(both)]) == both.totalAlloc
                    && model.reclaimableSize([NodeRef(trio)]) == trio.totalAlloc
                    && both.totalAlloc > 0 && trio.totalAlloc > 0
                    && !model.selectionSharesStorage([NodeRef(both), NodeRef(trio)]),
                "both: \(model.reclaimableSize([NodeRef(both)])) of "
                    + "\(both.totalAlloc), trio: "
                    + "\(model.reclaimableSize([NodeRef(trio)])) of \(trio.totalAlloc)"
            )
            // The other name isn't in the tree at all here, so only the link
            // count says it exists.
            check(
                "a name whose partner is outside the scan is left out too",
                model.reclaimableSize([NodeRef(mixed)]) == ordinary.alloc
                    && ordinary.alloc > 0
                    && model.selectionSharesStorage([NodeRef(mixed)]),
                "got \(model.reclaimableSize([NodeRef(mixed)])), "
                    + "expected \(ordinary.alloc)"
            )
            check(
                "a batch adds up the same way",
                model.reclaimableSize([
                    NodeRef(plain), NodeRef(pair.counted), NodeRef(mixed),
                ]) == plain.totalAlloc + ordinary.alloc,
                "got "
                    + "\(model.reclaimableSize([NodeRef(plain), NodeRef(pair.counted), NodeRef(mixed)]))"
                    + ", expected \(plain.totalAlloc + ordinary.alloc)"
            )

            model.sizeMetric = .logical
            check(
                "the logical metric leaves the same files out",
                model.reclaimableSize([NodeRef(mixed)]) == 3_000
                    && model.reclaimableSize([NodeRef(pair.counted)]) == 0
                    && model.reclaimableSize([NodeRef(both)]) == 7_000,
                "mixed \(model.reclaimableSize([NodeRef(mixed)])), "
                    + "pair \(model.reclaimableSize([NodeRef(pair.counted)])), "
                    + "both \(model.reclaimableSize([NodeRef(both)]))"
            )
            model.sizeMetric = .allocated

            // Once the other name is gone the bytes really are this folder's to
            // free, and an answer worked out before the delete must not be the
            // one given after it.
            deletePermanently(model, [NodeRef(pair.duplicate)])
            check(
                "the same folder promises its file once the other name is gone",
                model.reclaimableSize([NodeRef(pair.counted)])
                    == pair.counted.totalAlloc
                    && !model.selectionSharesStorage([NodeRef(pair.counted)]),
                "got \(model.reclaimableSize([NodeRef(pair.counted)])) "
                    + "of \(pair.counted.totalAlloc)"
            )
        }
    }

    /// Moving a name to the Trash takes it out of the tree but not off its
    /// inode — the file in the Trash is still a second name for the same bytes.
    /// Treated as gone, it left the survivor looking like the only name, and
    /// the delete confirmation promised back bytes that stay on disk until the
    /// Trash is emptied. The bytes still move to the survivor in the tree; what
    /// it keeps is its link count.
    @MainActor
    private static func testATrashedNameStillSharesItsStorage() {
        func names(atPath path: String) -> Int {
            var info = stat()
            return lstat(path, &info) == 0 ? Int(info.st_nlink) : -1
        }

        // The folder holding the counted name, sent to the Trash.
        withLinkFarm("trash-folder") { model, result in
            guard
                let pair = roles(
                    result.root.subdir(named: "left"),
                    result.root.subdir(named: "right")
                )
            else {
                check("the trashed farm's pair scanned", false, "no duplicate")
                return
            }
            let survivor = NodeRef(dir: pair.duplicate, fileIndex: 0)
            let rootBefore = result.root.totalSize

            trash(model, [NodeRef(pair.counted)])

            check(
                "the disk still has two names for a file whose folder was trashed",
                names(atPath: survivor.path) == 2,
                "lstat reports \(names(atPath: survivor.path))"
            )
            check(
                "the survivor takes the bytes over in the tree all the same",
                pair.duplicate.totalSize == 9_000
                    && result.root.totalSize == rootBefore
                    && survivor.file?.isDuplicateLink == false,
                "its folder is \(pair.duplicate.totalSize), root "
                    + "\(result.root.totalSize) of \(rootBefore)"
            )
            check(
                "but goes on sharing them with the name in the Trash",
                survivor.file?.linkCount == 2 && survivor.file?.sharesStorage == true,
                "linkCount=\(String(describing: survivor.file?.linkCount))"
            )
            check(
                "so deleting it, or its folder, promises nothing back",
                model.reclaimableSize([survivor]) == 0
                    && model.reclaimableSize([NodeRef(pair.duplicate)]) == 0
                    && model.selectionSharesStorage([NodeRef(pair.duplicate)]),
                "file \(model.reclaimableSize([survivor])), folder "
                    + "\(model.reclaimableSize([NodeRef(pair.duplicate)]))"
            )
        }

        // Single files: a duplicate name, which hands nothing on, and a counted
        // one of three, which does.
        withLinkFarm("trash-file") { model, result in
            guard
                let pair = roles(
                    result.root.subdir(named: "left"),
                    result.root.subdir(named: "right")
                ),
                let trio = result.root.subdir(named: "trio"),
                let counted = trio.subdirs.first(where: {
                    $0.files.first?.isDuplicateLink == false
                })
            else {
                check("the second trashed farm scanned", false, "missing folders")
                return
            }
            let holder = NodeRef(dir: pair.counted, fileIndex: 0)

            trash(model, [NodeRef(dir: pair.duplicate, fileIndex: 0)])
            check(
                "trashing the duplicate name leaves the counted one sharing",
                holder.file?.linkCount == 2 && model.reclaimableSize([holder]) == 0
                    && names(atPath: holder.path) == 2,
                "linkCount=\(String(describing: holder.file?.linkCount)), "
                    + "promised \(model.reclaimableSize([holder]))"
            )

            let trioBefore = trio.totalSize
            trash(model, [NodeRef(dir: counted, fileIndex: 0)])
            let left = trio.subdirs.compactMap { live($0).first }
            check(
                "trashing the counted name of three promotes one and unlinks none",
                left.count == 2
                    && left.filter { !$0.isDuplicateLink }.count == 1
                    && left.allSatisfy { $0.linkCount == 3 }
                    && trio.totalSize == trioBefore,
                "link counts \(left.map(\.linkCount)), duplicates "
                    + "\(left.map(\.isDuplicateLink)), trio \(trio.totalSize)"
            )
        }
    }

    /// The File Types panel was worked out once per scan and never again. A
    /// delete moved every total in the tree and left the panel quoting types,
    /// sizes and counts for files that were gone — measured against the new,
    /// smaller total, so one deleted 1.5 GB file read as "31789.1 %" of a scan
    /// that no longer held it.
    ///
    /// Checked against ground truth: after each removal the per-type figures
    /// have to be exactly what a fresh scan of the same folder reports.
    @MainActor
    private static func testFileTypesFollowADelete() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-types-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            for folder in ["a", "b", "c"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            // One file with a name of each of two types, in different folders,
            // so whichever the scan counted, removing it moves bytes between
            // types as well as between folders.
            try write(base.appendingPathComponent("a/one.dat"), bytes: 9_000)
            try FileManager.default.linkItem(
                at: base.appendingPathComponent("a/one.dat"),
                to: base.appendingPathComponent("b/one.log")
            )
            try write(base.appendingPathComponent("a/two.dat"), bytes: 4_000)
            try write(base.appendingPathComponent("b/three.log"), bytes: 2_000)
            try write(base.appendingPathComponent("c/four.txt"), bytes: 1_000)
            try write(base.appendingPathComponent("c/five.bin"), bytes: 6_000)
        } catch {
            check("the file-types fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }

        // Per type, for the types that still have a file: size, on disk, count.
        func types(_ scan: ScanResult) -> [String: [UInt64]] {
            var table: [String: [UInt64]] = [:]
            for stat in scan.extensionStats where stat.count > 0 {
                table[stat.ext] = [stat.size, stat.alloc, UInt64(stat.count)]
            }
            return table
        }
        func describe(_ table: [String: [UInt64]]) -> String {
            table.keys.sorted().map { "\($0)=\(table[$0] ?? [])" }
                .joined(separator: " ")
        }
        // While both names of the hard-linked file are in the tree, which of
        // its two types gets the bytes is whichever a scan worker reached
        // first, and two scans need not agree. Until one name is gone the
        // comparison is of what cannot differ: every type's count, and the
        // bytes summed over all of them.
        func agrees(_ what: String, exactly: Bool = true) {
            let panel = types(result)
            let fresh = types(scan(base))
            func counts(_ t: [String: [UInt64]]) -> [String: UInt64] {
                t.mapValues { $0[2] }
            }
            func bytes(_ t: [String: [UInt64]]) -> [UInt64] {
                [t.values.reduce(0) { $0 + $1[0] }, t.values.reduce(0) { $0 + $1[1] }]
            }
            check(
                what,
                exactly
                    ? panel == fresh
                    : counts(panel) == counts(fresh) && bytes(panel) == bytes(fresh),
                "panel \(describe(panel)), a fresh scan \(describe(fresh))"
            )
        }

        agrees("the file types start out as a fresh scan reports them", exactly: false)

        guard let c = result.root.subdir(named: "c"),
            let four = c.files.firstIndex(where: { $0.name == "four.txt" }),
            let a = result.root.subdir(named: "a")
        else {
            check("the file-types fixture scanned", false, "missing folders")
            return
        }
        deletePermanently(model, [NodeRef(dir: c, fileIndex: four)])
        agrees("deleting the only file of a type takes that type away", exactly: false)
        check(
            "and it is gone from the panel's rankings, not left there at nothing",
            result.stat(for: "txt")?.count == 0
                && !result.topBySize.contains { $0.ext == "txt" }
                && !result.topByAllocated.contains { $0.ext == "txt" }
                && result.typeCount == 3,
            "top by size \(result.topBySize.map(\.ext)), "
                + "\(result.typeCount) types counted"
        )

        deletePermanently(model, [NodeRef(a)])
        agrees("deleting a folder takes its files out of their types")
        check(
            "and a hard link's bytes move to the type of the name that is left",
            result.stat(for: "log")?.size == 11_000
                && (result.stat(for: "dat")?.count ?? 0) == 0,
            "log is \(result.stat(for: "log")?.size ?? 0) bytes, "
                + "dat still has \(result.stat(for: "dat")?.count ?? 0) files"
        )

        trash(model, [NodeRef(c)])
        agrees("moving a folder to the Trash does the same")
        check(
            "leaving the one type that still has files",
            result.topBySize.map(\.ext) == ["log"]
                && result.topByAllocated.map(\.ext) == ["log"]
                && result.typeCount == 1,
            "top by size \(result.topBySize.map(\.ext)), "
                + "\(result.typeCount) types counted"
        )
    }

    /// Two files in one folder, trashed together. Taking an entry out used to
    /// renumber every sibling after it, so the batch had to unlink from the back
    /// — done front-to-back it dropped the wrong rows from the model while
    /// deleting the right files from disk, which no error would ever reveal.
    /// The entries now keep their slots and the order no longer matters; that
    /// the model drops exactly the two that went is still what is checked.
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
        // order the filesystem enumerated them.
        let names = dir.files.map(\.name)
        let paths = (0..<3).map { dir.path(ofFileAt: $0) }
        let removedBytes = dir.files[0].size + dir.files[2].size
        let before = result.root.totalSize
        let beforeFiles = result.root.totalFiles

        // Selected and in the table, as they are when this is done by hand.
        let doomed: Set<NodeRef> = [
            NodeRef(dir: dir, fileIndex: 0), NodeRef(dir: dir, fileIndex: 2),
        ]
        model.setExpanded(dir, true)
        model.selection = doomed
        trash(model, doomed)

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
            live(dir).map(\.name) == [names[1]],
            "got \(live(dir).map(\.name)), expected [\(names[1])]"
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
            "the selection moves to the sibling that is left",
            model.selection == [NodeRef(dir: dir, fileIndex: 1)],
            "selection is \(model.selection.map(\.name))"
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
        deletePermanently(model, [
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
        // The folder was a row under the root with others beside it, so the
        // selection has a neighbour to move to and none of what went to keep.
        check(
            "the selection moves off what went, to a folder beside it",
            model.selection.count == 1
                && model.selection.allSatisfy {
                    !$0.isStale && $0.isDirectory && $0.dir.parent === result.root
                },
            "selection is \(model.selection.map(\.name))"
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

        deletePermanently(model, [NodeRef(b)])

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
            "/usr/local itself is not treated as protected",
            !FileActions.isSystemProtected("/usr/local"),
            "wrongly flagged"
        )
        // The exemption is a whole path component: matched as a bare prefix it
        // also waves through anything merely starting with those letters.
        check(
            "a sibling of /usr/local is still protected",
            FileActions.isSystemProtected("/usr/locality/bin/thing"),
            "the /usr/local exemption swallowed it"
        )
        check(
            "a home path is not treated as protected",
            !FileActions.isSystemProtected(NSHomeDirectory() + "/Downloads/x.zip"),
            "wrongly flagged"
        )
        // /System/Volumes/Data is the writable data volume's mount point and a
        // legitimate scan target — it is what a scan of / skips to avoid
        // double-counting firmlinks. Caught by the bare "/System/" prefix, every
        // delete in such a scan was refused with a false claim that the user's
        // own home directory was on the sealed read-only volume.
        check(
            "the data volume is not treated as protected",
            !FileActions.isSystemProtected(
                "/System/Volumes/Data/Users/someone/Downloads/x.zip"
            ),
            "the whole data volume was flagged read-only"
        )
        check(
            "the data volume's own mount point is not protected",
            !FileActions.isSystemProtected("/System/Volumes/Data"),
            "wrongly flagged"
        )
        check(
            "other paths under /System/Volumes are still protected",
            FileActions.isSystemProtected("/System/Volumes/Update/mnt1/x"),
            "the exemption was too broad"
        )
        check(
            "a name merely starting with System isn't caught",
            !FileActions.isSystemProtected("/Systemic/thing"),
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

    /// The header's capacity figures came from the scan's own snapshot for as
    /// long as there was a scan. Permanently deleting something moved every
    /// total in the tree, and "Volume Free" went on quoting the number from
    /// before it until the next full scan.
    ///
    /// The readings after each delete are supplied here rather than taken from
    /// the disk. Free space on a real volume moves for reasons that have
    /// nothing to do with this test, and is given back on the filesystem's own
    /// schedule, so asserting on it would fail on a busy machine for nothing.
    @MainActor
    private static func testVolumeFreeSpaceFollowsADelete() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wizzzee-selftest-capacity-\(getpid())")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
            for name in ["first.dat", "second.dat", "keep.dat"] {
                try write(base.appendingPathComponent(name), bytes: 1_000)
            }
        } catch {
            check("the capacity fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        func ref(_ name: String) -> NodeRef? {
            result.root.files.firstIndex { $0.name == name }
                .map { NodeRef(dir: result.root, fileIndex: $0) }
        }
        let scanned = model.targetCapacity
        check(
            "the header starts from the capacity the scan recorded",
            scanned.total == result.volumeTotal && scanned.free == result.volumeFree
                && scanned.total > 0,
            "got \(scanned), the scan recorded "
                + "\(result.volumeTotal)/\(result.volumeFree)"
        )

        // What the volume will say once the delete has run.
        let freed: UInt64 = 80_000_000_000
        var asked: [String] = []
        model.readCapacity = { path in
            asked.append(path)
            return (scanned.total, scanned.free + freed)
        }
        guard let first = ref("first.dat") else {
            check("the capacity fixture scanned", false, "missing first.dat")
            return
        }
        deletePermanently(model, [first])

        check(
            "the scanned volume is read again once a delete has run",
            asked == [result.rootPath],
            "asked about \(asked), expected one read of \(result.rootPath)"
        )
        check(
            "and that reading is what goes on show",
            model.targetCapacity.free == scanned.free + freed
                && model.targetCapacity.total == scanned.total,
            "showing \(model.targetCapacity), the volume said "
                + "\(scanned.total)/\(scanned.free + freed)"
        )

        // A read that fails comes back as zeros. Shown, it would turn the
        // header into "0 bytes" of a disk that is plainly still there.
        model.readCapacity = { _ in (0, 0) }
        if let second = ref("second.dat") { deletePermanently(model, [second]) }
        check(
            "a reading that failed is not put on show",
            model.targetCapacity.free == scanned.free + freed
                && model.targetCapacity.total == scanned.total,
            "showing \(model.targetCapacity)"
        )

        // Not kept past the scan it belonged to: the next one records its own.
        guard let rescanned = loadSynchronously(into: model) else { return }
        check(
            "a rescan goes back to the figures it records itself",
            model.targetCapacity.free == rescanned.volumeFree
                && model.targetCapacity.total == rescanned.volumeTotal,
            "got \(model.targetCapacity), the rescan recorded "
                + "\(rescanned.volumeTotal)/\(rescanned.volumeFree)"
        )
    }

    /// The volume list was read once at launch and never again — the method
    /// that refreshes it had no caller — so a disk plugged in afterwards never
    /// appeared in the picker and an ejected one stayed in it.
    ///
    /// No disk is mounted here. The workspace notifications are posted by hand,
    /// which is all a real mount amounts to as far as the model can tell.
    @MainActor
    private static func testTheVolumeListFollowsMountsAndUnmounts() {
        func announce(_ name: Notification.Name) {
            NSWorkspace.shared.notificationCenter.post(
                name: name,
                object: NSWorkspace.shared,
                userInfo: [NSWorkspace.volumeURLUserInfoKey: URL(fileURLWithPath: "/")]
            )
        }
        func pump(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !done() && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        let model = AppModel()
        guard let boot = model.volumes.first?.path else {
            check("there is at least one volume to list", false, "none")
            return
        }

        // A disk that has since been ejected: still selected, no longer mounted.
        model.selectedVolumePath = "/Volumes/wizzzee-selftest-ejected-\(getpid())"
        announce(NSWorkspace.didUnmountNotification)
        pump { model.selectedVolumePath == boot }
        check(
            "an unmount moves the selection off a disk that is gone",
            model.selectedVolumePath == boot,
            "still on \(model.selectedVolumePath)"
        )

        // As if the list had been read before a disk was plugged in.
        model.volumes = []
        announce(NSWorkspace.didMountNotification)
        pump { !model.volumes.isEmpty }
        check(
            "a mount is picked up without relaunching",
            model.volumes.first?.path == boot,
            "the list is \(model.volumes.map(\.path))"
        )

        // A rename moves the mount point, and the selection has to move with
        // it. Treated as an eject, it fell back to the boot volume and the next
        // Scan read a different disk from the one that had been picked.
        let before = URL(fileURLWithPath: "/Volumes/wizzzee-selftest-old-\(getpid())")
        let renamed = URL(fileURLWithPath: "/Volumes/wizzzee-selftest-new-\(getpid())")
        func rename(_ name: Notification.Name, to new: URL) -> Notification {
            Notification(
                name: name,
                object: NSWorkspace.shared,
                userInfo: [
                    NSWorkspace.oldVolumeURLUserInfoKey: before,
                    NSWorkspace.volumeURLUserInfoKey: new,
                ]
            )
        }
        let renameNote = rename(NSWorkspace.didRenameVolumeNotification, to: renamed)
        check(
            "a renamed volume keeps the selection, at its new mount point",
            AppModel.selection(before.path, following: renameNote) == renamed.path,
            "got \(AppModel.selection(before.path, following: renameNote))"
        )
        check(
            "a selection on some other volume is left where it was",
            AppModel.selection(boot, following: renameNote) == boot,
            "got \(AppModel.selection(boot, following: renameNote))"
        )
        check(
            "and only a rename moves it",
            AppModel.selection(
                before.path,
                following: rename(NSWorkspace.didUnmountNotification, to: renamed)
            ) == before.path,
            "an unmount carrying the same paths moved the selection"
        )
        // Through the model, onto a volume that is really mounted — the last in
        // the list, so that where there is more than one it can't be mistaken
        // for the fallback to the first.
        if let target = model.volumes.last?.path {
            model.selectedVolumePath = before.path
            NSWorkspace.shared.notificationCenter.post(
                rename(
                    NSWorkspace.didRenameVolumeNotification,
                    to: URL(fileURLWithPath: target)
                )
            )
            pump { model.selectedVolumePath == target }
            check(
                "the model follows a rename of the volume it has selected",
                model.selectedVolumePath == target,
                "on \(model.selectedVolumePath), expected \(target)"
            )
        }

        // Watching for mounts must not be what keeps a model alive.
        final class Watch { weak var model: AppModel? }
        let watch = Watch()
        do {
            let discarded = AppModel()
            watch.model = discarded
        }
        announce(NSWorkspace.didMountNotification)
        pump { watch.model == nil }
        check(
            "a discarded model is let go rather than kept listening",
            watch.model == nil,
            "still alive"
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

    /// Runs the main run loop until the File View's background walk has delivered
    /// `expecting` rows.
    @MainActor
    private static func pumpUntilFileRowsSettle(_ model: AppModel, expecting: Int) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !model.isFilteringFiles && model.fileRows.count == expecting { return }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Trashes `refs` and runs the main run loop until the batch has finished.
    ///
    /// The delete itself runs off the main actor so a large tree can't stop the
    /// run loop, which means the assertions after it would otherwise read the
    /// tree before anything had been removed.
    @MainActor
    private static func trash(_ model: AppModel, _ refs: Set<NodeRef>) {
        model.moveToTrash(refs)
        pumpUntilDeleteSettles(model)
    }

    @MainActor
    private static func deletePermanently(_ model: AppModel, _ refs: Set<NodeRef>) {
        model.deletePermanently(refs)
        pumpUntilDeleteSettles(model)
    }

    @MainActor
    private static func pumpUntilDeleteSettles(_ model: AppModel) {
        let deadline = Date().addingTimeInterval(30)
        while model.isDeleting && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        // One more turn so the batch's own completion work — detaching the
        // successes and reporting failures — has run before anything is checked.
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
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

    /// A folder's files that are still there, without the slots that deleted
    /// ones leave behind.
    private static func live(_ dir: DirNode) -> [FileEntry] {
        dir.files.filter { !$0.isRemoved }
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
