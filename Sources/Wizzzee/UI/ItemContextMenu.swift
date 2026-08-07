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
        Button("Open in Terminal") { FileActions.openTerminal(at: ref.path) }

        Divider()

        Button("Copy Path") { FileActions.copyPath(ref.path) }

        if ref.isDirectory {
            Button("Zoom Treemap Here") { model.zoom(into: ref.dir) }
                .disabled(ref.dir.subdirs.isEmpty && ref.dir.files.isEmpty)
        } else {
            Button("Show in Tree") { model.revealInTree(ref) }
        }

        Divider()

        if let refusal = model.deletionRefusal(for: ref) {
            Text(Self.menuNote(for: refusal))
        } else {
            Button("Move to Trash") { model.moveToTrash(ref) }
            Button("Delete Permanently…") { model.permanentDeleteTargets = [ref] }
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
            Button("Move \(ByteFormat.count(refs.count)) Items to Trash") {
                model.moveToTrash(refs)
            }
            Button("Delete \(ByteFormat.count(refs.count)) Items Permanently…") {
                model.permanentDeleteTargets = refs
            }
        }
    }
}
