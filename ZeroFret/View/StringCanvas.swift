//  StringCanvas.swift
//  Zero Fret
//
//  Spec §6, "The string" — the whole app in one shape.
//
//      envelope(x) = sin(π · x)     pins both ends
//      shape(x)    = sin(2π · x)    one node at the centre
//      amplitude   = clamp(|cents| / 45, 0, 1) · maxAmp
//      y(x)        = midY + amplitude · envelope(x) · shape(x) · sin(phase)
//
//  `phase` arrives already integrated from the display link. Nothing in this
//  file may compute it from a timestamp.
//
//  What is drawn, and why it is drawn that way
//
//  A string vibrating faster than the eye can follow does not read as a line in
//  a position. It reads as the blurred lens of everywhere it has just been —
//  the envelope. A slow one resolves back into a line you can actually watch.
//
//  Here the wobble rate is the *beat frequency* between the note and its
//  target, so that perceptual fact lands exactly on the meaning: a long way out
//  beats fast and smears into a shape, and as it comes into tune the beat slows,
//  the smear resolves, and at zero the string simply stops. Blur is the error.
//  Nothing has to explain that, and there is no legend to learn — it is how
//  every string the player has ever watched already behaves.
//
//  So three layers, in the order the eye assembles them:
//    1. the envelope, the swept region, strongest when the beat is fastest
//    2. persistence, a few positions the string has just left
//    3. the string itself, bright and exact
//
//  and, when it arrives, a bloom that fades to a steady glow.

import SwiftUI

struct StringCanvas: View {
    /// §6: 64 sample points. A polyline this short at 120 Hz is not a load, so
    /// Metal stays an optimisation rather than a requirement.
    private static let samples = 64
    /// §6: maxAmp, scaled up from the spec's 32 — the string is the display, not
    /// an ornament under it.
    private static let maxAmplitude: CGFloat = 46
    /// §6: full deflection at 45¢ out.
    private static let fullScaleCents: Double = 45
    /// Beat rate at which persistence is at full strength. Above roughly this
    /// the eye has genuinely stopped resolving individual sweeps.
    private static let fullBlurBeatHz: Double = 9
    /// How many positions the string has just left are kept.
    private static let ghosts = 3
    /// Phase separation between them, in radians.
    private static let ghostPhaseStep: Double = 0.42

    let cents: Double
    /// Beat frequency against the target, already clamped for display. Drives
    /// how much the sweep smears; it is the same number that drives the wobble,
    /// so the two can never disagree.
    let beatHz: Double
    /// Read at draw time rather than passed as a value: phase moves every frame
    /// and putting it in the observable state would invalidate the whole view
    /// tree at 120 Hz. `TimelineView(.animation)` is already redrawing at display
    /// rate, so reading it here costs nothing.
    let wobble: WobblePhase
    let hasPitch: Bool
    let inTune: Bool
    let color: Color
    /// 0 for the thinnest string in the tuning, 1 for the thickest. A wound low
    /// E really is several times the diameter of a plain high E, and carrying
    /// that through means the six strings do not all look like the same string.
    var gauge: Double = 0.5
    /// 1 on the frame the note arrives in tune, decaying to 0. Drives the bloom.
    var arrival: Double = 0
    /// When true the string holds a static deflection instead of oscillating.
    /// The amplitude still says how far out the note is, so no information is
    /// lost — only the motion.
    var reduceMotion: Bool = false

    private var amplitude: CGFloat {
        Self.maxAmplitude * CGFloat(min(abs(cents) / Self.fullScaleCents, 1))
    }

    /// How far the sweep has smeared, 0…1.
    private var blur: Double {
        guard hasPitch, !reduceMotion else { return 0 }
        return min(beatHz / Self.fullBlurBeatHz, 1)
    }

    private var lineWidth: CGFloat { 1.9 + 2.3 * CGFloat(gauge) }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                // Referenced so the draw closure cannot be elided: everything
                // else it reads is unchanged between frames.
                _ = timeline.date
                let midY = size.height / 2

