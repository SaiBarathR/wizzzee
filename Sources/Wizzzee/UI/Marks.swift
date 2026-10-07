import SwiftUI

/// The checkbox at the head of a row, which puts it among the marks.
///
/// A folder's mark stands for everything inside it, so what is inside shows
/// as ticked and can't be changed on its own, and a folder with only some of
/// its contents marked shows a dash.
struct MarkBox: View {
    @ObservedObject var model: AppModel
    let ref: NodeRef

    var body: some View {
        let state = model.markState(ref)
        Group {
            if state == .covered {
                Image(systemName: "checkmark.square.fill")
                    .foregroundStyle(.tertiary)
                    .help("Inside a marked folder, and going with it")
            } else if model.canMark(ref) {
                Button {
                    model.toggleMarks([ref])
                } label: {
                    Image(systemName: Self.symbol(for: state))
                        .foregroundStyle(
                            state == .none
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(Color.accentColor)
                        )
                        // The whole cell takes the click, not just the lines
                        // of an empty square.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The marks stand still while a batch runs.
                .disabled(model.isDeleting)
                .help(Self.help(for: state))
                .accessibilityLabel(
                    (state == .marked ? "Unmark " : "Mark ") + ref.name
                )
            } else if state == .partial {
                // A scan's root can't be marked, and is the one row that is
                // above everything that can: it still says something is.
                Image(systemName: Self.symbol(for: state))
                    .foregroundStyle(.secondary)
                    .help("Something inside is marked. This can’t be marked itself.")
            } else {
                // Nothing to click, and the reason on hand: a scan's root,
                // or something on the sealed system volume.
                Color.clear
                    .frame(width: 12, height: 12)
                    .help("Can’t be removed, so it can’t be marked")
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity)
    }

    private static func symbol(for state: AppModel.MarkState) -> String {
        switch state {
        case .marked, .covered: return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
        case .none: return "square"
        }
    }

    private static func help(for state: AppModel.MarkState) -> String {
        switch state {
        case .marked: return "Marked for removal — click to take the mark off"
        case .partial: return "Something inside is marked — click to mark all of it"
        case .none, .covered: return "Mark for removal (Space)"
        }
    }
}

/// The status bar's count of what is marked, which opens the list of it.
struct MarksChip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button {
            model.showsMarks.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.square.fill")
                Text(model.marksSummary)
                Image(systemName: model.showsMarks ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
            }
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
        .help(model.showsMarks ? "Hide the marked items" : "Show the marked items")
        .accessibilityLabel(
            (model.showsMarks ? "Hide" : "Show") + " marked items, "
                + model.marksSummary
        )
    }
}

/// The marked items, each with its size, and what to do with the lot.
///
/// Above the status bar on every tab, since marks are gathered from all of
/// them: the tree, the file list and the treemap.
struct MarksDrawer: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.markedItems) { ref in
                        MarkedRow(model: model, ref: ref)
                    }
                }
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Marked for removal")
                .font(.system(size: 11, weight: .semibold))
            Text(total)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .help(
                    "The space on disk that removing all of these gives back. "
                        + "A hard link whose data has another name on disk "
                        + "counts for nothing."
                )

            Spacer()

            Button("Clear") { model.clearMarks() }
                .help("Take every mark off. Nothing is removed.")
            Button("Move to Trash") { model.trashMarked() }
            Button("Delete…") { model.confirmDeletingMarked() }
        }
        .controlSize(.small)
        // Off while a batch runs, like every other way of starting one.
        .disabled(model.isDeleting)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// The figure the status bar gives, named here for what it is: space on
    /// disk, whichever measure the rows below are showing.
    private var total: String {
        ByteFormat.counted(model.marks.count, "item") + "  •  "
            + ByteFormat.decimal(model.markedBytes) + " on disk"
    }
}

private struct MarkedRow: View {
    @ObservedObject var model: AppModel
    let ref: NodeRef

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.setMarked([ref], false)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(model.isDeleting)
            .help("Take the mark off. Nothing is removed.")
            .accessibilityLabel("Unmark " + ref.name)

            Image(nsImage: FileActions.icon(for: ref))
                .resizable()
                .frame(width: 14, height: 14)
            Text(ref.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(folder)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 8)

            if ref.isDirectory {
                Text(ByteFormat.counted(ref.dir.totalItems, "item"))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(ByteFormat.decimal(ref.bytes(using: model.sizeMetric)))
                .font(.system(size: 11).monospacedDigit())
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // Where it is, on a click: the row in the tree, with the folders
        // above it opened.
        .onTapGesture {
            model.show(.tree)
            model.revealInTree(ref)
        }
        .leaving(ref, in: model)
        .help(ref.path)
    }

    /// The folder it is in, which is what tells two files of one name apart.
    private var folder: String {
        (ref.path as NSString).deletingLastPathComponent
    }
}
