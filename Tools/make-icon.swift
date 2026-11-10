#!/usr/bin/env swift
//
//  make-icon.swift
//  Draws the BarLens "Liquid Eclipse Orb" (Logo B) app icon and writes Resources/AppIcon.icns.
//
//  Uses an exact 1/16 (0.0625) grid-aligned margin so the squircle's top, bottom,
//  left, and right edges land on exact integer pixel boundaries at every iconset
//  resolution (16, 32, 64, 128, 256, 512, 1024), and supersamples from a 2048x2048
//  master canvas with smooth gradient rims (no abrupt arc endpoints or edge bleed).
//

import AppKit
import CoreGraphics

let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources", isDirectory: true)

let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

func drawRadialGlow(ctx: CGContext, center: CGPoint, radius: CGFloat, color: NSColor) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c0 = color.cgColor
    let c1 = color.withAlphaComponent(0).cgColor
    guard let grad = CGGradient(colorsSpace: cs, colors: [c0, c1] as CFArray, locations: [0.0, 1.0]) else { return }
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: .drawsAfterEndLocation)
}

/// Strokes `path` with a smooth linear gradient from `start` to `end` so there
/// are never abrupt arc start/end steps.
func strokeWithLinearGradient(ctx: CGContext,
                              path: CGPath,
                              lineWidth: CGFloat,
                              colors: [NSColor],
                              locations: [CGFloat],
                              start: CGPoint,
                              end: CGPoint) {
    ctx.saveGState()
    ctx.setLineWidth(lineWidth)
    ctx.addPath(path)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let cgColors = colors.map(\.cgColor) as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: cgColors, locations: locations) {
        ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
}

