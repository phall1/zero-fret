import XCTest

/// The instruments that are not guitars. The detector was built and measured
/// against guitar and bass, so every string of every other shipped tuning is
/// played through the same chain the app runs and has to come back as the
/// right string, in tune — not just "a frequency near it".
final class InstrumentTests: XCTestCase {
    private let fs = 48000.0

    private static let families: Set<InstrumentFamily> = [.ukulele, .mandolin, .banjo, .orchestral]

    /// Nylon is darker than steel: a strong fundamental and a quickly thinning
    /// series. Harder for a harmonic scorer than a guitar, which is the point.
    private static let plucked = [1.0, 0.45, 0.25, 0.12, 0.06]
    /// A bow drives the string as a sawtooth, so the partials fall as 1/n.
    private static let bowed = [1.0, 0.5, 0.33, 0.25, 0.2, 0.17, 0.14, 0.125]

    private func note(_ f0: Double, amplitudes: [Double], seed: UInt64) -> [Float] {
        let tone = Harness.tone(fundamental: f0, amplitudes: amplitudes,
                                sampleRate: fs, seconds: 2.0, decay: 1.6, level: 0.08)
        return Harness.addNoise(tone, level: 0.001, seed: seed)
    }

    func testEveryStringOfEveryOtherInstrumentIsReadAsItself() {
        let tunings = TuningLibrary.all.filter { Self.families.contains($0.family) }
        XCTAssertFalse(tunings.isEmpty)

        for tuning in tunings {
            assertReadsEveryString(of: tuning, amplitudes: Self.plucked)
            // The bowed ones are bowed as well.
            if tuning.family == .orchestral {
                assertReadsEveryString(of: tuning, amplitudes: Self.bowed)
            }
        }
    }

    private func assertReadsEveryString(of tuning: Tuning, amplitudes: [Double],
                                        file: StaticString = #filePath, line: UInt = #line) {
        for (index, midi) in tuning.midiNotes.enumerated() {
            let f0 = MusicMath.frequency(midi: Double(midi), referenceA: 440)
            let results = Harness.run(signal: note(f0, amplitudes: amplitudes, seed: UInt64(midi)),
                                      sampleRate: fs, windowSize: tuning.windowSize,
                                      smoothing: .fast, gated: true, gateTuning: tuning)
            let tracked = Harness.trackedStrings.compactMap { $0 }
            let settled = Harness.settled(results)
            let what = "\(tuning.name) string \(index) (\(MusicMath.label(midi: midi)))"
            guard !settled.isEmpty else {
                XCTFail("\(what): no reading", file: file, line: line)
                continue
            }

            let hz = settled.map(\.frequency).sorted()[settled.count / 2]
            XCTAssertLessThan(abs(Harness.cents(hz, f0)), 3.0, "\(what): read \(hz) Hz",
                              file: file, line: line)

            // Re-entrant tunings put octaves and near-octaves side by side, so
            // the right frequency on the wrong chip would still be a bug.
            let mostly = Dictionary(grouping: tracked, by: { $0 })
                .max { $0.value.count < $1.value.count }?.key
            XCTAssertEqual(mostly, index, "\(what): tracked as \(String(describing: mostly))",
                           file: file, line: line)
        }
    }

    /// The top of the editor's range, through the full chain. If it fails,
    /// `Tuning.midiRange` is promising a note the app cannot read. The bottom,
    /// B0, is §9.7 and already has its own acceptance test.
    func testTheTopOfTheEditorsRangeIsReadable() {
        let top = Tuning.midiRange.upperBound
        let tuning = Tuning(id: "custom.edge", name: "", family: .custom, midiNotes: [top - 5, top])
        let f0 = MusicMath.frequency(midi: Double(top), referenceA: 440)
        let settled = Harness.settled(Harness.run(signal: note(f0, amplitudes: Self.plucked, seed: 1),
                                                  sampleRate: fs, windowSize: tuning.windowSize,
                                                  smoothing: .fast, gated: true, gateTuning: tuning))
        XCTAssertFalse(settled.isEmpty, "MIDI \(top): no reading")
        guard !settled.isEmpty else { return }
        let hz = settled.map(\.frequency).sorted()[settled.count / 2]
        XCTAssertLessThan(abs(Harness.cents(hz, f0)), 3.0, "MIDI \(top): read \(hz) Hz")
    }
}
