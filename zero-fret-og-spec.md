# ZERO FRET — iOS build spec

Everything here is a decision, not an option. Where a value appears, it was chosen for a reason
stated inline. Deviating is allowed; guessing is not.

Target: iOS 17.0+. Swift 5.9+. Zero third-party dependencies. Xcode project, no SPM packages.

---

## 0. The five things that break overnight builds

Read these first. Each has killed a working tuner.

1. **`AVAudioSession` mode must be `.measurement`.** Default mode applies automatic gain control
   and an input EQ curve. Both corrupt amplitude and smear onsets, and your cents readings will
   drift by 2–6¢ depending on how hard you pick. This is the single most common tuner bug and it
   is invisible — the app *works*, it's just wrong.

2. **Never assume 48 kHz.** `setPreferredSampleRate(48000)` is a request. Bluetooth routes will
   hand you 16 kHz or 24 kHz. Read `engine.inputNode.inputFormat(forBus: 0).sampleRate` after the
   engine starts and derive every constant from it. Hardcoding 48000 produces a tuner that is
   exactly a fixed number of cents wrong on AirPods.

3. **Phase must be accumulated, not computed.** The string's wobble uses the beat frequency, which
   changes every frame as the user tunes. `sin(2π · beat · t)` snaps discontinuously whenever
   `beat` changes. Integrate instead: `phase += 2π · beat · dt`, wrap at 2π. Computing from
   absolute time produces a string that visibly jumps, and the bug reads as "the detector is
   noisy" when it isn't.

4. **Pick the first NSDF peak above threshold, not the highest.** The global maximum of the
   normalized autocorrelation is frequently at 2× or 3× the true period. This is why naive tuners
   read low E as E3. Detail in §3.

5. **`CADisableMinimumFrameDurationOnPhone` must be `true` in Info.plist** or iPhone caps you at
   60 Hz regardless of ProMotion and the display link config.

---

## 1. Project shape

```
ZeroFret/
  App/
    ZeroFretApp.swift          // @main, scene, idle timer
    Info.plist
  Audio/
    AudioEngine.swift          // session config, engine, tap, lifecycle
    RingBuffer.swift           // lock-free SPSC float ring
    PitchDetector.swift        // NSDF/MPM via vDSP
    Smoother.swift             // median-5 + one-euro
  Model/
    Tuning.swift               // MIDI-number based tuning defs
    TunerState.swift           // observable snapshot for the view layer
    StringAssigner.swift       // target selection + hysteresis
  View/
    TunerView.swift            // stage + thumb zone
    StringCanvas.swift         // Canvas + TimelineView polyline
    TuningSheet.swift
    SettingsView.swift
  Haptics/
    TrueTick.swift
```

Single target. No app groups, no extensions night one.

### Info.plist — exact keys

| Key | Value | Why |
|---|---|---|
| `NSMicrophoneUsageDescription` | `Zero Fret listens to your instrument to show you how far off you are. Audio never leaves your device and is never recorded.` | Rejection risk if vague. State the negative explicitly. |
| `CADisableMinimumFrameDurationOnPhone` | `true` | Unlocks >60 Hz on iPhone. |
| `UIBackgroundModes` | **absent** | Do not add `audio`. Adding it means the mic can run backgrounded, which triggers review scrutiny and the orange indicator persists. |
| `UIRequiresFullScreen` | `false` | — |
| `UISupportedInterfaceOrientations` | Portrait + both landscape | Landscape is a real use case with a strapped guitar. |

---

## 2. Audio capture

### Session configuration — exact call order

```
try session.setCategory(.playAndRecord,
                        mode: .measurement,
                        options: [.defaultToSpeaker, .allowBluetoothA2DP])
try session.setPreferredSampleRate(48000)
try session.setPreferredIOBufferDuration(0.005)   // ~256 frames @ 48k
try session.setActive(true)
```

- `.playAndRecord` not `.record`, because reference tone playback exists in v1. `.record` cannot
  play audio and switching categories mid-session drops the input node.
- `.defaultToSpeaker` or the reference tone comes out the earpiece.
- **Do not** pass `.mixWithOthers`. It lowers your input priority and inflates jitter.
- **Do not** call `setInputGain` unless `session.isInputGainSettable` is true. It throws otherwise.

### Permission (iOS 17+)

`AVAudioApplication.requestRecordPermission(completionHandler:)`.
The older `AVAudioSession.sharedInstance().requestRecordPermission` is deprecated in 17 and will
warn. Check `AVAudioApplication.shared.recordPermission` for current state.

### Lifecycle — the two notifications that are not optional

Both of these silently kill the engine and the app appears frozen. Handle both:

- `AVAudioSession.interruptionNotification` — on `.ended` with `.shouldResume`, reactivate the
  session and restart the engine. Phone calls and timers hit this constantly.
- `AVAudioSession.routeChangeNotification` — on `.oldDeviceUnavailable` and `.newDeviceAvailable`,
  tear down the tap, re-read the input format (sample rate may have changed), reinstall, restart.

