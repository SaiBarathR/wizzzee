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
                onSelect: { ref in model.select(fromMap: ref) },
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

            ZoomTrail(model: model)

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

/// The path of the folder the map is zoomed to, each folder in it a button
/// that zooms back out to there.
///
/// It was one line of text. Getting from five levels down to two levels down
/// was three clicks on the up arrow, or back to the root and in again.
struct ZoomTrail: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let trail = model.zoomTrail
        if trail.isEmpty {
            Text("—")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else {
            // The whole of it where there is room, and otherwise the root and
            // as many of the nearest folders as fit: the far end is the one
            // that says where the map is.
            //
            // Every one of these is something to show: an empty candidate
            // always fits, and would be chosen over a path that does not.
            ViewThatFits(in: .horizontal) {
                steps(trail, keeping: trail.count)
                steps(trail, keeping: 3)
                steps(trail, keeping: 2)
                steps(trail, keeping: 1)
                whereItIs(trail)
            }
            .font(.system(size: 10))
        }
    }

    /// The root, then the last `tail` folders, with a gap marked between
    /// them where some are left out.
    private func steps(_ trail: [DirNode], keeping tail: Int) -> some View {
        let last = trail.count - 1
        let kept = max(1, last - tail + 1)..<trail.count
        return HStack(spacing: 3) {
            step(trail[0], isCurrent: last == 0)
            if kept.lowerBound > 1 {
                separator
                Text("…").foregroundStyle(.tertiary)
            }
            ForEach(kept, id: \.self) { index in
                separator
                step(trail[index], isCurrent: index == last)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// What is left when not even the root and one folder fit: the folder
    /// the map is on, cut short in the middle if it has to be.
    private func whereItIs(_ trail: [DirNode]) -> some View {
        HStack(spacing: 3) {
            if trail.count > 1 {
                Text("…").foregroundStyle(.tertiary)
                separator
            }
            Text(Self.label(for: trail[trail.count - 1]))
                .foregroundStyle(.primary)
                .truncationMode(.middle)
                .help(trail[trail.count - 1].path)
        }
        .lineLimit(1)
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    /// What a folder is called in the path. A scan's root is named by the
    /// whole path it was scanned at, which is its name everywhere else and
    /// here would be wider than the strip: every way of showing the path
    /// that still had buttons in it then failed to fit, and what was left
    /// was the last folder's name with nothing to click.
    static func label(for dir: DirNode) -> String {
        guard dir.isRoot else { return dir.name }
        let last = (dir.name as NSString).lastPathComponent
        return last.isEmpty ? dir.name : last
    }

    /// The most room one folder's name is given before it is cut short.
    private static let widest: CGFloat = 180

    @ViewBuilder
    private func step(_ dir: DirNode, isCurrent: Bool) -> some View {
        if isCurrent {
            // Where the map is. Nothing to zoom to, so nothing to click.
            Text(Self.label(for: dir))
                .foregroundStyle(.primary)
                .truncationMode(.middle)
                .frame(maxWidth: Self.widest)
                .help(dir.path)
        } else {
            Button {
                model.zoom(into: dir)
            } label: {
                Text(Self.label(for: dir))
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .frame(maxWidth: Self.widest)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom out to \(dir.path)")
        }
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
    ///
    /// The list starts at the largest few: a real disk has thousands, and
    /// this view is handed all of its rows again for anything the model
    /// publishes.
    private var stats: [ExtensionStat] { model.legendTypes }

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
                        model.listsEveryType.toggle()
                    } label: {
                        Text(
                            model.listsEveryType
                                ? "all \(ByteFormat.count(total))"
                                : "top \(ScanResult.legendLength) of "
                                    + ByteFormat.count(total)
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(
                        model.listsEveryType
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
