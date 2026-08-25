//  Theme.swift
//  Zero Fret
//
//  Spec §6 colour table. Direction, not correctness: flat is warm, sharp is
//  cold, true is near-white and glows. One state change repaints the glyph, the
//  string and the readout in the same frame.

import SwiftUI

enum Theme {
    /// Flat / slack — warm.
    static let flat = Color(red: 0xE0 / 255, green: 0xA2 / 255, blue: 0x4A / 255)
    /// Sharp / tense — cold.
    static let sharp = Color(red: 0x7F / 255, green: 0xC7 / 255, blue: 0xE8 / 255)
    /// True.
    static let trueTone = Color(red: 0xEA / 255, green: 0xF6 / 255, blue: 0xF2 / 255)

    static let stage = Color(red: 0x0A / 255, green: 0x0C / 255, blue: 0x0C / 255)
    static let stageRaised = Color(red: 0x14 / 255, green: 0x17 / 255, blue: 0x17 / 255)
    static let hairline = Color.white.opacity(0.08)
    static let muted = Color.white.opacity(0.42)
    static let faint = Color.white.opacity(0.22)

    static func color(for direction: TuneDirection) -> Color {
        switch direction {
        case .flat: return flat
        case .sharp: return sharp
        case .inTune: return trueTone
        }
    }
}
