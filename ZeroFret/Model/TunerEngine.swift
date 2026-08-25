//  TunerEngine.swift
//  Zero Fret
//
//  Main-actor coordinator. Owns the audio engine, the detection worker, the
//  display link, string assignment, haptics and the idle timer, and produces the
//  single `DisplayState` the view layer reads.
//
//  The display link exists for two reasons (§6): it carries the frame-rate
//  request that unlocks 120 Hz on ProMotion, and it is where phase is
//  integrated. Phase must be accumulated frame to frame (§0.3) — computing
//  sin(2π·beat·t) from absolute time makes the string snap every time the beat
//  frequency moves, which is every frame while somebody is tuning, and the bug
//  reads as a noisy detector.

import Foundation
import QuartzCore
import SwiftUI
import UIKit

private final class DisplayLinkProxy: NSObject {
    var handler: ((CADisplayLink) -> Void)?
    @objc func step(_ link: CADisplayLink) { handler?(link) }
}

@MainActor
@Observable
final class TunerEngine {
    // MARK: - Tunables that are not in the spec but need a value

    /// §3: hold the last valid reading this long before blanking.
    static let holdSeconds = 0.25
    /// §8: re-enable sleep after this long with no pitch.
    static let idleTimerGraceSeconds = 45.0
    /// §6: above this the wobble aliases against the frame rate and reads as
    /// noise rather than as "very out of tune". Amplitude already carries that.
    static let maxDisplayBeatHz = 24.0
    /// Not specified. ±5¢ is the band every credible guitar tuner treats as in
    /// tune, and it is comfortably above this detector's resolution floor.
    nonisolated static let defaultToleranceCents = 5.0

    // MARK: - Published state

    private(set) var display = DisplayState()
    private(set) var permission: MicrophoneAuthorization = .undetermined
    private(set) var engineError: String?
    private(set) var isRunning = false
    /// True in the Simulator, where the input is generated. Surfaced so the UI
    /// can say so — a demo reading must never look like a real one.
    var isDemoSignal: Bool { audio.isSyntheticSource }

    // MARK: - Settings

    var referenceA: Double = Defaults.referenceA {
        didSet {
            referenceA = min(max(referenceA, 410), 470)
            Defaults.referenceA = referenceA
            tick.rearm()
        }
    }

    var toleranceCents: Double = Defaults.toleranceCents {
        didSet {
            toleranceCents = min(max(toleranceCents, 1), 15)
            Defaults.toleranceCents = toleranceCents
            tick.rearm()
        }
    }

    var responseMode: ResponseMode = Defaults.responseMode {
        didSet {
            Defaults.responseMode = responseMode
            worker?.responseMode = responseMode
        }
    }

    var hapticsEnabled: Bool = Defaults.hapticsEnabled {
        didSet {
            Defaults.hapticsEnabled = hapticsEnabled
            tick.isEnabled = hapticsEnabled
        }
    }

    var tuning: Tuning = Defaults.tuning {
        didSet {
            guard tuning != oldValue else { return }
            Defaults.tuning = tuning
            pinnedString = nil
            assigner.reset()
            tick.rearm()
            worker?.setWindowSize(tuning.windowSize)
        }
    }

    /// Manual pin. §4: assignment is disabled entirely while a string is pinned.
    var pinnedString: Int? {
        didSet {
            assigner.pinnedIndex = pinnedString
            assigner.reset()
            tick.rearm()
        }
    }

    // MARK: - Collaborators

    private let audio = AudioEngine()
    private var worker: DetectionWorker?
    private let assigner = StringAssigner()
    private let tick = TrueTick()

    private let proxy = DisplayLinkProxy()
    private var link: CADisplayLink?

    private var lastSequence: Int64 = -1
    private var lastValidTime: Double = 0
    private var lastPitchTime: Double = 0
    private var idleTimerHeld = false

    /// Set from the last accepted detection frame and held for `holdSeconds`.
    private var heldFrequency: Double = 0
    private var heldClarity: Double = 0
    private var heldTarget: PitchTarget = .chromatic(midi: 69)

