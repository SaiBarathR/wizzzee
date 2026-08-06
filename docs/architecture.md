# Architecture

How Wizzzee is put together, and why each piece is shaped the way it is. The
short version lives in the [README](../README.md); this is the longer one.

## The problem

WizTree is fast on Windows because it reads the NTFS master file table directly:
one sequential pass over an index that already holds every name and size on the
volume. APFS exposes no equivalent public index, so on macOS the tree has to be
walked. The work is therefore to make a walk of several million directory
entries finish in seconds rather than minutes.

Three things dominate the cost of a naive walk:

1. **Syscalls per file.** `readdir` plus a `stat` per entry is two-ish syscalls
   for every file on the disk.
2. **Serialization.** One thread walking a tree leaves an SSD almost entirely
   idle; the bottleneck is syscall latency, not bandwidth.
3. **Allocation.** Several million heap objects, each with reference counting,
   costs both memory and time.

Each layer below addresses one of them.

## Core

### `BulkEnumerator` — one syscall for many entries

Wraps `getattrlistbulk(2)`, which returns a packed buffer of attributes for as
many directory entries as fit, instead of one entry at a time. A single call
yields name, object type, modification time, file ID, link count, logical size,
allocated size, and mount status for a batch of entries.

The reply is a densely packed variable-length buffer, so the parser walks it
field by field in the order the kernel documents. The `ATTR_*` constants are
redeclared locally as `UInt32`: the imported macros arrive with inconsistent
signedness (`ATTR_CMN_RETURNED_ATTRS` does not fit in `Int32`), which makes the
bitwise arithmetic unreadable.

`ATTR_CMN_RETURNED_ATTRS` matters — filesystems may return fewer attributes than
asked for, and the returned-attributes mask says which fields are actually
present in each record. Skipping that check reads garbage on any filesystem that
declines an attribute.

### `ScanEngine` — a worker per core

A pool of `min(activeProcessorCount, 16)` threads pulls from a shared LIFO
`WorkStack` of pending directories. Each worker enumerates one directory,
appends its files to the parent node, and pushes any subdirectories back onto
the stack.

LIFO is deliberate: depth-first keeps the stack small and the working set warm,
where breadth-first on a large tree would queue millions of pending directories
before finishing the first level.

Termination is the interesting part. A worker that finds the stack empty cannot
simply exit — another worker may be about to push more work. So `WorkStack`
tracks how many workers are actively processing an item; a worker that finds the
stack empty *and* no active workers knows the tree is fully walked, sets
`stopped`, and broadcasts to wake the rest.

Two shared sets are consulted for essentially every entry: visited directories
(to break APFS firmlink cycles) and seen hard links (to count linked bytes once).
A single lock around either would serialize the whole pool, so both are
`ShardedKeySet` — 32 independent sets behind 32 `os_unfair_lock`s, picked by the
inode's hash. Contention drops by roughly the shard count.

Cancellation goes through the same lock. `cancel()` sets a flag and stops the
work stack; because the stack is created on the scan thread, a cancel arriving
before it exists would find nothing to stop, so `install(_:)` re-checks the flag
after publishing the stack. Without that handshake, stopping a scan in its first
instants let the entire walk run to completion before the result was discarded.

Aggregation happens afterwards, in a single bottom-up pass on one thread. That
is what keeps the parallel phase free of locks apart from the progress counters:
no worker ever updates an ancestor's totals.

### `ScanTree` — packed storage

`DirNode` is a class; `FileEntry` is a struct held in a contiguous array on its
parent. At four million files, one object per file would cost more in allocation
headers and retain/release traffic than the data itself. The array form keeps a
full-disk scan in a few hundred megabytes.

`DirNode.parent` is `unowned`: the root retains the tree downward, so a strong
back-reference would cycle and leak the whole tree on every rescan.

`NodeRef` is the shared currency of the UI — it points at either a directory or
one file within a directory (`fileIndex == -1` means the directory itself), so
the tree table, the file list and the treemap can all carry the same selection.
Because a file reference is an index, deleting a file invalidates every
`NodeRef` for its later siblings; `AppModel` drops the selection and rebuilds
derived rows after any removal rather than trying to patch indices.

Paths are not stored per node. `DirNode.path` rebuilds by walking up to the
root, whose `name` holds the full path the scan started from. Storing an
absolute path on four million nodes would cost more than the rest of the tree.

## Treemap

### `TreemapLayout` — squarified tiles with cushions

A standard squarified treemap: children are laid out in rows chosen to keep
aspect ratios near 1, which makes areas comparable by eye in a way slice-and-dice
layouts do not.

Alongside each tile the layout accumulates quadratic *cushion* coefficients — the
van Wijk and van de Wetering technique. Each nesting level adds a parabolic bump
to the surface, so depth in the hierarchy becomes visible shading rather than
just a border.

### `TreemapRenderer` — one pass over the bitmap

The cushion surface is evaluated per pixel and lit by a fixed directional light.
This sounds expensive and is not: the tiles tile the canvas, so the total work is
about one pass over the bitmap no matter how many files the scan found. A
million-file treemap costs the same as a hundred-file one.

## App

`AppModel` is the single `@MainActor` owner of scan state, derived table rows,
and treemap zoom and selection.

Two pieces of background work read the tree off the main thread — the scan
itself, and the File View's largest-files walk. Deletes mutate the tree in place
(unlinking a node and subtracting its bytes from every ancestor) instead of
rescanning, which means a mutation must never overlap a read. Both reads go
through one serial `treeQueue`, and a delete cancels any pending walk and then
syncs against that queue before touching a node.

Deleting adjusts totals up the ancestor chain rather than recomputing, so the
whole UI updates instantly after a delete. That path is the one place a bug does
real damage, so `--selftest` checks it against ground truth rather than by eye.

## Layout

```
Sources/Wizzzee/
  Core/       BulkEnumerator (getattrlistbulk), ScanEngine, ScanTree,
              Volumes, FileActions, Formatting
  Treemap/    TreemapLayout (squarify + cushions), TreemapRenderer,
              TreemapView, TreemapPalette
  UI/         ContentView, HeaderBar, TreeViewTab, FileViewTab, TreemapPane,
              StatusBar, ItemContextMenu
  App/        Main, WizzzeeApp, AppModel, AppInfo, CLI, SelfTest, UIShot
scripts/      build-app.sh, validate-release.sh, make-icon.swift
```

## Deliberate limitations

- **One volume per scan.** Other disks, network shares and the synthetic mounts
  under `/System/Volumes` are skipped. APFS firmlinks are followed once, so
  `/Users` is counted but `/System/Volumes/Data/Users` — the same directory by
  another path — is not.
- **No persistent index.** Every scan is a fresh walk. At ~15 seconds for a full
  disk, an index would add staleness and complexity for little gain.
- **Totals won't exactly match `df`.** Unreadable folders, APFS snapshots and
  filesystem metadata account for the difference.
