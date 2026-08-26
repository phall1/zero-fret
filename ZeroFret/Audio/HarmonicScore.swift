//  HarmonicScore.swift
//  Zero Fret
//
//  Scores a candidate fundamental by how much of the spectrum actually belongs
//  to its harmonic series.
//
//  Why this exists, and why it is not another clarity gate:
//
//  Clarity answers "is something periodic?" — and measurement says that is the
//  wrong question. Through a modelled phone microphone, background speech scores
//  0.994 clarity against a plucked string's 0.921, because a glottal pulse train
//  is more perfectly periodic than a real string. Tightening a clarity floor
//  rejects the instrument and keeps the interference.
//
//  This answers a different question: of everything reaching the microphone, how
//  much of it is arranged as harmonics of *this particular frequency*? Combined
//  with only ever asking about the six frequencies the user is trying to hit, it
//  becomes a test the room has to work hard to pass. Speech at 130 Hz sits 200
//  cents from D3 and 260 from A2, outside every string's acceptance window, so
//  every string scores low and the answer is correctly "nothing".
//
//  This is the shape of TC Electronic's PolyTune patent (US 9,070,350 B2), which
//  uses a per-string filter bank "tuned to the desired target pitch frequencies
//  of the strings", and of moekadu Tuner's `harmonicEnergyContentRelative`.

import Accelerate
import Foundation

struct HarmonicScore {
    /// Where in the search window the score peaked, in Hz.
    ///
    /// Coarse, and deliberately not the tuning readout. Harmonic energy is a
    /// broad, flat-topped function of the candidate frequency, so its argmax is
    /// only accurate to a few tens of cents — measured error against known
    /// detunings averaged 33 cents. The NSDF with parabolic interpolation reads
    /// the same signal to well under one cent, and that is what the display
    /// uses. This scorer answers "which string", not "how far off".
    var frequency: Double
    /// Fraction of in-band spectral energy sitting on this harmonic series, 0…1.
    var energyRatio: Double
    /// Cents from the target the window was centred on. Same coarse caveat.
    var cents: Double
}

final class HarmonicScorer {
    /// The §3 lowpass sits at 1 kHz, so harmonics above it carry little energy.
    static let analysisCeilingHz = 1050.0
    /// Never sum more than this many partials, however low the fundamental.
    static let maxPartials = 10
    /// A partial is looked for within this many bins either side of its ideal
    /// position — enough to absorb bin quantisation and mild string inharmonicity.
    static let binTolerance = 2
    /// Resolution of the search within a string's acceptance window.
    static let searchStepCents = 2.0
    /// A predicted partial counts as present at this share of the strongest one.
    static let presenceFraction = 0.15
    /// A reference point for what "standing out" means, not a decision.
    ///
    /// Measured medians through a modelled phone microphone: guitar 7.2–28.9,
    /// background speech 4.3–5.6, room noise 2.1. This value sits between the
    /// instrument and the room and was, for one build, the single threshold the
    /// whole app turned on.
    ///
    /// It no longer is. Finding a note and following one need different bars —
    /// see `TargetTracker`, which owns both — and collapsing them onto one
    /// number is what made the app let go of decaying notes. Kept because the
    /// distributions above are worth stating somewhere, and because a test
    /// asserting a guitar beats a room needs a number to point at.

    /// Bins per block when estimating the in-frame noise floor. At 5.9 Hz per
    /// bin this is a ~140 Hz neighbourhood — wide enough that a harmonic is a
    /// sparse outlier within it, narrow enough to follow the spectral tilt of
    /// room tone and microphone rolloff.
    static let floorBlockBins = 24
    /// The percentile of each block taken as its noise floor. Low enough to sit
    /// under the harmonics, high enough not to be chasing individual nulls.
    static let floorPercentile = 0.3
    /// How much of the estimated floor is removed. Full subtraction leaves the
    /// residual ragged where the estimate is slightly high; over-subtracting a
    /// little and clamping at zero is the standard remedy.
    static let floorOversubtraction = 1.5

    private let sampleRate: Double
    private let binWidth: Double
    private let bins: Int
    private let spectrum: UnsafeMutablePointer<Float>
    private let totalEnergy: Double

