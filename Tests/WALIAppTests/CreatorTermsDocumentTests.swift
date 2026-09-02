@testable import WALIAppRuntime
import XCTest

final class CreatorTermsDocumentTests: XCTestCase {
    func testDocumentIsAvailableOnlyForTheExactServerVersion() throws {
        let document = try XCTUnwrap(CreatorTermsDocument.supported(version: "2026-09-01"))

        XCTAssertEqual(document.version, "2026-09-01")
        XCTAssertEqual(document.title, "WALI Creator Content License")
        XCTAssertEqual(document.status, "Draft for counsel review; not yet effective for public UGC")
        XCTAssertEqual(
            document.sections.first { $0.title == "Creator promises" }?.paragraphs,
            [
                "The creator represents that they:",
                "own the content or hold written rights sufficient for every grant above;",
                "have permission for identifiable people, trademarks, characters, music, and other protected material where required;",
                "accurately state the source, rights holder, license, and attribution;",
                "are not uploading malicious, deceptive, private, or unlawfully obtained data;",
                "will preserve rights evidence and cooperate with valid notices.",
            ]
        )
        XCTAssertNil(CreatorTermsDocument.supported(version: "2026-09-01.1"))
        XCTAssertNil(CreatorTermsDocument.supported(version: "2027-01-01"))
    }
}