func renderMasterIcon(pixels: Int = 2048) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    nsCtx.shouldAntialias = true
    nsCtx.imageInterpolation = .high
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // 0.0625 = 1/16, which is an exact integer at every icon resolution
    // (1px @ 16, 2px @ 32, 4px @ 64, 8px @ 128, 16px @ 256, 32px @ 512, 64px @ 1024, 128px @ 2048).
    let inset = size * 0.0625
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = body.width * 0.225
    let squircle = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)

    // 1. Base Squircle with Deep Indigo-Midnight Gradient
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    NSGradient(
        colors: [
            NSColor(srgbRed: 0.07, green: 0.09, blue: 0.17, alpha: 1.0),
            NSColor(srgbRed: 0.12, green: 0.11, blue: 0.28, alpha: 1.0),
            NSColor(srgbRed: 0.08, green: 0.09, blue: 0.18, alpha: 1.0),
        ],
        atLocations: [0.0, 0.55, 1.0],
        colorSpace: .sRGB
    )?.draw(in: body, angle: -55)

    // Top-left cyan-azure nebula glow + bottom-right rose-magenta glow (kept well inside the squircle)
    drawRadialGlow(
        ctx: ctx,
        center: CGPoint(x: body.minX + body.width * 0.28, y: body.minY + body.height * 0.74),
        radius: body.width * 0.54,
        color: NSColor(srgbRed: 0.30, green: 0.68, blue: 0.98, alpha: 0.52)
    )
    drawRadialGlow(
        ctx: ctx,
        center: CGPoint(x: body.minX + body.width * 0.74, y: body.minY + body.height * 0.26),
        radius: body.width * 0.52,
        color: NSColor(srgbRed: 0.94, green: 0.42, blue: 0.72, alpha: 0.45)
    )

    let center = CGPoint(x: body.midX, y: body.midY)

    // 2. Outer Liquid Glass Eclipse Ring
    let outerRadius = body.width * 0.335
    let outerRect = NSRect(
        x: center.x - outerRadius,
        y: center.y - outerRadius,
        width: outerRadius * 2,
        height: outerRadius * 2
    )
    let outerCircle = NSBezierPath(ovalIn: outerRect)

    // Soft ambient shadow under outer glass ring
    NSGraphicsContext.saveGraphicsState()
    let ringShadow = NSShadow()
    ringShadow.shadowOffset = NSSize(width: 0, height: -size * 0.026)
    ringShadow.shadowBlurRadius = size * 0.060
    ringShadow.shadowColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.52)
    ringShadow.set()
    NSColor(srgbRed: 0.12, green: 0.16, blue: 0.28, alpha: 0.45).setFill()
    outerCircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Diagonal Liquid Glass fill inside outer ring
    NSGradient(
        colors: [
            NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.34),
            NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.08),
            NSColor(srgbRed: 0.38, green: 0.65, blue: 0.98, alpha: 0.26),
        ],
        atLocations: [0.0, 0.52, 1.0],
        colorSpace: .sRGB
    )?.draw(in: outerCircle, angle: -48)

    // Smooth continuous 135° Fresnel Specular Rim on Outer Ring (no partial arcs!)
    let rimWidth = size * 0.014
    let rimInsetRect = outerRect.insetBy(dx: rimWidth * 0.5, dy: rimWidth * 0.5)
    let rimCGPath = CGPath(ellipseIn: rimInsetRect, transform: nil)
    strokeWithLinearGradient(
        ctx: ctx,
        path: rimCGPath,
        lineWidth: rimWidth,
        colors: [
            NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.85),
            NSColor(srgbRed: 0.68, green: 0.85, blue: 1.0, alpha: 0.38),
            NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.20),
            NSColor(srgbRed: 0.96, green: 0.48, blue: 0.76, alpha: 0.62),
        ],
        locations: [0.0, 0.38, 0.68, 1.0],
        start: CGPoint(x: outerRect.minX, y: outerRect.maxY),
        end: CGPoint(x: outerRect.maxX, y: outerRect.minY)
    )

    // 3. Inner Luminous Core Sphere
    let coreRadius = body.width * 0.155
    let coreRect = NSRect(
        x: center.x - coreRadius,
        y: center.y - coreRadius,
        width: coreRadius * 2,
        height: coreRadius * 2
    )
    let coreCircle = NSBezierPath(ovalIn: coreRect)

    // Electric blue glow behind inner core
    drawRadialGlow(
        ctx: ctx,
        center: CGPoint(x: center.x, y: center.y - size * 0.01),
        radius: coreRadius * 1.85,
        color: NSColor(srgbRed: 0.22, green: 0.56, blue: 1.0, alpha: 0.72)
    )

    NSGradient(
        colors: [
            NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            NSColor(srgbRed: 0.74, green: 0.88, blue: 1.0, alpha: 1.0),
            NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1.0),
        ],
        atLocations: [0.0, 0.45, 1.0],
        colorSpace: .sRGB
    )?.draw(
        in: coreCircle,
        relativeCenterPosition: NSPoint(x: -0.28, y: 0.30)
    )

    // 4. Orbiting Rose-Pink Satellite Dot at upper-right
    let satRadius = body.width * 0.056
    let satAngle = CGFloat.pi * 0.23 // ~41 degrees (upper right)
    let satDist = outerRadius * 0.68
    let satCenter = CGPoint(
        x: center.x + cos(satAngle) * satDist,
        y: center.y + sin(satAngle) * satDist
    )
    drawRadialGlow(
        ctx: ctx,
        center: satCenter,
        radius: satRadius * 2.4,
        color: NSColor(srgbRed: 0.96, green: 0.44, blue: 0.72, alpha: 0.85)
    )
    let satRect = NSRect(
        x: satCenter.x - satRadius,
        y: satCenter.y - satRadius,
        width: satRadius * 2,
        height: satRadius * 2
    )
    let satPath = NSBezierPath(ovalIn: satRect)
    NSGradient(
        colors: [
            NSColor(srgbRed: 1.0, green: 0.88, blue: 0.95, alpha: 1.0),
            NSColor(srgbRed: 0.96, green: 0.44, blue: 0.72, alpha: 1.0),
            NSColor(srgbRed: 0.82, green: 0.22, blue: 0.58, alpha: 1.0),
        ],
        atLocations: [0.0, 0.48, 1.0],
        colorSpace: .sRGB
    )?.draw(in: satPath, relativeCenterPosition: NSPoint(x: -0.25, y: 0.28))

    // 5. Soft Inner Cushion Vignette around the squircle edge (darkens the outer
    // 1-2% perimeter slightly so the squircle boundary never has a bright fringe
    // against dark backgrounds)
    let vignetteWidth = size * 0.018
    let vignetteRect = body.insetBy(dx: vignetteWidth * 0.4, dy: vignetteWidth * 0.4)
    let vignettePath = CGPath(
        roundedRect: vignetteRect,
        cornerWidth: cornerRadius - vignetteWidth * 0.4,
        cornerHeight: cornerRadius - vignetteWidth * 0.4,
        transform: nil
    )
    ctx.saveGState()
    ctx.setLineWidth(vignetteWidth)
    ctx.addPath(vignettePath)
    ctx.setStrokeColor(NSColor(srgbRed: 0.04, green: 0.05, blue: 0.12, alpha: 0.42).cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func downsample(master: NSBitmapImageRep, to pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    nsCtx.shouldAntialias = true
    nsCtx.imageInterpolation = .high
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let image = NSImage(size: master.size)
    image.addRepresentation(master)
    image.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let masterRep = renderMasterIcon(pixels: 2048)

let iconset = outputDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (points, scale) in variants {
    let rep = downsample(master: masterRep, to: points * scale)
    let suffix = scale == 1 ? "" : "@2x"
    let url = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path,
                     "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()

try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
