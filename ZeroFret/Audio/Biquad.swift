//  Biquad.swift
//  Zero Fret
//
//  The §3 pre-filter: 2nd-order Butterworth highpass at 40 Hz followed by a
//  2nd-order Butterworth lowpass at 1000 Hz, run as a single two-section
//  `vDSP_biquad` cascade.
//
//  Both corners are load-bearing:
//    - 40 Hz kills handling noise and HVAC rumble. Raising it past ~45 Hz starts
//      eating E2's 82 Hz fundamental.
//    - 1000 Hz is the octave-error fix. MPM degrades when upper harmonics
//      dominate, which is exactly a bright new string.
//
//  Filter state lives in `delay` and persists across hops, so audio must be fed
//  through in contiguous order, hop by hop — never window by window, or every
//  overlapped sample would be filtered twice from a stale state.

import Accelerate

final class Biquad {
    /// Butterworth (maximally flat) — Q for a 2nd-order section.
    private static let q = 0.7071067811865476

    private let setup: vDSP_biquad_Setup
    private let sectionCount = 2
    private var delay: [Float]

    let sampleRate: Double

    init(sampleRate: Double, highpassHz: Double = 40.0, lowpassHz: Double = 1000.0) {
        self.sampleRate = sampleRate

        var coefficients = [Double]()
        coefficients.append(contentsOf: Biquad.highpass(fc: highpassHz, fs: sampleRate))
        coefficients.append(contentsOf: Biquad.lowpass(fc: lowpassHz, fs: sampleRate))

        guard let setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(sectionCount)) else {
            fatalError("vDSP_biquad_CreateSetup failed for fs=\(sampleRate)")
        }
        self.setup = setup
        // vDSP requires 2 * sections + 2 delay elements, zeroed.
        delay = [Float](repeating: 0, count: 2 * sectionCount + 2)
    }

    deinit { vDSP_biquad_DestroySetup(setup) }

    /// Filters `count` frames in place, carrying state forward.
    func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        delay.withUnsafeMutableBufferPointer { d in
            vDSP_biquad(setup, d.baseAddress!, buffer, 1, buffer, 1, vDSP_Length(count))
        }
    }

    /// Zeroes the delay line. Called on route changes and when the engine
    /// restarts, so a stale tail cannot leak into the first window.
    func reset() {
        for i in delay.indices { delay[i] = 0 }
    }

    // MARK: - RBJ cookbook coefficients, normalised to a0 = 1
    //
    // vDSP_biquad expects [b0, b1, b2, a1, a2] per section and evaluates
    //     H(z) = (b0 + b1 z^-1 + b2 z^-2) / (1 + a1 z^-1 + a2 z^-2)

    private static func highpass(fc: Double, fs: Double) -> [Double] {
        let w0 = 2 * Double.pi * fc / fs
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return [
            ((1 + cosw) / 2) / a0,
            (-(1 + cosw)) / a0,
            ((1 + cosw) / 2) / a0,
            (-2 * cosw) / a0,
            (1 - alpha) / a0,
        ]
    }

    private static func lowpass(fc: Double, fs: Double) -> [Double] {
        let w0 = 2 * Double.pi * fc / fs
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return [
            ((1 - cosw) / 2) / a0,
            (1 - cosw) / a0,
            ((1 - cosw) / 2) / a0,
            (-2 * cosw) / a0,
            (1 - alpha) / a0,
        ]
    }
}
