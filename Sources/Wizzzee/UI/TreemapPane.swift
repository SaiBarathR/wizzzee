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
                onSelect: { ref in model.selection = [ref] },
                onZoom: { dir in model.zoom(into: dir) },
                onHover: { ref in model.hoveredRef = ref }
            )
            .contextMenu {
                if !model.selection.isEmpty {
                    ItemContextMenu(model: model, refs: model.selection)
                }
            }
        }
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

            if let hovered = model.hoveredRef {
                Text(hovered.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Text(ByteFormat.decimal(hovered.size))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Double-click a folder to zoom in")
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
    /// The allocated order is instead derived once per scan and cached.
    private var stats: [ExtensionStat] {
        guard let result = model.result else { return [] }
        if model.sizeMetric == .logical {
            // Already stored in descending size order.
            return Array(result.extensionStats.prefix(40))
        }
        return result.topByAllocated
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
                if let total = model.result?.extensionStats.count, total > stats.count {
                    Text("top \(stats.count) of \(ByteFormat.count(total))")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
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
                Table(stats) {
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
                            .help("\(ByteFormat.count(stat.count)) files")
                    }
                    .width(min: 44, ideal: 50, max: 70)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
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
