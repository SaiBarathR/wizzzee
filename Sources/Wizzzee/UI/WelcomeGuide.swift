import AppKit
import SwiftUI

/// One page of the guide: a part of the app, where it is in the window, and
/// what can be done there.
enum WelcomePage: Int, CaseIterable, Identifiable {
    case scan, tree, treemap, search, look, remove, keys

    var id: Int { rawValue }

    /// What the page is called in the list of them.
    var title: String {
        switch self {
        case .scan: return "Start with a Scan"
        case .tree: return "Tree View"
        case .treemap: return "Treemap"
        case .search: return "File View and Search"
        case .look: return "Look Before Removing"
        case .remove: return "Mark and Remove"
        case .keys: return "Keyboard Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .scan: return "externaldrive.fill"
        case .tree: return "list.bullet.indent"
        case .treemap: return "rectangle.3.group.fill"
        case .search: return "magnifyingglass"
        case .look: return "eye.fill"
        case .remove: return "checkmark.square.fill"
        case .keys: return "keyboard.fill"
        }
    }

    /// The colour of the page's symbol in the list, and of its picture.
    var tint: Color {
        switch self {
        case .scan: return .blue
        case .tree: return .orange
        case .treemap: return .purple
        case .search: return .teal
        case .look: return .indigo
        case .remove: return .red
        case .keys: return .gray
        }
    }

    var headline: String {
        switch self {
        case .scan: return "Start with a scan"
        case .tree: return "Tree View: find what is big"
        case .treemap: return "Treemap: the whole disk at once"
        case .search: return "File View: search the scan"
        case .look: return "Look before you remove"
        case .remove: return "Mark, then remove"
        case .keys: return "Keyboard shortcuts"
        }
    }

    var lead: String {
        switch self {
        case .scan:
            return "Wizzzee reads a whole disk in seconds and shows where the "
                + "space went. It begins in the strip across the top of the window."
        case .tree:
            return "Every folder and what it holds, biggest first. Open folders "
                + "to follow the space down to where it is."
        case .treemap:
            return "Every file is a rectangle, sized by the space it takes and "
                + "coloured by its type. The big blocks are where the space is."
        case .search:
            return "The thousand biggest files anywhere in the scan, and a filter "
                + "that finds files and folders by name, size and age."
        case .look:
            return "Find out what something is, and where, without leaving the "
                + "window."
        case .remove:
            return "Gather things from anywhere in the scan, look the list over, "
                + "and remove them together."
        case .keys:
            return "Every key the app answers, in one place."
        }
    }

    /// Where in the window the page is about, in words, for under the map of
    /// it. Nil for a page that is about no one part.
    var place: String? {
        switch self {
        case .scan: return "The top of the window"
        case .tree: return "The upper half of Tree View"
        case .treemap: return "The lower half of Tree View"
        case .search: return "The File View tab"
        case .look: return "Any row, and any tile"
        case .remove: return "The foot of the window"
        case .keys: return nil
        }
    }

    /// The parts of the window lit on the map beside the heading.
    var regions: Set<WindowMap.Region> {
        switch self {
        case .scan: return [.header]
        case .tree: return [.table, .types]
        case .treemap: return [.treemap]
        case .search: return [.tabs, .filter, .table]
        case .look: return [.table, .treemap]
        case .remove: return [.marks, .status]
        case .keys: return []
        }
    }

