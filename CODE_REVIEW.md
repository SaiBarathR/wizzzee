# Wizzzee code review — 2026-08-07

Review run with Cursor CLI (`cursor-agent`, Opus 5 thinking-high, read-only plan
mode) over all of `Sources/Wizzzee/` at commit `fd3a9aa`, then every finding
re-verified against the source by hand before anything was changed.

**Cursor reported 18 findings.** Verification confirmed 15 as stated, corrected 2
where the mechanism or severity was wrong, and rejected 1 outright.

| Severity | Reported | Confirmed | Corrected | Rejected | Fixed | Partly fixed | Deferred |
|---|---|---|---|---|---|---|---|
| Critical | 1 | 1 | — | — | 1 | — | — |
| High | 3 | 2 | 1 | — | 2 | 1 | — |
| Medium | 8 | 6 | 1 | 1 | 6 | — | 1 |
| Low | 6 | 6 | — | — | 6 | — | — |
| **Total** | **18** | **15** | **2** | **1** | **15** | **1** | **1** |

Finding 2 is partly fixed: the number the delete dialog promises is now correct
in both directions, but the tree's own totals after deleting the surviving name
of a hard-linked pair still under-report. The reason is in that section.

Validation after the fixes: `swift build` succeeds with no new warnings (the one
`SendableClosureCaptures` warning on the scan dispatch in `AppModel.startScan`
is present in the baseline too, confirmed by building a full stash of it),
self-test **113/113** in both debug and release (was 88 — 25 new checks). No scan
or layout regression: `~/Library` (427k files) scans in 6.1–6.3 s before and
after, treemap layout 19–20 ms before and after, unreadable-directory count
unchanged at 147–149.

---

## Critical

### 1. Nothing prevented deleting the scan root, including `/` or `$HOME` — FIXED

`AppModel.scanFinished` sets `selection = [NodeRef(scanned.root)]`, so the root
is **already selected** the moment a scan lands. `ItemContextMenu` offered "Move
to Trash" / "Delete Permanently…" for it unconditionally, and
`FileActions.isSystemProtected` returns **false** for `/` and for `/Users/me` —
neither carries any of `protectedPrefixes` (`/System/`, `/usr/`, `/bin/`,
`/sbin/`, `/private/var/db/`) as a prefix.

Scan `~`, right-click the first row (already selected), pick "Delete
Permanently…". The dialog read *"Permanently delete "/Users/me" and 412,309 items
inside it?"* and confirming called `FileManager.removeItem(atPath: "/Users/me")`,
which succeeds. With the boot volume selected it recursively deletes everything
not SIP-protected before erroring out. `DirNode.isRoot` already existed but was
used only for a display name in `TreeViewTab`.

**Fix** — three independent layers, so no single call site is load-bearing:

- `FileActions.isUndeletableRoot` refuses `/`, `/Volumes/<name>`,
  `/Users/<name>`, and `NSHomeDirectory()`, with trailing slashes normalised.
  Both `moveToTrash` and `deletePermanently` throw `ActionError.undeletableRoot`
  before touching the filesystem.
- `AppModel.deletionRefusal(for:)` additionally refuses `ref.dir.isRoot` — only
  the model knows what a scan was rooted at, so a scan of `~/Projects` protects
  that folder too. `performBatch` filters on it and reports the refusal.
- `ItemContextMenu` no longer offers either destructive action for a refused
  item, showing "A root folder — can't be removed" in their place.

**Tests added** — `testScanRootIsNeverDeletable` asserts the root is selected on
completion, is refused, survives both a permanent delete and a trash, leaves its
totals untouched, and that the refusal is explained rather than silent.
`testVolumeAndHomeRootsAreRefused` covers `/`, other users' homes, volume mount
points, trailing slashes, and that ordinary paths inside them stay deletable.

---

## High

### 2. Hard-linked files were mis-accounted on delete, in both directions — PARTLY FIXED

`detachFile` subtracts `0` for a file marked `isDuplicateLink`, but
`reclaimableSize` counted every ref at full `.size`. Using the self-test's own
fixture: deleting `link.dat` promised "40 KB reclaimed" and freed nothing.
Deleting `five.dat` — the *non-duplicate* name of the same inode — promised the
same 40 KB and subtracted it from every ancestor, while `link.dat` still held all
40 KB on disk, so the tree under-reported and `df` never moved.

The scanner only marks the *second* name it reaches as a duplicate, so the first
was indistinguishable from an ordinary file. `FileEntry` had no link count to
tell them apart, even though `BulkEnumerator` already decodes
`ATTR_FILE_LINKCOUNT`.

