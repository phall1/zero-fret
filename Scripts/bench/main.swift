import Foundation

// A pedal tuner's job, stated as measurements:
//   lock    ms from note onset to the first reading shown
//   sharp   ms until the reading is within 3 cents and stays there
//   hold    ms from onset to the last frame still tracking
//   cov     % of the note's life with a reading on screen
//   str     % of readings naming the right string
//   err     median |cents| from truth
//   jit     median frame-to-frame movement in cents — the visible wobble
// and, separately, the number of readings produced when nothing is played.

struct Frame {
    var t: Double
    var voiced: Bool
    var hz: Double
    var string: Int?
    var contrast: Double
    var rmsDB: Double
}

func chain(_ signal: [Float], windowSize: Int = 4096, tuning: Tuning) -> [Frame] {
    let hop = windowSize / 4
    let det = PitchDetector(sampleRate: fs, windowSize: windowSize)
    let filt = Biquad(sampleRate: fs)
    let smoother = Smoother(mode: .fast)
    let assigner = StringAssigner()
    var tracker = TargetTracker()
    var hist = [Float](repeating: 0, count: windowSize)
    var filled = 0, off = 0
    var out: [Frame] = []
    let hopSec = Double(hop) / fs
    while off + hop <= signal.count {
        var blk = Array(signal[off..<(off + hop)]); off += hop
        blk.withUnsafeMutableBufferPointer { filt.process($0.baseAddress!, count: hop) }
        if windowSize > hop { hist.replaceSubrange(0..<(windowSize - hop), with: hist[hop..<windowSize]) }
        hist.replaceSubrange((windowSize - hop)..<windowSize, with: blk)
        filled = min(filled + hop, windowSize)
        if filled < windowSize { continue }
        _ = hist.withUnsafeBufferPointer { det.analyse($0.baseAddress!) }
        let sc = HarmonicScorer(detector: det)
        let scored = sc.detect(in: tuning, referenceA: 440)
        let r = tracker.read(from: det, proposedBy: scored)
        let decision = tracker.update(pitch: r, detection: scored) { i in
            MusicMath.frequency(midi: Double(tuning.midiNotes[i]), referenceA: 440)
        }
        var f = Frame(t: Double(off) / fs, voiced: false, hz: 0, string: nil,
                      contrast: scored?.contrast ?? 0, rmsDB: NoiseGate.decibels(r.rms))
        if decision.voiced {
            let sm = smoother.process(hz: decision.frequency, dt: hopSec)
            let t = assigner.target(frequency: sm, tuning: tuning, referenceA: 440,
                                    suggested: decision.string)
            f.voiced = true; f.hz = sm; f.string = t.stringIndex
        } else {
            smoother.reset()
        }
        out.append(f)
    }
    return out
}

struct Metrics {
    var lockMS = Double.nan
    var sharpMS = Double.nan
    var holdMS = 0.0
    var coverage = 0.0
    var stringPct = 0.0
    var errP50 = Double.nan
    var jitter = Double.nan
    var voicedCount = 0
    var total = 0
}

func measure(_ frames: [Frame], truth: Double, string: Int?) -> Metrics {
    var m = Metrics()
    m.total = frames.count
    let voiced = frames.filter(\.voiced)
    m.voicedCount = voiced.count
    guard !frames.isEmpty else { return m }
    m.coverage = 100.0 * Double(voiced.count) / Double(frames.count)
    if let first = voiced.first { m.lockMS = first.t * 1000 }
    if let last = voiced.last { m.holdMS = last.t * 1000 }
    if let s = string, !voiced.isEmpty {
        m.stringPct = 100.0 * Double(voiced.filter { $0.string == s }.count) / Double(voiced.count)
    }
    guard truth > 0, !voiced.isEmpty else { return m }
    let cents = voiced.map { 1200 * log2($0.hz / truth) }
    let abs50 = cents.map { Swift.abs($0) }.sorted()
    m.errP50 = abs50[abs50.count / 2]

    // First moment the reading is within 3 cents and stays there for 5 frames.
    for i in 0..<voiced.count {
        let run = voiced[i..<min(i + 5, voiced.count)]
        if run.count == 5 && run.allSatisfy({ Swift.abs(1200 * log2($0.hz / truth)) <= 3 }) {
            m.sharpMS = voiced[i].t * 1000
            break
        }
    }
    if cents.count > 1 {
        var d: [Double] = []
        for i in 1..<voiced.count where voiced[i].t - voiced[i-1].t < 0.05 {
            d.append(Swift.abs(cents[i] - cents[i-1]))
        }
        if !d.isEmpty { d.sort(); m.jitter = d[d.count / 2] }
    }
    return m
}

