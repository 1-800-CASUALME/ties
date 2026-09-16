#!/usr/bin/env swift
//
//  make-icon.swift — regenerates the Ties app icon.
//
//  Usage:  swift scripts/make-icon.swift
//
//  Draws a 1024×1024 master with AppKit/CoreGraphics (a white-to-light-gray rounded
//  square holding two overlapping circles in a blue→purple gradient with a soft inner
//  shadow), downsamples it with `sips`, and rewrites the AppIcon.appiconset catalogue.
//  No text, so the mark stays legible at 16pt.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry and palette

let master = 1024.0
let inset = 64.0                                  // keeps the mark off the canvas edge
let body = CGRect(x: inset, y: inset, width: master - inset * 2, height: master - inset * 2)
let cornerRadius = body.width * 0.22              // macOS-style squircle-ish corner

let blue = CGColor(srgbRed: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1)
let purple = CGColor(srgbRed: 0x8E / 255, green: 0x5B / 255, blue: 0xF5 / 255, alpha: 1)
let plateTop = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let plateBottom = CGColor(srgbRed: 0xEC / 255, green: 0xEE / 255, blue: 0xF2 / 255, alpha: 1)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor], _ locations: [CGFloat] = [0, 1]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// Paints `path` with an inner shadow: clip to the shape, then cast a shadow from the
/// (invisible) region outside it, which lands just inside the edge.
func innerShadow(_ ctx: CGContext, path: CGPath, offset: CGSize, blur: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let cutout = CGMutablePath()
    cutout.addRect(CGRect(x: -master, y: -master, width: master * 3, height: master * 3))
    cutout.addPath(path)
    ctx.setShadow(offset: offset, blur: blur,
                  color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(cutout)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

// MARK: - Draw the master

guard let ctx = CGContext(data: nil, width: Int(master), height: Int(master),
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("could not create the bitmap context")
}
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// 1. The plate: white → light gray, top to bottom.
let plate = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                   transform: nil)
ctx.saveGState()
ctx.addPath(plate)
ctx.clip()
ctx.drawLinearGradient(gradient([plateTop, plateBottom]),
                       start: CGPoint(x: body.midX, y: body.maxY),
                       end: CGPoint(x: body.midX, y: body.minY),
                       options: [])
ctx.restoreGState()

// A hairline edge so the plate reads against a white background.
ctx.saveGState()
ctx.addPath(plate)
ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// 2. Two overlapping circles — the tie.
let r = body.width * 0.245
let dx = r * 0.62
let center = CGPoint(x: body.midX, y: body.midY)
let leftRect = CGRect(x: center.x - dx - r, y: center.y - r, width: r * 2, height: r * 2)
let rightRect = CGRect(x: center.x + dx - r, y: center.y - r, width: r * 2, height: r * 2)
let left = CGPath(ellipseIn: leftRect, transform: nil)
let right = CGPath(ellipseIn: rightRect, transform: nil)

let union = CGMutablePath()
union.addPath(left)
union.addPath(right)
let unionBounds = union.boundingBox

// One gradient across the pair: blue at the top-left, purple at the bottom-right.
ctx.saveGState()
ctx.addPath(union)
ctx.clip()
ctx.drawLinearGradient(gradient([blue, purple]),
                       start: CGPoint(x: unionBounds.minX, y: unionBounds.maxY),
                       end: CGPoint(x: unionBounds.maxX, y: unionBounds.minY),
                       options: [])
ctx.restoreGState()

// 3. The lens where they overlap, lightened so the two circles stay legible.
ctx.saveGState()
ctx.addPath(left)
ctx.clip()
ctx.addPath(right)
ctx.clip()
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
ctx.fill(unionBounds)
ctx.restoreGState()

// 4. Inner shadow on each circle, lit from above.
innerShadow(ctx, path: left, offset: CGSize(width: 0, height: -10), blur: 26, alpha: 0.28)
innerShadow(ctx, path: right, offset: CGSize(width: 0, height: -10), blur: 26, alpha: 0.28)

// MARK: - Write the PNGs

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot
    .appendingPathComponent("Ties/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let image = ctx.makeImage() else { fatalError("could not render the master image") }
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: master, height: master)
guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode the master PNG")
}
let masterURL = outDir.appendingPathComponent("icon_1024.png")
try png.write(to: masterURL)
print("wrote \(masterURL.lastPathComponent)")

func sips(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("sips failed: sips \(arguments.joined(separator: " "))")
    }
}

for size in [16, 32, 64, 128, 256, 512] {
    let url = outDir.appendingPathComponent("icon_\(size).png")
    try sips(["-z", "\(size)", "\(size)", masterURL.path, "--out", url.path])
    print("wrote \(url.lastPathComponent)")
}

// MARK: - Catalogue

/// (size, scale, pixels) for the ten standard macOS app-icon entries.
let entries: [(Int, Int, Int)] = [
    (16, 1, 16), (16, 2, 32),
    (32, 1, 32), (32, 2, 64),
    (128, 1, 128), (128, 2, 256),
    (256, 1, 256), (256, 2, 512),
    (512, 1, 512), (512, 2, 1024),
]
let images = entries.map { size, scale, pixels in
    """
        { "idiom" : "mac", "size" : "\(size)x\(size)", "scale" : "\(scale)x", \
    "filename" : "icon_\(pixels).png" }
    """
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: outDir.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)
print("wrote Contents.json")
