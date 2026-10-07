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
            treemapToggle
        }
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// The View menu's Show / Hide Treemap, where the pointer already is.
    ///
    /// Greyed on the other tabs instead of removed, so the totals beside it
    /// don't shift sideways with every change of tab.
    private var treemapToggle: some View {
        let title = model.showsTreemap ? "Hide Treemap" : "Show Treemap"
        return Button {
            model.toggleTreemap()
        } label: {
            Image(
                systemName: model.showsTreemap
                    ? "rectangle.3.group.fill" : "rectangle.3.group"
            )
            .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .disabled(model.tab != .tree)
        .help(
            model.tab == .tree
                ? "\(title) (⌘T)" : "The treemap is part of Tree View"
        )
        .accessibilityLabel(title)
    }

    private func deleting(_ progress: AppModel.DeleteProgress) -> some View {
        Group {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(width: 130)

            // Which of several, when there are several; one target is the
            // usual case and needs no counting.
            if progress.total > 1 {
                Text(
                    "Removing "
                        + ByteFormat.count(min(progress.done + 1, progress.total))
                        + " of \(ByteFormat.count(progress.total))"
                )
            } else {
                Text("Removing")
            }
            if !progress.currentName.isEmpty {
                Text(progress.currentName)
                    .truncationMode(.middle)
            }
            Text(model.deleteSummary(progress))

            Spacer()

            // What has gone stays gone: the tree is brought into line with
            // whatever is left on disk once the batch has wound up.
            Button("Stop") { model.cancelDelete() }
                .controlSize(.small)
                .help("Stop removing. What has already gone is not brought back.")
        }
    }

    @ViewBuilder
    private var contents: some View {
        Group {
            if let single = model.primarySelection {
                Label {
                    Text(model.selectionSummary(single))
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
                    "\(ByteFormat.counted(result.root.totalFiles, "file")), "
                        + ByteFormat.counted(result.root.totalDirs, "folder")
                )
                // Space occupied first, and the combined length named for
                // what it is. It read "Total", which is the one thing a sum of
                // lengths is not: a single sparse image puts it past the size
                // of the disk.
                Text("On disk \(ByteFormat.decimal(result.root.totalAlloc))")
                Text("Logical size \(ByteFormat.decimal(result.root.totalSize))")
                    .help(
                        "Every file's length added up. Sparse files, such as "
                            + "container and virtual machine images, are longer "
                            + "than the space they occupy, so this can exceed "
                            + "the size of the disk."
                    )

                // Space, whichever measure is on show: it sits between two
                // totals that are each named, and a length here — a second
                // name for a sparse image is worth the image's whole length —
                // would read as disk that isn't there.
                let savings = result.hardLinkSavings(using: .allocated)
                if savings > 0 {
                    Text("Hard links \(ByteFormat.decimal(savings))")
                        .help(
                            "Space on disk that would be counted twice if "
                                + "every name of a hard-linked file were "
                                + "counted in full."
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
                        row("Size on disk", ByteFormat.decimal(result.root.totalAlloc))
                        row("Logical size", ByteFormat.decimal(result.root.totalSize))
                        row(
                            "Hard links skipped",
                            ByteFormat.decimal(
                                result.hardLinkSavings(using: .allocated)
                            )
                        )
                        row("Unreadable folders", ByteFormat.count(result.deniedCount))
                        row("File types", ByteFormat.count(result.typeCount))
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
                            + "virtual machine and container images, which can "
                            + "be longer than the disk they are on. Those are "
                            + "marked “sparse” in the tables. Compressed files "
                            + "occupy less than their length too, with nothing "
                            + "missing, and are not marked."
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
