import AppKit
import SwiftUI

/// Interactive treemap. Hover to inspect, click to select and sync the tree
/// table, double-click a folder to zoom into it.
struct TreemapCanvas: NSViewRepresentable {
    let root: DirNode?
    let metric: SizeMetric
    let selection: NodeRef?
    /// Bumped whenever the tree is mutated, to force a fresh layout.
    let revision: Int
    /// The tree's revision at the moment of asking, rather than as of the last
    /// update — see `TreemapNSView.showsCurrentTree`.
    let liveRevision: () -> Int
    /// The model's treemap queue, which a delete fences before unlinking nodes.
    let layoutQueue: DispatchQueue

    let onSelect: (NodeRef) -> Void
    let onZoom: (DirNode) -> Void
    let onHover: (NodeRef?) -> Void
    let onOutline: (NodeRef?) -> Void
    /// What is marked for removal, which the map draws hatched.
    let marks: Set<NodeRef>
    let onMark: (NodeRef) -> Void

    func makeNSView(context: Context) -> TreemapNSView {
        let view = TreemapNSView()
        view.onMark = onMark
        view.marks = marks
        view.layoutQueue = layoutQueue
        view.liveRevision = liveRevision
        view.onSelect = onSelect
        view.onZoom = onZoom
        view.onHover = onHover
        view.onOutline = onOutline
        return view
    }

    func updateNSView(_ view: TreemapNSView, context: Context) {
        view.layoutQueue = layoutQueue
        view.liveRevision = liveRevision
        view.onSelect = onSelect
        view.onZoom = onZoom
        view.onHover = onHover
        view.onOutline = onOutline
        view.onMark = onMark
        view.marks = marks
        view.selection = selection
        view.apply(root: root, metric: metric, revision: revision)
    }
}

final class TreemapNSView: NSView {
    var onSelect: ((NodeRef) -> Void)?
    var onZoom: ((DirNode) -> Void)?
    var onHover: ((NodeRef?) -> Void)?
    /// Told which item the map is drawing its selection outline round, and
    /// nil when it is drawing none.
    ///
    /// Being selected is not being outlined. A file inside a folder drawn as
    /// one tile has no tile of its own, nor has an empty file or a second
    /// name for a hard link, and a tile clicked at one zoom can be too small
    /// to draw at another. ⌘⌫ acts on what can be seen, so it has to be told
    /// which of those this is.
    var onOutline: ((NodeRef?) -> Void)?
    /// Asks the model for the tree's revision as it is this instant.
    var liveRevision: (() -> Int)?
    /// Told which tile was ⌘-clicked, to have its mark put on or taken off.
    var onMark: ((NodeRef) -> Void)?

    /// What is marked for removal. Their tiles are hatched, so what is about
    /// to go can be seen for the share of the disk it is.
    var marks: Set<NodeRef> = [] {
        didSet {
            guard marks != oldValue else { return }
            hatched = nil
            needsDisplay = true
        }
    }
    /// Where the hatching goes, worked out once per change of marks or
    /// layout: drawing happens on every move of the pointer.
    private var hatched: [CGRect]?

    var selection: NodeRef? {
        didSet {
            guard selection != oldValue else { return }
            needsDisplay = true
            reportOutline()
        }
    }
    /// What `onOutline` was last told, so it only hears of a change.
    private var reportedOutline: NodeRef?

    private var root: DirNode?
    /// `root`'s parent chain, held for as long as `root` is.
    ///
    /// Collected in `apply`, on the main thread at the moment SwiftUI hands the
    /// root over — the one point the chain is known to be alive — and passed to
    /// every layout queued for it. A layout that walked the chain itself did so
    /// on the layout queue, after a rescan could already have freed it.
    private var ancestors: [DirNode] = []
    private var metric: SizeMetric = .logical
    private var revision = -1

