import AppKit
import SwiftUI

struct WizzzeeApp: App {
    @StateObject private var model = AppModel()

    init() {
        WindowTabbing.disable()
        TableFocus.install()
    }

    var body: some Scene {
        WindowGroup("Wizzzee") {
            ContentView(model: model)
                // Here and not in the view: the same view is put together
                // off screen to be drawn and to be tested, and neither of
                // those is someone opening the app.
                .onAppear { model.offerWelcome() }
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
            // All of it off while the guide is over the window. A menu's
            // keys go on working under a sheet, and these were acting on a
            // window behind it: with the guide up, ⌘R ran a scan and ⌘2
            // changed the tab.
            CommandGroup(replacing: .newItem) {
                Group {
                    // The header's Folder… button, on the key every app opens
                    // something with.
                    Button("Scan Folder…") { model.chooseFolder() }
                        .keyboardShortcut("o", modifiers: .command)
                        .disabled(!model.canChooseFolder)
                    Divider()
                    // On Finder's other key for it. Space, its first, marks a
                    // row here.
                    Button(model.previewURL == nil ? "Quick Look" : "Close Quick Look") {
                        model.togglePreview()
                    }
                    .keyboardShortcut("y", modifiers: .command)
                    .disabled(!model.canTogglePreview)
                    Divider()
                    // Space does the same on a row. That one is the table's own,
                    // so it can't be shown here; this is the one that can.
                    Button(model.selectionIsMarked ? "Unmark" : "Mark for Removal") {
                        model.markSelection()
                    }
                        .keyboardShortcut("m", modifiers: [.command, .shift])
                        .disabled(!model.canMarkSelection)
                    Divider()
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
                .disabled(model.showsWelcome)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                // The filter is on one tab of three; this is on all of them.
                Button("Find…") { model.beginSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.showsWelcome)
            }
            CommandGroup(after: .toolbar) {
                Group {
                    // The tab strip, which only ever answered a click.
                    ForEach(MainTab.allCases, id: \.self) { tab in
                        Button(tab.rawValue) { model.show(tab) }
                            .keyboardShortcut(
                                KeyEquivalent(tab.key),
                                modifiers: .command
                            )
                    }
                    Divider()
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
                .disabled(model.showsWelcome)
            }
            // In place of "Wizzzee Help", which opened a window to say there
            // was none.
            //
            // The first has no key. ⌘? is the one a Help item is given, and
            // it never arrives: the system takes it to open this menu, with
            // its search field ready and this item under it.
            CommandGroup(replacing: .help) {
                Button("Welcome to Wizzzee") { model.showWelcome() }
                    .disabled(!model.showsWelcome && !model.canShowWelcome)
                Button("Keyboard Shortcuts") { model.showWelcome(at: .keys) }
                    .keyboardShortcut("/", modifiers: .command)
                    .disabled(!model.showsWelcome && !model.canShowWelcome)
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

/// Gives a table the keyboard when it is clicked.
///
/// A table takes it on a click everywhere on the Mac, and these did until
/// the app was built against the newer SDK. In the build that ships, a click
/// selects the row and leaves the keyboard with the window: ↑ and ↓ move
/// nothing, and →, ← and Space do nothing, until Tab has been pressed to put
/// the focus there by hand. A local build is stamped with the older SDK and
/// behaves as it always did, which is how 0.5.0 went out like this.
enum TableFocus {
    @MainActor
    static func install() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { giveKeyboard(for: event) }
            return event
        }
    }

    /// Makes the table `event` is a click in the first responder of its
    /// window, ahead of the click, so that the row it selects is drawn as
    /// selected in a table that has the keyboard.
    @MainActor
    static func giveKeyboard(for event: NSEvent) {
        guard let table = table(clickedBy: event) else { return }
        table.window?.makeFirstResponder(table)
    }

    /// The table `event` is a click in, when it is one of the window's own
    /// and does not have the keyboard already.
    ///
    /// Not in a panel: the folder picker has a list of its own, and looks
    /// after it. Not under a sheet, either. The click is not going to
    /// arrive, and the keyboard is the sheet's.
    @MainActor
    static func table(clickedBy event: NSEvent) -> NSTableView? {
        guard event.type == .leftMouseDown, let window = event.window,
            !(window is NSPanel), window.attachedSheet == nil,
            let content = window.contentView
        else { return nil }
        // Asked of the view above the contents, which is in the window's
        // own coordinates, as the click is.
        let point = content.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        var view = content.hitTest(point)
        while let candidate = view, !(candidate is NSTableView) {
            view = candidate.superview
        }
        guard let table = view as? NSTableView, table.acceptsFirstResponder else {
            return nil
        }
        if let holder = window.firstResponder as? NSView, holder.isDescendant(of: table) {
            return nil
        }
        return table
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
