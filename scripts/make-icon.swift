#!/usr/bin/env swift
//
// Renders Wizzzee's app icon: a squarified treemap on a dark rounded square,
// which is the thing the app actually shows. Writes every size an .icns needs
// into the iconset directory given as the first argument.
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let weights: [Double] = [30, 18, 12, 9, 7, 6, 5, 4, 3, 2.5, 2, 1.6, 1.2]
let palette: [(Double, Double, Double)] = [
    (0.91, 0.58, 0.20), (0.30, 0.68, 0.31), (0.86, 0.24, 0.31),
    (0.24, 0.47, 0.78), (0.94, 0.78, 0.20), (0.78, 0.31, 0.63),
    (0.19, 0.69, 0.66), (0.55, 0.31, 0.78), (0.78, 0.80, 0.20),
    (0.25, 0.75, 0.88), (0.85, 0.42, 0.35), (0.35, 0.55, 0.24),
    (0.63, 0.44, 0.25),
]

/// Same squarified subdivision the app uses, condensed.
func squarify(_ areas: [Double], in rect: CGRect) -> [CGRect] {
    var result = [CGRect](repeating: .zero, count: areas.count)
    let total = areas.reduce(0, +)
    guard total > 0 else { return result }
    let scale = Double(rect.width * rect.height) / total
    var free = rect
    var index = 0

    func worst(_ sum: Double, _ lo: Double, _ hi: Double, _ side: Double) -> Double {
        guard sum > 0, lo > 0 else { return .infinity }
        return max(side * side * hi / (sum * sum), sum * sum / (side * side * lo))
    }

    while index < areas.count {
        let side = Double(min(free.width, free.height))
        if side <= 0 { break }
        var sum = 0.0, count = 0, best = Double.infinity
        var lo = Double.greatestFiniteMagnitude, hi = 0.0
        while index + count < areas.count {
            let area = areas[index + count] * scale
            let w = worst(sum + area, min(lo, area), max(hi, area), side)
            if count > 0 && w > best { break }
            sum += area
            lo = min(lo, area)
            hi = max(hi, area)
            best = w
            count += 1
        }
        let thickness = CGFloat(sum / side)
        if free.width <= free.height {
            var x = free.minX
            for i in 0..<count {
                let w = CGFloat(areas[index + i] * scale) / thickness
                result[index + i] = CGRect(x: x, y: free.minY, width: w, height: thickness)
                x += w
            }
            free = CGRect(
                x: free.minX, y: free.minY + thickness,
                width: free.width, height: free.height - thickness)
        } else {
            var y = free.minY
            for i in 0..<count {
                let h = CGFloat(areas[index + i] * scale) / thickness
                result[index + i] = CGRect(x: free.minX, y: y, width: thickness, height: h)
                y += h
            }
            free = CGRect(
                x: free.minX + thickness, y: free.minY,
                width: free.width - thickness, height: free.height)
        }
        index += count
    }
    return result
}

func render(size: Int) -> CGImage? {
    let dimension = CGFloat(size)
    guard
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // macOS icons sit inset inside their canvas.
    let margin = dimension * 0.09
    let canvas = CGRect(
        x: margin, y: margin, width: dimension - margin * 2, height: dimension - margin * 2)
    let radius = canvas.width * 0.185

    // Dark rounded plate with a subtle vertical gradient.
    let plate = CGPath(roundedRect: canvas, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(plate)
    context.clip()
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1),
            CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1),
        ] as CFArray, locations: [0, 1])
    {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: canvas.maxY), end: CGPoint(x: 0, y: canvas.minY),
            options: [])
    }

    // Treemap tiles inside the plate.
    let inset = canvas.width * 0.115
    let field = canvas.insetBy(dx: inset, dy: inset)
    let gap = max(dimension * 0.006, 0.5)
    for (i, tile) in squarify(weights, in: field).enumerated() {
        let color = palette[i % palette.count]
        let drawn = tile.insetBy(dx: gap, dy: gap)
        guard drawn.width > 0, drawn.height > 0 else { continue }
        let corner = min(drawn.width, drawn.height) * 0.14
        context.addPath(
            CGPath(
                roundedRect: drawn, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.setFillColor(
            CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
        context.fillPath()

        // A soft top highlight, echoing the cushion shading in the app.
        if drawn.height > dimension * 0.05 {
            context.saveGState()
            context.addPath(
                CGPath(
                    roundedRect: drawn, cornerWidth: corner, cornerHeight: corner,
                    transform: nil))
            context.clip()
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
            context.fill(
                CGRect(
                    x: drawn.minX, y: drawn.maxY - drawn.height * 0.32,
                    width: drawn.width, height: drawn.height * 0.32))
            context.restoreGState()
        }
    }
    context.restoreGState()

    // Hairline edge so the plate reads against a light desktop.
    context.addPath(plate)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    context.setLineWidth(max(dimension * 0.004, 0.5))
    context.strokePath()

    return context.makeImage()
}

func write(_ image: CGImage, to url: URL) -> Bool {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(
    at: outputDirectory, withIntermediateDirectories: true)

// (base point size, scale) pairs iconutil expects.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

for (base, scale) in variants {
    let pixels = base * scale
    guard let image = render(size: pixels) else {
        FileHandle.standardError.write("failed to render \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    let suffix = scale == 1 ? "" : "@2x"
    let name = "icon_\(base)x\(base)\(suffix).png"
    if !write(image, to: outputDirectory.appendingPathComponent(name)) {
        FileHandle.standardError.write("failed to write \(name)\n".data(using: .utf8)!)
        exit(1)
    }
}
print("wrote \(variants.count) icon variants to \(outputDirectory.path)")
