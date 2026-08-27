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
    /// The Settings diagnostics are a readout, not an instrument. 6 Hz is legible
    /// and keeps the sheet from re-rendering under the user's finger.
    static let signalRefreshInterval = 1.0 / 6.0

    // MARK: - Published state

    private(set) var display = DisplayState()
    /// Diagnostics, republished at `signalRefreshInterval` rather than per frame.
    private(set) var signal = SignalState()
    /// Outside the observable graph on purpose — see `WobblePhase`.
    let wobble = WobblePhase()
    private(set) var permission: MicrophoneAuthorization = .undetermined
    private(set) var engineError: String?
    private(set) var isRunning = false
    /// True in the Simulator, where the input is generated. Surfaced so the UI
    /// can say so — a demo reading must never look like a real one.
    var isDemoSignal: Bool { audio.isSyntheticSource }
    /// What the microphone is actually doing — cardioid if the device offered it.
    var inputDescription: String { audio.inputDescription }

    // MARK: - Settings

    // Clamping happens in the setter, NOT in a `didSet` that assigns back to the
    // property. Under `@Observable` the macro splits the property, so the
    // observer sits on the generated backing store while the self-assignment
    // goes back through the public setter — which writes the store again and
    // re-enters `didSet` forever. A plain class calls `didSet` once; the
    // `@Observable` version recurses until the stack is gone. One touch of the
    // Reference slider was enough to take the app down.
    //
    // Neither setter re-arms the haptic latch. `Slider` writes once per step
    // during a drag, so re-arming there would fire a rigid impact on every step
    // the note happened to be in band — precisely the machine-gunning §7's latch
    // exists to prevent.
    private var storedReferenceA: Double = Defaults.referenceA
    var referenceA: Double {
        get { storedReferenceA }
        set {
            let clamped = min(max(newValue, 410), 470)
            guard clamped != storedReferenceA else { return }
            storedReferenceA = clamped
            Defaults.referenceA = clamped
            worker?.setTargets(tuning.midiNotes, referenceA: clamped)
            // Every target just moved, so nothing that was in tune against the
            // old reference can still be claimed as done.
            forgetTunedStrings()
        }
    }

    private var storedToleranceCents: Double = Defaults.toleranceCents
    var toleranceCents: Double {
        get { storedToleranceCents }
        set {
            let clamped = min(max(newValue, 1), 15)
            guard clamped != storedToleranceCents else { return }
            storedToleranceCents = clamped
            Defaults.toleranceCents = clamped
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
        beatHaptics.isEnabled = beatHapticsEnabled
        }
    }

    /// Tap once per beat against the target, so the instrument can be tuned
    /// without looking at the screen. Off by default: it is a real change to
    /// what the app does in the hand, and that should be asked for.
    var beatHapticsEnabled: Bool = Defaults.beatHapticsEnabled {
        didSet {
            Defaults.beatHapticsEnabled = beatHapticsEnabled
            beatHaptics.isEnabled = beatHapticsEnabled
        }
    }

    var tuning: Tuning = Defaults.tuning {
        didSet {
            guard tuning != oldValue else { return }
            Defaults.tuning = tuning
            pinnedString = nil
            assigner.reset()
            tick.rearm()
            forgetTunedStrings()
            // Drop the held reading. Without this the 250 ms hold keeps
            // rendering the previous tuning's target — including a stringIndex
            // that may not exist in the new tuning, so no chip matches.
            clearHeldReading()
            worker?.setWindowSize(tuning.windowSize)
            worker?.setTargets(tuning.midiNotes, referenceA: referenceA)
        }
    }

    /// Manual pin. §4: assignment is disabled entirely while a string is pinned.
    var pinnedString: Int? {
        didSet {
            guard pinnedString != oldValue else { return }
            assigner.pinnedIndex = pinnedString
            assigner.reset()
            tick.rearm()
            // Re-target the held reading straight away, so pinning a string
            // takes visible effect even if the note has already decayed.
            retargetHeldReading()
        }
    }

    // MARK: - Collaborators

    private let audio = AudioEngine()
    private var worker: DetectionWorker?
    private let assigner = StringAssigner()
    private let tick = TrueTick()
    private let beatHaptics = BeatHaptics()

    private let proxy = DisplayLinkProxy()
    // `nonisolated(unsafe)` so `deinit`, which is nonisolated, can invalidate it.
    // Every other access is on the main actor, and by the time `deinit` runs no
    // other reference to this object exists.
    @ObservationIgnored private nonisolated(unsafe) var link: CADisplayLink?
    private var lastSignalPublish: Double = 0

    private var lastSequence: Int64 = -1
    private var lastValidTime: Double = 0
    private var lastPitchTime: Double = 0
    private var idleTimerHeld = false

    /// Set from the last accepted detection frame and held for `holdSeconds`.
    private var heldFrequency: Double = 0
    private var heldClarity: Double = 0
    private var heldTarget: PitchTarget = .chromatic(midi: 69)
    /// True when the last accepted frame was the detector coasting rather than
    /// measuring. Kept out of `heldFrequency`'s story: the reading is the same,
    /// only our confidence in it differs.
    private var heldIsCoasting = false

    deinit {
        // CADisplayLink is retained by the run loop and retains its target, so a
        // released engine would otherwise leave a link firing at 120 Hz for the
        // rest of the process. `invalidate()` is the one thing safe to call here.
        link?.invalidate()
    }

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
        // Re-read rather than trusting the cached value: the app's own "Open
        // Settings" button sends the user to the one screen that changes it.
        permission = audio.authorization
        guard permission == .granted else { return }

        // `.active` also fires for Control Center, a notification banner and the
        // app switcher, none of which were preceded by `.background`. Restarting
        // there would rebuild the detector, re-prime the smoother and re-run the
        // 1 s gate calibration while a note is ringing.
        guard !isRunning else { return }
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
        worker?.setTargets(tuning.midiNotes, referenceA: referenceA)

        assigner.reset()
        tick.rearm()
        clearHeldReading()

        // The worker's snapshot buffer outlives a stop, so it still holds the
        // last reading from before the app was backgrounded. Adopting it would
        // flash a note nobody is playing — and fire a real haptic tick if that
        // stale reading happened to be in tune. Start from wherever the buffer
        // is now, not from -1.
        lastSequence = worker?.snapshots.latest()?.sequence ?? -1

        // `audio.start()` drives `onSampleRateChange` and `onRunningChange`,
        // which reconfigure and start the worker in that order on its own serial
        // queue. Doing it again here would only race those callbacks.
        audio.start()
        engineError = audio.lastError

        startLink()
    }

    private func stopEverything() {
        stopLink()
        worker?.stop()
        audio.stop()
        display = DisplayState()
        signal = SignalState()
        clearHeldReading()
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
            // Diagnostics move on every hop even in silence, so they are
            // republished on their own slow clock rather than dragging the
            // Settings list along at 47 Hz.
            if now - lastSignalPublish >= TunerEngine.signalRefreshInterval {
                lastSignalPublish = now
                let updated = SignalState(rmsDB: snapshot.rmsDB,
                                          gateDB: snapshot.gateDB,
                                          sampleRate: snapshot.sampleRate,
                                          windowSize: snapshot.windowSize,
                                          clarity: snapshot.clarity,
                                          contrast: snapshot.contrast)
                if updated != signal { signal = updated }
            }

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
            next.cents = cents
            next.beatHz = min(beat, TunerEngine.maxDisplayBeatHz)
            next.targetMIDI = heldTarget.midi
            next.noteName = MusicMath.noteName(midi: heldTarget.midi)
            next.octave = MusicMath.octave(midi: heldTarget.midi)
            next.stringIndex = heldTarget.stringIndex
            next.isChromaticFallback = heldTarget.stringIndex == nil
            next.direction = TuneDirection.from(cents: cents, tolerance: toleranceCents)
            next.isHeld = heldIsCoasting
            noteSettled(on: heldTarget.stringIndex, cents: cents)
        } else {
            next.hasPitch = false
            next.frequency = 0
            next.cents = 0
            next.beatHz = 0
            next.stringIndex = nil
            next.isChromaticFallback = false
            next.direction = .inTune
            next.noteName = "—"
            next.isHeld = false
        }

        // §0.3 / §6: integrate, never evaluate from absolute time.
        let beat = wobble.advance(beatHz: next.beatHz, dt: dt)
        // The felt beat and the seen beat are the same cycle of the same
        // oscillator, so they can never disagree about where the note is.
        beatHaptics.update(beat: beat, beatHz: next.beatHz,
                           hasPitch: next.hasPitch && !next.isHeld, now: now)

        // Only on a real change. `display` no longer carries anything that moves
        // every frame, so in silence this assigns nothing at all.
        if next != display { display = next }

        updateIdleTimer(now: now, pitchPresent: next.hasPitch)
    }

    private func consume(_ snapshot: DetectionSnapshot, now: Double) {
        guard snapshot.hasPitch, snapshot.frequency > 0 else { return }

        heldFrequency = snapshot.frequency
        heldClarity = snapshot.clarity
        heldIsCoasting = snapshot.isHeld

        let previousTarget = heldTarget
        heldTarget = assigner.target(frequency: snapshot.frequency,
                                     tuning: tuning,
                                     referenceA: referenceA,
                                     suggested: snapshot.harmonicString >= 0
                                         ? snapshot.harmonicString : nil)
        // §7's latch is about one hand vibrating around zero on one string.
        // Moving to a different string is a new note and deserves its own tick,
        // or a string that happens to already be in tune stays silent.
        if heldTarget.midi != previousTarget.midi { tick.rearm() }

        lastValidTime = now
        lastPitchTime = now

        // A coasted frame must not drive the haptic. §7's tick means "you have
        // arrived", and arriving on a reading we are only repeating would fire
        // it for a note that has already stopped.
        guard !snapshot.isHeld else { return }
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

    /// Forget the last reading outright, so the 250 ms hold cannot render it.
    private func clearHeldReading() {
        heldFrequency = 0
        heldClarity = 0
        heldTarget = .chromatic(midi: 69)
        heldIsCoasting = false
        lastValidTime = 0
        wobble.reset()
    }

    /// Re-run assignment against the current tuning without waiting for the next
    /// detection frame.
    private func retargetHeldReading() {
        guard heldFrequency > 0 else { return }
        heldTarget = assigner.target(frequency: heldFrequency,
                                     tuning: tuning,
                                     referenceA: referenceA)
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
    var clarity: Double { signal.clarity }

    func cents(to string: TuningString) -> Double? {
        guard display.hasPitch, display.frequency > 0 else { return nil }
        return MusicMath.cents(measured: display.frequency,
                               target: targetFrequency(for: string))
    }

    // MARK: - What is already done

    /// Strings that have been brought into tune and not since drifted off.
    ///
    /// A tuner measures one string; a guitarist tunes six, and until now the app
    /// had no idea which of the two it was helping with. Nothing here changes a
    /// reading — it only remembers, so the row of chips can answer "which ones
    /// have I done?" without the player holding it in their head.
    ///
    /// A string is forgotten again the moment it reads far enough out to be
    /// genuinely untuned, using §7's re-arm threshold rather than a second
    /// number: the same distance that earns another haptic tick is the same
    /// distance that stops counting as done, so the two can never disagree.
    private(set) var tunedStrings: Set<Int> = []

    private func noteSettled(on stringIndex: Int?, cents: Double) {
        guard let stringIndex else { return }
        let magnitude = abs(cents)
        if magnitude <= toleranceCents {
            // Only a freshly measured frame may mark a string done. Coasting
            // republishes the last reading, so without this a note that decayed
            // while in tune would keep re-marking itself.
            guard !heldIsCoasting else { return }
            if !tunedStrings.contains(stringIndex) { tunedStrings.insert(stringIndex) }
        } else if magnitude > toleranceCents * TrueTick.rearmMultiplier {
            if tunedStrings.contains(stringIndex) { tunedStrings.remove(stringIndex) }
        }
    }

    /// Everything the set was measured against has moved.
    private func forgetTunedStrings() {
        guard !tunedStrings.isEmpty else { return }
        tunedStrings.removeAll()
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
        static let beatHaptics = "zf.beatHapticsEnabled"
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

    /// Off unless asked for: it changes what the app does in the hand.
    static var beatHapticsEnabled: Bool {
        get { store.object(forKey: Key.beatHaptics) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.beatHaptics) }
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
