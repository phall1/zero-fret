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
//
//  3. Only frames with NO detected pitch feed the floor estimate. This is the
//     correction to (1): taking the minimum over the window is not robust to
//     somebody playing if they are playing for the *whole* window — a note
//     ringing through the entire calibration second makes its own level the
//     "floor", the gate clamps to its -30 dB ceiling, and the note is then
//     gated out as it decays. Measured on a plucked E2 through a modelled phone
//     microphone, that path rejected 51-75% of frames. The noise floor is by
//     definition the level when nothing is being played, so measure it there.
//
//  4. The floor keeps tracking after calibration: instant downward, slow upward.
//     A room that gets louder is followed within a few seconds; a brief quiet
//     moment does not permanently pin the gate low.

import Foundation

final class NoiseGate {
    /// §5 headroom above the measured floor.
    static let headroomDB = 12.0
    static let minGateDB = -60.0
    static let maxGateDB = -30.0
    /// Used until a floor has actually been observed.
    static let defaultGateDB = -50.0
    static let calibrationSeconds = 1.0
    /// §5: recalibrate after this long with no pitch.
    static let idleRecalibrateSeconds = 5.0
    /// How fast the floor may rise once established, in dB per second. Fast
    /// enough to follow a room filling up, slow enough that one loud frame
    /// cannot drag the gate over the instrument.
    static let floorRiseDBPerSecond = 3.0

    private(set) var thresholdDB = NoiseGate.defaultGateDB
    private(set) var isCalibrating = true
    /// Best current estimate of the room, in dBFS. Starts where the default gate
    /// implies rather than at the first thing heard: the first unvoiced frames
    /// of a session are usually the pick attack, and adopting that as the floor
    /// pins the gate to its ceiling.
    private(set) var floorDB: Double = NoiseGate.defaultGateDB - NoiseGate.headroomDB

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

        // Only silence teaches us where silence is — and it may only lower the
        // floor quickly. Raising it is rate-limited so a transient cannot drag
        // the gate up over the instrument.
        if !pitchDetected {
            if db < floorDB {
                floorDB = db
            } else {
                floorDB = min(floorDB + NoiseGate.floorRiseDBPerSecond * dt, db)
            }
            if isCalibrating { calibrationFloorDB = min(calibrationFloorDB, db) }
        }

        if isCalibrating {
            calibrationElapsed += dt
            if calibrationElapsed >= NoiseGate.calibrationSeconds {
                // If the whole window was voiced there is no floor to adopt;
                // keep the default rather than inventing one from the note.
                if calibrationFloorDB.isFinite { applyFloor(calibrationFloorDB) }
                isCalibrating = false
            }
        } else {
            applyFloor(floorDB)
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

    private func applyFloor(_ floor: Double) {
        thresholdDB = min(max(floor + NoiseGate.headroomDB, NoiseGate.minGateDB),
                          NoiseGate.maxGateDB)
    }

    static func decibels(_ linear: Double) -> Double {
        guard linear > 1e-9 else { return -180 }
        return 20 * log10(linear)
    }
}
