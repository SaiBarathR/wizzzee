---
title: Getting started
description: Install Wizzzee, run your first scan, and find your way around the window, the guide and Full Disk Access.
---

# Getting started

Wizzzee measures a disk, or any folder on it, and shows you where the space went: a folder tree with sizes, the
biggest files, and a treemap of every file. This page covers installing it, the first scan, and the parts of the
window.

## Install

1. [Download Wizzzee](/wizzzee/download/), unzip it and move **Wizzzee.app** to Applications.
2. Open it. The first time, macOS blocks it because it isn't notarized: go to **System Settings → Privacy & Security**
   and click **Open Anyway** (on macOS 14 you can Control-click the app and choose **Open** instead).
3. Optionally, but for totals you can trust, add it under **System Settings → Privacy & Security → Full Disk
   Access**. [Why it matters](#full-disk-access).

The [download page](/wizzzee/download/) has the details, including checking the archive and building from source.

## Your first scan

At the top left of the window, **Select** lists your volumes; **Folder…** (<kbd>⌘O</kbd>) picks a folder to scan
instead. Press **Scan** or <kbd>Return</kbd>.

A scan of a whole startup disk, around 3.9 million files, takes about 15 seconds; a folder takes a moment. Progress
shows under the path as it goes, and **Stop** (<kbd>⌘.</kbd>) ends it. When it is done, the line under the path says how long it
took, and how many folders could not be read, if any.

Wizzzee remembers the volume or folder you scanned last and whether you were looking at **Size** or **On Disk**, and
starts with them next time.

<figure>
  <img src="/wizzzee/images/tree-view.webp" width="2000" height="1215" alt="The Wizzzee window after a scan of /System/Library: the header, the tabs, the tree with the File Types list beside it, the treemap and the status bar" loading="lazy" decoding="async" />
  <figcaption>The window after a scan of /System/Library.</figcaption>
</figure>

## The window

- **The header.** What to scan and the Scan button at the left. In the middle, the selection and what was scanned,
  with the volume's total, used and free space. At the right, the version and the **Size / On Disk** switch: which measure every
  figure, bar and tile in the window uses. [Reading the numbers](/wizzzee/docs/reading-the-numbers/) explains the
  difference; **On Disk**, the default, is the space you get back by deleting something.
- **The tabs.** **Tree View** (<kbd>⌘1</kbd>) is the folder hierarchy, sorted by size. **File View** (<kbd>⌘2</kbd>) is
  the biggest files in the scan, and where you search. **About** (<kbd>⌘3</kbd>) has figures for
the scan, how Wizzzee reads the disk, and the guide.
- **File Types**, beside the tree: every extension in the scan, ranked by the space it takes. Click one to put it in
  focus.
- **The treemap**, below: every file as a rectangle, its area in proportion to its size and its colour that of its
  type. Double-click to zoom into a folder. **View ▸ Hide Treemap** (<kbd>⌘T</kbd>) gives the whole tab to the table.
- **The status bar**, at the foot: the selection's size and item count at the left; at the right, the scan's files and
  folders, the space on disk, the logical size and how much hard links would have counted twice.

[Using Wizzzee](/wizzzee/docs/using-wizzzee/) goes through each of these in turn.

## The guide

The first time it opens, Wizzzee puts up a guide: seven pages, one for each part of the app, each with a small
picture of that part of the window, numbered, and a card for every number saying what can be done there and on which
keys. The last page is every keyboard shortcut.

**Don't show this again** at its foot stops it opening with the app. It stays under **Help ▸ Welcome to Wizzzee**, in
the About tab, and on <kbd>⌘/</kbd>, which opens it at the shortcuts.

<figure>
  <img src="/wizzzee/images/welcome.webp" width="1400" height="1043" alt="The guide's page on marking and removing: a picture of the tabs' row, the tree and the status bar with six numbered points, and a card for each" loading="lazy" decoding="async" />
  <figcaption>The guide's page on marking and removing.</figcaption>
</figure>

## Full Disk Access

Without it, macOS hides Mail, Messages, Safari, Time Machine and other users' home folders from every app, and the
totals read low. The header says so when it detects this.

To grant it: **System Settings → Privacy & Security → Full Disk Access → +**, and add `Wizzzee.app`.

One wrinkle: the app is ad-hoc signed, because a real signature needs a paid Apple Developer account. macOS ties the
permission to the exact binary, so **every update or rebuild drops the grant** and it has to be added again. Remove
the old entry with **−** and add the new app with **+**.

## Next

- [Using Wizzzee](/wizzzee/docs/using-wizzzee/): the views, Quick Look, marking and removing, undo, and every
  keyboard shortcut.
- [Search and filters](/wizzzee/docs/search/): finding things by name, size, age, type and kind.
- [Reading the numbers](/wizzzee/docs/reading-the-numbers/): why Wizzzee's figures differ from `df`, Finder or
  WizTree, and which one to trust for what.
