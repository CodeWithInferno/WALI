@testable import WALIAppRuntime
import XCTest

final class CreatorTermsDocumentTests: XCTestCase {
    func testDocumentIsAvailableOnlyForTheExactServerVersion() throws {
        let document = try XCTUnwrap(CreatorTermsDocument.supported(version: "2026-09-12"))

        XCTAssertEqual(document.version, "2026-09-12")
        XCTAssertEqual(document.title, "WALI Creator Content License")
        XCTAssertEqual(document.status, "Effective 12 September 2026")
        let text = document.sections.flatMap(\.paragraphs).joined(separator: " ")
        XCTAssertTrue(text.contains("permission"))
        XCTAssertTrue(text.contains("original author"))
        XCTAssertTrue(text.contains("Report"))
        XCTAssertFalse(text.contains("counsel approval"))
        XCTAssertNil(CreatorTermsDocument.supported(version: "2026-09-01"))
        XCTAssertNil(CreatorTermsDocument.supported(version: "2026-09-01.1"))
        XCTAssertNil(CreatorTermsDocument.supported(version: "2027-01-01"))
    }
}