    /// What can be done there, numbered as the picture numbers them.
    var tips: [WelcomeTip] {
        switch self {
        case .scan:
            return [
                WelcomeTip(
                    1, "Choose what to scan",
                    "Pick a volume from **Select**, or press **Folder…** to scan "
                        + "one folder.",
                    keys: [["⌘", "O"]]
                ),
                WelcomeTip(
                    2, "Press Scan",
                    "A full startup disk takes about fifteen seconds. **Stop** "
                        + "ends a scan early.",
                    keys: [["↩"], ["⌘", "."]]
                ),
                WelcomeTip(
                    3, "Scan again, and keep your place",
                    "**Rescan** brings the figures up to date and keeps the open "
                        + "folders, the zoom, the selection and the marks, wherever "
                        + "they are still there.",
                    keys: [["⌘", "R"]]
                ),
                WelcomeTip(
                    4, "Let it see everything",
                    "Without Full Disk Access macOS hides Mail, Messages, Safari "
                        + "and other users’ folders, and the totals read low. The "
                        + "orange banner opens the setting."
                ),
            ]
        case .tree:
            return [
                WelcomeTip(
                    1, "Open and shut folders",
                    "Click the arrow beside a folder, or double-click its row. "
                        + "The arrow keys work as they do in Finder’s list view.",
                    keys: [["→"], ["←"]]
                ),
                WelcomeTip(
                    2, "Sort by any column",
                    "Click a column’s heading. Sorting applies inside each "
                        + "folder, so the tree keeps its shape."
                ),
                WelcomeTip(
                    3, "Size, or On Disk",
                    "**On Disk** is the space something occupies, which is what "
                        + "removing it gives back. **Size** is how long its files "
                        + "are. The switch is at the top right."
                ),
                WelcomeTip(
                    4, "File Types",
                    "The list beside the tree ranks the scan by type. Click a "
                        + "type to light its tiles on the treemap; File View then "
                        + "lists only its files. Esc in the list lets go.",
                    keys: [["esc"]]
                ),
            ]
        case .treemap:
            return [
                WelcomeTip(
                    1, "Click to select",
                    "Click a tile to select it. The top of the window names it, "
                        + "and the tree scrolls to its row if its folder is open."
                ),
                WelcomeTip(
                    2, "Zoom in, and back out",
                    "Double-click a folder to zoom into it. Each folder in the "
                        + "path above the map zooms back out to there.",
                    keys: [["⌘", "["], ["⌘", "0"]]
                ),
                WelcomeTip(
                    3, "Mark from the map",
                    "Hold ⌘ and click a tile to mark it for removal. Marked "
                        + "tiles are hatched.",
                    keys: [["⌘", "click"]]
                ),
                WelcomeTip(
                    4, "Hide the map",
                    "The button at the right-hand end of the status bar gives "
                        + "the table the whole tab, and brings the map back.",
                    keys: [["⌘", "T"]]
                ),
            ]
        case .search:
            return [
                WelcomeTip(
                    1, "Find by name",
                    "⌘F goes to the filter from any tab. Words are looked for in "
                        + "names, in any order, and find folders as well as "
                        + "files. A word with a / in it is looked for in the "
                        + "whole path.",
                    keys: [["⌘", "F"]]
                ),
                WelcomeTip(
                    2, "By size",
                    "`>1gb` finds what is bigger and `<500kb` what is smaller, "
                        + "in the measure on show: On Disk, unless Size is chosen."
                ),
                WelcomeTip(
                    3, "By age, type and kind",
                    "`older:1y`  `newer:30d`  `ext:dmg`  `kind:folder`. Filters "
                        + "combine: each one narrows the last."
                ),
                WelcomeTip(
                    4, "What it found",
                    "The line at the right counts everything that matched, "
                        + "listed or not, and what it takes up. Esc in the filter "
                        + "empties it.",
                    keys: [["esc"]]
                ),
            ]
        case .look:
            return [
                WelcomeTip(
                    1, "Quick Look",
                    "⌘Y previews the selected item and follows the selection, so "
                        + "a list can be worked down with it open. A file that is "
                        + "online only is not shown: that would download it.",
                    keys: [["⌘", "Y"]]
                ),
                WelcomeTip(
                    2, "Right-click anything",
                    "Reveal in Finder, Open, Quick Look, Open in Terminal and "
                        + "Copy Path, on a row or on a tile. A folder adds Zoom "
                        + "Treemap Here; a file, and anything in File View, adds "
                        + "Show in Tree."
                ),
                WelcomeTip(
                    3, "Double-click",
                    "A file’s row is shown in Finder. A folder’s row in the tree "
                        + "opens or shuts, and a folder on the treemap zooms in."
                ),
                WelcomeTip(
                    4, "The notes beside a name",
                    "**sparse** and **online only** mark a file that is longer "
                        + "than the space it takes. **hard link** and **alias** "
                        + "are names that take no space of their own."
                ),
            ]
        case .remove:
            return [
                WelcomeTip(
                    1, "Mark what should go",
                    "Tick the box at the start of a row, or press Space on a "
                        + "selected one. Marks stay put while you open folders, "
                        + "sort, search and change tabs.",
                    keys: [["space"], ["⇧", "⌘", "M"]]
                ),
                WelcomeTip(
                    2, "The bar at the foot of the window",
                    "It appears with the first mark, on every tab: how many "
                        + "things are marked, and what removing them frees. "
                        + "**Show List** opens the list of them."
                ),
                WelcomeTip(
                    3, "Remove the lot",
                    "**Move to Trash** takes everything marked. **Delete…** "
                        + "removes it for good, and asks first."
                ),
                WelcomeTip(
                    4, "Undo",
                    "⌘Z puts back the last move to the Trash. The status bar "
                        + "says what is in the Trash: emptying it is what frees "
                        + "the space.",
                    keys: [["⌘", "Z"]]
                ),
                WelcomeTip(
                    5, "Or one thing at a time",
                    "Finder’s keys act on what is selected, rows or the tile "
                        + "outlined on the map: ⌘⌫ moves it to the Trash, and ⌥⌘⌫ "
                        + "deletes it for good after asking.",
                    keys: [["⌘", "⌫"], ["⌥", "⌘", "⌫"]]
                ),
                WelcomeTip(
                    6, "What can’t be removed",
                    "The system volume is sealed, and a whole volume, a home "
                        + "folder and the folder a scan started from are not for "
                        + "removing. They can’t be marked: a dash on such a "
                        + "row says something inside it is."
                ),
            ]
        case .keys:
            return []
        }
    }
}

