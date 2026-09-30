import Foundation
import Testing
import XCTest

struct SwiftTestingFixtures {
    @Test("A readable title does not identify the function")
    func pass() { #expect(2 + 2 == 4) }

    @Test(arguments: [1, 2, 3])
    func parameterized(value: Int) {
        #expect(value > 0)
        Testing.Attachment.record("parameter value \(value)", named: "value-\(value).txt")
    }

    @Test(.disabled("Intentional fixture skip"))
    func skipped() { #expect(false) }

    @Test func expectedFailure() {
        withKnownIssue("Expected fixture assertion") { #expect(false) }
    }

    @Test func optInFailure() {
        #expect(ProcessInfo.processInfo.environment["TIDEN_FIXTURE_FAILURES"] != "1")
    }
}

final class XCTestFixtures: XCTestCase {
    func testPass() { XCTAssertEqual(2 + 2, 4) }
    func testSkipped() throws { throw XCTSkip("Intentional fixture skip") }
    func testExpectedFailure() {
        XCTExpectFailure("Expected fixture assertion")
        XCTAssertEqual(1, 2)
    }
    func testOptInFailure() { XCTAssertNotEqual(ProcessInfo.processInfo.environment["TIDEN_FIXTURE_FAILURES"], "1") }
}
