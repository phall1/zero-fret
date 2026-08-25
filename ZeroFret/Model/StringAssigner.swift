//  StringAssigner.swift
//  Zero Fret
//
//  Spec §4, "String assignment with hysteresis".
//
//  Nearest-target selection on its own flickers between adjacent strings on a
//  harmonically rich note and the display becomes unreadable. The rule:
//    - candidate = target minimising |cents|
//    - switch only if the candidate beats the incumbent by more than 20¢ of
//      absolute error, sustained for 3 consecutive frames
//    - a manual pin disables assignment entirely
//    - reject any candidate more than 60¢ out; that is between two strings and
//      means the detector is wrong or the user is playing something else

import Foundation

/// What the readout should be measured against for this frame.
enum PitchTarget: Equatable {
    /// A string of the active tuning.
    case string(index: Int, midi: Int)
    /// Nothing in the tuning is within 60¢, so fall back to the nearest note of
    /// the chromatic scale. Without this the app cannot report a bare 440 Hz
    /// reference tone, which is acceptance tests 3 and 4.
    case chromatic(midi: Int)

    var midi: Int {
        switch self {
        case let .string(_, midi): return midi
        case let .chromatic(midi): return midi
        }
    }

    var stringIndex: Int? {
        if case let .string(index, _) = self { return index }
        return nil
    }
}

final class StringAssigner {
    /// §4: switch only on a >20¢ improvement...
    static let switchMarginCents = 20.0
    /// ...sustained for 3 consecutive frames.
    static let switchFrames = 3
    /// §4: beyond this the candidate is between two strings — reject it.
    static let maxAcceptableCents = 60.0
    /// Consecutive out-of-range frames before the incumbent is released. ~0.5 s
    /// at hop 1024, long enough to ride out interference and short enough that
    /// genuinely moving to another instrument re-acquires promptly.
    static let releaseFrames = 24

    /// Set when the user taps a string row. Assignment is disabled while non-nil.
    var pinnedIndex: Int?

    private(set) var currentIndex: Int?
    private var pendingIndex: Int?
    private var pendingFrames = 0
    private var outOfRangeFrames = 0

    func reset() {
        currentIndex = nil
        pendingIndex = nil
        pendingFrames = 0
        outOfRangeFrames = 0
    }

    /// - Parameters:
    ///   - frequency: smoothed frequency in Hz.
    ///   - tuning: active tuning.
    ///   - referenceA: current reference pitch.
    /// - Parameter suggested: string chosen by harmonic scoring, when available.
    ///   Nearest-|cents| selection confuses strings whose harmonic series overlap
    ///   — E4 is the fourth harmonic of E2 — whereas asking which target actually
    ///   explains the spectrum does not. Measured on a plucked E4 through a
    ///   modelled phone microphone, harmonic scoring picked the right string on
    ///   183 frames of 184; nearest-|cents| is the rule that made the readout hop.
    func target(frequency: Double, tuning: Tuning, referenceA: Double,
                suggested: Int? = nil) -> PitchTarget {
        guard frequency > 0 else { return chromaticTarget(frequency: frequency, referenceA: referenceA) }

        if let pinned = pinnedIndex, tuning.midiNotes.indices.contains(pinned) {
            currentIndex = pinned
            pendingIndex = nil
            pendingFrames = 0
            return .string(index: pinned, midi: tuning.midiNotes[pinned])
        }

        // Candidate: the harmonically-scored string when one was found, else the
        // string minimising |cents|.
        var bestIndex = 0
        var bestAbsCents = Double.greatestFiniteMagnitude
        if let suggested, tuning.midiNotes.indices.contains(suggested) {
            bestIndex = suggested
            let target = MusicMath.frequency(midi: Double(tuning.midiNotes[suggested]),
                                             referenceA: referenceA)
            bestAbsCents = abs(MusicMath.cents(measured: frequency, target: target))
        } else {
            for (index, midi) in tuning.midiNotes.enumerated() {
                let target = MusicMath.frequency(midi: Double(midi), referenceA: referenceA)
                let absCents = abs(MusicMath.cents(measured: frequency, target: target))
                if absCents < bestAbsCents {
                    bestAbsCents = absCents
                    bestIndex = index
                }
            }
        }

        guard bestAbsCents <= StringAssigner.maxAcceptableCents else {
            // Report chromatically, but do NOT discard the incumbent on the
            // strength of one frame. Clearing it here meant the next plausible
            // frame hit the "no incumbent" path and adopted a string outright,
            // with no hysteresis at all — so any interference that briefly
            // landed between strings reset the whole mechanism, and the readout
            // hopped around. Only let go after sustained loss.
            outOfRangeFrames += 1
            if outOfRangeFrames >= StringAssigner.releaseFrames {
                currentIndex = nil
                pendingIndex = nil
                pendingFrames = 0
            }
            return chromaticTarget(frequency: frequency, referenceA: referenceA)
        }
        outOfRangeFrames = 0

        guard let incumbent = currentIndex, tuning.midiNotes.indices.contains(incumbent) else {
            currentIndex = bestIndex
            pendingIndex = nil
            pendingFrames = 0
            return .string(index: bestIndex, midi: tuning.midiNotes[bestIndex])
        }

        if bestIndex == incumbent {
            pendingIndex = nil
            pendingFrames = 0
            return .string(index: incumbent, midi: tuning.midiNotes[incumbent])
        }

        let incumbentTarget = MusicMath.frequency(midi: Double(tuning.midiNotes[incumbent]),
                                                  referenceA: referenceA)
        let incumbentAbsCents = abs(MusicMath.cents(measured: frequency, target: incumbentTarget))
        let improvement = incumbentAbsCents - bestAbsCents

        if improvement > StringAssigner.switchMarginCents {
            if pendingIndex == bestIndex {
                pendingFrames += 1
            } else {
                pendingIndex = bestIndex
                pendingFrames = 1
            }
            if pendingFrames >= StringAssigner.switchFrames {
                currentIndex = bestIndex
                pendingIndex = nil
                pendingFrames = 0
                return .string(index: bestIndex, midi: tuning.midiNotes[bestIndex])
            }
        } else {
            pendingIndex = nil
            pendingFrames = 0
        }

        // The incumbent is deliberately held even while it is hundreds of cents
        // away. §4 rejects a *candidate* beyond 60¢, not the incumbent — and the
        // candidate was already checked above. Dropping the incumbent here
        // instead would clear `currentIndex`, so the very next frame would adopt
        // the new string outright and the three-frame rule would never fire:
        // adjacent guitar strings are 400–500¢ apart, so every ordinary string
        // change would take that escape hatch. Three frames at hop 1024 is 64 ms.
        return .string(index: incumbent, midi: tuning.midiNotes[incumbent])
    }

    private func chromaticTarget(frequency: Double, referenceA: Double) -> PitchTarget {
        guard frequency > 0 else { return .chromatic(midi: 69) }
        let midi = Int(MusicMath.midi(frequency: frequency, referenceA: referenceA).rounded())
        return .chromatic(midi: min(max(midi, 0), 127))
    }
}
