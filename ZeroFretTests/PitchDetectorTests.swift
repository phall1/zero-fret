import XCTest

final class PitchDetectorTests: XCTestCase {
    private let fs = 48000.0

    private func detect(_ signal: [Float], windowSize: Int = 4096) -> (hz: Double, clarity: Double) {
        let settled = Harness.settled(Harness.run(signal: signal, sampleRate: fs,
                                                  windowSize: windowSize))
        XCTAssertFalse(settled.isEmpty, "detector produced no voiced frames")
        guard !settled.isEmpty else { return (0, 0) }
        let hz = settled.map(\.frequency).sorted()[settled.count / 2]
        let clarity = settled.map(\.clarity).sorted()[settled.count / 2]
        return (hz, clarity)
    }

    func testPureSineIsAccurate() {
        for f in [82.41, 110.0, 146.83, 196.0, 246.94, 329.63, 440.0] {
            let (hz, clarity) = detect(Harness.sine(f, sampleRate: fs, seconds: 0.8))
            XCTAssertEqual(Harness.cents(hz, f), 0, accuracy: 0.5, "\(f) Hz -> \(hz) Hz")
            XCTAssertGreaterThan(clarity, 0.95, "\(f) Hz")
        }
    }

    func testHarmonicRichLowEDoesNotReadAnOctaveHigh() {
        // The classic failure: the global NSDF maximum sits at 2τ.
        let f = 82.4069
        let signal = Harness.tone(fundamental: f,
                                  amplitudes: [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4],
                                  sampleRate: fs, seconds: 1.0)
        let (hz, _) = detect(signal)
        XCTAssertEqual(Harness.cents(hz, f), 0, accuracy: 3.0, "read \(hz) Hz")
    }

    func testMissingFundamentalStillReadsTheFundamental() {
        // A weak fundamental is exactly what an old string on a bright amp does.
        let f = 98.0
        let signal = Harness.tone(fundamental: f,
                                  amplitudes: [0.15, 1.0, 0.85, 0.6],
                                  sampleRate: fs, seconds: 1.0)
        let (hz, _) = detect(signal)
        XCTAssertEqual(Harness.cents(hz, f), 0, accuracy: 5.0, "read \(hz) Hz")
    }

    func testSubharmonicIsNotSelected() {
        // k below 0.8 causes this; k = 0.9 must not.
        let f = 329.6276
        let signal = Harness.tone(fundamental: f, amplitudes: [1.0, 0.5, 0.25],
                                  sampleRate: fs, seconds: 0.8)
        let (hz, _) = detect(signal)
        XCTAssertGreaterThan(hz, f * 0.9)
        XCTAssertLessThan(hz, f * 1.1)
    }

    func testSilenceProducesNoPitch() {
        let silence = [Float](repeating: 0, count: Int(fs * 0.5))
        let results = Harness.run(signal: silence, sampleRate: fs, windowSize: 4096)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { !$0.hasPitch })
    }

    func testWhiteNoiseProducesNoConfidentPitch() {
        let noise = Harness.addNoise([Float](repeating: 0, count: Int(fs * 1.0)), level: 0.2)
        let results = Harness.run(signal: noise, sampleRate: fs, windowSize: 4096)
        let voiced = results.filter(\.hasPitch)
        // Filtered noise is narrowband and can occasionally look periodic; the
        // clarity gate must still keep it well under half the frames.
        XCTAssertLessThan(Double(voiced.count) / Double(results.count), 0.5,
                          "noise was voiced \(voiced.count)/\(results.count)")
    }

    func testNoisyStringStillLocks() {
        let f = 146.8324
        var signal = Harness.tone(fundamental: f, amplitudes: [1.0, 0.6, 0.4, 0.2],
                                  sampleRate: fs, seconds: 1.0)
        signal = Harness.addNoise(signal, level: 0.02)
        let (hz, clarity) = detect(signal)
        XCTAssertEqual(Harness.cents(hz, f), 0, accuracy: 5.0)
        XCTAssertGreaterThan(clarity, 0.6)
    }

    func testDetunedStringReportsTheRightCents() {
        let target = 110.0
        for offset in [-31.0, -12.0, -4.0, 4.0, 12.0, 31.0] {
            let f = target * pow(2, offset / 1200)
            let signal = Harness.tone(fundamental: f, amplitudes: [1.0, 0.7, 0.45],
                                      sampleRate: fs, seconds: 0.8)
            let (hz, _) = detect(signal)
            XCTAssertEqual(Harness.cents(hz, target), offset, accuracy: 2.0,
                           "offset \(offset) -> \(Harness.cents(hz, target))")
        }
    }

    func testWorksAtBluetoothSampleRates() {
        // §0.2: never assume 48 kHz. Every constant derives from the real rate.
        for rate in [16000.0, 24000.0, 44100.0] {
            let f = 196.0
            let signal = Harness.tone(fundamental: f, amplitudes: [1.0, 0.7, 0.4],
                                      sampleRate: rate, seconds: 1.0)
            let settled = Harness.settled(Harness.run(signal: signal, sampleRate: rate,
                                                      windowSize: 4096))
            XCTAssertFalse(settled.isEmpty, "no lock at \(rate)")
            guard !settled.isEmpty else { continue }
            let hz = settled.map(\.frequency).sorted()[settled.count / 2]
            XCTAssertEqual(Harness.cents(hz, f), 0, accuracy: 4.0, "fs=\(rate) -> \(hz) Hz")
        }
    }

    func testProcessDoesNotDependOnPreviousCalls() {
        let detector = PitchDetector(sampleRate: fs, windowSize: 4096)
        let a = Harness.sine(220, sampleRate: fs, seconds: 0.2)
        var first = 0.0, second = 0.0
        a.withUnsafeBufferPointer { first = detector.process($0.baseAddress!).frequency }
        let noise = Harness.addNoise([Float](repeating: 0, count: 4096), level: 0.3)
        noise.withUnsafeBufferPointer { _ = detector.process($0.baseAddress!) }
        a.withUnsafeBufferPointer { second = detector.process($0.baseAddress!).frequency }
        XCTAssertEqual(first, second, accuracy: 1e-9)
    }

    func testFrameBudget() {
        // Hop 1024 at 48 kHz is a 21.3 ms budget. Measured on the host, which is
        // a floor rather than a guarantee — but an order-of-magnitude regression
        // shows up here before it shows up on a phone.
        let detector = PitchDetector(sampleRate: fs, windowSize: 4096)
        let signal = Harness.tone(fundamental: 110, amplitudes: [1.0, 0.7, 0.4],
                                  sampleRate: fs, seconds: 0.2)
        let window = Array(signal[0..<4096])
        measure {
            window.withUnsafeBufferPointer { buffer in
                for _ in 0..<20 { _ = detector.process(buffer.baseAddress!) }
            }
        }
    }
}
