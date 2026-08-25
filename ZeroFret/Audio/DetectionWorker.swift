//  DetectionWorker.swift
//  Zero Fret
//
//  Drains the ring buffer on a dedicated `.userInteractive` queue, runs the
//  pre-filter and the detector, and publishes into the triple buffer. Spec §2–§5.
//
//  The queue is woken by a timer rather than by the audio thread. Signalling a
//  semaphore from the render thread is common practice but it is still a syscall
//  on contention, and §2 permits exactly two operations in the tap: a copy into
//  the ring and an atomic store. A timer at half the hop period adds at most
//  ~10 ms of latency and keeps that promise intact.

import Foundation
import QuartzCore
import os

final class DetectionWorker {
    private let queue = DispatchQueue(label: "dev.phux.zerofret.detect", qos: .userInteractive)
    private let ring: RingBuffer
    let snapshots = SnapshotBuffer()

    private var timer: DispatchSourceTimer?
    private var running = false

    // Owned by `queue`.
    private var detector: PitchDetector
    private var filter: Biquad
    private var smoother: Smoother
    private let gate = NoiseGate()
    private var window: UnsafeMutablePointer<Float>
    private var windowCapacity: Int
    private var hopScratch: UnsafeMutablePointer<Float>
    private var filteredHistory: UnsafeMutablePointer<Float>
    private var filteredFilled = 0
    private var unvoicedHops = 0

    private var sampleRate: Double
    private var windowSize: Int
    private var hopSize: Int

    /// Settings the queue reads. Written from the main actor, so they go through
    /// a lock — this is not the render thread, and an uncontended
    /// `OSAllocatedUnfairLock` is tens of nanoseconds.
    private struct Config: Sendable {
        var responseMode: ResponseMode = .fast
        var windowSize: Int = 4096
    }
    private let config = OSAllocatedUnfairLock(initialState: Config())

    init(ring: RingBuffer, sampleRate: Double, windowSize: Int) {
        self.ring = ring
        self.sampleRate = sampleRate
        self.windowSize = windowSize
        self.hopSize = windowSize / 4
        detector = PitchDetector(sampleRate: sampleRate, windowSize: windowSize)
        filter = Biquad(sampleRate: sampleRate)
        smoother = Smoother(mode: .fast)
        windowCapacity = 8192
        window = .allocate(capacity: windowCapacity)
        window.initialize(repeating: 0, count: windowCapacity)
        hopScratch = .allocate(capacity: windowCapacity)
        hopScratch.initialize(repeating: 0, count: windowCapacity)
        filteredHistory = .allocate(capacity: windowCapacity)
        filteredHistory.initialize(repeating: 0, count: windowCapacity)
        config.withLock { $0.windowSize = windowSize }
    }

    deinit {
        timer?.cancel()
        window.deallocate()
        hopScratch.deallocate()
        filteredHistory.deallocate()
    }

    // MARK: - Control (main actor side)

    var responseMode: ResponseMode {
        get { config.withLock { $0.responseMode } }
        set { config.withLock { $0.responseMode = newValue } }
    }

    /// Called when the tuning family changes the required window (§3).
    func setWindowSize(_ size: Int) {
        config.withLock { $0.windowSize = size }
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            gate.beginCalibration()
            smoother.reset()
            filter.reset()
            filteredFilled = 0
            unvoicedHops = 0
            ring.clear()

            restartTimer()
        }
    }

    /// Wakes the queue every half hop period: enough headroom that a full window
    /// is never more than one tick late, cheap enough to be invisible.
    private func restartTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(4, Int((Double(hopSize) / sampleRate) * 500))
        source.schedule(deadline: .now(),
                        repeating: .milliseconds(interval),
                        leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.drain() }
        timer = source
        source.resume()
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            timer?.cancel()
            timer = nil
        }
    }

    /// Route change or engine restart: the sample rate may have moved, so every
    /// derived constant is rebuilt. §2, lifecycle.
    func reconfigure(sampleRate: Double, windowSize: Int) {
        queue.async { [self] in
            self.sampleRate = sampleRate
            self.windowSize = windowSize
            self.hopSize = windowSize / 4
            detector = PitchDetector(sampleRate: sampleRate, windowSize: windowSize)
            filter = Biquad(sampleRate: sampleRate)
            filter.reset()
            smoother.reset()
            filteredFilled = 0
            gate.beginCalibration()
            ring.clear()

            if running { restartTimer() }
        }
    }

    // MARK: - Detection queue

    private func drain() {
        guard running else { return }

        let desired = config.withLock { $0.windowSize }
        if desired != windowSize {
            reconfigureInline(windowSize: desired)
            return
        }
        smoother.mode = config.withLock { $0.responseMode }

        ring.resyncIfOverrun()

        // Prime: fill the filtered history one hop at a time so the biquad state
        // is continuous. Overlapped windows must never be filtered twice.
        while ring.available >= hopSize {
            guard ring.peek(into: hopScratch, count: hopSize) else { break }
            ring.advance(hopSize)
            filter.process(hopScratch, count: hopSize)

            // Slide the history left by one hop and append. 16 KB of memmove at
            // 47 Hz is nothing, and it keeps the window contiguous for vDSP.
            if windowSize > hopSize {
                memmove(filteredHistory,
                        filteredHistory + hopSize,
                        (windowSize - hopSize) * MemoryLayout<Float>.size)
            }
            memcpy(filteredHistory + (windowSize - hopSize),
                   hopScratch,
                   hopSize * MemoryLayout<Float>.size)
            filteredFilled = min(filteredFilled + hopSize, windowSize)

            guard filteredFilled >= windowSize else { continue }
            analyse()
        }
    }

    private func reconfigureInline(windowSize size: Int) {
        windowSize = size
        hopSize = size / 4
        detector = PitchDetector(sampleRate: sampleRate, windowSize: size)
        filter.reset()
        smoother.reset()
        filteredFilled = 0
        ring.clear()
        restartTimer()
    }

    private func analyse() {
        let result = detector.process(filteredHistory)
        let hopSeconds = Double(hopSize) / sampleRate
        let aboveGate = gate.update(rms: result.rms, dt: hopSeconds, pitchDetected: result.hasPitch)

        var snapshot = DetectionSnapshot()
        snapshot.timestamp = CACurrentMediaTime()
        snapshot.rmsDB = NoiseGate.decibels(result.rms)
        snapshot.gateDB = gate.thresholdDB
        snapshot.sampleRate = sampleRate
        snapshot.windowSize = windowSize

        if result.hasPitch, aboveGate {
            let smoothed = smoother.process(hz: result.frequency, dt: hopSeconds)
            snapshot.frequency = smoothed
            snapshot.clarity = result.clarity
            snapshot.hasPitch = true
            unvoicedHops = 0
        } else {
            // Don't tear down the smoother on a single clarity dip mid-note —
            // that would re-prime the one-euro filter and snap the readout. Only
            // let go once the display has stopped holding the last reading.
            unvoicedHops += 1
            if Double(unvoicedHops) * hopSeconds >= 0.25 { smoother.reset() }
            snapshot.frequency = 0
            snapshot.clarity = result.clarity
            snapshot.hasPitch = false
        }

        snapshots.publish(snapshot)
    }
}
