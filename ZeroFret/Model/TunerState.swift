//  TunerState.swift
//  Zero Fret
//
//  The hand-off between the detection queue and the display link, plus the
//  struct the view layer actually renders.
//
//  Spec §2: "Results publish via a triple-buffered snapshot struct read by the
//  display link." Three slots and a monotonic counter give the reader two full
//  frames of grace before the writer can reach the slot it is reading — at 47
//  writes/s against a reader that finishes in microseconds, that is not close.

import Foundation

/// What the detector produced for one hop. Trivially copyable by design: it is
/// read across threads without a lock.
struct DetectionSnapshot {
    /// Monotonic hop counter. Also how the display link tells a fresh frame from
    /// a repeat of the last one.
    var sequence: Int64 = 0
    var frequency: Double = 0
    var clarity: Double = 0
    var rmsDB: Double = -120
    var hasPitch: Bool = false
    /// Host time (`CACurrentMediaTime` domain) at which the hop was analysed.
    var timestamp: Double = 0
    /// Live noise-gate threshold in dBFS, surfaced in Settings.
    var gateDB: Double = -50
    var sampleRate: Double = 48000
    var windowSize: Int = 4096
    /// String chosen by harmonic scoring, or -1 when nothing scored.
    var harmonicString: Int = -1
    /// How far the winning target stood out from non-targets. See HarmonicScorer.
    var contrast: Double = 0
    /// True when this frame carries the previous reading forward because the
    /// tracker is still following the string but had no evidence this hop.
    var isHeld: Bool = false
}

/// Lock-free SPSC triple buffer for a trivially copyable payload.
final class SnapshotBuffer {
    private let slots: UnsafeMutablePointer<DetectionSnapshot>
    private let published: UnsafeMutablePointer<Int64>
    private var writeCounter: Int64 = 0

    init() {
        slots = .allocate(capacity: 3)
        slots.initialize(repeating: DetectionSnapshot(), count: 3)
        published = .allocate(capacity: 1)
        published.initialize(to: -1)
    }

    deinit {
        slots.deinitialize(count: 3)
        slots.deallocate()
        published.deallocate()
    }

    /// Writer side. Detection queue only.
    func publish(_ snapshot: DetectionSnapshot) {
        var value = snapshot
        value.sequence = writeCounter
        slots[Int(writeCounter % 3)] = value
        zf_atomic_store_i64(published, writeCounter)
        writeCounter &+= 1
    }

    /// Reader side. Display link only.
    ///
    /// The copy is ~70 bytes and non-atomic, so the counter is re-read
    /// afterwards: if the writer published while we were copying, the struct may
    /// be torn and is discarded. Publishes are not evenly spaced — after a queue
    /// stall `DetectionWorker.drain` emits a burst back to back — so "the writer
    /// cannot lap us in 64 ms" is not an argument you can lean on. A retry is
    /// two atomic loads and removes the question entirely.
    func latest() -> DetectionSnapshot? {
        for _ in 0..<4 {
            let before = zf_atomic_load_i64(published)
            guard before >= 0 else { return nil }
            let value = slots[Int(before % 3)]
            if zf_atomic_load_i64(published) == before { return value }
        }
        return nil
    }
}

/// Which side of the tolerance band the note is on. §6 colour table.
enum TuneDirection {
    case flat
    case sharp
    case inTune
}

/// The wobble phase, deliberately kept out of the observable graph.
///
/// Phase advances on every display frame. Storing it in `DisplayState` would
/// invalidate the entire view tree at 120 Hz, when in fact the note, the cents
/// and the colour only change when a new detection frame lands — ~47×/s at hop
/// 1024, which is what §6 describes. `StringCanvas` reads this from inside
/// `TimelineView(.animation)`, which is already redrawing at display rate.
@MainActor
final class WobblePhase {
    private(set) var value: Double = 0

    /// §0.3: integrate. Never evaluate from absolute time — the beat frequency
    /// moves every frame while somebody is tuning, and recomputing makes the
    /// string snap each time it does.
    /// - Returns: true on the frame the phase completed a cycle, which is one
    ///   beat against the target. Anything that wants to mark beats — a haptic,
    ///   a tone — takes them from here rather than deriving its own, so it is
    ///   physically impossible for what is felt to disagree with what is seen.
    @discardableResult
    func advance(beatHz: Double, dt: Double) -> Bool {
        value += 2 * .pi * beatHz * dt
        guard value >= 2 * .pi else { return false }
        value = value.truncatingRemainder(dividingBy: 2 * .pi)
        return true
    }

    func reset() { value = 0 }
}

/// Diagnostics for the Settings sheet. Separate from `DisplayState` because
/// `rmsDB` changes on every hop even in dead silence, and a shared struct would
/// re-render the whole Settings list — sliders and pickers included — at 47 Hz
/// underneath the user's finger.
struct SignalState: Equatable {
    var rmsDB = -120.0
    var gateDB = -50.0
    var sampleRate = 48000.0
    var windowSize = 4096
    var clarity = 0.0
    var contrast = 0.0
}

/// Everything the stage reads. Replaced only when a value actually changed, so a
/// frame produces at most one SwiftUI invalidation.
struct DisplayState: Equatable {
    var hasPitch = false
    var frequency = 0.0
    var cents = 0.0
    /// Already clamped for display (§6: 24 Hz ceiling).
    var beatHz = 0.0
    var targetMIDI = 69
    var noteName = "—"
    var octave = 4
    var stringIndex: Int?
    var isChromaticFallback = false
    var direction: TuneDirection = .inTune
    /// The reading is being coasted rather than freshly measured. The stage
    /// dims itself rather than blanking — a tuner that flickers off between
    /// uncertain frames reads as broken, and the string really is still there.
    var isHeld = false

    var noteLabel: String { hasPitch ? "\(noteName)\(octave)" : "—" }

    /// One decimal, signed by direction, and a plain `0.0` for anything that
    /// rounds to zero at that precision. The sign comes from the rounded value,
    /// not the raw one: −0.03¢ is shown as 0.0, and printing it as `−00.0` put
    /// a direction on a reading that has none. The view right-aligns this in a
    /// fixed-width field with `.monospacedDigit()`, so the decimal point stays
    /// put as the digit count changes and the block does not shimmer at 47
    /// updates/s.
    var centsText: String {
        guard hasPitch, cents.isFinite else { return "–––.–" }
        let rounded = (min(abs(cents), 99.9) * 10).rounded() / 10
        guard rounded > 0 else { return "0.0" }
        return String(format: "%@%.1f", cents < 0 ? "−" : "+", rounded)
    }
}

extension TuneDirection {
    static func from(cents: Double, tolerance: Double) -> TuneDirection {
        if cents < -tolerance { return .flat }
        if cents > tolerance { return .sharp }
        return .inTune
    }
}
