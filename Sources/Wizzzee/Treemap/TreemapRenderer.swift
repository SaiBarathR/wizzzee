import CoreGraphics
import Foundation

/// Rasterizes a `TreemapModel` into a shaded bitmap.
///
/// Each tile is a parabolic "cushion" lit by a directional light, so nesting
/// depth reads as depth on screen. The shading is evaluated per pixel — the sum
/// of all tile areas is just the canvas area, so the whole render costs about
/// one pass over the bitmap regardless of how many tiles there are.
enum TreemapRenderer {
    /// Light direction (x, y, z) with y pointing down the screen, so the
    /// highlight falls on the top-left of every bump.
    private static let light = normalize(-0.42, -0.52, 1.0)
    private static let ambient = 0.47
    private static let diffuse = 0.64
    /// Caps the highlight so bright palette entries don't clip to flat white.
    private static let maxIntensity = 1.22
    /// How much a tile's 1px border is darkened, to separate adjacent tiles.
    private static let edgeShade = 0.62
    private static let background: UInt32 = 0x0F_1114

    static func render(model: TreemapModel, scale: CGFloat) -> CGImage? {
        let width = Int((model.size.width * scale).rounded())
        let height = Int((model.size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        let pixelCount = width * height
        let buffer = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
        buffer.initialize(repeating: background, count: pixelCount)

        let inverseScale = 1.0 / Double(scale)

        for cell in model.cells {
            let base =
                cell.colorIndex < 0
                ? TreemapPalette.collapsedFolder
                : TreemapPalette.rgb(cell.colorIndex)

            // Pixel bounds, clamped to the bitmap.
            let x0 = max(0, Int((cell.rect.minX * scale).rounded(.down)))
            let x1 = min(width, max(x0 + 1, Int((cell.rect.maxX * scale).rounded(.up))))
            let y0 = max(0, Int((cell.rect.minY * scale).rounded(.down)))
            let y1 = min(height, max(y0 + 1, Int((cell.rect.maxY * scale).rounded(.up))))
            guard x0 < x1, y0 < y1 else { continue }

            // Tiles butt right up against each other, so without a darkened
            // edge a run of same-extension files reads as one smeared blob
            // instead of individually countable files.
            let edge = max(1, Int(scale.rounded()))
            let insetX = (x1 - x0) > edge * 3
            let insetY = (y1 - y0) > edge * 3

            for py in y0..<y1 {
                // Layout coordinates are in points, with y increasing downward,
                // matching the bitmap's row order.
                let y = (Double(py) + 0.5) * inverseScale
                let ny = -(2 * cell.sy2 * y + cell.sy1)
                let rowStart = py * width
                let onEdgeY = insetY && (py - y0 < edge || y1 - py <= edge)

                for px in x0..<x1 {
                    let x = (Double(px) + 0.5) * inverseScale
                    let nx = -(2 * cell.sx2 * x + cell.sx1)

                    let length = (nx * nx + ny * ny + 1).squareRoot()
                    let dot =
                        (nx * light.x + ny * light.y + light.z) / length
                    var intensity = min(
                        maxIntensity,
                        ambient + diffuse * max(0, dot)
                    )

                    let onEdgeX = insetX && (px - x0 < edge || x1 - px <= edge)
                    if onEdgeX || onEdgeY { intensity *= edgeShade }

                    buffer[rowStart + px] = pack(
                        base.r * intensity,
                        base.g * intensity,
                        base.b * intensity
                    )
                }
            }
        }

        let byteCount = pixelCount * 4
        guard
            let provider = CGDataProvider(
                dataInfo: nil,
                data: buffer,
                size: byteCount,
                releaseData: { _, data, _ in
                    UnsafeMutableRawPointer(mutating: data)
                        .assumingMemoryBound(to: UInt32.self)
                        .deallocate()
                }
            )
        else {
            buffer.deallocate()
            return nil
        }

        // CGImage raw data is top-down, which is how the buffer was filled.
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Packs into the 0xXXRRGGBB layout that `noneSkipFirst` + little-endian
    /// byte order expects.
    @inline(__always)
    private static func pack(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
        let red = UInt32(max(0, min(255, r * 255)))
        let green = UInt32(max(0, min(255, g * 255)))
        let blue = UInt32(max(0, min(255, b * 255)))
        return (red << 16) | (green << 8) | blue
    }

    private static func normalize(
        _ x: Double,
        _ y: Double,
        _ z: Double
    ) -> (x: Double, y: Double, z: Double) {
        let length = (x * x + y * y + z * z).squareRoot()
        guard length > 0 else { return (0, 0, 1) }
        return (x / length, y / length, z / length)
    }
}
