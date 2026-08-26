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

**Two questions, not one.** Finding a note and following one are different
problems, and asking them with the same thresholds is what made the app let go
of notes a guitarist could still plainly hear. Traced on an unplugged low E
decaying into room tone, the harmonic scorer named E2 correctly out to five
seconds while clarity and contrast both fell through their floors at 2.5 s — the
evidence was sitting there and the display went dark.

So the detector has two states. **Searching** is strict: contrast 8.0, nine
agreeing frames, the whole 25–1300 Hz range in play, because the answer might be
"nothing" and being wrong invents a note out of the room. **Tracking** is not:
there is one hypothesis, its frequency is known to within a few cents, and being
wrong costs a stale reading rather than a false one. Contrast drops to 2.6 and
the lag search is confined to a bracket around the string being followed.

That bracket is what lets the floors come down. The readings that made a 0.60
clarity gate necessary were 41 Hz, 27 Hz and 63 Hz against a true 82 — an
unconstrained lag search collapsing to subharmonics as noise closes in. Inside a
narrow bracket those candidates do not exist, so the gate is no longer carrying
that weight.

|                          | one state | two states |
|--------------------------|-----------|------------|
| acoustic E2              | 4.2 s     | 6.0 s      |
| unplugged E2, quiet room | 3.5 s     | 5.8 s      |
| unplugged E2, 9 dB down  | 2.4 s     | 4.3 s      |
| unplugged E2, 2 dB down  | 1.1 s     | 2.9 s      |

*Time still tracking, against room tone at −72 dBFS.*

The same split fixes acquisition, because the spectrum and the NSDF are each
reliable at a different question. The scorer says *which string*; the NSDF says
exactly *where* it is, searching only around that answer. Neither is asked to
work alone.

That steering is a rescue, never a replacement — the open search runs first and
the constrained one only when it fails. The scorer can only ever propose one of
six strings, so it has an opinion about signals that are not strings at all: a
bare 440 Hz reference tone was read as D3, because 440 is the third harmonic of
146.67 and of the six hypotheses D3 explains it best. Asking openly first costs
one extra scan of an array that is already computed and keeps §4's chromatic
fallback intact.

**Coasting.** Inside the release window the last reading is republished and the
stage dims rather than blanking. A tuner that flickers off between the frames it
is unsure about reads as broken even when the detector is doing the right thing.
The window is bounded at ~550 ms: a reading older than that is a lie, not a
kindness.

**Telling the instrument from the room.** A tuner knows its own answers: there
are six of them. So rather than estimating a frequency and then asking which
string it lands near, the detector asks how well each *target* explains the
spectrum — the shape of TC Electronic's PolyTune patent and of moekadu Tuner's
harmonic energy measure.

Four things gate a reading, multiplicatively, because no single one is enough:

- **Directional pickup.** A cardioid polar pattern where the device offers one,
  which attenuates a television across the room before a sample is captured.
- **Level** — measured, and deliberately *not* a veto. See below.
- **Contrast** — how far the best-fitting string stands out from frequencies
  that are not strings at all. A real note makes a sharp peak; broadband noise
  raises every hypothesis equally. Measured medians: guitar 7.2–28.9, background
  speech 4.3–5.6, room noise 2.1.
- **Pitch stability**, because a plucked string settles and stays put while
  speech glides.

The spectrum is whitened before any of this: the in-frame noise floor, estimated
as a low percentile of each ~140 Hz block, is subtracted from every bin. Every
score here is a ratio against the in-band total, so stationary room tone does not
cancel out — it inflates the denominator *and* leaks into every candidate's
partials, lifting the decoys and squashing the contrast between them. It is
PEFAC's spectral normalisation reduced to its causal core, and it halves the
frames on which speech is mistaken for an instrument. Estimating across frequency
rather than across time matters: a temporal tracker following a note that rings
for six seconds eventually learns the note as noise.

Level deliberately is *not* among them either, which is the correction that
made the tuner work on an unplugged electric. A solid body has no soundboard and
no air cavity, so the only radiator is the string, and a string is a dipole
whose efficiency collapses when its length is a fraction of a wavelength — low E
at 82 Hz has a 4-metre wavelength against a 65 cm string. What reaches a phone is
20–30 dB down on an acoustic and decays from there. The level gate rejected 60%
of those frames at −63 dBFS and 100% at −75, and removing it entirely costs
nothing:

|                            | with level veto | without |
|----------------------------|-----------------|---------|
| unplugged E2 at −83 dBFS   | 0%              | 97.3%   |
| room noise, all levels     | 0%              | 0%      |
| true silence / dither      | 0%              | 0%      |

Level is not evidence about whether an instrument is present; harmonic structure
is. The floor is still measured — it is worth showing in Settings — and it now
learns from frames where the *harmonic evidence* says no instrument, rather than
from frames where the detector found no periodicity. A quiet sustained note is
continuously periodic, so under the old test the floor was never measured at all
and an initial guess silenced the instrument forever.

Clarity deliberately is *not* among them. Measured through a modelled phone
microphone, background speech scores 0.994 against a plucked string's 0.921 — a
glottal pulse train is extremely periodic — so raising a clarity floor rejects
the instrument and keeps the interference. Absolute harmonic energy is out for
the same reason: A2 measured 0.147 against speech at 0.221, so only the
*contrast* between target and non-target is comparable across strings.

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
              noise gate, harmonic target scoring, pitch-stability gate
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
