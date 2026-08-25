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

        // The floor rises at a bounded rate, so a loud room takes a few seconds
        // to reach the ceiling rather than adopting it on the first frame — that
        // rate limit is what stops a pick attack pinning the gate over the
        // instrument. Give it time, then check it clamps.
        let loud = NoiseGate()
        for _ in 0..<Int(12.0 / hop) {
            _ = loud.update(rms: linear(-10), dt: hop, pitchDetected: false)
        }
        XCTAssertEqual(loud.thresholdDB, NoiseGate.maxGateDB, accuracy: 1e-9)

        // ...and it must not have got there instantly.
        let rising = NoiseGate()
        for _ in 0..<Int(1.0 / hop) {
            _ = rising.update(rms: linear(-10), dt: hop, pitchDetected: false)
        }
        XCTAssertLessThan(rising.thresholdDB, NoiseGate.maxGateDB - 10,
                          "the floor must not leap to a transient")
    }

    func testAPitchRingingThroughCalibrationCannotSetTheFloor() {
        // The original bug: the floor was the minimum RMS over the window
        // regardless of whether anything was playing. A note ringing through the
        // whole second made its own level the floor, the gate clamped to its
        // -30 dB ceiling, and the note was then gated out as it decayed —
        // measured at 51-75% of frames rejected. Only unvoiced frames may teach
        // the gate where silence is.
        let gate = NoiseGate()
        for _ in 0..<Int(3.0 / hop) {
            _ = gate.update(rms: linear(-18), dt: hop, pitchDetected: true)
        }
        XCTAssertEqual(gate.thresholdDB, NoiseGate.defaultGateDB, accuracy: 0.001,
                       "a continuously voiced signal must leave the gate at its default")
        XCTAssertTrue(gate.update(rms: linear(-42), dt: hop, pitchDetected: true),
                      "the instrument must still pass as it decays")
    }

    func testAttackTransientCannotDragTheGateUp() {
        // The pick attack produces loud *unvoiced* frames. Adopting the first
        // one as the floor pinned the gate to its ceiling, so the floor may only
        // rise slowly.
        let gate = NoiseGate()
        for _ in 0..<3 {
            _ = gate.update(rms: linear(-6), dt: hop, pitchDetected: false)
        }
        XCTAssertLessThan(gate.thresholdDB, NoiseGate.defaultGateDB + 1.0)
    }

    func testFloorFollowsARoomThatGetsLouder() {
        let gate = NoiseGate()
        for _ in 0..<Int(1.2 / hop) {
            _ = gate.update(rms: linear(-70), dt: hop, pitchDetected: false)
        }
        XCTAssertEqual(gate.thresholdDB, -58, accuracy: 0.5)
        // Room fills up. The floor should climb, but at a bounded rate.
        for _ in 0..<Int(10.0 / hop) {
            _ = gate.update(rms: linear(-40), dt: hop, pitchDetected: false)
        }
        XCTAssertEqual(gate.thresholdDB, -30, accuracy: 1.0)
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
        while elapsed < 14.0 {
            _ = gate.update(rms: linear(-44), dt: hop, pitchDetected: false)
            if gate.isCalibrating { recalibrationSeen = true }
            elapsed += hop
        }
        XCTAssertTrue(recalibrationSeen, "§5 requires recalibration after 5 s of no pitch")
        // The floor climbs to the new room level at the bounded rate and the
        // gate follows it to −44 + 12 = −32.
        XCTAssertEqual(gate.thresholdDB, -32, accuracy: 1.0)
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
