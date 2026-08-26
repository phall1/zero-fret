import Foundation

struct Cfg {
    var acquireContrast = TargetTracker.acquireContrast
    var holdContrast = TargetTracker.holdContrast
    var releaseFrames = TargetTracker.releaseFrames
    var acquireFrames = PitchStability.acquireFrames
    var acquireSpread = PitchStability.acquireSpreadCents
    var fastFrames = PitchStability.fastAcquireFrames
    var fastSpread = PitchStability.fastAcquireSpreadCents
}

struct Run { var coverage = 0.0; var hold = 0.0; var correct = 0.0; var lock = Double.nan; var err = Double.nan }

func run(_ signal: [Float], tuning: Tuning, truth: Double, string: Int?, cfg: Cfg, windowSize: Int = 4096) -> Run {
    let hop = windowSize / 4
    let det = PitchDetector(sampleRate: fs, windowSize: windowSize)
    let filt = Biquad(sampleRate: fs)
    let smoother = Smoother(mode: .fast)
    var tracker = TargetTracker()
    tracker.acquireContrast = cfg.acquireContrast
    tracker.holdContrast = cfg.holdContrast
    tracker.releaseFrames = cfg.releaseFrames
    tracker.stability.acquireFrames = cfg.acquireFrames
    tracker.stability.acquireSpreadCents = cfg.acquireSpread
    tracker.stability.fastAcquireFrames = cfg.fastFrames
    tracker.stability.fastAcquireSpreadCents = cfg.fastSpread
    var hist = [Float](repeating: 0, count: windowSize)
    var filled = 0, off = 0, total = 0, voiced = 0, right = 0
    var lastT = 0.0, lock = Double.nan
    var errs: [Double] = []
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
        let d = sc.detect(in: tuning, referenceA: 440)
        let r = tracker.read(from: det, proposedBy: d)
        let o = tracker.update(pitch: r, detection: d) { i in
            MusicMath.frequency(midi: Double(tuning.midiNotes[i]), referenceA: 440)
        }
        total += 1
        if o.voiced {
            let sm = smoother.process(hz: o.frequency, dt: hopSec)
            voiced += 1
            if o.string == string { right += 1 }
            if lock.isNaN { lock = Double(off) / fs * 1000 }
            lastT = Double(off) / fs * 1000
            if truth > 0 { errs.append(abs(1200 * log2(sm / truth))) }
        } else { smoother.reset() }
    }
    var rr = Run()
    rr.coverage = total > 0 ? 100.0 * Double(voiced) / Double(total) : 0
    rr.hold = lastT
    rr.correct = voiced > 0 ? 100.0 * Double(right) / Double(voiced) : 0
    rr.lock = lock
    if !errs.isEmpty { errs.sort(); rr.err = errs[errs.count / 2] }
    return rr
}
