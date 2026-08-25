import Accelerate
import Foundation

/// Offline mirror of `DetectionWorker`'s signal path: hop-by-hop biquad with
/// persistent state, then a sliding window into the detector. Tests must run the
/// same chain the app does or they prove nothing about the app.
enum Harness {
    /// - Parameter gated: run the noise gate and the pitch-stability gate too,
    ///   as `DetectionWorker` does. Off by default so detector-level tests can
    ///   look at raw output; the acceptance tests turn it on.
    static func run(signal: [Float],
                    sampleRate: Double,
                    windowSize: Int,
                    smoothing: ResponseMode? = nil,
                    gated: Bool = false) -> [PitchResult] {
        let hop = windowSize / 4
        let detector = PitchDetector(sampleRate: sampleRate, windowSize: windowSize)
        let filter = Biquad(sampleRate: sampleRate)
        let smoother = smoothing.map { Smoother(mode: $0) }
        let noiseGate = NoiseGate()
        var stability = PitchStability()

        var history = [Float](repeating: 0, count: windowSize)
        var filled = 0
        var results: [PitchResult] = []
        var offset = 0

        while offset + hop <= signal.count {
            var block = Array(signal[offset..<(offset + hop)])
            block.withUnsafeMutableBufferPointer { filter.process($0.baseAddress!, count: hop) }
            offset += hop

            if windowSize > hop {
                history.replaceSubrange(0..<(windowSize - hop), with: history[hop..<windowSize])
            }
            history.replaceSubrange((windowSize - hop)..<windowSize, with: block)
            filled = min(filled + hop, windowSize)
            guard filled >= windowSize else { continue }

            var result = history.withUnsafeBufferPointer { detector.process($0.baseAddress!) }
            if gated {
                let above = noiseGate.update(rms: result.rms,
                                             dt: Double(hop) / sampleRate,
                                             pitchDetected: result.hasPitch)
                result.hasPitch = stability.admit(frequency: result.frequency,
                                                  voiced: result.hasPitch && above)
            }
            if let smoother, result.hasPitch {
                result.frequency = smoother.process(hz: result.frequency,
                                                    dt: Double(hop) / sampleRate)
            }
            results.append(result)
        }
        return results
    }

    /// Sum of harmonics with per-partial amplitudes and phases.
    static func tone(fundamental: Double,
                     amplitudes: [Double],
                     sampleRate: Double,
                     seconds: Double,
                     phases: [Double]? = nil,
                     decay: Double = 0,
                     level: Double = 0.25) -> [Float] {
        let count = Int(sampleRate * seconds)
        var out = [Float](repeating: 0, count: count)
        var rng = SplitMix64(seed: 0x5EED_5EED)
        let ph = phases ?? amplitudes.indices.map { _ in rng.nextUnit() * 2 * Double.pi }
        for n in 0..<count {
            let t = Double(n) / sampleRate
            var value = 0.0
            for (index, amplitude) in amplitudes.enumerated() {
                let partial = Double(index + 1)
                // A partial above Nyquist would alias and invent energy.
                guard fundamental * partial < sampleRate / 2 else { break }
                value += amplitude * sin(2 * Double.pi * fundamental * partial * t + ph[index])
            }
            let envelope = decay > 0 ? exp(-t / decay) : 1.0
            out[n] = Float(value * level * envelope)
        }
        return out
    }

    static func sine(_ frequency: Double, sampleRate: Double, seconds: Double,
                     level: Double = 0.25) -> [Float] {
        tone(fundamental: frequency, amplitudes: [1.0], sampleRate: sampleRate,
             seconds: seconds, phases: [0.0], level: level)
    }

    static func addNoise(_ signal: [Float], level: Double, seed: UInt64 = 12345) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return signal.map { $0 + Float((rng.nextUnit() * 2 - 1) * level) }
    }

    static func cents(_ measured: Double, _ target: Double) -> Double {
        1200 * log2(measured / target)
    }

    /// Median of the stable tail of a run, which is what the display shows once
    /// the window has filled and the smoother has settled.
    static func settled(_ results: [PitchResult]) -> [PitchResult] {
        let voiced = results.filter(\.hasPitch)
        guard voiced.count > 4 else { return voiced }
        return Array(voiced.dropFirst(voiced.count / 3))
    }
}

/// Deterministic RNG — a test that fails one run in fifty is not a test.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
