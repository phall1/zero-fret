import XCTest

final class NoiseGateTests: XCTestCase {
    private let hop = 1024.0 / 48000.0

    private func linear(_ db: Double) -> Double { pow(10, db / 20) }

    func testStartsPermissiveSoTheFirstReadingIsNotBlocked() {
        // Acceptance test 8: cold launch to first pitch inside 400 ms. A 1 s
        // calibration cannot gate detection or that is unreachable.
        let gate = NoiseGate()
        XCTAssertEqual(gate.thresholdDB, NoiseGate.defaultGateDB)
        XCTAssertTrue(gate.update(rms: linear(-20), dt: hop, pitchDetected: true))
    }

    func testCalibratesToFloorPlusTwelve() {
        let gate = NoiseGate()
        for _ in 0..<Int(1.2 / hop) {
            _ = gate.update(rms: linear(-70), dt: hop, pitchDetected: false)
        }
        XCTAssertFalse(gate.isCalibrating)
        // −70 + 12 = −58, inside the clamp.
        XCTAssertEqual(gate.thresholdDB, -58, accuracy: 0.5)
    }

    func testClampsToTheSpecifiedRange() {
        let quiet = NoiseGate()
        for _ in 0..<Int(1.2 / hop) {
            _ = quiet.update(rms: linear(-120), dt: hop, pitchDetected: false)
        }
        XCTAssertEqual(quiet.thresholdDB, NoiseGate.minGateDB, accuracy: 1e-9)

        let loud = NoiseGate()
        for _ in 0..<Int(1.2 / hop) {
            _ = loud.update(rms: linear(-10), dt: hop, pitchDetected: false)
        }
        XCTAssertEqual(loud.thresholdDB, NoiseGate.maxGateDB, accuracy: 1e-9)
    }

    func testFloorSurvivesSomebodyPlayingDuringCalibration() {
        // The minimum, not the mean: a ringing string during the first second
        // must not set the gate above the instrument.
        let gate = NoiseGate()
        var frame = 0
        for _ in 0..<Int(1.2 / hop) {
            let db = frame % 4 == 0 ? -68.0 : -18.0
            _ = gate.update(rms: linear(db), dt: hop, pitchDetected: true)
            frame += 1
        }
        XCTAssertLessThan(gate.thresholdDB, -50)
    }

    func testRejectsSignalUnderTheGate() {
        let gate = NoiseGate()
        for _ in 0..<Int(1.2 / hop) {
            _ = gate.update(rms: linear(-70), dt: hop, pitchDetected: false)
        }
        XCTAssertFalse(gate.update(rms: linear(-65), dt: hop, pitchDetected: false))
        XCTAssertTrue(gate.update(rms: linear(-40), dt: hop, pitchDetected: true))
    }

    func testRecalibratesAfterFiveQuietSeconds() {
        let gate = NoiseGate()
        for _ in 0..<Int(1.2 / hop) {
            _ = gate.update(rms: linear(-70), dt: hop, pitchDetected: false)
        }
        XCTAssertFalse(gate.isCalibrating)
        XCTAssertEqual(gate.thresholdDB, -58, accuracy: 0.5)

        // The room gets louder. §5: after 5 s with no pitch the gate must
        // re-measure rather than sit on a floor that no longer exists.
        var recalibrationSeen = false
        var elapsed = 0.0
        while elapsed < 8.0 {
            _ = gate.update(rms: linear(-44), dt: hop, pitchDetected: false)
            if gate.isCalibrating { recalibrationSeen = true }
            elapsed += hop
        }
        XCTAssertTrue(recalibrationSeen, "§5 requires recalibration after 5 s of no pitch")
        // −44 + 12 = −32, and the new floor has replaced the old one.
        XCTAssertEqual(gate.thresholdDB, -32, accuracy: 0.5)
    }

    func testRecalibrationDoesNotRestartWhileAPitchIsPresent() {
        let gate = NoiseGate()
        for _ in 0..<Int(1.2 / hop) {
            _ = gate.update(rms: linear(-70), dt: hop, pitchDetected: false)
        }
        for _ in 0..<Int(20.0 / hop) {
            _ = gate.update(rms: linear(-30), dt: hop, pitchDetected: true)
        }
        XCTAssertFalse(gate.isCalibrating)
        XCTAssertEqual(gate.thresholdDB, -58, accuracy: 0.5)
    }
}
