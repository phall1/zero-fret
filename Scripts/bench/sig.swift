import Foundation

let fs = 48000.0

struct RNG {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func u() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func sym() -> Double { u() * 2 - 1 }
    mutating func gauss() -> Double {
        let a = max(u(), 1e-12), b = u()
        return (-2 * log(a)).squareRoot() * cos(2 * .pi * b)
    }
}

/// Two cascaded first-order highpasses: the iPhone mic's low-frequency rolloff.
func micResponse(_ x: [Float], fc: Double = 150) -> [Float] {
    let rc = 1.0 / (2 * .pi * fc), dt = 1.0 / fs
    let a = rc / (rc + dt)
    var y = x
    for _ in 0..<2 {
        var px = 0.0, py = 0.0
        for i in 0..<y.count {
            let xi = Double(y[i]); let yi = a * (py + xi - px)
            y[i] = Float(yi); px = xi; py = yi
        }
    }
    return y
}

func rmsDBFS(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return -200 }
    var s = 0.0
    for v in x { s += Double(v) * Double(v) }
    return 20 * log10(max((s / Double(x.count)).squareRoot(), 1e-12))
}

/// Scale a signal so its RMS over the first 0.5 s equals `dbfs`.
func normalise(_ x: [Float], to dbfs: Double) -> [Float] {
    let n = min(x.count, Int(fs * 0.5))
    let cur = rmsDBFS(x[0..<n])
    let g = Float(pow(10, (dbfs - cur) / 20))
    return x.map { $0 * g }
}

/// An unplugged solid-body electric as a phone hears it: no soundboard, no
/// cavity, a dipole radiator that collapses at low frequency. The fundamental
/// is essentially absent; the upper partials carry the note.
func unplugged(_ f0: Double, seconds: Double = 6, seed: UInt64 = 1) -> [Float] {
    var rng = RNG(s: seed)
    let amps: [Double] = [0.03, 0.35, 0.85, 1.0, 0.80, 0.62, 0.45, 0.30, 0.20, 0.12]
    let ph = amps.map { _ in rng.u() * 2 * .pi }
    let n = Int(fs * seconds)
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / fs
        var v = 0.0
        for (k, a) in amps.enumerated() {
            let pf = f0 * Double(k + 1)
            if pf >= fs / 2 { break }
            v += a * exp(-t / (3.0 / (1.0 + 0.35 * Double(k)))) * sin(2 * .pi * pf * t + ph[k])
        }
        if t < 0.010 { v += 0.5 * rng.sym() * exp(-t / 0.003) }
        out[i] = Float(v)
    }
    return micResponse(out)
}

/// A steel-string acoustic: strong fundamental, the other strings ringing
/// sympathetically, a pick transient.
func acoustic(_ f0: Double, sympathetic: [Double] = [], seconds: Double = 6, seed: UInt64 = 2) -> [Float] {
    var rng = RNG(s: seed)
    let amps: [Double] = [0.55, 1.0, 0.72, 0.50, 0.34, 0.24, 0.16, 0.11, 0.07, 0.05]
    let ph = amps.map { _ in rng.u() * 2 * .pi }
    let sph = sympathetic.map { _ in rng.u() * 2 * .pi }
    let n = Int(fs * seconds)
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / fs
        var v = 0.0
        for (k, a) in amps.enumerated() {
            let pf = f0 * Double(k + 1)
            if pf >= fs / 2 { break }
            v += a * exp(-t / (2.2 / (1.0 + 0.6 * Double(k)))) * sin(2 * .pi * pf * t + ph[k])
        }
        for (j, sf) in sympathetic.enumerated() {
            v += 0.06 * exp(-t / 4.8) * sin(2 * .pi * sf * t + sph[j])
            v += 0.024 * exp(-t / 3.5) * sin(2 * .pi * sf * 2 * t + sph[j])
        }
        if t < 0.012 { v += 0.8 * rng.sym() * exp(-t / 0.004) }
        out[i] = Float(v)
    }
    return micResponse(out)
}

/// Voiced speech: a glottal pulse train that glides. More periodic than a
/// plucked string, which is why clarity cannot separate them.
func speech(seconds: Double, basePitch: Double = 130, seed: UInt64 = 7) -> [Float] {
    var rng = RNG(s: seed)
    let n = Int(fs * seconds)
    var out = [Float](repeating: 0, count: n)
    var phase = 0.0, f0 = basePitch, target = basePitch
    var voiced = true, segLeft = 0
    for i in 0..<n {
        if segLeft <= 0 {
            segLeft = Int(fs * (0.08 + 0.22 * rng.u()))
            target = basePitch * pow(2.0, (rng.sym() * 5.0) / 12.0)
            voiced = rng.u() > 0.25
        }
        segLeft -= 1
        f0 += (target - f0) * 0.0008
        phase += 2 * .pi * f0 / fs
        if phase > 2 * .pi { phase -= 2 * .pi }
        var v = 0.0
        if voiced {
            for k in 1...12 { v += (1.0 / Double(k)) * sin(phase * Double(k)) }
            v *= 0.35
        } else {
            v = 0.5 * rng.gauss()
        }
        out[i] = Float(v)
    }
    return out
}

/// Room tone: pink-ish broadband with a little hum.
func room(seconds: Double, seed: UInt64 = 11) -> [Float] {
    var rng = RNG(s: seed)
    let n = Int(fs * seconds)
    var out = [Float](repeating: 0, count: n)
    var b0 = 0.0, b1 = 0.0, b2 = 0.0
    for i in 0..<n {
        let w = rng.gauss()
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        var v = (b0 + b1 + b2 + w * 0.1848) * 0.2
        let t = Double(i) / fs
        v += 0.08 * sin(2 * .pi * 60 * t) + 0.04 * sin(2 * .pi * 120 * t)
        out[i] = Float(v)
    }
    return micResponse(out)
}

func mix(_ parts: [Float]...) -> [Float] {
    let n = parts.map(\.count).max() ?? 0
    var o = [Float](repeating: 0, count: n)
    for p in parts { for i in 0..<p.count { o[i] += p[i] } }
    return o
}

/// A peg turn: the pitch slides from `fromCents` to `toCents` relative to `f0`
/// over `over` seconds and then holds, which is what a tuner is actually asked
/// to follow. §5's Fast mode exists for this.
///
/// Not a two-semitone bend. That was the first version of this scenario and it
/// was a bad test twice over: it landed on a pitch no string sits near, so the
/// harmonic scorer could not help and the row measured an octave error at high
/// coverage — and the ground truth was left unset, so nothing checked.
func pegTurn(_ f0: Double, fromCents: Double = -60, toCents: Double = 0,
             over: Double = 2, seconds: Double = 5, seed: UInt64 = 21) -> [Float] {
    var rng = RNG(s: seed)
    let amps: [Double] = [0.55, 1.0, 0.72, 0.50, 0.34, 0.24, 0.16, 0.11]
    var phases = amps.map { _ in rng.u() * 2 * .pi }
    let n = Int(fs * seconds)
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / fs
        let u = Swift.min(1, t / over)
        let f = f0 * pow(2, (fromCents + (toCents - fromCents) * u) / 1200)
        var v = 0.0
        for (k, a) in amps.enumerated() {
            let pf = f * Double(k + 1)
            if pf >= fs / 2 { break }
            phases[k] += 2 * .pi * pf / fs
            v += a * exp(-t / (2.8 / (1.0 + 0.6 * Double(k)))) * sin(phases[k])
        }
        if t < 0.012 { v += 0.8 * rng.sym() * exp(-t / 0.004) }
        out[i] = Float(v)
    }
    return micResponse(out)
}
