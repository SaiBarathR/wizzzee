import AppKit
import Combine
import Foundation
import SwiftUI

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
        // A model starts from what was chosen last time. Left on the real
        // preferences, every check here would start from whatever measure
        // and folder the person running it last picked in the app.
        let suite = "wizzzee-selftest-\(getpid())"
        let scratchPreferences = UserDefaults(suiteName: suite)
        if let scratchPreferences { Preferences.store = scratchPreferences }
        func finish(_ status: Int32) -> Never {
            scratchPreferences?.removePersistentDomain(forName: suite)
            exit(status)
        }

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
        testMarksGatherAcrossFolders()
        testAMarkStaysOnWhatCouldNotBeRemoved()
        testTheTreemapShowsAndTakesMarks()
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
        testAFileTypeCanBePickedOut()
        testTheMapSetsBackWhatIsOutOfFocus()
        testTheLegendCanListEveryType()
        testATypeOfNothingButSecondNamesCannotTakeTheFocus()
        testAFocusOutsideTheShortListStaysInTheLegend()
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
        testArrowKeysOpenAndShutFolders()
        testThePathAboveTheMapZoomsOut()
        testTabsAnswerTheirKeys()
        testARescanKeepsYourPlace()
        testAMoveToTheTrashCanBeUndone()
        testWhatCannotBePutBackStaysInTheTrash()
        testPuttingBackMovesOnlyWhatWasPutThere()
        testUndoingATrashPutsHardLinksRight()
        testChoicesOutlastALaunch()
        testQuickLookShowsWhatIsSelected()
        testASearchIsReadFromWhatWasTyped()
        testASearchFindsFoldersAndCountsWhatItFinds()
        testTheFileViewSearches()
        testARevealedRowIsScrolledIntoView()
        testTreemapVisibilityPersists()
        testPreferenceSummary()

        print("")
        if failures == 0 {
            print("all \(checks) checks passed")
            finish(0)
        }
        print("\(failures) of \(checks) checks FAILED")
        finish(1)
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

    // MARK: - Marks

    /// Marks are what gets removed when the list of them is acted on, so what
    /// they stand for is pinned down here: one mark for a folder and all it
    /// holds, never two that overlap, nothing marked that can't be removed,
    /// and a total that counts each byte once.
    //
    // docs/a.txt       30,000 bytes
    // docs/b.txt       20,000
    // docs/old/c.txt   10,000
    // media/m.bin      40,000
    // loose.dat         5,000
    @MainActor
    private static func testMarksGatherAcrossFolders() {
        let base = scratch("marks")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            for folder in ["docs/old", "media"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            try write(base.appendingPathComponent("docs/a.txt"), bytes: 30_000)
            try write(base.appendingPathComponent("docs/b.txt"), bytes: 20_000)
            try write(base.appendingPathComponent("docs/old/c.txt"), bytes: 10_000)
            try write(base.appendingPathComponent("media/m.bin"), bytes: 40_000)
            try write(base.appendingPathComponent("loose.dat"), bytes: 5_000)
        } catch {
            check("the marks fixture can be built", false, "\(error)")
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
        guard let docs = result.root.subdir(named: "docs"),
            let old = docs.subdir(named: "old"),
            let media = result.root.subdir(named: "media"),
            let a = docs.files.firstIndex(where: { $0.name == "a.txt" }),
            let b = docs.files.firstIndex(where: { $0.name == "b.txt" }),
            let loose = result.root.files.firstIndex(where: { $0.name == "loose.dat" })
        else {
            check("the marks fixture scanned", false, "missing entries")
            return
        }
        let aRef = NodeRef(dir: docs, fileIndex: a)
        let bRef = NodeRef(dir: docs, fileIndex: b)
        let cRef = NodeRef(dir: old, fileIndex: 0)
        let mRef = NodeRef(dir: media, fileIndex: 0)
        let looseRef = NodeRef(dir: result.root, fileIndex: loose)
        let rootRef = NodeRef(result.root)

        model.toggleMarks([rootRef])
        check(
            "what can't be removed can't be marked",
            !model.canMark(rootRef) && model.marks.isEmpty,
            "marked \(model.marks.map(\.name))"
        )

        // From three different folders, which a selection could only hold
        // for as long as all three stayed open and nothing else was clicked.
        model.toggleMarks([aRef])
        model.toggleMarks([cRef])
        model.toggleMarks([mRef])
        model.selection = [looseRef]
        model.setExpanded(docs, false)
        model.tab = .files
        model.tab = .tree
        check(
            "marks from different folders outlast the selection moving on",
            model.marks == [aRef, cRef, mRef],
            "marked \(model.marks.map(\.name).sorted())"
        )
        check(
            "a folder with something marked inside it says so",
            model.markState(NodeRef(docs)) == .partial
                && model.markState(NodeRef(old)) == .partial
                && model.markState(NodeRef(media)) == .partial
                && model.markState(bRef) == .none
                && model.markState(aRef) == .marked,
            "docs \(model.markState(NodeRef(docs))), b \(model.markState(bRef))"
        )
        check(
            "the total is the sum of what each would free",
            model.markedBytes == aRef.alloc + cRef.alloc + mRef.alloc
                && model.marksSummary
                    == "3 marked  •  "
                    + ByteFormat.decimal(aRef.alloc + cRef.alloc + mRef.alloc),
            model.marksSummary
        )
        check(
            "the list runs largest first",
            model.markedItems == [mRef, aRef, cRef],
            "listed \(model.markedItems.map(\.name))"
        )
        // The total sits beside a button that removes without asking again,
        // so it is what removing gives back whatever the tables are showing.
        // None of these files fills its last block, so the two differ.
        model.sizeMetric = .logical
        check(
            "with Size showing, the total is still space on disk",
            model.markedBytes == aRef.alloc + cRef.alloc + mRef.alloc
                && model.markedBytes != aRef.size + cRef.size + mRef.size,
            "\(model.markedBytes), lengths come to "
                + "\(aRef.size + cRef.size + mRef.size)"
        )
        model.sizeMetric = .allocated

        // A folder's mark stands for all of it.
        model.toggleMarks([NodeRef(docs)])
        check(
            "marking a folder takes over the marks inside it",
            model.marks == [NodeRef(docs), mRef]
                && model.markState(aRef) == .covered
                && model.markState(cRef) == .covered
                && model.markState(NodeRef(old)) == .covered,
            "marked \(model.marks.map(\.name).sorted())"
        )
        check(
            "so the folder is counted once, not once more for each",
            model.markedBytes == docs.totalAlloc + mRef.alloc,
            "\(model.markedBytes), expected \(docs.totalAlloc + mRef.alloc)"
        )
        model.toggleMarks([bRef])
        model.setMarked([cRef], true)
        check(
            "what a marked folder already covers takes no mark of its own",
            model.marks == [NodeRef(docs), mRef],
            "marked \(model.marks.map(\.name).sorted())"
        )
        model.toggleMarks([NodeRef(docs)])
        check(
            "taking the folder's mark off leaves its contents unmarked",
            model.marks == [mRef] && model.markState(aRef) == .none
                && model.markState(NodeRef(docs)) == .none,
            "marked \(model.marks.map(\.name).sorted())"
        )
        model.setMarked([NodeRef(docs), aRef, cRef], true)
        check(
            "a folder marked together with its own contents is marked once",
            model.marks == [NodeRef(docs), mRef],
            "marked \(model.marks.map(\.name).sorted())"
        )
        model.clearMarks()

        // Space and the menu work on what is selected and on show, like the
        // delete keys, and mark or unmark the lot together.
        model.showsTreemap = false
        model.setExpanded(docs, true)
        model.selection = [aRef, bRef]
        model.toggleMarks([aRef])
        let offeredToMark = !model.selectionIsMarked
        check(
            "marking a selection that is partly marked marks the rest",
            offeredToMark && model.markSelection() && model.marks == [aRef, bRef],
            "marked \(model.marks.map(\.name).sorted())"
        )
        let offeredToUnmark = model.selectionIsMarked
        check(
            "and doing it again takes them all off, as the menu then says",
            offeredToUnmark && model.markSelection() && model.marks.isEmpty
                && !model.selectionIsMarked,
            "marked \(model.marks.map(\.name).sorted())"
        )
        model.setExpanded(docs, false)
        check(
            "a selection that is not on show is not marked from the keyboard",
            !model.canMarkSelection && !model.markSelection()
                && model.marks.isEmpty,
            "marked \(model.marks.map(\.name).sorted())"
        )
        model.setExpanded(docs, true)
        model.isEditingFilter = true
        check(
            "nor is anything while the filter is being typed in",
            !model.markSelection() && model.marks.isEmpty,
            "marked \(model.marks.map(\.name).sorted())"
        )
        model.isEditingFilter = false

        // Acting on them.
        model.setMarked([aRef, cRef, mRef], true)
        model.showsMarks = true
        model.selection = [looseRef]
        model.confirmDeletingMarked()
        check(
            "deleting the marks for good asks first, about exactly them",
            model.permanentDeleteTargets == [aRef, cRef, mRef]
                && onDisk("docs/a.txt"),
            "pending \(model.permanentDeleteTargets.map(\.name).sorted())"
        )
        model.permanentDeleteTargets = []

        // One of the three is removed behind the marks' back, as a delete
        // from the context menu would.
        trash(model, [cRef])
        check(
            "a mark on something that has since gone is dropped",
            model.marks == [aRef, mRef] && model.showsMarks,
            "marked \(model.marks.map(\.name).sorted())"
        )

        model.trashMarked()
        // The batch took the marks as they stood. Taken off now, the list
        // would stop showing something that is still on its way out.
        model.setMarked([aRef], false)
        model.toggleMarks([bRef])
        model.clearMarks()
        check(
            "the marks stand still while a batch is running",
            model.isDeleting && model.marks == [aRef, mRef]
                && !model.canMarkSelection,
            "marked \(model.marks.map(\.name).sorted()), "
                + "deleting \(model.isDeleting)"
        )
        pumpUntilDeleteSettles(model)
        check(
            "moving the marks to the Trash removes them and nothing else",
            !onDisk("docs/a.txt") && !onDisk("media/m.bin")
                && onDisk("docs/b.txt") && onDisk("loose.dat")
                && model.actionError == nil,
            "error \(model.actionError ?? "none")"
        )
        check(
            "with nothing left marked, the list is put away",
            model.marks.isEmpty && !model.showsMarks,
            "marked \(model.marks.map(\.name)), open \(model.showsMarks)"
        )
        check(
            "the selection, which was none of them, is where it was",
            model.selection == [looseRef],
            "selection is \(model.selection.map(\.name))"
        )

        model.toggleMarks([bRef])
        model.startScan()
        check(
            "a rescan takes the marks with the tree they pointed into",
            model.marks.isEmpty,
            "marked \(model.marks.map(\.name))"
        )
        pumpUntilSettled(model)
    }

    /// A mark on something that could not be removed has to stay, or the
    /// list empties as though the job were done.
    @MainActor
    private static func testAMarkStaysOnWhatCouldNotBeRemoved() {
        let base = scratch("marks-locked")
        let locked = base.appendingPathComponent("locked.dat")
        defer {
            chflags(locked.path, 0)
            try? FileManager.default.removeItem(at: base)
        }
        do {
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
            try write(locked, bytes: 3_000)
            try write(base.appendingPathComponent("free.dat"), bytes: 2_000)
        } catch {
            check("the locked-mark fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        guard
            let lockedIndex = result.root.files.firstIndex(where: {
                $0.name == "locked.dat"
            }),
            let freeIndex = result.root.files.firstIndex(where: {
                $0.name == "free.dat"
            }),
            chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0
        else {
            check("the locked-mark fixture scanned", false, "missing entries")
            return
        }
        let lockedRef = NodeRef(dir: result.root, fileIndex: lockedIndex)
        let freeRef = NodeRef(dir: result.root, fileIndex: freeIndex)

        model.setMarked([lockedRef, freeRef], true)
        model.showsMarks = true
        deletePermanently(model, model.marks)

        check(
            "what was removed loses its mark and what was not keeps it",
            model.marks == [lockedRef] && model.showsMarks
                && FileManager.default.fileExists(atPath: locked.path)
                && model.actionError != nil,
            "marked \(model.marks.map(\.name)), error \(model.actionError ?? "none")"
        )
    }

    /// The map's side of the marks: which parts of it are hatched, and a
    /// ⌘-click that marks without disturbing what is selected.
    @MainActor
    private static func testTheTreemapShowsAndTakesMarks() {
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
        // big/x.dat fills most of the map; small/ holds y.dat, z.dat and a
        // folder of its own, nested/w.dat, and takes the rest.
        let root = DirNode(name: "/wizzzee-selftest-marked", parent: nil)
        let big = DirNode(name: "big", parent: root)
        big.files = [entry("x.dat", 8_000)]
        total(big, 8_000, files: 1, dirs: 0)
        let small = DirNode(name: "small", parent: root)
        small.files = [entry("y.dat", 1_200), entry("z.dat", 800)]
        let nested = DirNode(name: "nested", parent: small)
        nested.files = [entry("w.dat", 500)]
        total(nested, 500, files: 1, dirs: 0)
        small.subdirs = [nested]
        total(small, 2_500, files: 3, dirs: 1)
        root.subdirs = [big, small]
        total(root, 10_500, files: 4, dirs: 3)

        let queue = DispatchQueue(label: "com.wizzzee.selftest.marked")
        var picked: [NodeRef] = []
        var marked: [NodeRef] = []
        var zoomed: [DirNode] = []
        let view = TreemapNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.layoutQueue = queue
        view.liveRevision = { 0 }
        view.onSelect = { picked.append($0) }
        view.onMark = { marked.append($0) }
        view.onZoom = { zoomed.append($0) }
        // The layout lands on the main queue, behind whatever the checks
        // before this one left there, so one turn of the loop may not reach it.
        func settle() {
            queue.sync {}
            drainMainQueue()
        }
        func area(_ rects: [CGRect]) -> CGFloat {
            rects.reduce(0) { $0 + $1.width * $1.height }
        }
        view.apply(root: root, metric: .allocated, revision: 0)
        settle()
        let whole: CGFloat = 400 * 300
        let x = NodeRef(dir: big, fileIndex: 0)
        let y = NodeRef(dir: small, fileIndex: 0)

        check("with nothing marked, nothing is hatched", view.markedRects.isEmpty, "")
        view.marks = [y]
        let one = area(view.markedRects)
        check(
            "a marked file is hatched over its own tile",
            view.markedRects.count == 1 && one > 0 && one < whole * 0.2,
            "\(view.markedRects.count) rects covering \(one) of \(whole)"
        )
        view.marks = [NodeRef(small)]
        let folder = area(view.markedRects)
        check(
            "a marked folder is hatched over everything in it",
            view.markedRects.count == 1 && folder > one && folder < whole * 0.3,
            "\(view.markedRects.count) rects covering \(folder), one file was \(one)"
        )
        view.marks = [x, y]
        check(
            "marks in different folders are each hatched",
            view.markedRects.count == 2 && area(view.markedRects) > whole * 0.7,
            "\(view.markedRects.count) rects covering \(area(view.markedRects))"
        )

        // Zoomed to a folder inside a marked one, all that is on show is
        // going and none of it is the thing that was marked: the marked
        // folder is above the map's root, and has no tile or group here.
        view.marks = [NodeRef(small)]
        view.apply(root: nested, metric: .allocated, revision: 0)
        settle()
        check(
            "zoomed to somewhere inside a marked folder, the whole map is hatched",
            view.markedRects.count == 1
                && abs(area(view.markedRects) - whole) < 1,
            "\(view.markedRects.count) rects covering \(area(view.markedRects))"
        )

        view.marks = []
        view.apply(root: root, metric: .allocated, revision: 0)
        settle()
        func click(command: Bool, count: Int = 1) {
            guard
                let event = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: NSPoint(x: 100, y: 150),
                    modifierFlags: command ? [.command] : [],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    eventNumber: 0,
                    clickCount: count,
                    pressure: 1
                )
            else { return }
            view.mouseDown(with: event)
        }
        click(command: true)
        check(
            "a ⌘-click marks the tile under it and selects nothing",
            marked == [x] && picked.isEmpty,
            "marked \(marked.map(\.name)), picked \(picked.map(\.name))"
        )
        // The second of two quick ⌘-clicks arrives as a double-click. Taken
        // for one, it zoomed and left the mark the first had put on.
        click(command: true, count: 2)
        check(
            "a second ⌘-click straight after is another one, not a zoom",
            marked == [x, x] && zoomed.isEmpty && picked.isEmpty,
            "asked to mark \(marked.count) times, zoomed \(zoomed.count)"
        )
        click(command: false)
        check(
            "a plain click still selects, and marks nothing",
            marked == [x, x] && picked == [x],
            "marked \(marked.map(\.name)), picked \(picked.map(\.name))"
        )
        click(command: false, count: 2)
        check(
            "and a plain double-click still zooms",
            zoomed.count == 1 && marked == [x, x],
            "zoomed \(zoomed.count) times"
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
            drainMainQueue()
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

    // MARK: - File type in focus

    /// File Types said how much of a scan a type took and nothing about
    /// where. A row of it can be picked: the File View then lists that type's
    /// largest files and no others, and the focus lets go by itself when the
    /// row it was on has gone — with a delete, or with the scan.
    @MainActor
    private static func testAFileTypeCanBePickedOut() {
        let base = scratch("type-focus")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            for folder in ["a", "b", "c"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            try write(base.appendingPathComponent("a/one.dat"), bytes: 9_000)
            try write(base.appendingPathComponent("b/two.dat"), bytes: 4_000)
            try write(base.appendingPathComponent("b/three.log"), bytes: 2_000)
            try write(base.appendingPathComponent("c/four.txt"), bytes: 1_000)
            try write(base.appendingPathComponent("c/five.bin"), bytes: 6_000)
            try write(base.appendingPathComponent("c/README"), bytes: 3_000)
        } catch {
            check("the type-focus fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        pumpUntilFileRowsSettle(model, expecting: 6)

        let dat = result.typeIndex(for: "dat")
        let onlyDat = result.largestFiles(ofType: dat, limit: 10)
        check(
            "a walk held to one type lists that type's files, largest first",
            onlyDat.map(\.name) == ["one.dat", "two.dat"],
            "got \(onlyDat.map(\.name))"
        )
        check(
            "and a name filter narrows it further, not instead",
            result.largestFiles(matching: "two", ofType: dat, limit: 10)
                .map(\.name) == ["two.dat"]
                && result.largestFiles(matching: "three", ofType: dat, limit: 10)
                    .isEmpty,
            "‘three’ within .dat gave "
                + "\(result.largestFiles(matching: "three", ofType: dat, limit: 10).map(\.name))"
        )
        let bare = result.largestFiles(
            ofType: result.typeIndex(for: ""),
            limit: 10
        )
        check(
            "files with no extension are a type of their own",
            bare.map(\.name) == ["README"],
            "got \(bare.map(\.name))"
        )
        check(
            "a type the scan never saw has no index to ask for",
            result.typeIndex(for: "nope") == nil,
            "got \(String(describing: result.typeIndex(for: "nope")))"
        )

        model.focusType("dat")
        pumpUntilFileRowsSettle(model, expecting: 2)
        check(
            "picking a type puts it in focus, under the number its files carry",
            model.focusedType == "dat" && model.focusedTypeIndex == dat
                && model.focusedTypeStat?.count == 2,
            "focus \(model.focusedType ?? "nil"), index "
                + "\(String(describing: model.focusedTypeIndex)) against "
                + "\(String(describing: dat))"
        )
        check(
            "and the File View lists that type and nothing else",
            model.fileRows.map(\.name) == ["one.dat", "two.dat"],
            "rows \(model.fileRows.map(\.name))"
        )

        model.focusType("nope")
        check(
            "a type with no files can't take the focus, and leaves none",
            model.focusedType == nil,
            "focus \(model.focusedType ?? "nil")"
        )
        pumpUntilFileRowsSettle(model, expecting: 6)
        check(
            "with no type in focus the File View is every file again",
            model.fileRows.count == 6,
            "\(model.fileRows.count) rows"
        )

        // One of the two .dat files goes: the type is still there to look at.
        model.focusType("dat")
        pumpUntilFileRowsSettle(model, expecting: 2)
        guard let a = result.root.subdir(named: "a"),
            let b = result.root.subdir(named: "b"),
            let two = b.files.firstIndex(where: { $0.name == "two.dat" })
        else {
            check("the type-focus fixture scanned", false, "missing folders")
            return
        }
        deletePermanently(model, [NodeRef(a)])
        pumpUntilFileRowsSettle(model, expecting: 1)
        check(
            "a delete that leaves the type some files leaves it in focus",
            model.focusedType == "dat"
                && model.fileRows.map(\.name) == ["two.dat"],
            "focus \(model.focusedType ?? "nil"), rows "
                + "\(model.fileRows.map(\.name))"
        )

        // The last of them goes, and its row in File Types with it.
        deletePermanently(model, [NodeRef(dir: b, fileIndex: two)])
        pumpUntilFileRowsSettle(model, expecting: 4)
        check(
            "deleting the last file of the type in focus lets the focus go",
            model.focusedType == nil && model.focusedTypeIndex == nil,
            "focus \(model.focusedType ?? "nil")"
        )
        check(
            "and the File View goes back to everything that is left",
            model.fileRows.count == 4,
            "rows \(model.fileRows.map(\.name))"
        )

        model.focusType("bin")
        check(
            "another type can be picked afterwards",
            model.focusedType == "bin",
            "focus \(model.focusedType ?? "nil")"
        )
        _ = loadSynchronously(into: model)
        check(
            "a rescan of the same folder comes back with the type still in focus",
            model.focusedType == "bin",
            "focus \(model.focusedType ?? "nil")"
        )
        model.customFolder = base.appendingPathComponent("b").path
        _ = loadSynchronously(into: model)
        check(
            "a scan of somewhere else starts with none",
            model.focusedType == nil,
            "focus \(model.focusedType ?? "nil")"
        )
    }

    /// With a type in focus the map draws every other tile set back, in the
    /// bitmap itself. Read back out of the image: that a tile of the type is
    /// drawn exactly as it was, and one outside it — another type, or a
    /// folder drawn as one tile — a good deal darker.
    private static func testTheMapSetsBackWhatIsOutOfFocus() {
        func entry(_ name: String, _ bytes: UInt64, type: Int32) -> FileEntry {
            FileEntry(
                name: name,
                size: bytes,
                alloc: bytes,
                mtime: 0,
                extIndex: type,
                isSymlink: false,
                isDuplicateLink: false
            )
        }
        // Two files of different types side by side, and a folder too deep
        // to be broken down, which the layout draws as a single tile.
        let root = DirNode(name: "/wizzzee-selftest-focus", parent: nil)
        root.files = [entry("x.dat", 5_000, type: 0), entry("y.log", 3_000, type: 1)]
        let folder = DirNode(name: "folder", parent: root)
        folder.files = [entry("z.dat", 2_000, type: 0)]
        folder.totalSize = 2_000
        folder.totalAlloc = 2_000
        folder.totalFiles = 1
        root.subdirs = [folder]
        root.totalSize = 10_000
        root.totalAlloc = 10_000
        root.totalFiles = 3
        root.totalDirs = 1

        let layout = TreemapLayout.build(
            root: root,
            ancestors: [],
            size: CGSize(width: 300, height: 200),
            metric: .allocated,
            maxDepth: 0
        )
        guard let x = layout.cells.first(where: { $0.ref.name == "x.dat" }),
            let y = layout.cells.first(where: { $0.ref.name == "y.log" }),
            let z = layout.cells.first(where: { $0.ref.isDirectory })
        else {
            check(
                "the focus fixture lays out as two files and a folder tile",
                false,
                "cells \(layout.cells.map(\.ref.name))"
            )
            return
        }

        /// How bright the middle of `cell` is in `image`, out of 765.
        func light(_ cell: TreemapCell, in image: CGImage?) -> Int {
            guard let image, let data = image.dataProvider?.data,
                let bytes = CFDataGetBytePtr(data)
            else { return -1 }
            let px = min(image.width - 1, Int(cell.rect.midX))
            let py = min(image.height - 1, Int(cell.rect.midY))
            let at = py * image.bytesPerRow + px * 4
            // Little-endian 0xXXRRGGBB: blue, green, red, unused.
            return Int(bytes[at]) + Int(bytes[at + 1]) + Int(bytes[at + 2])
        }

        let plain = TreemapRenderer.render(model: layout, scale: 1)
        let focused = TreemapRenderer.render(model: layout, scale: 1, focus: 0)
        check(
            "the tile of the type in focus is drawn as it was",
            light(x, in: plain) > 0 && light(x, in: focused) == light(x, in: plain),
            "\(light(x, in: focused)) in focus against \(light(x, in: plain))"
        )
        check(
            "a tile of another type is set back",
            light(y, in: focused) * 2 < light(y, in: plain),
            "\(light(y, in: focused)) in focus against \(light(y, in: plain))"
        )
        check(
            "and so is a folder drawn as one tile, whatever is inside it",
            light(z, in: focused) * 2 < light(z, in: plain),
            "\(light(z, in: focused)) in focus against \(light(z, in: plain))"
        )
        check(
            "set back is not blacked out: the map underneath can still be read",
            light(y, in: focused) > 30,
            "\(light(y, in: focused)) of 765"
        )
    }

    /// The legend lists the largest few types, and a real disk has thousands.
    /// The rest are kept ranked too, so the list can be asked for all of them.
    private static func testTheLegendCanListEveryType() {
        let count = ScanResult.legendLength + 5
        // Built in a loop, a line at a time: as one expression inside a
        // closure it is more than the release toolchain will type-check.
        var stats: [ExtensionStat] = []
        for i in 0..<count {
            let size = UInt64(count - i) * 1_000
            let alloc = UInt64(i + 1) * 1_000
            let files = i == 3 ? 0 : 1
            stats.append(
                ExtensionStat(ext: "t\(i)", size: size, alloc: alloc, count: files)
            )
        }
        let result = ScanResult(
            root: DirNode(name: "/wizzzee-selftest-legend", parent: nil),
            rootPath: "/wizzzee-selftest-legend",
            extensionStats: stats,
            elapsed: 0,
            deniedCount: 0,
            hardLinkSavings: 0,
            hardLinkAllocSavings: 0,
            volumeTotal: 0,
            volumeFree: 0,
            volumeUsed: 0,
            isSharedContainer: false
        )
        check(
            "the legend's short list stops where it always has",
            result.topBySize.count == ScanResult.legendLength
                && result.topByAllocated.count == ScanResult.legendLength,
            "\(result.topBySize.count) by size, \(result.topByAllocated.count) on disk"
        )
        check(
            "the full list has every type that still has a file",
            result.allBySize.count == count - 1
                && result.allByAllocated.count == count - 1
                && result.typeCount == count - 1
                && !result.allBySize.contains { $0.ext == "t3" },
            "\(result.allBySize.count) by size, \(result.typeCount) counted"
        )
        check(
            "each in its own order, and the short list is the top of it",
            result.allBySize.first?.ext == "t0"
                && result.allByAllocated.first?.ext == "t\(count - 1)"
                && Array(result.allBySize.prefix(ScanResult.legendLength))
                    == result.topBySize,
            "first by size \(result.allBySize.first?.ext ?? "nil"), on disk "
                + "\(result.allByAllocated.first?.ext ?? "nil")"
        )
    }

    /// Every `NSTableView` under `view`, in the order they are found.
    @MainActor
    private static func tables(under view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        var pending: [NSView] = [view]
        while let next = pending.popLast() {
            if let table = next as? NSTableView { found.append(table) }
            pending.append(contentsOf: next.subviews)
        }
        return found
    }

    /// Runs the main run loop until it has nothing left to do.
    ///
    /// For a check that has put one thing on the main queue and needs it to
    /// have run. One turn of the loop does one thing, and it need not be
    /// that one: whatever the checks before left there is ahead of it, a
    /// window being taken down or a walk coming back. A turn that waits its
    /// whole time out with nothing to do is how the queue is known to be
    /// empty.
    @MainActor
    private static func drainMainQueue() {
        for _ in 0..<200 {
            let started = Date()
            RunLoop.main.run(mode: .default, before: started.addingTimeInterval(0.05))
            if Date().timeIntervalSince(started) >= 0.04 { return }
        }
    }

    /// Runs the main run loop until `condition` holds, and says whether it
    /// came to. For anything on screen: how long a table takes to lay out
    /// and scroll is the machine's business, and a fixed wait that is ample
    /// here is not on a loaded runner.
    @MainActor
    @discardableResult
    private static func pumpUntil(
        _ timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// Runs the main run loop for `seconds`.
    @MainActor
    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// A second name for a hard-linked file is counted under its own type
    /// and takes no space there. A type made of nothing else has a row in
    /// File Types, no tile on the map and no row in the File View: in focus
    /// it turned the one dark and the other empty, and stayed that way.
    @MainActor
    private static func testATypeOfNothingButSecondNamesCannotTakeTheFocus() {
        let base = scratch("focus-links")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            for folder in ["a", "b"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            // One file under two names of two types. Whichever the scan
            // reaches second is a duplicate, and its type has that and one
            // file of its own.
            try write(base.appendingPathComponent("a/film.aaa"), bytes: 9_000)
            try FileManager.default.linkItem(
                at: base.appendingPathComponent("a/film.aaa"),
                to: base.appendingPathComponent("b/film.bbb")
            )
            try write(base.appendingPathComponent("a/own.aaa"), bytes: 2_000)
            try write(base.appendingPathComponent("b/own.bbb"), bytes: 2_000)
        } catch {
            check("the focus-links fixture can be built", false, "\(error)")
            return
        }
        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model),
            let a = result.root.subdir(named: "a"),
            let b = result.root.subdir(named: "b"),
            let (_, duplicate) = roles(a, b)
        else {
            check("the focus-links fixture scanned as a linked pair", false, "")
            return
        }
        // The type the duplicate name is counted under, and its own file.
        let ext = duplicate === a ? "aaa" : "bbb"
        guard let own = duplicate.files.firstIndex(where: { $0.name == "own." + ext })
        else {
            check("the duplicate's folder has a file of its own", false, "")
            return
        }
        pumpUntilFileRowsSettle(model, expecting: 3)

        model.focusType(ext)
        pumpUntilFileRowsSettle(model, expecting: 1)
        check(
            "a type with a file of its own can be picked, second name or no",
            model.focusedType == ext
                && model.fileRows.map(\.name) == ["own." + ext],
            "focus \(model.focusedType ?? "nil"), rows \(model.fileRows.map(\.name))"
        )

        deletePermanently(model, [NodeRef(dir: duplicate, fileIndex: own)])
        pumpUntilFileRowsSettle(model, expecting: 2)
        let left = result.stat(for: ext)
        check(
            "its own file gone, the type still has a name to count and no space",
            left?.count == 1 && left?.size == 0 && left?.alloc == 0,
            "\(left?.count ?? -1) files, \(left?.size ?? 0) bytes"
        )
        check(
            "and the focus lets go, with nothing of the type left to show",
            model.focusedType == nil && model.fileRows.count == 2,
            "focus \(model.focusedType ?? "nil"), \(model.fileRows.count) rows"
        )
        model.focusType(ext)
        check(
            "nor can it be picked again",
            model.focusedType == nil,
            "focus \(model.focusedType ?? "nil")"
        )
    }

    /// The type in focus can be outside the legend's short list: picked from
    /// the full one, or ranked there by the other measure. The short list
    /// then had nothing selected while the map stayed dim, and the choice to
    /// list every type was forgotten at each change of tab.
    @MainActor
    private static func testAFocusOutsideTheShortListStaysInTheLegend() {
        let base = scratch("focus-tabs")
        defer { try? FileManager.default.removeItem(at: base) }
        let count = ScanResult.legendLength + 6
        do {
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
            // One file of each type, each a block bigger than the last, so
            // the types rank in a known order by either measure.
            for i in 0..<count {
                try write(
                    base.appendingPathComponent("f\(i).t\(i)"),
                    bytes: 4_096 * (count - i)
                )
            }
        } catch {
            check("the focus-tabs fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        model.dismissedAccessPrompt = true
        let hosting = NSHostingView(rootView: ContentView(model: model))
        let frame = NSRect(x: 0, y: 0, width: 1300, height: 760)
        hosting.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFront(nil)
        defer { window.close() }

        guard loadSynchronously(into: model) != nil else { return }
        pump(0.5)
        let short = ScanResult.legendLength
        /// How many rows the legend's table has: the one that is not the tree.
        func legendRows() -> Int {
            tables(under: hosting).map(\.numberOfRows)
                .first { $0 != model.treeRows.count } ?? -1
        }
        check(
            "the legend starts at the short list",
            model.legendTypes.count == short && legendRows() == short,
            "\(model.legendTypes.count) types, \(legendRows()) rows"
        )

        // The smallest type: last of all, and not in the short list.
        let last = "t\(count - 1)"
        model.focusType(last)
        pump(0.5)
        check(
            "a type in focus from outside the short list is added to it",
            model.legendTypes.count == short + 1
                && model.legendTypes.last?.ext == last && legendRows() == short + 1,
            "\(model.legendTypes.count) types ending "
                + "\(model.legendTypes.last?.ext ?? "nil"), \(legendRows()) rows"
        )
        model.focusType("t0")
        check(
            "one already in it is not listed twice",
            model.legendTypes.count == short,
            "\(model.legendTypes.count) types"
        )

        model.focusType(last)
        model.tab = .files
        pump(0.4)
        model.tab = .tree
        pump(0.6)
        check(
            "and is still in focus, and in the list, after a change of tab",
            model.focusedType == last && legendRows() == short + 1,
            "focus \(model.focusedType ?? "nil"), \(legendRows()) rows"
        )

        model.listsEveryType = true
        pump(0.4)
        check(
            "asked for every type, the legend lists every type",
            model.legendTypes.count == count && legendRows() == count,
            "\(model.legendTypes.count) types, \(legendRows()) rows"
        )
        model.tab = .files
        pump(0.4)
        model.tab = .tree
        pump(0.6)
        check(
            "and goes on doing so after a change of tab",
            model.listsEveryType && legendRows() == count
                && model.focusedType == last,
            "lists every type \(model.listsEveryType), \(legendRows()) rows"
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

    // MARK: - Getting about

    /// a/b/x.dat, a/y.dat, a/empty/ and c/z.dat, scanned into `model`.
    @MainActor
    private static func loadWalkabout(
        _ name: String,
        into model: AppModel
    ) -> (base: URL, result: ScanResult)? {
        let base = scratch(name)
        do {
            for folder in ["a/b", "a/empty", "c"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            try write(base.appendingPathComponent("a/b/x.dat"), bytes: 30_000)
            try write(base.appendingPathComponent("a/y.dat"), bytes: 10_000)
            try write(base.appendingPathComponent("c/z.dat"), bytes: 5_000)
        } catch {
            check("the \(name) fixture can be built", false, "\(error)")
            return nil
        }
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return nil }
        return (base, result)
    }

    /// → and ← on the tree, as an outline answers them: → opens a folder
    /// and then steps into it, ← shuts one and then steps out of it. The
    /// table is a flat list of rows, so neither did anything.
    @MainActor
    private static func testArrowKeysOpenAndShutFolders() {
        let model = AppModel()
        guard let (base, result) = loadWalkabout("arrows", into: model) else { return }
        defer { try? FileManager.default.removeItem(at: base) }
        guard let a = result.root.subdir(named: "a"),
            let b = a.subdir(named: "b"),
            let c = result.root.subdir(named: "c"),
            let empty = a.subdir(named: "empty"),
            let y = a.files.firstIndex(where: { $0.name == "y.dat" })
        else {
            check("the arrows fixture scanned", false, "missing folders")
            return
        }
        func rows() -> [String] { model.treeRows.map(\.ref.name) }
        func selected() -> [String] { model.selection.map(\.name).sorted() }

        model.selection = [NodeRef(a)]
        check(
            "→ on a shut folder opens it and stays on it",
            model.expandSelection() && model.isExpanded(a)
                && model.selection == [NodeRef(a)] && rows().contains("b"),
            "open \(model.isExpanded(a)), selected \(selected()), rows \(rows())"
        )
        let scrolls = model.revealCount
        check(
            "→ again steps down to the first thing in it, and brings it into view",
            model.expandSelection() && model.selection == [NodeRef(b)]
                && model.revealTarget == NodeRef(b)
                && model.revealCount == scrolls + 1,
            "selected \(selected()), asked to show "
                + "\(model.revealTarget?.name ?? "nothing")"
        )

        model.selection = [NodeRef(dir: a, fileIndex: y)]
        check(
            "→ on a file does nothing, so the key can go on to the table",
            !model.expandSelection()
                && model.selection == [NodeRef(dir: a, fileIndex: y)],
            "selected \(selected())"
        )
        check(
            "← on a file steps out to the folder it is in",
            model.collapseSelection() && model.selection == [NodeRef(a)]
                && model.revealTarget == NodeRef(a),
            "selected \(selected())"
        )
        check(
            "← on an open folder shuts it and stays on it",
            model.collapseSelection() && !model.isExpanded(a)
                && model.selection == [NodeRef(a)] && !rows().contains("b"),
            "open \(model.isExpanded(a)), selected \(selected())"
        )
        check(
            "← again steps out to the folder above",
            model.collapseSelection()
                && model.selection == [NodeRef(result.root)],
            "selected \(selected())"
        )
        check(
            "← on the open root shuts it, and after that has nowhere to go",
            model.collapseSelection() && !model.isExpanded(result.root)
                && !model.collapseSelection()
                && model.selection == [NodeRef(result.root)],
            "root open \(model.isExpanded(result.root)), selected \(selected())"
        )
        _ = model.expandSelection()

        model.selection = [NodeRef(a), NodeRef(c)]
        check(
            "→ opens every selected folder that is shut",
            model.expandSelection() && model.isExpanded(a) && model.isExpanded(c)
                && model.selection == [NodeRef(a), NodeRef(c)],
            "a \(model.isExpanded(a)), c \(model.isExpanded(c))"
        )
        check(
            "with several open folders selected, → has no one of them to step into",
            !model.expandSelection()
                && model.selection == [NodeRef(a), NodeRef(c)],
            "selected \(selected())"
        )
        check(
            "and ← shuts them all",
            model.collapseSelection() && !model.isExpanded(a)
                && !model.isExpanded(c),
            "a \(model.isExpanded(a)), c \(model.isExpanded(c))"
        )

        // b is inside a, which is shut: selected, and not on show.
        model.selection = [NodeRef(b)]
        check(
            "a selected row that a shut folder hides is left alone",
            !model.expandSelection() && !model.collapseSelection()
                && !model.isExpanded(b) && model.selection == [NodeRef(b)],
            "b open \(model.isExpanded(b)), selected \(selected())"
        )

        model.setExpanded(a, true)
        model.selection = [NodeRef(empty)]
        check(
            "→ on an empty folder has nothing to open",
            !model.expandSelection() && !model.isExpanded(empty),
            "open \(model.isExpanded(empty))"
        )

        // A tile clicked on the map is selected whether or not it has a
        // row, and only brought into view when it has.
        model.setExpanded(a, false)
        let before = model.revealCount
        model.select(fromMap: NodeRef(b))
        check(
            "a tile picked on the map opens no folders to show its row",
            model.selection == [NodeRef(b)] && !model.isExpanded(a)
                && model.revealCount == before,
            "a open \(model.isExpanded(a)), asked to scroll "
                + "\(model.revealCount - before) times"
        )
        model.select(fromMap: NodeRef(c))
        check(
            "one whose row is already there is brought into view",
            model.selection == [NodeRef(c)] && model.revealTarget == NodeRef(c)
                && model.revealCount == before + 1,
            "asked to show \(model.revealTarget?.name ?? "nothing")"
        )
    }

    /// The path above the map was one line of text. Each folder in it is now
    /// somewhere the map can be zoomed back out to.
    @MainActor
    private static func testThePathAboveTheMapZoomsOut() {
        let model = AppModel()
        guard let (base, result) = loadWalkabout("trail", into: model) else { return }
        defer { try? FileManager.default.removeItem(at: base) }
        guard let a = result.root.subdir(named: "a"), let b = a.subdir(named: "b")
        else {
            check("the trail fixture scanned", false, "missing folders")
            return
        }
        check(
            "at the root the path is the root alone",
            model.zoomTrail.count == 1 && model.zoomTrail.first === result.root,
            "\(model.zoomTrail.map(\.name))"
        )
        model.zoom(into: b)
        let trail = model.zoomTrail
        check(
            "zoomed in, it runs from the scan's root down to where the map is",
            trail.count == 3 && trail[0] === result.root && trail[1] === a
                && trail[2] === b,
            "\(trail.map(\.name))"
        )
        model.zoom(into: trail[1])
        check(
            "and a folder part-way along it is somewhere to zoom back out to",
            model.treemapRoot === a && model.zoomTrail.count == 2,
            "map at \(model.treemapRoot?.name ?? "nil")"
        )
        model.zoom(into: trail[0])
        check(
            "as is the root",
            model.treemapRoot === result.root && !model.canZoomOut,
            "map at \(model.treemapRoot?.name ?? "nil")"
        )

        // A scan's root is named by the whole path it was scanned at. In the
        // path above the map that was wider than the strip, and pushed out
        // every way of showing it that had buttons in.
        check(
            "the root is shown by its own name, not the path that leads to it",
            ZoomTrail.label(for: result.root) == base.lastPathComponent
                && result.root.name.count > base.lastPathComponent.count,
            "“\(ZoomTrail.label(for: result.root))” for \(result.root.name)"
        )
        check(
            "a folder below it by the name it has",
            ZoomTrail.label(for: a) == "a",
            ZoomTrail.label(for: a)
        )
        check(
            "and a whole volume by the one name it has",
            ZoomTrail.label(for: DirNode(name: "/", parent: nil)) == "/",
            ZoomTrail.label(for: DirNode(name: "/", parent: nil))
        )
    }

    /// The tabs only ever answered a click.
    @MainActor
    private static func testTabsAnswerTheirKeys() {
        let model = AppModel()
        guard let (base, _) = loadWalkabout("tabs", into: model) else { return }
        defer { try? FileManager.default.removeItem(at: base) }
        check(
            "each tab has a key of its own, in the order they are shown",
            MainTab.allCases.map(\.key) == ["1", "2", "3"],
            "\(MainTab.allCases.map(\.key))"
        )
        // The scan's own walk, so the list is known to be settled.
        pumpUntilFileRowsSettle(model, expecting: 3)
        model.show(.files)
        check(
            "showing a tab brings it to the front",
            model.tab == .files && model.fileRows.count == 3,
            "tab \(model.tab), \(model.fileRows.count) rows"
        )
        model.show(.about)
        model.show(.tree)
        check(
            "and back again",
            model.tab == .tree,
            "tab \(model.tab)"
        )

        // The folder picker has a key, and a key reaches the menu from under
        // a panel or a question. It is off wherever a scan could not start,
        // and wherever something is waiting for an answer.
        check(
            "the folder picker can be put up over a finished scan",
            model.canChooseFolder,
            ""
        )
        if let root = model.result?.root {
            model.permanentDeleteTargets = [NodeRef(root)]
            check(
                "but not over a delete that is waiting to be confirmed",
                !model.canChooseFolder,
                ""
            )
            model.permanentDeleteTargets = []
        }
        model.actionError = "something to read first"
        check("nor over an alert", !model.canChooseFolder, "")
        model.actionError = nil
        model.startScan()
        check("nor during a scan", !model.canChooseFolder, "")
        pumpUntilSettled(model)
        check("and can again once it is over", model.canChooseFolder, "")
    }

    /// A scan throws the tree away, and took with it which folders were
    /// open, where the map was zoomed to, what was selected and every mark.
    /// A scan of the folder already on show now puts back what is still
    /// there, and says how many marks it could not.
    @MainActor
    private static func testARescanKeepsYourPlace() {
        let model = AppModel()
        guard let (base, first) = loadWalkabout("rescan-place", into: model) else { return }
        defer { try? FileManager.default.removeItem(at: base) }
        guard let a = first.root.subdir(named: "a"),
            let b = a.subdir(named: "b"),
            let c = first.root.subdir(named: "c"),
            let y = a.files.firstIndex(where: { $0.name == "y.dat" })
        else {
            check("the rescan-place fixture scanned", false, "missing folders")
            return
        }
        model.setExpanded(a, true)
        model.setExpanded(b, true)
        model.zoom(into: b)
        let yRef = NodeRef(dir: a, fileIndex: y)
        model.selection = [yRef]
        model.setMarked([NodeRef(c), yRef], true)
        model.showsMarks = true
        model.focusType("dat")

        // Behind the app's back: c goes, and a gains a file.
        do {
            try FileManager.default.removeItem(at: base.appendingPathComponent("c"))
            try write(base.appendingPathComponent("a/new.dat"), bytes: 2_000)
        } catch {
            check("the fixture can be changed between scans", false, "\(error)")
            return
        }

        model.startScan()
        check(
            "while the scan runs there is nothing marked or selected to act on",
            model.marks.isEmpty && model.selection.isEmpty && model.result == nil,
            "marked \(model.marks.count), selected \(model.selection.count)"
        )
        pumpUntilSettled(model)
        guard let second = model.result, second !== first,
            let a2 = second.root.subdir(named: "a"),
            let b2 = a2.subdir(named: "b"),
            let y2 = a2.files.firstIndex(where: { $0.name == "y.dat" })
        else {
            check("the rescan landed with the folders that are still there", false, "")
            return
        }
        let y2Ref = NodeRef(dir: a2, fileIndex: y2)
        check(
            "the scan is a new one, and sees what changed",
            second.root.subdir(named: "c") == nil
                && a2.files.contains { $0.name == "new.dat" },
            "\(second.root.subdirs.map(\.name))"
        )
        check(
            "the folders that were open are open",
            model.isExpanded(second.root) && model.isExpanded(a2)
                && model.isExpanded(b2)
                && model.treeRows.contains { $0.ref.name == "x.dat" },
            "rows \(model.treeRows.map(\.ref.name))"
        )
        check(
            "the map is zoomed to where it was",
            model.treemapRoot === b2,
            "map at \(model.treemapRoot?.path ?? "nil")"
        )
        check(
            "what was selected is selected, in the new tree",
            model.selection == [y2Ref] && !y2Ref.isStale,
            "selected \(model.selection.map(\.path))"
        )
        check(
            "the mark on what is still there is back, and the list is still open",
            model.marks == [y2Ref] && model.showsMarks,
            "marked \(model.marks.map(\.path)), open \(model.showsMarks)"
        )
        check(
            "the one on what has gone is counted as lost, not dropped in silence",
            model.marksLostToRescan == 1,
            "\(model.marksLostToRescan) lost"
        )
        check(
            "and the type in focus is still in focus",
            model.focusedType == "dat",
            "focus \(model.focusedType ?? "nil")"
        )
        check(
            "nothing from the scan before is left in any of it",
            !model.isExpanded(a) && !model.marks.contains(yRef)
                && !model.selection.contains(yRef),
            ""
        )

        _ = loadSynchronously(into: model)
        check(
            "a rescan that loses nothing says nothing",
            model.marksLostToRescan == 0 && model.marks.count == 1,
            "\(model.marksLostToRescan) lost, \(model.marks.count) marked"
        )

        // An open folder is deleted, and the root is shut over the open
        // folders beneath it. What is put back is what was open: not the
        // folder that has gone, and not the root for being the root.
        guard let again = model.result, let a3 = again.root.subdir(named: "a"),
            let b3 = a3.subdir(named: "b")
        else { return }
        check("b is open before it goes", model.isExpanded(b3) && model.isExpanded(a3), "")
        model.zoom(into: again.root)
        deletePermanently(model, [NodeRef(b3)])
        model.setExpanded(again.root, false)
        check(
            "with the root shut only its own row is on show",
            model.treeRows.count == 1 && model.isExpanded(a3),
            "\(model.treeRows.count) rows"
        )
        guard let shut = loadSynchronously(into: model),
            let a4 = shut.root.subdir(named: "a")
        else { return }
        check(
            "a root that was shut comes back shut, with what was open under it still open",
            !model.isExpanded(shut.root) && model.isExpanded(a4)
                && model.treeRows.count == 1,
            "root open \(model.isExpanded(shut.root)), a open \(model.isExpanded(a4))"
        )
        check(
            "and a folder deleted while it was open is simply not there to open",
            a4.subdir(named: "b") == nil,
            "\(a4.subdirs.map(\.name))"
        )
        model.setExpanded(shut.root, true)

        // Somewhere else is somewhere new: nothing is carried over to it.
        model.customFolder = base.appendingPathComponent("a").path
        guard let third = loadSynchronously(into: model) else { return }
        check(
            "a scan of a different folder starts afresh",
            model.marks.isEmpty && model.selection == [NodeRef(third.root)]
                && model.treemapRoot === third.root && model.marksLostToRescan == 0
                && third.root.subdir(named: "empty").map(model.isExpanded) == false
                && model.isExpanded(third.root),
            "marked \(model.marks.count), map at \(model.treemapRoot?.name ?? "nil")"
        )

        // A scan that is stopped has no place to put back, and the next one
        // has nothing to take a place from.
        model.setMarked([NodeRef(dir: third.root, fileIndex: 0)], true)
        model.startScan()
        model.cancelScan()
        pumpUntilSettled(model)
        _ = loadSynchronously(into: model)
        check(
            "a scan that was stopped does not hand its place on to the next",
            model.marks.isEmpty && model.marksLostToRescan == 0,
            "marked \(model.marks.count), \(model.marksLostToRescan) lost"
        )
    }

    // MARK: - Undoing a move to the Trash

    /// Every folder's totals by where it is, for holding one tree to another.
    private static func ledger(_ root: DirNode) -> [String: [UInt64]] {
        var table: [String: [UInt64]] = [:]
        var stack: [(dir: DirNode, path: String)] = [(root, "")]
        while let (dir, path) = stack.popLast() {
            table[path] = [
                dir.totalSize, dir.totalAlloc, UInt64(dir.totalFiles), UInt64(dir.totalDirs),
            ]
            for sub in dir.subdirs { stack.append((sub, path + "/" + sub.name)) }
        }
        return table
    }

    /// The first folder whose totals are not the sum of what is in it, or nil
    /// when every one of them adds up.
    private static func firstThatDoesNotAddUp(_ root: DirNode) -> String? {
        var stack: [DirNode] = [root]
        while let dir = stack.popLast() {
            var size: UInt64 = 0
            var alloc: UInt64 = 0
            var files = 0
            var dirs = 0
            for file in dir.files where !file.isRemoved {
                files += 1
                if !file.isDuplicateLink {
                    size += file.size
                    alloc += file.alloc
                }
            }
            for sub in dir.subdirs {
                size += sub.totalSize
                alloc += sub.totalAlloc
                files += sub.totalFiles
                dirs += sub.totalDirs + 1
            }
            if size != dir.totalSize || alloc != dir.totalAlloc
                || files != dir.totalFiles || dirs != dir.totalDirs
            {
                return "\(dir.name): holds \(size)/\(alloc) in \(files) files and "
                    + "\(dirs) folders, says \(dir.totalSize)/\(dir.totalAlloc) in "
                    + "\(dir.totalFiles) and \(dir.totalDirs)"
            }
            stack.append(contentsOf: dir.subdirs)
        }
        return nil
    }

    /// Whether `model`'s tree is what a fresh scan of `base` finds: the same
    /// totals at the root, the same count of every type and the same bytes
    /// over all of them, the same saving from hard links — and every folder
    /// the sum of its parts. Which name of a hard-linked file carries its
    /// bytes is the scan's to choose, so nothing here hangs on that.
    @MainActor
    private static func agreesWithAFreshScan(_ model: AppModel, _ base: URL) -> String? {
        guard let result = model.result else { return "no scan" }
        let fresh = scan(base)
        func totals(_ root: DirNode) -> [UInt64] {
            [root.totalSize, root.totalAlloc, UInt64(root.totalFiles), UInt64(root.totalDirs)]
        }
        if totals(result.root) != totals(fresh.root) {
            return "root \(totals(result.root)), a fresh scan \(totals(fresh.root))"
        }
        func types(_ scan: ScanResult) -> [String: Int] {
            var table: [String: Int] = [:]
            for stat in scan.extensionStats where stat.count > 0 {
                table[stat.ext] = stat.count
            }
            return table
        }
        if types(result) != types(fresh) {
            return "types \(types(result)), a fresh scan \(types(fresh))"
        }
        func bytes(_ scan: ScanResult) -> [UInt64] {
            [
                scan.extensionStats.reduce(0) { $0 + $1.size },
                scan.extensionStats.reduce(0) { $0 + $1.alloc },
            ]
        }
        if bytes(result) != bytes(fresh) {
            return "type bytes \(bytes(result)), a fresh scan \(bytes(fresh))"
        }
        let saved = [result.hardLinkSavings(using: .logical), result.hardLinkSavings(using: .allocated)]
        let freshSaved = [fresh.hardLinkSavings(using: .logical), fresh.hardLinkSavings(using: .allocated)]
        if saved != freshSaved {
            return "hard links save \(saved), a fresh scan \(freshSaved)"
        }
        return firstThatDoesNotAddUp(result.root)
    }

    /// ⌘⌫ asks nothing, on the understanding that the Trash is not the end.
    /// From here it was: nothing could bring an item back. A move to the
    /// Trash can now be undone, on disk and in the tree, and what is still in
    /// the Trash is said, since it has left the totals and not the disk.
    @MainActor
    private static func testAMoveToTheTrashCanBeUndone() {
        let model = AppModel()
        guard let (base, result) = loadWalkabout("undo", into: model) else { return }
        defer { try? FileManager.default.removeItem(at: base) }
        guard let a = result.root.subdir(named: "a"),
            let b = a.subdir(named: "b"),
            let c = result.root.subdir(named: "c"),
            let y = a.files.firstIndex(where: { $0.name == "y.dat" }),
            let z = c.files.firstIndex(where: { $0.name == "z.dat" })
        else {
            check("the undo fixture scanned", false, "missing folders")
            return
        }
        func onDisk(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path)
        }
        let before = ledger(result.root)
        let yRef = NodeRef(dir: a, fileIndex: y)
        let zRef = NodeRef(dir: c, fileIndex: z)
        let yOnDisk = yRef.alloc
        model.setExpanded(a, true)

        check("with nothing moved to the Trash there is nothing to undo",
            !model.canUndoTrash && model.bytesInTrash == 0, "")
        model.undoTrash()

        // A file.
        trash(model, [yRef])
        check(
            "a move to the Trash can be undone, and the Trash is said to hold it",
            model.canUndoTrash && model.bytesInTrash == yOnDisk && !onDisk("a/y.dat")
                && yRef.isStale,
            "can undo \(model.canUndoTrash), \(model.bytesInTrash) bytes in the Trash"
        )
        model.undoTrash()
        check(
            "undoing it puts the file back where it was on disk",
            onDisk("a/y.dat"),
            "a/y.dat is not there"
        )
        check(
            "and back in the tree, in the slot it left, with every total as it was",
            !yRef.isStale && yRef.name == "y.dat" && ledger(result.root) == before
                && agreesWithAFreshScan(model, base) == nil,
            agreesWithAFreshScan(model, base) ?? "the ledger differs from before"
        )
        check(
            "it is what is selected, so it can be seen to be back",
            model.selection == [yRef] && model.treeRows.contains { $0.ref == yRef },
            "selected \(model.selection.map(\.name))"
        )
        check(
            "once undone there is nothing left to undo, and nothing in the Trash",
            !model.canUndoTrash && model.bytesInTrash == 0,
            "can undo \(model.canUndoTrash), \(model.bytesInTrash) bytes in the Trash"
        )
        model.undoTrash()
        check("undoing again does nothing", onDisk("a/y.dat") && ledger(result.root) == before, "")

        // A folder, removed from the list of marks.
        model.setMarked([NodeRef(a)], true)
        model.trashMarked()
        pumpUntilDeleteSettles(model)
        check(
            "a marked folder goes to the Trash, and its mark with it",
            !onDisk("a") && model.marks.isEmpty && NodeRef(a).isStale && NodeRef(b).isStale,
            "marked \(model.marks.map(\.name))"
        )
        model.undoTrash()
        check(
            "undoing brings the folder back with everything in it",
            onDisk("a/b/x.dat") && onDisk("a/y.dat") && onDisk("a/empty"),
            "a is not all there"
        )
        check(
            "the tree has it where it was, and what was inside is live again",
            a.parent === result.root && !NodeRef(a).isStale && !NodeRef(b).isStale
                && !yRef.isStale && ledger(result.root) == before
                && agreesWithAFreshScan(model, base) == nil,
            agreesWithAFreshScan(model, base) ?? "the ledger differs from before"
        )
        check(
            "and it comes back marked, as it left",
            model.marks == [NodeRef(a)] && model.selection == [NodeRef(a)],
            "marked \(model.marks.map(\.name)), selected \(model.selection.map(\.name))"
        )
        model.clearMarks()

        // Two things from different folders in one move.
        trash(model, [yRef, NodeRef(c)])
        check("a file and a folder go together", !onDisk("a/y.dat") && !onDisk("c"), "")
        model.undoTrash()
        check(
            "and come back together",
            onDisk("a/y.dat") && onDisk("c/z.dat") && ledger(result.root) == before
                && agreesWithAFreshScan(model, base) == nil
                && model.selection == [yRef, NodeRef(c)],
            agreesWithAFreshScan(model, base) ?? "selected \(model.selection.map(\.name))"
        )

        // Only the last move, and only until something else is removed: the
        // tree it would be put back into is not the one it left.
        trash(model, [yRef])
        deletePermanently(model, [zRef])
        check(
            "removing something else puts the move before it beyond undoing",
            !model.canUndoTrash,
            "can undo \(model.canUndoTrash)"
        )
        model.undoTrash()
        check(
            "so it stays in the Trash, and the Trash is still said to hold it",
            !onDisk("a/y.dat") && model.bytesInTrash == yOnDisk,
            "\(model.bytesInTrash) bytes in the Trash"
        )

        // The Trash is emptied from Finder, not from here, and with nothing
        // to tell the app that it has been: the line is kept up to date by
        // looking, for as long as it has anything to say.
        for url in model.trashedLocations { try? FileManager.default.removeItem(at: url) }
        let noticed = Date().addingTimeInterval(10)
        while model.bytesInTrash != 0 && Date() < noticed {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(
            "what has been emptied out of the Trash stops being said to be in it",
            model.bytesInTrash == 0 && model.trashedLocations.isEmpty,
            "\(model.bytesInTrash) bytes in the Trash"
        )

        trash(model, [NodeRef(b)])
        check("a later move is the one that can be undone", model.canUndoTrash, "")
        model.startScan()
        check(
            "a rescan puts it beyond undoing too",
            !model.canUndoTrash,
            "can undo \(model.canUndoTrash)"
        )
        pumpUntilSettled(model)
        model.undoTrash()
        check("and it stays where it is", !onDisk("a/b"), "a/b came back")
    }

    /// Each item goes back on its own. One whose place has been taken stays
    /// in the Trash, and is named; nothing is ever put back over something.
    @MainActor
    private static func testWhatCannotBePutBackStaysInTheTrash() {
        let model = AppModel()
        guard let (base, result) = loadWalkabout("undo-refused", into: model) else { return }
        defer { try? FileManager.default.removeItem(at: base) }
        guard let a = result.root.subdir(named: "a"),
            let c = result.root.subdir(named: "c"),
            let y = a.files.firstIndex(where: { $0.name == "y.dat" }),
            let z = c.files.firstIndex(where: { $0.name == "z.dat" })
        else {
            check("the undo-refused fixture scanned", false, "missing folders")
            return
        }
        let yRef = NodeRef(dir: a, fileIndex: y)
        let zRef = NodeRef(dir: c, fileIndex: z)
        let yPath = base.appendingPathComponent("a/y.dat")
        let yOnDisk = yRef.alloc
        let before = ledger(result.root)

        trash(model, [yRef, zRef])
        // Something else is put where y.dat was, behind the app's back.
        try? Data("in its place".utf8).write(to: yPath)
        model.undoTrash()
        check(
            "what can go back goes back",
            FileManager.default.fileExists(atPath: base.appendingPathComponent("c/z.dat").path)
                && !zRef.isStale,
            "c/z.dat is not back"
        )
        check(
            "what can't is named, and why",
            model.actionError == "Couldn’t put back “y.dat”"
                && model.actionErrorDetail?.contains("Something else is at") == true,
            "\(model.actionError ?? "no error"): \(model.actionErrorDetail ?? "")"
        )
        check(
            "nothing is put back over what has taken its place",
            (try? Data(contentsOf: yPath)) == Data("in its place".utf8) && yRef.isStale,
            "the file at a/y.dat was replaced"
        )
        check(
            "it is still counted as in the Trash, and the one that went back is not",
            model.bytesInTrash == yOnDisk && yOnDisk > 0,
            "\(model.bytesInTrash) bytes in the Trash, y.dat takes \(yOnDisk)"
        )
        check(
            "the tree is as it was before, less the one that stayed",
            ledger(result.root)[""]?[2] == (before[""]?[2] ?? 0) - 1
                && firstThatDoesNotAddUp(result.root) == nil,
            firstThatDoesNotAddUp(result.root) ?? "\(ledger(result.root)[""] ?? [])"
        )
        model.actionError = nil
        model.actionErrorDetail = nil

        // A move that removed nothing leaves the one before it as it was.
        // It used to be let go of as the next batch began, whatever came of
        // that batch.
        trash(model, [zRef])
        check("z.dat is in the Trash, to be brought back", model.canUndoTrash, "")
        guard let b = a.subdir(named: "b"),
            let x = b.files.firstIndex(where: { $0.name == "x.dat" })
        else { return }
        // Gone from the disk behind the app's back, so the move fails.
        try? FileManager.default.removeItem(at: base.appendingPathComponent("a/b/x.dat"))
        trash(model, [NodeRef(dir: b, fileIndex: x)])
        check(
            "a move that fails, and so removes nothing, leaves the last one undoable",
            model.actionError != nil && model.canUndoTrash,
            "error \(model.actionError ?? "none"), can undo \(model.canUndoTrash)"
        )
        model.actionError = nil
        model.actionErrorDetail = nil
        model.undoTrash()
        check(
            "and it is undone",
            FileManager.default.fileExists(atPath: base.appendingPathComponent("c/z.dat").path)
                && !zRef.isStale,
            "c/z.dat is not back"
        )
    }

    /// Bringing something back is the one place this app moves a file to
    /// somewhere it chose. Each thing it has to be sure of first is held to
    /// the disk here, with a folder standing in for the Trash: the thing in
    /// the Trash is the thing that was put there, the folder at the other
    /// end is the folder it left, and nothing is where it is going.
    private static func testPuttingBackMovesOnlyWhatWasPutThere() {
        let base = scratch("put-back")
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = FileManager.default
        let home = base.appendingPathComponent("home")
        let bin = base.appendingPathComponent("bin")
        let elsewhere = base.appendingPathComponent("elsewhere")
        for folder in [home, bin, elsewhere] {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let original = home.appendingPathComponent("notes.txt").path
        let binned = bin.appendingPathComponent("notes.txt").path

        /// Writes notes.txt in `home`, moves it to the stand-in Trash as a
        /// move to the Trash would, and gives the receipt for it.
        func throwAway(_ text: String = "the first") -> FileActions.TrashReceipt? {
            try? manager.removeItem(atPath: binned)
            try? manager.removeItem(atPath: original)
            try? Data(text.utf8).write(to: URL(fileURLWithPath: original))
            guard let item = FileActions.FileIdentity(atPath: original),
                let folder = FileActions.FileIdentity(atPath: home.path),
                (try? manager.moveItem(atPath: original, toPath: binned)) != nil
            else { return nil }
            return FileActions.TrashReceipt(inTrash: binned, item: item, folder: folder)
        }
        func outcome(_ receipt: FileActions.TrashReceipt, to path: String) -> String {
            do {
                try FileActions.putBack(receipt, to: path)
                return "put back"
            } catch {
                return error.localizedDescription
            }
        }
        func text(_ path: String) -> String {
            (try? String(contentsOfFile: path, encoding: .utf8)) ?? "nothing"
        }

        guard let plain = throwAway() else {
            check("the put-back fixture can be built", false, "")
            return
        }
        check(
            "something in the Trash is known to be there",
            plain.isStillInTrash,
            ""
        )
        check(
            "and goes back where it was",
            outcome(plain, to: original) == "put back" && text(original) == "the first"
                && !manager.fileExists(atPath: binned) && !plain.isStillInTrash,
            text(original)
        )

        // Emptied out, and another file of the same name thrown away since:
        // it is given the first one's place in the Trash.
        guard let emptied = throwAway() else { return }
        try? manager.removeItem(atPath: binned)
        check(
            "what has been emptied out of the Trash is not there to bring back",
            !emptied.isStillInTrash
                && outcome(emptied, to: original) == "It is no longer in the Trash.",
            outcome(emptied, to: original)
        )
        try? Data("somebody else's".utf8).write(to: URL(fileURLWithPath: binned))
        check(
            "nor is something else that has been given its place there",
            !emptied.isStillInTrash
                && outcome(emptied, to: original) == "It is no longer in the Trash."
                && text(binned) == "somebody else's" && !manager.fileExists(atPath: original),
            "\(outcome(emptied, to: original)); the Trash holds “\(text(binned))”"
        )

        // Something has arrived where it was. Whatever it is, it stays.
        func refusedOver(_ what: String, _ put: () -> Void) {
            guard let receipt = throwAway() else { return }
            put()
            let there = FileActions.FileIdentity(atPath: original)
            let said = outcome(receipt, to: original)
            check(
                "it is not put back over \(what), which is left as it was",
                said.hasPrefix("Something else is at") && receipt.isStillInTrash
                    && there != nil && FileActions.FileIdentity(atPath: original) == there,
                said
            )
            try? manager.removeItem(atPath: original)
        }
        refusedOver("a file") {
            try? Data("in its place".utf8).write(to: URL(fileURLWithPath: original))
        }
        refusedOver("an empty folder") {
            try? manager.createDirectory(atPath: original, withIntermediateDirectories: false)
        }
        refusedOver("a link that leads nowhere") {
            try? manager.createSymbolicLink(
                atPath: original,
                withDestinationPath: base.path + "/no-such-thing"
            )
        }

        // The folder it came out of has gone, or is not that folder.
        guard let orphan = throwAway() else { return }
        try? manager.removeItem(at: home)
        check(
            "it is not put back into a folder that has gone",
            outcome(orphan, to: original).contains("is no longer there")
                && orphan.isStillInTrash,
            outcome(orphan, to: original)
        )
        try? manager.createSymbolicLink(at: home, withDestinationURL: elsewhere)
        check(
            "nor through a link that has taken the folder's place, into somewhere else",
            outcome(orphan, to: original).contains("is no longer there")
                && orphan.isStillInTrash
                && (try? manager.contentsOfDirectory(atPath: elsewhere.path)) == [],
            outcome(orphan, to: original) + "; elsewhere holds "
                + "\((try? manager.contentsOfDirectory(atPath: elsewhere.path)) ?? [])"
        )
        try? manager.removeItem(at: home)
        try? manager.createDirectory(at: home, withIntermediateDirectories: true)
        check(
            "nor into a new folder of the same name, which is not the one it left",
            outcome(orphan, to: original).contains("is no longer there")
                && orphan.isStillInTrash,
            outcome(orphan, to: original)
        )
    }

    /// Taking one name of a hard-linked file out of the tree can hand its
    /// bytes to another name. Coming back, it has to be told which of them it
    /// now is, or the bytes are in the tree twice or not at all. Each way a
    /// pair can be parted by a move to the Trash is undone here and held to
    /// a fresh scan.
    @MainActor
    private static func testUndoingATrashPutsHardLinksRight() {
        let base = scratch("undo-links")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            for folder in ["a", "b", "c"] {
                try FileManager.default.createDirectory(
                    at: base.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            // One file with a name in each of two folders, one with both its
            // names in the same folder, and a plain file beside each.
            try write(base.appendingPathComponent("a/film.dat"), bytes: 9_000)
            try FileManager.default.linkItem(
                at: base.appendingPathComponent("a/film.dat"),
                to: base.appendingPathComponent("b/film.lnk")
            )
            try write(base.appendingPathComponent("a/plain.dat"), bytes: 2_000)
            try write(base.appendingPathComponent("b/plain.log"), bytes: 3_000)
            try write(base.appendingPathComponent("c/twin.dat"), bytes: 5_000)
            try FileManager.default.linkItem(
                at: base.appendingPathComponent("c/twin.dat"),
                to: base.appendingPathComponent("c/twin.bak")
            )
        } catch {
            check("the undo-links fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path

        /// Scans afresh, removes what `pick` chooses, undoes it, and holds
        /// the tree to a fresh scan both times.
        func round(
            _ what: String,
            _ pick: (_ counted: DirNode, _ duplicate: DirNode, _ root: DirNode) -> Set<NodeRef>
        ) {
            guard let result = loadSynchronously(into: model),
                let a = result.root.subdir(named: "a"),
                let b = result.root.subdir(named: "b"),
                let (counted, duplicate) = roles(a, b)
            else {
                check("the undo-links fixture scanned as a linked pair", false, what)
                return
            }
            let targets = pick(counted, duplicate, result.root)
            // Taken while they are still there to have one.
            let paths = targets.map(\.path)
            trash(model, targets)
            check(
                "\(what): gone, the tree is what is left on disk",
                agreesWithAFreshScan(model, base) == nil,
                agreesWithAFreshScan(model, base) ?? ""
            )
            model.undoTrash()
            check(
                "\(what): undone, the tree is what is on disk again",
                agreesWithAFreshScan(model, base) == nil && model.actionError == nil,
                agreesWithAFreshScan(model, base) ?? (model.actionError ?? "")
            )
            // A tree and a disk that are both still without it agree as well.
            check(
                "\(what): and what went is back, on disk and in the tree",
                !targets.isEmpty && targets.allSatisfy { !$0.isStale }
                    && paths.allSatisfy { FileManager.default.fileExists(atPath: $0) },
                "\(targets.filter(\.isStale).map(\.name)) not in the tree"
            )
            let names = [a, b].flatMap { dir in
                dir.files.filter { !$0.isRemoved && $0.name.hasPrefix("film") }
            }
            check(
                "\(what): and exactly one of the film's two names carries its bytes",
                names.count == 2 && names.filter(\.isDuplicateLink).count == 1,
                "\(names.map { "\($0.name) duplicate=\($0.isDuplicateLink)" })"
            )
        }
        func film(_ dir: DirNode) -> NodeRef {
            let index = dir.files.firstIndex { $0.name.hasPrefix("film") } ?? 0
            return NodeRef(dir: dir, fileIndex: index)
        }

        round("the name that carries the bytes") { counted, _, _ in [film(counted)] }
        round("the second name") { _, duplicate, _ in [film(duplicate)] }
        round("the folder of the name that carries the bytes") { counted, _, _ in
            [NodeRef(counted)]
        }
        round("the folder of the second name") { _, duplicate, _ in [NodeRef(duplicate)] }
        round("both names at once") { counted, duplicate, _ in
            [film(counted), film(duplicate)]
        }
        round("both their folders at once") { counted, duplicate, _ in
            [NodeRef(counted), NodeRef(duplicate)]
        }
        round("a folder holding both names of another file") { _, _, root in
            root.subdir(named: "c").map { [NodeRef($0)] } ?? []
        }
        round("one name of a pair in the same folder") { _, _, root in
            guard let c = root.subdir(named: "c"),
                let index = c.files.firstIndex(where: { !$0.isDuplicateLink })
            else { return [] }
            return [NodeRef(dir: c, fileIndex: index)]
        }

        // What the Trash is said to hold is what left the totals. Asked of
        // each name on its own it came to nothing for both names of a file:
        // each is a name that frees nothing, and between them were all of it.
        if let result = loadSynchronously(into: model),
            let a = result.root.subdir(named: "a"),
            let b = result.root.subdir(named: "b"),
            let (counted, duplicate) = roles(a, b)
        {
            let whole = film(counted).alloc
            let before = model.bytesInTrash
            trash(model, [film(counted), film(duplicate)])
            check(
                "both names moved together are all of it, once",
                model.bytesInTrash - before == whole,
                "\(model.bytesInTrash - before) more bytes in the Trash, the file takes \(whole)"
            )
            model.undoTrash()
        } else {
            check("the fixture is a linked pair for both names at once", false, "the pair did not scan as a pair")
        }

        // Both names go, and only one can come back: it is then the only
        // name in the tree, and has to be the one that carries the bytes.
        guard let result = loadSynchronously(into: model),
            let a = result.root.subdir(named: "a"),
            let b = result.root.subdir(named: "b"),
            let (counted, duplicate) = roles(a, b)
        else {
            check("the fixture is a linked pair for one name coming back", false, "")
            return
        }
        let stays = film(counted)
        let returns = film(duplicate)
        let blocked = URL(fileURLWithPath: stays.path)
        trash(model, [stays, returns])
        try? Data("in its place".utf8).write(to: blocked)
        model.undoTrash()
        check(
            "and the name left in the Trash holds nothing that is missing from the totals",
            model.bytesInTrash == 0,
            "\(model.bytesInTrash) bytes in the Trash"
        )
        check(
            "a second name that comes back alone carries the bytes itself",
            returns.file?.isDuplicateLink == false && stays.isStale
                && firstThatDoesNotAddUp(result.root) == nil
                && result.hardLinkSavings(using: .logical) == 5_000,
            "duplicate \(String(describing: returns.file?.isDuplicateLink)), "
                + "saving \(result.hardLinkSavings(using: .logical)); "
                + (firstThatDoesNotAddUp(result.root) ?? "adds up")
        )
        model.actionError = nil
        model.actionErrorDetail = nil

        // The name that stayed in the Trash is given back to the file under
        // its old name, so there is a pair again for one last round — which
        // comes last because it leaves a name in the Trash for good.
        try? FileManager.default.removeItem(at: blocked)
        try? FileManager.default.linkItem(atPath: returns.path, toPath: blocked.path)
        if let result = loadSynchronously(into: model),
            let a = result.root.subdir(named: "a"),
            let b = result.root.subdir(named: "b"),
            let (counted, duplicate) = roles(a, b)
        {
            let whole = film(counted).alloc
            let held = model.bytesInTrash
            trash(model, [film(duplicate)])
            check(
                "a second name in the Trash holds nothing there that is not still here",
                model.bytesInTrash == held,
                "\(model.bytesInTrash - held) more bytes in the Trash"
            )
            trash(model, [film(counted)])
            check(
                "once the last name has gone too, the Trash holds the file",
                model.bytesInTrash - held == whole && whole > 0,
                "\(model.bytesInTrash - held) more bytes in the Trash, the file takes \(whole)"
            )
            model.undoTrash()
        } else {
            check("the fixture is a linked pair for one name after the other", false, "the pair did not scan as a pair")
        }
    }

    /// The measure on show and what was last scanned started over at every
    /// launch. They are recorded when they are chosen, and only then.
    @MainActor
    private static func testChoicesOutlastALaunch() {
        let suite = "wizzzee-selftest-choices-\(getpid())"
        guard let scratchStore = UserDefaults(suiteName: suite) else {
            check("a throwaway preference suite is available", false, suite)
            return
        }
        let real = Preferences.store
        Preferences.store = scratchStore
        defer {
            Preferences.store = real
            scratchStore.removePersistentDomain(forName: suite)
        }
        let folder = scratch("choices")
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }

        let fresh = AppModel()
        check(
            "a first launch shows space on disk and the boot volume",
            fresh.sizeMetric == .allocated && fresh.customFolder == nil
                && fresh.treeSort.first?.key == .allocated,
            "metric \(fresh.sizeMetric), folder \(fresh.customFolder ?? "none")"
        )

        fresh.chooseMetric(.logical)
        let next = AppModel()
        check(
            "the measure chosen is the one the next launch starts with",
            next.sizeMetric == .logical && next.treeSort.first?.key == .size
                && next.fileSort.first?.keyPath == \FileRow.size,
            "metric \(next.sizeMetric), sorted by "
                + "\(String(describing: next.treeSort.first?.key))"
        )
        check(
            "and --prefs reports it under the name --metric takes",
            Preferences.summary().contains("sizeMetric: size (stored)"),
            Preferences.summary()
        )

        let render = AppModel()
        render.sizeMetric = .allocated
        render.customFolder = "/tmp"
        check(
            "assigning the properties, as the headless renderer does, records nothing",
            Preferences.sizeMetric == .logical && Preferences.lastFolder == nil,
            "stored \(Preferences.sizeMetric), folder \(Preferences.lastFolder ?? "none")"
        )

        // What choosing a folder in the panel comes to, without the panel.
        let chooser = AppModel()
        chooser.scanFolder(folder.path)
        pumpUntilSettled(chooser)
        check(
            "a folder that is chosen is recorded, and is what the next launch offers",
            Preferences.lastFolder == folder.path && chooser.customFolder == folder.path
                && chooser.phase == .complete && AppModel().customFolder == folder.path,
            "stored \(Preferences.lastFolder ?? "none"), next launch "
                + "\(AppModel().customFolder ?? "none")"
        )
        try? FileManager.default.removeItem(at: folder)
        check(
            "unless it has gone since",
            AppModel().customFolder == nil,
            "folder \(AppModel().customFolder ?? "none")"
        )

        let picker = AppModel()
        picker.customFolder = "/tmp"
        guard let volume = picker.volumes.last?.path else { return }
        picker.chooseVolume(volume)
        check(
            "picking a volume takes the folder's place, now and next time",
            picker.customFolder == nil && picker.selectedVolumePath == volume
                && Preferences.lastFolder == nil && Preferences.lastVolume == volume
                && AppModel().selectedVolumePath == volume,
            "stored volume \(Preferences.lastVolume ?? "none")"
        )
        Preferences.lastVolume = "/Volumes/wizzzee-selftest-no-such-disk"
        check(
            "a disk that is no longer mounted is not picked again",
            AppModel().selectedVolumePath == (picker.volumes.first?.path ?? "/"),
            "selected \(AppModel().selectedVolumePath)"
        )

        // Renaming a volume in Finder moves its mount point. What is
        // remembered has to move with it, or the next launch looks for the
        // disk where it no longer is.
        Preferences.lastVolume = "/Volumes/Backup"
        Preferences.lastFolder = "/Volumes/Backup/Photos/2024"
        Preferences.volumeMoved(from: "/Volumes/Backup", to: "/Volumes/Backups")
        check(
            "a renamed volume is remembered by its new name, and a folder on it too",
            Preferences.lastVolume == "/Volumes/Backups"
                && Preferences.lastFolder == "/Volumes/Backups/Photos/2024",
            "volume \(Preferences.lastVolume ?? "none"), folder "
                + "\(Preferences.lastFolder ?? "none")"
        )
        Preferences.lastFolder = "/Volumes/Backup2/Photos"
        Preferences.volumeMoved(from: "/Volumes/Backup", to: "/Volumes/Other")
        check(
            "a volume whose name only starts the same is left alone",
            Preferences.lastVolume == "/Volumes/Backups"
                && Preferences.lastFolder == "/Volumes/Backup2/Photos",
            "volume \(Preferences.lastVolume ?? "none"), folder "
                + "\(Preferences.lastFolder ?? "none")"
        )
    }

    /// ⌘Y opens Quick Look on the one item selected and on show, and shuts
    /// it again. What it shows follows the selection, goes when what it was
    /// showing is deleted, and is never a file whose contents would have to
    /// be downloaded to be shown.
    @MainActor
    private static func testQuickLookShowsWhatIsSelected() {
        let model = AppModel()
        guard let (base, result) = loadWalkabout("preview", into: model) else { return }
        defer { try? FileManager.default.removeItem(at: base) }
        guard let a = result.root.subdir(named: "a"),
            let b = a.subdir(named: "b"),
            let c = result.root.subdir(named: "c"),
            let y = a.files.firstIndex(where: { $0.name == "y.dat" }),
            let z = c.files.firstIndex(where: { $0.name == "z.dat" })
        else {
            check("the preview fixture scanned", false, "missing folders")
            return
        }
        let yRef = NodeRef(dir: a, fileIndex: y)
        let zRef = NodeRef(dir: c, fileIndex: z)
        func showing() -> String { model.previewURL?.lastPathComponent ?? "nothing" }

        // y.dat is inside a, which starts shut: selected, and not on show.
        model.selection = [yRef]
        check(
            "a selection a shut folder hides is not something to look at",
            !model.canTogglePreview,
            "can toggle \(model.canTogglePreview)"
        )
        model.togglePreview()
        check("so ⌘Y opens nothing for it", model.previewURL == nil, showing())

        model.setExpanded(a, true)
        check("on show, it is", model.canTogglePreview, "")
        model.togglePreview()
        check(
            "⌘Y opens Quick Look on the selected file",
            model.previewURL?.path == yRef.path && model.previewed == yRef,
            "showing \(showing())"
        )

        model.selection = [NodeRef(b)]
        check(
            "with the panel open, selecting something else shows that instead",
            model.previewURL?.path == NodeRef(b).path,
            "showing \(showing())"
        )
        // While it is up it shows the one thing selected. Several selected,
        // or nothing, is no one thing, and the delete keys act on the
        // selection: a panel left on a file that is not what ⌘⌫ would remove
        // is worse than no panel.
        model.selection = [NodeRef(b), yRef]
        check(
            "selecting several shuts it, there being no one of them to show",
            model.previewURL == nil && model.previewed == nil,
            "showing \(showing())"
        )
        check(
            "and with several selected there is nothing for ⌘Y to open",
            !model.canTogglePreview,
            "can toggle \(model.canTogglePreview)"
        )
        model.selection = [NodeRef(a)]
        check(
            "a change of selection does not open a panel that was shut",
            model.previewURL == nil,
            "showing \(showing())"
        )
        model.togglePreview()
        check("⌘Y opens it again", model.previewURL?.path == NodeRef(a).path, showing())
        model.selection = []
        check("selecting nothing shuts it", model.previewURL == nil, showing())
        model.selection = [NodeRef(a)]
        model.togglePreview()
        model.togglePreview()
        check(
            "⌘Y with the panel open shuts it",
            model.previewURL == nil && model.previewed == nil,
            "showing \(showing())"
        )

        // From the right-click menu, which acts on the row that was clicked
        // and not on whatever is selected. Looking at a row selects it: the
        // delete keys then name what is in the panel and nothing else.
        model.setExpanded(c, true)
        model.preview(zRef)
        check(
            "looking at a row from its menu selects it",
            model.previewed == zRef && model.selection == [zRef],
            "showing \(showing()), selected \(model.selection.map(\.name))"
        )
        check(
            "so the delete keys are aimed at what the panel is showing",
            model.selectionOnShow == [zRef],
            "on show \(model.selectionOnShow.map(\.name))"
        )

        // What is being looked at is removed. The selection moves to what
        // took its place — here the folder, which is now empty — and the
        // panel goes with it: working down a list with it open, looking and
        // then removing, is what it is for.
        deletePermanently(model, [zRef])
        check(
            "deleting what is on show moves the panel on with the selection",
            model.selection == [NodeRef(c)]
                && model.previewURL?.path == NodeRef(c).path,
            "selected \(model.selection.map(\.name)), showing \(showing())"
        )
        model.togglePreview()
        model.preview(zRef)
        check(
            "it will not open on something that has gone",
            model.previewURL == nil,
            "showing \(showing())"
        )

        model.preview(yRef)
        deletePermanently(model, [NodeRef(c)])
        check(
            "deleting something else leaves it where it was",
            model.previewURL?.path == yRef.path && model.selection == [yRef],
            "showing \(showing())"
        )
        model.selection = [NodeRef(b)]
        deletePermanently(model, [NodeRef(b)])
        check(
            "and again down a list: the next row is selected and on show",
            model.selection == [yRef] && model.previewURL?.path == yRef.path,
            "selected \(model.selection.map(\.name)), showing \(showing())"
        )

        // A key reaches the menu from under a question that is waiting for
        // an answer, and would put a panel up over it.
        model.togglePreview()
        model.permanentDeleteTargets = [yRef]
        check(
            "nothing is opened over a delete waiting to be confirmed",
            !model.canTogglePreview,
            "can toggle \(model.canTogglePreview)"
        )
        model.permanentDeleteTargets = []
        model.actionError = "something to read first"
        check("nor over an alert", !model.canTogglePreview, "")
        model.actionError = nil
        model.togglePreview()
        model.actionError = "something to read first"
        check(
            "though a panel that is already up can always be shut",
            model.canTogglePreview && model.previewURL != nil,
            "can toggle \(model.canTogglePreview)"
        )
        model.actionError = nil

        // Asked of the disk as it is, and through a link: what reads a link
        // reads what it is to. Nothing here can make a real online-only
        // file, so this is the half that can be held to the disk.
        let plain = base.appendingPathComponent("a/y.dat").path
        let link = base.appendingPathComponent("link-to-y").path
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: plain)
        check(
            "a file that is all here is not online only, by itself or through a link",
            !FileActions.isOnlineOnly(plain) && !FileActions.isOnlineOnly(link)
                && !FileActions.isOnlineOnly(base.path + "/no-such-file"),
            ""
        )

        _ = loadSynchronously(into: model)
        check("a rescan shuts it", model.previewURL == nil, showing())

        // A file a cloud provider is holding. Nothing here can make a real
        // one, so the entry is made by hand, under a root of its own.
        let cloud = DirNode(name: "/wizzzee-selftest-cloud", parent: nil)
        cloud.files = [
            FileEntry(
                name: "film.mov",
                size: 4_000_000_000,
                alloc: 0,
                mtime: 0,
                extIndex: -1,
                isSymlink: false,
                isDuplicateLink: false,
                storage: .dataless
            ),
            FileEntry(
                name: "note.txt",
                size: 100,
                alloc: 4_096,
                mtime: 0,
                extIndex: -1,
                isSymlink: false,
                isDuplicateLink: false
            ),
        ]
        let film = NodeRef(dir: cloud, fileIndex: 0)
        model.actionError = nil
        model.preview(film)
        check(
            "an online-only file is not opened, which would download it",
            model.previewURL == nil && model.actionError?.contains("online only") == true
                && model.actionErrorDetail?.contains("4.0 GB") == true,
            "showing \(showing()), said \(model.actionError ?? "nothing"): "
                + "\(model.actionErrorDetail ?? "")"
        )
        model.actionError = nil
        model.actionErrorDetail = nil
        model.preview(NodeRef(dir: cloud, fileIndex: 1))
        model.selection = [film]
        check(
            "and moving the selection onto one shuts the panel without a word",
            model.previewURL == nil && model.actionError == nil,
            "showing \(showing()), said \(model.actionError ?? "nothing")"
        )
        model.selection = []
    }

    // MARK: - Search

    /// The filter was one piece of text. It is now read: words to find, and
    /// filters for size, age, type and kind.
    private static func testASearchIsReadFromWhatWasTyped() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func read(_ text: String) -> SearchQuery { SearchQuery(text, now: now) }

        let nothing = read("   ")
        check(
            "nothing typed asks for nothing, and for files",
            nothing.isEmpty && nothing.finds(.file) && !nothing.finds(.folder),
            "empty \(nothing.isEmpty)"
        )

        let words = read("Node_Modules  src/app \"two words\"")
        check(
            "words are looked for in names, and one with a slash in the path",
            words.names == ["node_modules", "two words"] && words.paths == ["src/app"]
                && words.needsPaths && !words.isEmpty,
            "names \(words.names), paths \(words.paths)"
        )
        check(
            "a word to go by brings folders in as well as files",
            words.finds(.file) && words.finds(.folder),
            "files \(words.finds(.file)), folders \(words.finds(.folder))"
        )
        check(
            "every word has to be there, in any order and any case",
            words.matches(name: "Two Words in NODE_MODULES")
                && !words.matches(name: "node_modules")
                && words.matches(path: "/x/SRC/App/y") && !words.matches(path: "/x/src"),
            ""
        )

        let sizes = read(">1.5gb <2TB")
        check(
            "> and < are sizes, in the units the app shows",
            sizes.above == 1_500_000_000 && sizes.below == 2_000_000_000_000
                && sizes.names.isEmpty,
            "above \(String(describing: sizes.above)), below "
                + "\(String(describing: sizes.below))"
        )
        check(
            "and both ends are left out",
            !sizes.admits(bytes: 1_500_000_000, mtime: 0)
                && sizes.admits(bytes: 1_500_000_001, mtime: 0)
                && !sizes.admits(bytes: 2_000_000_000_000, mtime: 0),
            ""
        )
        check(
            "a bare number is bytes, and k, m, g and t are enough",
            read(">10").above == 10 && read(">3k").above == 3_000
                && read("<4m").below == 4_000_000 && read(">5g").above == 5_000_000_000
                && read(">1t").above == 1_000_000_000_000,
            "\(String(describing: read(">3k").above))"
        )

        let day = 86_400.0
        let ages = read("older:1y newer:6m")
        check(
            "older: and newer: are counted back from now",
            ages.modifiedBefore == now.timeIntervalSince1970 - 365 * day
                && ages.modifiedAfter == now.timeIntervalSince1970 - 180 * day,
            "before \(String(describing: ages.modifiedBefore)), after "
                + "\(String(describing: ages.modifiedAfter))"
        )
        let old = read("older:2w")
        check(
            "something modified before the cutoff is older, and at it is not",
            old.admits(bytes: 0, mtime: now.timeIntervalSince1970 - 14 * day - 1)
                && !old.admits(bytes: 0, mtime: now.timeIntervalSince1970 - 14 * day),
            ""
        )
        check(
            "days and weeks are read too",
            read("newer:30d").modifiedAfter == now.timeIntervalSince1970 - 30 * day
                && read("older:2w").modifiedBefore
                    == now.timeIntervalSince1970 - 14 * day,
            ""
        )

        check(
            "ext: names one type, with or without its dot, in any case",
            read("ext:DMG").ext == "dmg" && read("ext:.dmg").ext == "dmg"
                && read("ext:none").ext == "",
            "\(String(describing: read("ext:DMG").ext))"
        )
        check(
            "a type asked for leaves folders out, word or no word",
            !read("backup ext:dmg").finds(.folder) && read("backup ext:dmg").finds(.file),
            ""
        )
        let folders = read("kind:folder")
        check(
            "kind: says which of the two, and needs no word to go with it",
            folders.kind == .folder && folders.finds(.folder) && !folders.finds(.file)
                && !folders.isEmpty && read("x kind:file").finds(.file)
                && !read("x kind:file").finds(.folder),
            "kind \(String(describing: folders.kind))"
        )

        let bad = [">", ">1zb", "<big", "older:", "older:5x", "newer:soon", "kind:thing", "ext:"]
        let unread = bad.filter { read($0).unreadable != [$0] }
        check(
            "a filter that can't be read is kept as one that could not be",
            unread.isEmpty,
            "read without complaint: \(unread)"
        )
        let both = read("report >1zb")
        check(
            "and is not mistaken for a word to look for",
            both.names == ["report"] && both.unreadable == [">1zb"] && !both.isEmpty,
            "names \(both.names), unreadable \(both.unreadable)"
        )
        let literal = read("12:30 \">1gb\" a:b")
        check(
            "a name with a colon in it, or a filter in quotes, is a word",
            literal.names == ["12:30", ">1gb", "a:b"] && literal.unreadable.isEmpty
                && literal.above == nil,
            "names \(literal.names), above \(String(describing: literal.above))"
        )
        check(
            "a word typed with an accent has names folded to meet it",
            read("café").foldsNames && !read("cafe").foldsNames,
            ""
        )
        // Typed as one letter, and stored on disk as a letter and a mark
        // after it, which is how most of macOS writes it.
        check(
            "and meets them, however the accent is spelled and in either case",
            read("café").matches(name: "cafe\u{0301} menu.txt")
                && read("café").matches(name: "CAFÉ.TXT")
                && !read("café").matches(name: "cafe.txt"),
            ""
        )

        // A second filter of a kind is one more to meet, as a second word
        // is. The last one used to win, and what the first had ruled out
        // came back without a word.
        let twice = read(">10gb >1mb <1tb <500gb")
        check(
            "two sizes the same way round keep the tighter of the two",
            twice.above == 10_000_000_000 && twice.below == 500_000_000_000,
            "above \(String(describing: twice.above)), below "
                + "\(String(describing: twice.below))"
        )
        let ageTwice = read("older:30d older:2y newer:1y newer:30d")
        check(
            "and two ages likewise",
            ageTwice.modifiedBefore == now.timeIntervalSince1970 - 730 * day
                && ageTwice.modifiedAfter == now.timeIntervalSince1970 - 30 * day,
            "before \(String(describing: ageTwice.modifiedBefore)), after "
                + "\(String(describing: ageTwice.modifiedAfter))"
        )
        check(
            "two types, or files and folders, are something nothing can be both of",
            read("ext:dmg ext:pdf").isImpossible && read("kind:file kind:folder").isImpossible
                && !read("ext:dmg ext:.DMG").isImpossible
                && !read("kind:file kind:files").isImpossible,
            ""
        )
        check(
            "an extension that is all dots is not the files with none",
            read("ext:.").unreadable == ["ext:."] && read("ext:...").ext == nil
                && read("ext:none").ext == "",
            "unreadable \(read("ext:.").unreadable)"
        )

        // Where a word asked of the path can be, worked out once for a
        // folder: all of it in the folder's own path, or its last slash on
        // the slash between the folder and the name.
        let under = read("proj1/node")
        check(
            "in the folder the word ends in, a name has to start with the rest of it",
            under.pathScope(inFolder: "/x/proj1") == .namesStarting(["node"])
                && under.pathScope(inFolder: "/x/PROJ1") == .namesStarting(["node"]),
            "\(under.pathScope(inFolder: "/x/proj1"))"
        )
        check(
            "below that folder everything has it, and elsewhere nothing can",
            under.pathScope(inFolder: "/x/proj1/node_modules") == .everything
                && under.pathScope(inFolder: "/x/proj12") == .nothing
                && under.pathScope(inFolder: "/x") == .nothing,
            "\(under.pathScope(inFolder: "/x/proj1/node_modules"))"
        )
        check(
            "a word ending in a slash is only ever in the folder's part",
            read("proj1/").pathScope(inFolder: "/x/proj1") == .everything
                && read("proj1/").pathScope(inFolder: "/x") == .nothing,
            "\(read("proj1/").pathScope(inFolder: "/x"))"
        )
        check(
            "at the top of a volume the folder's part is the slash alone",
            read("/us").pathScope(inFolder: "/") == .namesStarting(["us"])
                && read("/").pathScope(inFolder: "/") == .everything,
            "\(read("/us").pathScope(inFolder: "/"))"
        )
        check(
            "a word with an accent has the whole path put together to look in",
            read("café/x").pathScope(inFolder: "/x") == .wholePath
                && read("word").pathScope(inFolder: "/x") == .everything,
            "\(read("café/x").pathScope(inFolder: "/x"))"
        )
    }

    /// proj1/node_modules/a.js (4,000), proj1/node_modules/pkg/node_modules/
    /// b.js (2,000), proj1/src/main.js (1,000), proj2/node_modules/c.js
    /// (3,000), big.bin (50,000), old.log (8,000, two years old), new.log
    /// (6,000).
    private static func buildSearchFixture(at base: URL) throws {
        let manager = FileManager.default
        for folder in [
            "proj1/node_modules/pkg/node_modules", "proj1/src", "proj2/node_modules",
        ] {
            try manager.createDirectory(
                at: base.appendingPathComponent(folder),
                withIntermediateDirectories: true
            )
        }
        try write(base.appendingPathComponent("proj1/node_modules/a.js"), bytes: 4_000)
        try write(
            base.appendingPathComponent("proj1/node_modules/pkg/node_modules/b.js"),
            bytes: 2_000
        )
        try write(base.appendingPathComponent("proj1/src/main.js"), bytes: 1_000)
        try write(base.appendingPathComponent("proj2/node_modules/c.js"), bytes: 3_000)
        try write(base.appendingPathComponent("big.bin"), bytes: 50_000)
        try write(base.appendingPathComponent("old.log"), bytes: 8_000)
        try write(base.appendingPathComponent("new.log"), bytes: 6_000)
        try manager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -2 * 365 * 86_400)],
            ofItemAtPath: base.appendingPathComponent("old.log").path
        )
    }

    /// "Every node_modules, and what they come to" is a question about
    /// folders, and the filter only ever looked at files. Nor did it say how
    /// much it had found: only the largest thousand of it.
    private static func testASearchFindsFoldersAndCountsWhatItFinds() {
        let base = scratch("search")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildSearchFixture(at: base)
        } catch {
            check("the search fixture can be built", false, "\(error)")
            return
        }
        let result = scan(base)
        func find(_ text: String, ofType type: Int? = nil, limit: Int = 100) -> SearchResult {
            result.search(SearchQuery(text), ofType: type, limit: limit, metric: .logical)
        }
        func names(_ found: SearchResult) -> [String] { found.rows.map(\.name) }
        func said(_ found: SearchResult) -> String {
            "rows \(names(found)), \(String(describing: found.matches)) matches, "
                + "\(found.bytes) bytes"
        }

        let modules = find("node_modules")
        check(
            "a word finds the folders of that name, wherever they are",
            modules.rows.count == 3 && modules.rows.allSatisfy(\.isDirectory)
                && Set(names(modules)) == ["node_modules"],
            said(modules)
        )
        check(
            "largest first, each at everything it holds",
            modules.rows.map(\.size) == [6_000, 3_000, 2_000],
            "\(modules.rows.map(\.size))"
        )
        check(
            "the count is of all three, and one inside another adds nothing to the size",
            modules.matches == 3 && modules.bytes == 9_000,
            said(modules)
        )
        check(
            "kind:file holds the same word to files, of which there are none",
            find("node_modules kind:file").rows.isEmpty
                && find("node_modules kind:file").matches == 0,
            said(find("node_modules kind:file"))
        )

        let scripts = find("js")
        check(
            "a word finds files as it always did, and says what they come to",
            names(scripts) == ["a.js", "c.js", "b.js", "main.js"]
                && scripts.matches == 4 && scripts.bytes == 10_000,
            said(scripts)
        )
        let few = find("js", limit: 2)
        check(
            "everything found is counted, however few of them are listed",
            names(few) == ["a.js", "c.js"] && few.matches == 4 && few.bytes == 10_000,
            said(few)
        )

        let folders = find("kind:folder")
        check(
            "kind:folder lists every folder, and totals only the outermost",
            folders.matches == 7 && folders.rows.allSatisfy(\.isDirectory)
                && names(folders).first == "proj1" && folders.bytes == 10_000,
            said(folders)
        )

        let large = find(">5kb")
        check(
            "a size on its own is asked of files, not of the folders they are in",
            names(large) == ["big.bin", "old.log", "new.log"] && large.matches == 3
                && large.bytes == 64_000,
            said(large)
        )
        check(
            "two sizes are a range",
            names(find(">5kb <10kb")) == ["old.log", "new.log"],
            said(find(">5kb <10kb"))
        )
        check(
            "older: finds what has not been touched since",
            names(find("older:1y")) == ["old.log"] && find("older:1y").matches == 1,
            said(find("older:1y"))
        )
        check(
            "newer: finds the rest, and a word narrows it",
            names(find("newer:30d log")) == ["new.log"],
            said(find("newer:30d log"))
        )

        check(
            "ext: is one type exactly",
            names(find("ext:log")) == ["old.log", "new.log"]
                && find("ext:log").bytes == 14_000,
            said(find("ext:log"))
        )
        check(
            "a type the scan has none of finds nothing",
            find("ext:nope").rows.isEmpty && find("ext:nope").matches == 0,
            said(find("ext:nope"))
        )
        let bin = result.typeIndex(for: "bin")
        check(
            "nor does one that is not the type in focus",
            find("ext:log", ofType: bin).rows.isEmpty
                && names(find("ext:bin", ofType: bin)) == ["big.bin"],
            said(find("ext:log", ofType: bin))
        )
        check(
            "with a type in focus, a word finds no folders",
            names(find("proj", ofType: bin)).isEmpty
                && names(find("big", ofType: bin)) == ["big.bin"],
            said(find("proj", ofType: bin))
        )

        let under = find("proj1/")
        check(
            "a word with a slash is looked for in the path, of folders too",
            under.matches == 7 && under.rows.filter(\.isDirectory).count == 4
                && under.bytes == 7_000,
            said(under)
        )

        let unread = find("js >zz")
        check(
            "a filter that can't be read finds nothing, not everything",
            unread.rows.isEmpty && unread.matches == 0,
            said(unread)
        )
        check(
            "nor do two filters that nothing can meet both of",
            find("ext:log ext:bin").matches == 0 && find("ext:log ext:bin").rows.isEmpty
                && find("js kind:file kind:folder").matches == 0,
            said(find("ext:log ext:bin"))
        )
        check(
            "a second size narrows the first, where it used to replace it",
            names(find(">7kb >1kb")) == ["big.bin", "old.log"],
            said(find(">7kb >1kb"))
        )
        check(
            "what was found is known to be folders, files, or some of each",
            modules.folders == 3 && scripts.folders == 0 && under.folders == 4,
            "\(modules.folders), \(scripts.folders), \(under.folders)"
        )

        // The path is never put together for a file: where a word can be in
        // it is worked out from the folder's part and the name's. Held to
        // doing it the plain way, for words that fall in the folder's part,
        // across the join, and nowhere.
        var everything: [(path: String, ref: NodeRef)] = []
        var pending: [DirNode] = [result.root]
        while let dir = pending.popLast() {
            for index in dir.files.indices
            where !dir.files[index].isRemoved && !dir.files[index].isDuplicateLink {
                let ref = NodeRef(dir: dir, fileIndex: index)
                everything.append((ref.path, ref))
            }
            for sub in dir.subdirs {
                everything.append((sub.path, NodeRef(sub)))
                pending.append(sub)
            }
        }
        let rootName = (result.root.path as NSString).lastPathComponent
        let words = [
            "proj1/", "proj1/node", "node_modules/a", "modules/pkg", "PKG/NODE_MODULES/B",
            "/proj", "src/main.js", "j/s", "/big", "\(rootName)/big", "\(rootName)/",
            "oj1/src/m", "node_modules/pkg/node_modules/", "/", "proj1/node_modules/a.js",
            "x/y/z",
        ]
        var wrong: [String] = []
        for word in words {
            let plain = Set(
                everything.filter { $0.path.lowercased().contains(word.lowercased()) }
                    .map(\.ref)
            )
            let found = find(word, limit: 1_000)
            if Set(found.rows) != plain || found.matches != plain.count {
                wrong.append(
                    "“\(word)”: \(found.rows.count) rows and "
                        + "\(String(describing: found.matches)) counted, "
                        + "\(plain.count) have it in their path"
                )
            }
        }
        check(
            "a word in the path finds exactly what has it in its path",
            wrong.isEmpty,
            wrong.joined(separator: "; ")
        )

        let plain = find("")
        check(
            "with nothing asked for, the list is the largest files and nothing is counted",
            plain.matches == nil && plain.rows.count == 7
                && plain.rows.allSatisfy { !$0.isDirectory }
                && names(plain).first == "big.bin",
            said(plain)
        )
        check(
            "the largest-files list never has a folder in it, whatever is typed",
            result.largestFiles(matching: "node_modules").isEmpty
                && result.largestFiles(matching: "proj1/").count == 3
                && result.largestFiles(matching: "kind:folder").count == 7
                && result.largestFiles(matching: "kind:folder")
                    .allSatisfy { !$0.isDirectory },
            "\(result.largestFiles(matching: "kind:folder").map(\.name))"
        )
        check(
            "and with nothing typed it is the same list it always was",
            result.largestFiles(limit: 100, metric: .logical).map(\.name) == names(plain),
            "\(result.largestFiles(limit: 100, metric: .logical).map(\.name))"
        )
    }

    /// The same, through the File View: what it lists, what it says it found,
    /// and that a folder it found can be acted on like any other row.
    @MainActor
    private static func testTheFileViewSearches() {
        let base = scratch("file-view-search")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try buildSearchFixture(at: base)
        } catch {
            check("the search fixture can be built", false, "\(error)")
            return
        }
        let model = AppModel()
        model.customFolder = base.path
        guard let result = loadSynchronously(into: model) else { return }
        pumpUntilFileRowsSettle(model, expecting: 7)
        check(
            "with nothing typed the File View counts nothing",
            model.fileTally == nil && model.fileRows.count == 7,
            "tally \(String(describing: model.fileTally))"
        )

        model.beginSearch()
        check(
            "⌘F brings the File View to the front and asks for the keyboard",
            model.tab == .files && model.takeFilterFocus(),
            "tab \(model.tab)"
        )
        check(
            "asked once, the filter takes it once",
            !model.takeFilterFocus(),
            ""
        )

        model.fileQuery = "node_modules"
        model.refreshFileRows(immediately: true)
        pumpUntilFileRowsSettle(model, expecting: 3)
        let found = model.fileRows
        let onDisk = found.prefix(2).reduce(UInt64(0)) { $0 + $1.alloc }
        check(
            "a folder search lists folders, each with the folder it is in",
            found.count == 3 && found.allSatisfy { $0.ref.isDirectory }
                && found.first?.name == "node_modules"
                && found.first?.directory == result.root.path + "/proj1",
            "\(found.map { $0.directory + "/" + $0.name })"
        )
        check(
            "and says how many it found and what they take up, counted once",
            model.fileTally == SearchTally(matches: 3, folders: 3, bytes: onDisk),
            "tally \(String(describing: model.fileTally)), expected 3 and \(onDisk)"
        )

        // The one inside another goes: a row like any other.
        guard let nested = found.first(where: { $0.directory.hasSuffix("/pkg") })?.ref
        else {
            check("the nested folder is among the rows", false, "\(found.map(\.directory))")
            return
        }
        model.selection = [nested]
        check(
            "a folder the search found can be removed with the delete key",
            model.canUseDeleteKeys && model.selectionOnShow == [nested],
            "on show \(model.selectionOnShow.map(\.name))"
        )
        model.trashSelection()
        pumpUntilDeleteSettles(model)
        pumpUntilFileRowsSettle(model, expecting: 2)
        check(
            "which takes its row out and counts again",
            model.fileRows.count == 2 && model.fileTally?.matches == 2
                && !FileManager.default.fileExists(atPath: base.path
                    + "/proj1/node_modules/pkg/node_modules"),
            "\(model.fileRows.count) rows, tally \(String(describing: model.fileTally))"
        )
        // The folder it was inside is a row as well, and has less in it now.
        let outer = model.fileRows.first { $0.directory.hasSuffix("/proj1") }
        check(
            "and the row of the folder it was in shows what that folder holds now",
            outer != nil && outer?.alloc == outer?.ref.alloc
                && (outer?.alloc ?? 0) < (found.first?.alloc ?? 0),
            "row \(outer?.alloc ?? 0), folder \(outer?.ref.alloc ?? 0), was "
                + "\(found.first?.alloc ?? 0)"
        )

        // A search lists a folder and things inside it as rows of their own.
        // Sorted so that one of those comes above its folder, removing the
        // folder used to put the selection where that row had been.
        model.fileQuery = "kind:folder"
        model.fileSort = [KeyPathComparator(\FileRow.name)]
        model.refreshFileRows(immediately: true)
        pumpUntilFileRowsSettle(model, expecting: 6)
        let byName = model.fileRows.map(\.name)
        guard let proj1 = model.fileRows.first(where: { $0.name == "proj1" })?.ref,
            let proj2 = model.fileRows.first(where: { $0.name == "proj2" })?.ref
        else {
            check("the folders are listed by name", false, "\(byName)")
            return
        }
        check(
            "by name, folders inside proj1 are listed above it",
            byName == ["node_modules", "node_modules", "pkg", "proj1", "proj2", "src"],
            "\(byName)"
        )
        model.selection = [proj1]
        model.trashSelection()
        pumpUntilDeleteSettles(model)
        pumpUntilFileRowsSettle(model, expecting: 2)
        check(
            "removing it leaves the selection on the row that took its place",
            model.selection == [proj2]
                && model.fileRows.map(\.name) == ["node_modules", "proj2"],
            "selected \(model.selection.map(\.name)), rows \(model.fileRows.map(\.name))"
        )
        model.fileSort = [KeyPathComparator(\FileRow.alloc, order: .reverse)]

        model.fileQuery = "js >zz"
        model.refreshFileRows(immediately: true)
        pumpUntilFileRowsSettle(model, expecting: 0)
        check(
            "a filter that can't be read lists nothing, and is named",
            model.fileRows.isEmpty && model.fileTally?.matches == 0
                && model.fileSearch.unreadable == [">zz"],
            "\(model.fileRows.count) rows, unreadable \(model.fileSearch.unreadable)"
        )

        model.clearSearch()
        pumpUntilFileRowsSettle(model, expecting: 4)
        check(
            "clearing the filter goes back to the largest files, uncounted",
            model.fileQuery.isEmpty && model.fileTally == nil
                && model.fileRows.count == 4
                && model.fileRows.allSatisfy { !$0.ref.isDirectory },
            "\(model.fileRows.count) rows, tally \(String(describing: model.fileTally))"
        )
    }

    /// A row picked from somewhere other than the table — a tile on the map,
    /// a line in the list of marks, an arrow key stepping out to the folder
    /// above — is selected in a table that may be showing rows nowhere near
    /// it. Selected and out of sight is not found.
    @MainActor
    private static func testARevealedRowIsScrolledIntoView() {
        let base = scratch("reveal")
        defer { try? FileManager.default.removeItem(at: base) }
        do {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("many"),
                withIntermediateDirectories: true
            )
            for i in 0..<400 {
                try write(base.appendingPathComponent("many/f\(i).dat"), bytes: 10)
            }
        } catch {
            check("the reveal fixture can be built", false, "\(error)")
            return
        }

        let model = AppModel()
        model.customFolder = base.path
        model.dismissedAccessPrompt = true
        let hosting = NSHostingView(rootView: ContentView(model: model))
        let frame = NSRect(x: 0, y: 0, width: 1300, height: 760)
        hosting.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFront(nil)
        defer { window.close() }

        guard let result = loadSynchronously(into: model),
            let many = result.root.subdir(named: "many")
        else { return }
        // By name, so which row is last doesn't hang on four hundred files of
        // one size: f399 sorts after f398, four hundred rows down.
        model.treeSort = [TreeSort(.name, order: .forward)]
        model.setExpanded(many, true)
        // Until the table has the rows, which is what the rest asks it about.
        pumpUntil {
            tables(under: hosting).contains { $0.numberOfRows == model.treeRows.count }
        }

        guard let last = many.files.firstIndex(where: { $0.name == "f399.dat" })
        else {
            check("the reveal fixture scanned", false, "no f399.dat")
            return
        }
        let target = NodeRef(dir: many, fileIndex: last)
        guard let row = model.treeRows.firstIndex(where: { $0.ref == target }),
            let table = tables(under: hosting).first(where: {
                $0.numberOfRows == model.treeRows.count
            })
        else {
            check(
                "the tree's table can be found to ask what it is showing",
                false,
                "\(tables(under: hosting).map(\.numberOfRows)) rows in the tables "
                    + "found, \(model.treeRows.count) in the model"
            )
            return
        }
        func showing() -> String {
            let visible = table.rows(in: table.visibleRect)
            return "row \(row) of \(model.treeRows.count); showing "
                + "\(visible.location)–\(visible.location + visible.length - 1)"
        }
        check(
            "the last of four hundred rows starts out of sight",
            !table.rows(in: table.visibleRect).contains(row),
            showing()
        )
        model.revealInTree(target)
        pumpUntil { table.rows(in: table.visibleRect).contains(row) }
        check(
            "revealing a row far down the tree scrolls it into view",
            table.rows(in: table.visibleRect).contains(row),
            showing()
        )
        check(
            "and it is the row a scroll that was put off would still go to",
            model.isStillRevealing(target),
            "selected \(model.selection.map(\.name))"
        )
        // A click somewhere else in the meantime: a scroll arriving after it
        // would carry what is now selected off the screen.
        model.selection = [NodeRef(result.root)]
        check(
            "until something else is selected",
            !model.isStillRevealing(target),
            "selected \(model.selection.map(\.name))"
        )

        // Asked for from another tab, as "Show in Tree" in the File View's
        // menu does it. The tree's table is not on screen to be told, and is
        // a new table when it comes back.
        model.show(.files)
        // Until the tree's table has gone, so that the one found below is
        // the new one and not the one that was just scrolled.
        pumpUntil {
            !tables(under: hosting).contains { $0.numberOfRows == model.treeRows.count }
        }
        model.show(.tree)
        model.revealInTree(target)
        func treeTable() -> NSTableView? {
            tables(under: hosting).first { $0.numberOfRows == model.treeRows.count }
        }
        pumpUntil { treeTable().map { $0.rows(in: $0.visibleRect).contains(row) } == true }
        guard let again = treeTable() else {
            check("the tree's table is back after a change of tab", false, "")
            return
        }
        let visible = again.rows(in: again.visibleRect)
        check(
            "a row asked for from another tab is in view when the tree comes back",
            model.tab == .tree && visible.contains(row),
            "row \(row); showing \(visible.location)–"
                + "\(visible.location + visible.length - 1)"
        )

        deletePermanently(model, [target])
        check(
            "a row that has been deleted is not one to scroll to",
            !model.isStillRevealing(target),
            ""
        )
        model.revealInTree(NodeRef(many))
        model.startScan()
        check(
            "nor is anything in a scan that is being replaced",
            !model.isStillRevealing(NodeRef(many)) && model.takeRevealTarget() == nil,
            ""
        )
        pumpUntilSettled(model)
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
