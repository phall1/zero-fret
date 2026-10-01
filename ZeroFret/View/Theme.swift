//  Theme.swift
//  Zero Fret
//
//  Spec §6 colour table. Direction, not correctness: flat is warm, sharp is
//  cold, true is near-white and glows. One state change repaints the glyph, the
//  string and the readout in the same frame.
//
//  The palette is deliberately three hues and nothing else. A tuner is read at
//  arm's length, over the top of an instrument, often on a dark stage — the only
//  thing colour is asked to carry here is which way to turn the peg, and any
//  fourth hue competing for attention makes that answer slower to find.

import SwiftUI

enum Theme {
    /// Flat / slack — warm.
    static let flat = Color(red: 0xE0 / 255, green: 0xA2 / 255, blue: 0x4A / 255)
    /// Sharp / tense — cold.
    static let sharp = Color(red: 0x7F / 255, green: 0xC7 / 255, blue: 0xE8 / 255)
    /// True.
    static let trueTone = Color(red: 0xEA / 255, green: 0xF6 / 255, blue: 0xF2 / 255)

    static let stage = Color(red: 0x0A / 255, green: 0x0C / 255, blue: 0x0C / 255)
    /// The bottom of the stage gradient. Barely a shade below `stage`, which is
    /// the point: enough for the surface to have a direction and a horizon,
    /// nowhere near enough to read as a decorative gradient.
    static let stageDeep = Color(red: 0x05 / 255, green: 0x06 / 255, blue: 0x07 / 255)
    static let stageRaised = Color(red: 0x14 / 255, green: 0x17 / 255, blue: 0x17 / 255)
    static let hairline = Color.white.opacity(0.08)
    /// Secondary text: the Hz line, octave numbers, captions. Opaque, so its
    /// contrast does not depend on what happens to be behind it: 7.8:1 on the
    /// stage and 6.5:1 on a chip. It was white at 0.42 — 4.0:1, under WCAG AA's
    /// 4.5:1 for small text, and it read as faint at arm's length. Still under
    /// half of `trueTone`'s contrast, so it stays secondary.
    static let muted = Color(red: 0xA1 / 255, green: 0xA4 / 255, blue: 0xA4 / 255)
    static let faint = Color.white.opacity(0.22)

    static func color(for direction: TuneDirection) -> Color {
        switch direction {
        case .flat: return flat
        case .sharp: return sharp
        case .inTune: return trueTone
        }
    }

    /// The stage itself: a vertical fall from `stage` to `stageDeep`. Flat black
    /// gives the string nothing to sit in front of; a very shallow gradient
    /// gives the eye a horizon without ever announcing itself.
    static var stageGradient: LinearGradient {
        LinearGradient(colors: [stage, stageDeep],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The light the string casts on the stage behind it. Tinted by whichever
    /// direction is showing, so the whole surface warms as a note goes flat and
    /// cools as it goes sharp — read before any digit is, and from further away.
    static func ambientLight(_ color: Color, intensity: Double) -> RadialGradient {
        RadialGradient(colors: [color.opacity(0.16 * intensity),
                                color.opacity(0.05 * intensity),
                                .clear],
                       center: .center, startRadius: 2, endRadius: 340)
    }
}
