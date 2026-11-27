---
title: Search and filters
description: Find files and folders in a scan by name, path, size, age, type and kind, from the File View's filter.
---

# Search and filters

Search lives in the File View. <kbd>⌘F</kbd> goes to its filter from any tab, and <kbd>Esc</kbd> empties it. With
nothing typed, the File View lists the 1,000 biggest files in the scan; with something typed, it lists what matches,
biggest first.

<figure>
  <img src="/wizzzee/images/search.webp" width="2000" height="1215" alt="A search for folders by name and size, with the count of what it found and what it takes up" loading="lazy" decoding="async" />
</figure>

## Words

Words are looked for in names: all of them, in any order, ignoring case. They find folders as well as files, so
`node_modules` lists every folder of that name and what they come to.

- **A word with a `/` in it** is looked for in the whole path instead of the name: `Library/Caches` finds everything
  under any folder of that name.
- **Words in double quotes** are one word, spaces and all: `"Screen Recording"`.

## Filters

| Filter | Finds |
| --- | --- |
| `>1gb` `<500kb` | What is bigger, or smaller, in the measure on show (Size or On Disk) |
| `older:1y` `newer:30d` | By when it was last modified |
| `ext:dmg` | One file type; `ext:none` for files with no extension |
| `kind:folder` `kind:file` | Folders only, or files only |

- **Sizes** take `b`, `kb`, `mb`, `gb` or `tb`, or just the first letter, in base 10 like the rest of the app:
  `>1gb` is more than 1,000,000,000 bytes. Decimals work: `>1.5g`.
- **Ages** take `d` for days, `w` for weeks, `m` for months of 30 days and `y` for years of 365.
- **`kind:`** also takes `folders`, `dir` and `files`.

Filters combine: `>100mb <1gb` is everything between the two. A second filter of the same kind narrows the first, as a
second word does.

Filters and words go together freely:

| Search | Finds |
| --- | --- |
| `node_modules kind:folder >100mb` | Every `node_modules` folder over 100 MB |
| `ext:dmg older:6m` | Disk images not modified in six months |
| `>1gb older:1y` | Anything over a gigabyte not modified for a year |
| `DerivedData/ >500mb` | Big things inside Xcode's build folders |
| `ext:mov "Screen Recording"` | Screen recordings |

## What gets searched

- **Files, and folders when you ask for them.** Folders are searched when there is a word to find them by, or
  `kind:folder` asks for them. Without either, the list is of files: a folder is at least as big as anything in it, so
  the largest of everything would be the scan's own top folders and nothing else. `ext:` lists files.
- **What can't be met finds nothing.** A filter that can't be read, like `>lots`, finds nothing rather than being
  dropped and showing everything. So do two filters nothing can meet at once, like `ext:dmg ext:zip` or `kind:file
  kind:folder`.
- **A file type in focus**, picked in the File Types list, limits the File View to that type.

## The count

The line at the right of the filter says how many things matched, listed or not, and what they take up. A match
inside a folder that also matched is counted, and adds nothing to the size, so the total is never more than the space
the matches really take.
