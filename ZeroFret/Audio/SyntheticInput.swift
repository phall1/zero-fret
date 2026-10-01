//  SyntheticInput.swift
//  Zero Fret
//
//  Simulator only. Compiled out entirely on device.
//
//  Two reasons this exists rather than "just use the Simulator's microphone":
//
//  1. §9 is explicit that the Simulator's microphone is unusable — it resamples,
//     applies processing you cannot disable, and produces plausible-looking
//     wrong answers. A tuner that reads confidently and wrongly during
//     development is worse than one that refuses.
//  2. Touching `AVAudioEngine.inputNode` in the Simulator initialises AURemoteIO
//     over an XPC bridge that times out unless Simulator.app itself holds macOS
//     microphone permission. AudioToolbox's response to that timeout is
//     `abort()`, which no amount of Swift error handling can catch.
//
//  So the Simulator gets a generated signal fed through the *same* ring buffer.
//  Everything downstream — pre-filter, NSDF, smoothing, assignment, the display
//  link, the string — is the real code path on the real data structures. The UI
//  labels it as a demo signal so it can never be mistaken for a reading.

#if DEBUG || targetEnvironment(simulator)

/// Launch flags for a review recording. Absent unless something passed them, so
/// a normal launch — tests included — never takes this path. Compiled out of
/// Release, which is what ships.
enum ReviewLaunch {
    private static let args = ProcessInfo.processInfo.arguments
    private static let env = ProcessInfo.processInfo.environment

    /// Shared with the view tour so the drawn string and the sheets move on one clock.
    static let startedAt = Date()
    static var elapsed: Double { Date().timeIntervalSince(startedAt) }

    static var tourEnabled: Bool { args.contains("-zf-review-tour") }
    static var demoEnabled: Bool {
        tourEnabled || args.contains("-zf-review-demo") || env["ZF_REVIEW_DEMO"] == "1"
    }
    static var hideDemoBadge: Bool {
        args.contains("-zf-hide-demo") || env["ZF_HIDE_DEMO"] == "1"
    }
    /// `ZF_SHEET=settings` or `tunings`: open on that sheet, for a store
    /// screenshot of a real screen without a UI test driving taps.
    static var initialSheet: String? { env["ZF_SHEET"] }
}

/// The note the review recording should be hearing. Nil is silence, so the
/// stage can show the idle tuner before a string arrives. Times match
/// `ReviewTour` in the view.
enum ReviewSignal {
    static func pose(at elapsed: Double) -> (midi: Int, cents: Double)? {
        if elapsed < 1.4 { return nil }
        if elapsed < 7.2 {
            let u = (elapsed - 1.4) / 5.8
            return (40, -30 + 30 * u) // low E, flat → true
        }
        if elapsed < 9.8 { return (40, 0) }
        if elapsed < 12.2 {
            let u = (elapsed - 9.8) / 2.4
            return (40, 16 * u) // sharp
        }
        if elapsed < 15.0 { return (45, 0) } // A, in tune
        if elapsed < 20.6 { return (40, 0) }
        if elapsed < ReviewTour.restore { return (38, 0) } // Drop D's low string
        return (40, 0)
    }
}

/// When the view opens and closes sheets. Kept next to `ReviewSignal` so the
/// two cannot drift without the mismatch being obvious.
enum ReviewTour {
    static let openTunings = 15.6
    static let selectDropD = 18.0
    static let dismissTunings = 20.2
    static let openSettings = 22.6
    static let setReference = 24.2
    static let enableBeat = 25.8
    static let dismissSettings = 28.2
    static let pin = 29.6
    static let unpin = 32.2
    static let restore = 33.4
    static let finished = 35.5
}

import Foundation

final class SyntheticInput {
    /// Walks the six strings of standard tuning, drifting each one from flat
    /// through true to sharp so the colour, the wobble and the haptic latch all
    /// get exercised without anybody picking up a guitar.
    private static let programme: [Int] = [40, 45, 50, 55, 59, 64]
    private static let secondsPerString = 6.0
    private static let sweepCents = 38.0

