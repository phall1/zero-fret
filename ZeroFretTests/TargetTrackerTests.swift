import XCTest

/// The tracker is where "find a note" and "follow a note" were separated, so
/// these tests are mostly about the difference between the two: what it takes
/// to start, and how much less it takes to continue.
final class TargetTrackerTests: XCTestCase {
    private let standard = TuningLibrary.standard
    private func nominal(_ index: Int) -> Double {
        MusicMath.frequency(midi: Double(standard.midiNotes[index]), referenceA: 440)
    }

    private func detection(_ index: Int, contrast: Double, hz: Double? = nil)
        -> HarmonicScorer.Detection {
        let f = hz ?? nominal(index)
        return HarmonicScorer.Detection(
            stringIndex: index,
            score: HarmonicScore(frequency: f, energyRatio: 0.2, cents: 0),
            contrast: contrast)
    }

    private func pitch(_ hz: Double, clarity: Double = 0.9) -> PitchResult {
        PitchResult(frequency: hz, clarity: clarity, rms: 0.01, hasPitch: true)
    }

    /// Drives the tracker until it acquires, returning how many frames it took.
    @discardableResult
    private func acquire(_ tracker: inout TargetTracker, string: Int,
                         contrast: Double = 12) -> Int {
        let hz = nominal(string)
        for frame in 1...40 {
            let outcome = tracker.update(pitch: pitch(hz),
                                         detection: detection(string, contrast: contrast),
                                         nominal: nominal)
            if outcome.voiced { return frame }
        }
        return -1
    }

    func testStartsOutSearching() {
        let tracker = TargetTracker()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertNil(tracker.searchCentre(proposedBy: nil))
    }

    // MARK: - Acquisition

    func testAcquiresASteadyStringAndReportsIt() {
        var tracker = TargetTracker()
        let frames = acquire(&tracker, string: 0)
        XCTAssertGreaterThan(frames, 0, "a dead-steady E2 at contrast 12 must acquire")
        XCTAssertLessThanOrEqual(frames, PitchStability.acquireFrames + 1)
        XCTAssertTrue(tracker.isTracking)
        if case let .tracking(string, _) = tracker.state {
            XCTAssertEqual(string, 0)
        } else {
            XCTFail("expected to be tracking")
        }
    }

    func testWillNotAcquireBelowTheContrastBar() {
        var tracker = TargetTracker()
        let hz = nominal(0)
        for _ in 0..<40 {
            let outcome = tracker.update(
                pitch: pitch(hz),
                detection: detection(0, contrast: TargetTracker.acquireContrast - 0.5),
                nominal: nominal)
            XCTAssertFalse(outcome.voiced)
        }
        XCTAssertFalse(tracker.isTracking)
    }

    /// The whole point of the acquire/hold split: the bar to start is far above
    /// the bar to continue, so raising one does not cost the other.
    func testAcquiringIsStricterThanHolding() {
        XCTAssertGreaterThan(TargetTracker.acquireContrast, TargetTracker.holdContrast)
    }

    // MARK: - The search is steered by the scorer

    func testSearchingCentresTheLagSearchOnTheScorersProposal() {
        let tracker = TargetTracker()
        let proposal = detection(1, contrast: 9, hz: 111.3)
        let centre = tracker.searchCentre(proposedBy: proposal)
        XCTAssertEqual(centre?.hz ?? 0, 111.3, accuracy: 1e-9)
        XCTAssertEqual(centre?.toleranceCents ?? 0, TargetTracker.searchToleranceCents)
    }

    /// The bracket must be narrow enough to exclude the octave below, which is
    /// the error the unconstrained search actually made.
    func testSearchBracketCannotReachAnOctave() {
        XCTAssertLessThan(TargetTracker.searchToleranceCents, 1200)
        XCTAssertLessThan(TargetTracker.trackToleranceCents, 1200)
    }

