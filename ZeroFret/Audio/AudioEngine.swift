//  AudioEngine.swift
//  Zero Fret
//
//  Session, engine, tap, lifecycle. Spec §2.
//
//  Three things here are the difference between a tuner that works and one that
//  is quietly, invisibly wrong:
//
//  - `mode: .measurement`. The default mode applies automatic gain control and
//    an input EQ curve, which smear onsets and drift the reading by 2–6¢
//    depending on pick attack. The app looks fine and is wrong.
//  - The sample rate is *read back*, never assumed. `setPreferredSampleRate` is
//    a request; Bluetooth routes hand back 16 or 24 kHz. Hardcoding 48000 makes
//    the tuner a fixed number of cents wrong on AirPods.
//  - Interruption and route-change notifications both silently kill the engine.
//    Unhandled, the app simply appears frozen.

import AVFoundation
import Foundation
import os

enum MicrophoneAuthorization {
    case undetermined
    case granted
    case denied
}

@MainActor
final class AudioEngine {
    /// 2^15 frames ≈ 683 ms at 48 kHz — four times the largest window, so a
    /// stalled detection queue has real headroom before it overruns.
    let ring = RingBuffer(capacity: 1 << 15)

    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private var tapInstalled = false
    private var observers: [NSObjectProtocol] = []
    private var wantsRunning = false

    #if targetEnvironment(simulator) || DEBUG
    /// See `SyntheticInput`. The Simulator never touches AVAudioEngine. A Debug
    /// device build uses the same path only when launched with `-zf-review-demo`
    /// (or the review tour), so a recording can show a note without an instrument.
    /// Release, which is what ships, does not compile this.
    private lazy var synthetic = SyntheticInput(writer: ring.writer, sampleRate: 48000)
    #endif

    #if targetEnvironment(simulator)
    let isSyntheticSource = true
    #elseif DEBUG
    let isSyntheticSource = ReviewLaunch.demoEnabled
    #else
    let isSyntheticSource = false
    #endif

    private(set) var sampleRate: Double = 48000
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Fired when the hardware format changed and every derived constant must be
    /// rebuilt.
    var onSampleRateChange: ((Double) -> Void)?
    /// Fired when the engine starts or stops, for whatever reason.
    var onRunningChange: ((Bool) -> Void)?

    private let log = Logger(subsystem: "dev.phux.zerofret", category: "audio")

    init() {
        registerObservers()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        // The tap closure holds raw pointers into `ring`'s heap allocations by
        // value. Stored-property release order is unspecified, so if `ring` were
        // deallocated while the input node still held the tap, a render callback
        // already in flight would memcpy into freed memory. Drop the tap first.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    // MARK: - Permission

    var authorization: MicrophoneAuthorization {
        #if targetEnvironment(simulator)
        return .granted
        #elseif DEBUG
        // The review recording does not open the microphone, so it must not
        // raise the permission alert and then wait for a tap that nobody is there
        // to make.
        if ReviewLaunch.demoEnabled { return .granted }
        #endif
        #if !targetEnvironment(simulator)
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
        #endif
    }

    func requestPermission() async -> Bool {
        if authorization == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        wantsRunning = true

        if useSyntheticInput {
            sampleRate = 48000
            #if targetEnvironment(simulator) || DEBUG
            synthetic.start()
            #endif
            lastError = nil
            setRunning(true)
            return
        }

        guard authorization == .granted else { return }
        do {
            try configureSession()
            try installTapAndStart()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("start failed: \(error.localizedDescription, privacy: .public)")
            setRunning(false)
        }
    }

    func stop() {
        wantsRunning = false
        if useSyntheticInput {
            #if targetEnvironment(simulator) || DEBUG
            synthetic.stop()
            #endif
            setRunning(false)
            return
        }
        teardown()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        setRunning(false)
    }

    /// Simulator always. A device only when a review launch asked for it, and
    /// only in Debug — `ReviewLaunch` does not exist in Release.
    private var useSyntheticInput: Bool {
        #if targetEnvironment(simulator)
        return true
        #elseif DEBUG
        return ReviewLaunch.demoEnabled
        #else
        return false
        #endif
    }

    // MARK: - Session

    private func configureSession() throws {
        // Exact call order from §2. `.playAndRecord` rather than `.record`
        // because switching category mid-session drops the input node, and
        // `.defaultToSpeaker` because otherwise playback lands in the earpiece.
        // `.mixWithOthers` is deliberately absent: it lowers input priority and
        // inflates jitter.
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.005) // ~256 frames at 48 kHz
        try session.setActive(true)

        // §2: only touch input gain when the route actually supports it —
        // setInputGain throws otherwise.
        if session.isInputGainSettable {
            try? session.setInputGain(1.0)
        }

        preferDirectionalInput()
    }

