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
            // With the treemap hidden there is nothing below to divide the
            // height with, so the table's floor is the only one that applies and
            // it takes the whole tab.
            .frame(minHeight: 160, idealHeight: model.showsTreemap ? 340 : 660)

            if model.showsTreemap {
                TreemapPane(model: model)
                    .frame(minHeight: 120, idealHeight: 260)
            }
        }
    }
}

struct TreeTable: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // A Set binding is what turns on macOS's native ⌘-click toggle,
        // ⇧-click range and ⇧-arrow extend — none of it needs a key handler.
        Table(
            model.treeRows,
            selection: $model.selection,
            sortOrder: $model.treeSort
        ) {
            TableColumn("Folder / File", sortUsing: TreeSort(.name)) { row in
                NameCell(model: model, row: row)
                    .leaving(row.ref, in: model)
            }
            .width(min: 150, ideal: 270)

            TableColumn("% of Parent", sortUsing: TreeSort(.percent)) { row in
                PercentCell(
                    fraction: row.ref.fractionOfParent(using: model.sizeMetric)
                )
                .leaving(row.ref, in: model)
            }
            .width(min: 68, ideal: 88, max: 140)

            // Space on disk leads, next to the bars that are drawn from it
            // unless someone asks otherwise. With Size in front, the first
            // figure read for a folder was its files' combined length: one
            // holding a sparse image read 1.2 TB beside a bar worked out from
            // the 198 GB it occupied.
            //
            // The two keep their places whichever is on show, and the one that
            // isn't is set back instead. A column that changed what it held
            // with the picker would be asking the table to follow a sort
            // comparator from one column to the other between two redraws.
            TableColumn("On Disk", sortUsing: TreeSort(.allocated)) { row in
                numeric(ByteFormat.decimal(row.ref.alloc))
                    .foregroundStyle(model.sizeMetric.emphasis(of: .allocated))
                    .leaving(row.ref, in: model)
            }
            .width(min: 62, ideal: 78, max: 120)

            TableColumn("Size", sortUsing: TreeSort(.size)) { row in
                numeric(ByteFormat.decimal(row.ref.size))
                    .foregroundStyle(model.sizeMetric.emphasis(of: .logical))
                    .leaving(row.ref, in: model)
            }
            .width(min: 62, ideal: 78, max: 120)

            TableColumn("Items", sortUsing: TreeSort(.items)) { row in
                numeric(row.ref.isDirectory ? ByteFormat.count(row.ref.dir.totalItems) : "")
                    .leaving(row.ref, in: model)
            }
            .width(min: 48, ideal: 60, max: 110)

            TableColumn("Files", sortUsing: TreeSort(.files)) { row in
                numeric(row.ref.isDirectory ? ByteFormat.count(row.ref.dir.totalFiles) : "")
                    .leaving(row.ref, in: model)
            }
            .width(min: 48, ideal: 60, max: 110)

            TableColumn("Folders", sortUsing: TreeSort(.folders)) { row in
                numeric(row.ref.isDirectory ? ByteFormat.count(row.ref.dir.totalDirs) : "")
                    .leaving(row.ref, in: model)
            }
            .width(min: 48, ideal: 60, max: 110)

            TableColumn("Modified", sortUsing: TreeSort(.modified)) { row in
                Text(ByteFormat.date(row.ref.mtime))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .leaving(row.ref, in: model)
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
            // As well as, not instead of: a second name for a sparse image is
            // both, and "hard link" alone leaves its two sizes unexplained.
            if let file = row.ref.file {
                StorageNote(file: file)
            }
            // On the row that was asked for, not on everything inside it: a
            // folder's contents going grey with it says the rest.
            if model.removing.contains(row.ref) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
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
        guard let file = row.ref.file else { return .secondary }
        if file.isDuplicateLink { return .secondary }
        if file.isSymlink { return .secondary }
        return .primary
    }

    private var exclusionNote: String? {
        guard row.ref.isDirectory else {
            guard let file = row.ref.file else { return nil }
            if file.isDuplicateLink { return "hard link" }
            if file.isSymlink { return "alias" }
            return nil
        }
        switch row.ref.dir.exclusion {
        case .none: return nil
        case .permissionDenied: return "no access"
        case .otherVolume: return "other volume"
        case .alreadyCounted: return "counted elsewhere"
        case .partiallyRead: return "partly read"
        }
    }
}

extension View {
    /// Sets a cell back while the batch in hand is removing what its row
    /// names, so it reads as on its way out for as long as that takes.
    func leaving(_ ref: NodeRef, in model: AppModel) -> some View {
        opacity(model.isBeingRemoved(ref) ? 0.4 : 1)
    }
}

/// The word beside a file whose length is not the space it takes — a sparse
/// image, or one a cloud provider is holding — with the two figures behind it
/// on hover. Without it the only sign is a pair of columns that disagree, and
/// nothing says which of them to believe.
struct StorageNote: View {
    let file: FileEntry

    var body: some View {
        if let note = file.storageNote {
            Text(note)
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .help(file.storageExplanation ?? note)
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
