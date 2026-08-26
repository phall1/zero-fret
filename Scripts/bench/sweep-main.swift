import Foundation

// Scratch pad for threshold sweeps. Edit the loop, run `./run.sh sweep`, read
// the table, pick the value, write down what it cost in the source comment
// beside the constant. Left in the repo deliberately: the numbers in those
// comments are only trustworthy if regenerating them is easy.

@main struct SweepMain {
  static func main() {
    let std = TuningLibrary.standard
    func hz(_ m: Int) -> Double { MusicMath.frequency(midi: Double(m), referenceA: 440) }
    let e2 = hz(40)

    // Instrument cases that must not get worse, and rejection cases that should.
    let keep: [(String, [Float], Double, Int?)] = [
        ("acoustic E2 -45", normalise(acoustic(e2, sympathetic: [hz(45), hz(50), hz(55)]), to: -45), e2, 0),
        ("acoustic A2 -55", normalise(acoustic(hz(45), sympathetic: [e2, hz(50)]), to: -55), hz(45), 1),
        ("unplugged E2 -70", normalise(unplugged(e2), to: -70), e2, 0),
        ("E2 -55 + room -72", mix(normalise(unplugged(e2), to: -55), normalise(room(seconds: 6), to: -72)), e2, 0),
        ("E2 -63 + room -72", mix(normalise(unplugged(e2), to: -63), normalise(room(seconds: 6), to: -72)), e2, 0),
        ("E2 -70 + room -72", mix(normalise(unplugged(e2), to: -70), normalise(room(seconds: 6), to: -72)), e2, 0),
        ("peg turn A2", normalise(pegTurn(hz(45), fromCents: -60, toCents: 0), to: -45), hz(45), 1),
    ]
    let reject: [(String, [Float])] = [
        ("speech -45", normalise(speech(seconds: 8), to: -45)),
        ("speech f0=98", normalise(speech(seconds: 8, basePitch: 98, seed: 3), to: -45)),
        ("speech f0=170", normalise(speech(seconds: 8, basePitch: 170, seed: 5), to: -45)),
        ("room -45", normalise(room(seconds: 8), to: -45)),
    ]

    print("acquire | keep: coverage%                                            | reject: voiced%")
    for acq in [4.5, 6.0, 8.0, 10.0, 13.0] {
        var cfg = Cfg(); cfg.acquireContrast = acq
        var ks: [String] = [], rs: [String] = []
        for (_, sig, truth, str) in keep {
            ks.append(String(format: "%5.1f", run(sig, tuning: std, truth: truth, string: str, cfg: cfg).coverage))
        }
        for (_, sig) in reject {
            rs.append(String(format: "%5.1f", run(sig, tuning: std, truth: 0, string: nil, cfg: cfg).coverage))
        }
        print("\(String(format: "%7.1f", acq)) | \(ks.joined(separator: " ")) | \(rs.joined(separator: " "))")
    }
    print("keep order:   " + keep.map(\.0).joined(separator: " | "))
    print("reject order: " + reject.map(\.0).joined(separator: " | "))
  }
}
