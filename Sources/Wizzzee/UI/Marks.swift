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

/// What is marked, what removing it would free, and what to do about it.
///
/// In the row the tabs are in, filling what they leave of it, from the first
/// mark to the last and on every tab. It has been a chip in the status bar's
/// small type, and then a bar across the foot of the window: both were at
/// the far end of the window from the boxes being ticked and from every
/// other control that acts on a selection, and someone new to the app did
/// not look there.
struct MarksBar: View {
    @ObservedObject var model: AppModel
    /// False for the moment the bar is first put up, which it spends lit.
    @State private var hasSettled = false

    var body: some View {
        HStack(spacing: 10) {
            // The box that was ticked, so the bar reads as being about those.
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(model.marksHeadline)
                .font(.system(size: 13, weight: .semibold))
                .layoutPriority(2)
            Text(ByteFormat.decimal(model.markedBytes) + " on disk")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .layoutPriority(1)
                .help(
                    "The space on disk that removing all of these gives back. "
                        + "A hard link whose data has another name on disk "
                        + "counts for nothing."
                )
            listToggle

            Spacer(minLength: 8)

            // Off while a batch runs, like every other way of starting one.
            Group {
                Button("Clear Marks") { model.clearMarks() }
                    .help("Take every mark off. Nothing is removed.")
                    .placed(as: .clearMarks)
                // The one that can be taken back, so the one put forward.
                Button("Move to Trash") { model.trashMarked() }
                    .buttonStyle(.borderedProminent)
                    .help("Move everything marked to the Trash. ⌘Z puts it back.")
                    .placed(as: .trashMarked)
                Button("Delete…") { model.confirmDeletingMarked() }
                    .help("Delete everything marked for good, after asking")
                    .placed(as: .deleteMarked)
            }
            .disabled(model.isDeleting)
            .fixedSize()
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        // A tinted strip with a line of the same colour round it. It
        // arrives lit and fades to that: it comes and goes, and has to be
        // seen arriving by someone looking at a checkbox further down.
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(hasSettled ? 0.16 : 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { hasSettled = true }
        }
    }

    /// Opens the list of what is marked, and shuts it. The list drops down
    /// under the row and the bar stays put, so this is under the pointer
    /// for both.
    private var listToggle: some View {
        Button {
            model.showsMarks.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(model.showsMarks ? "Hide List" : "Show List")
                Image(systemName: model.showsMarks ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .fixedSize()
        .help(
            model.showsMarks
                ? "Hide the marked items"
                : "Show each marked item, with its size and where it is"
        )
        .accessibilityLabel(
            model.showsMarks ? "Hide the marked items" : "Show the marked items"
        )
        .placed(as: .showMarksList)
    }
}

/// The marked items, each with its size and a way to take its mark back off.
///
/// Under the bar that counts them, on every tab, since marks are gathered
/// from all of them: the tree, the file list and the treemap.
struct MarksList: View {
    @ObservedObject var model: AppModel

    /// What the rest of the window needs when it has the most in it and
    /// each part is at its least: the header, the banner about Full Disk
    /// Access, the tabs' row with the bar in it, the tree over the treemap
    /// and the status bar. Added up from the window on screen, with a few
    /// points to spare.
    static let restOfWindow: CGFloat = 510

    /// A row for each of `count` up to ten, and no more than a window
    /// `window` high can spare: past either the list scrolls. `count` is how
    /// many were marked when the list was opened, which is what keeps the
    /// table under it still while more are.
    ///
    /// Given the height its rows asked for whatever the window's, a long
    /// list took room the window did not have. At its shortest, what was
    /// above the list was drawn over itself to fit — the tree across the
    /// tabs — or went off the top, and the status bar, where a delete's
    /// Stop is, off the foot.
    static func height(for count: Int, inWindow window: CGFloat) -> CGFloat {
        let rows = CGFloat(count) * 22 + 2
        return max(min(rows, 46), min(rows, 220, window - restOfWindow))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.markedItems) { ref in
                    MarkedRow(model: model, ref: ref)
                }
            }
        }
        .background(.background)
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
