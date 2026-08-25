//  Smoother.swift
//  Zero Fret
//
//  Spec §5. Median-of-5 into a one-euro filter, operating on frequency in Hz.
//
//  Order matters. The median goes first because a surviving octave error looks
//  like exactly one wild frame, and a median deletes it while a mean averages it
//  in. The one-euro filter goes second because it is the thing that makes the
//  readout feel alive under a bend and still without one.

import Foundation

enum ResponseMode: String, CaseIterable, Identifiable, Codable {
    case fast
    case steady
    case auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .steady: return "Steady"
        case .auto: return "Auto"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Tracks bends. Lets you hear and see the string settle."
        case .steady: return "Heavier averaging for a noisy stage."
        case .auto: return "Fast while the pitch is moving, Steady once it stops."
        }
    }
}

/// §5 coefficient table.
struct OneEuroParameters {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double

    static let fast = OneEuroParameters(minCutoff: 4.0, beta: 0.05, dCutoff: 1.0)
    static let steady = OneEuroParameters(minCutoff: 1.0, beta: 0.007, dCutoff: 1.0)
}

/// Classic 1€ filter (Casiez, Roussel, Vogel 2012).
struct OneEuroFilter {
    var parameters: OneEuroParameters
    private var xPrev: Double = 0
    private var dxHat: Double = 0
    private var primed = false

    init(parameters: OneEuroParameters) { self.parameters = parameters }

    mutating func reset() {
        primed = false
        dxHat = 0
        xPrev = 0
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    mutating func filter(_ x: Double, dt: Double) -> Double {
        guard dt > 0 else { return primed ? xPrev : x }
        guard primed else {
            primed = true
            xPrev = x
            dxHat = 0
            return x
        }
        let dx = (x - xPrev) / dt
        dxHat += OneEuroFilter.alpha(cutoff: parameters.dCutoff, dt: dt) * (dx - dxHat)
        let cutoff = parameters.minCutoff + parameters.beta * abs(dxHat)
        let a = OneEuroFilter.alpha(cutoff: cutoff, dt: dt)
        let value = xPrev + a * (x - xPrev)
        xPrev = value
        return value
    }
}

/// Median of the last five samples. Fixed storage, no allocation per frame.
///
/// Ordering within the window is irrelevant to a median, so the ring is read as
/// a flat slice rather than un-rotated.
struct Median5 {
    private var buffer = [Double](repeating: 0, count: 5)
    private var scratch = [Double](repeating: 0, count: 5)
    private var count = 0
    private var next = 0

    mutating func reset() { count = 0; next = 0 }

    mutating func push(_ value: Double) -> Double {
        buffer[next] = value
        next = (next + 1) % 5
        if count < 5 { count += 1 }

        // Insertion sort over at most five elements, in preallocated storage.
        for i in 0..<count {
            let v = buffer[i]
            var j = i - 1
            while j >= 0, scratch[j] > v {
                scratch[j + 1] = scratch[j]
                j -= 1
            }
            scratch[j + 1] = v
        }
        return scratch[count / 2]
    }
}

/// The full §5 chain, plus the Auto-mode state machine.
final class Smoother {
    /// §5: Auto flips to Fast when |Δcents| exceeds this for `fastFrames` frames.
    private static let motionCentsThreshold = 15.0
    private static let fastFrames = 2
    private static let settleSeconds = 1.0

    var mode: ResponseMode {
        didSet { if mode != oldValue { applyMode() } }
    }

    private var median = Median5()
    private var euro = OneEuroFilter(parameters: .fast)
    private var lastRawHz: Double?
    private var lastOutputHz: Double = 0
    private var movingFrames = 0
    private var calmSeconds = 0.0
    private(set) var autoIsFast = true

    init(mode: ResponseMode = .fast) {
        self.mode = mode
        applyMode()
    }

    func reset() {
        median.reset()
        euro.reset()
        lastRawHz = nil
        lastOutputHz = 0
        movingFrames = 0
        calmSeconds = 0
        autoIsFast = true
        applyMode()
    }

    private func applyMode() {
        switch mode {
        case .fast: euro.parameters = .fast
        case .steady: euro.parameters = .steady
        case .auto: euro.parameters = autoIsFast ? .fast : .steady
        }
    }

    /// - Parameters:
    ///   - hz: raw detector output.
    ///   - dt: seconds since the previous accepted frame.
    /// - Returns: smoothed frequency in Hz.
    func process(hz: Double, dt: Double) -> Double {
        let median = self.median.push(hz)

        if mode == .auto {
            updateAuto(rawHz: hz, dt: dt)
        }

        lastOutputHz = euro.filter(median, dt: dt)
        lastRawHz = hz
        return lastOutputHz
    }

    private func updateAuto(rawHz: Double, dt: Double) {
        if let previous = lastRawHz, previous > 0, rawHz > 0 {
            let deltaCents = abs(1200 * log2(rawHz / previous))
            if deltaCents > Smoother.motionCentsThreshold {
                movingFrames += 1
                calmSeconds = 0
                if movingFrames >= Smoother.fastFrames, !autoIsFast {
                    autoIsFast = true
                    euro.parameters = .fast
                }
            } else {
                movingFrames = 0
                calmSeconds += dt
                if calmSeconds >= Smoother.settleSeconds, autoIsFast {
                    autoIsFast = false
                    euro.parameters = .steady
                }
            }
        }
    }
}
