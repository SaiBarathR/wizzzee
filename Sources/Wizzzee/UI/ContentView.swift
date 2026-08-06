import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            Divider()

            if !model.hasFullDiskAccess && !model.dismissedAccessPrompt {
                FullDiskAccessBanner(model: model)
                Divider()
            }

            tabBar
            Divider()

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
        }
        // Eight tree columns need ~830pt and the legend's four need ~240pt.
        // Anything narrower and SwiftUI's Table silently clips its rightmost
        // columns instead of compressing them, so this is the real floor.
        // Enforced as the window minimum via .windowResizability(.contentMinSize).
        .frame(minWidth: 1160, minHeight: 660)
        .onChange(of: model.sizeMetric) {
            // The file list is ranked by the active metric, so it has to be
            // recomputed when the metric changes.
            model.refreshFileRows(immediately: true)
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
                get: { model.permanentDeleteTarget != nil },
                set: { if !$0 { model.permanentDeleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                if let target = model.permanentDeleteTarget {
                    model.permanentDeleteTarget = nil
                    model.deletePermanently(target)
                }
            }
            Button("Cancel", role: .cancel) { model.permanentDeleteTarget = nil }
        } message: {
            if let target = model.permanentDeleteTarget {
                Text(
                    "\(target.path)\n\n"
                        + "\(ByteFormat.decimal(target.size)) will be reclaimed. "
                        + "This bypasses the Trash and cannot be undone."
                )
            }
        }
    }

    private var deleteTitle: String {
        guard let target = model.permanentDeleteTarget else { return "" }
        if target.isDirectory {
            return "Permanently delete “\(target.name)” and "
                + "\(ByteFormat.count(target.dir.totalItems)) items inside it?"
        }
        return "Permanently delete “\(target.name)”?"
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button {
                    model.tab = tab
                    if tab == .files && model.fileRows.isEmpty {
                        model.refreshFileRows(immediately: true)
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: model.tab == tab ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
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
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
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
