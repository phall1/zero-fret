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

#if targetEnvironment(simulator)

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

    init(writer: RingWriter, sampleRate: Double) {
        self.writer = writer
        self.sampleRate = sampleRate
        block = .allocate(capacity: blockSize)
        block.initialize(repeating: 0, count: blockSize)
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
        let cycle = Double(Self.programme.count) * Self.secondsPerString
        let position = elapsed.truncatingRemainder(dividingBy: cycle)
        let index = min(Int(position / Self.secondsPerString), Self.programme.count - 1)
        let within = (position - Double(index) * Self.secondsPerString) / Self.secondsPerString

        // −sweep → +sweep across each string's slot.
        let cents = (within * 2 - 1) * Self.sweepCents
        let target = MusicMath.frequency(midi: Double(Self.programme[index]), referenceA: 440)
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
        elapsed += Double(blockSize) / sampleRate
    }
}

#endif
