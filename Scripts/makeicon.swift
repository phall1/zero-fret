import AppKit
import CoreGraphics
import Foundation

// The icon is a frame of the app, not a picture of one: the curve is exactly
// sin(πt)·sin(2πt), the standing wave StringCanvas draws, pinned at both ends.
// Three variants, because iOS 18 asks for them and a home screen that has been
// set to dark or tinted is not a place to be the one icon that ignores it.

let S: CGFloat = 1024

enum Variant { case light, dark, tinted }

func draw(_ variant: Variant, to url: URL) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // Background. The tinted variant must be transparent: the system supplies
    // the ground and derives the tint from luminance alone.
    if variant != .tinted {
        let top: CGFloat = variant == .dark ? 0.035 : 0.055
        let bottom: CGFloat = variant == .dark ? 0.010 : 0.020
        let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: top, green: top + 0.008, blue: top + 0.008, alpha: 1),
            CGColor(red: bottom, green: bottom + 0.004, blue: bottom + 0.006, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S),
                               end: CGPoint(x: 0, y: 0), options: [])
    }

    // The icon is the app's own answer, not a picture of its subject: a string
    // in tune is dead straight and glowing, and that is the one image this app
    // makes that no other audio app does. A wiggly line reads as "waveform" and
    // every audio app on the home screen already has one.
    //
    // Behind it, very faintly, the sweep it has just settled out of — so the
    // icon carries the whole idea: it was moving, and now it is not.
    let inset: CGFloat = 132
    let midY = S / 2
    let left = inset, right = S - inset
    let stroke: CGFloat = 44

    // Zero Fret's true tone, #EAF6F2. Tinted renders flat white so the system's
    // luminance mapping has the full range to work with.
    let core = variant == .tinted
        ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        : CGColor(red: 0xEA / 255, green: 0xF6 / 255, blue: 0xF2 / 255, alpha: 1)

    if variant != .tinted {
        // The settled-out-of sweep: the envelope of sin(πt)·sin(2πt), pinched to
        // nothing at the ends and at the centre node.
        let amplitude: CGFloat = 178
        let samples = 220
        let env = CGMutablePath()
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let x = left + t * (right - left)
            let y = midY - amplitude * abs(sin(.pi * t) * sin(2 * .pi * t))
            if i == 0 { env.move(to: CGPoint(x: x, y: y)) } else { env.addLine(to: CGPoint(x: x, y: y)) }
        }
        for i in stride(from: samples, through: 0, by: -1) {
            let t = CGFloat(i) / CGFloat(samples)
            let x = left + t * (right - left)
            env.addLine(to: CGPoint(x: x, y: midY + amplitude * abs(sin(.pi * t) * sin(2 * .pi * t))))
        }
        env.closeSubpath()
        ctx.setFillColor(core.copy(alpha: 0.085)!)
        ctx.addPath(env)
        ctx.fillPath()
    }

    let path = CGMutablePath()
    path.move(to: CGPoint(x: left, y: midY))
    path.addLine(to: CGPoint(x: right, y: midY))

    if variant != .tinted {
        // Glow built up in passes rather than one shadow — a wide soft halo plus
        // a tight bright one, which is what a lit filament does and what a single
        // blur radius cannot express.
        for (radius, alpha) in [(CGFloat(130), CGFloat(0.34)), (60, 0.42), (24, 0.55)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: radius, color: core.copy(alpha: alpha))
            ctx.setStrokeColor(core.copy(alpha: 0.92)!)
            ctx.setLineWidth(stroke)
            ctx.setLineCap(.round)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    ctx.setStrokeColor(core)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.addPath(path)
    ctx.strokePath()

    // Nut and bridge: the two fixed points the whole metaphor hangs on, and what
    // stops a horizontal bar reading as a redaction.
    for x in [left, right] {
        ctx.setFillColor(core)
        ctx.fillEllipse(in: CGRect(x: x - stroke * 0.92, y: midY - stroke * 0.92,
                                   width: stroke * 1.84, height: stroke * 1.84))
    }

    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
draw(.light, to: out.appendingPathComponent("AppIcon-1024.png"))
draw(.dark, to: out.appendingPathComponent("AppIcon-1024-dark.png"))
draw(.tinted, to: out.appendingPathComponent("AppIcon-1024-tinted.png"))
print("wrote three variants")
