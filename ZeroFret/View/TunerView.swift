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

    @State private var showTunings = false
    @State private var showSettings = false

    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            Theme.stage.ignoresSafeArea()

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
        .sheet(isPresented: $showTunings) { TuningSheet() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: - Top rail

    private var topRail: some View {
        HStack(spacing: 12) {
            Button { showTunings = true } label: {
                HStack(spacing: 6) {
                    Text(engine.tuning.name)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Theme.trueTone.opacity(0.85))
            }
            .accessibilityLabel("Tuning: \(engine.tuning.name). Change tuning.")

            if engine.isDemoSignal {
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
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var referenceLabel: String {
        let value = engine.referenceA
        return value == value.rounded()
            ? "A\(Int(value))"
            : String(format: "A%.1f", value)
    }

    // MARK: - Stage

    private var portraitStage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            noteGlyph
            Spacer(minLength: 12)
            string
                .padding(.horizontal, 28)
            Spacer(minLength: 12)
            readout
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var landscapeStage: some View {
        HStack(spacing: 24) {
            VStack(spacing: 4) {
                noteGlyph
                readout
            }
            .frame(maxWidth: 220)
            string
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accent: Color { Theme.color(for: engine.display.direction) }

    private var noteGlyph: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(engine.display.hasPitch ? engine.display.noteName : "—")
                    .font(.system(size: isLandscape ? 72 : 104, weight: .thin, design: .rounded))
                Text(engine.display.hasPitch ? "\(engine.display.octave)" : "")
                    .font(.system(size: isLandscape ? 28 : 38, weight: .light, design: .rounded))
                    .baselineOffset(isLandscape ? 12 : 18)
                    .foregroundStyle(accent.opacity(0.55))
            }
            .foregroundStyle(engine.display.hasPitch ? accent : Theme.faint)
            .shadow(color: shouldGlow ? accent.opacity(0.55) : .clear, radius: 11)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.12), value: engine.display.noteLabel)

            Text(targetLine)
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .opacity(engine.display.hasPitch ? 1 : 0.35)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var shouldGlow: Bool {
        engine.display.hasPitch && engine.display.direction == .inTune
    }

    private var targetLine: String {
        guard engine.display.hasPitch else { return "listening" }
        let target = MusicMath.frequency(midi: Double(engine.display.targetMIDI),
                                         referenceA: engine.referenceA)
        let suffix = engine.display.isChromaticFallback ? " · chromatic" : ""
        return String(format: "%.2f Hz → %.2f Hz%@",
                      engine.display.frequency, target, suffix)
    }

    private var string: some View {
        StringCanvas(cents: engine.display.cents,
                     phase: engine.display.phase,
                     hasPitch: engine.display.hasPitch,
                     inTune: engine.display.direction == .inTune,
                     color: accent)
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            // Fixed-width field sized to −00.0¢ with monospaced digits. §6:
            // proportional digits make the whole block shimmer at 47 updates/s.
            Text(engine.display.centsText)
                .font(.system(size: isLandscape ? 34 : 44, weight: .light, design: .rounded)
                    .monospacedDigit())
            Text("¢")
                .font(.system(size: isLandscape ? 20 : 24, weight: .light, design: .rounded))
                .foregroundStyle(accent.opacity(0.5))
        }
        .foregroundStyle(engine.display.hasPitch ? accent : Theme.faint)
        .shadow(color: shouldGlow ? accent.opacity(0.45) : .clear, radius: 11)
        .accessibilityHidden(true)
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
            }

            HStack(spacing: 6) {
                ForEach(engine.tuning.strings) { string in
                    StringChip(string: string,
                               isActive: engine.display.stringIndex == string.index,
                               isPinned: engine.pinnedString == string.index,
                               cents: engine.cents(to: string),
                               tolerance: engine.toleranceCents)
                        .onTapGesture {
                            engine.pinnedString = engine.pinnedString == string.index
                                ? nil
                                : string.index
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
private struct StringChip: View {
    let string: TuningString
    let isActive: Bool
    let isPinned: Bool
    let cents: Double?
    let tolerance: Double

    private var tint: Color {
        guard isActive, let cents else { return Theme.faint }
        return Theme.color(for: TuneDirection.from(cents: cents, tolerance: tolerance))
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(string.noteName)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(isActive ? tint : Theme.trueTone.opacity(0.55))
            Text("\(string.octave)")
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? tint.opacity(0.14) : Color.white.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isPinned ? Theme.trueTone.opacity(0.7)
                                       : (isActive ? tint.opacity(0.55) : Color.clear),
                              lineWidth: isPinned ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: isActive)
        .accessibilityLabel("\(string.label) string\(isPinned ? ", pinned" : "")")
        .accessibilityAddTraits(.isButton)
    }
}
