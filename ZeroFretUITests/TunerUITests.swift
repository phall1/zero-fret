import XCTest

/// Interaction and layout coverage that the host test bundle cannot reach.
///
/// These run against the Simulator's synthetic input (see `SyntheticInput`), so
/// the readout is a generated signal, not a microphone. That is deliberate: it
/// makes the UI deterministic enough to assert on while still driving the real
/// detection pipeline underneath.
final class TunerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-zf-reset-tunings"]
        app.launch()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app = nil
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testStageShowsAReadingFromTheSyntheticSource() {
        let glyph = app.staticTexts["noteGlyph"]
        XCTAssertTrue(glyph.waitForExistence(timeout: 10))

        // The window has to fill before anything is believable: 4096 frames at
        // 48 kHz is 85 ms, plus engine start.
        let deadline = Date().addingTimeInterval(10)
        var label = ""
        while Date() < deadline {
            label = glyph.label
            if label.contains("flat") || label.contains("sharp") || label.contains("in tune") {
                break
            }
            usleep(200_000)
        }
        XCTAssertFalse(label.contains("No pitch detected"), "stage never produced a reading")
        XCTAssertTrue(label.contains("cents"), "unexpected readout label: \(label)")
        attach("stage")
    }

    func testTappingAStringPinsAndUnpinsIt() {
        let chip = app.buttons["string.0"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10))

        chip.tap()
        XCTAssertTrue(app.staticTexts["pinBanner"].waitForExistence(timeout: 3),
                      "pinning a string should show the release hint")
        attach("pinned")

        chip.tap()
        XCTAssertTrue(app.staticTexts["pinBanner"].waitForNonExistence(timeout: 3),
                      "tapping again should release the pin")
    }

    func testTuningSheetSwitchesToBassAndBack() {
        app.buttons["tuningButton"].tap()
        XCTAssertTrue(app.otherElements["tuningList"].waitForExistence(timeout: 5)
                      || app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        attach("tuning-sheet")

        let bass = app.buttons["tuning.bass.five"]
        // The bass section is below the fold on a phone-sized sheet.
        var swipes = 0
        while !bass.exists, swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(bass.waitForExistence(timeout: 5), "Bass 5-String row missing")
        bass.tap()

        // The thumb zone must now show five strings, lowest B0.
        XCTAssertTrue(app.buttons["tuningButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["tuningButton"].label.contains("Bass 5-String"), true,
                       "top rail did not follow the tuning change")

        app.buttons["tuningButton"].tap()
        let standard = app.buttons["tuning.guitar.standard"]
        XCTAssertTrue(standard.waitForExistence(timeout: 5))
        standard.tap()
    }

    func testSettingsRoundTripsTheReferencePitch() {
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.otherElements["settingsList"].waitForExistence(timeout: 5)
                      || app.collectionViews.firstMatch.waitForExistence(timeout: 5))
        attach("settings")

        let preset442 = app.buttons["reference.442"]
        XCTAssertTrue(preset442.waitForExistence(timeout: 5), "442 preset missing")
        preset442.tap()
        app.buttons["Done"].tap()

        // A non-440 reference must be visible on the stage, in the warm colour.
        XCTAssertTrue(app.staticTexts["A442"].waitForExistence(timeout: 5),
                      "reference pitch did not reach the top rail")

        app.buttons["settingsButton"].tap()
        let preset440 = app.buttons["reference.440"]
        XCTAssertTrue(preset440.waitForExistence(timeout: 5))
        preset440.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["A440"].waitForExistence(timeout: 5))
    }

    func testFavoritesNarrowTheSheetToWhatThePlayerUses() {
        app.buttons["tuningButton"].tap()
        XCTAssertTrue(app.buttons["tuning.guitar.standard"].waitForExistence(timeout: 5))

        // Star a ukulele tuning, which is well below the fold.
        let star = app.buttons["favorite.ukulele.standard"]
        scrollTo(star)
        star.tap()
        XCTAssertEqual(star.label, "Remove Ukulele from favorites")

        app.segmentedControls["tuningFilter"].buttons["Favorites"].tap()
        let uke = app.buttons["tuning.ukulele.standard"]
        XCTAssertTrue(uke.waitForExistence(timeout: 3), "starred tuning missing from Favorites")
        XCTAssertFalse(app.buttons["tuning.guitar.standard"].exists,
                       "Favorites should hide what is not starred")
        attach("favorites")

        uke.tap()
        XCTAssertTrue(app.buttons["tuningButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tuningButton"].label.contains("Ukulele"))
        // Four strings, with the re-entrant G first.
        XCTAssertTrue(app.buttons["string.3"].exists)
        XCTAssertFalse(app.buttons["string.4"].exists)

        // The filter is remembered: the next open goes straight to Favorites.
        app.buttons["tuningButton"].tap()
        XCTAssertTrue(app.buttons["tuning.ukulele.standard"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tuning.guitar.standard"].exists)

        // Unstarring the last one leaves the empty state, not a blank sheet.
        app.buttons["favorite.ukulele.standard"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["favoritesEmpty"].waitForExistence(timeout: 3))

        app.segmentedControls["tuningFilter"].buttons["All"].tap()
        let standard = app.buttons["tuning.guitar.standard"]
        XCTAssertTrue(standard.waitForExistence(timeout: 3))
        standard.tap()
    }

    func testCustomTuningIsMadeUsedAndDeleted() {
        app.buttons["tuningButton"].tap()
        let add = app.buttons["newCustomTuning"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let name = app.textFields["customName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 24) + "Drop C")

        // Starts as a copy of Standard. Take every string down a whole step,
        // and the lowest one a further whole step: C G C F A D.
        for index in 0..<6 {
            let down = app.buttons["customString.\(index)-Decrement"]
            scrollTo(down)
            let steps = index == 0 ? 4 : 2
            for _ in 0..<steps { down.tap() }
        }
        XCTAssertEqual(app.buttons["customString.0-Decrement"].value as? String, "C2")
        attach("custom-editor")

        app.buttons["customSave"].tap()

        // Saving tunes to it and closes both sheets.
        let rail = app.buttons["tuningButton"]
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertTrue(rail.label.contains("Drop C"), "rail shows \(rail.label)")
        XCTAssertTrue(app.buttons["newCustomTuning"].waitForNonExistence(timeout: 3),
                      "the tuning sheet should close with the editor")
        XCTAssertTrue(app.buttons["string.5"].exists)

        // Delete it from the list; the tuner falls back to Standard.
        rail.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tuning.custom.'"))
            .firstMatch
        scrollTo(row)
        XCTAssertTrue(row.label.contains("Drop C"))
        row.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3), "custom tuning was not deleted")

        app.buttons["Done"].tap()
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        XCTAssertTrue(rail.label.contains("Standard"), "rail shows \(rail.label)")
    }

    private func scrollTo(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "\(element) never came into view", file: file, line: line)
    }

    func testLandscapeKeepsTheWholeStageOnScreen() {
        XCTAssertTrue(app.staticTexts["noteGlyph"].waitForExistence(timeout: 10))

        XCUIDevice.shared.orientation = .landscapeLeft
        // Give the layout a beat to settle before measuring.
        XCTAssertTrue(app.staticTexts["noteGlyph"].waitForExistence(timeout: 5))
        attach("landscape")

        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "did not actually rotate")

        // Everything that matters must still be inside the window: the stage is
        // read at arm's length with an instrument in the way, so a clipped glyph
        // or an off-screen thumb zone is a real defect.
        let stage: [XCUIElement] = [app.staticTexts["noteGlyph"],
                                    app.buttons["tuningButton"],
                                    app.buttons["settingsButton"]]
        for element in stage {
            XCTAssertTrue(element.exists, "\(element.identifier) missing in landscape")
            XCTAssertTrue(window.contains(element.frame),
                          "\(element.identifier) at \(element.frame) escapes \(window)")
        }

        for index in 0..<6 {
            let chip = app.buttons["string.\(index)"]
            XCTAssertTrue(chip.exists, "string \(index) missing in landscape")
            XCTAssertTrue(window.contains(chip.frame),
                          "string \(index) at \(chip.frame) escapes \(window)")
        }
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists { return true }
            usleep(100_000)
        }
        return !exists
    }
}
