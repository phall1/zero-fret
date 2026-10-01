//  TuningSheet.swift
//  Zero Fret

import SwiftUI

struct TuningSheet: View {
    @Environment(TunerEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    /// The tuning open in the editor, and whether saving it makes a new one.
    @State private var editing: EditorRequest?

    private var collection: TuningCollection { engine.tunings }

    var body: some View {
        NavigationStack {
            List {
                if collection.showsFavoritesOnly {
                    favoritesSection
                } else {
                    allSections
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.stage)
            .accessibilityIdentifier("tuningList")
            .navigationTitle("Tuning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        // Starts from whatever is being tuned to, because a
                        // custom tuning is almost always one or two strings away
                        // from something the player already uses.
                        editing = EditorRequest(tuning: engine.tuning.customized(
                            id: TuningCollection.makeID()), isNew: true)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("newCustomTuning")
                    .accessibilityLabel("New custom tuning")
                }
                ToolbarItem(placement: .principal) {
                    filterPicker
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editing) { request in
                TuningEditor(tuning: request.tuning, isNew: request.isNew) {
                    // Saving tunes to it, so the job of this sheet is done too.
                    dismiss()
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

    private var filterPicker: some View {
        @Bindable var collection = collection
        return Picker("Show", selection: $collection.showsFavoritesOnly) {
            Text("All").tag(false)
            Text("Favorites").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: 190)
        .accessibilityIdentifier("tuningFilter")
    }

    // MARK: - Sections

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = collection.favorites
        if favorites.isEmpty {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "star")
                        .font(.title.weight(.light))
                        .foregroundStyle(Theme.muted)
                    Text("No favorites yet")
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .foregroundStyle(Theme.trueTone)
                    Text("Tap the star on any tuning in All and it stays here, so switching is one tap.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .listRowBackground(Theme.stageRaised)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("favoritesEmpty")
            }
        } else {
            Section {
                ForEach(favorites) { row(for: $0) }
            }
        }
    }

    @ViewBuilder
    private var allSections: some View {
        ForEach(collection.groups) { group in
            Section {
                ForEach(group.tunings) { row(for: $0) }
            } header: {
                Text(group.family.title)
                    .foregroundStyle(Theme.muted)
            } footer: {
                footer(for: group.family)
            }
        }
    }

    @ViewBuilder
    private func footer(for family: InstrumentFamily) -> some View {
        switch family {
        case .bass:
            // §3: the window size is a real, audible trade-off, so say why the
            // app behaves differently down here.
            Text("Low tunings analyse an 8192-sample window so that B0 (30.87 Hz) holds enough periods to lock. Slightly slower, and the only way to be right.")
                .font(.caption2)
        case .ukulele, .banjo:
            Text("Strings are listed in the order they sit across the neck, so a re-entrant high string comes first.")
                .font(.caption2)
        case .mandolin:
            Text("One note per course. Tune each pair to the same note.")
                .font(.caption2)
        case .custom:
            Text("Swipe left to edit or delete.")
                .font(.caption2)
        case .guitar, .orchestral:
            EmptyView()
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for tuning: Tuning) -> some View {
        let isFavorite = collection.isFavorite(tuning.id)
        HStack(spacing: 12) {
            Button {
                engine.tuning = tuning
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tuning.name)
                            .font(.system(.body, design: .rounded, weight: .medium))
                            .foregroundStyle(Theme.trueTone)
                        Text(tuning.displaySummary)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if engine.tuning.id == tuning.id {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.trueTone)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("tuning.\(tuning.id)")

            // Borderless, or the List hands every tap in the row to the first
            // button and starring a tuning would select it instead.
            Button {
                collection.toggleFavorite(tuning.id)
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.body.weight(.medium))
                    .foregroundStyle(isFavorite ? Theme.flat : Theme.muted)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("favorite.\(tuning.id)")
            .accessibilityLabel(isFavorite ? "Remove \(tuning.name) from favorites"
                                           : "Add \(tuning.name) to favorites")
        }
        .listRowBackground(Theme.stageRaised)
        .swipeActions(edge: .trailing) {
            if tuning.isCustom {
                Button(role: .destructive) {
                    engine.deleteCustomTuning(id: tuning.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    editing = EditorRequest(tuning: tuning, isNew: false)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }
        }
        .contextMenu {
            Button {
                collection.toggleFavorite(tuning.id)
            } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            if tuning.isCustom {
                Button {
                    editing = EditorRequest(tuning: tuning, isNew: false)
                } label: {
                    Label("Edit…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    engine.deleteCustomTuning(id: tuning.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Button {
                    editing = EditorRequest(tuning: tuning.customized(id: TuningCollection.makeID()),
                                            isNew: true)
                } label: {
                    Label("Customize…", systemImage: "slider.horizontal.3")
                }
            }
        }
    }
}

private struct EditorRequest: Identifiable {
    let tuning: Tuning
    let isNew: Bool
    var id: String { tuning.id }
}
