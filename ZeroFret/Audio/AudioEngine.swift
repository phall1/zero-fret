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

    #if targetEnvironment(simulator)
    /// See `SyntheticInput`. The Simulator never touches AVAudioEngine.
    private lazy var synthetic = SyntheticInput(writer: ring.writer, sampleRate: 48000)
    let isSyntheticSource = true
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
    }

    // MARK: - Permission

    var authorization: MicrophoneAuthorization {
        #if targetEnvironment(simulator)
        return .granted
        #else
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

        #if targetEnvironment(simulator)
        sampleRate = 48000
        ring.clear()
        synthetic.start()
        lastError = nil
        setRunning(true)
        return
        #else
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
        #endif
    }

    func stop() {
        wantsRunning = false
        #if targetEnvironment(simulator)
        synthetic.stop()
        setRunning(false)
        return
        #else
        teardown()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        setRunning(false)
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

        let changed = abs(format.sampleRate - sampleRate) > 0.5
        sampleRate = format.sampleRate

        ring.clear()

        // Captured by value: `writer` is five words of plain pointers, so the
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
        setRunning(true)

        if changed {
            onSampleRateChange?(sampleRate)
        }
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
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(.shouldResume) {
                restart()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .override, .categoryChange,
             .routeConfigurationChange:
            // Tear down the tap, re-read the format — the sample rate may have
            // moved — reinstall, restart. Acceptance test 5 is this path.
            restart()
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