    /// Ask the built-in microphone for a cardioid pickup.
    ///
    /// The cheapest thing on the whole noise-rejection list: a directional
    /// pattern attenuates a television across the room before a single sample
    /// reaches the detector, and costs no DSP and no latency. Everything else in
    /// this file works on the signal after it has already been polluted.
    ///
    /// `supportedPolarPatterns` is nullable and the set varies by device and by
    /// which built-in microphone is selected, so every step is optional and
    /// failure is silent — an omnidirectional capture is exactly what we had
    /// before.
    private func preferDirectionalInput() {
        guard let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let sources = input.dataSources, !sources.isEmpty else { return }

        // Prefer a source that can do cardioid; fall back to subcardioid, which
        // is still tighter than omni.
        let wanted: [AVAudioSession.PolarPattern] = [.cardioid, .subcardioid]
        for pattern in wanted {
            guard let source = sources.first(where: {
                $0.supportedPolarPatterns?.contains(pattern) ?? false
            }) else { continue }
            do {
                try source.setPreferredPolarPattern(pattern)
                try input.setPreferredDataSource(source)
                try session.setPreferredInput(input)
                log.info("input: \(source.dataSourceName, privacy: .public) / \(pattern.rawValue, privacy: .public)")
                return
            } catch {
                log.error("polar pattern \(pattern.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// What the input is actually doing, for the Settings readout.
    var inputDescription: String {
        if isSyntheticSource { return "Synthetic" }
        #if targetEnvironment(simulator)
        return "Synthetic"
        #else
        guard let input = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
              let source = input.selectedDataSource else { return "Built-in" }
        let pattern = source.selectedPolarPattern ?? .omnidirectional
        let name: String
        switch pattern {
        case .cardioid:    name = "cardioid"
        case .subcardioid: name = "subcardioid"
        case .stereo:      name = "stereo"
        default:           name = "omni"
        }
        return "\(source.dataSourceName) · \(name)"
        #endif
    }

    private func installTapAndStart() throws {
        teardownTap()

        // Touching `inputNode` is what initialises AURemoteIO, and if the route
        // has no usable input that call does not fail — it blocks on an XPC
        // round trip and AudioToolbox aborts the process. Check first.
        // On device this is a real state (input claimed by another app, or a
        // route with no microphone); on the Simulator it is the normal state
        // unless Simulator.app itself has macOS microphone permission.
        guard session.isInputAvailable else {
            throw AudioEngineError.noInputAvailable
        }

        // Read AFTER setActive. This value is the truth; the preferred rate was
        // only ever a request.
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioEngineError.invalidInputFormat
        }

        // Captured by value: `writer` is four words of plain pointers, so the
        // render thread never touches a class reference.
        let writer = ring.writer
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Real-time thread. Copy and an atomic store, nothing else.
            guard let channels = buffer.floatChannelData else { return }
            writer.write(channels[0], Int(buffer.frameLength))
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()

        // Commit the rate only now. Assigning it before `start()` meant a throw
        // here latched a rate nobody had been told about, and every later
        // restart then saw "unchanged" and never notified — leaving the detector
        // deriving every constant from a sample rate the hardware stopped using.
        sampleRate = format.sampleRate

        // Unconditional, and before `setRunning`. `reconfigure` is idempotent, so
        // there is nothing to gain from guessing whether the rate moved, and the
        // worker must be reconfigured before it is told to start or its first
        // hop is analysed against the previous rate.
        //
        // Note there is no `ring.clear()` here: `readIndex` belongs to the
        // detection queue and writing it from the main actor is a data race
        // against `advance()`. The worker clears the ring from its own queue in
        // `start()` and `reconfigure()`.
        onSampleRateChange?(sampleRate)
        setRunning(true)
    }

    private func teardownTap() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func teardown() {
        if engine.isRunning { engine.stop() }
        teardownTap()
    }

    private func setRunning(_ value: Bool) {
        guard value != isRunning else { return }
        isRunning = value
        onRunningChange?(value)
    }

    /// Full rebuild. Used by both notification handlers — a route change can move
    /// the sample rate, and an interruption can leave the engine in a state where
    /// only a fresh tap recovers it.
    private func restart() {
        #if targetEnvironment(simulator)
        return
        #else
        guard wantsRunning, authorization == .granted else { return }
        teardown()
        setRunning(false)
        do {
            try configureSession()
            try installTapAndStart()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("restart failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    // MARK: - Notifications

    private func registerObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            teardown()
            setRunning(false)
        case .ended:
            // §2 says "on .ended with .shouldResume". In practice .shouldResume
            // is frequently absent — Siri, a call that ended while another app
            // still held the session, several system alerts — and honouring the
            // flag literally leaves the engine down while the display link keeps
            // running, so the app renders a frozen readout with no error. The
            // intent flag we actually care about is `wantsRunning`, which
            // `restart()` already checks, so restart either way.
            restart()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            // The two §2 names. Tear down the tap, re-read the format — the
            // sample rate may have moved — reinstall, restart. Acceptance test 5
            // is this path.
            restart()

        case .override, .categoryChange, .routeConfigurationChange:
            // These fire for changes we caused. `configureSession()` itself
            // posts .categoryChange on cold start, and restarting on it meant
            // every launch did a second teardown and a second 1 s gate
            // calibration — working directly against the <400 ms first-reading
            // target. Only rebuild if the hardware rate actually moved.
            if abs(session.sampleRate - sampleRate) > 0.5 { restart() }

        default:
            break
        }
    }
}

enum AudioEngineError: LocalizedError {
    case invalidInputFormat
    case noInputAvailable

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "The input device reported an unusable format."
        case .noInputAvailable:
            return "No audio input is available on the current route."
        }
    }
}
