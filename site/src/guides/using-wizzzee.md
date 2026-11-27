---
title: Using Wizzzee
description: Tree View, File View, the treemap and file types, Quick Look, marking and removing, rescans, undo, and every keyboard shortcut.
---

# Using Wizzzee

A scan builds one tree of everything it found. Every part of the window is a view of that tree, and they all use the
measure the **Size / On Disk** switch is set to.

## Tree View

The folder hierarchy, sorted by size, with a bar for each item's share of its parent. Click a column to re-sort;
sorting applies within each parent, so the hierarchy stays intact.

<kbd>→</kbd> opens the selected folder and <kbd>←</kbd> shuts it, as in Finder's list view; pressed again they step
into the folder and back out of it.

The table shows both measures, **On Disk** first, with the one that is not on show set back. A file with stretches
that were never written is marked **sparse**, or **online only** when a cloud provider is holding its contents;
hovering the mark gives both figures.

## File View

The 1,000 biggest files anywhere in the scan, with the folder each is in, and where to search it. <kbd>⌘F</kbd> goes to
its filter from any tab. Words find names, folders as well as files, and filters narrow by size, age, type and kind:
[Search and filters](/wizzzee/docs/search/) has all of it.

<figure>
  <img src="/wizzzee/images/file-view.webp" width="2000" height="1215" alt="File View, showing the biggest files in the scan with their folders, sizes and dates" loading="lazy" decoding="async" />
</figure>

## The treemap

Every file as a rectangle, its area proportional to its size and its colour that of its extension. Folders nest
inside their parents, shaded so the nesting reads as depth, and the bigger ones are labelled with their name and size.