**Fixed: the promise.** `FileEntry.linkCount` is now carried through from the
bulk read, with `sharesStorage` true when a file is either an already-counted
duplicate *or* has more than one name. `reclaimableSize` counts those as freeing
nothing, and the confirmation dialog says so explicitly rather than quoting a
figure `df` will disagree with. This covers both directions — neither name of a
pair now promises space it cannot deliver.

**Not fixed: the totals afterwards.** `detachFile` still subtracts the full size
when the *surviving* name is the one deleted, so the tree under-reports relative
to disk until a rescan. Correcting it needs to know whether another name for the
same inode is still inside the scan, and `FileEntry` deliberately does not store
the inode — it is sized to hold several million files. The alternative, always
subtracting zero for a linked file, is wrong the other way whenever the other
name lives outside the scan. That trade-off is a design decision, not a
mechanical fix; see `docs/plan-0.3.md`.

**Tests added** — `testHardLinkPromisesNoSpace` asserts both names of the pair
promise zero, that the dialog is told the space is shared, and that an ordinary
file still promises its own size.

### 3. Every treemap mouse-move forced a full custom redraw — FIXED (mechanism corrected)

Cursor's account was partly wrong. It claimed `mouseMoved` "calls `onHover`,
which writes the `@Published var hoveredRef`… every view re-evaluates its body on
each event". The `onHover` call was **already** guarded by
`if found?.ref != hovered?.ref`, so the publish only happened on an actual hover
*change*, not per event.

What was real: `needsDisplay = true` fired unconditionally, so every one of 100+
events per second ran a full `draw(_:)` — re-stroking every group border,
re-laying out an `NSAttributedString` per labelled folder with an O(n²)
`placed.contains(where:)` overlap test, and a linear `rect(for: selection)` scan.

**Fix** — invalidate only when the hovered cell changed or a tooltip is on screen
and has to follow the pointer. Sweeping across empty space no longer redraws.
The O(n²) label test and the linear hit-test are left alone; they are bounded by
what is *drawable* (4,343 tiles on a `~/Library` map) and measure 19–20 ms in
release, not the 239 ms Cursor quoted from a debug build.

### 4. Destructive I/O and a full-tree barrier both run on the main actor — FIXED

Confirmed exactly as reported. `performBatch` was a method on the `@MainActor`
`AppModel`, so `removeItem`/`trashItem` ran on the main thread, and `detach`
called `treeQueue.sync {}` to fence against an in-flight File View walk. Deleting
a large tree froze the UI with no spinner, no progress and no cancel, for long
enough that the responsiveness watchdog could kill the app part-way and leave a
half-removed tree behind totals that were never updated.

**Fix** — the batch runs off the main actor, one target at a time, each on a
detached task. A `.deleting` progress state drives a determinate bar and a Stop
button in the status bar; a second batch is refused while one is running, the
way `startScan` already refused a second scan.

Two honest limits, both documented in the code: progress is counted in top-level
targets rather than bytes, because `FileManager.removeItem` recurses into a
directory itself and reports nothing on the way; and Stop takes effect at the
next target, because a single `removeItem` cannot be interrupted.

**The `treeQueue.sync {}` barrier stays.** Cursor recommended replacing it with a
`treeRevision` generation check, but that is not sufficient — the walk checks the
revision only when *delivering* its result, while during traversal it is reading
the very `files` arrays the delete is about to mutate. Removing the barrier
trades a slow delete for a data race. Instead a `WalkToken` lets a walk already
running give up part-way, so the barrier waits microseconds rather than a full
pass over every file in the scan.

**Tests added** — `testDeleteReturnsBeforeItHasFinished` asserts the call returns
with the work still pending and nothing yet removed (deterministic: the task body
cannot run until the main actor is yielded), that progress starts at zero, that a
second batch is refused, and that the tree is correct once it settles.
`testDeleteCanBeStopped` asserts a batch stopped before its first item leaves
everything on disk and the totals untouched, and that the model is usable
afterwards rather than wedged. The nine existing delete checks now pump the run
loop through `trash(_:_:)` / `deletePermanently(_:_:)` helpers.

---

## Medium

### 5. `reclaimableSize` ignored the active size metric — FIXED

It reduced over `$1.size` unconditionally while `sizeMetric` defaults to
`.allocated` and the whole UI is built around that default. Selecting a 200 GB
sparse disk image that occupies 8 GB made the permanent-delete dialog state
*"200.0 GB will be reclaimed. This bypasses the Trash and cannot be undone."* —
the exact failure the `sizeMetric` comment says the default was chosen to avoid.

**Fix** — `reclaimableSize` now measures with the metric on show.
`testAncestorDedupe` was updated (it asserted the old logical-size behaviour) and
a second check pins the metric-following behaviour in both directions.

### 6. `isSystemProtected` blanket-blocked the whole data volume — FIXED (partly rejected)

