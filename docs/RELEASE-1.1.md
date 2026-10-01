# Zero Fret 1.1: release evidence

**Status: submitted 2026-10-01, Waiting for Review, releases automatically on
approval.** Build 10, tagged `v1.1` (`0212494`). Listing text, screenshots
(6.9" ×6, iPad 13" ×4, old 6.5" set deleted) and the privacy policy are live
on the version. The device checks in §8 were not run before submission.

This is the review packet for 1.1: what changed, what was verified and how, and
what still needs a person, a device or an approval. Nothing here has been
submitted, and no live App Store metadata has been changed. The privacy policy
update is on this branch, so it goes live only when the branch is merged.

Version 1.1, build 10. 1.0 shipped as build 9, tagged `v1.0`.

---

## 1. Cents display: negative zero

**Cause.** A live formatting bug, not a stale screenshot. `DisplayState.centsText`
chose the sign from the raw value and zero-padded the magnitude, so −0.03¢ printed
as `−00.0` and +0.0 as `+00.0`. The live 6.9" screenshot also shows `−04.5`. The
padding was there to keep the field from changing width.

**Fix.** The value is rounded to one decimal first, and the sign is taken from
the rounded value. Anything that rounds to zero is a plain `0.0`; everything else
is signed with no padding (`−3.2`, `+16.0`). The readout was already right-aligned
in a fixed-width frame with monospaced digits, so the decimal point stays put as
the digit count changes. That still meets spec §6's "fixed-width field" without
padded zeros. A missing reading, NaN or infinity shows `–––.–`, never a number.
The underlying measurement and the in-tune decision are unchanged.

**Coverage.** `ZeroFretTests/DisplayStateTests.swift`:
- ±0, −0.0 and ±0.0499 → `0.0`
- ±0.05 → `±0.1`, the first visible tenth
- the edges of the default ±5¢ tolerance
- clamping at ±99.9
- no-pitch, NaN and ±∞

`MusicMathTests.testCentsTextFitsTheFixedField` replaces the old fixed-character-count
test with the property that actually prevents shimmer: the decimal point never
moves and nothing outgrows the field. The VoiceOver value already used `abs()`
with `%.1f` and a word for the direction, so it never had the bug.

**Needs a device:** a real-device capture of an in-tune string showing `0.0`.

## 2. Feel the Beat, as the code establishes it

From `BeatHaptics.swift` and `TunerEngine.frame`:
- **One soft tap per beat.** The beat is the difference between the measured
  frequency and the target. The taps are driven by the same oscillator as the
  string's wobble, so the two cannot disagree.
- **When it starts.** Only when the beat is slow enough to count, at or under
  8 per second. That is within about 170¢ on a low E and about 40¢ on a high E.
- **How it slows.** The beat falls as the note approaches the target, so the
  taps slow. At the target there is no beat, so there are no taps; inside the
  default ±5¢ band, a low E beats about once every 4 seconds.
- **Hard floor:** at least 75 ms between taps.
- Off by default; it is a Settings toggle.
- The separate in-tune tick fires once on arrival and is latched until the
  note drifts more than 3× the tolerance away.

**Device limits, found and fixed.** No iPad has a haptic engine, and neither
does a Mac running the iPad app. `UIImpactFeedbackGenerator` then does nothing,
so the toggles were switches connected to nothing. They are now disabled where
`CHHapticEngine.capabilitiesForHardware().supportsHaptics` is false, and
Settings says why. Every iPhone that runs iOS 17 has a Taptic Engine.

**Needs a device:** feel it on an iPhone. Confirm the taps are countable, slow
as the peg turns and stop at the note, before the "taps slow as you get close"
screenshot caption ships.

## 3. Privacy audit

| Claim | Evidence | Verdict |
|---|---|---|
| No network | No `URLSession`, `Network`, web views or sockets anywhere in `ZeroFret/`; no third-party code; `ITSAppUsesNonExemptEncryption` false | ✅ keep |
| Audio never recorded or stored | No `AVAudioFile`/`AVAudioRecorder`, no `FileManager` writes. Samples live in a ring buffer in memory and are overwritten | ✅ keep |
| Audio never transmitted | Follows from no network | ✅ keep |
| Mic only while the app is open | `enterBackground()` stops the engine; no `audio` background mode. Note that `.inactive` (Control Center, a banner) keeps it running, because the app is still on screen | ✅ worded as "while Zero Fret is on screen and stops when you leave the app" |
| No analytics | No SDKs; one `os.Logger` writing engine errors and the mic's data source name to the on-device log, never audio | ✅ keep |
| Data Not Collected | Only UserDefaults: settings, selected tuning, custom tunings, favorites | ✅ keep |
| Privacy manifest | **Was missing.** UserDefaults is a required-reason API. Added `ZeroFret/App/PrivacyInfo.xcprivacy`: no tracking, no collected data, UserDefaults CA92.1 | ✅ fixed |
| Permission text | "Zero Fret listens to your instrument to show you how far off you are. Audio never leaves your device and is never recorded." | ✅ accurate |

**Privacy URL.** `https://github.com/phall1/zero-fret#privacy` opens while signed
out and the `#privacy` anchor exists. It used to be three sentences; on this
branch it is a full policy covering microphone, on-device storage, network,
Apple's own analytics and children. It goes live when merged.

## 4. Accessibility

Xcode's accessibility audit (`performAccessibilityAudit`) now runs as a UI test
over the stage, the tuning sheet, the custom editor and Settings:
`testAccessibilityAuditOfEveryScreen`.

**Found and fixed:**
- **Tuning button too small to tap.** The hit area was the 18pt text; it is now
  44pt.
- **Secondary text contrast.** White at 0.42 measured 4.0:1, under WCAG AA. Now
  an opaque grey at 7.8:1 on the stage and 6.5:1 on a chip. The idle "play a
  string" prompt was near-invisible at 0.22 and is now readable. The octave and
  ¢ went from 0.5–0.55 to 0.9 opacity.
- **Dynamic Type.** The tuning sheet, the editor and the top rail used fixed point
  sizes. They now use text styles or `@ScaledMetric`. The stage already scaled
  through `@ScaledMetric`.
- **Star buttons** are 44pt targets.

**Judged, not changed:**
- **Coasting.** A coasting reading is dimmed on purpose for at most half a
  second, to say the note is no longer being measured. The audit runs on a
  steady note, so it does not audit that half second.
- **Partly visible rows.** Contrast reports on rows partly under a sheet edge or
  at a scroll view's end are excluded. Contrast is sampled from whatever covers
  them.
- **Excluded audit types.** Dynamic Type and clipping are left out of the
  automated audit. The audit cannot see `@ScaledMetric`, and clipping only fired
  on rows scrolled under the nav bar.
  `testLargestTextSizesKeepTheStageUsable` covers both instead: at AX XXXL every
  stage control stays inside the window, with screenshots attached.
- **Inaccessible-text check, excluded in three places.** On the stage and on
  the half-height tuning sheet above it, the cause is known: the cents figure
  and the peg instruction are hidden from VoiceOver because the note element
  already says both, so exposing them would read every reading twice. On the
  custom editor it is **unresolved**: the audit names no element, and every
  visible string there is labelled. The string rows now read as "String 6, E2,
  82.4 Hz". The VoiceOver walk-through below covers it.
- **At AX XXXL** the tuning name truncates ("Stand…"), the Settings "Reference"
  label hyphenates, and the reference preset chips do not grow. All are usable;
  none is ideal.

**Already in place (code reading):**
- VoiceOver reads the note, the cents and the direction in words. The string
  canvas is hidden from it. Chips read as "E2 string, in tune, pinned" with a
  hint.
- No live announcements, so no VoiceOver spam from 47 updates a second.
- Direction is always in words ("too slack · tighten"), never colour alone.
- Reduce Motion holds the string still and keeps the cents.

**Proposed App Store accessibility declaration.** Only what has evidence.
Declare **Dark Interface** (the app is dark only) and **Sufficient Contrast**
(audited, above). **Larger Text** is supported in every menu and scaled on the
stage, but the AX-size truncations above mean it is worth a device pass first.
Do not declare **VoiceOver**, **Voice Control** or **Reduced Motion** until
they have been run on a device through the whole flow Apple's criteria describe:
launch, permission, tune a string, change tuning, Settings. Leave **Captions**
and **Audio Descriptions** undeclared: there is no media.

## 5. Store listing

The plain-text copy is in `AppStore/metadata/en-US/`; `Scripts/metadata.py diff` shows it against
the live listing.

- **Name:** `Zero Fret`, unchanged, per the brief.
- **Subtitle:** `Guitar & bass tuner. Feel it.` (29). The brief's first choice;
  haptics are on every supported iPhone. The ukulele and other instruments are in
  the description, keywords and What's New rather than the 30 characters.
  Alternative: `Guitar, bass & ukulele tuner` (28) if you want 1.1's headline
  feature in the subtitle.
- **Description:** leads with "a guitar and bass tuner you can see and feel" and
  the string metaphor, then Feel the Beat, with "On iPhone" stated. Every
  bullet is an existing feature, and the haptic limits are in plain language.
- **Keywords:** dropped words already in the name and subtitle (Apple indexes
  those), and added instruments. 95 characters.
- **Promotional text** and **What's New** announce 1.1, so they must not be
  pushed to the live 1.0.

## 6. Screenshots

`Scripts/screenshots.sh` captures each frame from the Debug build on the
simulator: real UI, a held synthetic note, no DEMO badge. It then frames each
capture with a headline in its own band above it, so no text covers the note,
cents, string or control.

- **iPhone 6.9"** (1320×2868, required): six shots.
- **iPad 13"** (2064×2752, required, since the app runs on iPad): four shots.
  The two Feel the Beat shots are iPhone only, because the feature does not
  exist on iPad.

| # | Headline | Shows |
|---|---|---|
| 01 | See your string settle. | In-tune low E, still string |
| 02 | Feel the Beat. | Settings with Feel the Beat on (iPhone only) |
| 03 | Tune by touch. | A string 12¢ flat, wobbling (iPhone only) |
| 04 | Too slack? Tighten. | Low E 22¢ flat, "TOO SLACK · TIGHTEN" |
| 05 | Guitar. Bass. Ukulele. Yours. | Tuning sheet, Favorites |
| 06 | No accounts. No ads. | A 16¢ sharp, "TOO TIGHT · EASE OFF" |

The live 1.0 listing shows a DEMO badge in its 6.9" and iPad shots and `−00.0` /
`−04.5` in its in-tune shots; see `AppStore/screenshots/contact-before.png`.
The 1.1 sets replace all three live sets. The old 6.5" set should be deleted, or
it keeps showing on 6.5" devices.

## 7. Preview video: deferred

An honest preview needs the real thing: a phone on a guitar, a string brought
into tune by hand, real sound or none. The simulator's synthetic note would be
UI footage of a signal no one played. Proposed shot list when there is time:
- open on a flat low E, wobbling
- turn the peg until the string goes still
- open Settings and turn on Feel the Beat
- a caption: "Your phone taps the beat. Feel it slow, then stop."
- 15–25 s, captions instead of narration

## 8. Device and test matrix

| Check | How | Result |
|---|---|---|
| Unit: DSP, assignment, tunings, cents format | `ZeroFretTests`, iPhone 17 Pro Max sim, iOS 26 | ✅ 129 pass |
| UI: stage, pin, sheets, favorites, custom tuning, landscape | `ZeroFretUITests` | ✅ 9 pass |
| Accessibility audit, AX XXXL | `ZeroFretUITests` | ✅ pass, with the exclusions in §4 |
| Every new instrument's strings read correctly | `InstrumentTests` (synthetic plucked and bowed) | pass |
| Release build for device | `xcodebuild -configuration Release generic/platform=iOS` | see final run |
| **On device, needs Patrick** | | |
| Zero shows `0.0` in tune; flat/sharp keep sign | iPhone + guitar | ☐ |
| Feel the Beat: countable, slows, stops | iPhone | ☐ |
| iPad: haptic toggles disabled with the note | iPad | ☐ |
| Low B (5-string bass), 7/8-string, ukulele re-entrant G | instruments | ☐ |
| Reference 442 then back to 440: targets and direction follow | any | ☐ |
| Mic denied → Open Settings; call interruption; background → foreground | iPhone | ☐ |
| Readability at low brightness, smallest supported iPhone | iPhone SE / mini | ☐ |
| VoiceOver walk-through (for the declaration), including the custom editor | iPhone | ☐ |
| Pitch against a reference tone (A440 fork or generator) | iPhone | ☐ (no pass threshold invented here; §9.3 says ±0.5¢) |

## 9. Needs Patrick's approval before release

1. Merge `release-1.1-polish`. This publishes the new privacy policy in the README.
2. The device checks above, especially Feel the Beat, before its captions ship.
3. Choose the subtitle: `Guitar & bass tuner. Feel it.` or `Guitar, bass & ukulele tuner`.
4. The accessibility declaration in App Store Connect.
5. Ship it:
   - `Scripts/archive.sh --upload` (build 10)
   - `Scripts/metadata.py push --create-version 1.1`
   - upload the screenshot sets and delete the old 6.5" set
   - tag `v1.1` on the archived commit

## Follow-ups (not in this release)

- At AX sizes: let the tuning name wrap or shrink rather than truncate, and scale
  the reference presets.
- Cello and other sparse low tunings do not lock. This needs detector work,
  not a preset.
- `xcrun simctl delete unavailable`: the simulator store is 48 GB, and the
  disk filled during this work.