func f(_ x: Double, _ w: Int, _ p: Int = 0) -> String {
    if x.isNaN { return String(repeating: " ", count: w - 1) + "—" }
    return String(format: "%\(w).\(p)f", x)
}

let std = TuningLibrary.standard
func hz(_ m: Int) -> Double { MusicMath.frequency(midi: Double(m), referenceA: 440) }

print("SIGNAL                        lvl   lock  sharp   hold   cov%   str%   err   jit")
print(String(repeating: "-", count: 78))

func row(_ name: String, _ sig: [Float], truth: Double, string: Int?, level: Double) {
    let m = measure(chain(sig, tuning: std), truth: truth, string: string)
    print(String(format: "%-28@ %5.0f  %@  %@  %@  %@  %@  %@  %@",
                 name as NSString, level,
                 f(m.lockMS, 5), f(m.sharpMS, 6), f(m.holdMS, 6),
                 f(m.coverage, 6, 1), f(m.stringPct, 6, 1), f(m.errP50, 5, 1), f(m.jitter, 5, 1)))
}

// ---- the low-sensitivity sweep: an unplugged electric, quieter and quieter ----
let levels: [Double] = [-45, -55, -63, -70, -78, -85, -92]
for (idx, midi) in [40, 45, 59, 64].enumerated() {
    let names = ["unplugged E2", "unplugged A2", "unplugged B3", "unplugged E4"]
    let strIdx = [0, 1, 4, 5][idx]
    for lv in levels {
        let s = normalise(unplugged(hz(midi)), to: lv)
        row(names[idx], s, truth: hz(midi), string: strIdx, level: lv)
    }
    print()
}

// ---- quiet instrument in a live room ----
print("SIGNAL                        lvl   lock  sharp   hold   cov%   str%   err   jit")
print(String(repeating: "-", count: 78))
for lv in [-55.0, -63, -70, -78] {
    let s = mix(normalise(unplugged(hz(40)), to: lv), normalise(room(seconds: 6), to: -72))
    row("E2 + room -72", s, truth: hz(40), string: 0, level: lv)
}
for lv in [-55.0, -63, -70] {
    let s = mix(normalise(unplugged(hz(40)), to: lv), normalise(speech(seconds: 6), to: -60))
    row("E2 + speech -60", s, truth: hz(40), string: 0, level: lv)
}
print()

// ---- a peg turn: §5's Fast mode has to follow this ----
for (name, midi, str) in [("peg turn E2", 40, 0), ("peg turn A2", 45, 1),
                          ("peg turn G3", 55, 3), ("peg turn E4", 64, 5)] {
    let s = normalise(pegTurn(hz(midi), fromCents: -60, toCents: 0), to: -50)
    row(name, s, truth: hz(midi), string: str, level: -50)
}
print()

// ---- acoustic, for regression ----
for lv in [-30.0, -45, -60, -72] {
    let s = normalise(acoustic(hz(40), sympathetic: [hz(45), hz(50), hz(55)]), to: lv)
    row("acoustic E2", s, truth: hz(40), string: 0, level: lv)
}
print()

// ---- false positives: nothing is being played ----
print("QUIET SCENARIO                 lvl   voiced/total")
print(String(repeating: "-", count: 46))
func quiet(_ name: String, _ sig: [Float], _ lv: Double) {
    let m = measure(chain(sig, tuning: std), truth: 0, string: nil)
    print(String(format: "%-29@ %4.0f   %3d/%3d", name as NSString, lv, m.voicedCount, m.total))
}
for lv in [-40.0, -55, -70] { quiet("room tone", normalise(room(seconds: 8), to: lv), lv) }
for lv in [-30.0, -45, -60] { quiet("speech", normalise(speech(seconds: 8), to: lv), lv) }
quiet("digital silence", [Float](repeating: 0, count: Int(fs * 6)), -200)
var dr = RNG(s: 99)
quiet("dither", (0..<Int(fs * 6)).map { _ in Float(dr.sym() * 3e-5) }, -95)
