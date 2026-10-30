import XCTest
@testable import Paperole

/// Rename Student…'s sentence (review 2026-10-24, UI-07: it read "All 1 paper of Maya Chen get this name.").
final class RenameStudentTests: XCTestCase {
    func testTheSentenceAgreesWithTheCount() {
        XCTAssertEqual(RenameStudentSheet.whoGetsIt("Maya Chen", papers: 1), "Maya Chen’s paper gets this name.")
        XCTAssertEqual(RenameStudentSheet.whoGetsIt("Maya Chen", papers: 3), "All 3 papers of Maya Chen get this name.")
        XCTAssertEqual(RenameStudentSheet.whoGetsIt(nil, papers: 1), "The student’s paper gets this name.")
    }
}
