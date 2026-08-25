import XCTest

final class SmootherTests: XCTestCase {
    private let dt = 1024.0 / 48000.0

    func testMedianRemovesASingleOutlier() {
        var median = Median5()
        var last = 0.0
        for value in [110.0, 110.0, 110.0, 220.0, 110.0, 110.0, 110.0] {
            last = median.push(value)
        }
        XCTAssertEqual(last, 110.0, accuracy: 1e-9)
    }

    func testMedianIsNotAMean() {
        // §5: a mean averages the octave error in rather than deleting it.
        var median = Median5()
        for value in [110.0, 110.0, 220.0, 110.0, 110.0] {
            _ = median.push(value)
        }
        XCTAssertEqual(median.push(110.0), 110.0, accuracy: 1e-9)
    }

    func testConvergesToTheTrueValue() {
        let smoother = Smoother(mode: .fast)
        var out = 0.0
        for _ in 0..<200 { out = smoother.process(hz: 146.8324, dt: dt) }
        XCTAssertEqual(out, 146.8324, accuracy: 0.001)
    }

    func testSteadyIsHeavierThanFast() {
        func settleFrames(_ mode: ResponseMode) -> Int {
            let smoother = Smoother(mode: mode)
            for _ in 0..<60 { _ = smoother.process(hz: 110.0, dt: dt) }
            var frames = 0
            for i in 0..<400 {
                let value = smoother.process(hz: 116.54, dt: dt)
                if abs(value - 116.54) < 0.1 { frames = i; break }
                frames = i
            }
            return frames
        }
        XCTAssertLessThan(settleFrames(.fast), settleFrames(.steady))
    }

    func testFastRejectsSingleFrameOutliers() {
        let smoother = Smoother(mode: .fast)
        for _ in 0..<40 { _ = smoother.process(hz: 82.41, dt: dt) }
        let before = smoother.process(hz: 82.41, dt: dt)
        _ = smoother.process(hz: 164.82, dt: dt)   // one octave-error frame
        let after = smoother.process(hz: 82.41, dt: dt)
        XCTAssertEqual(after, before, accuracy: 0.5)
    }

    func testAutoSwitchesToFastWhenTheNoteMoves() {
        let smoother = Smoother(mode: .auto)
        for _ in 0..<60 { _ = smoother.process(hz: 110.0, dt: dt) }
        for _ in 0..<80 { _ = smoother.process(hz: 110.0, dt: dt) }
        XCTAssertFalse(smoother.autoIsFast, "should have settled to Steady")

        // A bend: > 15¢ per frame for two frames.
        var hz = 110.0
        for _ in 0..<3 {
            hz *= pow(2, 25.0 / 1200)
            _ = smoother.process(hz: hz, dt: dt)
        }
        XCTAssertTrue(smoother.autoIsFast, "should have flipped to Fast")
    }

    func testResetClearsState() {
        let smoother = Smoother(mode: .fast)
        for _ in 0..<50 { _ = smoother.process(hz: 440.0, dt: dt) }
        smoother.reset()
        XCTAssertEqual(smoother.process(hz: 82.41, dt: dt), 82.41, accuracy: 1e-9)
    }
}
