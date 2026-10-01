//  TuningEditor.swift
//  Zero Fret
//
//  Makes or edits a custom tuning. Notes move a semitone at a time, because
//  that is how a player thinks about retuning a string — "drop it a whole
//  step" is two taps, not a scroll through a picker of every note there is.

import SwiftUI

struct TuningEditor: View {
    @Environment(TunerEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    private let id: String
    private let isNew: Bool
    private let onSave: () -> Void

    @State private var name: String
    @State private var strings: [EditableString]
    @State private var confirmingDelete = false

    init(tuning: Tuning, isNew: Bool, onSave: @escaping () -> Void) {
        id = tuning.id
        self.isNew = isNew
        self.onSave = onSave
        _name = State(initialValue: tuning.name)
        _strings = State(initialValue: tuning.midiNotes.map { EditableString(midi: $0) })
    }

    private var draft: Tuning {
        Tuning(id: id, name: name, family: .custom, midiNotes: strings.map(\.midi))
    }

    private var canAdd: Bool { strings.count < Tuning.stringCountRange.upperBound }
    private var canRemove: Bool { strings.count > Tuning.stringCountRange.lowerBound }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityIdentifier("customName")
                } header: {
                    Text("Name")
                }
                .listRowBackground(Theme.stageRaised)

                Section {
                    addButton("Add Low String", identifier: "addLowString") {
                        let below = (strings.first?.midi ?? 45) - 5
                        strings.insert(EditableString(midi: clamp(below)), at: 0)
                    }
                    ForEach($strings) { $string in
                        stringRow($string)
                    }
                    .onDelete { offsets in
                        guard strings.count - offsets.count >= Tuning.stringCountRange.lowerBound
                        else { return }
                        strings.remove(atOffsets: offsets)
                    }
                    .deleteDisabled(!canRemove)
                    addButton("Add High String", identifier: "addHighString") {
                        let above = (strings.last?.midi ?? 40) + 5
                        strings.append(EditableString(midi: clamp(above)))
                    }
                } header: {
                    Text("Strings")
                } footer: {
                    Text("In the order they sit across the neck, the string nearest your face first — the same order as the chips on the tuner. Paired strings tuned in unison go in once. Swipe a string to remove it.")
                }
                .listRowBackground(Theme.stageRaised)

                if !isNew {
                    Section {
                        Button("Delete Tuning", role: .destructive) {
                            confirmingDelete = true
                        }
                        .accessibilityIdentifier("customDelete")
                    }
                    .listRowBackground(Theme.stageRaised)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(Theme.stage)
            .navigationTitle(isNew ? "New Tuning" : "Edit Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        engine.saveCustomTuning(draft)
                        dismiss()
                        onSave()
                    }
                    .accessibilityIdentifier("customSave")
                }
            }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    engine.deleteCustomTuning(id: id)
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func stringRow(_ string: Binding<EditableString>) -> some View {
        let position = (strings.firstIndex { $0.id == string.wrappedValue.id } ?? 0)
        let midi = string.wrappedValue.midi
        let hz = MusicMath.frequency(midi: Double(midi), referenceA: engine.referenceA)
        return Stepper(value: string.midi, in: Tuning.midiRange) {
            HStack(alignment: .firstTextBaseline) {
                // Numbered the way players number them: 1 is the highest-placed
                // string, at the far end of the row.
                Text("\(strings.count - position)")
                    .font(.system(.footnote, design: .rounded, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .frame(minWidth: 22, alignment: .leading)
                    .accessibilityLabel("String \(strings.count - position)")
                Text(MusicMath.label(midi: midi))
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(Theme.trueTone)
                    .frame(minWidth: 44, alignment: .leading)
                Text(String(format: "%.1f Hz", hz))
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            // Everything the row shows, read as one phrase: "String 6, E2,
            // 82.4 Hz". Combined from the visible text rather than replaced
            // by a label, so nothing on screen is missing from it.
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("customString.\(position)")
        .accessibilityValue(MusicMath.label(midi: midi))
    }

    private func addButton(_ title: String, identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
        }
        .disabled(!canAdd)
        .accessibilityIdentifier(identifier)
    }

    private func clamp(_ midi: Int) -> Int {
        min(max(midi, Tuning.midiRange.lowerBound), Tuning.midiRange.upperBound)
    }
}

/// A string with an identity of its own, so deleting one row does not shift
/// every binding below it onto the wrong note.
private struct EditableString: Identifiable {
    let id = UUID()
    var midi: Int
}
