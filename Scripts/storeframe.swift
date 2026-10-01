import AppKit
import CoreGraphics
import Foundation

// One App Store screenshot: a real capture of the app, scaled down onto the
// stage colour with a short headline above it. The headline sits in its own
// band so it can never cover the note, the cents or the control it explains,
// and the capture is only ever scaled uniformly — never cropped or stretched
// into another device's shape.
//
//   swift Scripts/storeframe.swift <capture.png> <out.png> <width> <height> "Headline" "Supporting line"

let args = CommandLine.arguments
guard args.count == 7, let W = Double(args[3]), let H = Double(args[4]) else {
    FileHandle.standardError.write("usage: storeframe.swift capture.png out.png width height headline subline\n".data(using: .utf8)!)
    exit(2)
}
let (inPath, outPath, headline, subline) = (args[1], args[2], args[5], args[6])

guard let source = NSImage(contentsOfFile: inPath),
      let capture = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(inPath)\n".data(using: .utf8)!)
    exit(1)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
// Opaque: App Store Connect rejects screenshots with an alpha channel.
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.interpolationQuality = .high

// Theme.stage → Theme.stageDeep, the app's own ground.
let ground = CGGradient(colorsSpace: cs, colors: [
    CGColor(srgbRed: 0x0A / 255, green: 0x0C / 255, blue: 0x0C / 255, alpha: 1),
    CGColor(srgbRed: 0x05 / 255, green: 0x06 / 255, blue: 0x07 / 255, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// Type is sized from the short side, so an iPad frame does not get a banner.
let short = min(W, H)
let landscape = W > H
let margin = short * 0.075

func rounded(_ size: Double, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
}

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
paragraph.lineBreakMode = .byWordWrapping

// Theme.trueTone and the new Theme.muted, so the frame reads as the app.
let headAttrs: [NSAttributedString.Key: Any] = [
    .font: rounded(short * 0.075, .semibold),
    .foregroundColor: NSColor(srgbRed: 0xEA / 255, green: 0xF6 / 255, blue: 0xF2 / 255, alpha: 1),
    .paragraphStyle: paragraph,
]
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: rounded(short * 0.038, .regular),
    .foregroundColor: NSColor(white: 1, alpha: 0.62),
    .paragraphStyle: paragraph,
]

let textWidth = W - margin * 2
let head = NSAttributedString(string: headline, attributes: headAttrs)
let sub = NSAttributedString(string: subline, attributes: subAttrs)
let headSize = head.boundingRect(with: NSSize(width: textWidth, height: H),
                                 options: [.usesLineFragmentOrigin, .usesFontLeading]).size
let subSize = sub.boundingRect(with: NSSize(width: textWidth, height: H),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).size
let gap = short * 0.018
let top = margin * (landscape ? 0.6 : 1.2)
let band = top + headSize.height + gap + subSize.height + margin * 0.7

// CoreGraphics is bottom-up; AppKit text drawing goes through a flipped context.
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ns
head.draw(with: NSRect(x: margin, y: H - top - headSize.height, width: textWidth, height: headSize.height),
          options: [.usesLineFragmentOrigin, .usesFontLeading])
sub.draw(with: NSRect(x: margin, y: H - top - headSize.height - gap - subSize.height,
                      width: textWidth, height: subSize.height),
         options: [.usesLineFragmentOrigin, .usesFontLeading])
NSGraphicsContext.restoreGraphicsState()

// The capture: as large as fits under the band, aspect preserved.
let cw = Double(capture.width), ch = Double(capture.height)
let available = CGSize(width: W - margin * 2, height: H - band - margin * 0.6)
let scale = min(available.width / cw, available.height / ch)
let size = CGSize(width: cw * scale, height: ch * scale)
let rect = CGRect(x: (W - size.width) / 2, y: margin * 0.6 + (available.height - size.height) / 2,
                  width: size.width, height: size.height)
let radius = min(size.width, size.height) * 0.075
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(path)
ctx.clip()
ctx.draw(capture, in: rect)
ctx.restoreGState()
// Theme.hairline, so the capture's own black does not dissolve into the ground.
ctx.addPath(path)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
ctx.setLineWidth(max(2, short * 0.0018))
ctx.strokePath()

let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("\(outPath) \(Int(W))x\(Int(H))")
