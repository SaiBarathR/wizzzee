import SwiftUI

/// Bottom strip mirroring WizTree's status line: what's selected, and the totals
/// for the whole scan.
struct StatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            // A delete takes over the strip while it runs. It is the only thing
            // happening, it can take minutes on a large tree, and the Stop has
            // to be somewhere the user is already looking.
            if let progress = model.deleteProgress {
                deleting(progress)
            } else {
                contents
            }
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func deleting(_ progress: AppModel.DeleteProgress) -> some View {
        Group {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 130)

            Text(
                "Removing \(ByteFormat.count(progress.done + 1)) of "
                    + "\(ByteFormat.count(progress.total))"
            )
            if !progress.currentName.isEmpty {
                Text(progress.currentName)
                    .truncationMode(.middle)
            }

            Spacer()

            // Stops after the item in hand: removing a directory is a single
            // uninterruptible call, so there is nothing honest to promise
            // beyond "no further items will be started".
            Button("Stop") { model.cancelDelete() }
                .controlSize(.small)
                .help("Stop after the item currently being removed")
        }
    }

    @ViewBuilder
    private var contents: some View {
        Group {
            if let single = model.primarySelection {
                Label {
                    Text(selectionSummary(single))
                } icon: {
                    Image(systemName: single.isDirectory ? "folder" : "doc")
                }
                .labelStyle(.titleAndIcon)
            } else if model.selection.count > 1 {
                Label {
                    Text(multipleSelectionSummary)
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                .labelStyle(.titleAndIcon)
            } else {
                Text("Nothing selected")
            }

            Spacer()

            if let result = model.result {
                Text(
                    "\(ByteFormat.count(result.root.totalFiles)) files, "
                        + "\(ByteFormat.count(result.root.totalDirs)) folders"
                )
                Text("Total \(ByteFormat.decimal(result.root.totalSize))")
                Text("On disk \(ByteFormat.decimal(result.root.totalAlloc))")

                if result.hardLinkSavings > 0 {
                    Text("Hard links \(ByteFormat.decimal(result.hardLinkSavings))")
                        .help(
                            "Space that would be double-counted if hard-linked "
                                + "files were each counted in full."
                        )
                }
            }
        }
    }

    /// The size quoted is what deleting the selection would actually free, so a
    /// folder selected alongside a file inside it is counted once.
    private var multipleSelectionSummary: String {
        "\(ByteFormat.count(model.selection.count)) items selected  •  "
            + ByteFormat.decimal(model.reclaimableSize(model.selection))
    }

    private func selectionSummary(_ ref: NodeRef) -> String {
        var parts = [ref.path, ByteFormat.decimal(ref.size)]
        if ref.isDirectory {
            parts.append("\(ByteFormat.count(ref.dir.totalItems)) items")
        }
        return parts.joined(separator: "  •  ")
    }
}

/// Explains what the numbers mean and where they come from.
struct AboutTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Wizzzee")
                    .font(.system(size: 22, weight: .semibold))
                Text("A disk space analyzer for macOS, in the shape of WizTree.")
                    .foregroundStyle(.secondary)

                if let result = model.result {
                    Divider()
                    Text("This scan").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        row("Root", result.rootPath)
                        row("Duration", ByteFormat.duration(result.elapsed))
                        row("Files", ByteFormat.count(result.root.totalFiles))
                        row("Folders", ByteFormat.count(result.root.totalDirs))
                        row("Logical size", ByteFormat.decimal(result.root.totalSize))
                        row("Size on disk", ByteFormat.decimal(result.root.totalAlloc))
                        row(
                            "Hard links skipped",
                            ByteFormat.decimal(result.hardLinkSavings)
                        )
                        row("Unreadable folders", ByteFormat.count(result.deniedCount))
                        row("File types", ByteFormat.count(result.extensionStats.count))
                    }
                    .font(.system(size: 11))
                }

                Divider()
                Text("How it reads the disk").font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    bullet(
                        "Enumeration uses getattrlistbulk, which returns names, "
                            + "sizes and dates for many directory entries per "
                            + "syscall. Work is spread across every CPU core."
                    )
                    bullet(
                        "Sizes come in two flavours. “Size” is the logical file "
                            + "length; “On Disk” is the space actually allocated. "
                            + "They diverge sharply for sparse files such as "
                            + "virtual machine and container images."
                    )
                    bullet(
                        "Hard-linked files are counted once, so totals line up "
                            + "with du rather than inflating."
                    )
                    bullet(
                        "A scan stays on one volume. Other disks, network shares "
                            + "and the synthetic mounts under /System/Volumes are "
                            + "left out, and APFS firmlinks are followed only "
                            + "once so nothing is counted twice."
                    )
                    bullet(
                        "Sizes are base-10, matching Finder: 1 GB is "
                            + "1,000,000,000 bytes."
                    )
                }

                Divider()
                Text("What can't be deleted").font(.headline)
                Text(
                    "The system volume is sealed and read-only under System "
                        + "Integrity Protection. Wizzzee shows what lives there so "
                        + "the space is accounted for, but nothing — not even an "
                        + "administrator — can remove it."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
