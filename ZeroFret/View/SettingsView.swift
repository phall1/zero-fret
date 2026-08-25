//  SettingsView.swift
//  Zero Fret

import SwiftUI

struct SettingsView: View {
    @Environment(TunerEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    private static let referencePresets: [Double] = [415, 432, 438, 440, 441, 442, 443]

    var body: some View {
        @Bindable var engine = engine

        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Reference")
                        Spacer()
                        Text(String(format: "A = %.1f Hz", engine.referenceA))
                            .font(.system(.body, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.trueTone)
                    }
                    Slider(value: $engine.referenceA, in: 410...470, step: 0.5)
                        .tint(Theme.trueTone)
                        .accessibilityIdentifier("referenceSlider")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.referencePresets, id: \.self) { value in
                                Button {
                                    engine.referenceA = value
                                } label: {
                                    Text(String(format: "%.0f", value))
                                        .font(.system(size: 13, weight: .medium, design: .rounded)
                                            .monospacedDigit())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule().fill(engine.referenceA == value
                                                           ? Theme.trueTone.opacity(0.18)
                                                           : Color.white.opacity(0.05))
                                        )
                                        .foregroundStyle(engine.referenceA == value
                                                         ? Theme.trueTone : Theme.muted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("reference.\(Int(value))")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Reference pitch")
                } footer: {
                    Text("Every target is stored as a MIDI note and derived from this, so changing it moves the whole instrument at once.")
                }
                .listRowBackground(Theme.stageRaised)

                Section {
                    HStack {
                        Text("In tune within")
                        Spacer()
                        Text(String(format: "±%.0f¢", engine.toleranceCents))
                            .font(.system(.body, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.trueTone)
                    }
                    Slider(value: $engine.toleranceCents, in: 1...15, step: 1)
                        .tint(Theme.trueTone)
                    Toggle("Haptic tick", isOn: $engine.hapticsEnabled)
                        .tint(Theme.trueTone)
                } header: {
                    Text("Tolerance")
                } footer: {
                    Text("One tick when the note crosses into the band. It will not tick again until the note has drifted past ±\(Int(engine.toleranceCents * 3))¢.")
                }
                .listRowBackground(Theme.stageRaised)

                Section {
                    Picker("Response", selection: $engine.responseMode) {
                        ForEach(ResponseMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(engine.responseMode.detail)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                } header: {
                    Text("Response")
                }
                .listRowBackground(Theme.stageRaised)

                Section {
                    LabeledContent("Input level",
                                   value: String(format: "%.0f dB", max(engine.signal.rmsDB, -99)))
                    LabeledContent("Noise gate (auto)",
                                   value: String(format: "%.0f dB", engine.signal.gateDB))
                    LabeledContent("Sample rate",
                                   value: String(format: "%.0f Hz", engine.signal.sampleRate))
                    LabeledContent("Analysis window",
                                   value: "\(engine.signal.windowSize) samples")
                    LabeledContent("Clarity",
                                   value: String(format: "%.2f", engine.signal.clarity))
                } header: {
                    Text("Signal")
                } footer: {
                    Text("The gate re-calibrates itself after five seconds of silence. The sample rate is whatever the current route actually reports — it is never assumed.")
                }
                .listRowBackground(Theme.stageRaised)
                .font(.system(.body, design: .rounded).monospacedDigit())

                Section {
                    Text("Zero Fret does not record, store, or transmit audio. The microphone runs only while the app is in the foreground.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    LabeledContent("Version", value: AppInfo.versionString)
                } header: {
                    Text("About")
                }
                .listRowBackground(Theme.stageRaised)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.stage)
            .accessibilityIdentifier("settingsList")
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

enum AppInfo {
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
