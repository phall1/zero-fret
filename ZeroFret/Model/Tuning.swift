//  Tuning.swift
//  Zero Fret
//
//  Spec §4. Targets are MIDI note numbers. Hz is always derived:
//
//      f(n) = referenceA · 2^((n − 69) / 12)
//
//  Hardcoding 82.41 Hz for low E means the A=442 setting silently does nothing —
//  a bug nobody notices until someone in an orchestra pit complains.

import Foundation

enum MusicMath {
    static let concertA = 440.0

    static func frequency(midi: Double, referenceA: Double) -> Double {
        referenceA * pow(2.0, (midi - 69.0) / 12.0)
    }

    static func midi(frequency: Double, referenceA: Double) -> Double {
        69.0 + 12.0 * log2(frequency / referenceA)
    }

    static func cents(measured: Double, target: Double) -> Double {
        1200.0 * log2(measured / target)
    }

    static func beatHz(measured: Double, target: Double) -> Double {
        abs(measured - target)
    }

    private static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func noteName(midi: Int) -> String {
        sharpNames[((midi % 12) + 12) % 12]
    }

    static func octave(midi: Int) -> Int {
        Int(floor(Double(midi) / 12.0)) - 1
    }

    /// "E2", "F♯1", "A♯3".
    static func label(midi: Int) -> String {
        "\(noteName(midi: midi))\(octave(midi: midi))"
    }
}

/// One string of a tuning. `index` is 0 for the lowest-pitched string.
struct TuningString: Identifiable, Hashable {
    let index: Int
    let midi: Int

    var id: Int { index }
    var noteName: String { MusicMath.noteName(midi: midi) }
    var octave: Int { MusicMath.octave(midi: midi) }
    var label: String { MusicMath.label(midi: midi) }

    func frequency(referenceA: Double) -> Double {
        MusicMath.frequency(midi: Double(midi), referenceA: referenceA)
    }
}

/// Instrument family, which selects the analysis window (§3).
enum InstrumentFamily: String, Codable, CaseIterable, Identifiable {
    case guitar
    case bass

    var id: String { rawValue }
    var title: String { self == .guitar ? "Guitar" : "Bass" }
}

struct Tuning: Identifiable, Hashable {
    let id: String
    let name: String
    let family: InstrumentFamily
    /// MIDI numbers, lowest string first.
    let midiNotes: [Int]

    var strings: [TuningString] {
        midiNotes.enumerated().map { TuningString(index: $0.offset, midi: $0.element) }
    }

    /// §3 window table, expressed as the rule that produces it rather than as a
    /// lookup: anything whose lowest string falls below A1 (55 Hz) needs 8192 to
    /// hold three periods, everything else is fine at 4096 and feels quicker.
    ///
    ///   E2  = 82.41 Hz → 4096  (spec: guitar)
    ///   B1  = 61.74 Hz → 4096  (7-string)
    ///   F♯1 = 46.25 Hz → 8192  (8-string)
    ///   B0  = 30.87 Hz → 8192  (spec: bass)
    var windowSize: Int {
        let lowest = MusicMath.frequency(midi: Double(midiNotes.min() ?? 40),
                                         referenceA: MusicMath.concertA)
        return lowest < 55.0 ? 8192 : 4096
    }

    var hopSize: Int { windowSize / 4 }

    var displaySummary: String {
        strings.reversed().map(\.noteName).joined(separator: " ")
    }
}

enum TuningLibrary {
    // Guitar family. §10 ships "the six strings, one tuning family"; these are
    // the standard-family variants that need no custom-tuning editor.
    static let standard = Tuning(id: "guitar.standard", name: "Standard",
                                 family: .guitar, midiNotes: [40, 45, 50, 55, 59, 64])
    static let dropD = Tuning(id: "guitar.dropD", name: "Drop D",
                              family: .guitar, midiNotes: [38, 45, 50, 55, 59, 64])
    static let halfStepDown = Tuning(id: "guitar.eflat", name: "E♭ Standard",
                                     family: .guitar, midiNotes: [39, 44, 49, 54, 58, 63])
    static let fullStepDown = Tuning(id: "guitar.d", name: "D Standard",
                                     family: .guitar, midiNotes: [38, 43, 48, 53, 57, 62])
    static let dadgad = Tuning(id: "guitar.dadgad", name: "DADGAD",
                               family: .guitar, midiNotes: [38, 45, 50, 55, 57, 62])
    static let openG = Tuning(id: "guitar.openG", name: "Open G",
                              family: .guitar, midiNotes: [38, 43, 50, 55, 59, 62])
    static let openD = Tuning(id: "guitar.openD", name: "Open D",
                              family: .guitar, midiNotes: [38, 45, 50, 54, 57, 62])
    /// 7-string low B is MIDI 35 (§4).
    static let sevenString = Tuning(id: "guitar.seven", name: "7-String",
                                    family: .guitar, midiNotes: [35, 40, 45, 50, 55, 59, 64])
    /// 8-string low F♯ is MIDI 30 (§4).
    static let eightString = Tuning(id: "guitar.eight", name: "8-String",
                                    family: .guitar, midiNotes: [30, 35, 40, 45, 50, 55, 59, 64])

    // Bass family.
    static let bassFour = Tuning(id: "bass.four", name: "Bass 4-String",
                                 family: .bass, midiNotes: [28, 33, 38, 43])
    /// Bass low B is MIDI 23 (§4) — 30.87 Hz, acceptance test 7.
    static let bassFive = Tuning(id: "bass.five", name: "Bass 5-String",
                                 family: .bass, midiNotes: [23, 28, 33, 38, 43])
    static let bassSix = Tuning(id: "bass.six", name: "Bass 6-String",
                                family: .bass, midiNotes: [23, 28, 33, 38, 43, 48])

    static let all: [Tuning] = [
        standard, dropD, halfStepDown, fullStepDown, dadgad, openG, openD,
        sevenString, eightString,
        bassFour, bassFive, bassSix,
    ]

    static func tuning(id: String) -> Tuning? { all.first { $0.id == id } }

    static func grouped() -> [TuningGroup] {
        InstrumentFamily.allCases.map { family in
            TuningGroup(family: family, tunings: all.filter { $0.family == family })
        }
    }
}

struct TuningGroup: Identifiable {
    let family: InstrumentFamily
    let tunings: [Tuning]
    var id: String { family.rawValue }
}
