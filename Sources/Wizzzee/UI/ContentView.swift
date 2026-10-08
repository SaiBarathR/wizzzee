import QuickLook
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    /// The window's, which is what Edit ▸ Undo and ⌘Z act on.
    @Environment(\.undoManager) private var undoManager
    /// How high the window's contents are. The shortest it goes until told.
    @State private var windowHeight: CGFloat = 660

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
                .placed(as: .header)
            Divider()

            if !model.hasFullDiskAccess && !model.dismissedAccessPrompt {
                FullDiskAccessBanner(model: model)
                Divider()
            }

            tabBar
            Divider()

            // The list of what is marked drops down from the bar that counts
            // it, which is in the row above with the tabs. It is as tall as
            // the rows it opened with, and not as the rows it has now:
            // everything under it would move with every mark.
            if model.showsMarks && !model.marks.isEmpty {
                MarksList(model: model)
                    .frame(
                        height: MarksList.height(
                            for: model.marksListRows,
                            inWindow: windowHeight
                        )
                    )
                    .placed(as: .marksList)
                Divider()
            }

            Group {
                switch model.tab {
                case .tree: TreeViewTab(model: model)
                case .files: FileViewTab(model: model)
                case .about: AboutTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            StatusBar(model: model)
                .placed(as: .statusBar)
        }
        // Eight tree columns need ~830pt and the legend's four need ~240pt.
        // Anything narrower and SwiftUI's Table silently clips its rightmost
        // columns instead of compressing them, so this is the real floor.
        // Enforced as the window minimum via .windowResizability(.contentMinSize).
        .frame(minWidth: 1160, minHeight: 660)
        // Measured, for the list of marks to be told how much there is. The
        // stack would not share it out: the tree and the treemap are an
        // AppKit split, which takes the least it will do with whatever it is
        // offered, and draws over the tabs above it to get it.
        .background(
            GeometryReader { window in
                Color.clear
                    .onAppear { windowHeight = window.size.height }
                    .onChange(of: window.size.height) {
                        windowHeight = window.size.height
                    }
            }
        )
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .quickLookPreview($model.previewURL)
        .sheet(isPresented: $model.showsWelcome) {
            WelcomeGuide(page: $model.welcomePage) { model.showsWelcome = false }
        }
        .alert(
            model.actionError ?? "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK") { model.actionError = nil }
        } message: {
            if let detail = model.actionErrorDetail { Text(detail) }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { !model.permanentDeleteTargets.isEmpty },
                set: { if !$0 { model.permanentDeleteTargets = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                let targets = model.permanentDeleteTargets
                model.permanentDeleteTargets = []
                model.deletePermanently(targets)
            }
            Button("Cancel", role: .cancel) { model.permanentDeleteTargets = [] }
        } message: {
            if !model.permanentDeleteTargets.isEmpty { Text(deleteMessage) }
        }
    }

    private var deleteTitle: String {
        let targets = model.permanentDeleteTargets
        if targets.count > 1 {
            return "Permanently delete \(ByteFormat.count(targets.count)) items?"
        }
        guard let target = targets.first else { return "" }
        if target.isDirectory {
            return "Permanently delete “\(target.name)” and "
                + "\(ByteFormat.counted(target.dir.totalItems, "item")) inside it?"
        }
        return "Permanently delete “\(target.name)”?"
    }

    private var deleteMessage: String {
        let targets = model.permanentDeleteTargets
        var warning =
            "\(ByteFormat.decimal(model.reclaimableSpace(targets))) will be "
            + "reclaimed. This bypasses the Trash and cannot be undone."
        // Hard-linked bytes stay on disk under their other names, so the figure
        // above deliberately excludes them and says so rather than quoting a
        // number that `df` will not agree with afterwards.
        if model.selectionSharesStorage(targets) {
            warning +=
                " Some of these are hard links whose data has another name on "
                + "disk; removing them frees nothing on their own."
        }
        if targets.count == 1, let single = targets.first {
            return "\(single.path)\n\n\(warning)"
        }

        // Names, not full paths: a dozen absolute paths make an alert unreadable,
        // and the list is only here to confirm the right things are about to go.
        let names = targets.map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let shown = names.prefix(6).joined(separator: "\n")
        let rest = names.count - 6
        let more = rest > 0 ? "\n…and \(ByteFormat.count(rest)) more" : ""
        return "\(shown)\(more)\n\n\(warning)"
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    Button {
                        model.show(tab)
                    } label: {
                        Text(tab.rawValue)
                            .font(
                                .system(
                                    size: 12,
                                    weight: model.tab == tab ? .semibold : .regular
                                )
                            )
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(
                                        model.tab == tab
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.clear
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help("\(tab.rawValue) (⌘\(tab.key))")
                }
            }
            .placed(as: .tabs)
            // What is marked, and what to do with it, beside the tabs: at
            // the top of the window, where a selection's own buttons are,
            // and in a row that is there already. It was across the foot of
            // the window, and before that a chip in the status bar.
            if model.marks.isEmpty {
                Spacer()
            } else {
                MarksBar(model: model)
                    .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 8)
        // One height with the bar in it or not, so that the first mark
        // moves nothing: the box that was just ticked stays under the
        // pointer.
        .frame(height: Self.tabRowHeight)
        .background(.bar)
    }

    private static let tabRowHeight: CGFloat = 42
}

/// Shown when the app can't read TCC-protected locations, which would otherwise
/// leave large parts of the disk silently missing from the totals.
struct FullDiskAccessBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 1) {
                Text("Wizzzee doesn't have Full Disk Access")
                    .font(.system(size: 11, weight: .semibold))
                Text(
                    "Without it, protected folders — Mail, Messages, Safari, other "
                        + "users' home folders — are skipped, and totals will read low."
                )
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open Settings…") { FullDiskAccess.openSystemSettings() }
            Button("Re-check") {
                model.hasFullDiskAccess = FullDiskAccess.isGranted()
            }
            Button {
                model.dismissedAccessPrompt = true
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Continue without Full Disk Access")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.10))
    }
}