`/System/Volumes/Data` is the mount point of the writable APFS data volume and a
legitimate scan target — it is exactly what a scan of `/` skips to avoid
double-counting firmlinks, so seeing inside it means scanning it directly. Every
path in such a scan begins `/System/`, so every delete was refused with a flatly
false claim that the user's own home directory is on the sealed read-only volume.

Cursor also recommended switching to component-wise matching "so `/Systemic/foo`
is not caught either". **That half is unnecessary** — every entry in
`protectedPrefixes` already ends in `/`, so `/Systemic/foo` never matched. A
regression check now pins that.

**Fix** — `/System/Volumes/Data` joins `/usr/local` as a writable exception,
matched as a whole path or a `/`-terminated prefix.

### 7. A directory that failed part-way through enumeration was silently under-counted — FIXED

`BulkEnumerator.enumerate` returns `errno` on the first `getattrlistbulk`
failure, keeping whatever it had already visited, and did not retry `EINTR`. The
caller only flagged the directory when the failure left it looking *completely*
empty: `if err != 0 && files.isEmpty && node.subdirs.isEmpty`. A directory of
40,000 entries whose third batch returned `EINTR` yielded ~3,000 entries and was
reported as fully scanned — quietly wrong, which for a measuring tool is worse
than visibly incomplete.

**Fix** — `EINTR` is retried in place rather than ending the walk. Any other
non-zero errno now flags the directory regardless of how much was collected, with
a new `DirExclusion.partiallyRead` case (shown as "partly read" in the tree)
kept distinct from `permissionDenied` so the two causes stay legible.

### 8. `scanSynchronously` conflated four outcomes into `nil` — FIXED

It returned `nil` for cancelled, nonexistent, not-a-directory and unreadable
alike, and the caller read the mutable `wasCancelled` property separately to tell
them apart. The two reads were not atomic, and "the folder doesn't exist" and
"you aren't allowed to read it" surfaced as the same *"Couldn't scan …"* — with
Full Disk Access, the single most common cause, unnamed despite the app having a
whole banner for it.

**Fix** — replaced with `ScanEngine.Outcome` (`completed` / `cancelled` /
`notADirectory` / `unreadable(errno:)`), and `wasCancelled` is gone. `ENOENT`,
`EACCES`/`EPERM` and everything else now produce distinct messages, and the
permission case names Full Disk Access. `Outcome.result` / `.failureDescription`
keep the two headless CLI call sites terse.

### 9. The extension legend re-sorted the whole table on every body evaluation — FIXED

`ExtensionLegend.stats` was a computed property calling
`all.sorted { $0.alloc > $1.alloc }` over every distinct extension in the scan —
thousands on a real disk — before taking `prefix(40)`. Because the view observes
`AppModel`, that ran on every publish.

Cursor's claim that this happens "a hundred times a second while hovering" is
overstated for the same reason as finding 3 — `hoveredRef` is only written on a
hover *change*. It still ran far more often than the ranking could change.

**Fix** — the allocated-order top 40 is derived once in `ScanResult.init`, where
the size-descending order already lived. It cannot change for a given scan.

### 10. The File View filter allocated per candidate file, per keystroke — FIXED

`containsCaseInsensitive` did `let hay = Array(utf8)` — a heap allocation and a
full copy — on every call, and with a `/` in the query `largestFiles` rebuilt
`dir.path` (an O(depth) reconstruction from the parent chain) for every directory
holding files. The comment above it correctly rejects
`localizedCaseInsensitiveContains` for being slow, then reintroduced per-call
allocation.

**Fix** — both sides are now read through `withContiguousStorageIfAvailable` with
a copying fallback only for `NSString`-bridged strings, so the search allocates
nothing. The walk carries each directory's path down as it descends, extending
the parent's string instead of rebuilding an absolute path per directory.

### 11. Unbounded recursion over tree depth on 512 KB stacks — CORRECTED, hardened anyway

Cursor reported this as a crash: *"a pathological tree — trivially created by a
runaway script doing `mkdir a && cd a` in a loop — reaches several thousand
levels and overflows the stack, crashing the app with `EXC_BAD_ACCESS`."*

**Measured, and it does not happen.** The depth the scanner can reach is bounded
by `PATH_MAX`, not by the tree: the workers `open` an *absolute* path per
directory, so anything past ~1024 bytes of path is unreachable however deep it
was built. A 3,000-level tree was built (via relative `mkdir`; absolute path
6,104 chars) and scanned: the walk reached **460 folders** and reported the
remainder as unreadable, exactly as it should. At ~460 frames the recursion uses
well under 100 KB of a 512 KB stack.

The three traversals were converted to explicit worklists anyway — `aggregate`
as a two-phase post-order, `remapExtensionIndices` and `largestFiles` as plain
stacks. It removes a latent hazard for free, and the `largestFiles` conversion is
what carries the path-caching fix in finding 10. Severity is **low**, not medium.

