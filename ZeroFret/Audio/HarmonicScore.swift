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
    /// Below this the winning target does not stand out from frequencies that
    /// are not targets at all. Measured medians through a modelled phone
    /// microphone: guitar 7.2–28.9, background speech 4.3–5.6, room noise 2.1.
    static let minimumContrast = 4.5

    private let sampleRate: Double
    private let binWidth: Double
    private let bins: Int
    private let spectrum: UnsafePointer<Float>
    private let totalEnergy: Double

    /// - Parameter detector: must have just run `process`; the spectrum is
    ///   borrowed and is only valid until the next call.
    init(detector: PitchDetector) {
        sampleRate = detector.sampleRate
        binWidth = detector.binWidth
        bins = detector.spectrumBins
        spectrum = detector.powerSpectrum

        // Total energy over the band the pre-filter actually passes. Comparing
        // against the full spectrum would let out-of-band content dilute every
        // score equally and make the measure useless.
        let lo = max(1, Int(30.0 / binWidth))
        let hi = min(bins - 1, Int(HarmonicScorer.analysisCeilingHz / binWidth))
        var sum = 0.0
        if hi > lo {
            for i in lo...hi { sum += Double(spectrum[i]) }
        }
        totalEnergy = sum
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
