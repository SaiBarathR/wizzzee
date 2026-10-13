import SwiftUI

/// A part of the window that says where it has been put.
enum WindowPart: Hashable {
    case header, tabs, statusBar
    case marksList
    case showMarksList, clearMarks, trashMarked, deleteMarked
    /// The guide's page, and what is on it: longer or wider than the page,
    /// some of it is out of sight.
    case guidePage, guidePageContents
}

/// Where each of those parts is, of the ones on screen, in the window's own
/// coordinates from its top left.
///
/// For the self-test, which puts the real window together and asks where
/// things are. It used to look for AppKit's buttons under the window. Built
/// against the newer SDK, SwiftUI draws its buttons without any, and in the
/// build that ships there were none to find. This is the layout as SwiftUI
/// has it, whatever it is drawn with.
struct WindowPartFrames: PreferenceKey {
    static var defaultValue: [WindowPart: CGRect] = [:]

    static func reduce(
        value: inout [WindowPart: CGRect],
        nextValue: () -> [WindowPart: CGRect]
    ) {
        value.merge(nextValue()) { _, later in later }
    }
}

extension View {
    /// Reports where this view has been put, as `part`.
    func placed(as part: WindowPart) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WindowPartFrames.self,
                    value: [part: geometry.frame(in: .global)]
                )
            }
        )
    }
}
