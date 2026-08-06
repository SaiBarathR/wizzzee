import SwiftUI

/// Actions available on a selected file or folder, in both tables and the treemap.
struct ItemContextMenu: View {
    @ObservedObject var model: AppModel
    let refs: Set<NodeRef>

    private var ref: NodeRef? { refs.first }

    var body: some View {
        if let ref {
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

            if FileActions.isSystemProtected(ref.path) {
                Text("Protected by macOS — can't be removed")
            } else {
                Button("Move to Trash") { model.moveToTrash(ref) }
                Button("Delete Permanently…") {
                    model.permanentDeleteTarget = ref
                }
            }
        }
    }
}