    func testTrackingCentresOnTheStringBeingFollowed() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 2)
        // Even if the scorer proposes something else, a tracking search follows
        // the string it already has.
        let centre = tracker.searchCentre(proposedBy: detection(5, contrast: 9))
        XCTAssertEqual(centre?.hz ?? 0, nominal(2), accuracy: 0.5)
        XCTAssertEqual(centre?.toleranceCents ?? 0, TargetTracker.trackToleranceCents)
    }

    // MARK: - Holding

    func testHoldsThroughContrastFarBelowWhatAcquisitionNeeds() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        let hz = nominal(0)
        // Contrast a decaying note into a live room actually reaches.
        for _ in 0..<200 {
            let outcome = tracker.update(pitch: pitch(hz, clarity: 0.3),
                                         detection: detection(0, contrast: 3.0),
                                         nominal: nominal)
            XCTAssertTrue(outcome.voiced, "3.0 contrast is above the hold bar")
        }
        XCTAssertTrue(tracker.isTracking)
    }

    func testSurvivesAGapShorterThanTheReleaseWindow() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        for _ in 0..<(TargetTracker.releaseFrames - 1) {
            _ = tracker.update(pitch: PitchResult.none, detection: nil, nominal: nominal)
        }
        XCTAssertTrue(tracker.isTracking, "a gap this short must not cost the lock")
        let outcome = tracker.update(pitch: pitch(nominal(0)),
                                     detection: detection(0, contrast: 3.0),
                                     nominal: nominal)
        XCTAssertTrue(outcome.voiced)
    }

    func testLetsGoAfterTheReleaseWindow() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        for _ in 0..<TargetTracker.releaseFrames {
            _ = tracker.update(pitch: PitchResult.none, detection: nil, nominal: nominal)
        }
        XCTAssertFalse(tracker.isTracking)
        XCTAssertNil(tracker.searchCentre(proposedBy: nil))
    }

    /// Without the leash, a constrained search dragged off by noise keeps
    /// re-centring on wherever it landed and never finds its way back.
    func testLeashReleasesWhenTheFollowedPitchWandersTooFar() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        let farAway = nominal(0) * pow(2, (TargetTracker.leashCents + 40) / 1200)
        let outcome = tracker.update(pitch: pitch(farAway),
                                     detection: detection(0, contrast: 5),
                                     nominal: nominal)
        XCTAssertFalse(outcome.voiced)
        XCTAssertFalse(tracker.isTracking)
    }

    func testFollowsAStringThatIsBadlyOutOfTune() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        // A semitone and a half flat is well inside the leash and must be kept.
        let flat = nominal(0) * pow(2, -150.0 / 1200)
        let outcome = tracker.update(pitch: pitch(flat),
                                     detection: detection(0, contrast: 4),
                                     nominal: nominal)
        XCTAssertTrue(outcome.voiced)
        XCTAssertEqual(outcome.frequency, flat, accuracy: 1e-9)
    }

    // MARK: - Changing strings

    func testMovesToAnotherStringPlayedConvincingly() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        for _ in 0..<TargetTracker.switchFrames {
            _ = tracker.update(pitch: pitch(nominal(0)),
                               detection: detection(3, contrast: 14),
                               nominal: nominal)
        }
        // It drops back to searching rather than jumping across, because the
        // constrained search does not yet know where the new string is.
        XCTAssertFalse(tracker.isTracking)
        let frames = acquire(&tracker, string: 3)
        XCTAssertGreaterThan(frames, 0)
        if case let .tracking(string, _) = tracker.state {
            XCTAssertEqual(string, 3)
        } else {
            XCTFail("expected to be tracking the new string")
        }
    }

    func testDoesNotMoveOnAnUnconvincingNeighbour() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        for _ in 0..<20 {
            _ = tracker.update(pitch: pitch(nominal(0)),
                               detection: detection(3, contrast: 3.0),
                               nominal: nominal)
        }
        XCTAssertTrue(tracker.isTracking, "3.0 is below the bar to take over")
        if case let .tracking(string, _) = tracker.state {
            XCTAssertEqual(string, 0)
        }
    }

    /// The pitch stays near the tracked string throughout, because that is what
    /// a search constrained around E2 actually returns while a G3 rings — it is
    /// the *scorer* that changes its mind, and it has to hold that opinion for
    /// three consecutive frames.
    func testAnInterruptedRunDoesNotSwitch() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        for _ in 0..<(TargetTracker.switchFrames - 1) {
            _ = tracker.update(pitch: pitch(nominal(0)),
                               detection: detection(3, contrast: 14),
                               nominal: nominal)
        }
        // One frame naming the original string resets the contender's run.
        _ = tracker.update(pitch: pitch(nominal(0)),
                           detection: detection(0, contrast: 14),
                           nominal: nominal)
        for _ in 0..<(TargetTracker.switchFrames - 1) {
            _ = tracker.update(pitch: pitch(nominal(0)),
                               detection: detection(3, contrast: 14),
                               nominal: nominal)
        }
        XCTAssertTrue(tracker.isTracking)
        if case let .tracking(string, _) = tracker.state {
            XCTAssertEqual(string, 0)
        }
    }

    func testResetReturnsToSearching() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        tracker.reset()
        XCTAssertFalse(tracker.isTracking)
        XCTAssertEqual(tracker.state, .searching)
    }

    func testAcquisitionReportsItselfOnceOnly() {
        var tracker = TargetTracker()
        let hz = nominal(0)
        var acquisitions = 0
        for _ in 0..<40 {
            let outcome = tracker.update(pitch: pitch(hz),
                                         detection: detection(0, contrast: 12),
                                         nominal: nominal)
            if outcome.acquired { acquisitions += 1 }
        }
        XCTAssertEqual(acquisitions, 1)
    }
}

