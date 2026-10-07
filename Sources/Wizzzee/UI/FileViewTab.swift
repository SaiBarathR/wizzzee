import SwiftUI

/// Flat list of the biggest files anywhere in the scan, with a live filter.
struct FileViewTab: View {
    @ObservedObject var model: AppModel
    @FocusState private var filterHasFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            table
        }
        // Leaving the tab takes the field away without it ever losing focus,
        // which would leave the delete keys off for good.
        .onDisappear { model.isEditingFilter = false }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField(
                "Filter by name, or type a / to match the whole path",
                text: $model.fileQuery
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 460)
            .focused($filterHasFocus)
            .onChange(of: filterHasFocus) { model.isEditingFilter = filterHasFocus }
            .onChange(of: model.fileQuery) { model.refreshFileRows() }

            if !model.fileQuery.isEmpty {
                Button("Clear") {
                    model.fileQuery = ""
                    model.refreshFileRows(immediately: true)
                }
                .buttonStyle(.borderless)
            }

            // The list is one type's files and no others while this is up.
            TypeFocusChip(model: model)

            if model.isFilteringFiles {
                ProgressView().controlSize(.small)
            }

            Spacer()

            Text(summary)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var summary: String {
        guard model.result != nil else { return "" }
        let shown = model.fileRows.count
        // Totalled with the metric the rows were ranked by, so the figure agrees
        // with the column the list is sorted on rather than quietly reporting
        // logical size while "On Disk" is what's on show.
        let logical = model.sizeMetric == .logical
        let total = model.fileRows.reduce(UInt64(0)) {
            $0 + (logical ? $1.size : $1.alloc)
        }
        let cap = shown >= 1000 ? "largest 1,000" : ByteFormat.counted(shown, "file")
        return "\(cap) • \(ByteFormat.decimal(total))"
    }

    private var table: some View {
        // As in the Tree View, the Set binding is what gives the table macOS's
        // native ⌘-click and ⇧-arrow multi-select.
        Table(
            model.fileRows,
            selection: $model.selection,
            sortOrder: $model.fileSort
        ) {
            TableColumn("") { row in
                MarkBox(model: model, ref: row.ref)
            }
            .width(16)

            TableColumn("File Name", value: \.name) { row in
                HStack(spacing: 5) {
                    Image(nsImage: FileActions.icon(for: row.ref))
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(row.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let file = row.ref.file {
                        StorageNote(file: file)
                    }
                    if model.removing.contains(row.ref) {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    }
                }
                .leaving(row.ref, in: model)
            }
            .width(min: 160, ideal: 280)

            TableColumn("Folder", value: \.directory) { row in
                Text(row.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .leaving(row.ref, in: model)
            }
            .width(min: 180, ideal: 380)

            TableColumn("% of Scan", value: \.fractionOfRoot) { row in
                Text(ByteFormat.percent(row.fractionOfRoot))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .leaving(row.ref, in: model)
            }
            .width(min: 64, ideal: 74, max: 110)

            // As in the Tree View: space on disk leads, and whichever of the
            // two is not on show is set back.
            TableColumn("On Disk", value: \.alloc) { row in
                Text(ByteFormat.decimal(row.alloc))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(model.sizeMetric.emphasis(of: .allocated))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .leaving(row.ref, in: model)
            }
            .width(min: 70, ideal: 84, max: 120)

            TableColumn("Size", value: \.size) { row in
                Text(ByteFormat.decimal(row.size))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(model.sizeMetric.emphasis(of: .logical))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .leaving(row.ref, in: model)
            }
            .width(min: 70, ideal: 84, max: 120)

            TableColumn("Modified", value: \.mtime) { row in
                Text(ByteFormat.date(row.mtime))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .leaving(row.ref, in: model)
            }
            .width(min: 100, ideal: 130, max: 190)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onChange(of: model.fileSort) { model.resortFileRows() }
        .onKeyPress(.space) { model.markSelection() ? .handled : .ignored }
        .contextMenu(forSelectionType: NodeRef.self) { refs in
            ItemContextMenu(model: model, refs: refs)
        } primaryAction: { refs in
            if let ref = refs.first { FileActions.revealInFinder(ref.path) }
        }
    }
}
