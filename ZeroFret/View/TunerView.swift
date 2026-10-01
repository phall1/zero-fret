//  TunerView.swift
//  Zero Fret
//
//  Stage and thumb zone. The stage is read at arm's length with an instrument in
//  the way; the thumb zone is the only part that is ever touched, so everything
//  tappable lives in the bottom third and nothing tappable lives above it.

import SwiftUI

struct TunerView: View {
    @Environment(TunerEngine.self) private var engine
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showTunings = false
    @State private var showSettings = false
    /// 1 on the frame a note arrives in tune, animated back to 0. The only
    /// thing in the app that celebrates: everything else is a measurement.
    @State private var arrival: Double = 0

    private var isLandscape: Bool { verticalSizeClass == .compact }

    /// The shipping app has no demo chip. The simulator shows one so a generated
    /// reading cannot be mistaken for a microphone — except a screenshot launch,
    /// which passes `-zf-hide-demo` or `ZF_HIDE_DEMO=1` so the store shot matches
    /// the device. The flag string stays in the simulator build only.
    private var showsDemoBadge: Bool {
        guard engine.isDemoSignal else { return false }
        #if DEBUG || targetEnvironment(simulator)
        if ReviewLaunch.hideDemoBadge { return false }
        #endif
        return true
    }

    /// Pinning is a deliberate choice about what the app is listening to, so it
    /// gets the selection feedback the system uses for exactly that, and never
    /// the impact used for §7's in-tune tick — two different events must not
    /// feel like the same one.
    private let pinFeedback = UISelectionFeedbackGenerator()

    /// Where this string sits between the thinnest and thickest in the tuning.
    private func chipGauge(for string: TuningString) -> Double {
        engine.tuning.gauge(of: string.index)
    }

    /// Type scales with the reader's setting. The stage is read at arm's length
    /// over the top of an instrument, which is exactly the situation where a
    /// fixed 17pt label is somebody else's decision about your eyesight.
    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 104
    @ScaledMetric(relativeTo: .title2) private var octaveSize: CGFloat = 38
    @ScaledMetric(relativeTo: .title) private var readoutSize: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var targetLineSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var chipNoteSize: CGFloat = 17

