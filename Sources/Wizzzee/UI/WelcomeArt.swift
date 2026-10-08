import SwiftUI

/// The picture at the head of a page of the guide: the part of the window
/// the page is about, drawn small, with a numbered dot on each thing the
/// cards below it go on to explain.
///
/// Drawn, not photographed. A screenshot is a file to ship and to keep up
/// with the app, shows one appearance, and is somebody's disk.
struct WelcomeArt: View {
    let page: WelcomePage

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [page.tint.opacity(0.34), page.tint.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            picture
                .padding(11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.primary.opacity(0.14))
                )
                .shadow(color: .black.opacity(0.2), radius: 9, y: 4)
                .padding(.horizontal, 30)
                .padding(.vertical, 17)
        }
        // The cards say all of it in words.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var picture: some View {
        switch page {
        case .scan: ScanArt()
        case .tree: TreeArt()
        case .treemap: TreemapArt()
        case .search: SearchArt()
        case .look: LookArt()
        case .remove: RemoveArt()
        case .keys: EmptyView()
        }
    }
}

extension View {
    /// Pins a numbered dot to an edge or a corner of something in a picture.
    /// `outset` is how far out from there its near side starts: half its own
    /// width puts it half on and half off, and all of it puts it clear of
    /// something too small to have a dot on top of it.
    func guideBadge(
        _ number: Int,
        at alignment: Alignment = .topTrailing,
        outset: CGFloat = 8
    ) -> some View {
        let across: CGFloat =
            alignment.horizontal == .trailing
            ? outset : (alignment.horizontal == .leading ? -outset : 0)
        let down: CGFloat =
            alignment.vertical == .top
            ? -outset : (alignment.vertical == .bottom ? outset : 0)
        return overlay(alignment: alignment) {
            GuideBadge(number: number).offset(x: across, y: down)
        }
    }
}

// MARK: - Parts the pictures share

/// A push button, as the app draws them.
private struct ArtButton: View {
    let title: String
    var isProminent = false

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(isProminent ? Color.white : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isProminent ? Color.accentColor : Color.primary.opacity(0.12))
            )
    }
}

/// The Size / On Disk switch.
private struct ArtMetricSwitch: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Size")
                .frame(width: 44, height: 18)
            Text("On Disk")
                .foregroundStyle(.white)
                .frame(width: 54, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
        }
        .font(.system(size: 10, weight: .medium))
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.12)))
    }
}

/// A line of small type, as most of the window is set in.
private func artText(_ text: String, _ style: HierarchicalShapeStyle = .primary) -> some View {
    Text(text)
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(style)
        .lineLimit(1)
}

/// A folder's or a file's icon.
private struct ArtIcon: View {
    var isFolder = true

    var body: some View {
        Image(systemName: isFolder ? "folder.fill" : "doc.fill")
            .font(.system(size: 10))
            .foregroundStyle(isFolder ? Color.blue.opacity(0.85) : Color.secondary)
            .frame(width: 13)
    }
}

/// The box at the head of a row.
private struct ArtCheckbox: View {
    enum Mark { case off, on, partly }
    var mark = Mark.off

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(mark == .off ? Color.secondary.opacity(0.7) : Color.accentColor)
            .frame(width: 13)
    }

    private var symbol: String {
        switch mark {
        case .off: return "square"
        case .on: return "checkmark.square.fill"
        case .partly: return "minus.square.fill"
        }
    }
}

/// The bar behind a row's share of its folder.
private struct ArtShare: View {
    let fraction: Double
    let label: String

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18))
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2)
                    .fill(colour)
                    .frame(width: geometry.size.width * fraction)
            }
            Text(label)
                .font(.system(size: 8.5).monospacedDigit())
                .padding(.leading, 3)
        }
        .frame(width: 62, height: 11)
    }

    private var colour: Color {
        if fraction >= 0.5 { return .orange.opacity(0.6) }
        if fraction >= 0.2 { return .yellow.opacity(0.5) }
        return .accentColor.opacity(0.4)
    }
}