    private var model = TreemapModel()
    /// The tree revision the layout in `model` was built from.
    private var modelRevision = -1
    private var image: NSImage?
    private var hovered: TreemapCell?
    private var pointerLocation: CGPoint?

    /// Guards against a stale background render landing after a newer one.
    private var renderToken = 0
    private var layoutSize: CGSize = .zero
    private var resizeDebounce: DispatchWorkItem?
    /// Where layout and rasterizing run. Supplied by the model rather than made
    /// here, because a delete has to be able to fence against it.
    var layoutQueue: DispatchQueue?

    /// False from the moment a delete changes the tree until a layout of the
    /// changed tree has landed.
    ///
    /// Layout is asynchronous, so for that long the tiles on show are the old
    /// ones, tiles for folders the delete has just unlinked among them. Those
    /// nodes are alive only because this layout still holds them. A click that
    /// handed one to the model left it holding a node whose parents are freed
    /// the moment the new layout replaces this one, and the next thing to ask
    /// for its path read freed memory. So the map answers nothing until what
    /// it shows is the tree as it now is.
    ///
    /// Asked of the model, not judged from `revision`: that is only as new as
    /// SwiftUI's last update, and a click can arrive between a delete and it.
    private var showsCurrentTree: Bool {
        guard let liveRevision else { return true }
        return liveRevision() == modelRevision
    }