    /// - Parameter detector: must have just run `process`; the spectrum is
    ///   borrowed and is only valid until the next call.
    init(detector: PitchDetector) {
        sampleRate = detector.sampleRate
        binWidth = detector.binWidth
        bins = detector.spectrumBins
        spectrum = detector.whitenedSpectrum

        let lo = max(1, Int(30.0 / binWidth))
        let hi = min(bins - 1, Int(HarmonicScorer.analysisCeilingHz / binWidth))

        HarmonicScorer.whiten(spectrum, from: lo, to: hi)

        // Total energy over the band the pre-filter actually passes. Comparing
        // against the full spectrum would let out-of-band content dilute every
        // score equally and make the measure useless.
        var sum = 0.0
        if hi > lo {
            for i in lo...hi { sum += Double(spectrum[i]) }
        }
        totalEnergy = sum
    }

    /// Removes the in-frame noise floor from the power spectrum, in place.
    ///
    /// Every score here is a ratio against the in-band total, so stationary
    /// noise does not cancel out — it inflates the denominator *and* leaks into
    /// every candidate's partials, lifting the decoys and squashing contrast.
    /// Measured on a decaying note into room tone, contrast fell from 9 to
    /// below the acceptance threshold while the correct string was still being
    /// named on every frame: the evidence was there and the statistic was
    /// hiding it.
    ///
    /// The estimate is taken across frequency within the frame rather than
    /// across time, which matters: a temporal tracker following a note that
    /// rings for six seconds eventually learns the note as noise. Harmonics are
    /// sparse peaks and room tone is smooth, so a low percentile of each
    /// frequency block is a good floor and needs no history at all.
    ///
    /// This is PEFAC's spectral normalisation (Gonzalez & Brookes 2011) reduced
    /// to its causal, in-frame core, and the same move as the spectral
    /// whitening in Klapuri's multipitch front end.
    static func whiten(_ p: UnsafeMutablePointer<Float>, from lo: Int, to hi: Int) {
        guard hi > lo + floorBlockBins else { return }
        let blocks = (hi - lo) / floorBlockBins
        guard blocks >= 2 else { return }

        var floors = [Float](repeating: 0, count: blocks)
        var scratch = [Float](repeating: 0, count: floorBlockBins)
        for b in 0..<blocks {
            let start = lo + b * floorBlockBins
            for i in 0..<floorBlockBins { scratch[i] = p[start + i] }
            scratch.sort()
            floors[b] = scratch[Int(Double(floorBlockBins - 1) * floorPercentile)]
        }

        // Linear interpolation between block centres, so the subtracted floor
        // is continuous rather than a staircase that leaves seams at the joins.
        for b in 0..<blocks {
            let start = lo + b * floorBlockBins
            let here = floors[b]
            let next = floors[Swift.min(b + 1, blocks - 1)]
            let prev = floors[Swift.max(b - 1, 0)]
            for i in 0..<floorBlockBins {
                let u = (Float(i) + 0.5) / Float(floorBlockBins)
                let f = u < 0.5 ? prev + (here - prev) * (u + 0.5)
                                : here + (next - here) * (u - 0.5)
                p[start + i] = Swift.max(0, p[start + i] - f * Float(floorOversubtraction))
            }
        }
        // Tail bins the blocking did not cover keep the last floor.
        let covered = lo + blocks * floorBlockBins
        if covered <= hi {
            let f = floors[blocks - 1] * Float(floorOversubtraction)
            for i in covered...hi { p[i] = Swift.max(0, p[i] - f) }
        }
    }

    /// Energy at one partial: the strongest bin within tolerance of its ideal
    /// position, which absorbs both bin quantisation and slight inharmonicity.
    private func partialEnergy(_ hz: Double) -> Double {
        let centre = hz / binWidth
        let lo = max(0, Int(centre.rounded()) - HarmonicScorer.binTolerance)
        let hi = min(bins - 1, Int(centre.rounded()) + HarmonicScorer.binTolerance)
        guard lo <= hi else { return 0 }
        var best = 0.0
        for i in lo...hi { best = max(best, Double(spectrum[i])) }
        return best
    }

