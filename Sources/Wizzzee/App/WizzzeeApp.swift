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
            // In place of New Window, which a single scan has no use for, and
            // where Finder keeps the same two on the same keys.
            //
            // The keys stay on the items whatever is going on. Taking them
            // off while the filter was being typed in left them off: a menu
            // item is only given a changed key when its menu is next opened,
            // so ⌘⌫ did nothing on a row picked straight afterwards. Greyed
            // out is enough — a key that matches a disabled item goes on to
            // whatever has the keyboard.
            CommandGroup(replacing: .newItem) {
                Button("Move to Trash") {
                    if TextEntry.isUnderWay {
                        TextEntry.deleteToBeginningOfLine()
                    } else {
                        model.trashSelection()
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canUseDeleteKeys)
                Button("Delete Permanently…") {
                    if !TextEntry.isUnderWay { model.confirmDeletingSelection() }
                }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(!model.canUseDeleteKeys)
            }
            CommandGroup(after: .toolbar) {
                // Disabled rather than silently ignored: `startScan` refuses
                // while a scan or a delete is running, so ⌘R then looked like a
                // broken shortcut or a wedged app.
                Button("Rescan") { model.startScan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canStartScan)
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

/// Whether the keyboard is in a text field, asked of AppKit at the moment a
/// delete key lands.
///
/// The model already keeps the keys off while the filter has focus, from what
/// SwiftUI reports. That report is the only thing between ⌘⌫ in a text field
/// and the selection going to the Trash unasked, so it is not taken on trust:
/// if a field is being edited when the action arrives, the key is given back
/// to it.
enum TextEntry {
    @MainActor
    static var isUnderWay: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    /// What ⌘⌫ means to a text field.
    @MainActor
    static func deleteToBeginningOfLine() {
        NSApp.sendAction(
            #selector(NSResponder.deleteToBeginningOfLine(_:)),
            to: nil,
            from: nil
        )
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
