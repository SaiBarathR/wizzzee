import SwiftUI

/// Top strip: what to scan, the scan control and progress, and a summary of the
/// current selection and volume — the same information WizTree puts above its
/// tabs.
struct HeaderBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // Drops the summary, then the metric picker, as the window narrows —
        // rather than letting every control truncate to "Fol…" / "Sc…".
        ViewThatFits(in: .horizontal) {
            layout(showSummary: true, showMetric: true)
            layout(showSummary: false, showMetric: true)
            layout(showSummary: false, showMetric: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func layout(showSummary: Bool, showMetric: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            targetControls
            if showSummary {
                Divider().frame(height: 62)
                summaryGrid
            }
            Spacer(minLength: 8)
            if showMetric { metricPicker }
        }
    }

    // MARK: - Target & scan

    private var targetControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Select:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize()

                Picker("", selection: volumeSelection) {
                    ForEach(model.volumes) { volume in
                        Text(volume.menuTitle).tag(volume.path)
                    }
                    if let folder = model.customFolder {
                        Divider()
                        Text(folder).tag(folder)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 170, idealWidth: 240, maxWidth: 300)
                .disabled(model.phase == .scanning)

                Button("Folder…") { model.chooseFolder() }
                    .fixedSize()
                    .disabled(!model.canStartScan)
                    .help("Scan a specific folder instead of a whole volume")

                if model.phase == .scanning {
                    Button("Stop") { model.cancelScan() }
                        .fixedSize()
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Scan") { model.startScan() }
                        .fixedSize()
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartScan)
                }
            }

            progressLine
        }
    }

    private var volumeSelection: Binding<String> {
        Binding(
            get: { model.customFolder ?? model.selectedVolumePath },
            set: { newValue in
                if newValue == model.customFolder { return }
                model.chooseVolume(newValue)
            }
        )
    }

    @ViewBuilder
    private var progressLine: some View {
        switch model.phase {
        case .scanning:
            VStack(alignment: .leading, spacing: 2) {
                Text(model.progressSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // How far, where that can be known: a whole volume has a
                // size to be a share of, and a folder has not.
                Group {
                    if let fraction = model.scanFraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .frame(width: 380)
                // Where it has got to, which was collected and never shown.
                Text(model.scanningIn)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 380, alignment: .leading)
            }
        case .complete:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(
                    "Scan complete in "
                        + ByteFormat.duration(model.result?.elapsed ?? 0)
                )
                if let denied = model.result?.deniedCount, denied > 0 {
                    Text("• \(ByteFormat.counted(denied, "folder")) unreadable")
                        .foregroundStyle(.orange)
                }
                if model.marksLostToRescan > 0 {
                    Text(
                        "• \(ByteFormat.counted(model.marksLostToRescan, "marked item"))"
                            + " no longer there"
                    )
                    .foregroundStyle(.orange)
                    .help(
                        "What these marks were on has gone since the last scan, "
                            + "or can no longer be removed. The other marks "
                            + "were put back."
                    )
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        case .cancelled:
            Text("Scan stopped")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failed(let message):
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.red)
        case .idle:
            Text("Choose a volume or folder, then press Scan")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Summary

    /// Row labels must never wrap or abbreviate — a header reading "Se:" / "Vo:"
    /// is worse than no header at all.
    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var summaryGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
            GridRow {
                rowLabel("Selection:")
                Text(selectionName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            GridRow {
                rowLabel("Scanned:")
                if let scanned = model.scannedSummary {
                    Text(scanned)
                        .fontWeight(.medium)
                        .lineLimit(1)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            GridRow {
                // Capacity is the whole volume's, which is what matters when
                // deciding what to delete even if only a folder was scanned.
                rowLabel("Volume Total:")
                Text(ByteFormat.decimal(model.targetCapacity.total))
            }
            GridRow {
                rowLabel("Volume Used:")
                let capacity = model.targetCapacity
                let used = capacity.total > capacity.free
                    ? capacity.total - capacity.free : 0
                Text(
                    "\(ByteFormat.decimal(used))  "
                        + "(\(ByteFormat.percent(fraction(used, capacity.total))))"
                )
            }
            GridRow {
                rowLabel("Volume Free:")
                let capacity = model.targetCapacity
                Text(
                    "\(ByteFormat.decimal(capacity.free))  "
                        + "(\(ByteFormat.percent(fraction(capacity.free, capacity.total))))"
                )
            }
        }
        .font(.system(size: 11))
        .frame(minWidth: 260, maxWidth: 420, alignment: .leading)
    }

    private var selectionName: String {
        if let single = model.primarySelection { return single.path }
        if model.selection.count > 1 {
            return "\(ByteFormat.count(model.selection.count)) items  •  "
                + ByteFormat.decimal(model.reclaimableSize(model.selection))
        }
        return model.result?.rootPath ?? model.scanTargetLabel
    }

    private func fraction(_ value: UInt64, _ total: UInt64) -> Double {
        total > 0 ? Double(value) / Double(total) : 0
    }

    // MARK: - Size metric

    private var metricPicker: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Picker(
                "",
                selection: Binding(
                    get: { model.sizeMetric },
                    set: { model.chooseMetric($0) }
                )
            ) {
                Text("Size").tag(SizeMetric.logical)
                Text("On Disk").tag(SizeMetric.allocated)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help(
                "Which measure is on show. Size is how long files are; On Disk "
                    + "is the space they occupy. A sparse file, such as a "
                    + "container or virtual machine image, can be far longer "
                    + "than the space it takes."
            )

            // The bulk actions take the version line's place rather than adding
            // a row, so the header doesn't change height as the selection grows.
            if model.selection.count > 1 {
                bulkActions
            } else {
                Text("Wizzzee \(AppInfo.version)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }

    // MARK: - Bulk actions

    /// Shown only for a multiple selection: the single-item versions live in the
    /// context menu, and a permanently visible delete button next to the metric
    /// picker would be an easy mis-click during ordinary browsing.
    private var bulkActions: some View {
        let refs = model.selection
        let blocked = FileActions.containsSystemProtected(refs)
        let count = ByteFormat.count(refs.count)
        return HStack(spacing: 6) {
            Button("Move \(count) to Trash") { model.moveToTrash(refs) }
            Button("Delete \(count)…") { model.permanentDeleteTargets = refs }
        }
        .controlSize(.small)
        // Off while a batch runs, as the context menu's are: a confirmation
        // raised now would be answered after that batch had changed what it
        // says will be freed.
        .disabled(blocked || model.isDeleting)
        .help(
            blocked
                ? "Part of the selection is on the sealed system volume and "
                    + "can't be removed."
                : "Applies to all \(count) selected items."
        )
    }
}