Also handle `.willEnterForeground` / `.didEnterBackground` to start and stop the engine. Mic is
live only in the foreground. This is a product commitment, not just hygiene.

### Tap

```
let fmt = engine.inputNode.inputFormat(forBus: 0)   // read AFTER setActive
engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in ... }
```

`bufferSize` is a hint; the callback may deliver a different frame count. Never assume.

**The tap callback runs on a real-time thread.** Inside it, the only legal operations are:
copying floats into the preallocated ring buffer and an atomic store. No allocation, no locks, no
`os_log`, no `print`, no `DispatchQueue.sync`, no Swift `Array` growth, no ARC traffic on
non-trivial types. Violating this produces intermittent audio glitches that are nearly impossible
to attribute later.

Detection runs on a separate `DispatchQueue(label: "detect", qos: .userInteractive)` draining the
ring. Results publish via a triple-buffered snapshot struct read by the display link.

---

## 3. Pitch detection — MPM / NSDF

### Windowing

| Instrument class | Window | Hop | Rationale |
|---|---|---|---|
| Guitar / uke / mandolin | 4096 | 1024 | 85 ms @ 48k. Holds ≥3 periods of E2 (82.41 Hz, period 582 samples). |
| Bass (4/5-string) | 8192 | 2048 | B0 is 30.87 Hz, period 1555 samples. 4096 gives <3 periods and the NSDF peak becomes unreliable. |

Switch window size when the assigned instrument changes. Do not run 8192 universally — the added
latency is perceptible and makes the app feel dead.

### Pre-filter

Apply before autocorrelation, in this order:

1. **Highpass, 2nd-order Butterworth, fc = 40 Hz.** Kills handling noise, HVAC rumble, and table
   thumps. Do **not** set this above 45 Hz — E2's fundamental is 82 Hz and a steep 60 Hz corner
   audibly weakens it.
2. **Lowpass, 2nd-order Butterworth, fc = 1000 Hz.** MPM degrades when upper harmonics dominate,
   which is exactly what a bright new string does. This single filter removes most octave errors
   before they happen.

Use `vDSP_biquad` with precomputed coefficients. Persist filter state across hops.

### NSDF

Compute the McLeod normalized square difference function:

```
n'(τ) = 2·r(τ) / m(τ)
```

where `r(τ)` is the autocorrelation and `m(τ) = Σ(x[j]² + x[j+τ]²)` over the overlap.

- Compute `r(τ)` via FFT: zero-pad to `2N`, forward FFT, multiply by conjugate, inverse FFT.
  Use `vDSP.FFT<DSPSplitComplex>` with `log2n = 13` for N=4096. Direct O(N²) autocorrelation at
  4096 will not hold your frame budget on older devices.
- Compute `m(τ)` incrementally from a running power sum — recomputing it per lag is the naive
  mistake that makes this slow.

### Peak picking — the octave-error fix

1. Find all **positively-sloped zero crossings** in `n'(τ)`.
2. Between each consecutive pair of zero crossings, record the maximum. These are the candidates.
3. Let `maxVal` be the largest candidate value.
4. **Select the first candidate whose value ≥ `k · maxVal`, with `k = 0.9`.**

Step 4 is the whole trick. Taking the global max instead selects a harmonic-multiple period and
reports the note an octave high. `k` below 0.8 causes subharmonic errors; above 0.95 it degenerates
to the global-max behavior.

5. **Parabolic interpolation** around the chosen peak's three samples for sub-sample τ. Without
   this your resolution floor is ~6¢ at E4 and the readout visibly quantizes.

```
f = sampleRate / τ_interpolated
```

### Clarity gate

`clarity = n'(τ_chosen)`, range 0…1.

- `clarity < 0.60` → no pitch. Hold the last valid reading for 250 ms, then blank the display.
- Also gate on RMS: below the noise floor (§5), no pitch regardless of clarity.

Do not display a note you don't believe. A tuner that guesses during silence is worse than one
that shows nothing.

---

## 4. Music math

**Store tuning targets as MIDI note numbers, never as Hz.** Hz is derived:

```
f(n) = referenceA · 2^((n − 69) / 12)
```

Hardcoding 82.41 Hz for low E means the 442 Hz reference setting silently does nothing, which is a
bug you will not notice until someone in an orchestra pit complains.

| String | MIDI | Hz @ A=440 |
|---|---|---|
| E2 | 40 | 82.4069 |
| A2 | 45 | 110.0000 |
| D3 | 50 | 146.8324 |
| G3 | 55 | 195.9977 |
| B3 | 59 | 246.9417 |
| E4 | 64 | 329.6276 |

```
cents = 1200 · log2(f_measured / f_target)
beatHz = |f_measured − f_target|
```

Bass low B = MIDI 23. 7-string low B = MIDI 35. 8-string F# = MIDI 30.

### String assignment with hysteresis

Naive nearest-target selection flickers between adjacent strings on harmonically rich notes,
and the display becomes unreadable.

- Candidate = target minimizing `|cents|`.
- **Switch only if the new candidate beats the current one by more than 20¢ of absolute error,
  sustained for 3 consecutive frames.**
