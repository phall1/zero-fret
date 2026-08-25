import XCTest

final class StringAssignerTests: XCTestCase {
    private let tuning = TuningLibrary.standard
    private let a = 440.0

    private func hz(_ midi: Double, cents: Double = 0) -> Double {
        MusicMath.frequency(midi: midi, referenceA: a) * pow(2, cents / 1200)
    }

    func testPicksTheNearestString() {
        let assigner = StringAssigner()
        let target = assigner.target(frequency: hz(45, cents: 6), tuning: tuning, referenceA: a)
        XCTAssertEqual(target.stringIndex, 1)
        XCTAssertEqual(target.midi, 45)
    }

    func testDoesNotFlickerOnASmallImprovement() {
        let assigner = StringAssigner()
        _ = assigner.target(frequency: hz(50), tuning: tuning, referenceA: a)
        XCTAssertEqual(assigner.currentIndex, 2)

        // Drift towards G3 but only enough to beat D3 by ~10¢ of error.
        // 50 -> 55 is 500¢; sit where |cents to D3| = 30 and |cents to G3| = 470.
        for _ in 0..<10 {
            let target = assigner.target(frequency: hz(50, cents: 30), tuning: tuning, referenceA: a)
            XCTAssertEqual(target.stringIndex, 2)
        }
    }

    func testSwitchesOnlyAfterThreeSustainedFrames() {
        let assigner = StringAssigner()
        _ = assigner.target(frequency: hz(50), tuning: tuning, referenceA: a)
        XCTAssertEqual(assigner.currentIndex, 2)

        // A clear move to G3: 0¢ from G3, 500¢ from D3.
        var switched = 0
        for frame in 1...4 {
            let target = assigner.target(frequency: hz(55), tuning: tuning, referenceA: a)
            if target.stringIndex == 3 { switched = frame; break }
        }
        XCTAssertEqual(switched, 3, "§4 requires three consecutive frames")
    }

    func testInterruptedRunDoesNotSwitch() {
        let assigner = StringAssigner()
        _ = assigner.target(frequency: hz(50), tuning: tuning, referenceA: a)
        _ = assigner.target(frequency: hz(55), tuning: tuning, referenceA: a)
        _ = assigner.target(frequency: hz(55), tuning: tuning, referenceA: a)
        _ = assigner.target(frequency: hz(50), tuning: tuning, referenceA: a)   // back
        let target = assigner.target(frequency: hz(55), tuning: tuning, referenceA: a)
        XCTAssertEqual(target.stringIndex, 2, "the run was broken; must not switch yet")
    }

    func testPinDisablesAssignment() {
        let assigner = StringAssigner()
        assigner.pinnedIndex = 0
        for _ in 0..<10 {
            let target = assigner.target(frequency: hz(64), tuning: tuning, referenceA: a)
            XCTAssertEqual(target.stringIndex, 0, "pinned to low E")
            XCTAssertEqual(target.midi, 40)
        }
    }

    func testRejectsCandidatesBeyond60Cents() {
        let assigner = StringAssigner()
        // A4 is 500¢ above E4 and 200¢ below nothing in the tuning.
        let target = assigner.target(frequency: 440.0, tuning: tuning, referenceA: a)
        XCTAssertNil(target.stringIndex)
        XCTAssertEqual(target.midi, 69, "chromatic fallback should name A4")
    }

    func testChromaticFallbackIsExactForAReferenceTone() {
        // Acceptance tests 3 and 4 live or die on this path.
        let assigner = StringAssigner()
        let target = assigner.target(frequency: 440.0, tuning: tuning, referenceA: 442.0)
        XCTAssertEqual(target.midi, 69)
        let cents = MusicMath.cents(measured: 440.0,
                                    target: MusicMath.frequency(midi: 69, referenceA: 442))
        XCTAssertEqual(cents, -7.9, accuracy: 0.05)
    }

    func testHalfwayBetweenStringsFallsBackToChromatic() {
        // Exactly between B3 (59) and E4 (64) — 250¢ from each.
        let assigner = StringAssigner()
        let target = assigner.target(frequency: hz(61.5), tuning: tuning, referenceA: a)
        XCTAssertNil(target.stringIndex)
    }

    func testBassLowBIsAssignable() {
        let assigner = StringAssigner()
        let target = assigner.target(frequency: 30.8677,
                                     tuning: TuningLibrary.bassFive, referenceA: a)
        XCTAssertEqual(target.stringIndex, 0)
        XCTAssertEqual(target.midi, 23)
    }
}
