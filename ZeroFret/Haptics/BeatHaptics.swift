//  BeatHaptics.swift
//  Zero Fret
//
//  The beat, felt.
//
//  Tuning is done with both hands busy and both eyes on the pegs, and every
//  tuner ever made still asks you to look at it. This one does not have to: the
//  phone taps once per beat against the target, so the pulses slow as the note
//  comes in and simply stop when it arrives — the same thing the string does,
//  in the one channel that is still free.
//
//  It is also how the instrument was tuned before there were tuners. A piano
//  technician does not read a number; they count beats and turn until the
//  beating stops. This is that, without needing a trained ear to hear it.
//
//  The taps are driven by `WobblePhase`'s wrap rather than by a rate of their
//  own, so the haptic and the string are the same oscillator. They cannot drift
//  apart, and there is no second constant to keep in step.
//
//  For a blind musician this is not an enhancement, it is the whole interface.

import CoreHaptics
import UIKit

/// Whether a tap can be felt at all. Every iPhone iOS 17 runs on has a Taptic
/// Engine; no iPad does, and neither does a Mac running the iPad app. There,
/// `UIImpactFeedbackGenerator` silently does nothing, so offering the haptic
/// settings would be offering a switch that is not connected to anything.
enum HapticSupport {
    static let isAvailable: Bool = {
        #if targetEnvironment(simulator)
        // The simulator has no engine but stands in for a device that does;
        // an iPhone simulator should look like an iPhone.
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #endif
    }()
}

@MainActor
final class BeatHaptics {
    /// Above this the beats arrive too quickly to be counted and the hand reads
    /// them as one continuous buzz, which says nothing a fast-blurring string
    /// has not already said better.
    ///
    /// Eight per second is about where a piano technician stops counting and
    /// starts hearing a tone, and the same limit applies to a fingertip. It also
    /// scales the way it should: beat rate is proportional to frequency, so this
    /// engages within about 170 cents on a low E and about 40 on the high E —
    /// wide where the string is slow and hard to hear, tight where it is not.
    static let maximumBeatHz = 8.0
    /// Hard floor between taps, whatever the beat is doing. The Taptic Engine
    /// will happily be asked for more than it can render and the result is a
    /// mush rather than a rhythm.
    static let minimumInterval = 0.075
    /// Soft: this fires many times per second and must never compete with §7's
    /// single arrival tick, which is the one event that should feel decisive.
    static let intensity = 0.45

    private let generator = UIImpactFeedbackGenerator(style: .soft)
    private var prepared = false
    private var lastFire: Double = 0

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { prepared = false }
        }
    }

    /// - Parameters:
    ///   - beat: whether `WobblePhase` completed a cycle this frame.
    ///   - beatHz: the current beat rate, for the too-fast-to-count cutoff.
    ///   - hasPitch: nothing is beating against nothing.
    ///   - now: `CACurrentMediaTime`, passed in so the caller's clock is the
    ///     only clock.
    func update(beat: Bool, beatHz: Double, hasPitch: Bool, now: Double) {
        guard isEnabled, hasPitch else {
            // Let the engine go cold rather than holding it warm through
            // silence; it is re-prepared on the next reading.
            prepared = false
            return
        }
        guard beatHz > 0, beatHz <= BeatHaptics.maximumBeatHz else { return }

        if !prepared {
            generator.prepare()
            prepared = true
        }
        guard beat, now - lastFire >= BeatHaptics.minimumInterval else { return }
        lastFire = now
        generator.impactOccurred(intensity: BeatHaptics.intensity)
    }

    func stop() { prepared = false }
}
