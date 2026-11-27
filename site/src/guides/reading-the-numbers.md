---
title: Reading the numbers
description: Size versus On Disk, base-10 units, hard links, one volume per scan, why totals differ from df, and what can't be deleted.
---

# Reading the numbers

Two disk analyzers pointed at the same folder rarely agree, and neither agrees with `df`. There are real reasons for
that, and this page goes through them, so you know which figure to trust for what.

## Size and On Disk

**Size** is a file's logical length. **On Disk** is the space actually allocated to it. Usually they are close; for
some files they are wildly apart.

- **Sparse files** have stretches that were never written, which take no space. A virtual machine or container disk
  image is the usual case: an OrbStack image on the Mac Wizzzee was built on reports 996 GB and occupies 42 GB, on a
  995 GB disk.
- **Online-only files**, whose contents a cloud provider is holding, take next to nothing until they are downloaded.
- **Compressed files** occupy less than their length too, as most of the system's own do. Nothing of theirs is missing,
  so Wizzzee leaves them unmarked.

Wizzzee defaults to **On Disk**, since that is the space you get back by deleting something. The switch is at the top
right of the window, and the next launch starts with whichever was chosen.

Whichever is on show is what the window reports: the header's **Scanned** line, the status bar, the bars and the
treemap. The tables show both, **On Disk** first, with the one that is not on show set back. A sparse file is marked
**sparse**, an online-only one **online only**, and hovering the mark gives both figures.

Lengths added up can come to more than the disk holds; a single sparse image does it. That sum is the status bar's
**Logical size**, and it is why a length is never quoted on its own next to the volume's capacity.

## Base-10 units

1 GB is 1,000,000,000 bytes, matching Finder and Get Info. That differs from `df -h`, which is base 2, and from WizTree
on Windows, which labels base-2 units "GB". A "100 GB" folder in Wizzzee is about 93 GB in those.

## Hard links are counted once

A file with several names, hard links to the same data, takes its space once, so Wizzzee counts it once. The status
bar shows how much would have been double-counted otherwise.

Which of the linked names is the one shown is arbitrary: whichever the scanner reaches first. An analyzer that counts
every name in full reports a folder of hard links, such as a package store or a developer cache, as larger than
Wizzzee and `du` do.

## One volume per scan

Other disks, network shares and the synthetic mounts under `/System/Volumes` are left out of a scan. APFS firmlinks
are followed once, so `/Users` is counted but `/System/Volumes/Data/Users`, the same directory by another path, is
not.

## Why totals won't exactly match df

Unreadable folders, APFS snapshots and filesystem metadata account for the difference. The header reports how many
folders it could not read.

If that number is large, or the totals look low, check [Full Disk Access](/wizzzee/docs/#full-disk-access): without
it, macOS hides Mail, Messages, Safari, Time Machine and other users' home folders.

What Wizzzee does match is `du`: the command line's `--scan` totals match `du -sk` exactly on the trees they have been
compared against. [Command line](/wizzzee/docs/command-line/) has the details.

## What can't be deleted

`/System`, `/usr`, `/bin` and `/sbin` are on the sealed system volume, which System Integrity Protection makes
read-only. Nothing can remove files there, not even an administrator. Wizzzee still shows them, so the space is
accounted for, and says so instead of failing with a bare permission error.

## Moved to the Trash isn't gone yet

Something moved to the Trash leaves Wizzzee's totals at once, but it is still on the disk until the Trash is emptied.
The status bar says how much of what Wizzzee moved there is still there: that is what emptying the Trash frees.