- Manual pin (user tapped a string row) disables assignment entirely until tapped again.
- Reject any candidate with `|cents| > 60` — that's between two strings and means the detector
  is wrong or the user is playing something else.

---

## 5. Smoothing

Chain, in order, operating on **frequency in Hz**, not on cents:

1. **Median of 5.** Removes single-frame outliers, which are what octave errors look like after
   the peak-picker mostly fixes them. A mean here does not work — it averages the error in.
2. **One-euro filter.**

| Response mode | minCutoff | beta | dCutoff |
|---|---|---|---|
| Fast (default) | 4.0 | 0.05 | 1.0 |
| Steady | 1.0 | 0.007 | 1.0 |

Fast tracks bends and lets you hear the string settle. Steady is for a noisy stage. Auto mode
switches to Fast when frame-to-frame `|Δcents| > 15` for 2 frames, back to Steady after 1 s below.

### Noise gate auto-calibration

On foreground, measure RMS over 1.0 s. Set the gate to `floor + 12 dB`, clamped to
`[−60 dB, −30 dB]`. Recalibrate whenever no pitch has been detected for 5 s. This is the "Auto"
value shown live in Settings.

---

## 6. Rendering

### Display link

```
let link = CADisplayLink(target: ..., selector: ...)
link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
```

Combined with the Info.plist key from §0.5. Without both, you get 60 Hz.

### The string

`TimelineView(.animation) { Canvas { ... } }` is sufficient for night one. Metal is an
optimization, not a requirement — a 64-point polyline at 120 Hz is not a load.

Standing wave, 64 sample points across width:

```
envelope(x) = sin(π · x)                        // x normalized 0…1, pins both ends
shape(x)    = sin(2π · x)                       // single node at center
amplitude   = clamp(|cents| / 45, 0, 1) · maxAmp
y(x)        = midY + amplitude · envelope(x) · shape(x) · sin(phase)
phase      += 2π · beatHz · dt                  // ACCUMULATE. see §0.3
```

`maxAmp` = 32 pt. Clamp `beatHz` to 24 Hz max for display purposes — above that it aliases against
the frame rate and reads as noise rather than as "very out of tune". Amplitude already carries
that information.

### Color

| State | Color | Meaning |
|---|---|---|
| `cents < −tolerance` | `#E0A24A` | Flat / slack — warm |
| `cents > +tolerance` | `#7FC7E8` | Sharp / tense — cold |
| `|cents| ≤ tolerance` | `#EAF6F2` + 11 pt glow | True |

Direction, not correctness. Applies to the note glyph, the string, and the cents readout
simultaneously — one color change, three elements, same frame.

### Readout

Fixed-width field sized to `−00.0¢`, `.monospacedDigit()` font. It updates ~47×/s at hop 1024;
proportional digits make the entire block shimmer.

---

## 7. Haptics

`UIImpactFeedbackGenerator(style: .rigid)`. Call `prepare()` when a pitch first appears.

**Latch to prevent machine-gunning:**

- Fire once on the transition from outside to inside `±tolerance`.
- Do not fire again until `|cents|` has exceeded `3 × tolerance`.

Without the latch, a hand vibrating around zero produces continuous haptic buzz that users
describe as the app being broken.

---

## 8. Screen and lifecycle

```
UIApplication.shared.isIdleTimerDisabled = pitchPresent
```

Set on the main actor. Re-enable sleep after 45 s of no detected pitch. Leaving it permanently
disabled is a battery complaint and an App Review question.

---

## 9. Acceptance criteria

Physical device only. **The Simulator's microphone is unusable for this** — it resamples, applies
processing you cannot disable, and produces plausible-looking wrong answers.

| # | Test | Pass condition |
|---|---|---|
| 1 | Play E2 on an electric with the tone knob rolled off | Reads E2, never E3. 20 consecutive picks. |
| 2 | Play a harmonic at the 12th fret of low E | Reads E3 with clarity > 0.9 |
| 3 | Tune-fork or generated 440.0 Hz tone at the phone | Reads within ±0.5¢ |
| 4 | Same, with reference set to 442.0 | Reads −7.9¢ |
| 5 | AirPods connected, then disconnected mid-detection | Continues without restart, no cents offset |
| 6 | Incoming call, then dismiss | Resumes automatically |
| 7 | Bass low B (30.87 Hz) | Locks within 1 s, clarity > 0.7 |
| 8 | Cold launch to first pitch reading | < 400 ms wall clock, device unplugged |
| 9 | Hold in tune for 60 s | Exactly one haptic tick |
| 10 | Silence for 10 s | Display blanks, no phantom notes, idle timer re-enabled |
| 11 | Instruments profiler, 5 min continuous | No allocation growth; no priority inversions in the audio thread |

Tests 1, 4, and 5 are the ones that fail. Run them first.

---

## 10. Explicitly out of scope for night one

Android. watchOS. Strobe mode. Custom tuning creation. Temperaments beyond equal. Reference tone
playback. Left-handed layout. Ship the six strings, one tuning family, and the string visual.
