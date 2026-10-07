import SwiftUI

/// The treemap plus its zoom breadcrumb.
struct TreemapPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            // The map highlights a single tile, so it tracks the selection only
            // when there is exactly one — a multi-row selection made in a table
            // has no meaningful outline here. Clicking a tile still replaces the
            // whole selection.
            TreemapCanvas(
                root: model.treemapRoot,
                metric: model.sizeMetric,
                selection: model.primarySelection,
                revision: model.treeRevision,
                liveRevision: { model.treeRevision },
                layoutQueue: model.treemapQueue,
                onSelect: { ref in model.selection = [ref] },
                onZoom: { dir in model.zoom(into: dir) },
                onHover: { ref in model.hoveredRef = ref },
                onOutline: { ref in model.treemapOutline = ref },
                marks: model.marks,
                onMark: { ref in model.toggleMarks([ref]) },
                focus: model.focusedTypeIndex
            )
            .contextMenu {
                if !model.selection.isEmpty {
                    ItemContextMenu(model: model, refs: model.selection)
                }
            }
        }
        // A map that has been put away outlines nothing, and is not there to
        // say so.
        .onDisappear { model.treemapOutline = nil }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Button {
                model.zoomOut()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canZoomOut)
            .help("Zoom out to the parent folder")

            Button {
                model.resetZoom()
            } label: {
                Image(systemName: "arrow.up.to.line")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canZoomOut)
            .help("Back to the scan root")

            Text(model.treemapRoot?.path ?? "—")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 4)

            // Beside the map it explains: most of that has just gone dark.
            TypeFocusChip(model: model)

            if let hovered = model.hoveredRef {
                Text(hovered.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Text(ByteFormat.decimal(hovered.bytes(using: model.sizeMetric)))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Double-click a folder to zoom in  •  ⌘-click to mark")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.bar)
    }
}

/// Top file types by total size, colored to match the treemap.
struct ExtensionLegend: View {
    @ObservedObject var model: AppModel

    /// Ranked by whichever metric is showing, so the legend order matches the
    /// treemap's tile sizes.
    ///
    /// A computed property here re-sorted every extension in the scan —
    /// thousands on a real disk — on each body evaluation, which this view gets
    /// for any change published by the model, hovering the treemap included.
    /// Both orders are instead kept by the scan result, which re-ranks them
    /// when a delete changes what the types hold.
    private var stats: [ExtensionStat] {
        guard let result = model.result else { return [] }
        if showsEveryType {
            return model.sizeMetric == .logical
                ? result.allBySize : result.allByAllocated
        }
        return model.sizeMetric == .logical
            ? result.topBySize : result.topByAllocated
    }

    /// Whether the list runs to every type in the scan. It starts at the
    /// largest few: a real disk has thousands, and this view is handed all of
    /// its rows again for anything the model publishes.
    @State private var showsEveryType = false

    /// The row picked, which is the type in focus. Picking another moves the
    /// focus; a click below the last row, or ⌘-click on the one picked, takes
    /// it off, as it deselects a row in any table.
    private var focus: Binding<ExtensionStat.ID?> {
        Binding(
            get: { model.focusedType },
            set: { model.focusType($0) }
        )
    }

    private func weight(_ stat: ExtensionStat) -> UInt64 {
        model.sizeMetric == .logical ? stat.size : stat.alloc
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("File Types")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if let total = model.result?.typeCount,
                    total > ScanResult.legendLength
                {
                    Button {
                        showsEveryType.toggle()
                    } label: {
                        Text(
                            showsEveryType
                                ? "all \(ByteFormat.count(total))"
                                : "top \(stats.count) of \(ByteFormat.count(total))"
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(
                        showsEveryType
                            ? "List only the \(ScanResult.legendLength) largest types"
                            : "List all \(ByteFormat.count(total)) types"
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)

            if stats.isEmpty {
                Spacer()
                Text("No scan yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Table(stats, selection: focus) {
                    TableColumn("Type") { stat in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(TreemapPalette.color(stat.colorIndex))
                                .frame(width: 11, height: 11)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(.black.opacity(0.25), lineWidth: 0.5)
                                )
                            Text(stat.displayName)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                    }
                    .width(min: 58, ideal: 66)

                    TableColumn(
                        model.sizeMetric == .logical ? "Size" : "On Disk"
                    ) { stat in
                        Text(ByteFormat.decimal(weight(stat)))
                            .font(.system(size: 11).monospacedDigit())
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 58, ideal: 68)

                    TableColumn("%") { stat in
                        Text(ByteFormat.percent(share(stat)))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(min: 44, ideal: 48)

                    TableColumn("Files") { stat in
                        Text(ByteFormat.compactCount(stat.count))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .help(ByteFormat.counted(stat.count, "file"))
                    }
                    .width(min: 44, ideal: 50, max: 70)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .onExitCommand { model.focusType(nil) }
            }
        }
    }

    private func share(_ stat: ExtensionStat) -> Double {
        guard let root = model.result?.root else { return 0 }
        let total = model.sizeMetric == .logical ? root.totalSize : root.totalAlloc
        guard total > 0 else { return 0 }
        return Double(weight(stat)) / Double(total)
    }
}

/// Names the file type in focus, and is the way back out of it.
///
/// Shown wherever the focus has changed what is on screen — beside the map it
/// has dimmed, and above the file list it has narrowed — so neither is left
/// looking broken to someone who picked the type on the other tab.
struct TypeFocusChip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let stat = model.focusedTypeStat {
            Button {
                model.focusType(nil)
            } label: {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TreemapPalette.color(stat.colorIndex))
                        .frame(width: 9, height: 9)
                    Text("\(stat.displayName) only")
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 10))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.22))
                )
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Showing \(stat.displayName) files only. Click to show every type.")
            .accessibilityLabel("Stop showing only \(stat.displayName) files")
        }
    }
}
