//  TuningCollection.swift
//  Zero Fret
//
//  The presets plus what the player has made of them: their own tunings, the
//  ones they have starred, and whether the sheet shows only those. Switching
//  between three tunings a night should be two taps, not a scroll past
//  twenty-odd instruments the player does not own.
//
//  Persisted in UserDefaults, which is injected so the tests can use a
//  throwaway suite rather than the app's own.

import Foundation
import Observation

struct TuningGroup: Identifiable {
    let family: InstrumentFamily
    let tunings: [Tuning]
    var id: String { family.rawValue }
}

@Observable
final class TuningCollection {
    private(set) var custom: [Tuning]
    private(set) var favoriteIDs: Set<String>
    var showsFavoritesOnly: Bool {
        didSet { store.set(showsFavoritesOnly, forKey: Key.favoritesOnly) }
    }

    @ObservationIgnored private let store: UserDefaults

    private enum Key {
        static let custom = "zf.customTunings"
        static let favorites = "zf.favoriteTunings"
        static let favoritesOnly = "zf.favoritesOnly"
    }

    init(store: UserDefaults = .standard) {
        self.store = store
        #if DEBUG
        // UI tests start with nothing starred and nothing made, whatever the
        // last run left behind. Release does not compile this.
        if ProcessInfo.processInfo.arguments.contains("-zf-reset-tunings") {
            // The selected tuning too, or a test that stopped on a custom or
            // ukulele tuning would hand the next one the wrong strings.
            [Key.custom, Key.favorites, Key.favoritesOnly, "zf.tuningID"]
                .forEach(store.removeObject(forKey:))
        }
        #endif
        custom = Self.loadCustom(from: store)
        favoriteIDs = Set(store.stringArray(forKey: Key.favorites) ?? [])
        showsFavoritesOnly = store.bool(forKey: Key.favoritesOnly)
    }

    // MARK: - Reading

    /// Presets first, in library order, then the player's own in the order made.
    var all: [Tuning] { TuningLibrary.all + custom }

    func tuning(id: String) -> Tuning? { all.first { $0.id == id } }

    /// Every family that has something in it. Custom comes last.
    var groups: [TuningGroup] {
        let everything = all
        return InstrumentFamily.allCases.compactMap { family in
            let members = everything.filter { $0.family == family }
            return members.isEmpty ? nil : TuningGroup(family: family, tunings: members)
        }
    }

    /// In the same order as `all`, so starring one does not reshuffle the rest.
    /// An ID that no longer names anything is ignored rather than pruned, so a
    /// preset that comes back in a later version comes back starred.
    var favorites: [Tuning] { all.filter { favoriteIDs.contains($0.id) } }

    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }

    // MARK: - Writing

    func toggleFavorite(_ id: String) {
        if favoriteIDs.contains(id) {
            favoriteIDs.remove(id)
        } else {
            favoriteIDs.insert(id)
        }
        saveFavorites()
    }

    /// Inserts a new custom tuning or replaces the one with the same ID.
    /// Returns what was actually stored, which may differ from what was passed:
    /// see `sanitized`. Nil when there is nothing left worth storing.
    @discardableResult
    func save(_ tuning: Tuning) -> Tuning? {
        guard let clean = Self.sanitized(tuning) else { return nil }
        if let index = custom.firstIndex(where: { $0.id == clean.id }) {
            custom[index] = clean
        } else {
            custom.append(clean)
        }
        saveCustom()
        return clean
    }

    func delete(id: String) {
        guard let index = custom.firstIndex(where: { $0.id == id }) else { return }
        custom.remove(at: index)
        saveCustom()
        if favoriteIDs.contains(id) {
            favoriteIDs.remove(id)
            saveFavorites()
        }
    }

    static func makeID() -> String { "custom." + UUID().uuidString }

    /// What may be stored as a custom tuning: always in the custom family, a
    /// name that is not blank, and only a shape the detector is tested against
    /// — see `Tuning.midiRange` and `Tuning.stringCountRange`.
    /// Applied on load as well as save, so a hand-edited or older store cannot
    /// hand the detector a target it was never built for.
    static func sanitized(_ tuning: Tuning) -> Tuning? {
        let notes = tuning.midiNotes
            .prefix(Tuning.stringCountRange.upperBound)
            .map { min(max($0, Tuning.midiRange.lowerBound), Tuning.midiRange.upperBound) }
        guard notes.count >= Tuning.stringCountRange.lowerBound,
              tuning.id.hasPrefix("custom.") else { return nil }
        let trimmed = tuning.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Tuning(id: tuning.id,
                      name: trimmed.isEmpty ? "Custom" : trimmed,
                      family: .custom,
                      midiNotes: Array(notes))
    }

    // MARK: - Persistence

    private static func loadCustom(from store: UserDefaults) -> [Tuning] {
        // One entry at a time: a single record this build cannot read must not
        // take every other custom tuning down with it on the next save.
        guard let data = store.data(forKey: Key.custom),
              let decoded = try? JSONDecoder().decode([Lenient].self, from: data) else { return [] }
        return decoded.compactMap { $0.tuning.flatMap(sanitized) }
    }

    private struct Lenient: Decodable {
        let tuning: Tuning?
        init(from decoder: Decoder) throws {
            tuning = try? Tuning(from: decoder)
        }
    }

    private func saveCustom() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        store.set(data, forKey: Key.custom)
    }

    private func saveFavorites() {
        store.set(favoriteIDs.sorted(), forKey: Key.favorites)
    }
}
