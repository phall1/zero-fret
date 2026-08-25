//  PitchDetector.swift
//  Zero Fret
//
//  McLeod Pitch Method: normalised square difference function, FFT-accelerated
//  autocorrelation, first-peak-above-threshold selection, parabolic refinement.
//  Spec §3.
//
//  The three things here that are not negotiable:
//    1. The candidate is the FIRST peak at or above k·maxVal, not the global
//       maximum. The global maximum sits at 2τ or 3τ often enough that naive
//       tuners read low E as E3.
//    2. m(τ) is accumulated incrementally, not recomputed per lag. Recomputing
//       is O(N²) and blows the frame budget.
//    3. Parabolic interpolation is mandatory. Integer τ gives a ~6¢ resolution
//       floor at E4 and the readout visibly quantises.

import Accelerate
import Foundation

struct PitchResult {
    var frequency: Double
    var clarity: Double
    var rms: Double
    /// True when a candidate cleared the clarity floor. RMS gating happens
    /// upstream in `DetectionWorker`, which owns the noise floor.
    var hasPitch: Bool

    static let none = PitchResult(frequency: 0, clarity: 0, rms: 0, hasPitch: false)
}

final class PitchDetector {
    /// §3: "Select the first candidate whose value >= k · maxVal, with k = 0.9."
    /// Below 0.8 gives subharmonic errors; above 0.95 degenerates to global-max.
    static let peakThresholdRatio: Float = 0.9

    /// §3 clarity gate.
    static let clarityFloor: Double = 0.60

    /// Bracket of periods we are willing to report. 25 Hz sits below a 5-string
    /// bass B0 (30.87 Hz); 1300 Hz is comfortably above anything that survives
    /// the 1 kHz lowpass.
    static let minFrequency: Double = 25.0
    static let maxFrequency: Double = 1300.0

    let sampleRate: Double
    let windowSize: Int

    let tauMin: Int
    let tauMax: Int

    private let fftLength: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    // Preallocated once. Nothing in `process` allocates — acceptance test 11
    // watches for allocation growth over a five-minute Instruments run.
    private let inRe: UnsafeMutablePointer<Float>
    private let inIm: UnsafeMutablePointer<Float>
    private let outRe: UnsafeMutablePointer<Float>
    private let outIm: UnsafeMutablePointer<Float>
    private let squares: UnsafeMutablePointer<Float>
    private let nsdf: UnsafeMutablePointer<Float>

    private static let maxCandidates = 512
    private var candidateTau = [Int](repeating: 0, count: maxCandidates)
    private var candidateVal = [Float](repeating: 0, count: maxCandidates)

    init(sampleRate: Double, windowSize: Int) {
        precondition(windowSize > 0 && windowSize & (windowSize - 1) == 0,
                     "windowSize must be a power of two")
        self.sampleRate = sampleRate
        self.windowSize = windowSize

        // Zero-pad to 2N so the circular correlation the FFT gives us equals the
        // linear autocorrelation for every lag we care about (0...N).
        fftLength = windowSize * 2
        log2n = vDSP_Length(log2(Double(fftLength)).rounded())

        // Deliberately the C API rather than `vDSP.FFT<DSPSplitComplex>`.
        // The Swift wrapper's split-complex specialisation is the *real-packed*
        // transform (zrop): it reads realp/imagp as the even/odd interleave of a
        // real signal, not as a complex sequence. Handing it a real signal with a
        // zeroed imaginary part compiles, runs, and silently autocorrelates a
        // different signal — the error is zero at τ=0 and grows with τ, so the
        // detector lands on a lag two or three periods long and reports ~27 Hz.
        // `vDSP_fft_zop` is unambiguously complex-to-complex; verified against a
        // direct O(N²) autocorrelation to 2e-7 relative error.
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed for log2n=\(log2n)")
        }
        fftSetup = setup

