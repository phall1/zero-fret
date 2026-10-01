//  TuningSheet.swift
//  Zero Fret

import SwiftUI

struct TuningSheet: View {
    @Environment(TunerEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(TuningLibrary.grouped()) { group in
                    Section {
                        ForEach(group.tunings) { tuning in
                            row(for: tuning)
                        }
                    } header: {
                        Text(group.family.title)
                            .foregroundStyle(Theme.muted)
                    } footer: {
                        if group.family == .bass {
                            // §3: the window size is a real, audible trade-off,
                            // so say why the app behaves differently down here.
                            Text("Low tunings analyse an 8192-sample window so that B0 (30.87 Hz) holds enough periods to lock. Slightly slower, and the only way to be right.")
                                .font(.caption2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.stage)
            .accessibilityIdentifier("tuningList")
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        #if DEBUG
        .presentationDetents(ReviewLaunch.tourEnabled ? [.large] : [.medium, .large])
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    @ViewBuilder
    private func row(for tuning: Tuning) -> some View {
        Button {
            engine.tuning = tuning
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tuning.name)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.trueTone)
                    Text(tuning.displaySummary)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                if engine.tuning.id == tuning.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.trueTone)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("tuning.\(tuning.id)")
        .listRowBackground(Theme.stageRaised)
    }
}