                // Reduce Motion pins the string at full deflection rather than
                // sweeping through it. Still legible, still quantitative.
                let swing = reduceMotion ? 1.0 : sin(wobble.value)

                if hasPitch, amplitude > 0.5, blur > 0.01 {
                    // The swept region. Its opacity is the blur, so a note a
                    // long way out is a soft lens and a nearly-tuned one is
                    // almost entirely the line itself.
                    context.fill(envelopePath(in: size, midY: midY),
                                 with: .color(color.opacity(0.13 * blur)))
                }

                if hasPitch, !reduceMotion, blur > 0.01 {
                    // Positions the string has just left. Each is fainter than
                    // the last, which is what gives the sweep a direction.
                    for ghost in 1...Self.ghosts {
                        let phase = wobble.value - Double(ghost) * Self.ghostPhaseStep
                        let fade = (1 - Double(ghost) / Double(Self.ghosts + 1)) * 0.5 * blur
                        context.stroke(
                            stringPath(in: size, midY: midY, swing: sin(phase)),
                            with: .color(color.opacity(fade)),
                            style: StrokeStyle(lineWidth: lineWidth * 0.8, lineCap: .round))
                    }
                }

                let path = stringPath(in: size, midY: midY, swing: swing)

                if hasPitch, inTune {
                    // §6: the true state is the one that glows. The bloom on
                    // arrival is the same glow, briefly much larger — a note
                    // landing should feel like an event, not a state change.
                    // The filter goes on the *layer*, not on `context` — adding
                    // it to the outer context would blur the core stroke below
                    // as well, and the string would read as permanently soft.
                    let bloom = 11 + 26 * arrival
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: bloom))
                        layer.stroke(path,
                                     with: .color(color.opacity(0.85)),
                                     style: StrokeStyle(lineWidth: 3 + 3 * arrival,
                                                        lineCap: .round))
                    }
                }

                context.stroke(path,
                               with: .color(hasPitch ? color : color.opacity(0.22)),
                               style: StrokeStyle(lineWidth: hasPitch ? lineWidth : 1.4,
                                                  lineCap: .round,
                                                  lineJoin: .round))

                // Nut and bridge: the two pinned ends, so the string reads as
                // stretched rather than as a floating squiggle.
                let capRadius: CGFloat = hasPitch ? 3 + 1.5 * CGFloat(arrival) : 2.5
                for x in [CGFloat(0), size.width] {
                    let cap = Path(ellipseIn: CGRect(x: x - capRadius, y: midY - capRadius,
                                                     width: capRadius * 2,
                                                     height: capRadius * 2))
                    context.fill(cap, with: .color(color.opacity(hasPitch ? 0.9 : 0.3)))
                }
            }
        }
        .frame(height: Self.maxAmplitude * 2 + 28)
        .accessibilityHidden(true)
    }

    /// The string at one instant.
    private func stringPath(in size: CGSize, midY: CGFloat, swing: Double) -> Path {
        var path = Path()
        for index in 0..<Self.samples {
            let t = Double(index) / Double(Self.samples - 1)
            let x = CGFloat(t) * size.width
            let y = midY + amplitude * CGFloat(displacement(t) * swing)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    /// Everywhere the string goes: the outer bound traced left to right, then
    /// its mirror traced back. Pinched to nothing at the ends and at the centre
    /// node, which is what makes it read as a *standing wave* rather than a
    /// blob — the node is the part a player recognises.
    private func envelopePath(in size: CGSize, midY: CGFloat) -> Path {
        var path = Path()
        for index in 0..<Self.samples {
            let t = Double(index) / Double(Self.samples - 1)
            let x = CGFloat(t) * size.width
            let y = midY - amplitude * CGFloat(abs(displacement(t)))
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        for index in stride(from: Self.samples - 1, through: 0, by: -1) {
            let t = Double(index) / Double(Self.samples - 1)
            let x = CGFloat(t) * size.width
            let y = midY + amplitude * CGFloat(abs(displacement(t)))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }

    /// §6's shape: pinned at both ends, one node at the centre.
    private func displacement(_ t: Double) -> Double {
        sin(Double.pi * t) * sin(2 * Double.pi * t)
    }
}