**Test added** — `testDeepestReachableTreeIsWalked` builds the deepest tree that
fits under `PATH_MAX` and asserts all three traversals reach the bottom with
correct totals and no unreadable directories.

### 12. Treemap layout runs synchronously on the main thread — DEFERRED

Confirmed: `TreemapLayout.build` walks the live tree, allocating and sorting a
`[NodeRef]` per visited directory, on the main thread; only rasterisation goes to
`renderQueue`. `setFrameSize` re-triggers it every 80 ms while the splitter is
dragged.

Cursor's 239 ms figure is a **debug** measurement. In release the same
`~/Library` layout is **19–20 ms** (4,343 tiles / 442 folders), which is not a
visible stall. Fixing it properly means a `Sendable` snapshot of the subtree so
both layout and render can leave the main thread — a real refactor that also
retires the `TreemapModel.ancestors` pinning hazard. Scheduled as item 3 of the
0.3 plan.

---

## Low — all fixed

| # | Finding | Fix |
|---|---|---|
| 13 | Double-clicking a collapsed folder tile zoomed to its **parent**. A folder too small or too deep to subdivide is a directory cell with *no frame of its own*, so the fallback found the enclosing frame. At the map's root it did nothing at all, leaving no way to drill past `maxDepth`. | `mouseDown` matches a directory *cell* before falling back to the enclosing frame. |
| 14 | A progress callback could land after the scan was reported complete — `progressTimer.cancel()` doesn't wait for a handler already running, and that handler ends in `DispatchQueue.main.async { self?.progress = snapshot }`. | Two-sided: `scanFinished` resets `progress`, *and* the assignment is guarded on `phase == .scanning`. The reset alone only covered ticks already queued ahead of `scanFinished`; the guard closes the case of one enqueued after it. |
| 15 | Pressing Stop as a scan finished discarded the completed result: `workStack` was cleared after `group.wait()` but `isCancelled` checked after that, so a cancel in the window found nothing to stop yet still set the flag. | `WorkStack` now records whether `stop()` — rather than the work running out — is what ended it, and only that counts as cancellation. Making the two reads atomic was *not* sufficient; the flag is global and the cancel genuinely arrived after the walk drained. |
| 16 | Expansion state keyed on `ObjectIdentifier`, which is an address and reusable once a delete frees the node. Not currently reachable (no `DirNode`s are allocated between a delete and the next scan, which clears the set) but a live footgun. | `DirNode.id` — a process-monotonic counter — is the key instead. Stale entries are now harmless rather than collidable. |
| 17 | ⌘R and the Scan button silently did nothing mid-scan: `startScan` opens with `guard phase != .scanning`, and the menu item was never disabled. | The Rescan item is disabled while `phase == .scanning`, so the shortcut reads as unavailable rather than broken. |
| 18 | A stale hover outline survived a resize-triggered relayout — `hovered = nil` was done in `apply(root:metric:revision:)`, which the `setFrameSize` debounce doesn't go through. | Cleared at the top of `rebuild()`. The `onHover(nil)` notification is dispatched async, never inline, because `rebuild()` is reachable from `updateNSView` and publishing model state inside a SwiftUI view update is not allowed. |

---

## What Cursor got wrong

Worth recording, because all three would have led to unnecessary work:

1. **Finding 11 (stack overflow)** — reported as a crash reachable by a runaway
   `mkdir` loop. `PATH_MAX` caps the reachable depth at ~460 levels, measured.
   Not a crash; hardened anyway.
2. **Findings 3 and 9 (hover invalidation)** — both claimed a `@Published` write
   per mouse-*event*. The `onHover` call was already guarded to fire only on a
   hover *change*. The redraw cost was real; the publish storm was not.
3. **Finding 6 (component matching)** — recommended splitting paths on `/` so
   `/Systemic/foo` isn't caught by `/System/`. The prefixes already end in `/`,
   so it never was.

Two performance numbers in the report (239 ms treemap layout, "sorts a
multi-thousand-element array a hundred times a second") came from a debug build
and from the mistaken publish-per-event model respectively. The release figure is
19–20 ms.

## What was left alone

Both deferred items are UI-thread work with no data-correctness consequence, and
both need more than a minimal edit. They open `docs/plan-0.3.md`.

Cursor's own summary of the codebase is worth keeping: it traced the work-stack
idle accounting and could not deadlock it, confirmed the squarify implementation
always advances, confirmed `SizeHeap` short-circuits before touching `sizes[0]`,
and confirmed the `unowned(unsafe) var parent` hazard is genuinely handled by
`TreemapModel` pinning its root's ancestors. The problems clustered in one place:
the destructive path, which the self-test probed for *stale* references but never
for a *valid* reference to the scan root.
