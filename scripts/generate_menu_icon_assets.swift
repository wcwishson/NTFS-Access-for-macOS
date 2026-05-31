import CoreGraphics
import Foundation

enum IconVariant {
    case idle
    case degraded
    case error

    var filename: String {
        switch self {
        case .idle:
            return "MenuBarIdle.pdf"
        case .degraded:
            return "MenuBarDegraded.pdf"
        case .error:
            return "MenuBarError.pdf"
        }
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let destinations: [IconVariant: URL] = [
    .idle: root.appendingPathComponent("App/Assets.xcassets/MenuBarIdle.imageset/MenuBarIdle.pdf"),
    .degraded: root.appendingPathComponent("App/Assets.xcassets/MenuBarDegraded.imageset/MenuBarDegraded.pdf"),
    .error: root.appendingPathComponent("App/Assets.xcassets/MenuBarError.imageset/MenuBarError.pdf")
]

func drawDrive(in context: CGContext) {
    context.setStrokeColor(gray: 0, alpha: 1)
    context.setFillColor(gray: 0, alpha: 1)
    context.setLineWidth(1.4)

    let body = CGRect(x: 2.2, y: 5.4, width: 13.6, height: 8.0)
    let radius: CGFloat = 1.8

    let bodyPath = CGPath(
        roundedRect: body,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
    context.addPath(bodyPath)
    context.strokePath()

    context.move(to: CGPoint(x: 4.2, y: 9.7))
    context.addLine(to: CGPoint(x: 13.8, y: 9.7))
    context.strokePath()
}

func drawStatusDot(in context: CGContext, filled: Bool) {
    let center = CGPoint(x: 13.9, y: 4.0)
    let radius: CGFloat = 1.9

    context.setLineWidth(1.2)
    context.setStrokeColor(gray: 0, alpha: 1)
    context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    context.strokePath()

    if filled {
        context.setFillColor(gray: 0, alpha: 1)
        let fillRadius: CGFloat = 1.05
        context.fillEllipse(in: CGRect(x: center.x - fillRadius, y: center.y - fillRadius, width: fillRadius * 2, height: fillRadius * 2))
    }
}

func drawErrorMark(in context: CGContext) {
    context.setStrokeColor(gray: 0, alpha: 1)
    context.setLineWidth(1.4)
    context.move(to: CGPoint(x: 13.9, y: 5.0))
    context.addLine(to: CGPoint(x: 13.9, y: 2.8))
    context.strokePath()

    context.setFillColor(gray: 0, alpha: 1)
    context.fillEllipse(in: CGRect(x: 13.35, y: 1.7, width: 1.1, height: 1.1))
}

func render(_ variant: IconVariant, to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create CGContext for \(url.path)"])
    }

    context.beginPDFPage(nil)
    drawDrive(in: context)

    switch variant {
    case .idle:
        drawStatusDot(in: context, filled: true)
    case .degraded:
        drawStatusDot(in: context, filled: false)
    case .error:
        drawStatusDot(in: context, filled: false)
        drawErrorMark(in: context)
    }

    context.endPDFPage()
    context.closePDF()
}

for (variant, url) in destinations {
    try render(variant, to: url)
    print("generated \(url.path)")
}

let runtimeResourceDir = root.appendingPathComponent("Sources/NTFSMenuApp/Resources")
for variant in [IconVariant.idle, .degraded, .error] {
    let source = destinations[variant]!
    let destination = runtimeResourceDir.appendingPathComponent(variant.filename)

    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
    print("copied \(destination.path)")
}
