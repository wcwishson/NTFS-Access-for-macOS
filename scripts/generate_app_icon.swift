#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Sources/NTFSMenuApp/Resources/AppIcon.icns")
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ntfsaccess-appicon-\(UUID().uuidString).iconset")

try FileManager.default.createDirectory(
    at: iconset,
    withIntermediateDirectories: true
)

func roundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func makeImage(size: Int) -> NSImage {
    let size = CGFloat(size)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    func s(_ value: CGFloat) -> CGFloat {
        value * size / 1024
    }

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    NSColor(calibratedRed: 0.10, green: 0.37, blue: 0.92, alpha: 1).setFill()
    roundedPath(NSRect(x: s(96), y: s(96), width: s(832), height: s(832)), radius: s(190)).fill()

    NSColor(calibratedRed: 0.34, green: 0.66, blue: 1.0, alpha: 0.38).setFill()
    roundedPath(NSRect(x: s(126), y: s(526), width: s(772), height: s(372)), radius: s(165)).fill()

    let driveRect = NSRect(x: s(210), y: s(334), width: s(604), height: s(330))
    NSColor(calibratedRed: 0.96, green: 0.98, blue: 1.0, alpha: 1).setFill()
    roundedPath(driveRect, radius: s(74)).fill()

    NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.46, alpha: 1).setStroke()
    let driveOutline = roundedPath(driveRect, radius: s(74))
    driveOutline.lineWidth = max(s(30), 1)
    driveOutline.stroke()

    NSColor(calibratedRed: 0.12, green: 0.38, blue: 0.83, alpha: 1).setFill()
    roundedPath(NSRect(x: s(286), y: s(478), width: s(366), height: s(46)), radius: s(20)).fill()

    NSColor(calibratedRed: 0.03, green: 0.16, blue: 0.46, alpha: 0.45).setFill()
    roundedPath(NSRect(x: s(300), y: s(250), width: s(424), height: s(58)), radius: s(28)).fill()

    let badgeRect = NSRect(x: s(646), y: s(610), width: s(194), height: s(194))
    NSColor(calibratedRed: 0.09, green: 0.72, blue: 0.46, alpha: 1).setFill()
    NSBezierPath(ovalIn: badgeRect).fill()
    NSColor(calibratedRed: 0.96, green: 0.98, blue: 1.0, alpha: 1).setStroke()
    let badgeOutline = NSBezierPath(ovalIn: badgeRect)
    badgeOutline.lineWidth = max(s(24), 1)
    badgeOutline.stroke()

    let check = NSBezierPath()
    check.move(to: NSPoint(x: s(704), y: s(708)))
    check.line(to: NSPoint(x: s(754), y: s(662)))
    check.line(to: NSPoint(x: s(786), y: s(754)))
    check.lineWidth = max(s(34), 1)
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor.white.setStroke()
    check.stroke()

    return image
}

func writePNG(size: Int, name: String) throws {
    let image = makeImage(size: size)
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(
            domain: "NTFSAccessIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to render \(name)"]
        )
    }

    try data.write(to: iconset.appendingPathComponent(name))
}

try writePNG(size: 16, name: "icon_16x16.png")
try writePNG(size: 32, name: "icon_16x16@2x.png")
try writePNG(size: 32, name: "icon_32x32.png")
try writePNG(size: 64, name: "icon_32x32@2x.png")
try writePNG(size: 128, name: "icon_128x128.png")
try writePNG(size: 256, name: "icon_128x128@2x.png")
try writePNG(size: 256, name: "icon_256x256.png")
try writePNG(size: 512, name: "icon_256x256@2x.png")
try writePNG(size: 512, name: "icon_512x512.png")
try writePNG(size: 1024, name: "icon_512x512@2x.png")

if FileManager.default.fileExists(atPath: output.path) {
    try FileManager.default.removeItem(at: output)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()

try? FileManager.default.removeItem(at: iconset)

guard process.terminationStatus == 0 else {
    throw NSError(
        domain: "NTFSAccessIcon",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed"]
    )
}

print("Generated \(output.path)")
