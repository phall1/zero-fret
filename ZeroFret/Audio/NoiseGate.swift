//  NoiseGate.swift
//  Zero Fret
//
//  Spec §5, "Noise gate auto-calibration": measure RMS over 1.0 s on foreground,
//  set the gate to floor + 12 dB clamped to [−60, −30] dBFS, and recalibrate
//  whenever no pitch has been detected for 5 s.
//
//  Two deliberate refinements, both forced by other parts of the spec:
//
//  1. The floor is the *minimum* per-hop RMS across the calibration second, not
//     the mean. "Measure the noise floor over a second" and "the user might be
//     playing during that second" are both true; the minimum is the reading that
//     survives both. A mean taken while a string rings would set the gate above
//     the instrument and the app would look dead.
//
//  2. Calibration does not block detection. Acceptance test 8 wants a first
//     pitch reading inside 400 ms of a cold launch, and a 1 s calibration would
//     make that impossible. The gate starts at a conservative default and is
//     replaced when the measurement completes.

import Foundation

final class NoiseGate {
    /// §5 headroom above the measured floor.
    static let headroomDB = 12.0
    static let minGateDB = -60.0
    static let maxGateDB = -30.0
    /// Used while the first calibration is still in flight.
    static let defaultGateDB = -50.0
    static let calibrationSeconds = 1.0
    /// §5: recalibrate after this long with no pitch.
    static let idleRecalibrateSeconds = 5.0

    private(set) var thresholdDB = NoiseGate.defaultGateDB
    private(set) var isCalibrating = true

    private var calibrationElapsed = 0.0
    private var calibrationFloorDB = Double.greatestFiniteMagnitude
    private var quietSeconds = 0.0

    /// Call on foreground, on route change, and after any engine restart.
    func beginCalibration() {
        isCalibrating = true
        calibrationElapsed = 0
        calibrationFloorDB = .greatestFiniteMagnitude
        quietSeconds = 0
    }

    /// - Parameters:
    ///   - rms: linear RMS of the analysed (pre-filtered) hop.
    ///   - dt: seconds of audio this hop represents.
    ///   - pitchDetected: whether the frame produced a believable pitch.
    /// - Returns: whether the frame is above the gate.
    @discardableResult
    func update(rms: Double, dt: Double, pitchDetected: Bool) -> Bool {
        let db = NoiseGate.decibels(rms)

        if isCalibrating {
            calibrationFloorDB = min(calibrationFloorDB, db)
            calibrationElapsed += dt
            if calibrationElapsed >= NoiseGate.calibrationSeconds,
               calibrationFloorDB.isFinite {
                thresholdDB = min(max(calibrationFloorDB + NoiseGate.headroomDB,
                                      NoiseGate.minGateDB),
                                  NoiseGate.maxGateDB)
                isCalibrating = false
            }
        }

        if pitchDetected {
            quietSeconds = 0
        } else {
            quietSeconds += dt
            if quietSeconds >= NoiseGate.idleRecalibrateSeconds, !isCalibrating {
                beginCalibration()
            }
        }

        return db >= thresholdDB
    }

    static func decibels(_ linear: Double) -> Double {
        guard linear > 1e-9 else { return -180 }
        return 20 * log10(linear)
    }
}
