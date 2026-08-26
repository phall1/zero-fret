//  TargetTracker.swift
//  Zero Fret
//
//  Decides, every frame, whether there is a reading to show — and if so, of
//  what. It replaces a single fixed set of thresholds with two states, because
//  finding a note and following one are different problems and were being asked
//  the same question.
//
//  Why two states
//
//  Everything upstream is built to answer "what, if anything, is playing?" That
//  is the hard question: six hypotheses plus the possibility that the answer is
//  none of them, decided against whatever else is in the room. The thresholds
//  that make it safe — clarity 0.60, contrast 8.0, nine agreeing frames — are
//  set by how wrong it can go, and they are strict.
//
//  Once a string has been identified, the question collapses to "is *this* one
//  still ringing?" There is one hypothesis, its frequency is known to within a
//  few cents, and being wrong costs a stale reading rather than a false one.
//  The strict thresholds are no longer buying anything, and they are what makes
//  the app let go of a note a guitarist can still plainly hear.
//
//  Traced on an unplugged low E decaying into room tone, the harmonic scorer
//  named E2 correctly on essentially every frame out to five seconds. Clarity
//  and contrast both fell through their floors at 2.5 s, and the display went
//  dark with the evidence still sitting there. The readings that made the 0.60
//  clarity floor necessary were 41 Hz, 27 Hz and 63 Hz against a true 82 — the
//  unconstrained lag search collapsing to subharmonics. Constrain the search to
//  a bracket around the string being followed and those candidates do not exist,
//  which is what lets the floor come down.
//
//  This is what a pedal tuner does, and it is why one feels certain: it takes a
//  clean instrument-level signal, so its "is the note still there?" test almost
//  never fails. Through a phone microphone we cannot have the clean signal, but
//  we can ask the same easier question.
//
//  Measured, unplugged E2 decaying into room tone at −72 dBFS. Time still
//  tracking, out of a six-second recording:
//
//                        one state    two states
//      E2 at −55           3.5 s         6.0 s
//      E2 at −63           2.4 s         4.8 s
//      E2 at −70           1.1 s         3.5 s
//      E2 at −78           never         never
//      acoustic E2         4.2 s         6.0 s
//
//  The −78 row is the honest one: six decibels *below* the room, the pitch
//  estimate genuinely wobbles by ±20 cents and there is no reading worth
//  showing. Nothing here manufactures one. The rows above it are all cases
//  where the note was plainly audible and the app had stopped listening.

import Foundation

struct TargetTracker {
    /// Contrast required to start following a string. Strict: this is the one
    /// decision here that can be wrong about the room, and the one the tracking
    /// state then trusts for as long as it holds.
    ///
    /// Deliberately well above `HarmonicScorer.minimumContrast`, which was set
    /// when a single threshold had to serve both finding and following. Now that
    /// following has its own much lower bar, acquisition is free to be strict —
    /// and it needs to be, because the constrained lag search made the pitch of
    /// a nearby voice steadier too, which is exactly what the stability gate was
    /// relying on to reject it.
    ///
    /// Swept against seven instrument scenarios and four rejection scenarios
    /// (`Scripts/bench/run.sh sweep`):
    ///
    ///      contrast   instrument coverage       speech admitted
    ///        4.5        no change                    18.8%
    ///        6.0        no change                    18.8%
    ///        8.0        no change                     4.8%
    ///       10.0        acoustic A2 98.2 -> 93.2      4.6%
    ///       13.0        acoustic E2 98.2 -> 0         4.6%
    ///
    /// Eight is the last value that costs nothing at all, and the step from six
    /// to eight is where almost all of the rejection is.
    static let acquireContrast = 8.0
    /// Contrast required to keep following one. Room tone alone measures 2.1
    /// and speech 4.3–5.6, so this sits above the floor the room can reach
    /// while being far below what acquisition demands.
    static let holdContrast = 2.6
    /// Consecutive frames without evidence before the string is let go. At a
    /// 21 ms hop this is a little over half a second, so a momentary dip in a
    /// decaying note never costs the lock.
    static let releaseFrames = 26
    /// Consecutive frames of acquire-strength evidence for a *different* string
    /// before the tracker moves. Three frames is §4's rule.
    static let switchFrames = 3
    /// How far the followed frequency may sit from the string's nominal pitch
    /// before the tracker concludes it is following something else. Wider than
    /// a semitone, so a badly flat string is still tracked.
    static let leashCents = 350.0
    /// Half-width of the constrained lag search while tracking.
    static let trackToleranceCents = 260.0