    /// Summed harmonic energy for a candidate fundamental, as a fraction of the
    /// in-band total, multiplied by how many of the predicted partials are
    /// actually present.
    ///
    /// The density term is not optional. Coverage alone always prefers the
    /// lowest candidate, because a lower fundamental's harmonic series contains
    /// a higher one's as a subset: E4 is the fourth harmonic of E2, so the E2
    /// hypothesis captures every partial of an E4 note and then sums extra ones
    /// on top. Measured without the density term, E4 was misassigned to E2 on
    /// 184 frames out of 184. Density asks a question that distinguishes them —
    /// of the partials this hypothesis *predicts*, how many are really there?
    /// For an E4 note the E2 hypothesis predicts ten and finds three.
    func energyRatio(at f0: Double) -> Double {
        guard totalEnergy > 0, f0 > 0 else { return 0 }
        let partials = min(HarmonicScorer.maxPartials,
                           max(1, Int(HarmonicScorer.analysisCeilingHz / f0)))

        var sum = 0.0
        var peaks = [Double](repeating: 0, count: partials)
        for k in 1...partials {
            let e = partialEnergy(f0 * Double(k))
            peaks[k - 1] = e
            sum += e
        }
        guard sum > 0 else { return 0 }

        // A partial counts as present if it carries a non-trivial share of the
        // strongest one. Relative rather than absolute, so this holds up as the
        // note decays.
        let strongest = peaks.max() ?? 0
        let floor = strongest * HarmonicScorer.presenceFraction
        let present = peaks.reduce(into: 0) { $0 += ($1 >= floor ? 1 : 0) }
        let density = Double(present) / Double(partials)

        return min((sum / totalEnergy) * density, 1.0)
    }

    /// Searches a target's acceptance window for the best-fitting fundamental.
    /// - Parameters:
    ///   - target: the string's frequency at the current reference pitch.
    ///   - windowCents: half-width of the search, matching §4's 60-cent rule.
    func score(target: Double, windowCents: Double = 60) -> HarmonicScore {
        var best = HarmonicScore(frequency: target, energyRatio: 0, cents: 0)
        var cents = -windowCents
        while cents <= windowCents {
            let f = target * pow(2, cents / 1200)
            let ratio = energyRatio(at: f)
            if ratio > best.energyRatio {
                best = HarmonicScore(frequency: f, energyRatio: ratio, cents: cents)
            }
            cents += HarmonicScorer.searchStepCents
        }
        return best
    }

    /// Offsets, in cents, at which a decoy is scored. Deliberately far enough
    /// from any real target to be a genuine non-answer, close enough to see the
    /// same spectral neighbourhood.
    private static let decoyOffsetsCents = [-250.0, -150.0, 150.0, 250.0]

    /// How far the best target stands out from frequencies that are *not*
    /// targets.
    ///
    /// The absolute energy ratio turned out not to be comparable across strings
    /// — A2 measured 0.147 against background speech at 0.221, so any fixed
    /// threshold on it rejects the instrument. Contrast is self-normalising:
    /// a real note makes a sharp peak at one specific frequency, while broadband
    /// or mismatched interference raises every hypothesis about equally.
    ///
    /// Measured, median contrast: guitar 7.2–28.9, speech 4.3–5.6, room noise 2.1.
    struct Detection {
        var stringIndex: Int
        var score: HarmonicScore
        var contrast: Double
    }

    func detect(in tuning: Tuning, referenceA: Double) -> Detection? {
        var winner: (Int, HarmonicScore)?
        for (index, midi) in tuning.midiNotes.enumerated() {
            let target = MusicMath.frequency(midi: Double(midi), referenceA: referenceA)
            let s = score(target: target)
            if s.energyRatio > (winner?.1.energyRatio ?? 0) {
                winner = (index, s)
            }
        }
        guard let winner else { return nil }

        var decoys: [Double] = []
        decoys.reserveCapacity(tuning.midiNotes.count * HarmonicScorer.decoyOffsetsCents.count)
        for midi in tuning.midiNotes {
            let target = MusicMath.frequency(midi: Double(midi), referenceA: referenceA)
            for offset in HarmonicScorer.decoyOffsetsCents {
                decoys.append(energyRatio(at: target * pow(2, offset / 1200)))
            }
        }
        decoys.sort()
        let median = decoys.isEmpty ? 0 : decoys[decoys.count / 2]
        let contrast = median > 1e-9 ? winner.1.energyRatio / median : 0

        return Detection(stringIndex: winner.0, score: winner.1, contrast: contrast)
    }
}
