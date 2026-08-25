//  StringCanvas.swift
//  Zero Fret
//
//  Spec §6, "The string".
//
//      envelope(x) = sin(π · x)     pins both ends
//      shape(x)    = sin(2π · x)    one node at the centre
//      amplitude   = clamp(|cents| / 45, 0, 1) · maxAmp
//      y(x)        = midY + amplitude · envelope(x) · shape(x) · sin(phase)
//
//  `phase` arrives already integrated from the display link. Nothing in this
//  file may compute it from a timestamp.

import SwiftUI

struct StringCanvas: View {
    /// §6: 64 sample points. A polyline this short at 120 Hz is not a load, so
    /// Metal stays an optimisation rather than a requirement.
    private static let samples = 64
    /// §6: maxAmp.
    private static let maxAmplitude: CGFloat = 32
    /// §6: full deflection at 45¢ out.
    private static let fullScaleCents: Double = 45

    let cents: Double
    /// Read at draw time rather than passed as a value: phase moves every frame
    /// and putting it in the observable state would invalidate the whole view
    /// tree at 120 Hz. `TimelineView(.animation)` is already redrawing at display
    /// rate, so reading it here costs nothing.
    let wobble: WobblePhase
    let hasPitch: Bool
    let inTune: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                // Referenced so the draw closure cannot be elided: everything
                // else it reads is unchanged between frames.
                _ = timeline.date
                let midY = size.height / 2
                let amplitude = Self.maxAmplitude
                    * CGFloat(min(abs(cents) / Self.fullScaleCents, 1))
                let swing = CGFloat(sin(wobble.value))

                var path = Path()
                for index in 0..<Self.samples {
                    let t = Double(index) / Double(Self.samples - 1)
                    let x = CGFloat(t) * size.width
                    let envelope = sin(Double.pi * t)
                    let shape = sin(2 * Double.pi * t)
                    let y = midY + amplitude * CGFloat(envelope * shape) * swing
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                if hasPitch, inTune {
                    // §6: the true state is the one that glows. 11 pt.
                    // The filter goes on the *layer*, not on `context` — adding
                    // it to the outer context would blur the core stroke below
                    // as well, and the string would read as permanently soft.
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 11))
                        layer.stroke(path, with: .color(color.opacity(0.85)),
                                     style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }

                context.stroke(path,
                               with: .color(hasPitch ? color : color.opacity(0.22)),
                               style: StrokeStyle(lineWidth: hasPitch ? 2.5 : 1.5,
                                                  lineCap: .round,
                                                  lineJoin: .round))

                // Nut and bridge: the two pinned ends, so the string reads as
                // stretched rather than as a floating squiggle.
                for x in [CGFloat(0), size.width] {
                    let cap = Path(ellipseIn: CGRect(x: x - 2.5, y: midY - 2.5,
                                                     width: 5, height: 5))
                    context.fill(cap, with: .color(color.opacity(hasPitch ? 0.9 : 0.3)))
                }
            }
        }
        .frame(height: Self.maxAmplitude * 2 + 24)
        .accessibilityHidden(true)
    }
}
