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

`DirNode.parent` is `weak`: the root retains the tree downward, so a strong
back-reference would cycle and leak the whole tree on every rescan. It is weak
rather than unowned because the UI holds nodes past the life of their scan — a
closed context menu keeps its references — and a parent that has gone has to
read as gone, not as whatever now occupies its memory.

`NodeRef` is the shared currency of the UI — it points at either a directory or
one file within a directory (`fileIndex == -1` means the directory itself), so
the tree table, the file list and the treemap can all carry the same selection.

A file reference is an index, so taking a deleted file's entry out of its
folder's array would renumber every sibling after it. That is what it used to
do, and everything holding a reference paid for it: the table was handed a list
of rows it had never seen and redrew all of them, the File View was emptied
until a walk refilled it, and the selection was thrown away because it could no
longer be trusted. The entry is kept instead — flagged removed and reset to
hold nothing — and every walk over files steps past it. A reference to a
sibling goes on naming the sibling, so a delete takes one row out of the table
and leaves the rest, and the selection, where they were. A folder that is
deleted has its parent pointer cleared, which is what makes a reference to it,
or to anything inside it, read as stale.

Paths are not stored per node. `DirNode.path` rebuilds by walking up to the
root, whose `name` holds the full path the scan started from. Storing an
absolute path on four million nodes would cost more than the rest of the tree.

Every file carries two sizes: its length and the space it occupies. They are
not interchangeable, and summing the wrong one is the easiest way for this app
to be badly wrong — a container image can be longer than the disk it is on.
`SizeMetric` says which is on show, and whatever states how big something is
has to choose by it — the lines that summarise a scan through `bytes(using:)`,
the treemap, the legend and the file list each in their own way — rather than
reading `size` directly. The places that mean the length specifically say so.
`FileStorage` records why the two differ when they do. A sparse file is told
from attributes the scan already reads instead of asking the filesystem for its
own flag, which would mean a second attribute group on every entry: over the
3.1 million files of a home folder the two agreed on all of them. That was
measured on APFS and is trusted only there — a network share can report no
allocation at all, and every file on it would otherwise be called sparse.

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

A file type picked out in the legend is drawn here as well: every tile of
another type has most of its colour taken out and is darkened, in the bitmap.
As an overlay in the view it would be filled again on every move of the
pointer, once per tile, and a map can hold two hundred thousand of them.

## App

`AppModel` is the single `@MainActor` owner of scan state, derived table rows,
and treemap zoom and selection. The lines that summarise a scan — the header's
"Scanned", the status bar's selection, the running count — are put together
there too rather than in the views, so `--selftest` can hold them to the
measure on show.

Two pieces of background work read the tree off the main thread — the scan
itself, and the File View's walk. With nothing typed that walk is the largest
files, and a file too small to make the list is passed over without a look.
With a search in the filter (`SearchQuery`) every file and folder is held up to
it, listed or not, because how many matched and what they come to is half of
what was asked; that is the one thing a search costs over the plain list. Deletes mutate the tree in place
(unlinking a node and subtracting its bytes from every ancestor) instead of
rescanning, which means a mutation must never overlap a read. Both reads go
through one serial `treeQueue`, and a delete cancels any pending walk and then
syncs against that queue before touching a node.

Deleting adjusts totals up the ancestor chain rather than recomputing, so the
whole UI updates instantly after a delete. That path is the one place a bug does
real damage, so `--selftest` checks it against ground truth rather than by eye.

A scan throws the tree away, and nothing that points into one tree means
anything in the next: a `NodeRef` is a node and an index. What carries over a
rescan of the same folder is therefore kept as paths — the open folders, the
map's root, the selection, the marks — taken before the old tree is let go and
looked up in the new one when it lands. What is no longer there is not put
back, and a mark that could not be is counted.

The selection and the marks are two sets and are kept apart on purpose. The
selection is what is being looked at: a plain click replaces it, and a
collapsed folder or a change of tab takes it off the screen, which is why the
delete keys only act on the part of it that is on show. The marks are what has
been decided on. They live in the model, not in a table, so they outlast all of
that, and they never nest — a folder's mark stands for everything in it — so
the list of them can be totalled without counting anything twice. Both are sets
of `NodeRef`, which is only workable because a delete no longer renumbers what
it leaves behind.

### `Removal` — deleting with something to show for it

Deleting for good goes through `removefile(3)`, the routine underneath
`FileManager.removeItem`, called directly. `removeItem` keeps what it learns on
the way to itself: a folder of a million files was one call that reported
nothing until it returned and could not be interrupted, so the progress bar for
the usual case — one folder — sat at nothing until it was over, and Stop did
nothing until then either. `removefile` calls back per entry, and hands over
the `FTSENT` it already has for each, so counting what has gone and the space
it held costs no extra look at the disk.

Three things follow from doing it this way:

- **Stop works inside a folder.** The callback is where it is checked, so it
  takes effect at the next file.
- **A failure costs one file, not the rest.** What can be removed is, as
  `rm -rf` does it, and the caller is told what could not be.
- **Part of a folder can be gone and part not.** The tree is then brought into
  line by asking the disk which of the entries it knew about are still there —
  not by trusting the callbacks — and those that are not go through the same
  detach as any other delete.

A tree deeper than `PATH_MAX` needs `REMOVEFILE_ALLOW_LONG_PATHS`, which has
`removefile` change the working directory of the whole process as it descends.
It is passed only on a second attempt, for a tree that turned out to need it.

That reaches what is *under* the item being deleted. An item whose own path is
already past `PATH_MAX` — a scan lists one level of them, the contents of the
deepest folder it could open — can't be handed to `removefile` at all:
`removefileat`, relative to the folder it is in, turns it down the same way.
Deleting one of those on its own fails as it always has, and says why; deleting
the folder above it is what removes it.

`removefile.h` is imported through `Sources/CRemoveFile`, a module map and a
one-line header. It only joined the Darwin module in the macOS 27 SDK, and a
release is built with an older one.

## Layout

```
Sources/Wizzzee/
  Core/       BulkEnumerator (getattrlistbulk), ScanEngine, ScanTree,
              Volumes, FileActions, Removal (removefile), Formatting
  Treemap/    TreemapLayout (squarify + cushions), TreemapRenderer,
              TreemapView, TreemapPalette
  UI/         ContentView, HeaderBar, TreeViewTab, FileViewTab, TreemapPane,
              StatusBar, ItemContextMenu, Marks
  App/        Main, WizzzeeApp, AppModel, AppInfo, Preferences, CLI, SelfTest,
              UIShot
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
