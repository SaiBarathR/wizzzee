import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Renders the real UI to a PNG from inside the process.
///
/// This exists because verifying the interface otherwise needs the Screen
/// Recording permission, which a command-line build can't obtain. Here the app
/// draws its own view hierarchy with `cacheDisplay`, so the output is the actual
/// SwiftUI layout with no capture permission involved.
enum UIShot {
    @MainActor
    static func run(arguments: [String]) {
        var output = "wizzzee-ui.png"
        var scanPath = FileManager.default.currentDirectoryPath
        var width = 1500.0
        var height = 900.0
        var tab = MainTab.tree
        var selectLargest = false
        var zoomDepth = 0
        var hideAccessBanner = false
        var showTreemap = true

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "--out":
                if let next { output = next }
                index += 2
            case "--path":
                if let next { scanPath = next }
                index += 2
            case "--size":
                if let next {
                    let parts = next.lowercased().split(separator: "x")
                    if parts.count == 2, let w = Double(parts[0]),
                        let h = Double(parts[1])
                    {
                        width = w
                        height = h
                    }
                }
                index += 2
            case "--tab":
                if let next {
                    if let match = MainTab(cliName: next) {
                        tab = match
                    } else {
                        let names = MainTab.allCases.map(\.cliName).joined(
                            separator: ", ")
                        print("unknown tab “\(next)”; expected one of: \(names)")
                        exit(2)
                    }
                }
                index += 2
            case "--select-largest":
                selectLargest = true
                index += 1
            case "--no-access-banner":
                // A command-line build can't hold Full Disk Access, so the
                // warning is always up. Documentation shots want the layout a
                // user who has granted it sees.
                hideAccessBanner = true
                index += 1
            case "--no-treemap":
                // The View menu's Hide Treemap, so the table-only layout can be
                // rendered without a screen capture.
                showTreemap = false
                index += 1
            case "--zoom":
                zoomDepth = Int(next ?? "1") ?? 1
                index += 2
            default:
                index += 1
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let model = AppModel()
        model.tab = tab
        model.customFolder = scanPath
        model.dismissedAccessPrompt = hideAccessBanner
        model.showsTreemap = showTreemap

        let hosting = NSHostingView(rootView: ContentView(model: model))
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.frame = frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wizzzee"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        // Kept off screen so the capture doesn't steal focus from the user.
        window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
        window.orderFront(nil)

        print("Scanning \(scanPath) for UI capture…")
        model.startScan()

        // Pump the run loop until the scan lands, then a little longer so the
        // treemap's background raster and SwiftUI's layout both settle.
        waitUntil(timeout: 600) { model.phase != .scanning }

        guard model.phase == .complete else {
            print("scan did not complete: \(model.phase)")
            exit(1)
        }
        if selectLargest {
            let biggest = model.result?.root.subdirs.max { $0.totalSize < $1.totalSize }
            if let biggest {
                model.selection = [NodeRef(biggest)]
                model.setExpanded(biggest, true)
            }
        }
        // Walk down the biggest folder at each level, the same thing
        // double-clicking the treemap does.
        for _ in 0..<zoomDepth {
            guard
                let deeper = model.treemapRoot?.subdirs.max(by: {
                    $0.totalAlloc < $1.totalAlloc
                })
            else { break }
            model.zoom(into: deeper)
        }
        if zoomDepth > 0 {
            print("zoomed to \(model.treemapRoot?.path ?? "—")")
        }
        if tab == .files { model.refreshFileRows(immediately: true) }

        pump(seconds: 2.5)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        pump(seconds: 1.5)

        guard
            let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else {
            print("couldn't allocate a bitmap for the view")
            exit(1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let image = rep.cgImage else {
            print("couldn't rasterize the view")
            exit(1)
        }

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
            exit(1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        if CGImageDestinationFinalize(destination) {
            print("wrote \(output) (\(image.width)x\(image.height))")
        } else {
            print("failed to write \(output)")
            exit(1)
        }
        exit(0)
    }

    /// Runs the main run loop until `condition` holds or `timeout` elapses.
    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func pump(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}
