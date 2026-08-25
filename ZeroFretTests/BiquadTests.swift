import XCTest

final class BiquadTests: XCTestCase {
    private func gain(at frequency: Double, sampleRate: Double = 48000) -> Double {
        let filter = Biquad(sampleRate: sampleRate)
        // Two seconds so the transient is far behind the measured tail.
        var signal = Harness.sine(frequency, sampleRate: sampleRate, seconds: 1.0, level: 1.0)
        let count = signal.count
        signal.withUnsafeMutableBufferPointer {
            filter.process($0.baseAddress!, count: count)
        }
        let tail = Array(signal[(signal.count / 2)...])
        let peak = tail.map { Double(abs($0)) }.max() ?? 0
        return peak
    }

    func testPassbandIsFlatWhereItMatters() {
        // Every guitar and bass fundamental the app targets lives here.
        for f in [82.41, 110.0, 146.83, 196.0, 246.94, 329.63] {
            XCTAssertEqual(gain(at: f), 1.0, accuracy: 0.06, "\(f) Hz")
        }
    }

    func testHighpassCornerIsAt40Hz() {
        // -3 dB at the corner for a 2nd-order Butterworth.
        XCTAssertEqual(20 * log10(gain(at: 40)), -3.0, accuracy: 0.6)
    }

    func testLowpassCornerIsAt1000Hz() {
        XCTAssertEqual(20 * log10(gain(at: 1000)), -3.0, accuracy: 0.6)
    }

    func testRumbleIsKilledButLowEIsNot() {
        // §3: do not raise the highpass above 45 Hz — E2's fundamental is 82 Hz.
        XCTAssertLessThan(20 * log10(gain(at: 10)), -20)
        XCTAssertGreaterThan(20 * log10(gain(at: 82.41)), -1.0)
    }

    func testBassLowBSurvivesTheHighpass() {
        // Acceptance test 7 depends on 30.87 Hz still being usable.
        XCTAssertGreaterThan(20 * log10(gain(at: 30.87)), -12)
    }

    func testBrightHarmonicsAreAttenuated() {
        // The reason the lowpass exists: a bright new string's upper partials
        // are what push MPM into an octave error.
        XCTAssertLessThan(20 * log10(gain(at: 3000)), -18)
    }

    func testCoefficientsTrackSampleRate() {
        // A Bluetooth route can hand back 16 kHz. The corner must not move.
        for rate in [16000.0, 24000.0, 44100.0, 48000.0] {
            XCTAssertEqual(20 * log10(gain(at: 40, sampleRate: rate)), -3.0,
                           accuracy: 0.8, "fs=\(rate)")
        }
    }
}
