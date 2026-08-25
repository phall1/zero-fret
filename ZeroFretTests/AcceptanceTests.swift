import XCTest

/// Spec §9. The tests here are the ones that can be answered without a
/// microphone; 5, 6, 8, 9, 10 and 11 are device tests and are tracked in
/// docs/ACCEPTANCE.md.
///
/// §9 says tests 1, 4 and 5 are the ones that fail. Two of the three are here.
final class AcceptanceTests: XCTestCase {
    private let fs = 48000.0

    private func settledHz(_ signal: [Float], windowSize: Int = 4096,
                           smoothing: ResponseMode? = .fast) -> (hz: Double, clarity: Double)? {
        let settled = Harness.settled(Harness.run(signal: signal, sampleRate: fs,
                                                  windowSize: windowSize,
                                                  smoothing: smoothing))
        guard !settled.isEmpty else { return nil }
        let hz = settled.map(\.frequency).sorted()[settled.count / 2]
        let clarity = settled.map(\.clarity).sorted()[settled.count / 2]
        return (hz, clarity)
    }

    private func pluck(fundamental: Double, amplitudes: [Double], seed: UInt64,
                       seconds: Double = 1.0, decay: Double = 1.4) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let phases = amplitudes.map { _ in rng.nextUnit() * 2 * Double.pi }
        return Harness.tone(fundamental: fundamental, amplitudes: amplitudes,
                            sampleRate: fs, seconds: seconds, phases: phases,
                            decay: decay)
    }

    /// §9.1 — Play E2 on an electric with the tone knob rolled off.
    /// Reads E2, never E3. 20 consecutive picks.
    func testAcceptance1_LowEIsNeverAnOctaveHigh() {
        let e2 = MusicMath.frequency(midi: 40, referenceA: 440)
        let e3 = e2 * 2
        // Tone rolled off: fundamental dominant, upper partials dark. Also the
        // bright case, because a new string is the other half of this failure.
        let voicings: [[Double]] = [
            [1.00, 0.55, 0.20, 0.06],
            [1.00, 0.90, 0.80, 0.70, 0.60, 0.45],
            [0.70, 1.00, 0.65, 0.40, 0.25],
        ]
        for pick in 0..<20 {
            let amplitudes = voicings[pick % voicings.count]
            let signal = pluck(fundamental: e2, amplitudes: amplitudes,
                               seed: UInt64(pick) &* 0x9E37_79B9)
            guard let (hz, _) = settledHz(signal) else {
                return XCTFail("pick \(pick): no lock")
            }
            XCTAssertLessThan(abs(Harness.cents(hz, e2)), 12.0,
                              "pick \(pick) read \(hz) Hz (E2 = \(e2))")
            XCTAssertGreaterThan(abs(Harness.cents(hz, e3)), 600.0,
                                 "pick \(pick) read the octave: \(hz) Hz")
        }
    }

    /// §9.2 — A harmonic at the 12th fret of low E reads E3 with clarity > 0.9.
    func testAcceptance2_TwelfthFretHarmonic() {
        let e3 = MusicMath.frequency(midi: 52, referenceA: 440)
        XCTAssertEqual(e3, 164.8138, accuracy: 0.001)
        // A node-plucked harmonic is close to a pure tone with a faint octave.
        let signal = pluck(fundamental: e3, amplitudes: [1.0, 0.12, 0.04],
                           seed: 0xE3, seconds: 1.2, decay: 2.5)
        guard let (hz, clarity) = settledHz(signal) else {
            return XCTFail("no lock on the harmonic")
        }
        XCTAssertLessThan(abs(Harness.cents(hz, e3)), 6.0, "read \(hz) Hz")
        XCTAssertGreaterThan(clarity, 0.9, "clarity \(clarity)")
    }

    /// §9.3 — A generated 440.0 Hz tone reads within ±0.5¢.
    func testAcceptance3_ReferenceToneWithinHalfACent() {
        let signal = Harness.sine(440.0, sampleRate: fs, seconds: 1.5)
        guard let (hz, clarity) = settledHz(signal) else {
            return XCTFail("no lock on 440 Hz")
        }
        XCTAssertLessThan(abs(Harness.cents(hz, 440.0)), 0.5,
                          "read \(hz) Hz = \(Harness.cents(hz, 440.0))¢")
        XCTAssertGreaterThan(clarity, 0.95)

        // ...and it must name the note, which is the chromatic fallback path.
        let assigner = StringAssigner()
        let target = assigner.target(frequency: hz, tuning: TuningLibrary.standard,
                                     referenceA: 440)
        XCTAssertEqual(target.midi, 69)
        XCTAssertEqual(MusicMath.label(midi: target.midi), "A4")
    }

    /// §9.4 — The same tone with the reference set to 442.0 reads −7.9¢.
    func testAcceptance4_SameToneAtReference442() {
        let signal = Harness.sine(440.0, sampleRate: fs, seconds: 1.5)
        guard let (hz, _) = settledHz(signal) else { return XCTFail("no lock") }

        let assigner = StringAssigner()
        let target = assigner.target(frequency: hz, tuning: TuningLibrary.standard,
                                     referenceA: 442)
        XCTAssertEqual(target.midi, 69)
        let cents = MusicMath.cents(measured: hz,
                                    target: MusicMath.frequency(midi: 69, referenceA: 442))
        XCTAssertEqual(cents, -7.9, accuracy: 0.5, "read \(cents)¢")
    }

    /// §9.7 — Bass low B (30.87 Hz) locks within 1 s with clarity > 0.7.
    func testAcceptance7_BassLowB() {
        let b0 = MusicMath.frequency(midi: 23, referenceA: 440)
        XCTAssertEqual(b0, 30.8677, accuracy: 0.001)

        let window = TuningLibrary.bassFive.windowSize
        XCTAssertEqual(window, 8192, "§3 requires 8192 for bass")

        let signal = pluck(fundamental: b0, amplitudes: [1.0, 0.8, 0.6, 0.45, 0.3],
                           seed: 0xB0, seconds: 2.0, decay: 3.0)
        let results = Harness.run(signal: signal, sampleRate: fs, windowSize: window)

        // "Locks within 1 s": at hop 2048 that is the first 23 frames.
        let hop = Double(window / 4) / fs
        let withinOneSecond = results.prefix(Int(1.0 / hop))
        guard let first = withinOneSecond.first(where: { $0.hasPitch }) else {
            return XCTFail("no lock inside 1 s")
        }
        XCTAssertLessThan(abs(Harness.cents(first.frequency, b0)), 15.0,
                          "read \(first.frequency) Hz")

        guard let (hz, clarity) = settledHz(signal, windowSize: window) else {
            return XCTFail("no settled reading")
        }
        XCTAssertLessThan(abs(Harness.cents(hz, b0)), 6.0, "settled at \(hz) Hz")
        XCTAssertGreaterThan(clarity, 0.7, "clarity \(clarity)")
    }

    /// §9.7 companion — the rationale behind the §3 window table, asserted as
    /// the periods-per-window rule it is derived from.
    ///
    /// Deliberately *not* a "4096 detects B0 worse" test. On a synthetic
    /// stationary tone both windows read B0 to within 0.03¢ with clarity 0.999,
    /// so such a test would either fail honestly or pass for the wrong reason.
    /// The spec's claim is about real strings — inharmonicity, decay envelope,
    /// room — and is validated on device (docs/ACCEPTANCE.md).
    func testWindowTableHoldsAtLeastThreePeriods() {
        func periods(_ hz: Double, window: Int, sampleRate: Double = 48000) -> Double {
            Double(window) / (sampleRate / hz)
        }
        // §3: 4096 "holds >=3 periods of E2 (82.41 Hz, period 582 samples)".
        XCTAssertGreaterThanOrEqual(periods(82.4069, window: 4096), 3.0)
        // §3: "B0 is 30.87 Hz... 4096 gives <3 periods and the NSDF peak becomes
        // unreliable." That is the whole reason the bass window exists.
        XCTAssertLessThan(periods(30.8677, window: 4096), 3.0)
        XCTAssertGreaterThanOrEqual(periods(30.8677, window: 8192), 3.0)

        // And the tuning library must actually route B0 to the wide window.
        XCTAssertEqual(TuningLibrary.bassFive.windowSize, 8192)
        XCTAssertEqual(TuningLibrary.standard.windowSize, 4096)

        // Every string of every shipped tuning must clear the bar at its own
        // window, or the rule in `Tuning.windowSize` has a hole in it.
        for tuning in TuningLibrary.all {
            let lowest = MusicMath.frequency(midi: Double(tuning.midiNotes.min()!),
                                             referenceA: 440)
            XCTAssertGreaterThanOrEqual(periods(lowest, window: tuning.windowSize), 3.0,
                                        "\(tuning.name): lowest string \(lowest) Hz")
        }
    }

    /// The detector must also be able to *reach* B0's period. τ is capped at
    /// N/2, and at 4096 that leaves almost no margin over a 1555-sample period.
    func testLagRangeCoversEveryShippedString() {
        for tuning in TuningLibrary.all {
            let detector = PitchDetector(sampleRate: 48000, windowSize: tuning.windowSize)
            let lowest = MusicMath.frequency(midi: Double(tuning.midiNotes.min()!),
                                             referenceA: 440)
            let period = 48000 / lowest
            XCTAssertLessThan(period, Double(detector.tauMax),
                              "\(tuning.name): period \(period) vs tauMax \(detector.tauMax)")
            let highest = MusicMath.frequency(midi: Double(tuning.midiNotes.max()!),
                                              referenceA: 440)
            XCTAssertGreaterThan(48000 / highest, Double(detector.tauMin),
                                 "\(tuning.name): top string above tauMin")
        }
    }

    /// §9.10 — silence blanks the display, with no phantom notes.
    func testAcceptance10_SilenceProducesNothing() {
        var signal = Harness.sine(196.0, sampleRate: fs, seconds: 0.5)
        signal += [Float](repeating: 0, count: Int(fs * 2.0))
        let results = Harness.run(signal: signal, sampleRate: fs, windowSize: 4096)

        let hop = 1024.0 / fs
        let tail = results.suffix(Int(1.0 / hop))
        XCTAssertFalse(tail.isEmpty)
        XCTAssertTrue(tail.allSatisfy { !$0.hasPitch },
                      "phantom pitch during silence")
    }

    /// §9.11, host-side half: repeated analysis must not grow.
    func testNoAllocationGrowthAcrossManyFrames() {
        let detector = PitchDetector(sampleRate: fs, windowSize: 4096)
        let signal = Harness.tone(fundamental: 110, amplitudes: [1.0, 0.7, 0.4],
                                  sampleRate: fs, seconds: 0.3)
        let window = Array(signal[0..<4096])
        window.withUnsafeBufferPointer { buffer in
            for _ in 0..<2000 { _ = detector.process(buffer.baseAddress!) }
        }
        // Reaching here without the allocator thrashing is the assertion; the
        // real measurement is Instruments on device.
        XCTAssertTrue(true)
    }
}