    init() {
        permission = audio.authorization
        tick.isEnabled = hapticsEnabled
        assigner.pinnedIndex = nil

        audio.onSampleRateChange = { [weak self] rate in
            guard let self else { return }
            self.worker?.reconfigure(sampleRate: rate, windowSize: self.tuning.windowSize)
        }
        audio.onRunningChange = { [weak self] running in
            guard let self else { return }
            self.isRunning = running
            self.engineError = self.audio.lastError
            if running {
                self.worker?.start()
            } else {
                self.worker?.stop()
            }
        }
    }

    // MARK: - Lifecycle

    func onAppear() async {
        permission = audio.authorization
        if permission == .undetermined {
            _ = await audio.requestPermission()
            permission = audio.authorization
        }
        guard permission == .granted else { return }
        startEverything()
    }

    func enterForeground() {
        guard permission == .granted else { return }
        startEverything()
    }

    func enterBackground() {
        // §2: the mic is live only in the foreground. This is a product
        // commitment, not hygiene — there is deliberately no `audio` background
        // mode in Info.plist.
        stopEverything()
    }

    private func startEverything() {
        if worker == nil {
            worker = DetectionWorker(ring: audio.ring,
                                     sampleRate: audio.sampleRate,
                                     windowSize: tuning.windowSize)
        }
        worker?.responseMode = responseMode
        worker?.setWindowSize(tuning.windowSize)

        audio.start()
        engineError = audio.lastError

        if audio.isRunning {
            worker?.reconfigure(sampleRate: audio.sampleRate, windowSize: tuning.windowSize)
            worker?.start()
        }

        assigner.reset()
        tick.rearm()
        lastSequence = -1
        startLink()
    }

    private func stopEverything() {
        stopLink()
        worker?.stop()
        audio.stop()
        display = DisplayState()
        releaseIdleTimer()
    }

    private func startLink() {
        guard link == nil else { return }
        proxy.handler = { [weak self] link in self?.frame(link) }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        // §6. Paired with CADisableMinimumFrameDurationOnPhone in Info.plist —
        // without both, iPhone caps at 60 Hz no matter what this says.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        proxy.handler = nil
    }

    // MARK: - Per-frame

    private func frame(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = max(link.targetTimestamp - link.timestamp, 1.0 / 240.0)

        var next = display

        if let snapshot = worker?.snapshots.latest() {
            next.rmsDB = snapshot.rmsDB
            next.gateDB = snapshot.gateDB
            next.sampleRate = snapshot.sampleRate
            next.windowSize = snapshot.windowSize

            if snapshot.sequence != lastSequence {
                lastSequence = snapshot.sequence
                consume(snapshot, now: now)
            }
        }

        let holding = now - lastValidTime <= TunerEngine.holdSeconds
        if holding, heldFrequency > 0 {
            let targetHz = MusicMath.frequency(midi: Double(heldTarget.midi), referenceA: referenceA)
            let cents = MusicMath.cents(measured: heldFrequency, target: targetHz)
            let beat = MusicMath.beatHz(measured: heldFrequency, target: targetHz)

            next.hasPitch = true
            next.frequency = heldFrequency
            next.clarity = heldClarity
            next.cents = cents
            next.beatHz = min(beat, TunerEngine.maxDisplayBeatHz)
            next.targetMIDI = heldTarget.midi
            next.noteName = MusicMath.noteName(midi: heldTarget.midi)
            next.octave = MusicMath.octave(midi: heldTarget.midi)
            next.stringIndex = heldTarget.stringIndex
            next.isChromaticFallback = heldTarget.stringIndex == nil
            next.direction = TuneDirection.from(cents: cents, tolerance: toleranceCents)
        } else {
            next.hasPitch = false
            next.frequency = 0
            next.cents = 0
            next.beatHz = 0
            next.clarity = 0
            next.stringIndex = nil
            next.isChromaticFallback = false
            next.direction = .inTune
            next.noteName = "—"
        }

        // §0.3 / §6: integrate, never evaluate from absolute time.
        var phase = display.phase + 2 * .pi * next.beatHz * dt
        if phase >= 2 * .pi { phase = phase.truncatingRemainder(dividingBy: 2 * .pi) }
        next.phase = phase

        if next != display { display = next }

        updateIdleTimer(now: now, pitchPresent: next.hasPitch)
    }

