import SwiftUI

/// Actions available on the selected files and folders, in both tables and the
/// treemap.
struct ItemContextMenu: View {
    @ObservedObject var model: AppModel
    let refs: Set<NodeRef>

    /// SwiftUI re-evaluates this menu's body after a delete has already changed
    /// the tree, so what it captured has to be re-checked rather than trusted.
    private var live: Set<NodeRef> { refs.filter { !$0.isStale } }

    var body: some View {
        let refs = live
        if refs.count > 1 {
            manyItems(refs)
        } else if let ref = refs.first {
            oneItem(ref)
        }
    }

    @ViewBuilder
    private func oneItem(_ ref: NodeRef) -> some View {
        Button("Reveal in Finder") { FileActions.revealInFinder(ref.path) }
        Button(ref.isDirectory ? "Open Folder" : "Open") {
            FileActions.open(ref.path)
        }
        Button("Quick Look") { model.preview(ref) }
        Button("Open in Terminal") { FileActions.openTerminal(at: ref.path) }

        Divider()

        Button("Copy Path") { FileActions.copyPath(ref.path) }

        if ref.isDirectory {
            Button("Zoom Treemap Here") { model.zoom(into: ref.dir) }
                .disabled(ref.dir.isEmpty)
        }
        // A folder a search turned up is as much in need of placing as a
        // file. In the tree itself it is already where this would put it.
        //
        // From the File View this is a change of tab as well: the row was
        // found, opened to and selected behind a tab that stayed where it
        // was.
        if !ref.isDirectory || model.tab == .files {
            Button("Show in Tree") {
                model.show(.tree)
                model.revealInTree(ref)
            }
        }

        Divider()

        if let refusal = model.deletionRefusal(for: ref) {
            Text(Self.menuNote(for: refusal))
        } else {
            markItem([ref])
            Divider()
            Button("Move to Trash") { model.moveToTrash(ref) }
                .disabled(model.isDeleting)
            Button("Delete Permanently…") { model.permanentDeleteTargets = [ref] }
                .disabled(model.isDeleting)
        }
    }

    /// A menu-length version of the refusal. The full explanation belongs in the
    /// alert; here it only has to say why the two actions are missing.
    private static func menuNote(for refusal: FileActions.ActionError) -> String {
        switch refusal {
        case .undeletableRoot:
            return "A root folder — can't be removed"
        default:
            return "Protected by macOS — can't be removed"
        }
    }

    /// Marks what was clicked, or takes the marks off when all of it that can
    /// carry one already does. Greyed for something inside a marked folder,
    /// which is going with the folder either way.
    @ViewBuilder
    private func markItem(_ refs: Set<NodeRef>) -> some View {
        let open = refs.filter { model.markState($0) != .covered }
        Button(
            !open.isEmpty && open.allSatisfy(model.marks.contains)
                ? "Unmark" : "Mark for Removal"
        ) {
            model.toggleMarks(refs)
        }
        .disabled(open.isEmpty || model.isDeleting)
    }

    /// Reveal, Open and Zoom all describe one item and have no sensible reading
    /// across a set, so a multiple selection is offered only the two actions
    /// that genuinely apply to all of it.
    @ViewBuilder
    private func manyItems(_ refs: Set<NodeRef>) -> some View {
        Text("\(ByteFormat.count(refs.count)) items selected")

        Divider()

        if model.isDeletionRefused(refs) {
            Text("Some can't be removed — protected, or a root folder")
        } else {
            markItem(refs)
            Divider()
            Button("Move \(ByteFormat.count(refs.count)) Items to Trash") {
                model.moveToTrash(refs)
            }
            .disabled(model.isDeleting)
            Button("Delete \(ByteFormat.count(refs.count)) Items Permanently…") {
                model.permanentDeleteTargets = refs
            }
            .disabled(model.isDeleting)
        }
    }
}
