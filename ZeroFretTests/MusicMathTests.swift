import XCTest

final class MusicMathTests: XCTestCase {
    /// Spec §4 table, at A = 440.
    func testStandardTuningFrequencies() {
        let expected: [(midi: Int, hz: Double)] = [
            (40, 82.4069), (45, 110.0000), (50, 146.8324),
            (55, 195.9977), (59, 246.9417), (64, 329.6276),
        ]
        for (midi, hz) in expected {
            let actual = MusicMath.frequency(midi: Double(midi), referenceA: 440)
            XCTAssertEqual(actual, hz, accuracy: 0.0005, "MIDI \(midi)")
        }
    }

    func testExtendedRangeReferences() {
        // §4: bass low B = 23, 7-string low B = 35, 8-string F# = 30.
        XCTAssertEqual(MusicMath.frequency(midi: 23, referenceA: 440), 30.8677, accuracy: 0.001)
        XCTAssertEqual(MusicMath.frequency(midi: 35, referenceA: 440), 61.7354, accuracy: 0.001)
        XCTAssertEqual(MusicMath.frequency(midi: 30, referenceA: 440), 46.2493, accuracy: 0.001)
    }

    func testReferencePitchMovesEveryTarget() {
        // The whole reason targets are MIDI numbers: A=442 must move low E too.
        let at440 = MusicMath.frequency(midi: 40, referenceA: 440)
        let at442 = MusicMath.frequency(midi: 40, referenceA: 442)
        XCTAssertEqual(MusicMath.cents(measured: at442, target: at440), 7.85, accuracy: 0.02)
    }

    /// Acceptance test 4: 440.0 Hz measured against an A=442 reference.
    func testAcceptance4_440AgainstReference442() {
        let target = MusicMath.frequency(midi: 69, referenceA: 442)
        XCTAssertEqual(target, 442.0, accuracy: 1e-9)
        let cents = MusicMath.cents(measured: 440.0, target: target)
        XCTAssertEqual(cents, -7.9, accuracy: 0.05)
    }

    func testNoteLabels() {
        XCTAssertEqual(MusicMath.label(midi: 40), "E2")
        XCTAssertEqual(MusicMath.label(midi: 64), "E4")
        XCTAssertEqual(MusicMath.label(midi: 69), "A4")
        XCTAssertEqual(MusicMath.label(midi: 23), "B0")
        XCTAssertEqual(MusicMath.label(midi: 30), "F♯1")
        XCTAssertEqual(MusicMath.label(midi: 28), "E1")
    }

    func testMidiRoundTrip() {
        for midi in 20...90 {
            let hz = MusicMath.frequency(midi: Double(midi), referenceA: 440)
            XCTAssertEqual(MusicMath.midi(frequency: hz, referenceA: 440),
                           Double(midi), accuracy: 1e-9)
        }
    }

    func testBeatFrequency() {
        XCTAssertEqual(MusicMath.beatHz(measured: 82.0, target: 82.4069),
                       0.4069, accuracy: 1e-6)
    }

    /// §3 window table, expressed as the rule in `Tuning.windowSize`.
    func testWindowSelection() {
        XCTAssertEqual(TuningLibrary.standard.windowSize, 4096)
        XCTAssertEqual(TuningLibrary.standard.hopSize, 1024)
        XCTAssertEqual(TuningLibrary.sevenString.windowSize, 4096)
        XCTAssertEqual(TuningLibrary.eightString.windowSize, 8192)
        XCTAssertEqual(TuningLibrary.bassFour.windowSize, 8192)
        XCTAssertEqual(TuningLibrary.bassFive.windowSize, 8192)
        XCTAssertEqual(TuningLibrary.bassFive.hopSize, 2048)
    }

    func testCentsTextIsFixedWidth() {
        var state = DisplayState()
        state.hasPitch = true
        // §6: the field is sized to −00.0¢ and updates ~47x/s. Any width change
        // makes the whole block shimmer.
        for cents in stride(from: -120.0, through: 120.0, by: 0.7) {
            state.cents = cents
            XCTAssertEqual(state.centsText.count, 5, "\(cents) -> \(state.centsText)")
        }
        state.cents = 0
        XCTAssertEqual(state.centsText, "+00.0")
        state.cents = -0.04
        XCTAssertEqual(state.centsText, "−00.0")
        // 12.35 is not exactly representable, so %.1f gives 12.3. Pick a value
        // off the rounding boundary rather than encoding a float artefact.
        state.cents = -12.36
        XCTAssertEqual(state.centsText, "−12.4")
        state.cents = 99.94
        XCTAssertEqual(state.centsText, "+99.9", "must clamp rather than widen")
        state.cents = -450.0
        XCTAssertEqual(state.centsText, "−99.9")
        state.cents = 7.0
        XCTAssertEqual(state.centsText, "+07.0")
        // Blank state keeps the same glyph count.
        state.hasPitch = false
        XCTAssertEqual(state.centsText.count, 5)
    }
}
