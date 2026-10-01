import XCTest

final class TuningCollectionTests: XCTestCase {
    private var suiteName = ""
    private var store: UserDefaults!

    override func setUp() {
        suiteName = "zf.tests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
    }

    private func custom(_ name: String = "Mine", notes: [Int] = [38, 45, 50, 55, 59, 62],
                        id: String = TuningCollection.makeID()) -> Tuning {
        Tuning(id: id, name: name, family: .guitar, midiNotes: notes)
    }

    // MARK: - The presets

    func testPresetIDsAreUnique() {
        let ids = TuningLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryPresetIsSomethingACustomTuningCouldAlsoBe() {
        // The editor's limits are the detector's limits. A preset outside them
        // would be a note the app ships but will not let a player type in.
        for tuning in TuningLibrary.all {
            XCTAssertTrue(Tuning.stringCountRange.contains(tuning.midiNotes.count), tuning.name)
            for midi in tuning.midiNotes {
                XCTAssertTrue(Tuning.midiRange.contains(midi), "\(tuning.name): \(midi)")
            }
            XCTAssertNotEqual(tuning.family, .custom, tuning.name)
        }
    }

    func testGaugeFollowsPitchNotPosition() {
        let standard = TuningLibrary.standard
        XCTAssertEqual(standard.gauge(of: 0), 1)
        XCTAssertEqual(standard.gauge(of: 5), 0)
        XCTAssertEqual(standard.gauge(of: 1), 0.8, accuracy: 1e-9)

        // G4 sits first on a ukulele but is not its thickest string.
        let uke = TuningLibrary.ukulele
        XCTAssertEqual(uke.gauge(of: 1), 1, "C4 is the lowest note")
        XCTAssertEqual(uke.gauge(of: 3), 0, "A4 is the highest note")
        XCTAssertLessThan(uke.gauge(of: 0), uke.gauge(of: 2), "G4 is thinner than E4")

        XCTAssertEqual(Tuning(id: "x", name: "", family: .custom, midiNotes: [40]).gauge(of: 0), 0.5)
        XCTAssertEqual(standard.gauge(of: 99), 0.5)
    }

    func testGroupsListEveryPresetOnceAndCustomLast() {
        let collection = TuningCollection(store: store)
        XCTAssertFalse(collection.groups.contains { $0.family == .custom },
                       "an empty Custom section is noise")
        XCTAssertEqual(collection.groups.flatMap(\.tunings).count, TuningLibrary.all.count)

        collection.save(custom())
        XCTAssertEqual(collection.groups.last?.family, .custom)
        XCTAssertEqual(collection.groups.last?.tunings.count, 1)
    }

    // MARK: - Custom tunings

    func testSavedTuningSurvivesARelaunch() {
        let made = custom("Open C", notes: [36, 43, 48, 55, 60, 64])
        TuningCollection(store: store).save(made)

        let reloaded = TuningCollection(store: store)
        XCTAssertEqual(reloaded.custom.count, 1)
        XCTAssertEqual(reloaded.tuning(id: made.id)?.midiNotes, [36, 43, 48, 55, 60, 64])
        XCTAssertEqual(reloaded.tuning(id: made.id)?.family, .custom)
        XCTAssertEqual(reloaded.tuning(id: made.id)?.name, "Open C")
    }

    func testSavingTheSameIDReplacesRatherThanDuplicates() {
        let collection = TuningCollection(store: store)
        let id = TuningCollection.makeID()
        collection.save(custom("First", id: id))
        collection.save(custom("Second", notes: [40, 45], id: id))
        XCTAssertEqual(collection.custom.count, 1)
        XCTAssertEqual(collection.custom.first?.name, "Second")
        XCTAssertEqual(collection.custom.first?.midiNotes, [40, 45])
    }

    func testSaveCleansUpWhatTheEditorHandsIt() {
        let collection = TuningCollection(store: store)
        let notes = [5, 40, 120] + Array(repeating: 50, count: 20)
        let saved = collection.save(custom("   ", notes: notes))
        XCTAssertEqual(saved?.name, "Custom", "a blank name still needs to read as something")
        XCTAssertEqual(saved?.midiNotes.count, Tuning.stringCountRange.upperBound)
        XCTAssertEqual(saved?.midiNotes.first, Tuning.midiRange.lowerBound)
        XCTAssertEqual(saved?.midiNotes[2], Tuning.midiRange.upperBound)
    }

    func testSaveRefusesWhatCannotBeACustomTuning() {
        let collection = TuningCollection(store: store)
        XCTAssertNil(collection.save(custom(notes: [])))
        XCTAssertNil(collection.save(custom(notes: [40])), "one string never locks")
        // A preset's ID must never be shadowed by a custom one.
        XCTAssertNil(collection.save(custom(id: TuningLibrary.standard.id)))
        XCTAssertTrue(collection.custom.isEmpty)
        XCTAssertEqual(collection.tuning(id: TuningLibrary.standard.id), TuningLibrary.standard)
    }

    func testCustomizedPresetIsAnIndependentCopy() {
        let copy = TuningLibrary.dadgad.customized(id: TuningCollection.makeID())
        XCTAssertEqual(copy.family, .custom)
        XCTAssertEqual(copy.midiNotes, TuningLibrary.dadgad.midiNotes)
        XCTAssertNotEqual(copy.id, TuningLibrary.dadgad.id)
        XCTAssertNotNil(TuningCollection(store: store).save(copy))
    }

    func testCorruptStoreLoadsAsEmptyRatherThanCrashing() {
        store.set(Data("not json".utf8), forKey: "zf.customTunings")
        XCTAssertTrue(TuningCollection(store: store).custom.isEmpty)
    }

    func testOneUnreadableEntryDoesNotLoseTheRest() {
        let good = custom("Keep me")
        let json = """
        [{"id": "custom.future", "name": "From a later build", "family": "harp", "midiNotes": [40, 45]},
         \(String(data: try! JSONEncoder().encode(good), encoding: .utf8)!)]
        """
        store.set(Data(json.utf8), forKey: "zf.customTunings")
        XCTAssertEqual(TuningCollection(store: store).custom.map(\.name), ["Keep me"])
    }

    func testDeletingForgetsTheFavoriteToo() {
        let collection = TuningCollection(store: store)
        let made = custom()
        collection.save(made)
        collection.toggleFavorite(made.id)
        XCTAssertTrue(collection.isFavorite(made.id))

        collection.delete(id: made.id)
        XCTAssertNil(collection.tuning(id: made.id))
        XCTAssertFalse(collection.isFavorite(made.id))
        XCTAssertFalse(TuningCollection(store: store).isFavorite(made.id))
    }

    func testDeletingAPresetIsNotPossible() {
        let collection = TuningCollection(store: store)
        collection.delete(id: TuningLibrary.standard.id)
        XCTAssertNotNil(collection.tuning(id: TuningLibrary.standard.id))
    }

    // MARK: - Favorites

    func testFavoritesKeepLibraryOrderAndPersist() {
        let collection = TuningCollection(store: store)
        let made = custom()
        collection.save(made)
        // Starred out of order on purpose.
        collection.toggleFavorite(made.id)
        collection.toggleFavorite(TuningLibrary.ukulele.id)
        collection.toggleFavorite(TuningLibrary.dropD.id)

        let expected = [TuningLibrary.dropD.id, TuningLibrary.ukulele.id, made.id]
        XCTAssertEqual(collection.favorites.map(\.id), expected)
        XCTAssertEqual(TuningCollection(store: store).favorites.map(\.id), expected)

        collection.toggleFavorite(TuningLibrary.ukulele.id)
        XCTAssertEqual(collection.favorites.map(\.id), [TuningLibrary.dropD.id, made.id])
    }

    func testFavoritesFilterIsRemembered() {
        let collection = TuningCollection(store: store)
        XCTAssertFalse(collection.showsFavoritesOnly)
        collection.showsFavoritesOnly = true
        XCTAssertTrue(TuningCollection(store: store).showsFavoritesOnly)
    }

    func testAFavoriteThatNamesNothingIsIgnored() {
        store.set(["guitar.gone", TuningLibrary.standard.id], forKey: "zf.favoriteTunings")
        XCTAssertEqual(TuningCollection(store: store).favorites.map(\.id),
                       [TuningLibrary.standard.id])
    }
}