/// One thing that can be done on a page, and the keys for it.
struct WelcomeTip: Identifiable {
    /// Its number on the page, which is its number on the picture.
    let id: Int
    let title: String
    /// Markdown: `**bold**` for what a control is called on screen, and
    /// backticks for something to type.
    let text: String
    /// Each of these is one key or one chord: `["⌘", "R"]`.
    let keys: [[String]]

    init(_ id: Int, _ title: String, _ text: String, keys: [[String]] = []) {
        self.id = id
        self.title = title
        self.text = text
        self.keys = keys
    }
}

/// A line of the shortcuts page: the keys, and what they do.
struct WelcomeShortcut: Identifiable {
    let keys: [[String]]
    let action: String

    var id: String { action }

    init(_ keys: [[String]], _ action: String) {
        self.keys = keys
        self.action = action
    }
}

/// The shortcuts under one heading.
struct WelcomeShortcutGroup: Identifiable {
    let title: String
    let shortcuts: [WelcomeShortcut]

    var id: String { title }

    /// Every key the app answers, in the order someone would come to need
    /// them. The menus are where these are set; this is where they are all in
    /// one place.
    static let all: [WelcomeShortcutGroup] = [
        WelcomeShortcutGroup(
            title: "Scanning",
            shortcuts: [
                WelcomeShortcut([["↩"]], "Scan (not while typing in the filter)"),
                WelcomeShortcut([["⌘", "O"]], "Choose a folder to scan"),
                WelcomeShortcut([["⌘", "."]], "Stop a scan"),
                WelcomeShortcut([["⌘", "R"]], "Rescan, keeping your place"),
            ]
        ),
        WelcomeShortcutGroup(
            title: "Getting about",
            shortcuts: [
                WelcomeShortcut(
                    [["⌘", "1"], ["⌘", "2"], ["⌘", "3"]],
                    "Tree View, File View, About"
                ),
                WelcomeShortcut(
                    [["→"], ["←"]],
                    "Open or shut a folder; again, step into or out of it"
                ),
                WelcomeShortcut([["⌘", "F"]], "Search: go to the File View’s filter"),
                WelcomeShortcut(
                    [["esc"]],
                    "In the filter, empty it; in File Types, let go of the type"
                ),
                WelcomeShortcut([["⌘", "Y"]], "Quick Look, or shut it"),
            ]
        ),
        WelcomeShortcutGroup(
            title: "Treemap",
            shortcuts: [
                WelcomeShortcut([["⌘", "T"]], "Show or hide the treemap"),
                WelcomeShortcut([["double-click"]], "Zoom into a folder"),
                WelcomeShortcut([["⌘", "["]], "Zoom out one folder"),
                WelcomeShortcut([["⌘", "0"]], "Zoom all the way out"),
                WelcomeShortcut([["⌘", "click"]], "Mark a tile, or unmark it"),
            ]
        ),
        WelcomeShortcutGroup(
            title: "Removing",
            shortcuts: [
                WelcomeShortcut(
                    [["space"], ["⇧", "⌘", "M"]],
                    "Mark the selection, or unmark it"
                ),
                WelcomeShortcut([["⌘", "⌫"]], "Move the selection to the Trash"),
                WelcomeShortcut(
                    [["⌥", "⌘", "⌫"]],
                    "Delete the selection for good, after asking"
                ),
                WelcomeShortcut([["⌘", "Z"]], "Undo the last move to the Trash"),
            ]
        ),
        WelcomeShortcutGroup(
            title: "This guide",
            shortcuts: [
                WelcomeShortcut([["⌘", "/"]], "Open it at this page"),
                WelcomeShortcut(
                    [["→"], ["←"]],
                    "Turn its pages"
                ),
            ]
        ),
    ]
}

