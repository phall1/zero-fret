# Zero Fret

A guitar and bass tuner for iOS that shows you a string, not a needle.

The reading is a standing wave whose wobble beats at `|f_measured − f_target|`
and whose amplitude tracks how far out you are. When the note lands inside the
tolerance band the wave goes still, turns near-white, and glows. One haptic tick.
That is the whole interface.

Built to [`zero-fret-og-spec.md`](zero-fret-og-spec.md), which is in the repo and
is the authority. Every non-obvious constant in the source cites the section it
comes from.

---

## Status

| | |
|---|---|
| Platform | iOS 17.0+, iPhone and iPad |
| Language | Swift 5, SwiftUI |
| Dependencies | none — Accelerate, AVFoundation, UIKit, SwiftUI |
| Project | plain Xcode project, no SPM packages, no workspace |
| Tests | Host tests over the DSP and model layers, plus UI tests for the stage, thumb zone, sheets and landscape |

## Build

```sh
open ZeroFret.xcodeproj                      # or:
xcodebuild build -scheme ZeroFret -destination 'generic/platform=iOS'
xcodebuild test  -scheme ZeroFret -destination 'platform=iOS Simulator,name=iPhone 17'
```

The tuner is useless against the Simulator's microphone — it resamples and
applies processing you cannot disable, and produces plausible-looking wrong
answers. Two things follow from that:

- The **unit test bundle has no host app**. It compiles the pure DSP and model
  layer and drives it with synthesised signals, so it runs anywhere.
- The **app feeds itself a generated signal in the Simulator** and labels the
  readout `DEMO`. Everything downstream of the ring buffer is the real code path
  on real data structures, which is what makes the UI tests meaningful. On device
  that file compiles to nothing.

## How it works

```
AVAudioEngine tap  ──▶  RingBuffer  ──▶  detect queue  ──▶  SnapshotBuffer  ──▶  CADisplayLink  ──▶  SwiftUI
   real-time         lock-free SPSC     biquad + MPM       triple-buffered       phase, haptics       Canvas
```

**Capture.** `.playAndRecord` in `.measurement` mode — the default mode applies
automatic gain control and an input EQ curve, and both quietly cost you 2–6¢
depending on pick attack. The sample rate is read back from
`inputNode.inputFormat(forBus:)` after the session goes active and every derived
constant follows it, because `setPreferredSampleRate` is a request and Bluetooth
routes answer 16 or 24 kHz.

**Hand-off.** The tap runs on a real-time thread, so it does two things: a
`memcpy` into preallocated ring storage and one release-ordered atomic store. No
locks, no allocation, no ARC. `ZFAtomics.h` is twenty lines of C because
`Synchronization.Atomic` is iOS 18+ and the deployment target is 17.

**Detection.** A 2nd-order Butterworth highpass at 40 Hz and lowpass at 1 kHz,
state persisted across hops, then the McLeod normalised square difference
function with FFT-accelerated autocorrelation. The peak picker takes the *first*
NSDF peak at or above 0.9 × max, not the global maximum — the global maximum sits
at 2τ or 3τ often enough that naive tuners read low E as E3. Parabolic
interpolation on the chosen peak; without it the resolution floor is ~6¢ at E4.

**Telling the instrument from the room.** Three gates, in order. Level, against
a noise floor learned *only* from frames with no detected pitch — measuring it
regardless of what is playing makes a ringing note its own floor, and the gate
then mutes the note as it decays. Clarity, per §3. And pitch stability, which is
the one that does the work: a plucked string settles onto a pitch and stays
there (6-frame spread ~6 cents) while speech glides continuously (~41 cents).

Clarity deliberately is *not* the discriminator here. Measured through a
modelled phone microphone, background speech scores 0.994 against a plucked
string's 0.921 — a glottal pulse train is extremely periodic — so raising the
clarity floor rejects the instrument and keeps the interference.

**Smoothing.** Median-of-5 then a one-euro filter, on frequency in Hz. The median
is first because a surviving octave error is exactly one wild frame — a mean
averages it in, a median deletes it.

**Display.** Phase is *accumulated* (`phase += 2π · beat · dt`), never evaluated
from absolute time. The beat frequency changes every frame while somebody is
tuning, and `sin(2π · beat · t)` snaps every time it does — a bug that reads as a
noisy detector when the detector is fine.

## Running it on a phone

```sh
Scripts/device.sh          # build, install and launch on a connected iPhone
Scripts/archive.sh         # archive + export a signed .ipa
Scripts/archive.sh --upload  # ...and send it to TestFlight
```

Signing needs your own Apple credentials; see [docs/SHIPPING.md](docs/SHIPPING.md).
Nothing account-identifying is tracked — `Config/Signing.xcconfig` is gitignored
and `Config/Signing.example.xcconfig` shows what goes in it.

## Layout

```
ZeroFret/
  App/        entry point, Info.plist
  Audio/      session, ring buffer, biquad, MPM detector, smoothing,
              noise gate, pitch-stability gate
  Model/      tuning maths, string assignment, snapshot buffer, coordinator
  View/       stage, string canvas, tuning sheet, settings
  Haptics/    the latch that stops the tick machine-gunning
  Support/    C atomics shim + bridging header
```

## Tunings

Guitar Standard, Drop D, E♭, D Standard, DADGAD, Open G, Open D, 7-string,
8-string. Bass 4-, 5- and 6-string.

Targets are stored as MIDI note numbers and Hz is always derived
(`f(n) = referenceA · 2^((n−69)/12)`), so the reference-pitch setting moves the
whole instrument rather than one string. Anything whose lowest string falls below
A1 analyses an 8192-sample window instead of 4096, because B0 at 30.87 Hz does
not hold three periods in 4096 and the NSDF peak stops being trustworthy.

## Privacy

The microphone runs only in the foreground. There is deliberately no `audio`
entry in `UIBackgroundModes`. Nothing is recorded, stored, or transmitted.

## Acceptance

`docs/ACCEPTANCE.md` tracks all eleven criteria from §9 — which are covered by
the host test suite and which need a physical device and an instrument.

## Licence

MIT. See [LICENSE](LICENSE).
