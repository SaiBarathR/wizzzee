import SwiftUI

/// Colors shared by the treemap and the file-type legend.
///
/// Extensions are ranked by total size during aggregation, so `colorIndex` is a
/// popularity rank: the biggest contributors get the most separable hues and
/// everything past the palette falls through to a neutral gray, which is how
/// WizTree keeps a busy treemap readable.
enum TreemapPalette {
    /// RGB triples, chosen for separability at small sizes under cushion shading.
    static let colors: [(r: Double, g: Double, b: Double)] = [
        (0.91, 0.58, 0.20),  // orange
        (0.30, 0.68, 0.31),  // green
        (0.86, 0.24, 0.31),  // crimson
        (0.24, 0.47, 0.78),  // steel blue
        (0.94, 0.78, 0.20),  // gold
        (0.78, 0.31, 0.63),  // magenta
        (0.19, 0.69, 0.66),  // teal
        (0.55, 0.31, 0.78),  // purple
        (0.78, 0.80, 0.20),  // yellow green
        (0.25, 0.75, 0.88),  // cyan
        (0.85, 0.42, 0.35),  // salmon
        (0.35, 0.55, 0.24),  // olive
        (0.63, 0.44, 0.25),  // brown
        (0.94, 0.51, 0.69),  // pink
        (0.31, 0.35, 0.75),  // indigo
        (0.20, 0.63, 0.44),  // sea green
        (0.72, 0.62, 0.24),  // amber
        (0.60, 0.24, 0.40),  // rose
        (0.44, 0.69, 0.87),  // sky
        (0.44, 0.80, 0.62),  // mint
        (0.64, 0.38, 0.64),  // plum
        (0.87, 0.66, 0.44),  // tan
        (0.48, 0.52, 0.60),  // slate
        (0.36, 0.42, 0.47),  // charcoal
    ]

    /// Neutral fill for extensions outside the palette.
    static let overflow = (r: 0.45, g: 0.47, b: 0.50)
    /// Fill for a folder too small to subdivide any further.
    static let collapsedFolder = (r: 0.38, g: 0.42, b: 0.48)

    static func rgb(_ index: Int) -> (r: Double, g: Double, b: Double) {
        index >= 0 && index < colors.count ? colors[index] : overflow
    }

    static func color(_ index: Int) -> Color {
        let c = rgb(index)
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}
