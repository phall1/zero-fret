# Acceptance — spec §9

Eleven criteria. Six are answerable on the host with synthesised signals and are
covered by the test bundle; five need a physical device, an instrument, and in
two cases a phone call. §9 calls out 1, 4 and 5 as the ones that fail, so run
those first.

The Simulator's microphone is unusable for any of this. It resamples, applies
processing you cannot disable, and produces plausible-looking wrong answers.

## Covered by `xcodebuild test`

| # | Criterion | Test |
|---|---|---|
| 1 | E2 with the tone rolled off reads E2, never E3, 20 consecutive picks | `AcceptanceTests.testAcceptance1_LowEIsNeverAnOctaveHigh` — 20 picks across dark, bright and weak-fundamental voicings, each with independent partial phases |
| 2 | 12th-fret harmonic on low E reads E3 with clarity > 0.9 | `AcceptanceTests.testAcceptance2_TwelfthFretHarmonic` |
| 3 | Generated 440.0 Hz reads within ±0.5¢ | `AcceptanceTests.testAcceptance3_ReferenceToneWithinHalfACent` |
| 4 | The same tone with the reference at 442.0 reads −7.9¢ | `AcceptanceTests.testAcceptance4_SameToneAtReference442`, `MusicMathTests.testAcceptance4_440AgainstReference442` |
| 7 | Bass low B (30.87 Hz) locks within 1 s, clarity > 0.7 | `AcceptanceTests.testAcceptance7_BassLowB` |
| 10 | Silence produces no phantom notes | `AcceptanceTests.testAcceptance10_SilenceProducesNothing` |
| 11 | No allocation growth across sustained analysis (host half) | `AcceptanceTests.testNoAllocationGrowthAcrossManyFrames`, `PitchDetectorTests.testFrameBudget` |

Tests 3 and 4 exercise the chromatic-fallback path rather than string
assignment: 440 Hz is 500¢ from E4 and every string in standard tuning is
rejected by the §4 sixty-cent rule, so without a chromatic fallback the app
could not report a bare reference tone at all.

## Device-only

Run on a physical iPhone. `mk42` (iPhone 13 Pro) is registered on the team and
has ProMotion, which criteria 8 and the 120 Hz path need.

| # | Criterion | How to run | Result |
|---|---|---|---|
| 5 | AirPods connected then disconnected mid-detection: continues without restart, no cents offset | Play a sustained note, pull the AirPods out of range. Watch the Sample rate row in Settings change and the cents reading stay put. | ☐ |
| 6 | Incoming call, then dismiss: resumes automatically | Call the phone from another one, decline. The reading should come back with no interaction. | ☐ |
| 8 | Cold launch to first pitch reading < 400 ms, device unplugged | Force-quit, start a stopwatch, launch and pick. 4096 at 48 kHz is an 85 ms window; the rest is engine start. | ☐ |
| 9 | Hold in tune for 60 s: exactly one haptic tick | Tune, then hold. The §7 latch does not re-arm until the note passes ±3× tolerance. | ☐ |
| 10 | Silence for 10 s: display blanks, idle timer re-enabled | Watch the readout blank after 250 ms of hold, then leave it. Sleep re-enables 45 s later. | ☐ |
| 11 | Instruments, 5 min continuous: no allocation growth, no priority inversions on the audio thread | Allocations + Time Profiler. The tap does one `memcpy` and one atomic store; anything else showing up there is a regression. | ☐ |

## UI coverage

`ZeroFretUITests` drives the Simulator against the synthetic input source and
covers what the host bundle structurally cannot: that the stage produces a
reading at all, that tapping a string chip pins and releases it, that the tuning
sheet and Settings round-trip, and that nothing escapes the window in landscape.

It is not a substitute for any of the device tests above — the input is
generated, so it says nothing about the microphone, the audio session, or the
detector's behaviour on a real string.

## Noise rejection

`Scripts/` has no benchmark for this, but the scenario harness used to tune the
gates lives in the commit history for `fix(audio): separate the instrument from
the room`. It replays a plucked string, sympathetic ringing of the other five,
pick attack, room noise and synthesised speech through a modelled phone
microphone, and reports voiced-frame rate, string-assignment correctness and
switch count.

Thresholds in `PitchStability` were swept against that set rather than chosen by
feel; the sweep table is in the source. They are calibrated to a *model* of a
room, so they are a starting point for on-device judgement, not a substitute for
it.

Worth re-checking on device:

| | |
|---|---|
| Low E held with a TV or conversation in the room | ☐ |
| First reading after a pluck does not feel sluggish (128 ms settle) | ☐ |
| Nothing displayed when the instrument is silent but the room is not | ☐ |
| A bend still tracks smoothly rather than dropping the lock | ☐ |

## What the host suite deliberately does not prove

- **Microphone frequency response.** Everything upstream of `AVAudioEngine` is
  untested here by construction.
- **Real-time safety.** The tap's discipline is enforced by review and by
  Instruments, not by a unit test.
- **Actual 120 Hz.** `CADisableMinimumFrameDurationOnPhone` plus
  `preferredFrameRateRange` is the documented pair; confirm with the Core
  Animation FPS gauge on a ProMotion device.
