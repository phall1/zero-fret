import XCTest

/// The cents readout. What it must never do is put a direction on a reading
/// that rounds to nothing, or show a number for one that is not a reading.
final class DisplayStateTests: XCTestCase {
    private func text(_ cents: Double, hasPitch: Bool = true) -> String {
        var state = DisplayState()
        state.hasPitch = hasPitch
        state.cents = cents
        return state.centsText
    }

    func testZeroIsPlainWhicheverSideItRoundsFrom() {
        for cents in [0.0, -0.0, 0.01, -0.01, 0.049, -0.049, 0.0499999, -0.0499999] {
            XCTAssertEqual(text(cents), "0.0", "\(cents)")
        }
    }

    func testTheFirstVisibleTenthCarriesItsDirection() {
        XCTAssertEqual(text(0.05), "+0.1")
        XCTAssertEqual(text(-0.05), "−0.1")
        XCTAssertEqual(text(0.06), "+0.1")
        XCTAssertEqual(text(-0.14), "−0.1")
    }

    func testFlatAndSharpKeepOneDecimalAndNoPadding() {
        XCTAssertEqual(text(-3.24), "−3.2")
        XCTAssertEqual(text(4.96), "+5.0")
        XCTAssertEqual(text(-22.0), "−22.0")
        XCTAssertEqual(text(16.04), "+16.0")
    }

    func testEitherSideOfTheDefaultToleranceReadsAsItIs() {
        // ±5¢ is in tune by default (`TunerEngine.defaultToleranceCents`, which
        // this bundle does not compile); the number still says where inside it.
        let tolerance = 5.0
        XCTAssertEqual(text(-tolerance), "−5.0")
        XCTAssertEqual(text(tolerance + 0.04), "+5.0")
        XCTAssertEqual(text(-(tolerance + 0.06)), "−5.1")
        XCTAssertEqual(TuneDirection.from(cents: -tolerance, tolerance: tolerance), .inTune)
        XCTAssertEqual(TuneDirection.from(cents: -(tolerance + 0.06), tolerance: tolerance), .flat)
    }

    func testOutOfRangeClampsWithoutLosingDirection() {
        XCTAssertEqual(text(250), "+99.9")
        XCTAssertEqual(text(-250), "−99.9")
    }

    func testNoReadingIsNeverAPerfectOne() {
        XCTAssertEqual(text(0, hasPitch: false), "–––.–")
        XCTAssertEqual(text(.nan), "–––.–")
        XCTAssertEqual(text(.infinity), "–––.–")
        XCTAssertEqual(text(-.infinity), "–––.–")
    }
}