        inRe = .allocate(capacity: fftLength); inRe.initialize(repeating: 0, count: fftLength)
        inIm = .allocate(capacity: fftLength); inIm.initialize(repeating: 0, count: fftLength)
        outRe = .allocate(capacity: fftLength); outRe.initialize(repeating: 0, count: fftLength)
        outIm = .allocate(capacity: fftLength); outIm.initialize(repeating: 0, count: fftLength)
        squares = .allocate(capacity: windowSize); squares.initialize(repeating: 0, count: windowSize)
        nsdf = .allocate(capacity: windowSize + 2); nsdf.initialize(repeating: 0, count: windowSize + 2)

        let loTau = Int((sampleRate / PitchDetector.maxFrequency).rounded(.down))
        let hiTau = Int((sampleRate / PitchDetector.minFrequency).rounded(.up))
        tauMin = max(2, loTau)
        // Beyond N/2 the NSDF overlap is under half the window and the estimate
        // stops being trustworthy.
        tauMax = min(windowSize / 2, max(tauMin + 2, hiTau))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        inRe.deallocate(); inIm.deallocate()
        outRe.deallocate(); outIm.deallocate()
        squares.deallocate(); nsdf.deallocate()
    }

    /// - Parameter window: exactly `windowSize` pre-filtered frames.
    func process(_ window: UnsafePointer<Float>) -> PitchResult {
        let n = windowSize

        // --- RMS, and the running power sum m(0)/2 -------------------------
        var meanSquare: Float = 0
        vDSP_measqv(window, 1, &meanSquare, vDSP_Length(n))
        let rms = Double(sqrt(meanSquare))
        vDSP_vsq(window, 1, squares, 1, vDSP_Length(n))
        var sumSquares: Float = 0
        vDSP_sve(squares, 1, &sumSquares, vDSP_Length(n))
        guard sumSquares > 0, rms.isFinite else {
            return PitchResult(frequency: 0, clarity: 0, rms: rms.isFinite ? rms : 0, hasPitch: false)
        }

        // --- r(τ) via FFT --------------------------------------------------
        // r = IFFT(|FFT(x_padded)|²). Real input, imaginary zero. A full complex
        // transform costs twice a packed real one and buys immunity to the
        // DC/Nyquist packing trap, at well under 100 µs for N=4096.
        memcpy(inRe, window, n * MemoryLayout<Float>.size)
        memset(inRe + n, 0, n * MemoryLayout<Float>.size)
        memset(inIm, 0, fftLength * MemoryLayout<Float>.size)

        var input = DSPSplitComplex(realp: inRe, imagp: inIm)
        var output = DSPSplitComplex(realp: outRe, imagp: outIm)
        vDSP_fft_zop(fftSetup, &input, 1, &output, 1, log2n, FFTDirection(FFT_FORWARD))

        // |X|² back into the input buffers for the inverse pass.
        vDSP_zvmags(&output, 1, inRe, 1, vDSP_Length(fftLength))
        memset(inIm, 0, fftLength * MemoryLayout<Float>.size)
        input = DSPSplitComplex(realp: inRe, imagp: inIm)
        vDSP_fft_zop(fftSetup, &input, 1, &output, 1, log2n, FFTDirection(FFT_INVERSE))

        // vDSP's forward/inverse pair is unnormalised, and the exact factor
        // varies with radix and length. Rather than hardcode it, recover it:
        // r(0) is Σx² by definition, so scale = Σx² / rRaw(0). This also makes
        // n'(0) exactly 1, which is the identity the NSDF is defined to have.
        let rZero = outRe[0]
        guard rZero > 0, rZero.isFinite else {
            return PitchResult(frequency: 0, clarity: 0, rms: rms, hasPitch: false)
        }
        let scale = sumSquares / rZero

        // --- m(τ) incrementally --------------------------------------------
        // m(τ) = Σ_{j=0}^{N-1-τ} (x[j]² + x[j+τ]²)
        //      = m(τ-1) − x[N-τ]² − x[τ-1]²,  with m(0) = 2Σx².
        var m = 2 * sumSquares
        nsdf[0] = 1
        var tau = 1
        while tau <= tauMax + 1 {
            m -= squares[n - tau] + squares[tau - 1]
            nsdf[tau] = m > 1e-20 ? (2 * outRe[tau] * scale) / m : 0
            tau += 1
        }

        // --- Peak picking ----------------------------------------------------
        let candidates = collectCandidates()
        guard candidates > 0 else {
            return PitchResult(frequency: 0, clarity: 0, rms: rms, hasPitch: false)
        }

        var maxVal: Float = 0
        for i in 0..<candidates where candidateVal[i] > maxVal { maxVal = candidateVal[i] }
        guard maxVal > 0 else {
            return PitchResult(frequency: 0, clarity: 0, rms: rms, hasPitch: false)
        }

        // The whole trick: FIRST candidate over the bar, not the biggest one.
        let bar = PitchDetector.peakThresholdRatio * maxVal
        var chosen = -1
        for i in 0..<candidates where candidateVal[i] >= bar { chosen = candidateTau[i]; break }
        guard chosen > 0 else {
            return PitchResult(frequency: 0, clarity: 0, rms: rms, hasPitch: false)
        }

        // --- Parabolic interpolation ----------------------------------------
        let y0 = Double(nsdf[chosen - 1])
        let y1 = Double(nsdf[chosen])
        let y2 = Double(nsdf[chosen + 1])
        let curvature = y0 - 2 * y1 + y2
        var delta = 0.0
        if abs(curvature) > 1e-12 {
            delta = 0.5 * (y0 - y2) / curvature
        }
        delta = min(max(delta, -1), 1)

        let tauInterpolated = Double(chosen) + delta
        guard tauInterpolated >= 1 else {
            return PitchResult(frequency: 0, clarity: 0, rms: rms, hasPitch: false)
        }

        let clarity = min(max(y1 - 0.25 * (y0 - y2) * delta, 0), 1)
        let frequency = sampleRate / tauInterpolated

        let believable = clarity >= PitchDetector.clarityFloor
            && frequency >= PitchDetector.minFrequency
            && frequency <= PitchDetector.maxFrequency

        return PitchResult(frequency: frequency, clarity: clarity, rms: rms, hasPitch: believable)
    }

    /// §3 steps 1–2: the maximum of n'(τ) between each pair of consecutive
    /// positively-sloped zero crossings. Returns the candidate count; results
    /// land in `candidateTau` / `candidateVal`.
    private func collectCandidates() -> Int {
        var count = 0
        var tau = tauMin

        // n'(τ) starts near 1, so step off the initial positive lobe first...
        while tau <= tauMax, nsdf[tau] > 0 { tau += 1 }
        // ...then across the negative region to the first positively-sloped crossing.
        while tau <= tauMax, nsdf[tau] <= 0 { tau += 1 }

        while tau <= tauMax {
            var bestTau = tau
            var bestVal = nsdf[tau]
            while tau <= tauMax, nsdf[tau] > 0 {
                if nsdf[tau] > bestVal { bestVal = nsdf[tau]; bestTau = tau }
                tau += 1
            }
            if count < PitchDetector.maxCandidates {
                candidateTau[count] = bestTau
                candidateVal[count] = bestVal
                count += 1
            } else {
                break
            }
            while tau <= tauMax, nsdf[tau] <= 0 { tau += 1 }
        }
        return count
    }

    // MARK: - Spectrum reuse
    //
    // `process` computes |X|² into `inRe` on its way to the autocorrelation, and
    // the inverse pass only reads it. So the power spectrum of the most recent
    // frame is still sitting there afterwards, and harmonic scoring can use it
    // without paying for a second FFT.

    /// Power spectrum of the most recent `process` call. Valid until the next one.
    var powerSpectrum: UnsafePointer<Float> { UnsafePointer(inRe) }
    /// Usable bins: the spectrum is symmetric, so only the first half is meaningful.
    var spectrumBins: Int { fftLength / 2 }
    /// Hz per bin.
    var binWidth: Double { sampleRate / Double(fftLength) }

    /// Exposed for tests: the raw NSDF of the most recent `process` call.
    func nsdfSnapshot() -> [Float] {
        Array(UnsafeBufferPointer(start: nsdf, count: tauMax + 2))
    }
}
