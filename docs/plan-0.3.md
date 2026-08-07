# Wizzzee 0.3 — release plan

Shipped: **0.3.0** (build 6) and **0.3.1** (build 7). Started from 0.2.3.

0.3 is a correctness release for the destructive path. 0.2.3 fixed the scanner
reporting the wrong *numbers*; this series fixes it offering the wrong *actions*
— a scan's root row is selected the moment a scan lands, and until 0.3.0 the
context menu would delete it.

Findings and verification are in [`../CODE_REVIEW.md`](../CODE_REVIEW.md).

---

## Status

**Landed** across four stacked branches for 0.3.0, plus one for 0.3.1.
Self-test 88 → 144.

| Area | Change |
|---|---|
| Safety | Volume, home and scan-root folders refused by `FileActions`, `AppModel` and the context menu |
| Accuracy | `reclaimableSize` honours the size metric and counts hard links as freeing nothing |
| Accuracy | `/System/Volumes/Data` no longer blanket-refused as read-only |
| Accuracy | Partly-read directories flagged rather than reported complete; `EINTR` retried |
| API | `ScanEngine.Outcome` replaces `nil` + `wasCancelled`; distinct messages per failure |
| Robustness | A Stop landing as a scan completes keeps the result |
| Performance | Legend ranking derived once per scan; filter search allocation-free; path built as the walk descends |
| UI | Collapsed-folder zoom, stale hover outline, late progress tick, ⌘R gating |
| Responsiveness | Deletes run off the main actor with progress, a Stop, and one batch at a time |
| Accuracy (0.3.1) | A hard link's surviving name takes over the bytes rather than the tree losing them |

**0.3.0 shipped** items 1 and everything in the table above. **0.3.1** adds item
2. Item 3 is still open, with a recommendation.

---

## 1. Move destructive I/O off the main actor — *done*

`performBatch` is a method on the `@MainActor` `AppModel`, so
`FileManager.removeItem` / `trashItem` run synchronously on the main thread, and
`detach` then calls `treeQueue.sync {}` to fence against an in-flight File View
walk. Deleting a large tree — a 200 GB `node_modules`, an Xcode `DerivedData`
with several hundred thousand entries — is tens of seconds to minutes of
`unlink(2)` with the run loop stopped: no spinner, no progress, no cancel, and
macOS's responsiveness watchdog may terminate the app mid-delete and leave a
half-removed tree behind a model whose totals were never updated.

**Shipped as** `fix/async-delete`. The batch now runs off the main actor, one
target at a time on a detached task, with a determinate bar and a Stop in the
status bar and a second batch refused while one runs.

Two limits are deliberate and written into the code: progress counts top-level
targets rather than bytes, because `removeItem` recurses into a directory itself
and reports nothing on the way; and Stop takes effect at the next target,
because one `removeItem` cannot be interrupted.

The `treeQueue.sync {}` barrier was **kept**, against the review's suggestion of
a `treeRevision` generation check. The walk tests the revision only when
delivering its result, but during traversal it reads the very arrays the delete
mutates — dropping the barrier trades a slow delete for a data race. A
`WalkToken` lets a running walk give up part-way instead, so the barrier waits
microseconds rather than a full pass over the scan.

**What was done**

1. The deletion loop moved to `await Task.detached { … }.value`, one target at a
   time, with the main actor applying `detach` to the successes afterwards.
   Paths are still resolved up front — that ordering is what the
   sibling-renumbering checks pin.
2. `AppModel.DeleteProgress` drives a determinate bar and a Stop in the status
   bar, which takes over the strip for as long as the batch runs.
3. A second batch is refused while one is in flight, since it would resolve its
   paths against a tree the first is still changing.
4. The nine existing delete checks now go through `trash(_:_:)` /
   `deletePermanently(_:_:)`, which pump the run loop the way
   `pumpUntilFileRowsSettle` already did for the File View.
5. `WalkToken` gives a running `largestFiles` walk a way to give up part-way,
   which is what keeps the retained barrier short.

All nine existing delete checks kept passing unchanged once routed through
run-loop-pumping helpers, and two new ones cover the asynchrony itself:
`testDeleteReturnsBeforeItHasFinished` and `testDeleteCanBeStopped`.

## 2. Hard-linked totals after a delete — *done, shipped in 0.3.1*

The other half of review finding 2. `detachFile` subtracted a file's full size
even when the surviving name of a hard-linked pair still held the bytes, so the
tree under-reported against disk until a rescan.

Three options were costed here, and **option 3 — the exact one — was taken**,
because the objection recorded against it turned out to be wrong.

That objection was memory: pairing two names needs the inode, and `FileEntry` is
allocated once per file, so an extra `UInt64` looked like +32 MB on a full-disk
scan. It isn't. The struct had six bytes of tail padding, and the link count was
sitting in a `UInt32` whose value is only ever compared against 1. Narrowing it
to a saturating `UInt8` paid for `fileID` exactly: **56 bytes before, 56 after**,
now asserted by `testFileEntryStaysNarrow` so a future field can't quietly round
it up to 64.