    enum State: Equatable {
        case searching
        /// `hz` is the last believed frequency, which is what the next frame's
        /// lag search is centred on — not the string's nominal pitch, so a
        /// string that is badly out of tune is still followed.
        case tracking(string: Int, hz: Double)
    }

    // Instance copies so the thresholds can be swept offline against real
    // scenarios rather than picked by feel, the same way `PitchStability` does.
    // Defaults are the swept values.
    var acquireContrast = TargetTracker.acquireContrast
    var holdContrast = TargetTracker.holdContrast
    var releaseFrames = TargetTracker.releaseFrames

    private(set) var state: State = .searching
    var stability = PitchStability()
    private var misses = 0
    private var contender: Int?
    private var contenderFrames = 0
    private var lastGood: Double = 0

    /// Half-width of the constrained lag search while searching. The scorer's
    /// argmax is only good to a few tens of cents, so this is generous — but a
    /// long way short of the 1200 it would take to admit the octave below.
    static let searchToleranceCents = 130.0

    /// Where the lag search should be centred this frame, and how wide.
    ///
    /// While tracking, the string being followed. While *searching*, whatever
    /// the harmonic scorer has just proposed — which is the point. Traced on a
    /// note 6 dB into room tone, the scorer named the right string on nearly
    /// every frame while the open lag search returned 41 Hz, 27 Hz and 119 Hz
    /// against a true 82, and clarity never once reached its 0.60 floor. The
    /// evidence needed to acquire was present the whole time and the search was
    /// not using it.
    ///
    /// So the spectrum decides *what* to look for and the NSDF decides exactly
    /// *where* it is. Each is asked the question it is good at, and neither is
    /// asked to work alone.
    func searchCentre(proposedBy detection: HarmonicScorer.Detection?)
        -> (hz: Double, toleranceCents: Double)? {
        if case let .tracking(_, hz) = state {
            return (hz, TargetTracker.trackToleranceCents)
        }
        guard let f = detection?.score.frequency, f > 0 else { return nil }
        return (f, TargetTracker.searchToleranceCents)
    }

    /// Reads a frequency out of a detector that has just been given a window.
    ///
    /// While tracking, this is simply the constrained search around the string
    /// being followed.
    ///
    /// While *searching* it is open first, constrained only as a rescue. The
    /// distinction matters more than it looks. Steering the search with the
    /// scorer is what rescues a quiet instrument, but the scorer only ever
    /// proposes one of the six strings — so a tone that is not a string at all
    /// still gets a proposal, and a constrained search will dutifully find
    /// something near it. A bare 440 Hz reference tone was read as D3: 440 is
    /// the third harmonic of 146.67, so of the six hypotheses D3 explains it
    /// best, and the search then never looked anywhere near 440. That breaks
    /// §4's chromatic fallback, which exists precisely so the app can report a
    /// note that is not one of the six.
    ///
    /// Asking openly first costs one extra scan of an array that is already
    /// computed, and means the steering only ever engages where the open search
    /// had already failed — which is exactly the case it was added for.
    func read(from detector: PitchDetector,
              proposedBy detection: HarmonicScorer.Detection?) -> PitchResult {
        guard let centre = searchCentre(proposedBy: detection) else {
            return detector.pitch()
        }
        if isTracking {
            return detector.pitch(near: centre.hz, toleranceCents: centre.toleranceCents)
        }
        let open = detector.pitch()
        if open.hasPitch { return open }
        return detector.pitch(near: centre.hz, toleranceCents: centre.toleranceCents)
    }

    var isTracking: Bool {
        if case .tracking = state { return true }
        return false
    }