/// Diagonal lines across a tile: how the treemap shows a mark.
private struct ArtHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var start = rect.minX - rect.height
        while start < rect.maxX {
            path.move(to: CGPoint(x: start, y: rect.maxY))
            path.addLine(to: CGPoint(x: start + rect.height, y: rect.minY))
            start += 6
        }
        return path
    }
}

/// One tile of the treemap, shaded as the map shades them.
private struct ArtTile: View {
    let colour: Color
    var label: String?
    var isSelected = false
    var isMarked = false

    var body: some View {
        Rectangle()
            .fill(colour)
            .overlay(
                LinearGradient(
                    colors: [.white.opacity(0.22), .clear, .black.opacity(0.34)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if isMarked {
                    ArtHatch().stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 1)
                        .lineLimit(1)
                        .padding(3)
                }
            }
            .overlay(
                Rectangle()
                    .stroke(
                        isSelected ? Color.white : Color.black.opacity(0.4),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            )
    }
}

// MARK: - The pictures

/// The strip at the top of the window, and the banner under it.
private struct ScanArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                artText("Select:", .secondary)
                picker.guideBadge(1)
                ArtButton(title: "Folder…")
                ArtButton(title: "Scan", isProminent: true).guideBadge(2)
                Spacer(minLength: 8)
                ArtMetricSwitch()
            }
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                artText("Scan complete in 14.8 s", .secondary)
                    .guideBadge(3, at: .trailing, outset: 21)
            }
            HStack(spacing: 18) {
                figure("Scanned:", "528 GB  (3,912,440 files)")
                figure("Volume Used:", "528 GB  (53.1 %)")
                figure("Volume Free:", "466 GB  (46.9 %)")
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
            banner.guideBadge(4)
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            artText(label, .secondary)
            artText(value)
        }
    }

    private var picker: some View {
        HStack(spacing: 4) {
            artText("Macintosh HD   (995 GB)")
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .frame(width: 176, height: 18)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.12)))
    }

    private var banner: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.shield")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text("Wizzzee doesn’t have Full Disk Access")
                    .font(.system(size: 10, weight: .semibold))
                artText("Protected folders are skipped, and totals will read low.", .secondary)
            }
            Spacer(minLength: 6)
            ArtButton(title: "Open Settings…")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.14)))
    }
}

/// The tree's table, with File Types beside it.
private struct TreeArt: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                tab("Tree View", isCurrent: true)
                tab("File View")
                tab("About")
                Spacer(minLength: 8)
                ArtMetricSwitch().guideBadge(3, at: .leading, outset: 21)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    headings
                    Divider()
                    row(0, open: true, "Macintosh HD", 1.0, "100.0 %", "528 GB")
                    row(1, open: true, "Users", 0.47, "47.2 %", "249 GB")
                        .overlay(alignment: .leading) {
                            // On the arrow, which is what opens the folder.
                            Color.clear.frame(width: 14, height: 12)
                                .guideBadge(1, at: .leading, outset: 6)
                        }
                    row(2, open: false, "you", 0.93, "93.1 %", "232 GB")
                    row(1, open: false, "Applications", 0.19, "18.6 %", "98.1 GB")
                }
                Divider()
                types
                    .frame(width: 132)
            }
        }
    }

    private func tab(_ title: String, isCurrent: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isCurrent ? Color.accentColor.opacity(0.22) : Color.clear)
            )
    }

    private var headings: some View {
        HStack(spacing: 4) {
            artText("Folder / File", .secondary)
            Spacer(minLength: 6)
            artText("% of Parent", .secondary).frame(width: 62, alignment: .leading)
            HStack(spacing: 2) {
                Text("On Disk")
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .frame(width: 54, alignment: .trailing)
            .guideBadge(2, at: .top, outset: 17)
        }
    }

    private func row(
        _ depth: Int, open: Bool, _ name: String, _ fraction: Double,
        _ share: String, _ size: String
    ) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 12, height: 1)
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 9)
            ArtIcon()
            artText(name)
            Spacer(minLength: 6)
            ArtShare(fraction: fraction, label: share)
            artText(size).frame(width: 54, alignment: .trailing)
        }
    }

    private var types: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("File Types")
                .font(.system(size: 10, weight: .semibold))
            Divider()
            type(0, ".mov", "112 GB")
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.25))
                        .padding(.horizontal, -3)
                )
                .guideBadge(4, at: .leading, outset: 23)
            type(1, ".dmg", "64.2 GB")
            type(3, ".zip", "41.0 GB")
        }
    }

    private func type(_ colour: Int, _ name: String, _ size: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(TreemapPalette.color(colour))
                .frame(width: 9, height: 9)
            artText(name)
            Spacer(minLength: 4)
            artText(size, .secondary)
        }
    }
}