/// The guide to the app: what it does, where each thing is, and the keys.
///
/// Put up over the window the first time the app is opened, and from the
/// Help menu after that. There is a good deal in the app that nothing on
/// screen gives away — that Space marks a row, that the path above the map
/// can be clicked, that the filter reads sizes — and it was all in a README.
struct WelcomeGuide: View {
    @Binding var page: WelcomePage
    let onClose: () -> Void
    /// The box at the foot of it. Held here as well as in the preferences so
    /// the tick is drawn from what was just clicked.
    @State private var staysAway = !Preferences.showsWelcome

    static let size = CGSize(width: 900, height: 680)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 216)
                Divider()
                WelcomePageView(page: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A new page starts at its top, not where the last was
                    // scrolled to.
                    .id(page)
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - The list of pages

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 54, height: 54)
                    .accessibilityHidden(true)
                Text("Welcome to Wizzzee")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.top, 4)
                Text("What it does, and where everything is")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(WelcomePage.allCases) { entry in
                    pageButton(entry)
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            Text("Wizzzee \(AppInfo.version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04))
    }

    private func pageButton(_ entry: WelcomePage) -> some View {
        let isCurrent = entry == page
        return Button {
            page = entry
        } label: {
            HStack(spacing: 8) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(entry.tint.gradient)
                    )
                Text(entry.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isCurrent ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: - The foot of it

    private var isLastPage: Bool { page == WelcomePage.allCases.last }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Don’t show this again", isOn: $staysAway)
                .toggleStyle(.checkbox)
                .onChange(of: staysAway) { Preferences.showsWelcome = !staysAway }
                .help("Wizzzee opens with this guide until this is ticked.")
            // Said, not left to a tooltip: it is what makes the box safe to
            // tick.
            Text("It stays in the Help menu.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(page.rawValue + 1) of \(WelcomePage.allCases.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            Button("Back") { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(page == WelcomePage.allCases.first)

            if isLastPage {
                Button("Get Started") { onClose() }
                    .keyboardShortcut(.defaultAction)
            } else {
                // Esc and Return are both a way out of a dialog, and Return
                // here turns the page: Esc is the one that shuts it.
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Next") { step(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Keys for buttons that are not drawn, since one button takes one
        // key: → turns the page as Return does, and Esc shuts the guide on
        // the last page, where there is no Close to carry it.
        .background(
            Group {
                Button("") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                if isLastPage {
                    Button("") { onClose() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .opacity(0)
            .accessibilityHidden(true)
        )
    }

    private func step(_ by: Int) {
        guard let next = WelcomePage(rawValue: page.rawValue + by) else { return }
        page = next
    }
}

/// What one page says: a picture of the part of the app it is about, where
/// that is, and the things to do there.
struct WelcomePageView: View {
    let page: WelcomePage

    /// The tips two to a row.
    private var rows: [[WelcomeTip]] {
        let tips = page.tips
        return stride(from: 0, to: tips.count, by: 2).map { start in
            Array(tips[start..<min(start + 2, tips.count)])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if page == .keys {
                    heading
                    WelcomeShortcutsTable()
                } else {
                    WelcomeArt(page: page)
                        .frame(height: 184)
                    heading
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach(rows, id: \.first?.id) { row in
                            GridRow {
                                ForEach(row) { tip in
                                    WelcomeTipCard(tip: tip)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(page.headline)
                    .font(.system(size: 21, weight: .semibold))
                Text(page.lead)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let place = page.place {
                VStack(spacing: 4) {
                    WindowMap(lit: page.regions, showsFileView: page == .search)
                    Text(place)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: 112)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Where it is: " + place)
            }
        }
    }
}

/// One thing to do, under the number the picture points at it with.
struct WelcomeTipCard: View {
    let tip: WelcomeTip

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            GuideBadge(number: tip.id)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text(tip.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                    Spacer(minLength: 0)
                    if !tip.keys.isEmpty {
                        KeyRow(keys: tip.keys).fixedSize()
                    }
                }
                Text(LocalizedStringKey(tip.text))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        // As tall as the card beside it, whichever of the two has more to say.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08))
        )
    }
}

/// Every key, under the heading of what it is for.
struct WelcomeShortcutsTable: View {
    /// Two columns of about the same length.
    private var halves: [[WelcomeShortcutGroup]] {
        let groups = WelcomeShortcutGroup.all
        return [Array(groups.prefix(2)), Array(groups.dropFirst(2))]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(Array(halves.enumerated()), id: \.offset) { half in
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(half.element) { group in
                        section(group)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func section(_ group: WelcomeShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 5)
            VStack(spacing: 0) {
                ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { entry in
                    if entry.offset > 0 { Divider() }
                    line(entry.element)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08))
            )
        }
    }

    private func line(_ shortcut: WelcomeShortcut) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(shortcut.action)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            KeyRow(keys: shortcut.keys)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
    }
}

/// Keys and chords in a row: `⌘ R`, or `→  ←`.
struct KeyRow: View {
    let keys: [[String]]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(keys.enumerated()), id: \.offset) { chord in
                HStack(spacing: 2) {
                    ForEach(Array(chord.element.enumerated()), id: \.offset) { key in
                        KeyCap(label: key.element)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(KeyCap.spoken(chord.element))
            }
        }
    }
}

/// One key, drawn as the top of one.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 19)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.22))
            )
            .shadow(color: .black.opacity(0.14), radius: 0, y: 1)
    }

    /// The names of the keys the symbols stand for, for being read out.
    static func spoken(_ chord: [String]) -> String {
        chord.map { key in
            switch key {
            case "⌘": return "Command"
            case "⇧": return "Shift"
            case "⌥": return "Option"
            case "⌫": return "Delete"
            case "↩": return "Return"
            case "→": return "Right Arrow"
            case "←": return "Left Arrow"
            case "esc": return "Escape"
            case "space": return "Space"
            default: return key
            }
        }
        .joined(separator: " ")
    }
}

/// A numbered dot: on a picture, and on the card that says what it is
/// pointing at.
struct GuideBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            .accessibilityHidden(true)
    }
}

/// The window, drawn small, with the part a page is about lit.
struct WindowMap: View {
    enum Region: Hashable {
        case header, tabs, table, types, treemap, filter, marks, status
    }

    let lit: Set<Region>
    /// The window as it is with File View in front: the filter over one
    /// table, where Tree View has the tree, the types beside it and the
    /// treemap below.
    var showsFileView = false

    var body: some View {
        VStack(spacing: 2) {
            part(.header).frame(height: 11)
            part(.tabs).frame(height: 4)
            if showsFileView {
                part(.filter).frame(height: 4)
                part(.table).frame(height: 28)
            } else {
                HStack(spacing: 2) {
                    part(.table)
                    part(.types).frame(width: 24)
                }
                .frame(height: 17)
                part(.treemap).frame(height: 15)
            }
            part(.marks).frame(height: 4)
            part(.status).frame(height: 3)
        }
        .padding(5)
        .frame(width: 112)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.18)))
    }

    private func part(_ region: Region) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                lit.contains(region)
                    ? Color.accentColor : Color.primary.opacity(0.13)
            )
    }
}