    private func consume(_ snapshot: DetectionSnapshot, now: Double) {
        guard snapshot.hasPitch, snapshot.frequency > 0 else { return }

        heldFrequency = snapshot.frequency
        heldClarity = snapshot.clarity

        let previousTarget = heldTarget
        heldTarget = assigner.target(frequency: snapshot.frequency,
                                     tuning: tuning,
                                     referenceA: referenceA)
        // §7's latch is about one hand vibrating around zero on one string.
        // Moving to a different string is a new note and deserves its own tick,
        // or a string that happens to already be in tune stays silent.
        if heldTarget.midi != previousTarget.midi { tick.rearm() }

        lastValidTime = now
        lastPitchTime = now

        let targetHz = MusicMath.frequency(midi: Double(heldTarget.midi), referenceA: referenceA)
        tick.update(cents: MusicMath.cents(measured: heldFrequency, target: targetHz),
                    tolerance: toleranceCents)
    }

    private func updateIdleTimer(now: Double, pitchPresent: Bool) {
        if pitchPresent {
            lastPitchTime = now
            if !idleTimerHeld {
                idleTimerHeld = true
                UIApplication.shared.isIdleTimerDisabled = true
            }
        } else if idleTimerHeld, now - lastPitchTime > TunerEngine.idleTimerGraceSeconds {
            releaseIdleTimer()
        }
        if !pitchPresent {
            tick.update(cents: nil, tolerance: toleranceCents)
        }
    }

    private func releaseIdleTimer() {
        idleTimerHeld = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - View helpers

    func targetFrequency(for string: TuningString) -> Double {
        string.frequency(referenceA: referenceA)
    }

    /// Cents from the currently detected pitch to a given string, for the row
    /// display. Nil when there is no pitch.
    func cents(to string: TuningString) -> Double? {
        guard display.hasPitch, display.frequency > 0 else { return nil }
        return MusicMath.cents(measured: display.frequency,
                               target: targetFrequency(for: string))
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Persistence

private enum Defaults {
    private static let store = UserDefaults.standard

    private enum Key {
        static let referenceA = "zf.referenceA"
        static let tolerance = "zf.toleranceCents"
        static let response = "zf.responseMode"
        static let haptics = "zf.hapticsEnabled"
        static let tuning = "zf.tuningID"
    }

    static var referenceA: Double {
        get {
            let value = store.double(forKey: Key.referenceA)
            return value >= 410 && value <= 470 ? value : MusicMath.concertA
        }
        set { store.set(newValue, forKey: Key.referenceA) }
    }

    static var toleranceCents: Double {
        get {
            let value = store.double(forKey: Key.tolerance)
            return value >= 1 && value <= 15 ? value : TunerEngine.defaultToleranceCents
        }
        set { store.set(newValue, forKey: Key.tolerance) }
    }

    static var responseMode: ResponseMode {
        get {
            guard let raw = store.string(forKey: Key.response),
                  let mode = ResponseMode(rawValue: raw) else { return .fast }
            return mode
        }
        set { store.set(newValue.rawValue, forKey: Key.response) }
    }

    static var hapticsEnabled: Bool {
        get { store.object(forKey: Key.haptics) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.haptics) }
    }

    static var tuning: Tuning {
        get {
            guard let id = store.string(forKey: Key.tuning),
                  let tuning = TuningLibrary.tuning(id: id) else { return TuningLibrary.standard }
            return tuning
        }
        set { store.set(newValue.id, forKey: Key.tuning) }
    }
}
