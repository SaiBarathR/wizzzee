import AppKit
import SwiftUI

struct WizzzeeApp: App {
    @StateObject private var model = AppModel()

    init() {
        WindowTabbing.disable()
    }

    var body: some Scene {
        WindowGroup("Wizzzee") {
            ContentView(model: model)
        }
        // Without an explicit default the window opens at whatever SwiftUI
        // infers from ideal sizes, which is far too small for a table plus a
        // treemap; contentMinSize makes the root view's minimum an actual
        // window constraint so the header can't be squeezed into ellipses.
        .defaultSize(width: 1460, height: 920)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Rescan") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                // One item with a changing verb rather than a checkmark, which
                // is how the system apps title a pane they can hide.
                Button(model.showsTreemap ? "Hide Treemap" : "Show Treemap") {
                    model.toggleTreemap()
                }
                .keyboardShortcut("t", modifiers: .command)
                Button("Zoom Treemap Out") { model.zoomOut() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canZoomOut || !model.showsTreemap)
                Button("Reset Treemap Zoom") { model.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!model.showsTreemap)
            }
        }
    }
}

/// AppKit gives every window group native tabbing, which puts Show Tab Bar and
/// Show All Tabs in the View menu and a "+" in a tab bar as soon as either is
/// used. Wizzzee's window is a single scan with its own in-app tabs, so a native
/// tab stacks a second identically-titled window behind the first with nothing
/// to tell them apart, and the app's own tab strip ends up under a system one
/// that looks just like it. Turning tabbing off removes the menu items and the
/// bar together.
enum WindowTabbing {
    @MainActor
    static func disable() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}
