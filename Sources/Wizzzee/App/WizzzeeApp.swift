import SwiftUI

struct WizzzeeApp: App {
    @StateObject private var model = AppModel()

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
                Button("Zoom Treemap Out") { model.zoomOut() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.canZoomOut)
                Button("Reset Treemap Zoom") { model.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}