Options 1 and 2 were both rejected on correctness once that was clear. Option 1
leaves the tree disagreeing with the disk. Option 2 — subtract zero for any
linked file — breaks a stronger invariant: `detachFile` removes the entry from
its folder, so subtracting nothing leaves a folder total that no file in it
accounts for, and "a folder's total is the sum of its parts" stops holding.

**What it does now.** Removing one name of a hard-linked file walks the tree
once and does two things:

- Every surviving name loses a link. One left as the last name stops sharing its
  storage, so the delete dialog will promise its bytes again — without this the
  survivor would be credited with 9 KB by the tree and 0 by the dialog.
- If the departing name was the one carrying the bytes, a survivor takes over
  the count. The bytes move between the two folders' chains rather than leaving
  the tree, since they are still on disk.

When no other name is in the tree — a link whose partner lives outside the scan,
the Time Machine case — nothing is promoted and the subtraction stands, which is
correct: those bytes really have left the scanned tree.

## 3. Move treemap layout off the main thread — *still open*

`TreemapLayout.build` walks the live tree, allocating and sorting a `[NodeRef]`
per visited directory, on the main thread; only the rasterisation goes to
`renderQueue`. `setFrameSize` re-triggers it every 80 ms while the splitter is
dragged, and it also runs on every zoom, metric change and `treeRevision` bump.

**Measured cost is 19–20 ms** in release for `~/Library` (4,343 tiles, 442
folders) — not a visible stall. The 239 ms in the review was a debug build. A
folder with 200,000 entries in a single directory would be far worse, but that is
not the common case.

**Shape of the work** — snapshot the subtree into a `Sendable` value form (id,
weight, extIndex, children) once per `treeRevision`, then run both `build` and
`render` on `renderQueue` keyed by the existing `renderToken`. This also retires
the `TreemapModel.ancestors` pinning, which exists only because the layout holds
live `DirNode`s across a possible delete.

**Recommendation** — 0.3.2 or later. It is a real refactor of the layout's ownership
model with no correctness bug behind it, and 0.3 is stronger as a focused safety
release.

---

## Release checklist

Following [`releasing.md`](releasing.md):

1. `swift build && ./.build/debug/Wizzzee --selftest` — expect **144/144**.
2. Release build, then re-run the self-test against it. Confirm no scan
   regression: `--scan ~/Library` should stay at ~6 s / 427k files, and
   `--treemap ~/Library` at ~20 ms layout.
3. Bump `CFBundleShortVersionString` to `0.3.0` and `CFBundleVersion` to `6` in
   `Resources/Info.plist`.
4. Write `docs/releases/v0.3.0.md`. It is published verbatim as the release body,
   so it has to stand alone. Lead with the root-deletion fix — it is the reason
   to upgrade, and anyone who used the context menu on a root row on 0.2.x should
   be told plainly what it could do.
5. `./scripts/validate-release.sh v0.3.0`.
6. Optional dry run:
   `gh workflow run "Release macOS app" -f tag=v0.3.0 -f ref="$(git rev-parse main)"`.
7. Commit, tag `v0.3.0`, push with `--follow-tags`, watch the run.

## Release-notes outline for `v0.3.0.md` (shipped)

Mark it **worth upgrading to**, as 0.2.3 was, and lead with the safety fix.

- **Wizzzee could delete the folder you scanned.** The scan root is selected as
  soon as a scan finishes, and the right-click menu offered it "Move to Trash"
  and "Delete Permanently…" like any other row. Confirming on a scan of your home
  folder or a whole volume did exactly what it said. Volume roots, home folders
  and the scanned folder itself are now refused outright, and the menu no longer
  offers the actions.
- **The delete confirmation quoted the wrong amount.** It reported logical size
  while the app measures on-disk size by default, so a sparse disk image promised
  hundreds of gigabytes back from a delete that frees a fraction of it. It also
  counted hard links at full size, which frees nothing at all.
- **Deletes in a scan of `/System/Volumes/Data` were refused** with a message
  claiming your home folder is on the read-only system volume. It isn't.
- **Folders that could only be read part-way are now marked "partly read"**
  instead of being reported as fully scanned with a number too low.
- **Stopping a scan just as it finished threw the result away.** It is kept now.
- **Scan failures say what went wrong** — missing folder, or permission, which
  names Full Disk Access.
- **Smaller fixes** — double-clicking a small folder tile in the treemap zooms
  into it rather than to its parent; the hover outline no longer lingers over the
  wrong tile after a resize; ⌘R reads as unavailable during a scan instead of
  doing nothing.
- **Removing a big folder no longer freezes the app.** It runs in the
  background with a progress bar and a Stop button.