    struct Outcome {
        /// True when there is a frequency worth showing.
        var voiced = false
        var frequency = 0.0
        /// The string being followed, or nil while searching.
        var string: Int?
        /// True on the frame a string was picked up, for the haptic in §6.
        var acquired = false
        /// The frequency is the previous one carried forward: still following
        /// this string, but this frame produced no evidence of its own. A pedal
        /// tuner does not blank between the frames it is unsure about, and a
        /// display that flickers off mid-note reads as broken even when the
        /// detector is doing exactly the right thing.
        var isHeld = false
    }

    /// - Parameters:
    ///   - pitch: the detector's result, as returned by `read`.
    ///   - detection: the harmonic scorer's verdict for this frame.
    ///   - nominal: the followed string's in-tune frequency, for the leash.
    mutating func update(pitch: PitchResult,
                         detection: HarmonicScorer.Detection?,
                         nominal: (Int) -> Double) -> Outcome {
        switch state {
        case .searching:
            return search(pitch: pitch, detection: detection)
        case let .tracking(string, hz):
            return track(string: string, hz: hz, pitch: pitch,
                         detection: detection, nominal: nominal)
        }
    }

    private mutating func search(pitch: PitchResult,
                                 detection: HarmonicScorer.Detection?) -> Outcome {
        let contrast = detection?.contrast ?? 0
        let standsOut = contrast >= acquireContrast
        let steady = stability.admit(frequency: pitch.frequency,
                                     voiced: pitch.hasPitch && standsOut)
        guard steady, let detection else { return Outcome() }

        state = .tracking(string: detection.stringIndex, hz: pitch.frequency)
        lastGood = pitch.frequency
        misses = 0
        contender = nil
        contenderFrames = 0
        return Outcome(voiced: true, frequency: pitch.frequency,
                       string: detection.stringIndex, acquired: true)
    }

    private mutating func track(string: Int, hz: Double, pitch: PitchResult,
                                detection: HarmonicScorer.Detection?,
                                nominal: (Int) -> Double) -> Outcome {
        // A different string, played convincingly, takes over. Checked before
        // the hold test: switching strings mid-tune must not have to wait out
        // the release timer.
        if let detection, detection.stringIndex != string,
           detection.contrast >= acquireContrast {
            if contender == detection.stringIndex {
                contenderFrames += 1
            } else {
                contender = detection.stringIndex
                contenderFrames = 1
            }
            if contenderFrames >= TargetTracker.switchFrames {
                // Re-enter search rather than jumping straight across. The new
                // string's frequency is not known to the constrained search yet,
                // and one open frame is all it takes to find it.
                release()
                return Outcome()
            }
        } else {
            contender = nil
            contenderFrames = 0
        }

        // The evidence test. Contrast is the honest one — it asks how much this
        // string stands out from frequencies that are not strings at all — but
        // it is answered against the whole tuning, so it dips when a neighbour
        // rings sympathetically. Accept either that or the scorer simply still
        // naming this string.
        let contrast = detection?.contrast ?? 0
        let stillNamed = detection?.stringIndex == string
        let evidence = pitch.hasPitch
            && (contrast >= holdContrast || stillNamed)

        guard evidence else {
            misses += 1
            if misses >= releaseFrames {
                release()
                return Outcome()
            }
            // Coast. The string is still being followed; this frame just had
            // nothing to say about it.
            guard lastGood > 0 else { return Outcome() }
            return Outcome(voiced: true, frequency: lastGood, string: string, isHeld: true)
        }
        misses = 0

        // The leash. Without it, a constrained search that has been dragged off
        // by noise keeps re-centring on wherever it landed and never comes back.
        let target = nominal(string)
        guard target > 0,
              abs(1200 * log2(pitch.frequency / target)) <= TargetTracker.leashCents else {
            release()
            return Outcome()
        }

        state = .tracking(string: string, hz: pitch.frequency)
        lastGood = pitch.frequency
        return Outcome(voiced: true, frequency: pitch.frequency, string: string)
    }

    mutating func release() {
        state = .searching
        stability.reset()
        misses = 0
        contender = nil
        contenderFrames = 0
        lastGood = 0
    }

    mutating func reset() { release() }
}
