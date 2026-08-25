//  PitchStability.swift
//  Zero Fret
//
//  An onset gate. The clarity gate in §3 answers "is this periodic?", and that
//  turns out not to be the question that matters in a real room.
//
//  Measured on synthesised material through a modelled phone microphone:
//
//                        clarity p50    6-frame pitch spread p50
//      plucked E2            0.921                 5.8 cents
//      plucked A2            0.949                 5.1 cents
//      background speech     0.994                41.2 cents
//
//  Speech scores *higher* clarity than a plucked string — a glottal pulse train
//  is extremely periodic — so raising the clarity floor rejects the instrument
//  and keeps the interference. What separates them is that a plucked string
//  settles onto one pitch and stays there, while speech glides continuously.
//
//  So: gate the *onset*, not the sustain. Acquiring a pitch requires several
//  consecutive frames that agree; once acquired, the lock is held without
//  re-testing spread, which leaves §5's Fast mode free to track a bend.

import Foundation

struct PitchStability {
    // Two tiers, because a single one forces a choice between rejecting speech
    // and §9's 400 ms cold-launch budget. Swept against plucked E2/A2/E4 and
    // two speech scenarios through a modelled phone microphone:
    //
    //   frames  spread   guitar pass   speech pass
    //     5       12       81-92%        26-38%
    //     7        8       80-90%        10-15%
    //     9        8       79-88%           0%
    //
    // Nine frames is 192 ms at hop 1024, which with engine start and the 85 ms
    // window fill leaves almost nothing against the 400 ms target. So: acquire
    // in six frames when the pitch is already dead steady — which is what a
    // clean pluck in a quiet room looks like, 128 ms — and demand nine
    // otherwise. Sweeping the fast tier with the slow one fixed at 9/8:
    //
    //   fast    guitar pass   speech pass
    //   5 / 5     82-92%        21-23%
    //   6 / 2.5   81-89%         0-5%
    //   7 / 3     80-89%         0-5%
    //
    // If a real pluck jitters more than 2.5 cents over six frames the fast path
    // simply never fires and everything takes the nine-frame route. That is a
    // slower first reading, not a wrong one.

    /// Fast path: fewer frames, but they must agree very tightly.
    static let fastAcquireFrames = 6
    static let fastAcquireSpreadCents = 2.5
    /// Slow path, for anything less clear-cut.
    static let acquireFrames = 9
    static let acquireSpreadCents = 8.0
    /// Unvoiced frames tolerated before the lock is dropped. 12 frames is ~250 ms,
    /// matching the display hold in §3, so the lock and the readout expire together.
    static let holdMisses = 12

    /// Once locked, how far the pitch may move between frames and still be
    /// believed. A deliberate whole-tone bend over 300 ms is ~14 cents per frame
    /// at hop 1024, so 40 leaves room for that while rejecting the 20–100 cent
    /// jumps that characterise speech.
    static let holdJumpCents = 40.0
    /// Consecutive wild frames before the lock is dropped.
    static let holdJumpsAllowed = 3

    // Instance copies so the thresholds can be swept offline against real
    // scenarios rather than picked by feel. Defaults are the swept values.
    var fastAcquireFrames = PitchStability.fastAcquireFrames
    var fastAcquireSpreadCents = PitchStability.fastAcquireSpreadCents
    var acquireFrames = PitchStability.acquireFrames
    var acquireSpreadCents = PitchStability.acquireSpreadCents
    var holdJumpCents = PitchStability.holdJumpCents
    var holdJumpsAllowed = PitchStability.holdJumpsAllowed
    var holdMisses = PitchStability.holdMisses

    private var recent: [Double] = []
    private var locked = false
    private var misses = 0
    private var jumps = 0
    private var lastAccepted: Double = 0

    /// True once the incoming pitch is trustworthy enough to show.
    /// - Parameters:
    ///   - frequency: detector output, Hz. Ignored when `voiced` is false.
    ///   - voiced: whether the detector believed this frame.
    mutating func admit(frequency: Double, voiced: Bool) -> Bool {
        guard voiced, frequency > 0 else {
            misses += 1
            if misses >= holdMisses { reset() }
            return false
        }
        misses = 0

        if locked {
            // Holding is not unconditional. Letting any voiced frame renew the
            // lock meant speech, which is continuously voiced, never lost it —
            // the gate acquired once on a chance-stable moment and then held
            // forever. Require frame-to-frame continuity as well.
            let jump = lastAccepted > 0 ? abs(1200 * log2(frequency / lastAccepted)) : 0
            if jump > holdJumpCents {
                jumps += 1
                if jumps >= holdJumpsAllowed {
                    reset()
                    return false
                }
                // Tolerate the odd outlier without surrendering the lock, but
                // don't let it drag the reference either.
                return true
            }
            jumps = 0
            lastAccepted = frequency
            return true
        }

        recent.append(frequency)
        if recent.count > acquireFrames { recent.removeFirst() }

        if spread(ofLast: fastAcquireFrames).map({ $0 <= fastAcquireSpreadCents }) == true {
            return acquire(frequency)
        }
        if spread(ofLast: acquireFrames).map({ $0 <= acquireSpreadCents }) == true {
            return acquire(frequency)
        }
        // Not settled. Keep the newest frames and try again next hop rather than
        // starting from scratch, or a note that settles slowly never acquires.
        return false
    }

    /// Spread in cents across the last `n` frames, or nil if there aren't that many.
    private func spread(ofLast n: Int) -> Double? {
        guard n > 1, recent.count >= n else { return nil }
        let window = recent.suffix(n)
        guard let lo = window.min(), let hi = window.max(), lo > 0 else { return nil }
        return 1200 * log2(hi / lo)
    }

    private mutating func acquire(_ frequency: Double) -> Bool {
        locked = true
        jumps = 0
        lastAccepted = frequency
        return true
    }

    mutating func reset() {
        recent.removeAll(keepingCapacity: true)
        locked = false
        misses = 0
        jumps = 0
        lastAccepted = 0
    }

    var isLocked: Bool { locked }
}
