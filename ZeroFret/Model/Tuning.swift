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

/// One string of a tuning. `index` is 0 for the string nearest the player's
/// face — the lowest-pitched one, except on a re-entrant tuning (see `Tuning`).
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

/// Which section of the tuning sheet a tuning is listed under. The analysis
/// window is not chosen by this — it follows the lowest note (see `windowSize`)
/// so that a custom tuning gets the same rule as a preset.
enum InstrumentFamily: String, Codable, CaseIterable, Identifiable {
    case guitar
    case bass
    case ukulele
    case mandolin
    case banjo
    case orchestral
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guitar: return "Guitar"
        case .bass: return "Bass"
        case .ukulele: return "Ukulele"
        case .mandolin: return "Mandolin"
        case .banjo: return "Banjo"
        case .orchestral: return "Violin & Viola"
        case .custom: return "Custom"
        }
    }
}

struct Tuning: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let family: InstrumentFamily
    /// MIDI numbers in the order the strings sit across the neck, starting
    /// from the one nearest the player's face — the order the chips are drawn
    /// in. That is lowest pitch first for almost everything, but not for a
    /// re-entrant tuning: a ukulele's G4 sits above its C4, and a banjo's short
    /// fifth string is its highest. Nothing may assume this array is sorted.
    let midiNotes: [Int]

    /// The pitch range a string may be set to. B0 (MIDI 23) is the lowest
    /// note the detector is tested against (§9.7); A5 (MIDI 81, 880 Hz) leaves
    /// the fundamental clear of the §3 1 kHz lowpass, which is what the
    /// detector has to see.
    static let midiRange = 23...81
    /// At least two, because the scorer judges a string by how far it stands
    /// out from the *other* strings' neighbourhoods; with one string there is
    /// nothing to stand out from, and a lone low E never locks. Twelve is room
    /// for anything with up to twelve distinct courses; past that the chips
    /// stop being something a thumb can hit. A unison pair belongs in once:
    /// two strings on the same note are one target, and auto-detection always
    /// names the first of them.
    static let stringCountRange = 2...12

    var strings: [TuningString] {
        midiNotes.enumerated().map { TuningString(index: $0.offset, midi: $0.element) }
    }

    /// How heavy a string is drawn, 1 for the lowest-pitched in the set and 0
    /// for the highest. Ranked by pitch rather than position, so a ukulele's
    /// high G is drawn thin even though it sits first.
    func gauge(of index: Int) -> Double {
        guard midiNotes.indices.contains(index) else { return 0.5 }
        let distinct = Array(Set(midiNotes)).sorted()
        guard distinct.count > 1,
              let rank = distinct.firstIndex(of: midiNotes[index]) else { return 0.5 }
        return 1 - Double(rank) / Double(distinct.count - 1)
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

    /// Across the neck, the way players write a tuning down: DADGAD reads
    /// "D A D G A D" and a ukulele "G C E A". Reading it high to low instead
    /// turned DADGAD into "D A G D A D".
    var displaySummary: String {
        strings.map(\.noteName).joined(separator: " ")
    }

    var isCustom: Bool { family == .custom }

    /// A copy with a new identity, for "start a custom tuning from this one".
    func customized(id: String, name: String? = nil) -> Tuning {
        Tuning(id: id, name: name ?? "My \(self.name)", family: .custom, midiNotes: midiNotes)
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

    // Ukulele. Soprano, concert and tenor share a tuning; the standard one is
    // re-entrant, so its first string is G4, not the lowest note.
    static let ukulele = Tuning(id: "ukulele.standard", name: "Ukulele",
                                family: .ukulele, midiNotes: [67, 60, 64, 69])
    static let ukuleleLowG = Tuning(id: "ukulele.lowG", name: "Ukulele Low G",
                                    family: .ukulele, midiNotes: [55, 60, 64, 69])
    static let ukuleleD = Tuning(id: "ukulele.d", name: "Ukulele D (A D F♯ B)",
                                 family: .ukulele, midiNotes: [69, 62, 66, 71])
    static let baritoneUkulele = Tuning(id: "ukulele.baritone", name: "Baritone Ukulele",
                                        family: .ukulele, midiNotes: [50, 55, 59, 64])

    // Mandolin, listed by course: each pair is tuned in unison.
    static let mandolin = Tuning(id: "mandolin.standard", name: "Mandolin",
                                 family: .mandolin, midiNotes: [55, 62, 69, 76])
    static let mandola = Tuning(id: "mandolin.mandola", name: "Mandola",
                                family: .mandolin, midiNotes: [48, 55, 62, 69])

    // Five-string banjo. The short fifth string is the highest note and sits
    // first across the neck, so these are re-entrant too.
    static let banjoOpenG = Tuning(id: "banjo.openG", name: "Banjo Open G",
                                   family: .banjo, midiNotes: [67, 50, 55, 59, 62])
    static let banjoDoubleC = Tuning(id: "banjo.doubleC", name: "Banjo Double C",
                                     family: .banjo, midiNotes: [67, 48, 55, 60, 62])
    static let banjoTenor = Tuning(id: "banjo.tenor", name: "Tenor Banjo",
                                   family: .banjo, midiNotes: [48, 55, 62, 69])

    static let violin = Tuning(id: "orchestral.violin", name: "Violin",
                               family: .orchestral, midiNotes: [55, 62, 69, 76])
    static let viola = Tuning(id: "orchestral.viola", name: "Viola",
                              family: .orchestral, midiNotes: [48, 55, 62, 69])
    // No cello. Its C2 and G2 do not lock in `InstrumentTests`: four strings a
    // fifth apart that low put the scorer's decoys on each other's harmonics,
    // so the played string never stands out far enough to be acquired.

    static let all: [Tuning] = [
        standard, dropD, halfStepDown, fullStepDown, dadgad, openG, openD,
        sevenString, eightString,
        bassFour, bassFive, bassSix,
        ukulele, ukuleleLowG, ukuleleD, baritoneUkulele,
        mandolin, mandola,
        banjoOpenG, banjoDoubleC, banjoTenor,
        violin, viola,
    ]

    static func tuning(id: String) -> Tuning? { all.first { $0.id == id } }
}