/// The map, under the path that says where it is zoomed to.
private struct TreemapArt: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up")
                Image(systemName: "arrow.up.to.line")
                path.guideBadge(2, at: .trailing, outset: 21)
                Spacer(minLength: 6)
                artText("Double-click a folder to zoom in  •  ⌘-click to mark", .tertiary)
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)

            GeometryReader { geometry in
                tiles(in: geometry.size)
            }
        }
    }

    private var path: some View {
        HStack(spacing: 3) {
            artText("Macintosh HD", .secondary)
            Image(systemName: "chevron.right").font(.system(size: 6, weight: .bold))
            artText("Users", .secondary)
            Image(systemName: "chevron.right").font(.system(size: 6, weight: .bold))
            artText("you")
        }
    }

    /// Laid out by hand in the proportions a real map comes out in: one
    /// folder that is most of it, and the rest in strips beside it.
    private func tiles(in size: CGSize) -> some View {
        let gap: CGFloat = 2
        let first = size.width * 0.36
        let second = size.width * 0.24
        let third = size.width * 0.22
        let fourth = size.width - first - second - third - gap * 3
        let upper = size.height * 0.62
        let lower = size.height - upper - gap
        return HStack(spacing: gap) {
            ArtTile(colour: TreemapPalette.color(0), label: "Movies (112 GB)", isSelected: true)
                .frame(width: first)
                .guideBadge(1, at: .bottomTrailing)
            VStack(spacing: gap) {
                ArtTile(colour: TreemapPalette.color(1), label: "Downloads (64.2 GB)")
                    .frame(height: upper)
                ArtTile(colour: TreemapPalette.color(6), label: "old")
                    .frame(height: lower)
            }
            .frame(width: second)
            VStack(spacing: gap) {
                ArtTile(colour: TreemapPalette.color(2), label: "Caches (41.0 GB)", isMarked: true)
                    .frame(height: lower)
                    .guideBadge(3)
                ArtTile(colour: TreemapPalette.color(3), label: "Projects")
                    .frame(height: upper)
            }
            .frame(width: third)
            VStack(spacing: gap) {
                ArtTile(colour: TreemapPalette.color(5))
                ArtTile(colour: TreemapPalette.color(4))
                ArtTile(colour: TreemapPalette.color(7))
                    .frame(height: lower * 0.7)
            }
            .frame(width: fourth)
            .overlay(alignment: .bottomTrailing) {
                // The status bar's button, at the corner it is in.
                Image(systemName: "rectangle.3.group.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
                    .padding(4)
                    .guideBadge(4, at: .topLeading)
            }
        }
    }
}

/// The File View's filter, with a search typed into it and what it found.
private struct SearchArt: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                field
                Spacer(minLength: 8)
                artText("37 folders  •  12.4 GB", .secondary)
                    .guideBadge(4, at: .leading, outset: 21)
            }
            // Room above the field for the dots on what is typed in it.
            .padding(.top, 12)
            Divider()
            result("node_modules", "/Users/you/Projects/shop", "1.9 GB")
            result("node_modules", "/Users/you/Projects/site/web", "1.4 GB")
            result("node_modules", "/Users/you/Archive/2023/app", "1.1 GB")
            result("node_modules", "/Users/you/Projects/tools", "642 MB")
        }
    }

    private var field: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            artText("node_modules")
                .padding(.trailing, 2)
                .guideBadge(1, at: .top, outset: 19)
            token(">500mb").guideBadge(2, at: .top, outset: 18)
            token("kind:folder").guideBadge(3, at: .top, outset: 18)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(width: 300, height: 21)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5))
    }

    private func token(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.22)))
    }

    private func result(_ name: String, _ folder: String, _ size: String) -> some View {
        HStack(spacing: 5) {
            ArtCheckbox()
            ArtIcon()
            artText(name)
            artText(folder, .secondary)
            Spacer(minLength: 6)
            artText(size).frame(width: 54, alignment: .trailing)
        }
    }
}

