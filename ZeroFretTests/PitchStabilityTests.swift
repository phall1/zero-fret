import XCTest

final class PitchStabilityTests: XCTestCase {
    /// Feed a constant pitch and report the frame index at which it was admitted.
    private func framesToAcquire(hz: Double, jitterCents: Double = 0,
                                 seed: UInt64 = 1) -> Int? {
        var gate = PitchStability()
        var rng = SplitMix64(seed: seed)
        for i in 0..<40 {
            let offset = jitterCents == 0 ? 0 : (rng.nextUnit() * 2 - 1) * jitterCents
            let f = hz * pow(2, offset / 1200)
            if gate.admit(frequency: f, voiced: true) { return i }
        }
        return nil
    }

    func testDeadSteadyPitchTakesTheFastPath() {
        // A clean pluck in a quiet room: 6 frames, ~128 ms at hop 1024.
        XCTAssertEqual(framesToAcquire(hz: 82.41), PitchStability.fastAcquireFrames - 1)
    }

    func testSlightlyJitteryPitchStillAcquires() {
        // Too jittery for the fast tier, fine for the slow one.
        guard let n = framesToAcquire(hz: 110.0, jitterCents: 3.0) else {
            return XCTFail("a 3-cent-jitter pitch should still acquire")
        }
        XCTAssertGreaterThanOrEqual(n, PitchStability.fastAcquireFrames - 1)
        XCTAssertLessThanOrEqual(n, PitchStability.acquireFrames + 4)
    }

    func testWanderingPitchNeverAcquires() {
        // Speech glides tens of cents per frame. It must never lock.
        var gate = PitchStability()
        var rng = SplitMix64(seed: 99)
        var admitted = 0
        var f = 130.0
        for _ in 0..<200 {
            f *= pow(2, ((rng.nextUnit() * 2 - 1) * 45.0) / 1200)
            f = min(max(f, 90), 260)
            if gate.admit(frequency: f, voiced: true) { admitted += 1 }
        }
        XCTAssertEqual(admitted, 0, "a pitch wandering ±45 cents per frame must not lock")
    }

    func testUnvoicedFramesDoNotAcquire() {
        var gate = PitchStability()
        for _ in 0..<50 {
            XCTAssertFalse(gate.admit(frequency: 110, voiced: false))
        }
        XCTAssertFalse(gate.isLocked)
    }

    func testLockSurvivesABend() {
        // §5's Fast mode is supposed to track bends, so holding must not re-test
        // spread — only frame-to-frame continuity.
        var gate = PitchStability()
        for _ in 0..<10 { _ = gate.admit(frequency: 110, voiced: true) }
        XCTAssertTrue(gate.isLocked)

        var f = 110.0
        var held = true
        for _ in 0..<40 {          // a whole tone over ~850 ms
            f *= pow(2, 5.0 / 1200)
            if !gate.admit(frequency: f, voiced: true) { held = false }
        }
        XCTAssertTrue(held, "a 5-cent-per-frame bend must not break the lock")
        XCTAssertGreaterThan(f, 120.0)
    }

    func testLockDropsOnRepeatedWildJumps() {
        var gate = PitchStability()
        for _ in 0..<10 { _ = gate.admit(frequency: 110, voiced: true) }
        XCTAssertTrue(gate.isLocked)
        for _ in 0..<PitchStability.holdJumpsAllowed {
            _ = gate.admit(frequency: 220, voiced: true)   // an octave, every frame
        }
        XCTAssertFalse(gate.isLocked, "sustained octave-sized jumps must drop the lock")
    }

    func testLockDropsAfterSilence() {
        var gate = PitchStability()
        for _ in 0..<10 { _ = gate.admit(frequency: 110, voiced: true) }
        XCTAssertTrue(gate.isLocked)
        for _ in 0..<PitchStability.holdMisses {
            _ = gate.admit(frequency: 0, voiced: false)
        }
        XCTAssertFalse(gate.isLocked)
    }

    /// §9 test 8 budget: acquisition must not eat the 400 ms cold-launch target.
    func testAcquisitionLatencyFitsTheColdLaunchBudget() {
        let hopSeconds = 1024.0 / 48000.0
        let windowFill = 4096.0 / 48000.0
        let fast = Double(PitchStability.fastAcquireFrames) * hopSeconds
        let slow = Double(PitchStability.acquireFrames) * hopSeconds
        XCTAssertLessThan(windowFill + fast, 0.25, "fast path leaves no headroom")
        XCTAssertLessThan(windowFill + slow, 0.30, "slow path leaves no headroom")
    }
}
