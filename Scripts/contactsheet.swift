import AppKit
import Foundation

// A row of images at one height, each captioned with its filename, for
// reviewing a screenshot set at roughly the size a phone shows it.
//
//   swift Scripts/contactsheet.swift <out.png> <tile height px> "Title" a.png b.png ...

let args = CommandLine.arguments
guard args.count >= 5, let tileHeight = Double(args[2]) else {
    FileHandle.standardError.write("usage: contactsheet.swift out.png height title images...\n".data(using: .utf8)!)
    exit(2)
}
let title = args[3]
let paths = Array(args.dropFirst(4))
let images = paths.map { path -> CGImage in
    guard let image = NSImage(contentsOfFile: path)?
        .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return image
}

let gap = 24.0, pad = 32.0, caption = 34.0, header = 64.0
let widths = images.map { tileHeight * Double($0.width) / Double($0.height) }
let W = pad * 2 + widths.reduce(0, +) + gap * Double(images.count - 1)
let H = pad + header + tileHeight + caption + pad

let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white,
]
NSAttributedString(string: title, attributes: titleAttrs)
    .draw(at: NSPoint(x: pad, y: H - pad - 38))
let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular),
    .foregroundColor: NSColor(white: 0.75, alpha: 1),
]
var x = pad
for (index, image) in images.enumerated() {
    ctx.draw(image, in: CGRect(x: x, y: pad + caption, width: widths[index], height: tileHeight))
    // Clipped to the tile, so long names do not run into the next one.
    let name = (paths[index] as NSString).lastPathComponent
    NSAttributedString(string: String(name.prefix(Int(widths[index] / 10))), attributes: labelAttrs)
        .draw(at: NSPoint(x: x, y: pad + 6))
    x += widths[index] + gap
}
NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
print("\(args[1]) \(Int(W))x\(Int(H))")
