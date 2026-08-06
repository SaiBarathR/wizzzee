import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Headless entry points, used to verify the scan engine independently of the UI.
enum CLI {
    static func usage() {
        print(
            """
            Wizzzee \(AppInfo.version) — disk space analyzer for macOS

              Wizzzee                        launch the app
              Wizzzee --probe <dir>          dump one directory's raw bulk attributes
              Wizzzee --scan <dir>           scan a tree and print the largest entries
              Wizzzee --treemap <dir> <png>  scan and write the treemap to a PNG
                                             [--size WxH] [--metric size|disk]
              Wizzzee --prefs                print the preferences the app reads
              Wizzzee --selftest             check the scanner and the delete paths
              Wizzzee --uishot --out <png>   render the real UI to a PNG
                                             [--path <dir>] [--size WxH]
                                             [--tab tree|files|about] [--zoom N]
                                             [--select-largest] [--no-access-banner]
              Wizzzee --version              print the version
            """
        )
    }

    /// Scans and writes the treemap image straight to disk, which is how the
    /// layout and cushion shading get checked without launching the UI.
    static func renderTreemap(arguments: [String]) {
        guard arguments.count >= 2 else {
            print("usage: Wizzzee --treemap <dir> <out.png> [--size WxH] [--metric size|disk]")
            return
        }
        let path = arguments[0]
        let output = arguments[1]

        var size = CGSize(width: 1400, height: 500)
        var metric = SizeMetric.logical
        var index = 2
        while index < arguments.count - 1 {
            switch arguments[index] {
            case "--size":
                let parts = arguments[index + 1].lowercased().split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    size = CGSize(width: w, height: h)
                }
            case "--metric":
                metric = arguments[index + 1] == "disk" ? .allocated : .logical
            default:
                break
            }
            index += 2
        }

        print("Scanning \(path)…")
        guard let result = ScanEngine().scanSynchronously(rootPath: path) else {
            print("scan failed")
            return
        }
        print(
            "  \(ByteFormat.count(result.root.totalFiles)) files, "
                + "\(ByteFormat.decimal(result.root.totalSize)) in "
                + ByteFormat.duration(result.elapsed)
        )

        let started = Date()
        let model = TreemapLayout.build(root: result.root, size: size, metric: metric)
        let layoutTime = Date().timeIntervalSince(started)
        let renderStarted = Date()
        guard let image = TreemapRenderer.render(model: model, scale: 2) else {
            print("render failed")
            return
        }
        let renderTime = Date().timeIntervalSince(renderStarted)

        print(
            "  layout \(ByteFormat.count(model.cells.count)) tiles / "
                + "\(ByteFormat.count(model.frames.count)) folders "
                + "in \(String(format: "%.0f ms", layoutTime * 1000)), "
                + "raster in \(String(format: "%.0f ms", renderTime * 1000))"
        )

        let url = URL(fileURLWithPath: output)
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            print("couldn't create \(output)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            print("  wrote \(output) (\(image.width)x\(image.height))")
        } else {
            print("  failed to write \(output)")
        }
    }

    /// Prints the preferences this build would start with, so a setting that is
    /// only visible in the UI can still be checked from a script. Read-only.
    static func prefs() {
        print(Preferences.summary())
    }

    /// Dumps a single directory's entries exactly as `getattrlistbulk` reported
    /// them. This is the sanity check on the reply-buffer decoding: wrong field
    /// offsets show up here immediately as garbled names or absurd sizes.
    static func probe(path: String) {
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else {
            print("open(\(path)) failed: \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        print("=== \(path) ===")
        print(
            "type  links  size         alloc        modified          id         name"
        )

        var count = 0
        let enumerator = BulkEnumerator()
        let err = enumerator.enumerate(fd: fd) { e in
            count += 1
            let kind: String
            if e.isDir {
                kind = e.isMountPoint ? "MNT " : "dir "
            } else if e.isSymlink {
                kind = "link"
            } else if e.isRegularFile {
                kind = "file"
            } else {
                kind = "t\(e.objType)  "
            }
            let date = formatter.string(
                from: Date(timeIntervalSince1970: e.mtime)
            )
            print(
                "\(kind)  \(pad(String(e.linkCount), 5))  "
                    + "\(pad(String(e.size), 11))  \(pad(String(e.alloc), 11))  "
                    + "\(date)  \(pad(String(e.fileID), 9))  \(e.name)"
            )
        }
        print("--- \(count) entries, errno=\(err)")
    }

    /// Scans a tree and prints totals plus the biggest folders and files, so the
    /// numbers can be diffed against `du -sk` / `df`.
    static func scan(path: String) {
        let engine = ScanEngine()
        let start = Date()
        var lastReport = start

        engine.onProgress = { p in
            // Keep stdout readable: at most a few lines per second.
            if Date().timeIntervalSince(lastReport) > 0.5 {
                lastReport = Date()
                FileHandle.standardError.write(
                    "  \(p.items) items, \(ByteFormat.decimal(p.bytes))\n"
                        .data(using: .utf8)!
                )
            }
        }

        guard let result = engine.scanSynchronously(rootPath: path) else {
            print("scan failed or was cancelled")
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        let root = result.root
        print("")
        print("Scan of \(path) complete in \(String(format: "%.2f", elapsed))s")
        print(
            "  total size:      \(ByteFormat.decimal(root.totalSize)) "
                + "(\(root.totalSize) bytes)"
        )
        print(
            "  on disk:         \(ByteFormat.decimal(root.totalAlloc)) "
                + "(\(root.totalAlloc) bytes)"
        )
        print("  files:           \(root.totalFiles)")
        print("  folders:         \(root.totalDirs)")
        print("  unreadable dirs: \(result.deniedCount)")
        print("  hardlinks saved: \(ByteFormat.decimal(result.hardLinkSavings))")
        print("  du -sk equivalent: \(root.totalAlloc / 1024)")

        print("\nLargest folders:")
        for child in root.subdirs.sorted(by: { $0.totalSize > $1.totalSize })
            .prefix(15)
        {
            print(
                "  \(pad(ByteFormat.decimal(child.totalSize), 10))  "
                    + "\(pct(child.totalSize, of: root.totalSize))  \(child.name)"
            )
        }

        print("\nLargest files:")
        // Ranked by the same measure that gets printed. The default is
        // allocated size, which would list logical sizes out of order.
        for file in result.largestFiles(limit: 15, metric: .logical) {
            print(
                "  \(pad(ByteFormat.decimal(file.size), 10))  \(file.path)"
            )
        }

        print("\nLargest file types:")
        for stat in result.extensionStats.prefix(15) {
            print(
                "  \(pad(ByteFormat.decimal(stat.size), 10))  "
                    + "\(pct(stat.size, of: root.totalSize))  "
                    + "\(pad(stat.displayName, 12))  \(stat.count) files"
            )
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width
            ? s : String(repeating: " ", count: width - s.count) + s
    }

    private static func pct(_ value: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "  0.0%" }
        let p = Double(value) / Double(total) * 100
        return pad(String(format: "%.1f%%", p), 6)
    }
}