- **Hover** a tile to see its path and size.
- **Click** to select it. The selection is the same one the tables use.
- **Double-click** a folder to zoom in. Double-clicking a file zooms to the innermost folder that holds it.
- **Click any folder in the path above the map** to zoom back out to there. <kbd>⌘[</kbd> zooms out one folder, and
  <kbd>⌘0</kbd> back to the top.
- **⌘-click** a tile to mark it for removal.

**View ▸ Hide Treemap** (<kbd>⌘T</kbd>), or the button at the right-hand end of the status bar, gives the whole tab to
the table. Showing it again keeps the zoom you left it at, and whichever way you leave it is how it opens next launch.

<figure>
  <img src="/wizzzee/images/treemap.webp" width="2000" height="858" alt="The treemap alone: thousands of shaded tiles, coloured by file type, nested by folder" loading="lazy" decoding="async" />
</figure>

The colours rank the file types by total size: the biggest types get the most distinct hues, and everything past the
palette shares a neutral grey. A grey-blue tile is a folder too small, or too deep, to break down any further;
double-click it to zoom in and see what is inside.

## File types

The list beside the tree ranks the scan by file extension, with each type's share and number of files. It starts at
the 40 largest types; click **top 40 of …** in its heading for all of them.

Click a type to put it in focus: its tiles stay lit on the treemap while every other tile is set back, and File View
lists that type's largest files and no others. A label naming the type appears beside the map and above the file list;
click it to take the focus off, or press <kbd>Esc</kbd> in the list.

<figure>
  <img src="/wizzzee/images/file-types.webp" width="2000" height="1215" alt="One file type in focus: its tiles lit on the treemap, the rest set back, and File View listing that type alone" loading="lazy" decoding="async" />
</figure>

## Quick Look

<kbd>⌘Y</kbd> opens Quick Look on the selected item, and shuts it again, so you can see what a file is before deciding
what to do with it.

While it is open it shows the one thing selected: it follows the selection, shuts when several rows are selected, and
when the item on show is removed it moves on to whatever took its place, so a list can be worked down with it up.
Opened from the right-click menu, it selects the row it shows. A file that is *online only* is not previewed: that
would download it.

## The right-click menu

Right-click anything, in a table or on the treemap, for **Reveal in Finder**, **Open**, **Quick Look**, **Open in
Terminal**, **Copy Path**, **Mark for Removal**, **Move to Trash** or **Delete Permanently**.

Removing something updates the sizes all the way up the tree without rescanning: the row goes, its neighbours stay
where they were, and the selection moves to whatever took its place. A removal that takes a while shows how many items
and how much space have gone in the status bar, and **Stop** there ends it part-way. What is left stays in the tree,
measured as it now is.

<kbd>⌘⌫</kbd> and <kbd>⌥⌘⌫</kbd> do what they do in Finder, to whatever is selected: the first moves it to the Trash
straight away, the second asks and then deletes it for good. They act only on a selection you can see, a row in the
tab in front or the tile outlined on the treemap, and leave <kbd>⌘⌫</kbd> to the File View filter while you are typing
in it.

## Marking things to remove together

The box at the start of each row marks it, and so do <kbd>Space</kbd> on a selected row, ⌘-click on a treemap tile,
and **Mark for Removal** in the right-click menu.

A mark is not the selection. It stays put while you open other folders, sort, filter or switch tabs, so you can
gather items from anywhere in the scan. Marking a folder marks everything in it, and a folder with something marked
inside shows a dash. Marked tiles are hatched on the treemap.

From the first mark, a bar fills the row the tabs are in, at the top of the window and on every tab: how many things
are marked, what removing them would free, and **Move to Trash**, **Delete…** and **Clear Marks** for the lot. **Show
List** on it drops down the list of them, which gives each item's size and lets you take a mark back off.

<figure>
  <img src="/wizzzee/images/marks.webp" width="2000" height="1215" alt="Two folders marked for removal: ticked in the table, hatched on the treemap, and listed with their sizes under the bar beside the tabs" loading="lazy" decoding="async" />
</figure>

## Rescanning

<kbd>⌘R</kbd>, or **Scan** on the folder already on show, brings the figures up to date and leaves the window as it
was: the same folders open, the map zoomed to the same folder, the same selection and the same marks, wherever those
things are still there.

A mark whose item has gone, or has been replaced by another of the same name, is counted beside "Scan complete", so a
shorter list is not taken for the whole of it. Stopping a rescan does not lose the marks: the next scan of that folder
puts them back. A scan of somewhere else starts afresh.

## Undo

<kbd>⌘Z</kbd> undoes the last move to the Trash, as do **Edit ▸ Undo** and the **Undo** button the status bar shows
after one. What went comes back, on disk and in the tree, selected and with the marks it left with.

It is the last move only, and only until something else is removed, the folder is scanned again, or the Trash is
emptied. Something whose place has been taken in the meantime stays in the Trash and is named, and is not put back
over what took it.

The status bar says what Wizzzee has moved to the Trash that is still there. It has left the totals but not the disk,
so that figure is what emptying the Trash frees.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| <kbd>Return</kbd> | Scan (not while typing in the File View's filter) |
| <kbd>⌘O</kbd> | Choose a folder to scan |
| <kbd>⌘.</kbd> | Stop a running scan |
| <kbd>⌘R</kbd> | Rescan |
| <kbd>⌘F</kbd> | Search: go to the File View's filter |
| <kbd>⌘Y</kbd> | Quick Look at the selected item, or shut it |
| <kbd>Space</kbd> or <kbd>⇧⌘M</kbd> | Mark the selected rows for removal, or unmark them |
| <kbd>⌘⌫</kbd> | Move the selection to the Trash |
| <kbd>⌥⌘⌫</kbd> | Delete the selection permanently, after confirming |
| <kbd>⌘Z</kbd> | Undo the last move to the Trash |
| <kbd>⌘1</kbd> <kbd>⌘2</kbd> <kbd>⌘3</kbd> | Tree View, File View, About |
| <kbd>→</kbd> <kbd>←</kbd> | Open or shut the selected folder; again, step into it or out of it |
| <kbd>⌘T</kbd> | Show or hide the treemap |
| <kbd>⌘[</kbd> | Zoom the treemap out |
| <kbd>⌘0</kbd> | Reset the treemap zoom |
| <kbd>⌘/</kbd> | The guide, at its page of keyboard shortcuts |
