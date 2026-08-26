import XCTest

/// The gate measures the room. It deliberately no longer silences anything —
/// see the note at the top of NoiseGate.swift for the measurements that led
/// there. These tests pin the measuring behaviour, and the fact that its
/// starting position cannot mute a quiet instrument.
final class NoiseGateTests: XCTestCase {
    private let hop = 1024.0 / 48000.0

    private func linear(_ db: Double) -> Double { pow(10, db / 20) }

    // MARK: - The bug this design exists to prevent

    func testAnUnmeasuredRoomCannotSilenceAQuietInstrument() {
        // The failure that made the tuner deaf to an unplugged electric: the
        // floor only learned from frames with no instrument, a sustained note
        // produces none, so the initial guess stood forever and everything
        // quieter than it was thrown away. An unplugged solid-body arrives at
        // roughly −60 to −70 dBFS and decays from there.
        let gate = NoiseGate()
        for db in [-55.0, -62.0, -68.0, -72.0] {
            XCTAssertTrue(gate.update(rms: linear(db), dt: hop, instrumentPresent: true),
                          "a \(db) dBFS instrument must not start out below the gate")
        }
    }

    func testStartingGateIsBelowAnUnpluggedElectric() {
        XCTAssertLessThanOrEqual(NoiseGate.defaultGateDB, -70.0)
        XCTAssertLessThanOrEqual(NoiseGate.minGateDB, -75.0,
                                 "§5's −60 floor is deaf to a solid-body")
    }

    func testAPitchRingingThroughCalibrationCannotSetTheFloor() {
        // Only frames with no instrument may teach the gate where silence is.
        let gate = NoiseGate()
        let before = gate.thresholdDB
        for _ in 0..<Int(3.0 / hop) {
            _ = gate.update(rms: linear(-18), dt: hop, instrumentPresent: true)
        }
        XCTAssertEqual(gate.thresholdDB, before, accuracy: 0.001,
                       "a continuously sounding instrument must not move the floor")
    }

    // MARK: - Measuring the room

    func testFloorFallsInstantlyToAQuietRoom() {
        let gate = NoiseGate()
        for _ in 0..<Int(0.2 / hop) {
            _ = gate.update(rms: linear(-95), dt: hop, instrumentPresent: false)
        }
        XCTAssertEqual(gate.floorDB, -95, accuracy: 0.5, "downward tracking is immediate")
    }

    func testFloorRisesSlowlyIntoALouderRoom() {
        let gate = NoiseGate()
        for _ in 0..<Int(0.2 / hop) {
            _ = gate.update(rms: linear(-90), dt: hop, instrumentPresent: false)
        }
        // One second of a −40 dB room may only lift the floor by the rate limit.
        for _ in 0..<Int(1.0 / hop) {
            _ = gate.update(rms: linear(-40), dt: hop, instrumentPresent: false)
        }
        XCTAssertEqual(gate.floorDB, -90 + NoiseGate.floorRiseDBPerSecond, accuracy: 1.0,
                       "a transient must not drag the floor up with it")

        // Given long enough it does get there.
        for _ in 0..<Int(30.0 / hop) {
            _ = gate.update(rms: linear(-40), dt: hop, instrumentPresent: false)
        }
        XCTAssertEqual(gate.floorDB, -40, accuracy: 1.0)
    }

    func testThresholdIsFloorPlusHeadroomAndClamped() {
        // The floor starts near −84 and may only rise at floorRiseDBPerSecond,
        // so reaching a −70 room takes several seconds by design. That rate
        // limit is what stops a pick attack dragging the gate over the
        // instrument, so the test waits rather than working around it.
        let gate = NoiseGate()
        for _ in 0..<Int(10.0 / hop) {
            _ = gate.update(rms: linear(-70), dt: hop, instrumentPresent: false)
        }
        XCTAssertEqual(gate.thresholdDB, -70 + NoiseGate.headroomDB, accuracy: 1.0)

        let loud = NoiseGate()
        for _ in 0..<Int(60.0 / hop) {
            _ = loud.update(rms: linear(-5), dt: hop, instrumentPresent: false)
        }
        XCTAssertEqual(loud.thresholdDB, NoiseGate.maxGateDB, accuracy: 1e-9)

        // Downward is immediate, but the threshold only republishes once the
        // initial calibration window has closed.
        let silent = NoiseGate()
        for _ in 0..<Int(2.0 / hop) {
            _ = silent.update(rms: linear(-140), dt: hop, instrumentPresent: false)
        }
        XCTAssertEqual(silent.thresholdDB, NoiseGate.minGateDB, accuracy: 1e-9)
    }

    func testRecalibratesAfterFiveSecondsWithNoInstrument() {
        let gate = NoiseGate()
        for _ in 0..<Int(1.2 / hop) {
            _ = gate.update(rms: linear(-70), dt: hop, instrumentPresent: true)
        }
        XCTAssertFalse(gate.isCalibrating)
        var seen = false
        for _ in 0..<Int(7.0 / hop) {
            _ = gate.update(rms: linear(-70), dt: hop, instrumentPresent: false)
            if gate.isCalibrating { seen = true }
        }
        XCTAssertTrue(seen, "§5 requires recalibration after 5 s with no instrument")
    }

    func testDecibelsFloorsAtSilence() {
        XCTAssertLessThan(NoiseGate.decibels(0), -100)
        XCTAssertEqual(NoiseGate.decibels(1.0), 0, accuracy: 1e-9)
        XCTAssertEqual(NoiseGate.decibels(0.1), -20, accuracy: 1e-9)
    }
}
