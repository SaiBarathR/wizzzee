import CoreGraphics
import Foundation

/// A rendered leaf tile: one file, or one folder too small to subdivide.
struct TreemapCell {
    let rect: CGRect
    let ref: NodeRef
    let colorIndex: Int
    /// Quadratic cushion-surface coefficients, in layout point coordinates.
    let sx1: Double
    let sx2: Double
    let sy1: Double
    let sy2: Double
}

/// A folder's bounding box, used to draw group borders and labels.
struct TreemapFrame {
    let rect: CGRect
    let dir: DirNode
    let depth: Int
}

struct TreemapModel {
    var cells: [TreemapCell] = []
    var frames: [TreemapFrame] = []
    var size: CGSize = .zero
    /// The subtree this layout was built for.
    var root: DirNode?
    /// `root`'s parent chain, held only to keep it alive.
    ///
    /// A `DirNode`'s `parent` is unowned, on the basis that the scan's root
    /// retains the whole tree top-down. A layout outlives that guarantee: the
    /// view keeps the last one it was handed until SwiftUI gets round to
    /// updating it, and a delete in the meantime can free the folders above
    /// `root` while the cells and frames below it are still retained. Reading
    /// `path` or `fractionOfParent` on one of those would then walk into freed
    /// memory, so the chain is pinned for as long as the layout exists.
    var ancestors: [DirNode] = []
    var metric: SizeMetric = .logical

    /// Topmost tile at a point. Cells are appended in draw order, so the search
    /// runs backwards to find the deepest one first.
    func cell(at point: CGPoint) -> TreemapCell? {
        for cell in cells.reversed() where cell.rect.contains(point) {
            return cell
        }
        return nil
    }

    /// Innermost folder containing a point, for double-click-to-zoom.
    func frame(at point: CGPoint) -> TreemapFrame? {
        var best: TreemapFrame?
        for frame in frames where frame.rect.contains(point) {
            if best == nil || frame.depth > best!.depth { best = frame }
        }
        return best
    }
}

/// Builds a squarified treemap with van Wijk cushion shading coefficients.
///
/// Squarified layout keeps tiles close to square, which makes their areas far
/// easier to compare by eye than the long slivers a naive slice-and-dice
/// produces. The cushion coefficients accumulate down the recursion so nested
/// folders read as nested bumps rather than flat color fields.
enum TreemapLayout {
    /// Stop subdividing below this many points on either side.
    private static let minSubdivideSide: CGFloat = 5
    /// Skip tiles thinner than this — they cannot be seen or clicked.
    private static let minCellSide: CGFloat = 0.7
    private static let maxCells = 200_000

    /// Cushion height per tile, and how much of an ancestor's curvature carries
    /// into its children.
    ///
    /// The tile being drawn always gets the full ridge and inherited curvature is
    /// damped on the way down, so every file reads as its own bump. Letting
    /// ancestors keep full weight instead (as a literal reading of the paper
    /// suggests) makes one broad gradient wash across a big folder and swallows
    /// the tiles inside it.
    private static let cushionHeight = 0.30
    private static let inheritedDamping = 0.30

    static func build(
        root: DirNode,
        size: CGSize,
        metric: SizeMetric,
        maxDepth: Int = 12
    ) -> TreemapModel {
        var chain: [DirNode] = []
        var above = root.parent
        while let step = above {
            chain.append(step)
            above = step.parent
        }
        var model = TreemapModel(
            size: size,
            root: root,
            ancestors: chain,
            metric: metric
        )
        guard size.width > 1, size.height > 1 else { return model }

        let rect = CGRect(origin: .zero, size: size)
        model.frames.append(TreemapFrame(rect: rect, dir: root, depth: 0))
        subdivide(
            dir: root,
            rect: rect,
            depth: 0,
            maxDepth: maxDepth,
            metric: metric,
            sx1: 0,
            sx2: 0,
            sy1: 0,
            sy2: 0,
            into: &model
        )
        return model
    }

    private static func weight(_ ref: NodeRef, _ metric: SizeMetric) -> UInt64 {
        metric == .logical ? ref.size : ref.alloc
    }

