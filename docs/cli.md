# Command line

The same binary that draws the UI also runs headless. This is how the scan
engine gets verified against `du` and `df` without going through the interface,
and it makes the scanner usable from scripts.

Inside an installed bundle the executable is at:

```bash
/Applications/Wizzzee.app/Contents/MacOS/Wizzzee --help
```

A built-from-source binary is at `dist/Wizzzee.app/Contents/MacOS/Wizzzee`, or
`swift run Wizzzee -- --help` during development.

## `--scan <dir>`

Scans a tree and prints totals, the biggest folders, the biggest files, and the
biggest file types.

```bash
Wizzzee --scan ~/Library
```

Totals match `du -sk` exactly on the trees they have been compared against.
Progress lines are written as the walk proceeds, so piping through `head` is
safe on a large tree.

## `--probe <dir>`

Dumps one directory's raw `getattrlistbulk(2)` attributes: name, type, sizes,
link count, mount status, and which attributes the filesystem actually returned.

```bash
Wizzzee --probe /System/Volumes
```

Useful when a folder's numbers look wrong and the question is whether the
filesystem reported something unexpected or the aggregation mishandled it.

## `--treemap <dir> <out.png>`

Scans and rasterizes the treemap straight to a PNG, with no window involved.

```bash
Wizzzee --treemap / disk.png --size 2000x1200 --metric disk
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `--size WxH` | `1400x500` | Output size in points (rendered at 2×) |
| `--metric size\|disk` | `size` | Logical size, or space occupied on disk |

## `--uishot --out <png>`

Renders the real SwiftUI view hierarchy to a PNG from inside the process.

This exists because capturing the interface any other way needs the Screen
Recording permission, which a command-line build cannot obtain. Here the app
draws its own views with `cacheDisplay`, so the output is the actual layout with
no capture permission involved. Every screenshot in this repository is produced
this way.

```bash
Wizzzee --uishot --tab files --path /System/Library \
        --size 1400x850 --no-access-banner --out file-view.png
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `--out <png>` | `wizzzee-ui.png` | Where to write the image |
| `--path <dir>` | current directory | What to scan before rendering |
| `--size WxH` | `1500x900` | Window size in points (rendered at 2×) |
| `--tab tree\|files\|about` | `tree` | Which tab to show |
| `--zoom N` | `0` | Zoom the treemap N levels into the largest folder |
| `--select-largest` | off | Select the biggest item before rendering |
| `--no-access-banner` | off | Hide the Full Disk Access warning |
| `--no-treemap` | off | Hide the treemap, as the View menu's Hide Treemap does |

`--tab` accepts either the short name or the display title, matched by prefix,
so `files`, `file`, and `"file view"` all select the File View. An unrecognized
value exits with status 2 rather than silently falling back.

A command-line build can never hold Full Disk Access, so the warning banner is
always up; `--no-access-banner` produces the layout a user who has granted it
sees.

## `--selftest`

Builds a throwaway tree with known contents and checks the scanner and the
destructive file actions against ground truth.

```bash
Wizzzee --selftest
```

Exits 0 when every check passes, 1 otherwise, so it works as a CI gate. It
covers logical and allocated totals, hard-link deduplication, extension
statistics, filtering and ranking, that trashing and permanent deletion adjust
every ancestor's totals correctly, that System Integrity Protection paths are
refused, and that a stopped scan is reported as cancelled while an unreadable
root is reported as an error.

The delete path gets the most attention because it is the one place a bug does
real damage: it removes user files and then adjusts totals in place rather than
rescanning.

## `--version`, `--help`

Print the version and the usage summary. The version comes from the bundle's
`CFBundleShortVersionString`, so a source build outside a bundle reports `dev`.