/// A row with the right-click menu on it, and Quick Look beside it.
private struct LookArt: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                row("backup-2021.sparsebundle", "42.0 GB", note: "sparse", badge: 4)
                row("IMG_2041.mov", "4.1 GB", isSelected: true)
                row("installer.dmg", "2.8 GB", badge: 3)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottomTrailing) {
                menu.guideBadge(2, at: .topLeading)
            }
            preview
                .frame(width: 176)
                .guideBadge(1)
        }
    }

    private func row(
        _ name: String, _ size: String, isSelected: Bool = false,
        note: String? = nil, badge: Int? = nil
    ) -> some View {
        HStack(spacing: 5) {
            ArtIcon(isFolder: false)
            artText(name)
            if let note {
                Text(note)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.orange)
            }
            if let badge {
                GuideBadge(number: badge).padding(.leading, 2)
            }
            Spacer(minLength: 6)
            artText(size, .secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 3) {
            artText("Reveal in Finder")
            artText("Open")
            artText("Quick Look")
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor))
                .foregroundStyle(.white)
                .padding(.horizontal, -5)
            artText("Open in Terminal")
            artText("Copy Path")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 118, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.18)))
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                artText("IMG_2041.mov")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Color.primary.opacity(0.1))
            ZStack {
                LinearGradient(
                    colors: [Color.indigo.opacity(0.75), Color.orange.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.2)))
    }
}

/// Rows with their boxes ticked, over the bar that counts them.
private struct RemoveArt: View {
    var body: some View {
        VStack(spacing: 5) {
            // The folder the scan started from: no box, since it can't go.
            row(nil, "/Users/you", "232 GB")
                .guideBadge(6, at: .leading, outset: 20)
            row(.partly, "Projects", "38.2 GB", depth: 1)
            row(.on, "node_modules", "1.9 GB", depth: 2)
                .guideBadge(1, at: .leading, outset: 20)
            // Selected and not marked, which is what the Finder keys act on.
            row(.off, "Documents", "21.7 GB", depth: 1, isSelected: true)
                .guideBadge(5, at: .trailing, outset: 20)
            Spacer(minLength: 0)
            bar.guideBadge(2, at: .topLeading)
            status
        }
        // Room at the sides for the dots that sit beside a row.
        .padding(.horizontal, 12)
    }

    private func row(
        _ mark: ArtCheckbox.Mark?, _ name: String, _ size: String, depth: Int = 0,
        isSelected: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            if let mark {
                ArtCheckbox(mark: mark)
            } else {
                Color.clear.frame(width: 13, height: 1)
            }
            Color.clear.frame(width: CGFloat(depth) * 12, height: 1)
            ArtIcon()
            artText(name)
            Spacer(minLength: 6)
            artText(size, .secondary)
        }
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                .padding(.horizontal, -3)
                .padding(.vertical, -1)
        )
    }

    private var bar: some View {
        HStack(spacing: 6) {
            ArtCheckbox(mark: .on)
            Text("1 item marked for removal")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            artText("1.9 GB on disk", .secondary)
            ArtButton(title: "Show List")
            Spacer(minLength: 4)
            ArtButton(title: "Move to Trash", isProminent: true).guideBadge(3)
            ArtButton(title: "Delete…")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.16)))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: 1)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            // What the row above has selected, as the real one names it.
            artText("/Users/you/Documents  •  21.7 GB", .secondary)
            Spacer(minLength: 6)
            Image(systemName: "trash")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            artText("In the Trash 22.4 GB", .secondary)
            ArtButton(title: "Undo").guideBadge(4)
        }
        .padding(.horizontal, 7)
    }
}