// MARK: - Coasting

extension TargetTrackerTests {
    /// The behaviour the display depends on: a gap inside the release window
    /// keeps producing readings, flagged so the stage can dim rather than blank.
    func testCoastsThroughAGapRatherThanBlanking() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        let last = nominal(0)
        for frame in 1..<TargetTracker.releaseFrames {
            let outcome = tracker.update(pitch: PitchResult.none, detection: nil,
                                         nominal: nominal)
            XCTAssertTrue(outcome.voiced, "frame \(frame) inside the window must still read")
            XCTAssertTrue(outcome.isHeld, "and must say it is coasting")
            XCTAssertEqual(outcome.frequency, last, accuracy: 1e-9)
            XCTAssertEqual(outcome.string, 0)
        }
        let past = tracker.update(pitch: PitchResult.none, detection: nil, nominal: nominal)
        XCTAssertFalse(past.voiced, "past the window it must let go")
        XCTAssertFalse(tracker.isTracking)
    }

    func testAMeasuredFrameIsNotFlaggedAsHeld() {
        var tracker = TargetTracker()
        acquire(&tracker, string: 0)
        let outcome = tracker.update(pitch: pitch(nominal(0)),
                                     detection: detection(0, contrast: 5),
                                     nominal: nominal)
        XCTAssertTrue(outcome.voiced)
        XCTAssertFalse(outcome.isHeld)
    }

    func testNothingIsCoastedBeforeAnythingWasAcquired() {
        var tracker = TargetTracker()
        let outcome = tracker.update(pitch: PitchResult.none, detection: nil, nominal: nominal)
        XCTAssertFalse(outcome.voiced)
        XCTAssertFalse(outcome.isHeld)
    }

    /// Coasting must not paper over a string that has genuinely stopped: the
    /// window is bounded, and after it the display goes dark.
    func testCoastingIsBounded() {
        XCTAssertLessThanOrEqual(Double(TargetTracker.releaseFrames) * (1024.0 / 48000.0), 0.75,
                                 "a coasted reading older than this is a lie, not a kindness")
    }
}
