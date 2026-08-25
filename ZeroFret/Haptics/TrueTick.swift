//  TrueTick.swift
//  Zero Fret
//
//  Spec §7. One tick when the note crosses into tune, and then nothing until it
//  has genuinely left.
//
//  The latch is the entire point. A hand vibrating around zero without one
//  produces continuous haptic buzz, and users report that as the app being
//  broken rather than as their own hand.

import UIKit

@MainActor
final class TrueTick {
    /// §7: re-arm only once |cents| exceeds this multiple of the tolerance.
    static let rearmMultiplier = 3.0

    private let generator = UIImpactFeedbackGenerator(style: .rigid)
    private var armed = true
    private var prepared = false

    var isEnabled = true

    /// Call when a pitch first appears, so the Taptic Engine is warm.
    func prepare() {
        guard !prepared else { return }
        generator.prepare()
        prepared = true
    }

    /// Call once per display frame.
    /// - Parameter cents: nil when no pitch is present.
    func update(cents: Double?, tolerance: Double) {
        guard let cents else {
            // No pitch: let the engine go cold, but stay latched so that
            // re-attacking an already-in-tune string does not tick.
            prepared = false
            return
        }
        prepare()

        let magnitude = abs(cents)
        if magnitude <= tolerance {
            if armed {
                armed = false
                if isEnabled { generator.impactOccurred() }
            }
        } else if magnitude > tolerance * TrueTick.rearmMultiplier {
            armed = true
        }
    }

    /// Reset on tuning change, string pin, or engine restart.
    func rearm() {
        armed = true
    }
}