    private let queue = DispatchQueue(label: "dev.phux.zerofret.synthetic", qos: .userInitiated)
    private let writer: RingWriter
    private let sampleRate: Double
    private var timer: DispatchSourceTimer?

    private var phase = 0.0
    private var elapsed = 0.0
    private var block: UnsafeMutablePointer<Float>
    private let blockSize = 512
    /// Set only for store screenshots. Absent on a normal simulator launch, so
    /// the sweep below is what the UI tests still drive.
    private let pose: (midi: Int, cents: Double)?

    init(writer: RingWriter, sampleRate: Double) {
        self.writer = writer
        self.sampleRate = sampleRate
        block = .allocate(capacity: blockSize)
        block.initialize(repeating: 0, count: blockSize)
        pose = Self.poseFromLaunch()
    }

    /// `-zf-pose-midi` / `-zf-pose-cents`, or the same names as environment
    /// variables. `simctl launch` forwards `SIMCTL_CHILD_*` as env, which is
    /// how a negative cents value survives the shell.
    private static func poseFromLaunch() -> (midi: Int, cents: Double)? {
        let args = ProcessInfo.processInfo.arguments
        let env = ProcessInfo.processInfo.environment
        let midiString = flag("-zf-pose-midi", in: args) ?? env["ZF_POSE_MIDI"]
        let centsString = flag("-zf-pose-cents", in: args) ?? env["ZF_POSE_CENTS"]
        guard let midiString, let centsString,
              let midi = Int(midiString),
              let cents = Double(centsString) else { return nil }
        return (midi, cents)
    }

    private static func flag(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    deinit {
        timer?.cancel()
        block.deallocate()
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            let interval = Int((Double(blockSize) / sampleRate) * 1000)
            source.schedule(deadline: .now(), repeating: .milliseconds(max(1, interval)),
                            leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.render() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            phase = 0
            elapsed = 0
        }
    }

    private func render() {
        if ReviewLaunch.tourEnabled {
            if let posed = ReviewSignal.pose(at: ReviewLaunch.elapsed) {
                writeTone(midi: Double(posed.midi), cents: posed.cents)
            } else {
                writeSilence()
            }
            return
        }

        let midi: Double
        let cents: Double
        if let pose {
            midi = Double(pose.midi)
            cents = pose.cents
        } else {
            let cycle = Double(Self.programme.count) * Self.secondsPerString
            let position = elapsed.truncatingRemainder(dividingBy: cycle)
            let index = min(Int(position / Self.secondsPerString), Self.programme.count - 1)
            let within = (position - Double(index) * Self.secondsPerString) / Self.secondsPerString
            // −sweep → +sweep across each string's slot.
            midi = Double(Self.programme[index])
            cents = (within * 2 - 1) * Self.sweepCents
        }
        writeTone(midi: midi, cents: cents)
        elapsed += Double(blockSize) / sampleRate
    }

    private func writeSilence() {
        for n in 0..<blockSize { block[n] = 0 }
        writer.write(block, blockSize)
    }

    private func writeTone(midi: Double, cents: Double) {
        let target = MusicMath.frequency(midi: midi, referenceA: 440)
        let frequency = target * pow(2, cents / 1200)

        // A plausible plucked-string partial series, dark enough to be realistic.
        let partials: [Double] = [1.0, 0.62, 0.38, 0.22, 0.12]
        let step = 2 * Double.pi * frequency / sampleRate

        for n in 0..<blockSize {
            var value = 0.0
            for (k, amplitude) in partials.enumerated() {
                value += amplitude * sin(phase * Double(k + 1))
            }
            block[n] = Float(value * 0.16)
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }

        writer.write(block, blockSize)
    }
}

#endif