    // Layout uses a top-left origin, like the tree table.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(root: DirNode?, metric: SizeMetric, revision: Int) {
        let changed =
            self.root !== root || self.metric != metric || self.revision != revision
        guard changed else { return }
        self.root = root
        self.ancestors = root.map { TreemapLayout.ancestors(of: $0) } ?? []
        self.metric = metric
        self.revision = revision
        rebuild()
    }

    // MARK: - Layout & render

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Relayout only once resizing settles — a full layout per frame would
        // make dragging the splitter crawl.
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.bounds.size != self.layoutSize else { return }
            self.rebuild()
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Works out whether the selection has an outline and passes on a change.
    private func reportOutline() {
        let outlined =
            showsCurrentTree
            ? selection.flatMap { rect(for: $0) == nil ? nil : $0 } : nil
        guard outlined != reportedOutline else { return }
        reportedOutline = outlined
        // On the next turn of the run loop, as with hover: this is reachable
        // from `updateNSView`, and the model can't be published to from there.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedOutline == outlined else { return }
            self.onOutline?(outlined)
        }
    }

    private func rebuild() {
        renderToken += 1
        let token = renderToken
        let size = bounds.size
        layoutSize = size
        // A layout of the tree before a delete outlines nothing that can be
        // acted on, from the moment the tree moves on.
        reportOutline()

        // Cleared here rather than in `apply`, which the resize path doesn't go
        // through: dragging the splitter with the pointer over the map re-laid
        // it out underneath the cursor while the hover outline kept being
        // stroked at the old cell's rect, over entirely different tiles.
        if hovered != nil {
            hovered = nil
            // Announced on the next turn of the run loop, never inline:
            // `rebuild()` is reachable from `updateNSView`, and publishing model
            // state from inside a SwiftUI view update is not allowed.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hovered == nil else { return }
                self.onHover?(nil)
            }
        }

        guard let root, size.width > 4, size.height > 4, root.totalSize > 0,
            let queue = layoutQueue
        else {
            model = TreemapModel()
            image = nil
            needsDisplay = true
            reportOutline()
            return
        }

        // Layout walks the live tree — allocating and sorting a `[NodeRef]` per
        // directory it visits — and it runs again on every resize step, zoom,
        // metric change and tree revision. On the main thread that was tens of
        // milliseconds of stopped run loop each time, and a folder with a very
        // large number of entries in one directory is far worse.
        //
        // It goes to the model's treemap queue, which `AppModel.detach` fences
        // before it unlinks anything: the layout reads nodes a delete would
        // otherwise be freeing underneath it. Rasterizing only touches the
        // value types the layout produced, so it follows on the same queue
        // rather than hopping to another.
        //
        // A rescan doesn't fence. It only lets go of the tree, so what a queued
        // layout reads has to be held by the layout itself: the subtree through
        // `root`, and the folders above it through `ancestors`.
        let metric = self.metric
        let ancestors = self.ancestors
        let revision = self.revision
        let scale = window?.backingScaleFactor ?? 2

        queue.async { [weak self] in
            let built = TreemapLayout.build(
                root: root,
                ancestors: ancestors,
                size: size,
                metric: metric
            )
            let rendered = TreemapRenderer.render(model: built, scale: scale)
            DispatchQueue.main.async {
                guard let self, token == self.renderToken else { return }
                // Both land together, so the borders and labels drawn from the
                // model always describe the image underneath them.
                self.model = built
                self.modelRevision = revision
                self.image = rendered.map { NSImage(cgImage: $0, size: size) }
                self.hatched = nil
                self.needsDisplay = true
                self.reportOutline()
            }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        NSColor(white: 0.06, alpha: 1).setFill()
        bounds.fill()

        guard let image else {
            drawPlaceholder()
            return
        }
        image.draw(in: bounds)

        drawGroupBorders(in: context)
        drawMarks(in: context)
        drawFolderLabels()

        if let selection, let rect = rect(for: selection) {
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }

        if let hovered, hovered.ref != selection {
            NSColor(white: 1, alpha: 0.85).setStroke()
            let path = NSBezierPath(rect: hovered.rect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }

        drawTooltip()
    }

    private func drawPlaceholder() {
        let text = root == nil ? "No scan yet" : "Nothing to show"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(white: 0.45, alpha: 1),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(
            at: CGPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            )
        )
    }

    /// White hairlines around folder groups, fading with depth so the top-level
    /// structure stays the most legible.
    private func drawGroupBorders(in context: CGContext) {
        context.saveGState()
        for frame in model.frames where frame.depth > 0 {
            guard frame.depth <= 6 else { continue }
            guard frame.rect.width > 3, frame.rect.height > 3 else { continue }
            let alpha = max(0.08, 0.55 - Double(frame.depth - 1) * 0.09)
            context.setStrokeColor(
                NSColor(white: 1, alpha: alpha).cgColor
            )
            context.setLineWidth(frame.depth == 1 ? 1.0 : 0.5)
            context.stroke(frame.rect.insetBy(dx: 0.25, dy: 0.25))
        }
        context.restoreGState()
    }

    /// The parts of the map that are marked for removal.
    ///
    /// A marked file is its tile, and a marked folder is its whole group — or
    /// its one tile, where it is too small to have been broken down. One pass
    /// over what was laid out, asking each whether it is marked, not a search
    /// of the layout per mark: there can be a great many of either.
    ///
    /// Zoomed to somewhere inside a marked folder, everything on show is
    /// going with it, and nothing on show is the thing that was marked.
    var markedRects: [CGRect] {
        guard !marks.isEmpty, let root = model.root else { return [] }
        if ([root] + model.ancestors).contains(where: { marks.contains(NodeRef($0)) }) {
            return [CGRect(origin: .zero, size: model.size)]
        }
        var rects: [CGRect] = []
        for frame in model.frames where marks.contains(NodeRef(frame.dir)) {
            rects.append(frame.rect)
        }
        for cell in model.cells where marks.contains(cell.ref) {
            rects.append(cell.rect)
        }
        return rects
    }

    /// Diagonal lines over a darkened tile: still the tile it was, plainly
    /// struck through.
    private func drawMarks(in context: CGContext) {
        guard showsCurrentTree, !marks.isEmpty else { return }
        let rects = hatched ?? markedRects
        hatched = rects
        let spacing: CGFloat = 6

        for rect in rects where rect.width > 2 && rect.height > 2 {
            context.saveGState()
            context.clip(to: rect)
            context.setFillColor(NSColor(white: 0, alpha: 0.38).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor(white: 1, alpha: 0.5).cgColor)
            context.setLineWidth(1)
            var x = rect.minX - rect.height
            while x < rect.maxX {
                context.move(to: CGPoint(x: x, y: rect.maxY))
                context.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += spacing
            }
            context.strokePath()
            context.restoreGState()

            context.setStrokeColor(NSColor(white: 1, alpha: 0.75).cgColor)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// Labels folder groups at their top-left, WizTree style.
    ///
    /// A folder and its biggest child share that corner, so a label that would
    /// land on one already drawn is pushed down a line instead; if there is still
    /// no room it is dropped rather than rendered as overlapping mush.
    private func drawFolderLabels() {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = .zero

        let lineHeight: CGFloat = 13
        // Keep the label off the tile's top-left corner so it reads as sitting
        // inside the group instead of clipped against its top and left edges.
        // A group at the very edge of the pane has its first few points hidden
        // under the surrounding chrome, so the inset has to clear that too.
        let insetX: CGFloat = 12
        let insetTop: CGFloat = 8
        // Only the left gap is spent twice over; the right side just needs
        // enough room that the truncation ellipsis isn't flush to the border.
        let trailingGap: CGFloat = 4
        var placed: [CGRect] = []

        // frames are appended depth-first, so shallower groups get first claim.
        for frame in model.frames where frame.depth > 0 {
            guard frame.depth <= 4 else { continue }
            guard frame.rect.width >= 62, frame.rect.height >= insetTop + lineHeight
            else { continue }

            let label =
                "\(frame.dir.name) (\(ByteFormat.decimal(sizeValue(frame.dir))))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(
                    ofSize: frame.depth == 1 ? 10.5 : 9.5,
                    weight: .medium
                ),
                .foregroundColor: NSColor(white: 1, alpha: 0.96),
                .shadow: shadow,
            ]
            let string = NSAttributedString(string: label, attributes: attributes)
            let width = min(
                string.size().width + 2,
                frame.rect.width - insetX - trailingGap
            )

            var textRect = CGRect(
                x: frame.rect.minX + insetX,
                y: frame.rect.minY + insetTop,
                width: width,
                height: lineHeight
            )
            var attempt = 0
            while placed.contains(where: { $0.intersects(textRect) }), attempt < 3 {
                textRect.origin.y += lineHeight
                attempt += 1
            }
            // Only keep it if the shifted line still sits inside the group.
            guard textRect.maxY <= frame.rect.maxY,
                !placed.contains(where: { $0.intersects(textRect) })
            else { continue }

            placed.append(textRect.insetBy(dx: -2, dy: -1))
            // .usesLineFragmentOrigin is required: without it the rect's origin
            // is taken as the text baseline, drawing every label a line too high
            // and clipping the ascenders against the top of the tile.
            string.draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
        }
    }

    private func drawTooltip() {
        guard let hovered, let pointer = pointerLocation else { return }
        let ref = hovered.ref

        let title = ref.path
        let detail = Self.tooltipDetail(for: ref, metric: metric)

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor(white: 0.75, alpha: 1),
        ]
        let titleString = NSAttributedString(string: title, attributes: titleAttributes)
        let detailString = NSAttributedString(
            string: detail,
            attributes: detailAttributes
        )

        let maxWidth: CGFloat = min(520, bounds.width - 24)
        let titleSize = titleString.boundingRect(
            with: CGSize(width: maxWidth, height: 32),
            options: [.usesLineFragmentOrigin]
        ).size
        let detailSize = detailString.size()

        let padding: CGFloat = 6
        let boxWidth = min(maxWidth, max(titleSize.width, detailSize.width)) + padding * 2
        let boxHeight = titleSize.height + detailSize.height + padding * 2 + 2

        // Keep the box on screen and out from under the cursor.
        var origin = CGPoint(x: pointer.x + 14, y: pointer.y + 16)
        if origin.x + boxWidth > bounds.maxX - 4 {
            origin.x = max(4, pointer.x - boxWidth - 10)
        }
        if origin.y + boxHeight > bounds.maxY - 4 {
            origin.y = max(4, pointer.y - boxHeight - 10)
        }
        let box = CGRect(x: origin.x, y: origin.y, width: boxWidth, height: boxHeight)

        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor(white: 0.1, alpha: 0.95).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()

        titleString.draw(
            with: CGRect(
                x: box.minX + padding,
                y: box.minY + padding,
                width: boxWidth - padding * 2,
                height: titleSize.height
            ),
            options: [.usesLineFragmentOrigin]
        )
        detailString.draw(
            at: CGPoint(
                x: box.minX + padding,
                y: box.minY + padding + titleSize.height + 2
            )
        )
    }

    /// The tooltip's second line: both measures, each named, with the one the
    /// tiles are drawn from in front. It led with the length whatever the map
    /// was showing, so the tile for a sparse image — sized by the 42 GB it
    /// occupies — opened on "995 GB".
    static func tooltipDetail(for ref: NodeRef, metric: SizeMetric) -> String {
        let size = ByteFormat.decimal(ref.size)
        let alloc = ByteFormat.decimal(ref.alloc)
        var detail =
            metric == .logical
            ? "\(size)  •  on disk \(alloc)"
            : "\(alloc) on disk  •  size \(size)"
        if ref.isDirectory {
            detail += "  •  \(ByteFormat.counted(ref.dir.totalItems, "item"))"
        }
        return detail
    }

    private func sizeValue(_ dir: DirNode) -> UInt64 {
        metric == .logical ? dir.totalSize : dir.totalAlloc
    }

    private func rect(for ref: NodeRef) -> CGRect? {
        if let cell = model.cells.first(where: { $0.ref == ref }) {
            return cell.rect
        }
        if ref.isDirectory,
            let frame = model.frames.first(where: { $0.dir === ref.dir })
        {
            return frame.rect
        }
        return nil
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerLocation = point
        let found = showsCurrentTree ? model.cell(at: point) : nil
        let changed = found?.ref != hovered?.ref
        if changed {
            hovered = found
            onHover?(found?.ref)
        }
        // A redraw here re-strokes every group border and lays out an attributed
        // string per labelled folder, so it is worth skipping when nothing on
        // screen would differ. Moving within one tile still redraws — the
        // tooltip follows the pointer — but sweeping across empty space no
        // longer does.
        if changed || hovered != nil { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        pointerLocation = nil
        onHover?(nil)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard showsCurrentTree else { return }
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount >= 2 {
            // A folder drawn as a single tile — too small or too deep to
            // subdivide — has no frame of its own, so asking for the innermost
            // frame here returned its *parent* and the zoom either went the
            // wrong way or, at the map's root, did nothing at all. That tile is
            // the only way to drill past the layout's depth limit, so it is
            // matched before falling back to the enclosing frame.
            if let cell = model.cell(at: point), cell.ref.isDirectory {
                onZoom?(cell.ref.dir)
                return
            }
            // A file tile zooms to the innermost folder that contains it.
            if let frame = model.frame(at: point), frame.depth > 0 {
                onZoom?(frame.dir)
                return
            }
            if let cell = model.cell(at: point) { onZoom?(cell.ref.dir) }
            return
        }

        // ⌘-click marks, as it adds to a selection in a table: the tile is
        // put among the marks, or taken out, and what is selected is left be.
        if event.modifierFlags.contains(.command) {
            if let cell = model.cell(at: point) { onMark?(cell.ref) }
            return
        }

        if let cell = model.cell(at: point) {
            selection = cell.ref
            onSelect?(cell.ref)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard showsCurrentTree, let cell = model.cell(at: point) else { return }
        selection = cell.ref
        onSelect?(cell.ref)
        super.rightMouseDown(with: event)
    }
}
