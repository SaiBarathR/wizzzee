import CRemoveFile
import Darwin
import Foundation

/// Deletes a file or a whole folder for good, saying how far it has got and
/// stopping part-way when asked.
///
/// `FileManager.removeItem` does the same work with `removefile(3)` and keeps
/// what it learns on the way to itself: a folder of a million files was one
/// call that reported nothing until it returned and could not be interrupted.
/// Calling `removefile` directly gets a callback per entry, which is where
/// both the progress and the Stop come from.
///
/// Two more things differ from `removeItem`, both on purpose. A failure does
/// not end the run: what can be removed is, as `rm -rf` does it, and the
/// caller is told what couldn't be. And a tree deeper than `PATH_MAX`, which
/// `removeItem` refuses outright, is removed.
enum Removal {
    /// How much has gone so far.
    struct Tally: Equatable {
        /// Files and folders removed.
        var items = 0
        /// The space the files among them occupied.
        var bytes: UInt64 = 0
    }

    /// Lets another thread ask a removal to stop at the next entry.
    final class Stop: @unchecked Sendable {
        private let lock = UnfairLock()
        private var requested = false

        var isRequested: Bool { lock.withLock { requested } }
        func request() { lock.withLock { requested = true } }
    }

    struct Outcome {
        var tally = Tally()
        /// False when any of it is still on disk, whatever the reason.
        var isGone = false
        /// True when it ended because it was asked to.
        var wasStopped = false
        /// Entries that could not be removed. A folder left behind only
        /// because something inside it stayed is not counted again.
        var failures = 0
        /// The first of them, for the message.
        var firstFailure: (path: String, code: Int32)?
    }

    /// Removes `path`, calling `onProgress` on the calling thread a few times
    /// a second with the running tally.
    ///
    /// A symbolic link is removed, never followed, and nothing on another
    /// volume is touched: a mount point inside the folder is left where it
    /// is, with the folders above it.
    static func remove(
        _ path: String,
        stop: Stop = Stop(),
        onProgress: (Tally) -> Void = { _ in }
    ) -> Outcome {
        // Named with a slash on the end, a link to a folder is resolved
        // before `removefile` ever sees it, and what goes is everything in
        // the folder it points at. No path built from the scan tree ends in
        // one; this is so that none handed in from anywhere else can either.
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        return withoutActuallyEscaping(onProgress) { report in
            let run = Run(stop: stop, report: report)
            run.pass(over: path, flags: REMOVEFILE_RECURSIVE)
            // Without this flag a path past `PATH_MAX` fails where it stands,
            // and with it `removefile` changes the working directory of the
            // whole process as it descends. So it is kept for the trees that
            // need it, which are few, and that are then worth it.
            if run.metLongPath && !run.wasStopped {
                run.forgetFailures()
                run.pass(
                    over: path,
                    flags: REMOVEFILE_RECURSIVE | REMOVEFILE_ALLOW_LONG_PATHS
                )
            }

            var outcome = Outcome()
            outcome.tally = run.tally
            outcome.wasStopped = run.wasStopped
            outcome.failures = run.failures
            outcome.firstFailure = run.firstFailure
            var info = stat()
            outcome.isGone = lstat(path, &info) != 0 && errno == ENOENT
            // Nothing there to begin with is the state that was asked for.
            if outcome.isGone {
                outcome.failures = 0
                outcome.firstFailure = nil
            }
            return outcome
        }
    }

    /// What the callbacks share for the length of one `remove`.
    private final class Run {
        var tally = Tally()
        var failures = 0
        var firstFailure: (path: String, code: Int32)?
        var metLongPath = false
        var wasStopped = false

        private let stop: Stop
        private let report: (Tally) -> Void
        private var lastReport = DispatchTime.now().uptimeNanoseconds
        /// A twentieth of a second: often enough to read as movement, and far
        /// enough apart that the main thread isn't sent a message per file.
        private static let reportInterval: UInt64 = 50_000_000

        init(stop: Stop, report: @escaping (Tally) -> Void) {
            self.stop = stop
            self.report = report
        }

        func forgetFailures() {
            failures = 0
            firstFailure = nil
            metLongPath = false
        }

        func pass(over path: String, flags: Int) {
            guard let state = removefile_state_alloc() else {
                note(failureAt: path, code: ENOMEM)
                return
            }
            defer { removefile_state_free(state) }
            let context = Unmanaged.passUnretained(self).toOpaque()

            let removed: removefile_callback_t = { state, _, context in
                guard let context else { return Int32(REMOVEFILE_PROCEED) }
                let run = Unmanaged<Run>.fromOpaque(context).takeUnretainedValue()
                return run.removed(state)
            }
            let failed: removefile_callback_t = { state, path, context in
                guard let context else { return Int32(REMOVEFILE_PROCEED) }
                let run = Unmanaged<Run>.fromOpaque(context).takeUnretainedValue()
                var code: Int32 = 0
                removefile_state_get(state, UInt32(REMOVEFILE_STATE_ERRNO), &code)
                run.note(failureAt: path.map { String(cString: $0) } ?? "", code: code)
                return run.shouldStop()
            }
            removefile_state_set(
                state,
                UInt32(REMOVEFILE_STATE_STATUS_CALLBACK),
                unsafeBitCast(removed, to: UnsafeRawPointer.self)
            )
            removefile_state_set(
                state, UInt32(REMOVEFILE_STATE_STATUS_CONTEXT), context)
            removefile_state_set(
                state,
                UInt32(REMOVEFILE_STATE_ERROR_CALLBACK),
                unsafeBitCast(failed, to: UnsafeRawPointer.self)
            )
            removefile_state_set(
                state, UInt32(REMOVEFILE_STATE_ERROR_CONTEXT), context)

            let result = removefile(path, state, removefile_flags_t(flags))
            // Each entry's failure went to the callback. What comes back here
            // without one is the path as a whole being refused, and a path
            // that is already gone is no failure at all.
            if result != 0, failures == 0, !wasStopped, errno != ENOENT {
                note(failureAt: path, code: errno)
            }
            report(tally)
        }

        /// One entry has gone. The traversal took its size before removing it,
        /// so the space it held costs no second look at the disk.
        private func removed(_ state: removefile_state_t?) -> Int32 {
            tally.items += 1
            var entry: UnsafeMutablePointer<FTSENT>?
            if removefile_state_get(state, UInt32(REMOVEFILE_STATE_FTSENT), &entry) == 0,
                let entry, Int32(entry.pointee.fts_info) != FTS_DP,
                let info = entry.pointee.fts_statp
            {
                tally.bytes += UInt64(max(0, info.pointee.st_blocks)) * 512
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastReport >= Self.reportInterval {
                lastReport = now
                report(tally)
            }
            return shouldStop()
        }

        private func shouldStop() -> Int32 {
            guard stop.isRequested else { return Int32(REMOVEFILE_PROCEED) }
            wasStopped = true
            return Int32(REMOVEFILE_STOP)
        }

        func note(failureAt path: String, code: Int32) {
            if code == ENAMETOOLONG { metLongPath = true }
            // A folder is still there because something in it is, and that
            // something has been counted already.
            if code == ENOTEMPTY && failures > 0 { return }
            failures += 1
            if firstFailure == nil { firstFailure = (path, code) }
        }
    }
}
