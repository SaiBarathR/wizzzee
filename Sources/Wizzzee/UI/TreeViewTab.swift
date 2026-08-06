import SwiftUI

/// Hierarchical folder table over the treemap, split so both can be resized.
struct TreeViewTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VSplitView {
            HSplitView {
                // HSplitView hands surplus width to its trailing view, so the
                // legend is capped: left uncapped it grows to its maximum and
                // starves the table, which then clips its last column.
                TreeTable(model: model)
                    .frame(minWidth: 400, idealWidth: 880, maxWidth: .infinity)
                ExtensionLegend(model: model)
                    .frame(minWidth: 240, idealWidth: 252, maxWidth: 300)
            }
            .frame(minHeight: 160, idealHeight: 340)

            TreemapPane(model: model)
                .frame(minHeight: 120, idealHeight: 260)
        }
    }
}

struct TreeTable: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Table(
            model.treeRows,
            selection: selectionBinding,
            sortOrder: $model.treeSort
        ) {
            TableColumn("Folder / File", sortUsing: TreeSort(.name)) { row in
                NameCell(model: model, row: row)
            }
            .width(min: 150, ideal: 270)

            TableColumn("% of Parent", sortUsing: TreeSort(.percent)) { row in
                PercentCell(
                    fraction: row.ref.fractionOfParent(using: model.sizeMetric)
                )
            }
            .width(min: 68, ideal: 88, max: 140)

            TableColumn("Size", sortUsing: TreeSort(.size)) { row in
                numeric(ByteFormat.decimal(row.ref.size))
            }
            .width(min: 62, ideal: 78, max: 120)

            TableColumn("Allocated", sortUsing: TreeSort(.allocated)) { row in
                numeric(ByteFormat.decimal(row.ref.alloc))
            }
            .width(min: 62, ideal: 78, max: 120)

            TableColumn("Items", sortUsing: TreeSort(.items)) { row in
                numeric(row.ref.isDirectory ? ByteFormat.count(row.ref.dir.totalItems) : "")
            }
            .width(min: 48, ideal: 60, max: 110)

            TableColumn("Files", sortUsing: TreeSort(.files)) { row in
                numeric(row.ref.isDirectory ? ByteFormat.count(row.ref.dir.totalFiles) : "")
            }
            .width(min: 48, ideal: 60, max: 110)

            TableColumn("Folders", sortUsing: TreeSort(.folders)) { row in
                numeric(row.ref.isDirectory ? ByteFormat.count(row.ref.dir.totalDirs) : "")
            }
            .width(min: 48, ideal: 60, max: 110)

            TableColumn("Modified", sortUsing: TreeSort(.modified)) { row in
                Text(ByteFormat.date(row.ref.mtime))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .width(min: 96, ideal: 116, max: 200)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onChange(of: model.treeSort) { model.rebuildTreeRows() }
        .contextMenu(forSelectionType: NodeRef.self) { refs in
            ItemContextMenu(model: model, refs: refs)
        } primaryAction: { refs in
            // Double-click: open a folder, reveal a file.
            guard let ref = refs.first else { return }
            if ref.isDirectory {
                model.toggleExpansion(ref.dir)
            } else {
                FileActions.revealInFinder(ref.path)
            }
        }
    }

    private var selectionBinding: Binding<NodeRef?> {
        Binding(
            get: { model.selection },
            set: { model.selection = $0 }
        )
    }

    private func numeric(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Indented name cell with the disclosure control and a type icon.
private struct NameCell: View {
    @ObservedObject var model: AppModel
    let row: TreeRow

    var body: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: CGFloat(row.depth) * 13, height: 1)

            if row.isExpandable {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleExpansion(row.ref.dir) }
            } else {
                Color.clear.frame(width: 11, height: 1)
            }

            Image(nsImage: FileActions.icon(for: row.ref))
                .resizable()
                .frame(width: 14, height: 14)

            Text(displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(nameColor)

            if let note = exclusionNote {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }

    private var displayName: String {
        // The root row carries the full scanned path.
        row.ref.isDirectory && row.ref.dir.isRoot
            ? row.ref.dir.name : row.ref.name
    }

    private var nameColor: Color {
        if row.ref.isDirectory { return .primary }
        let file = row.ref.dir.files[Int(row.ref.fileIndex)]
        if file.isDuplicateLink { return .secondary }
        if file.isSymlink { return .secondary }
        return .primary
    }

    private var exclusionNote: String? {
        guard row.ref.isDirectory else {
            let file = row.ref.dir.files[Int(row.ref.fileIndex)]
            if file.isDuplicateLink { return "hard link" }
            if file.isSymlink { return "alias" }
            return nil
        }
        switch row.ref.dir.exclusion {
        case .none: return nil
        case .permissionDenied: return "no access"
        case .otherVolume: return "other volume"
        case .alreadyCounted: return "counted elsewhere"
        }
    }
}

/// WizTree's "% of Parent" column: a proportional bar behind the number.
private struct PercentCell: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
                Text(ByteFormat.percent(fraction))
                    .font(.system(size: 10).monospacedDigit())
                    .padding(.leading, 4)
            }
        }
        .frame(height: 14)
    }

    /// Warmer as an entry dominates its parent, so hot spots stand out.
    private var barColor: Color {
        if fraction >= 0.5 { return .orange.opacity(0.55) }
        if fraction >= 0.2 { return .yellow.opacity(0.45) }
        return .accentColor.opacity(0.35)
    }
}