    private static func subdivide(
        dir: DirNode,
        rect: CGRect,
        depth: Int,
        maxDepth: Int,
        metric: SizeMetric,
        sx1: Double,
        sx2: Double,
        sy1: Double,
        sy2: Double,
        into model: inout TreemapModel
    ) {
        guard model.cells.count < maxCells else { return }

        // Rank folders and files together by size, largest first.
        var children: [NodeRef] = []
        children.reserveCapacity(dir.subdirs.count + dir.files.count)
        for sub in dir.subdirs where weight(NodeRef(sub), metric) > 0 {
            children.append(NodeRef(sub))
        }
        for index in dir.files.indices {
            let ref = NodeRef(dir: dir, fileIndex: index)
            if dir.files[index].isDuplicateLink { continue }
            if weight(ref, metric) > 0 { children.append(ref) }
        }
        guard !children.isEmpty else { return }
        children.sort { weight($0, metric) > weight($1, metric) }

        let areas = children.map { Double(weight($0, metric)) }
        let rects = squarify(areas: areas, in: rect)

        for (index, child) in children.enumerated() {
            let childRect = rects[index]
            if childRect.width < minCellSide || childRect.height < minCellSide {
                continue
            }

            // Damp what this tile inherits, then lay its own ridge on top at
            // full strength so the tile itself is the dominant shape.
            var csx1 = sx1 * inheritedDamping
            var csx2 = sx2 * inheritedDamping
            var csy1 = sy1 * inheritedDamping
            var csy2 = sy2 * inheritedDamping
            addRidge(
                Double(childRect.minX),
                Double(childRect.maxX),
                cushionHeight,
                &csx1,
                &csx2
            )
            addRidge(
                Double(childRect.minY),
                Double(childRect.maxY),
                cushionHeight,
                &csy1,
                &csy2
            )

            if child.isDirectory {
                let canRecurse =
                    depth < maxDepth
                    && childRect.width >= minSubdivideSide
                    && childRect.height >= minSubdivideSide
                if canRecurse {
                    // Inset by a point so the group border has somewhere to go.
                    let inner = childRect.insetBy(dx: 1, dy: 1)
                    model.frames.append(
                        TreemapFrame(rect: childRect, dir: child.dir, depth: depth + 1)
                    )
                    if inner.width > minCellSide && inner.height > minCellSide {
                        subdivide(
                            dir: child.dir,
                            rect: inner,
                            depth: depth + 1,
                            maxDepth: maxDepth,
                            metric: metric,
                            sx1: csx1,
                            sx2: csx2,
                            sy1: csy1,
                            sy2: csy2,
                            into: &model
                        )
                        continue
                    }
                }
                // Too small or too deep to break down — draw it as one tile.
                model.cells.append(
                    TreemapCell(
                        rect: childRect,
                        ref: child,
                        colorIndex: -1,
                        sx1: csx1,
                        sx2: csx2,
                        sy1: csy1,
                        sy2: csy2
                    )
                )
            } else {
                model.cells.append(
                    TreemapCell(
                        rect: childRect,
                        ref: child,
                        colorIndex: Int(dir.files[Int(child.fileIndex)].extIndex),
                        sx1: csx1,
                        sx2: csx2,
                        sy1: csy1,
                        sy2: csy2
                    )
                )
            }
        }
    }

    /// Accumulates one parabolic ridge along an axis, per van Wijk & van de
    /// Wetering, "Cushion Treemaps" (1999).
    private static func addRidge(
        _ low: Double,
        _ high: Double,
        _ height: Double,
        _ s1: inout Double,
        _ s2: inout Double
    ) {
        let span = high - low
        guard span > 0 else { return }
        s1 += 4 * height * (high + low) / span
        s2 -= 4 * height / span
    }

    // MARK: - Squarified subdivision

    /// Lays `areas` (descending) out in `rect`, greedily filling strips along
    /// whichever side is currently shorter and closing a strip as soon as
    /// adding another tile would make its worst aspect ratio worse.
    static func squarify(areas: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: areas.count)
        let total = areas.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }

        // Convert weights into on-screen areas.
        let scale = Double(rect.width) * Double(rect.height) / total
        var free = rect
        var index = 0

        while index < areas.count {
            let shortSide = Double(min(free.width, free.height))
            guard shortSide > 0 else { break }

            var rowSum = 0.0
            var rowCount = 0
            var bestWorst = Double.infinity
            var minArea = Double.greatestFiniteMagnitude
            var maxArea = 0.0

            while index + rowCount < areas.count {
                let area = areas[index + rowCount] * scale
                let trySum = rowSum + area
                let tryMin = min(minArea, area)
                let tryMax = max(maxArea, area)
                let worst = worstAspect(
                    sum: trySum,
                    minArea: tryMin,
                    maxArea: tryMax,
                    side: shortSide
                )
                // Keep growing the strip only while squareness improves.
                if rowCount > 0 && worst > bestWorst { break }
                rowSum = trySum
                minArea = tryMin
                maxArea = tryMax
                bestWorst = worst
                rowCount += 1
            }

            let thickness = CGFloat(rowSum / shortSide)
            if free.width <= free.height {
                // Horizontal strip across the top of the free area.
                var x = free.minX
                for offset in 0..<rowCount {
                    let area = CGFloat(areas[index + offset] * scale)
                    let width = thickness > 0 ? area / thickness : 0
                    result[index + offset] = CGRect(
                        x: x,
                        y: free.minY,
                        width: width,
                        height: thickness
                    )
                    x += width
                }
                free = CGRect(
                    x: free.minX,
                    y: free.minY + thickness,
                    width: free.width,
                    height: max(0, free.height - thickness)
                )
            } else {
                // Vertical strip down the left of the free area.
                var y = free.minY
                for offset in 0..<rowCount {
                    let area = CGFloat(areas[index + offset] * scale)
                    let height = thickness > 0 ? area / thickness : 0
                    result[index + offset] = CGRect(
                        x: free.minX,
                        y: y,
                        width: thickness,
                        height: height
                    )
                    y += height
                }
                free = CGRect(
                    x: free.minX + thickness,
                    y: free.minY,
                    width: max(0, free.width - thickness),
                    height: free.height
                )
            }
            index += rowCount
        }
        return result
    }

    /// Worst aspect ratio in a strip of total area `sum` laid along `side`.
    private static func worstAspect(
        sum: Double,
        minArea: Double,
        maxArea: Double,
        side: Double
    ) -> Double {
        guard sum > 0, minArea > 0 else { return .infinity }
        let side2 = side * side
        let sum2 = sum * sum
        return max(side2 * maxArea / sum2, sum2 / (side2 * minArea))
    }
}
