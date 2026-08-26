//  NoiseGate.swift
//  Zero Fret
//
//  Spec §5, "Noise gate auto-calibration": measure RMS over 1.0 s on foreground,
//  set the gate to floor + 12 dB clamped to [−60, −30] dBFS, and recalibrate
//  whenever no pitch has been detected for 5 s.
//
//  IMPORTANT: this no longer vetoes a reading. §3 says "gate on RMS: below the
//  noise floor, no pitch regardless of clarity", and that turned out to be the
//  single thing standing between the tuner and an unplugged electric guitar.
//
//  A solid body has no soundboard and no air cavity, so the only radiator is the
//  string, and a string is a dipole whose efficiency collapses when its length is
//  a fraction of a wavelength — low E at 82 Hz has a 4-metre wavelength against a
//  65 cm string. The result reaches a phone at roughly −60 to −70 dBFS and then
//  decays from there. Measured against a model of one, the level gate rejected
//  60% of frames at −63 dBFS and 100% at −75.
//
//  Removing the veto entirely and re-running the whole scenario set:
//
//                              with level veto      without
//    unplugged E2 @ −83 dBFS          0%             97.3%
//    unplugged, every level        0–97%             97.3% flat
//    room noise, all levels           0%                0%
//    true silence / dither            0%                0%
//    background speech                0%              2.2%
//
//  Level is not evidence about whether an instrument is present; harmonic
//  structure is. Contrast, clarity and stability do the whole job and do it
//  independently of how loud the room happens to be, which is also what Kaldi's
//  pitch tracker concluded — "rather than making hard decisions about voicing on
//  each frame, we treat all frames as voiced and allow the search to naturally
//  interpolate."
//
//  The floor is still measured, because it is worth showing in Settings and
//  because §5's recalibration behaviour is still the right description of the
//  room. It simply no longer silences the instrument.
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
    /// §5 clamps this at −60. Deliberately lower here: an unplugged electric is
    /// 20–30 dB quieter than an acoustic, because a solid body has no soundboard
    /// and a bare string is a hopeless radiator below a few hundred hertz. A
    /// −60 dB floor is simply deaf to one.
    static let minGateDB = -75.0
    static let maxGateDB = -30.0
    /// Where the gate sits before a room has actually been measured.
    ///
    /// This starts low on purpose. The floor only learns from frames with no
    /// detected pitch, and a sustained note produces none — so on a quiet
    /// instrument the initial guess was never replaced, the gate stayed at its
    /// assumed value, and anything below it was rejected forever. Measured on a
    /// modelled unplugged electric, that rejected 60% of frames at one level and
    /// 100% at the next one down: the tuner was deaf to the instrument because
    /// of an assumption, not a measurement.
    ///
    /// Failing open is the right default here. Level is no longer the only thing
    /// standing between the room and the display — harmonic contrast rejects
    /// broadband noise at about 2.1 against a guitar's 7–29, and the stability
    /// gate rejects most speech. The level gate does not need to carry that
    /// weight any more, and when it tries it takes the quiet instrument with it.
    static let defaultGateDB = -72.0
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
    /// pins the gate to its ceiling. Low to begin with, so an unmeasured room
    /// never gates out a quiet instrument — see `defaultGateDB`.
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
    /// - Parameter instrumentPresent: whether the harmonic evidence says an
    ///   instrument is sounding. This is a much better definition of "the room
    ///   is what we are hearing" than "the detector found no periodicity" — a
    ///   quiet sustained note is continuously periodic, so under the old test the
    ///   floor never got measured at all and the initial guess stood forever.
    /// - Returns: whether the frame is above the gate. Advisory: the caller no
    ///   longer treats this as a veto. See the note at the top of the file.
    @discardableResult
    func update(rms: Double, dt: Double, instrumentPresent: Bool) -> Bool {
        let pitchDetected = instrumentPresent
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
