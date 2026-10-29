import XCTest
@testable import SwarSaathiCore

final class ExerciseRangeTests: XCTestCase {
    func testDifferentHighestNotesAreCheckedAgainstTheSameSa() {
        // The octave does not fit, but the three-note span does. Sa stays 220.
        let sa = 220.0
        XCTAssertTrue(Alankaar.fiveNote.fits(sa: sa, lowerHz: 130, upperHz: 310))
        XCTAssertFalse(Alankaar.standard.fits(sa: sa, lowerHz: 130, upperHz: 310))
        let paPhrase = Alankaar(name: "Sa Re Pa Re Sa", labels: ["Sa", "Re", "Pa", "Re", "Sa"])
        XCTAssertFalse(paPhrase.fits(sa: sa, lowerHz: 130, upperHz: 310))
        XCTAssertTrue(paPhrase.fits(sa: sa, lowerHz: 130, upperHz: 340))
        XCTAssertTrue(Alankaar.standard.fits(sa: sa, lowerHz: 130, upperHz: 450))
        XCTAssertEqual(paPhrase.targets(sa: sa, tuning: .justShuddha)[2].frequency, 330)
    }

    func testNotesBelowSaAreAlsoChecked() {
        let tuning = TuningSystem(name: "Lower-register test", swars: [Swar(label: "Sa", ratio: 1), Swar(label: "Lower Pa", ratio: 0.75)])
        let phrase = Alankaar(name: "Lower phrase", labels: ["Sa", "Lower Pa", "Sa"])
        XCTAssertTrue(phrase.fits(sa: 220, lowerHz: 160, upperHz: 300, tuning: tuning))
        XCTAssertFalse(phrase.fits(sa: 220, lowerHz: 170, upperHz: 300, tuning: tuning))
    }

    func testUnknownOrInvalidTargetDefinitionsCannotLookLikeAFittingExercise() {
        XCTAssertFalse(Alankaar(name: "Empty", labels: []).fits(sa: 220))
        XCTAssertFalse(Alankaar(name: "Unknown", labels: ["Sa", "Missing"]).fits(sa: 220))
        let invalid = TuningSystem(name: "Invalid", swars: [Swar(label: "Bad", ratio: .nan)])
        XCTAssertFalse(Alankaar(name: "Bad", labels: ["Bad"]).fits(sa: 220, tuning: invalid))
    }

    func testInvalidSaAndRangeDoNotPermitPlaybackOrPractice() {
        for sa in [0.0, -220, .nan, .infinity] {
            XCTAssertFalse(Alankaar.fiveNote.fits(sa: sa, lowerHz: 100, upperHz: 300))
        }
        XCTAssertFalse(Alankaar.fiveNote.fits(sa: 220, lowerHz: 300, upperHz: 100))
        XCTAssertFalse(Alankaar.fiveNote.fits(sa: 220, lowerHz: .nan, upperHz: 300))
        XCTAssertFalse(Alankaar.fiveNote.fits(sa: 220, lowerHz: 100, upperHz: .infinity))
    }

    func testActualExtremaFitInclusivelyAndOctaveErrorsCannotBeIgnored() {
        XCTAssertTrue(Alankaar.fiveNote.fits(sa: 220, lowerHz: 220, upperHz: 275))
        XCTAssertFalse(Alankaar.fiveNote.fits(sa: 220, lowerHz: 220.1, upperHz: 275))
        XCTAssertFalse(Alankaar.fiveNote.fits(sa: 220, lowerHz: 220, upperHz: 274.9))
        XCTAssertTrue(Alankaar.standard.fits(sa: 220, lowerHz: 220, upperHz: 440))
        XCTAssertFalse(Alankaar.standard.fits(sa: 220, lowerHz: 220, upperHz: 439.9))
    }
}
