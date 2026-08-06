import SwiftUI

/// Flat list of the biggest files anywhere in the scan, with a live filter.
struct FileViewTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            table
        }
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
            .onChange(of: model.fileQuery) { model.refreshFileRows() }

            if !model.fileQuery.isEmpty {
                Button("Clear") {
                    model.fileQuery = ""
                    model.refreshFileRows(immediately: true)
                }
                .buttonStyle(.borderless)
            }

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
        let total = model.fileRows.reduce(UInt64(0)) { $0 + $1.size }
        let cap = shown >= 1000 ? "largest 1,000" : "\(ByteFormat.count(shown)) files"
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
            TableColumn("File Name", value: \.name) { row in
                HStack(spacing: 5) {
                    Image(nsImage: FileActions.icon(for: row.ref))
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text(row.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 280)

            TableColumn("Folder", value: \.directory) { row in
                Text(row.directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .width(min: 180, ideal: 380)

            TableColumn("% of Scan", value: \.fractionOfRoot) { row in
                Text(ByteFormat.percent(row.fractionOfRoot))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 74, max: 110)

            TableColumn("Size", value: \.size) { row in
                Text(ByteFormat.decimal(row.size))
                    .font(.system(size: 11).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84, max: 120)

            TableColumn("Allocated", value: \.alloc) { row in
                Text(ByteFormat.decimal(row.alloc))
                    .font(.system(size: 11).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84, max: 120)

            TableColumn("Modified", value: \.mtime) { row in
                Text(ByteFormat.date(row.mtime))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 100, ideal: 130, max: 190)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onChange(of: model.fileSort) { model.resortFileRows() }
        .contextMenu(forSelectionType: NodeRef.self) { refs in
            ItemContextMenu(model: model, refs: refs)
        } primaryAction: { refs in
            if let ref = refs.first { FileActions.revealInFinder(ref.path) }
        }
    }
}