    var body: some View {
        ZStack {
            Theme.stageGradient.ignoresSafeArea()

            // The light the string throws onto the stage. It is behind
            // everything and it is never the thing being read — it just means
            // the direction is legible from across a room, before any digit is.
            if engine.display.hasPitch {
                Theme.ambientLight(accent, intensity: ambientIntensity)
                    .ignoresSafeArea()
                    .animation(.easeOut(duration: 0.45), value: engine.display.direction)
                    .animation(.easeOut(duration: 0.3), value: ambientIntensity)
                    .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                topRail
                Divider().overlay(Theme.hairline)

                if engine.permission == .denied {
                    microphoneDenied
                } else if let error = engine.engineError, !engine.isRunning {
                    engineStalled(error)
                } else if isLandscape {
                    landscapeStage
                } else {
                    portraitStage
                }

                thumbZone
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(isLandscape)
        .task { await engine.onAppear() }
        #if DEBUG
        .task { await runReviewTourIfNeeded() }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                engine.enterForeground()
            case .background:
                // Only `.background`. `.inactive` also fires for the microphone
                // permission alert, Control Center and the app switcher, and
                // tearing the engine down there would kill it mid-start.
                engine.enterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: engine.display.direction) { previous, current in
            // Fire only on the crossing into tune, and only from a real reading
            // — a note that appears already in tune has not arrived anywhere.
            guard current == .inTune, previous != .inTune,
                  engine.display.hasPitch, !engine.display.isHeld else { return }
            guard !reduceMotion else { return }
            arrival = 1
            withAnimation(.easeOut(duration: 0.85)) { arrival = 0 }
        }
        .sheet(isPresented: $showTunings) { TuningSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    #if DEBUG
    /// Opens the tuning sheet, switches to Drop D, opens Settings, turns on
    /// Feel the beat, pins a string, then puts the persisted settings back.
    /// Only runs for `-zf-review-tour`. The sleeps are the recording's shot list.
    private func runReviewTourIfNeeded() async {
        guard ReviewLaunch.tourEnabled else { return }
        let savedTuning = engine.tuning
        let savedReference = engine.referenceA
        let savedBeat = engine.beatHapticsEnabled

        await waitUntil(ReviewTour.openTunings)
        showTunings = true
        await waitUntil(ReviewTour.selectDropD)
        engine.tuning = TuningLibrary.dropD
        await waitUntil(ReviewTour.dismissTunings)
        showTunings = false
        await waitUntil(ReviewTour.openSettings)
        showSettings = true
        await waitUntil(ReviewTour.setReference)
        engine.referenceA = 442
        await waitUntil(ReviewTour.enableBeat)
        engine.beatHapticsEnabled = true
        await waitUntil(ReviewTour.dismissSettings)
        showSettings = false
        await waitUntil(ReviewTour.pin)
        engine.pinnedString = 0
        await waitUntil(ReviewTour.unpin)
        engine.pinnedString = nil
        await waitUntil(ReviewTour.restore)
        engine.tuning = savedTuning
        engine.referenceA = savedReference
        engine.beatHapticsEnabled = savedBeat
        engine.pinnedString = nil
    }

    private func waitUntil(_ mark: Double) async {
        let remaining = mark - ReviewLaunch.elapsed
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
    }
    #endif

    // MARK: - Top rail

    private var topRail: some View {
        HStack(spacing: 12) {
            Button { showTunings = true } label: {
                HStack(spacing: 6) {
                    Text(engine.tuning.name)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Theme.trueTone.opacity(0.85))
            }
            .accessibilityIdentifier("tuningButton")
            .accessibilityLabel("Tuning: \(engine.tuning.name). Change tuning.")

            if showsDemoBadge {
                Text("DEMO")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(Theme.stage)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.flat, in: Capsule())
                    .accessibilityLabel("Demo signal, not a microphone reading")
            }

            Spacer(minLength: 0)

            Text(referenceLabel)
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(engine.referenceA == MusicMath.concertA ? Theme.muted : Theme.flat)

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.trueTone.opacity(0.75))
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("settingsButton")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, isLandscape ? 6 : 10)
    }

    private var referenceLabel: String {
        let value = engine.referenceA
        return value == value.rounded()
            ? "A\(Int(value))"
            : String(format: "A%.1f", value)
    }

    // MARK: - Stage

    // The stage is one composition, not three things sharing a screen. Equal
    // spacers pushed the glyph, the string and the readout to opposite ends and
    // left the hero floating in the middle of nothing; fixed internal gaps with
    // flexible space only *outside* the group keeps them reading as one object
    // and lets the string be the centre of gravity it is supposed to be.
    private var portraitStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            noteGlyph
            Spacer().frame(height: 30)
            string
                .padding(.horizontal, 18)
            Spacer().frame(height: 26)
            readoutBlock
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Landscape is not a narrower portrait, and it was being treated as one —
    // the glyph and readout stacked in a fixed 240pt column with the string
    // squeezed into whatever was left. But a string's natural orientation is
    // exactly this one, and a phone is turned sideways precisely so the thing
    // being watched can be wide. So the string spans the whole screen and
    // everything else compresses around it.
    private var landscapeStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            noteGlyph
            Spacer().frame(height: 8)
            string
                .padding(.horizontal, 10)
            Spacer().frame(height: 6)
            readoutBlock
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accent: Color { Theme.color(for: engine.display.direction) }

    /// Coasting readings are dimmed rather than blanked. The detector keeps
    /// following a string for half a second after the evidence thins out, which
    /// is what stops a decaying note flickering off and back on — but the reading
    /// is being repeated, not measured, and the display should say so.
    private var coastOpacity: Double { engine.display.isHeld ? 0.45 : 1 }

    private var noteGlyph: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(engine.display.hasPitch ? engine.display.noteName : "—")
                    .font(.system(size: isLandscape ? glyphSize * 0.60 : glyphSize,
                                  weight: .thin, design: .rounded))
                Text(engine.display.hasPitch ? "\(engine.display.octave)" : "")
                    .font(.system(size: isLandscape ? octaveSize * 0.66 : octaveSize,
                                  weight: .light, design: .rounded))
                    .baselineOffset(isLandscape ? 12 : 18)
                    .foregroundStyle(accent.opacity(0.55))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(engine.display.hasPitch ? accent : Theme.faint)
            .shadow(color: shouldGlow ? accent.opacity(0.55) : .clear, radius: 11)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.12), value: engine.display.noteLabel)

            Text(targetLine)
                .font(.system(size: targetLineSize, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .frame(height: targetLineSize * 1.4)
        }
        .opacity(coastOpacity)
        .animation(.easeOut(duration: 0.18), value: engine.display.isHeld)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("noteGlyph")
        .accessibilityLabel(accessibilitySummary)
    }

    private var shouldGlow: Bool {
        engine.display.hasPitch && engine.display.direction == .inTune
            && !engine.display.isHeld
    }

    /// Empty when idle rather than a second "listening": the instruction under
    /// the readout is already saying it, and the same word twice on one screen
    /// reads as a stuck display rather than a calm one. The height is held so
    /// the layout does not jump when a note arrives.
    private var targetLine: String {
        guard engine.display.hasPitch else { return "" }
        let target = MusicMath.frequency(midi: Double(engine.display.targetMIDI),
                                         referenceA: engine.referenceA)
        let suffix = engine.display.isChromaticFallback ? " · chromatic" : ""
        return String(format: "%.2f Hz → %.2f Hz%@",
                      engine.display.frequency, target, suffix)
    }

    /// How brightly the stage is lit. Strongest in tune — arriving should make
    /// the whole surface come up, not just one glyph — and it swells briefly on
    /// the crossing itself.
    private var ambientIntensity: Double {
        guard engine.display.hasPitch else { return 0 }
        let base = engine.display.direction == .inTune ? 1.0 : 0.6
        return (base + arrival * 0.8) * (engine.display.isHeld ? 0.4 : 1)
    }

    /// Thickest for the lowest string in the tuning, thinnest for the highest.
    /// A wound low E really is several times the diameter of a plain high E.
    private var gauge: Double {
        guard let index = engine.display.stringIndex else { return 0.5 }
        return engine.tuning.gauge(of: index)
    }

    private var string: some View {
        StringCanvas(cents: engine.display.cents,
                     beatHz: engine.display.beatHz,
                     wobble: engine.wobble,
                     hasPitch: engine.display.hasPitch,
                     inTune: engine.display.direction == .inTune,
                     color: accent,
                     gauge: gauge,
                     arrival: arrival,
                     reduceMotion: reduceMotion,
                     maxAmplitude: isLandscape ? 22 : 46)
            .opacity(coastOpacity)
            .animation(.easeOut(duration: 0.18), value: engine.display.isHeld)
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            // Fixed-width field sized to −00.0¢ with monospaced digits. §6:
            // proportional digits make the whole block shimmer at 47 updates/s.
            Text(engine.display.centsText)
                .font(.system(size: isLandscape ? readoutSize * 0.70 : readoutSize,
                              weight: .light, design: .rounded).monospacedDigit())
                .frame(minWidth: isLandscape ? readoutSize * 2.9 : readoutSize * 3.4, alignment: .trailing)
            Text("¢")
                .font(.system(size: (isLandscape ? readoutSize * 0.70 : readoutSize) * 0.55,
                          weight: .light, design: .rounded))
                .foregroundStyle(accent.opacity(0.5))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .foregroundStyle(engine.display.hasPitch ? accent : Theme.faint)
        .shadow(color: shouldGlow ? accent.opacity(0.45) : .clear, radius: 11)
        .opacity(coastOpacity)
        .animation(.easeOut(duration: 0.18), value: engine.display.isHeld)
        .accessibilityHidden(true)
    }

    /// The cents figure with the one instruction that actually moves a peg.
    private var readoutBlock: some View {
        VStack(spacing: 6) {
            readout
            Text(pegInstruction)
                .font(.system(size: targetLineSize + 1, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(engine.display.hasPitch ? accent.opacity(0.75) : Theme.faint)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Deliberately no `contentTransition`. It cross-dissolves the
                // two strings *in place*, so mid-transition "TOO SLACK ·
                // TIGHTEN" and "IN TUNE" are both painted over each other and
                // the line reads as a rendering fault. These are instructions,
                // not a counter — swapping one for the other instantly is both
                // clearer and more honest about the reading having changed.
                .animation(nil, value: pegInstruction)
                // The glyph's summary already states the direction; repeating it
                // here would make VoiceOver say it twice per reading.
                .accessibilityHidden(true)
        }
        .opacity(coastOpacity)
        .animation(.easeOut(duration: 0.18), value: engine.display.isHeld)
    }

    /// Said in the instrument's own words rather than the tuner's.
    ///
    /// "Sharp" and "+25¢" are both facts about the note, and neither is an
    /// instruction — a player still has to know that sharp means tight means
    /// turn it the other way. A string is under tension and every guitarist
    /// already thinks in that vocabulary, so the app says the thing that moves
    /// the hand and lets the number stay the thing that measures.
    private var pegInstruction: String {
        guard engine.display.hasPitch else { return "play a string" }
        switch engine.display.direction {
        case .flat: return "too slack · tighten"
        case .sharp: return "too tight · ease off"
        case .inTune: return "in tune"
        }
    }

    private var accessibilitySummary: String {
        guard engine.display.hasPitch else { return "No pitch detected" }
        let direction: String
        switch engine.display.direction {
        case .flat: direction = "flat"
        case .sharp: direction = "sharp"
        case .inTune: direction = "in tune"
        }
        return String(format: "%@, %.1f cents %@",
                      engine.display.noteLabel, abs(engine.display.cents), direction)
    }

    // MARK: - Thumb zone

    private var thumbZone: some View {
        VStack(spacing: 10) {
            if let pinned = engine.pinnedString,
               engine.tuning.strings.indices.contains(pinned) {
                Text("Pinned to \(engine.tuning.strings[pinned].label) — tap again to release")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("pinBanner")
            }

            HStack(spacing: 6) {
                ForEach(engine.tuning.strings) { string in
                    StringChip(string: string,
                               isActive: engine.display.stringIndex == string.index,
                               isPinned: engine.pinnedString == string.index,
                               cents: engine.cents(to: string),
                               tolerance: engine.toleranceCents,
                               noteSize: chipNoteSize,
                               gauge: chipGauge(for: string),
                               isTuned: engine.tunedStrings.contains(string.index)) {
                        engine.pinnedString = engine.pinnedString == string.index
                            ? nil
                            : string.index
                        pinFeedback.selectionChanged()
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.top, 12)
        .padding(.bottom, isLandscape ? 8 : 18)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Theme.stageRaised
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    // MARK: - Failure states

    private func engineStalled(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.flat)
            Text("No audio input")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.trueTone)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button("Try again") { engine.enterForeground() }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.stage)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Theme.trueTone, in: Capsule())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var microphoneDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.slash")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(Theme.flat)
            Text("Zero Fret needs the microphone")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.trueTone)
            Text("Audio never leaves your device and is never recorded.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button("Open Settings") { engine.openSettings() }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.stage)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Theme.trueTone, in: Capsule())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One string in the thumb zone. Tapping pins assignment to it (§4).
///
/// Six chips in a row is six chances to read the wrong one, and a letter is a
/// slow thing to read at arm's length with a guitar in the way. So each carries
/// a rule beneath it drawn at that string's real gauge — thick for the wound low
/// E, hair-thin for the plain high E. It is the same fact the stage string uses,
/// and it means the row can be navigated by shape before any letter is read.
private struct StringChip: View {
    let string: TuningString
    let isActive: Bool
    let isPinned: Bool
    let cents: Double?
    let tolerance: Double
    let noteSize: CGFloat
    /// 0 thinnest, 1 thickest, within this tuning.
    let gauge: Double
    /// Brought into tune and not since drifted off.
    let isTuned: Bool

    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        guard isActive, let cents else { return Theme.faint }
        return Theme.color(for: TuneDirection.from(cents: cents, tolerance: tolerance))
    }

    private var rule: some View {
        Capsule()
            .fill(isActive ? tint.opacity(0.9)
                           : Theme.trueTone.opacity(isTuned ? 0.85 : 0.28))
            .frame(width: 22, height: 1 + 2.6 * gauge)
    }

    var body: some View {
        // A real Button, not a tap gesture on a shape. The first attempt at
        // press feedback added a zero-distance DragGesture alongside
        // `onTapGesture` to learn when the finger was down, and the drag
        // swallowed the tap — pinning stopped working entirely. A ButtonStyle
        // is handed `isPressed` for free, and being an actual button is also
        // what gives VoiceOver its trait and its activation behaviour.
        Button(action: action) {
            VStack(spacing: 4) {
                Text(string.noteName)
                    .font(.system(size: noteSize, weight: .medium, design: .rounded))
                    .foregroundStyle(isActive ? tint
                                              : Theme.trueTone.opacity(isTuned ? 0.9 : 0.55))
                Text("\(string.octave)")
                    .font(.system(size: noteSize * 0.59, weight: .regular, design: .rounded))
                    .foregroundStyle(Theme.muted)
                rule
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isActive ? tint.opacity(0.15)
                                   : Color.white.opacity(isTuned ? 0.09 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isPinned ? Theme.trueTone.opacity(0.7)
                                           : (isActive ? tint.opacity(0.55) : Color.clear),
                                  lineWidth: isPinned ? 1.5 : 1)
            }
            // The active chip is lit by the same colour lighting the stage, so
            // the eye connects the string it is watching to the chip it taps.
            .shadow(color: isActive ? tint.opacity(0.28) : .clear, radius: 10)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(ChipPressStyle(reduceMotion: reduceMotion))
        .animation(.easeOut(duration: 0.15), value: isActive)
        .animation(.easeOut(duration: 0.3), value: isTuned)
        // Combine first. Without this the note name and the octave each become
        // their own accessibility element, so VoiceOver reads "E" then "2" as two
        // separate buttons and the chip is impossible to address as one control.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("string.\(string.index)")
        .accessibilityLabel("\(string.label) string\(isTuned ? ", in tune" : "")\(isPinned ? ", pinned" : "")")
        .accessibilityHint(isPinned ? "Double tap to release"
                                    : "Double tap to pin the reading to this string")
    }
}

/// Presses in, springs back. A control under a thumb with no press state reads
/// as dead even when it is working.
private struct ChipPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.62),
                       value: configuration.isPressed)
    }
}
