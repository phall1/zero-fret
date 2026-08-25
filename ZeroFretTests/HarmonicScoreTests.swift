import Accelerate
import XCTest

final class HarmonicScoreTests: XCTestCase {
    private let fs = 48000.0
    private let std = TuningLibrary.standard

    /// Runs one window through the detector so the scorer has a spectrum, then
    /// scores the tuning's targets.
    private func detect(_ signal: [Float]) -> HarmonicScorer.Detection? {
        let detector = PitchDetector(sampleRate: fs, windowSize: 4096)
        let filter = Biquad(sampleRate: fs)
        var history = [Float](repeating: 0, count: 4096)
        var offset = 0, filled = 0
        var last: HarmonicScorer.Detection?
        while offset + 1024 <= signal.count {
            var block = Array(signal[offset..<(offset + 1024)])
            block.withUnsafeMutableBufferPointer { filter.process($0.baseAddress!, count: 1024) }
            offset += 1024
            history.replaceSubrange(0..<3072, with: history[1024..<4096])
            history.replaceSubrange(3072..<4096, with: block)
            filled = min(filled + 1024, 4096)
            guard filled >= 4096 else { continue }
            _ = history.withUnsafeBufferPointer { detector.process($0.baseAddress!) }
            last = HarmonicScorer(detector: detector).detect(in: std, referenceA: 440)
        }
        return last
    }

    private func note(_ midi: Int, partials: [Double]) -> [Float] {
        Harness.tone(fundamental: MusicMath.frequency(midi: Double(midi), referenceA: 440),
                     amplitudes: partials, sampleRate: fs, seconds: 0.6)
    }

    func testEachStringIsIdentified() {
        let cases: [(Int, Int, [Double])] = [
            (40, 0, [1.0, 0.75, 0.55, 0.40, 0.25]),
            (45, 1, [1.0, 0.70, 0.50, 0.30]),
            (50, 2, [1.0, 0.70, 0.50, 0.30]),
            (55, 3, [1.0, 0.65, 0.45]),
            (59, 4, [1.0, 0.60, 0.40]),
            (64, 5, [1.0, 0.60, 0.35]),
        ]
        for (midi, index, partials) in cases {
            guard let d = detect(note(midi, partials: partials)) else {
                return XCTFail("no detection for MIDI \(midi)")
            }
            XCTAssertEqual(d.stringIndex, index, "MIDI \(midi) named string \(d.stringIndex)")
        }
    }

    func testHighStringIsNotMistakenForItsOwnSubharmonic() {
        // E4 is the fourth harmonic of E2, so the E2 hypothesis contains every
        // partial of an E4 note and sums extra ones on top. Coverage alone picks
        // E2 every time — measured 184 frames out of 184 before the density term.
        guard let d = detect(note(64, partials: [1.0, 0.6, 0.35])) else {
            return XCTFail("no detection")
        }
        XCTAssertEqual(d.stringIndex, 5, "E4 must not be reported as E2")
    }

    func testStringIsIdentifiedAcrossTheWholeAcceptanceWindow() {
        // The scorer's job is "which string", not "how far off". A string flat
        // or sharp by anything inside §4's 60-cent window must still be named
        // correctly — the deviation itself is measured by the NSDF, which reads
        // it to under a cent, whereas harmonic energy is a broad function of
        // candidate frequency whose argmax is only good to a few tens of cents.
        for cents in [-55.0, -40.0, -18.0, 0.0, 22.0, 45.0, 55.0] {
            let target = MusicMath.frequency(midi: 45, referenceA: 440)
            let sig = Harness.tone(fundamental: target * pow(2, cents / 1200),
                                   amplitudes: [1.0, 0.7, 0.5, 0.3],
                                   sampleRate: fs, seconds: 0.6)
            guard let d = detect(sig) else { return XCTFail("no detection at \(cents)¢") }
            XCTAssertEqual(d.stringIndex, 1, "A2 detuned \(cents)¢ named string \(d.stringIndex)")
        }
    }

    func testAdjacentStringsAreNotConfused() {
        // The failure this whole mechanism exists to prevent.
        for (midi, expected) in [(40, 0), (45, 1), (50, 2), (55, 3), (59, 4), (64, 5)] {
            // Detune far enough to be ambiguous under a nearest-cents rule, but
            // still unambiguously this string.
            let target = MusicMath.frequency(midi: Double(midi), referenceA: 440)
            let sig = Harness.tone(fundamental: target * pow(2, 50.0 / 1200),
                                   amplitudes: [1.0, 0.7, 0.5, 0.3],
                                   sampleRate: fs, seconds: 0.6)
            guard let d = detect(sig) else { return XCTFail("no detection for MIDI \(midi)") }
            XCTAssertEqual(d.stringIndex, expected,
                           "MIDI \(midi) sharp by 50¢ named string \(d.stringIndex)")
        }
    }

    func testARealNoteStandsOutFromNonTargets() {
        guard let d = detect(note(40, partials: [1.0, 0.75, 0.55, 0.40, 0.25])) else {
            return XCTFail("no detection")
        }
        XCTAssertGreaterThan(d.contrast, HarmonicScorer.minimumContrast,
                             "a plucked string should clear the contrast bar")
    }

    func testBroadbandNoiseDoesNotStandOut() {
        // Contrast is the statistic that rejects this cleanly: noise raises every
        // hypothesis about equally, so nothing stands out.
        let noise = Harness.addNoise([Float](repeating: 0, count: Int(fs * 0.6)),
                                     level: 0.15, seed: 4242)
        guard let d = detect(noise) else { return XCTFail("expected a scored result") }
        XCTAssertLessThan(d.contrast, HarmonicScorer.minimumContrast,
                          "noise scored contrast \(d.contrast)")
    }

    func testScoringFollowsTheReferencePitch() {
        // At A=442 every target moves, so a note at the A=440 frequency should
        // read as detuned rather than as a different string.
        let detector = PitchDetector(sampleRate: fs, windowSize: 4096)
        let filter = Biquad(sampleRate: fs)
        let sig = Harness.tone(fundamental: MusicMath.frequency(midi: 45, referenceA: 440),
                               amplitudes: [1.0, 0.7, 0.5], sampleRate: fs, seconds: 0.6)
        var history = [Float](repeating: 0, count: 4096)
        var offset = 0, filled = 0
        while offset + 1024 <= sig.count {
            var block = Array(sig[offset..<(offset + 1024)])
            block.withUnsafeMutableBufferPointer { filter.process($0.baseAddress!, count: 1024) }
            offset += 1024
            history.replaceSubrange(0..<3072, with: history[1024..<4096])
            history.replaceSubrange(3072..<4096, with: block)
            filled = min(filled + 1024, 4096)
        }
        _ = history.withUnsafeBufferPointer { detector.process($0.baseAddress!) }
        let scorer = HarmonicScorer(detector: detector)
        guard let d = scorer.detect(in: std, referenceA: 442) else { return XCTFail("no detection") }
        XCTAssertEqual(d.stringIndex, 1)
        // 440 against a 442 reference is about -7.9 cents.
        XCTAssertLessThan(d.score.cents, 0)
    }
}
